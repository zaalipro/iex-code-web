defmodule IexCode.Tools.MutationSnapshotTest do
  use IexCode.DataCase, async: false

  alias IexCode.Tools.MultiPatch
  alias IexCode.Tools.MultiPatch.Snapshot
  alias IexCode.{Projects, Runs, Sessions}
  alias IexCode.Engine.SwarmCoordinator

  setup do
    root = Path.join(System.tmp_dir!(), "iex_code_snapshot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "rollback manifest stays out of ETS and survives through SQLite", %{root: root} do
    path = Path.join(root, "lib/durable.ex")
    original = "defmodule Durable do\n  def value, do: :before\nend\n"
    File.write!(path, original)

    {:ok, summary} =
      MultiPatch.apply_patches(
        root,
        [%{path: "lib/durable.ex", target: ":before", replacement: ":after"}],
        session_id: "durable-session"
      )

    assert File.read!(path) =~ ":after"
    assert [] == :ets.lookup(Snapshot.table_name(), summary.transaction_id)
    assert [] == :ets.tab2list(Snapshot.table_name())

    assert {:ok, persisted} = Snapshot.get_snapshot(summary.transaction_id)
    assert persisted.session_id == "durable-session"
    assert persisted.project_root == root
    assert [persisted_patch] = persisted.patches
    assert persisted_patch.original_content == original
    assert persisted_patch.new_content =~ ":after"

    assert {:ok, %{restored_files: ["lib/durable.ex"]}} =
             MultiPatch.rollback(summary.transaction_id)

    assert File.read!(path) == original
    assert {:error, :not_found} = Snapshot.get_snapshot(summary.transaction_id)
  end

  test "lists and claims durable rows while purging legacy ETS payloads", %{root: root} do
    other_root = "#{root}-other"
    File.mkdir_p!(other_root)
    on_exit(fn -> File.rm_rf(other_root) end)

    first_id = "claim-first-#{System.unique_integer([:positive])}"
    other_id = "claim-other-#{System.unique_integer([:positive])}"

    assert :ok =
             Snapshot.save_snapshot(first_id, [snapshot_patch(root, "first.txt")],
               project_root: root
             )

    assert :ok =
             Snapshot.save_snapshot(other_id, [snapshot_patch(other_root, "other.txt")],
               project_root: other_root
             )

    :ets.insert(Snapshot.table_name(), {
      "legacy-memory-copy",
      %{patches: [%{original_content: String.duplicate("body", 1_000)}]}
    })

    assert :ok = Snapshot.claim_unscoped(root, "claimed-session")
    assert [] == :ets.tab2list(Snapshot.table_name())

    assert [claimed] = Snapshot.list_snapshots("claimed-session")
    assert claimed.transaction_id == first_id
    assert claimed.patches |> hd() |> Map.fetch!(:original_content) == "before"

    assert {:ok, untouched} = Snapshot.get_snapshot(other_id)
    assert is_nil(untouched.session_id)
  end

  test "streams bounded lightweight references newest first without rollback bodies", %{
    root: root
  } do
    session_id = "reference-session-#{System.unique_integer([:positive])}"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    large_body = String.duplicate("rollback-body", 40_000)

    transaction_ids =
      for index <- 1..3 do
        transaction_id = "reference-#{index}-#{System.unique_integer([:positive])}"

        patch = %{
          snapshot_patch(root, "reference-#{index}.txt")
          | original_content: large_body,
            new_content: large_body <> "-changed"
        }

        assert :ok =
                 Snapshot.save_snapshot(transaction_id, [patch],
                   project_root: root,
                   session_id: session_id,
                   timestamp: timestamp
                 )

        transaction_id
      end

    refs =
      session_id
      |> Snapshot.stream_session_snapshot_refs(batch_size: 1)
      |> Enum.to_list()

    assert Enum.map(refs, & &1.transaction_id) == Enum.reverse(transaction_ids)
    assert Enum.all?(refs, &(not Map.has_key?(&1, :patches)))
    assert byte_size(:erlang.term_to_binary(refs)) < 10_000
  end

  test "coordinator rolls sequential snapshots back in reverse application order", %{root: root} do
    path = Path.join(root, "lib/sequential.txt")
    session_id = "sequential-session-#{System.unique_integer([:positive])}"
    File.write!(path, "one")

    assert {:ok, first} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/sequential.txt", target: "one", replacement: "two"}],
               session_id: session_id
             )

    assert {:ok, second} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/sequential.txt", target: "two", replacement: "three"}],
               session_id: session_id
             )

    assert File.read!(path) == "three"

    state = %SwarmCoordinator.State{session_id: session_id, project_root: root}
    assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(root, state)
    assert File.read!(path) == "one"
    assert {:error, :not_found} = Snapshot.get_snapshot(first.transaction_id)
    assert {:error, :not_found} = Snapshot.get_snapshot(second.transaction_id)
  end

  test "run and legacy session cleanup preserve unrelated manifests", %{root: root} do
    {:ok, project} = Projects.create_project(%{name: "Cleanup scope", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Cleanup"})
    {:ok, other_session} = Sessions.create_session(%{project_id: project.id, title: "Other"})

    {:ok, first_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "First cleanup run"
      })

    {:ok, second_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Second cleanup run"
      })

    first_run_id = "run-one-#{System.unique_integer([:positive])}"
    second_run_id = "run-two-#{System.unique_integer([:positive])}"
    interactive_id = "interactive-#{System.unique_integer([:positive])}"
    unrelated_id = "unrelated-#{System.unique_integer([:positive])}"

    assert :ok =
             Snapshot.save_snapshot(first_run_id, [snapshot_patch(root, "run-one.txt")],
               project_root: root,
               session_id: session.id,
               run_id: first_run.id
             )

    assert :ok =
             Snapshot.save_snapshot(second_run_id, [snapshot_patch(root, "run-two.txt")],
               project_root: root,
               session_id: session.id,
               run_id: second_run.id
             )

    assert :ok =
             Snapshot.save_snapshot(interactive_id, [snapshot_patch(root, "interactive.txt")],
               project_root: root,
               session_id: session.id
             )

    assert :ok =
             Snapshot.save_snapshot(unrelated_id, [snapshot_patch(root, "unrelated.txt")],
               project_root: root,
               session_id: other_session.id
             )

    assert :ok = Snapshot.delete_run_snapshots(first_run.id)
    assert {:error, :not_found} = Snapshot.get_snapshot(first_run_id)
    assert {:ok, _} = Snapshot.get_snapshot(second_run_id)
    assert {:ok, _} = Snapshot.get_snapshot(interactive_id)
    assert {:ok, _} = Snapshot.get_snapshot(unrelated_id)

    assert :ok = Snapshot.delete_session_snapshots(session.id)
    assert {:error, :not_found} = Snapshot.get_snapshot(interactive_id)
    assert {:ok, _} = Snapshot.get_snapshot(second_run_id)
    assert {:ok, _} = Snapshot.get_snapshot(unrelated_id)
    assert [] == :ets.tab2list(Snapshot.table_name())
  end

  test "successful commit cleans only its snapshot scope", %{root: root} do
    {:ok, project} = Projects.create_project(%{name: "Commit cleanup", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Commit cleanup"})

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Commit cleanup run"
      })

    run_tx = "committed-run-#{System.unique_integer([:positive])}"
    interactive_tx = "committed-session-#{System.unique_integer([:positive])}"

    assert :ok =
             Snapshot.save_snapshot(run_tx, [snapshot_patch(root, "run.txt")],
               project_root: root,
               session_id: session.id,
               run_id: run.id
             )

    assert :ok =
             Snapshot.save_snapshot(interactive_tx, [snapshot_patch(root, "interactive.txt")],
               project_root: root,
               session_id: session.id
             )

    init_git_repo!(root)
    File.write!(Path.join(root, "committed.txt"), "committed")

    assert {:ok, :committed} =
             SwarmCoordinator.perform_commit(root,
               run_id: run.id,
               session_id: session.id,
               message: "test: commit run scope"
             )

    assert {:error, :not_found} = Snapshot.get_snapshot(run_tx)
    assert {:ok, _} = Snapshot.get_snapshot(interactive_tx)

    assert {:ok, :committed} =
             SwarmCoordinator.perform_commit(root,
               session_id: session.id,
               message: "test: commit interactive scope"
             )

    assert {:error, :not_found} = Snapshot.get_snapshot(interactive_tx)
  end

  test "failed commit retains rollback manifests", %{root: root} do
    transaction_id = "failed-commit-#{System.unique_integer([:positive])}"
    session_id = "failed-commit-session"

    assert :ok =
             Snapshot.save_snapshot(transaction_id, [snapshot_patch(root, "retained.txt")],
               project_root: root,
               session_id: session_id
             )

    init_git_repo!(root)
    File.write!(Path.join(root, "blocked.txt"), "must remain recoverable")
    hook = Path.join(root, ".git/hooks/pre-commit")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert {:error, _reason} =
             SwarmCoordinator.perform_commit(root,
               session_id: session_id,
               message: "test: this commit must fail"
             )

    assert {:ok, retained} = Snapshot.get_snapshot(transaction_id)
    assert retained.session_id == session_id
  end

  test "snapshot persistence fails closed before populating the hot cache", %{root: root} do
    path = Path.join(root, "lib/fail_closed.ex")
    File.write!(path, "before")
    transaction_id = String.duplicate("x", 201)

    patch = %{
      path: "lib/fail_closed.ex",
      full_path: path,
      file_existed?: true,
      original_content: "before",
      new_content: "after"
    }

    assert {:error, %Ecto.Changeset{}} =
             Snapshot.save_snapshot(transaction_id, [patch], project_root: root)

    assert [] = :ets.lookup(Snapshot.table_name(), transaction_id)
    assert File.read!(path) == "before"
  end

  test "rollback re-authorizes durable paths against their workspace", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside_#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "after")
    on_exit(fn -> File.rm(outside) end)
    transaction_id = "tampered-#{System.unique_integer([:positive])}"

    patch = %{
      path: outside,
      full_path: outside,
      file_existed?: true,
      original_content: "before",
      new_content: "after"
    }

    assert :ok = Snapshot.save_snapshot(transaction_id, [patch], project_root: root)
    assert {:error, {:partial, %{failed_files: [^outside]}}} = MultiPatch.rollback(transaction_id)
    assert File.read!(outside) == "after"
    Snapshot.delete_snapshot(transaction_id)
  end

  test "durable run ownership isolates rollback within one legacy session", %{root: root} do
    {:ok, project} = Projects.create_project(%{name: "Snapshot scope", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Shared session"})

    {:ok, first_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "First durable mutation"
      })

    {:ok, second_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Second durable mutation"
      })

    first = Path.join(root, "lib/first.txt")
    second = Path.join(root, "lib/second.txt")
    interactive = Path.join(root, "lib/interactive.txt")
    File.write!(first, "first-before")
    File.write!(second, "second-before")
    File.write!(interactive, "interactive-before")

    assert {:ok, first_summary} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/first.txt", target: "first-before", replacement: "first-after"}],
               session_id: session.id,
               run_id: first_run.id
             )

    assert {:ok, second_summary} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/second.txt", target: "second-before", replacement: "second-after"}],
               session_id: session.id,
               run_id: second_run.id
             )

    assert {:ok, interactive_summary} =
             MultiPatch.apply_patches(
               root,
               [
                 %{
                   path: "lib/interactive.txt",
                   target: "interactive-before",
                   replacement: "interactive-after"
                 }
               ],
               session_id: session.id
             )

    assert [owned] = Snapshot.list_run_snapshots(first_run.id)
    assert owned.transaction_id == first_summary.transaction_id
    assert [legacy] = Snapshot.list_snapshots(session.id)
    assert legacy.transaction_id == interactive_summary.transaction_id

    state = %SwarmCoordinator.State{session_id: session.id, run_id: first_run.id}
    assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(root, state)
    assert File.read!(first) == "first-before"
    assert File.read!(second) == "second-after"
    assert File.read!(interactive) == "interactive-after"

    assert {:ok, _} = MultiPatch.rollback(second_summary.transaction_id)
    assert {:ok, _} = MultiPatch.rollback(interactive_summary.transaction_id)
  end

  defp snapshot_patch(root, relative_path) do
    %{
      path: relative_path,
      full_path: Path.join(root, relative_path),
      file_existed?: true,
      original_content: "before",
      new_content: "after"
    }
  end

  defp init_git_repo!(root) do
    {_output, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    :ok
  end
end
