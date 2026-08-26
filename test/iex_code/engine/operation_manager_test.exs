defmodule IexCode.Engine.OperationManagerTest do
  use IexCode.DataCase, async: false
  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.OperationManager
  alias IexCode.Sessions.Operation

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "OpMgr Test Project", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "OpMgr Test Session"})

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  describe "Sync and Async Operation Execution with Crash Monitoring" do
    test "runs synchronous operation and completes with telemetry", %{session: session} do
      # Attach telemetry handler to assert telemetry event
      test_pid = self()
      handler_id = "test-telemetry-stop-#{session.id}"

      :telemetry.attach(
        handler_id,
        [:iex_code, :operation, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "SyncAgent",
          "compute",
          "Compute 2+2",
          %{},
          fn progress ->
            progress.(50, "Computing...")
            {:ok, 4}
          end
        )

      assert res == {:ok, 4}
      assert_receive {:operation_completed, %Operation{status: "completed", progress: 100}}, 5000

      assert_receive {:telemetry_event, [:iex_code, :operation, :stop], %{duration_ms: _},
                      %{session_id: session_id}},
                     5000

      assert session_id == session.id
    end

    test "catches exception in sync operation immediately without timeout", %{session: session} do
      start_time = System.monotonic_time(:millisecond)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "CrashingAgent",
          "fail_task",
          "Exploding Task",
          %{},
          fn _progress ->
            raise RuntimeError, "kaboom!"
          end,
          10_000
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed < 5_000
      assert {:error, err_msg} = res
      assert String.contains?(err_msg, "kaboom!")
      assert_receive {:operation_failed, %Operation{status: "failed", error_message: em}}, 5000
      assert String.contains?(em, "kaboom!")
    end

    test "catches process exit(:killed) in async task via crash watcher", %{session: session} do
      {:ok, task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "KilledAgent",
          "kill_task",
          "Killed Task",
          %{},
          fn _progress ->
            :timer.sleep(50)
            Process.exit(self(), :kill)
          end
        )

      assert is_pid(task_pid)
      assert_receive {:operation_started, _started_op}, 5000
      assert_receive {:operation_failed, failed_op}, 5000
      assert failed_op.id == op.id
      assert failed_op.status == "failed"
      assert String.contains?(failed_op.error_message, "killed")
    end
  end

  describe "Operation Tree Hierarchy & Stats" do
    test "builds hierarchical tree from parent-child operations" do
      root_id = Ecto.UUID.generate()
      child1_id = Ecto.UUID.generate()
      child2_id = Ecto.UUID.generate()
      grandchild_id = Ecto.UUID.generate()

      operations = [
        %Operation{
          id: root_id,
          parent_op_id: nil,
          title: "Root Swarm",
          status: "completed",
          duration_ms: 100
        },
        %Operation{
          id: child1_id,
          parent_op_id: root_id,
          title: "Planner Task",
          status: "completed",
          duration_ms: 40
        },
        %Operation{
          id: child2_id,
          parent_op_id: root_id,
          title: "Coder Task",
          status: "running",
          duration_ms: 60
        },
        %Operation{
          id: grandchild_id,
          parent_op_id: child2_id,
          title: "Patch File",
          status: "completed",
          duration_ms: 20
        }
      ]

      tree = OperationManager.build_tree(operations)
      assert length(tree) == 1

      root = hd(tree)
      assert root.id == root_id
      assert length(root.children) == 2

      child2 = Enum.find(root.children, &(&1.id == child2_id))
      assert length(child2.children) == 1
      assert hd(child2.children).id == grandchild_id

      # Get children
      assert length(OperationManager.get_children(root_id, operations)) == 2
      assert length(OperationManager.get_children(child2_id, operations)) == 1

      # Get roots
      roots = OperationManager.get_root_operations(operations)
      assert length(roots) == 1
      assert hd(roots).id == root_id

      # Tree Stats
      stats = OperationManager.tree_stats(operations)
      assert stats.total == 4
      assert stats.roots == 1
      assert stats.running == 1
      assert stats.completed == 3
      assert stats.failed == 0
      assert stats.total_duration_ms == 220
    end
  end

  describe "format_crash_reason/1" do
    test "formats various crash terms into clean strings" do
      assert OperationManager.format_crash_reason(:normal) == "Process exited normally"
      assert OperationManager.format_crash_reason(:killed) == "Process was killed (:killed)"

      assert OperationManager.format_crash_reason(:noproc) ==
               "Process does not exist or died before monitor"

      assert OperationManager.format_crash_reason(%RuntimeError{message: "custom err"}) ==
               "custom err"

      assert OperationManager.format_crash_reason({:shutdown, :timeout}) ==
               "Process shut down: timeout"

      assert is_binary(OperationManager.format_crash_reason({:badarith, []}))
    end
  end
end
