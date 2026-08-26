defmodule IexCode.WorkspaceLocksTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, WorkspaceLocks}

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-gateway-locks-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create_project(%{name: "Gateway Lock Test", root_path: root})
    %{project: project, root: root}
  end

  test "an opaque handle owns, asserts, heartbeats, and idempotently releases a batch", %{
    project: project
  } do
    assert {:ok, handle} =
             WorkspaceLocks.acquire(
               project,
               [{:project, :read}, {{:file, "lib/a.ex"}, :write}],
               owner_id: "gateway-test"
             )

    assert :ok = WorkspaceLocks.assert(handle)
    assert is_pid(handle.heartbeat_pid)
    assert Process.alive?(handle.heartbeat_pid)

    inspected = inspect(handle)
    refute inspected =~ handle.capability
    refute inspected =~ "capability"

    locks = Runs.list_workspace_locks(batch_id: handle.batch_id)
    assert Enum.map(locks, & &1.status) == ["held", "held"]

    assert :ok = WorkspaceLocks.release(handle)
    assert :ok = WorkspaceLocks.release(handle)
    refute Process.alive?(handle.heartbeat_pid)

    assert Enum.all?(
             Runs.list_workspace_locks(batch_id: handle.batch_id),
             &(&1.status == "released")
           )
  end

  test "with_locks asserts immediately before the callback and always releases", %{
    root: root,
    project: project
  } do
    assert :callback_result ==
             WorkspaceLocks.with_locks(
               root,
               [{{:file, "lib/a.ex"}, :write}],
               %{owner_id: "callback-owner", project_id: project.id},
               fn ->
                 assert [%{status: "held"}] =
                          Runs.list_workspace_locks(
                            project_id: project.id,
                            owner_id: "callback-owner",
                            active: true
                          )

                 :callback_result
               end
             )

    assert [] ==
             Runs.list_workspace_locks(
               project_id: project.id,
               owner_id: "callback-owner",
               active: true
             )

    assert_raise RuntimeError, "protected effect failed", fn ->
      WorkspaceLocks.with_locks(
        project,
        [:git],
        [owner_id: "raising-owner"],
        fn -> raise "protected effect failed" end
      )
    end

    assert [] ==
             Runs.list_workspace_locks(
               project_id: project.id,
               owner_id: "raising-owner",
               active: true
             )
  end

  test "a waiting batch never runs the protected callback and is cancelled", %{project: project} do
    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [{{:file, "lib/a.ex"}, :write}], owner_id: "blocker")

    assert {:error, {:workspace_lock_waiting, [%{status: "waiting"} = waiting]}} =
             WorkspaceLocks.with_locks(
               project,
               [{{:file, "lib/a.ex"}, :write}],
               [owner_id: "waiter"],
               fn -> flunk("a waiting caller must not perform its effect") end
             )

    assert Runs.get_workspace_lock!(waiting.id).status == "cancelled"
    assert :ok = WorkspaceLocks.release(blocker)
  end

  test "a scheduler may retain and promote an opaque durable FIFO waiter", %{project: project} do
    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [{{:file, "lib/a.ex"}, :write}], owner_id: "blocker")

    assert {:waiting, waiter} =
             WorkspaceLocks.acquire_or_wait(
               project,
               [{{:file, "lib/a.ex"}, :write}],
               owner_id: "durable-waiter"
             )

    waiting_id = WorkspaceLocks.handle_id(waiter)
    assert Runs.get_workspace_lock!(waiting_id).status == "waiting"
    assert {:waiting, same_waiter} = WorkspaceLocks.retry(waiter)
    assert WorkspaceLocks.handle_id(same_waiter) == waiting_id

    assert :ok = WorkspaceLocks.release(blocker)
    assert {:ok, promoted} = WorkspaceLocks.retry(same_waiter)
    assert WorkspaceLocks.handle_id(promoted) == waiting_id
    assert :ok = WorkspaceLocks.assert(promoted)
    assert :ok = WorkspaceLocks.release(promoted)
  end

  test "a covered nested effect borrows the same owner's capability", %{project: project} do
    identity = [owner_id: "run:borrow-test", project_id: project.id]
    assert {:ok, outer} = WorkspaceLocks.acquire(project, [:project], identity)

    assert {:error, denied_reason} =
             WorkspaceLocks.with_locks(
               project,
               [{{:file, "lib/a.ex"}, :write}],
               identity,
               fn -> flunk("metadata alone must never borrow a capability") end
             )

    assert denied_reason in [:invalid_capability, :lock_upgrade_not_supported]

    assert {:ok, delegation} = WorkspaceLocks.delegate(outer)
    delegated_identity = Keyword.put(identity, :delegation, delegation)

    assert {:error, :unsupported} =
             GenServer.call(WorkspaceLocks, {:lookup, delegation.registry_key})

    registry_table = :sys.get_state(WorkspaceLocks)

    assert_raise ArgumentError, fn ->
      :ets.tab2list(registry_table)
    end

    refute inspect(delegation) =~ outer.capability

    assert :borrowed_effect ==
             WorkspaceLocks.with_locks(
               project,
               [{{:file, "lib/a.ex"}, :write}],
               delegated_identity,
               fn -> :borrowed_effect end
             )

    assert :ok = WorkspaceLocks.assert(outer)

    assert [%{id: outer_id, status: "held"}] =
             Runs.list_workspace_locks(project_id: project.id, active: true)

    assert outer_id == WorkspaceLocks.handle_id(outer)
    assert :ok = WorkspaceLocks.release(outer)
  end

  test "unregistered roots fail closed unless unmanaged operation is explicitly allowed" do
    unmanaged =
      Path.join(System.tmp_dir!(), "iex-code-unmanaged-#{System.unique_integer([:positive])}")

    File.mkdir_p!(unmanaged)

    assert {:error, :unmanaged_workspace} =
             WorkspaceLocks.with_locks(
               unmanaged,
               [:project],
               [owner_id: "unmanaged"],
               fn -> :should_not_run end
             )

    assert :ran_unmanaged ==
             WorkspaceLocks.with_locks(
               unmanaged,
               [:project],
               [owner_id: "unmanaged", allow_unmanaged: true],
               fn -> :ran_unmanaged end
             )
  end

  test "allow_unmanaged never bypasses locking for a registered root", %{
    root: root,
    project: project
  } do
    assert :managed_effect ==
             WorkspaceLocks.with_locks(
               root,
               [:project],
               [owner_id: "registered-root", allow_unmanaged: true],
               fn ->
                 assert [%{status: "held"}] =
                          Runs.list_workspace_locks(
                            project_id: project.id,
                            owner_id: "registered-root",
                            active: true
                          )

                 :managed_effect
               end
             )
  end

  test "with_locks installs delegation for nested covered effects", %{project: project} do
    identity = [owner_id: "nested-callback", project_id: project.id]

    assert :nested_effect ==
             WorkspaceLocks.with_locks(project, [:project], identity, fn ->
               assert %WorkspaceLocks{} = WorkspaceLocks.current_delegation()

               WorkspaceLocks.with_locks(
                 project,
                 [{{:file, "lib/a.ex"}, :write}],
                 Keyword.put(identity, :delegation, WorkspaceLocks.current_delegation()),
                 fn -> :nested_effect end
               )
             end)

    assert is_nil(WorkspaceLocks.current_delegation())
  end

  test "a supplied project id must identify the registered root", %{project: project} do
    other_root =
      Path.join(System.tmp_dir!(), "iex-code-other-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(other_root)

    assert {:error, :project_path_mismatch} =
             WorkspaceLocks.acquire(other_root, [:project],
               owner_id: "mismatch",
               project_id: project.id,
               allow_unmanaged: true
             )
  end
end
