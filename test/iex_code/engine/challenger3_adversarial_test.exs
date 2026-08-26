defmodule IexCode.Engine.Challenger3AdversarialTest do
  @moduledoc """
  Adversarial Challenge Suite 3 for Milestone 2:
  Empirical stress verification for Feature F2 (OTP Subagent Process Tree)
  and Feature F3 (Process Crash Monitoring).
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000
  alias IexCode.{Projects, Sessions, Repo}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager}
  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Sessions.Operation
  import Ecto.Query

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "Challenger 3 Proj", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Challenger 3 Session"})

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # Feature F2: Subagent Supervision Tree Concurrency & Lifecycle Storm
  # ============================================================================
  describe "Feature F2: Concurrency & Lifecycle Storm" do
    test "burst spawns and terminates 120 subagents across 30 sessions under heavy concurrency",
         %{project: project} do
      session_ids =
        for i <- 1..30 do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Storm Session #{i}"
            })

          s.id
        end

      agent_types = [:planner, :explorer, :coder, :verifier]

      # Spawn 120 subagents concurrently
      spawn_tasks =
        for sid <- session_ids, type <- agent_types do
          Task.async(fn ->
            {:ok, pid} = AgentSupervisor.start_agent(sid, type)
            assert is_pid(pid) and Process.alive?(pid)
            assert AgentSupervisor.find_agent(sid, type) == pid
            assert AgentRegistry.whereis(sid, type) == pid
            {sid, type, pid}
          end)
        end

      spawned = Task.await_many(spawn_tasks, 20_000)
      assert length(spawned) == 120

      # Verify all 30 sessions have exactly 4 active subagents
      for sid <- session_ids do
        active = AgentRegistry.list_agents(sid)
        assert length(active) == 4
      end

      # Concurrently stop individual agents and stop_all_agents across sessions
      stop_tasks =
        Enum.map(session_ids, fn sid ->
          Task.async(fn ->
            # Stop one specifically, then stop_all for the rest
            AgentSupervisor.stop_agent(sid, :planner)
            assert AgentSupervisor.find_agent(sid, :planner) == nil
            assert length(AgentRegistry.list_agents(sid)) == 3

            AgentSupervisor.stop_all_agents(sid)
            assert AgentRegistry.list_agents(sid) == []
          end)
        end)

      Task.await_many(stop_tasks, 20_000)

      # Final verification: zero active agents remain
      for sid <- session_ids do
        assert AgentRegistry.list_agents(sid) == []
      end
    end

    test "races 40 concurrent start_agent and stop_agent calls on the same session without crash or corruption",
         %{session: session} do
      sid = session.id

      # 40 workers randomly racing start and stop on the same agent
      tasks =
        for i <- 1..40 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              AgentSupervisor.start_agent(sid, :coder)
            else
              AgentSupervisor.stop_agent(sid, :coder)
            end
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 40

      # Clean up and verify final clean state
      AgentSupervisor.stop_all_agents(sid)
      assert AgentRegistry.list_agents(sid) == []
    end

    test "handles large payload (1MB string) across subagents without memory exhaustion or crash",
         %{session: session, project: project} do
      sid = session.id

      {:ok, planner_pid} =
        AgentSupervisor.start_agent(sid, :planner, project_root: project.root_path)

      {:ok, explorer_pid} =
        AgentSupervisor.start_agent(sid, :explorer, project_root: project.root_path)

      {:ok, coder_pid} =
        AgentSupervisor.start_agent(sid, :coder, project_root: project.root_path)

      {:ok, verifier_pid} =
        AgentSupervisor.start_agent(sid, :verifier, project_root: project.root_path)

      for pid <- [planner_pid, explorer_pid, coder_pid, verifier_pid] do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
      end

      huge_goal = String.duplicate("Refactor modular architecture. ", 35_000)
      assert byte_size(huge_goal) > 1_000_000

      assert {:ok, plan_text} = PlannerAgent.plan(sid, huge_goal, timeout: 60_000)
      assert is_binary(plan_text) and byte_size(plan_text) > 0

      assert {:ok, exp_res} = ExplorerAgent.explore(sid, huge_goal, timeout: 60_000)
      assert is_binary(exp_res) or is_map(exp_res)

      # CoderAgent handles large payloads safely
      code_res = CoderAgent.code(sid, huge_goal, timeout: 60_000)
      assert match?({:ok, _}, code_res) or match?({:error, _}, code_res)

      assert {:ok, verif_res} = VerifierAgent.check_compile(sid, timeout: 60_000)
      assert is_map(verif_res) or is_binary(verif_res) or is_struct(verif_res)

      AgentSupervisor.stop_all_agents(sid)
    end
  end

  # ============================================================================
  # Feature F3: Immediate Unblocking Latency (< 500ms) on Crashes & Exceptions
  # ============================================================================
  describe "Feature F3: Crash Unblocking Latency Benchmark (< 500ms)" do
    test "benchmark: unblocks in < 500ms across 10 distinct crash and exit vectors", %{
      session: session
    } do
      sid = session.id

      crash_scenarios = [
        {"RuntimeError", fn _p -> raise RuntimeError, "boom" end},
        {"ArgumentError", fn _p -> raise ArgumentError, "bad arg" end},
        {"KeyError", fn _p -> raise KeyError, key: :non_existent, term: %{} end},
        {"Atom Throw", fn _p -> throw(:abort) end},
        {"Tuple Throw", fn _p -> throw({:fatal, "error_payload", 123}) end},
        {"Normal Exit", fn _p -> exit(:normal) end},
        {"Shutdown Exit", fn _p -> exit(:shutdown) end},
        {"Shutdown Reason Exit", fn _p -> exit({:shutdown, :user_requested}) end},
        {"Custom Exit Reason", fn _p -> exit({:worker_oom, 999}) end},
        {"Killed Signal", fn _p -> Process.exit(self(), :kill) end}
      ]

      for {name, crash_fun} <- crash_scenarios do
        start_t = System.monotonic_time(:millisecond)

        result =
          OperationManager.run_sync_operation(
            sid,
            nil,
            "BenchWorker_#{name}",
            "benchmark_crash",
            "Benchmarking #{name}",
            %{},
            crash_fun,
            60_000
          )

        elapsed = System.monotonic_time(:millisecond) - start_t

        # CRITICAL ASSERTION: Must return immediately under 500ms, never hanging on 60s timeout
        assert elapsed < 500,
               "Scenario #{name} took #{elapsed}ms (expected < 500ms)"

        assert {:error, err_msg} = result
        assert is_binary(err_msg) and byte_size(err_msg) > 0
      end
    end
  end

  # ============================================================================
  # Feature F3: Database Integrity — Zero Dangling 'running' Operations
  # ============================================================================
  describe "Feature F3: Database Integrity Under Massive Crash Concurrency" do
    test "stress: 50 concurrent crashing operations across 5 sessions result in ZERO dangling running ops",
         %{project: project} do
      session_ids =
        for i <- 1..5 do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "DB Integrity Session #{i}"
            })

          s.id
        end

      # Launch 50 crashing async operations concurrently
      tasks =
        for i <- 1..50 do
          sid = Enum.at(session_ids, rem(i, 5))

          crash_fn =
            case rem(i, 5) do
              0 -> fn _p -> raise "Crash #{i}" end
              1 -> fn _p -> throw({:throw, i}) end
              2 -> fn _p -> Process.exit(self(), :kill) end
              3 -> fn _p -> exit(:shutdown) end
              4 -> fn _p -> exit({:bad_state, i}) end
            end

          Task.async(fn ->
            OperationManager.run_async_operation(
              sid,
              nil,
              "CrashWorker_#{i}",
              "mass_crash",
              "Crashing Task #{i}",
              %{task_index: i},
              crash_fn
            )
          end)
        end

      launch_results = Task.await_many(tasks, 15_000)
      assert length(launch_results) == 50

      for res <- launch_results do
        assert {:ok, _pid, %Operation{}} = res
      end

      # Allow crash watcher tasks to settle and persist failure states
      :timer.sleep(2000)

      # Query DB across all 5 sessions
      all_ops = Repo.all(from o in Operation, where: o.session_id in ^session_ids)
      assert length(all_ops) == 50

      # EMPIRICAL VALIDATION: ZERO running operations
      running_count = Enum.count(all_ops, &(&1.status == "running"))
      assert running_count == 0, "Found #{running_count} dangling 'running' operations in DB!"

      # EMPIRICAL VALIDATION: ALL 50 operations are failed with duration, completed_at, and error_message
      failed_ops = Enum.filter(all_ops, &(&1.status == "failed"))
      assert length(failed_ops) == 50

      for op <- failed_ops do
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
        assert not is_nil(op.completed_at)
        assert is_integer(op.duration_ms) and op.duration_ms >= 0
      end
    end
  end

  # ============================================================================
  # Feature F3: Operation Tree Deep Nesting, Massive Scale, Orphans, & Stats
  # ============================================================================
  describe "Feature F3: Operation Tree Hierarchy Stress & Edge Cases" do
    test "builds deeply nested tree of 200 sequential levels" do
      ops =
        Enum.reduce(0..199, [], fn i, acc ->
          parent_id = if i == 0, do: nil, else: "node_#{i - 1}"

          [
            %Operation{
              id: "node_#{i}",
              parent_op_id: parent_id,
              title: "Depth #{i}",
              status: "completed",
              duration_ms: 5
            }
            | acc
          ]
        end)

      start_t = System.monotonic_time(:millisecond)
      tree = OperationManager.build_tree(ops)
      elapsed = System.monotonic_time(:millisecond) - start_t

      assert elapsed < 50
      assert length(tree) == 1

      # Traverse down 200 levels
      depth =
        Stream.iterate(hd(tree), fn node ->
          case node.children do
            [child] -> child
            _ -> nil
          end
        end)
        |> Stream.take_while(&(&1 != nil))
        |> Enum.count()

      assert depth == 200

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 200
      assert stats.roots == 1
      assert stats.completed == 200
      assert stats.failed == 0
      assert stats.running == 0
      assert stats.total_duration_ms == 1000
    end

    test "handles massive hybrid tree (5,000 nodes across 50 roots) in < 100ms" do
      # 50 roots, each with 19 children, each child with 4 grandchildren = 50 * (1 + 19 + 76) = 4800 ops
      ops =
        for root_i <- 1..50 do
          root_id = "r_#{root_i}"

          root_op = %Operation{
            id: root_id,
            parent_op_id: nil,
            title: "Root #{root_i}",
            status: "completed",
            duration_ms: 20
          }

          children =
            for child_i <- 1..19 do
              child_id = "c_#{root_i}_#{child_i}"

              child_op = %Operation{
                id: child_id,
                parent_op_id: root_id,
                title: "Child #{child_i}",
                status: "completed",
                duration_ms: 10
              }

              grandchildren =
                for g_i <- 1..4 do
                  %Operation{
                    id: "g_#{root_i}_#{child_i}_#{g_i}",
                    parent_op_id: child_id,
                    title: "Grandchild #{g_i}",
                    status: if(rem(g_i, 2) == 0, do: "failed", else: "completed"),
                    duration_ms: 5
                  }
                end

              [child_op | grandchildren]
            end

          [root_op | List.flatten(children)]
        end
        |> List.flatten()

      assert length(ops) == 4800

      start_t = System.monotonic_time(:millisecond)
      tree = OperationManager.build_tree(ops)
      stats = OperationManager.tree_stats(ops)
      elapsed = System.monotonic_time(:millisecond) - start_t

      # Must build 4,800 node tree in under 100ms
      assert elapsed < 100
      assert length(tree) == 50
      assert stats.total == 4800
      assert stats.roots == 50

      for root <- tree do
        assert length(root.children) == 19

        for child <- root.children do
          assert length(child.children) == 4
        end
      end
    end

    test "handles diverse orphaned and irregular parent_op_id values safely" do
      ops = [
        %Operation{
          id: "r1",
          parent_op_id: nil,
          title: "Legitimate Nil Root",
          status: "completed"
        },
        %Operation{
          id: "r2",
          parent_op_id: "",
          title: "Empty String Root",
          status: "completed"
        },
        %Operation{
          id: "o1",
          parent_op_id: "non_existent_uuid_123",
          title: "Orphan Missing Parent",
          status: "failed"
        },
        %Operation{
          id: "o2",
          parent_op_id: "o2",
          title: "Self Referencing Node",
          status: "failed"
        },
        %Operation{
          id: "c1",
          parent_op_id: "r1",
          title: "Child of R1",
          status: "completed"
        }
      ]

      tree = OperationManager.build_tree(ops)
      root_ids = Enum.map(tree, & &1.id)

      # r1, r2, o1 must all be roots. o2 has parent_op_id "o2" which is in all_ids, so it's not a root
      assert "r1" in root_ids
      assert "r2" in root_ids
      assert "o1" in root_ids

      r1_node = Enum.find(tree, &(&1.id == "r1"))
      assert length(r1_node.children) == 1
      assert hd(r1_node.children).id == "c1"

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 5
      assert stats.completed == 3
      assert stats.failed == 2
    end
  end
end
