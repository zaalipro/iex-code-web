defmodule IexCode.Engine.AdversarialStressTest do
  @moduledoc """
  Adversarial Stress Test Suite for Milestone 2:
  Features F2 (OTP Subagent Process Tree) and F3 (Process Crash Monitoring).
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.{Projects, Sessions, Repo}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager}
  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Sessions.Operation
  import Ecto.Query

  setup do
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{name: "Stress Test Proj", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Stress Test Session"})

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  describe "Feature F2: Concurrency & Stress on AgentSupervisor & AgentRegistry" do
    test "concurrently spawns subagents across 20 distinct sessions without deadlock", %{
      project: project
    } do
      session_ids =
        for i <- 1..20 do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Concurrent Session #{i}"
            })

          s.id
        end

      # Concurrently spawn 4 agent types for all 20 sessions (80 GenServers total)
      agent_types = [:planner, :explorer, :coder, :verifier]

      tasks =
        for sid <- session_ids, type <- agent_types do
          Task.async(fn ->
            {:ok, pid} = AgentSupervisor.start_agent(sid, type)
            assert is_pid(pid) and Process.alive?(pid)
            assert AgentSupervisor.find_agent(sid, type) == pid
            assert AgentRegistry.whereis(sid, type) == pid
            {sid, type, pid}
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 80

      # Verify all 20 sessions have exactly 4 active subagents
      for sid <- session_ids do
        active_agents = AgentRegistry.list_agents(sid)
        assert length(active_agents) == 4
      end

      # Concurrently stop all agents across all sessions
      stop_tasks =
        for sid <- session_ids do
          Task.async(fn ->
            AgentSupervisor.stop_all_agents(sid)
          end)
        end

      Task.await_many(stop_tasks, 15_000)

      # Verify all registries are empty
      for sid <- session_ids do
        assert AgentRegistry.list_agents(sid) == []
      end
    end

    test "races 30 concurrent start_agent calls for the SAME session and agent type", %{
      session: session
    } do
      sid = session.id

      # 30 tasks racing to start the same planner agent
      results =
        1..30
        |> Enum.map(fn _ ->
          Task.async(fn ->
            AgentSupervisor.start_agent(sid, :planner)
          end)
        end)
        |> Task.await_many(10_000)

      # All 30 callers must receive {:ok, pid} with the exact same pid
      pids =
        Enum.map(results, fn
          {:ok, pid} -> pid
          other -> flunk("Expected {:ok, pid}, got: #{inspect(other)}")
        end)

      unique_pids = Enum.uniq(pids)
      assert length(unique_pids) == 1
      running_pid = hd(unique_pids)
      assert Process.alive?(running_pid)

      # Clean up
      AgentSupervisor.stop_agent(sid, :planner)
      refute Process.alive?(running_pid)
    end

    test "recovers cleanly when subagent process is killed unexpectedly with :kill (OTP transient restart)",
         %{
           session: session
         } do
      sid = session.id
      {:ok, pid1} = AgentSupervisor.start_agent(sid, :coder)
      assert Process.alive?(pid1)
      assert AgentRegistry.whereis(sid, :coder) == pid1

      # Force kill the subagent GenServer
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}, 2000

      # Under OTP DynamicSupervisor with restart: :transient, abnormal termination triggers automatic restart
      # Wait briefly for supervisor to restart the child
      :timer.sleep(100)
      restarted_pid = AgentRegistry.whereis(sid, :coder)
      assert is_pid(restarted_pid)
      assert Process.alive?(restarted_pid)
      assert restarted_pid != pid1

      # Now stop the agent cleanly via supervisor
      assert :ok = AgentSupervisor.stop_agent(sid, :coder)
      refute Process.alive?(restarted_pid)
      assert AgentRegistry.whereis(sid, :coder) == nil
    end
  end

  describe "Feature F3: Process Crash Monitoring & Immediate Return (No Timeout Hang)" do
    test "run_sync_operation returns immediate error on unhandled exception (< 500ms)", %{
      session: session
    } do
      start_time = System.monotonic_time(:millisecond)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "CrashWorker",
          "crash_type",
          "Crashing Task",
          %{},
          fn _progress ->
            raise ArgumentError, "simulated fatal argument error"
          end,
          60_000
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      # Must return immediately, never waiting for 60s timeout
      assert elapsed < 500
      assert {:error, err_msg} = res
      assert String.contains?(err_msg, "simulated fatal argument error")

      assert_receive {:operation_failed, %Operation{status: "failed", error_message: em}}, 3000
      assert String.contains?(em, "simulated fatal argument error")
    end

    test "run_sync_operation returns immediate error on throw/catch (< 500ms)", %{
      session: session
    } do
      start_time = System.monotonic_time(:millisecond)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "ThrowWorker",
          "throw_type",
          "Throwing Task",
          %{},
          fn _progress ->
            throw(:abort_execution)
          end,
          60_000
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed < 500
      assert {:error, err_msg} = res
      assert String.contains?(err_msg, "throw") or String.contains?(err_msg, "abort_execution")
    end

    test "run_sync_operation returns immediate error on Process.exit(self(), :shutdown)", %{
      session: session
    } do
      start_time = System.monotonic_time(:millisecond)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "ShutdownWorker",
          "shutdown_type",
          "Shutdown Task",
          %{},
          fn _progress ->
            Process.exit(self(), :shutdown)
          end,
          60_000
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed < 500
      assert {:error, err_msg} = res
      assert String.contains?(err_msg, "shutdown") or String.contains?(err_msg, "shut down")
    end

    test "run_sync_operation returns immediate error when worker is killed externally with :kill",
         %{
           session: session
         } do
      test_pid = self()

      task =
        Task.async(fn ->
          start_time = System.monotonic_time(:millisecond)

          res =
            OperationManager.run_sync_operation(
              session.id,
              nil,
              "ExternalKillWorker",
              "long_task",
              "Long Task to be Killed",
              %{},
              fn progress ->
                progress.(10, "Working...")
                send(test_pid, {:worker_running, self()})
                :timer.sleep(30_000)
                {:ok, "should not finish"}
              end,
              60_000
            )

          elapsed = System.monotonic_time(:millisecond) - start_time
          {res, elapsed}
        end)

      # Receive worker pid and forcefully kill it
      assert_receive {:worker_running, worker_pid}, 3000
      Process.exit(worker_pid, :kill)

      # Await Task result
      {res, elapsed} = Task.await(task, 5000)

      # Must return within < 1000ms after kill, not 60,000ms
      assert elapsed < 2000
      assert {:error, err_msg} = res

      assert String.contains?(err_msg, "killed") or
               String.contains?(err_msg, "Process was killed")
    end

    test "run_sync_operation enforces timeout cutoff and unblocks caller", %{session: session} do
      start_time = System.monotonic_time(:millisecond)

      res =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "SlowWorker",
          "slow_task",
          "Slow Task",
          %{},
          fn _progress ->
            :timer.sleep(5_000)
            {:ok, "done"}
          end,
          150
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed >= 140 and elapsed < 1_000
      assert res == {:error, "Operation timed out after 150ms"}
    end

    test "emits :crash telemetry event and PubSub on abnormal worker death", %{session: session} do
      test_pid = self()
      handler_id = "test-crash-telemetry-#{session.id}"

      :telemetry.attach(
        handler_id,
        [:iex_code, :operation, :crash],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_crash, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "TelemetryCrashWorker",
          "crash_type",
          "Telemetry Crash Task",
          %{},
          fn _progress ->
            Process.exit(self(), :kill)
          end
        )

      assert_receive {:operation_failed, %Operation{id: op_id, status: "failed"}}, 3000
      assert op_id == op.id

      assert_receive {:telemetry_crash, [:iex_code, :operation, :crash], %{duration_ms: _},
                      %{session_id: sid, operation_id: ^op_id, reason: :killed}},
                     3000

      assert sid == session.id
    end
  end

  describe "Feature F2: Concurrent Subagent Invocation Across Sessions" do
    test "concurrently executes operations across all 4 subagent types simultaneously" do
      # Keep this concurrency test independent from the repository running the
      # test suite. Pointing five verifier agents at this project's mix.exs
      # launches five nested full compiles and can exhaust the operation's
      # otherwise-valid 60 second deadline under full-suite load. A small real
      # workspace still exercises Planner, Explorer, Coder, and Verifier
      # concurrently without benchmarking the host checkout.
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "iex-code-concurrent-agents-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)
      File.write!(Path.join(workspace_root, "sample.ex"), "defmodule ConcurrentSample do\nend\n")
      on_exit(fn -> File.rm_rf(workspace_root) end)

      {:ok, project} =
        Projects.create_project(%{
          name: "Concurrent Agent Workspace",
          root_path: workspace_root
        })

      sessions =
        for i <- 1..5 do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Subagent Session #{i}",
              model_provider: "openai",
              model_name: "gpt-4o"
            })

          {:ok, p_pid} =
            AgentSupervisor.start_agent(s.id, :planner,
              project_root: project.root_path,
              session: s,
              llm: IexCode.ConcurrentAgentLLMStub
            )

          {:ok, e_pid} =
            AgentSupervisor.start_agent(s.id, :explorer,
              project_root: project.root_path,
              session: s
            )

          {:ok, c_pid} =
            AgentSupervisor.start_agent(s.id, :coder,
              project_root: project.root_path,
              session: s,
              llm: IexCode.ConcurrentAgentLLMStub
            )

          {:ok, v_pid} =
            AgentSupervisor.start_agent(s.id, :verifier,
              project_root: project.root_path,
              session: s
            )

          for pid <- [p_pid, e_pid, c_pid, v_pid] do
            Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
          end

          s
        end

      # Concurrently invoke tasks on all 4 agent types across sessions
      tasks =
        Enum.flat_map(sessions, fn session ->
          [
            Task.async(fn ->
              PlannerAgent.plan(session.id, "Plan task for session #{session.id}",
                timeout: 120_000
              )
            end),
            Task.async(fn ->
              ExplorerAgent.explore(session.id, "Explore workspace", timeout: 120_000)
            end),
            Task.async(fn ->
              CoderAgent.code(session.id, "Code implementation", timeout: 120_000)
            end),
            Task.async(fn ->
              VerifierAgent.check_compile(session.id, timeout: 120_000)
            end)
          ]
        end)

      results = Task.await_many(tasks, 120_000)
      assert length(results) == 20

      for res <- results do
        assert {:ok, _} = res
      end

      for [planner, _explorer, coder, _verifier] <- Enum.chunk_every(results, 4) do
        assert planner == {:ok, "deterministic concurrent plan"}
        assert coder == {:ok, "deterministic concurrent implementation"}
      end

      # Clean up
      for session <- sessions do
        AgentSupervisor.stop_all_agents(session.id)
      end
    end
  end

  describe "Feature F3: Database Integrity — Zero Dangling 'running' Operations" do
    test "stress test with 30 crashing async operations guarantees zero running ops in DB", %{
      session: session
    } do
      sid = session.id

      # Spawn 30 async operations that crash in diverse ways
      for i <- 1..30 do
        crash_fn =
          case rem(i, 5) do
            0 -> fn _p -> raise "Crash #{i}" end
            1 -> fn _p -> throw("Throw #{i}") end
            2 -> fn _p -> Process.exit(self(), :kill) end
            3 -> fn _p -> exit(:shutdown) end
            4 -> fn _p -> exit({:custom_exit, i}) end
          end

        {:ok, _task_pid, _op} =
          OperationManager.run_async_operation(
            sid,
            nil,
            "CrashAgent_#{i}",
            "stress_crash",
            "Crashing Op #{i}",
            %{index: i},
            crash_fn
          )
      end

      # Wait for all crash events to settle
      :timer.sleep(1500)

      # Query DB for all operations in this session
      ops = Repo.all(from o in Operation, where: o.session_id == ^sid)
      assert length(ops) == 30

      # Assert ZERO operations remain in 'running' status
      running_ops = Enum.filter(ops, &(&1.status == "running"))
      assert running_ops == []

      # Assert ALL 30 operations have status 'failed' with error_message and completed_at
      failed_ops = Enum.filter(ops, &(&1.status == "failed"))
      assert length(failed_ops) == 30

      for op <- failed_ops do
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
        assert not is_nil(op.completed_at)
        assert not is_nil(op.duration_ms)
      end
    end
  end

  describe "Feature F3: Operation Tree Edge Cases (Deep Nesting, Orphans, Scalability)" do
    test "builds deeply nested tree of 50 sequential levels" do
      # Op0 -> Op1 -> Op2 -> ... -> Op49
      ops =
        Enum.reduce(0..49, [], fn i, acc ->
          parent_id = if i == 0, do: nil, else: "op_#{i - 1}"

          [
            %Operation{
              id: "op_#{i}",
              parent_op_id: parent_id,
              title: "Level #{i}",
              status: "completed",
              duration_ms: 10
            }
            | acc
          ]
        end)

      tree = OperationManager.build_tree(ops)
      assert length(tree) == 1

      # Traverse 50 levels
      depth =
        Stream.iterate(hd(tree), fn node ->
          case node.children do
            [child] -> child
            _ -> nil
          end
        end)
        |> Stream.take_while(&(&1 != nil))
        |> Enum.count()

      assert depth == 50

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 50
      assert stats.roots == 1
      assert stats.completed == 50
      assert stats.total_duration_ms == 500
    end

    test "handles orphaned nodes whose parent_op_id does not exist in operation list" do
      root_id = Ecto.UUID.generate()
      orphan_id_1 = Ecto.UUID.generate()
      orphan_id_2 = Ecto.UUID.generate()
      non_existent_parent = Ecto.UUID.generate()

      ops = [
        %Operation{
          id: root_id,
          parent_op_id: nil,
          title: "Legitimate Root",
          status: "completed"
        },
        %Operation{
          id: orphan_id_1,
          parent_op_id: non_existent_parent,
          title: "Orphan 1",
          status: "failed"
        },
        %Operation{
          id: orphan_id_2,
          parent_op_id: "",
          title: "Empty String Parent",
          status: "completed"
        }
      ]

      tree = OperationManager.build_tree(ops)
      # All 3 should be represented as roots without crashing or being dropped
      assert length(tree) == 3

      tree_ids = Enum.map(tree, & &1.id)
      assert root_id in tree_ids
      assert orphan_id_1 in tree_ids
      assert orphan_id_2 in tree_ids

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 3
      assert stats.roots == 3
      assert stats.completed == 2
      assert stats.failed == 1
    end

    test "efficiently processes large trees (1,000 operations across 20 roots)" do
      # 20 roots, each with 49 children
      ops =
        for root_idx <- 1..20,
            child_idx <- 0..49 do
          if child_idx == 0 do
            %Operation{
              id: "root_#{root_idx}",
              parent_op_id: nil,
              title: "Root #{root_idx}",
              status: "completed",
              duration_ms: 50
            }
          else
            %Operation{
              id: "child_#{root_idx}_#{child_idx}",
              parent_op_id: "root_#{root_idx}",
              title: "Child #{child_idx} of Root #{root_idx}",
              status: if(rem(child_idx, 5) == 0, do: "failed", else: "completed"),
              duration_ms: 10
            }
          end
        end

      assert length(ops) == 1000

      start_t = System.monotonic_time(:millisecond)
      tree = OperationManager.build_tree(ops)
      stats = OperationManager.tree_stats(ops)
      elapsed = System.monotonic_time(:millisecond) - start_t

      # Must build 1,000 node tree in under 50ms
      assert elapsed < 50
      assert length(tree) == 20
      assert stats.total == 1000
      assert stats.roots == 20

      # Each root must have 49 children
      for root <- tree do
        assert length(root.children) == 49
      end
    end

    test "handles empty operations list" do
      assert OperationManager.build_tree([]) == []
      assert OperationManager.get_children("any_id", []) == []
      assert OperationManager.get_root_operations([]) == []

      assert OperationManager.tree_stats([]) == %{
               total: 0,
               roots: 0,
               running: 0,
               completed: 0,
               failed: 0,
               total_duration_ms: 0
             }
    end
  end
end
