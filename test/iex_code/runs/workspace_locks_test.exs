defmodule IexCode.Runs.WorkspaceLocksTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs}

  setup do
    root = Path.join(System.tmp_dir!(), "iex-code-locks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create_project(%{name: "Lock Test", root_path: root})
    %{project: project, root: root}
  end

  defp attrs(project, owner, path, overrides \\ %{}) do
    Map.merge(
      %{
        project_id: project.id,
        owner_id: owner,
        resource_type: "file",
        resource_key: path,
        mode: "write",
        lease_seconds: 60
      },
      overrides
    )
  end

  test "canonicalizes files, returns a secret once, and renews idempotently", %{
    project: project,
    root: root
  } do
    assert :ok = Runs.subscribe_workspace_locks(project.id)
    assert {:ok, acquired} = Runs.acquire_workspace_lock(attrs(project, "one", "lib/a.ex"))
    assert_receive {:workspace_locks_updated, [%{capability_token_hash: "[REDACTED]"}]}
    assert is_binary(acquired.capability_token)
    assert [%{status: "held", fencing_token: 1} = lock] = acquired.locks
    assert {:ok, canonical} = IexCode.WorkspacePath.resolve(root, "lib/a.ex")
    assert lock.resource_key == canonical
    assert lock.capability_token_hash == "[REDACTED]"

    assert Runs.get_workspace_lock!(lock.id).capability_token_hash == "[REDACTED]"

    assert hd(Runs.list_workspace_locks(project_id: project.id)).capability_token_hash ==
             "[REDACTED]"

    repeat =
      attrs(project, "one", "lib/a.ex", %{capability_token: acquired.capability_token})

    assert {:ok, renewed} = Runs.acquire_workspace_lock(repeat)
    assert [same] = renewed.locks
    assert same.id == lock.id
    assert same.fencing_token == lock.fencing_token
    assert renewed.capability_token == nil

    assert {:ok, heartbeat} =
             Runs.heartbeat_workspace_lock(lock.id, acquired.capability_token)

    assert heartbeat.capability_token == nil

    assert {:error, :invalid_capability} =
             Runs.acquire_workspace_lock(attrs(project, "one", "lib/a.ex"))

    assert {:error, :invalid_capability} = Runs.assert_workspace_lock(lock.id, "stale-token")
    assert {:ok, asserted} = Runs.assert_workspace_lock(lock.id, acquired.capability_token)
    assert asserted.capability_token == nil
    assert [%{fencing_token: 1}] = asserted.locks
  end

  test "persists conflicts, enforces capabilities and promotes FIFO", %{project: project} do
    {:ok, first} = Runs.acquire_workspace_lock(attrs(project, "one", "lib/a.ex"))
    {:ok, second} = Runs.acquire_workspace_lock(attrs(project, "two", "lib/a.ex"))
    {:ok, third} = Runs.acquire_workspace_lock(attrs(project, "three", "lib/a.ex"))

    assert [%{status: "waiting", wait_reason: "external_conflict"} = second_lock] = second.locks
    assert [%{status: "waiting"} = third_lock] = third.locks

    assert {:error, :invalid_capability} =
             Runs.release_workspace_lock(hd(first.locks).id, "not-the-secret")

    assert {:ok, _released} =
             Runs.release_workspace_lock(hd(first.locks).id, first.capability_token)

    # A newer batch cannot jump the older conflicting waiter.
    assert {:ok, still_waiting} =
             Runs.retry_workspace_lock(third_lock.id, third.capability_token)

    assert still_waiting.capability_token == nil
    assert [%{status: "waiting", wait_reason: "queue_predecessor"}] = still_waiting.locks

    assert {:ok, promoted} =
             Runs.retry_workspace_lock(second_lock.id, second.capability_token)

    assert promoted.capability_token == nil
    assert [%{status: "held", fencing_token: 2}] = promoted.locks

    assert {:ok, _} =
             Runs.release_workspace_lock(second_lock.id, second.capability_token)

    assert {:ok, promoted_third} =
             Runs.retry_workspace_lock(third_lock.id, third.capability_token)

    assert [%{status: "held", fencing_token: 3}] = promoted_third.locks
  end

  test "acquires and promotes multi-resource batches all-or-none", %{project: project} do
    {:ok, blocker} = Runs.acquire_workspace_lock(attrs(project, "blocker", "lib/a.ex"))

    assert {:ok, batch} =
             Runs.acquire_workspace_locks([
               attrs(project, "batch", "lib/a.ex"),
               attrs(project, "batch", "lib/b.ex")
             ])

    assert Enum.map(batch.locks, & &1.status) == ["waiting", "waiting"]
    assert Enum.any?(batch.locks, &(&1.wait_reason == "batch_blocked"))

    assert {:ok, _} =
             Runs.release_workspace_lock(hd(blocker.locks).id, blocker.capability_token)

    assert {:ok, promoted} =
             Runs.retry_workspace_lock(hd(batch.locks).id, batch.capability_token)

    assert Enum.map(promoted.locks, & &1.status) == ["held", "held"]
    assert promoted.locks |> Enum.map(& &1.fencing_token) |> Enum.sort() == [2, 3]
  end

  test "project and git scopes coordinate mutations and reject upgrades", %{project: project} do
    {:ok, file} = Runs.acquire_workspace_lock(attrs(project, "one", "lib/a.ex"))

    assert {:error, :lock_upgrade_not_supported} =
             Runs.acquire_workspace_lock(%{
               project_id: project.id,
               owner_id: "one",
               resource_type: "workspace",
               resource_key: ".",
               mode: "exclusive"
             })

    {:ok, git} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        owner_id: "two",
        resource_type: "git",
        resource_key: ".",
        mode: "exclusive"
      })

    assert [%{status: "waiting"}] = git.locks
    assert {:ok, _} = Runs.release_workspace_lock(hd(file.locks).id, file.capability_token)
  end

  test "canonical aliases and nested project roots share conflict scope", %{
    project: project,
    root: root
  } do
    alias_path = root <> "-alias"
    File.ln_s!(root, alias_path)
    {:ok, alias_project} = Projects.create_project(%{name: "Alias", root_path: alias_path})

    {:ok, parent} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        owner_id: "parent",
        resource_type: "workspace",
        mode: "exclusive"
      })

    {:ok, aliased} =
      Runs.acquire_workspace_lock(attrs(alias_project, "alias", "lib/a.ex"))

    assert [%{status: "waiting"}] = aliased.locks

    nested_root = Path.join(root, "nested")
    File.mkdir_p!(nested_root)
    {:ok, nested} = Projects.create_project(%{name: "Nested", root_path: nested_root})
    {:ok, nested_lock} = Runs.acquire_workspace_lock(attrs(nested, "nested", "file.txt"))
    assert [%{status: "waiting"}] = nested_lock.locks

    assert {:ok, _} =
             Runs.release_workspace_lock(hd(parent.locks).id, parent.capability_token)
  end

  test "expired leases remain durable and cannot be revived", %{project: project} do
    {:ok, acquired} = Runs.acquire_workspace_lock(attrs(project, "one", "lib/a.ex"))
    lock = hd(acquired.locks)
    past = DateTime.utc_now() |> DateTime.add(-5, :second)

    from(lock in IexCode.Runs.WorkspaceLock, where: lock.id == ^lock.id)
    |> Repo.update_all(set: [lease_expires_at: past])

    assert {:ok, 1} = Runs.release_expired_workspace_locks()
    assert Runs.get_workspace_lock!(lock.id).status == "expired"

    assert {:error, {:lock_batch_not_held, ["expired"]}} =
             Runs.assert_workspace_lock(lock.id, acquired.capability_token)

    assert {:error, {:lock_batch_not_active, ["expired"]}} =
             Runs.retry_workspace_lock(lock.id, acquired.capability_token)
  end

  test "project deletion cannot erase an active coordination lease", %{project: project} do
    assert {:ok, acquired} =
             Runs.acquire_workspace_lock(attrs(project, "delete-guard", "lib/guard.ex"))

    assert {:error, :project_has_active_workspace_locks} = Projects.delete_project(project)
    assert Projects.get_project!(project.id)

    assert {:ok, _released} =
             Runs.release_workspace_lock(hd(acquired.locks).id, acquired.capability_token)

    assert {:ok, deleted} = Projects.delete_project(project)
    assert deleted.id == project.id
  end

  test "an unreconciled expired row does not block project deletion", %{project: project} do
    assert {:ok, acquired} =
             Runs.acquire_workspace_lock(attrs(project, "stale-delete", "lib/stale.ex"))

    lock = hd(acquired.locks)
    past = DateTime.utc_now() |> DateTime.add(-5, :second)

    from(row in IexCode.Runs.WorkspaceLock, where: row.id == ^lock.id)
    |> Repo.update_all(set: [lease_expires_at: past])

    assert {:ok, deleted} = Projects.delete_project(project)
    assert deleted.id == project.id
  end
end
