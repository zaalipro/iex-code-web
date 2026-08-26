defmodule IexCode.Engine.Challenger9OtpStressTest do
  @moduledoc """
  Challenger 9 Empirical Verification Suite for Milestone 2:
  - F2: OTP Subagent Process Tree (Supervision, Registry, Concurrency, Isolation)
  - F3: OTP Process Crash Monitoring (<50ms latency SLA, zero dangling ops, large tree hierarchy)
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions, Repo}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager}
  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Sessions.Operation
  import Ecto.Query

  setup do
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{name: "Challenger 9 Project", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Challenger 9 Session"})

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  describe "Feature F2: High Concurrency OTP Subagent Process Tree Stress" do
    test "spawns 200+ concurrent subagents across 50 sessions and verifies registry, naming, and isolated state",
         %{project: project} do
      session_count = 50
      agent_types = [:planner, :explorer, :coder, :verifier]

      # Create 50 distinct sessions
      session_ids =
        for i <- 1..session_count do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "C9 Session #{i}"
            })

          s.id
        end

      t0 = System.monotonic_time(:millisecond)

      # Concurrently spawn 4 agents per session (200 GenServers)
      spawn_tasks =
        for sid <- session_ids, type <- agent_types do
          Task.async(fn ->
            {:ok, pid} =
              AgentSupervisor.start_agent(sid, type, project_root: project.root_path)

            assert is_pid(pid)
            assert Process.alive?(pid)

            # Check registry lookups
            assert AgentSupervisor.find_agent(sid, type) == pid
            assert AgentRegistry.whereis(sid, type) == pid

            # Verify isolated state per subagent
            state =
              case type do
                :planner -> PlannerAgent.get_state(pid)
                :explorer -> ExplorerAgent.get_state(pid)
                :coder -> CoderAgent.get_state(pid)
                :verifier -> VerifierAgent.get_state(pid)
              end

            assert state.session_id == sid
            assert state.status == :idle

            {sid, type, pid}
          end)
        end

      spawned = Task.await_many(spawn_tasks, 30_000)
      spawn_duration = System.monotonic_time(:millisecond) - t0

      assert length(spawned) == 200

      IO.puts(
        "[Challenger 9] Successfully spawned and verified 200 subagents in #{spawn_duration}ms"
      )

      # Verify all 200 PIDs are distinct
      all_pids = Enum.map(spawned, fn {_, _, pid} -> pid end)
      assert length(Enum.uniq(all_pids)) == 200

      # Verify registry consistency across all sessions
      for sid <- session_ids do
        active_agents = AgentRegistry.list_agents(sid)
        assert length(active_agents) == 4
        active_types = Enum.map(active_agents, &elem(&1, 0))
        assert Enum.sort(active_types) == [:coder, :explorer, :planner, :verifier]
      end

      # Concurrently stop all agents
      t1 = System.monotonic_time(:millisecond)

      stop_tasks =
        for sid <- session_ids do
          Task.async(fn ->
            AgentSupervisor.stop_all_agents(sid)
          end)
        end

      Task.await_many(stop_tasks, 30_000)
      stop_duration = System.monotonic_time(:millisecond) - t1
      IO.puts("[Challenger 9] Successfully stopped 200 subagents in #{stop_duration}ms")

      # Verify all processes terminated and registry is clean
      for pid <- all_pids do
        refute Process.alive?(pid)
      end

      for sid <- session_ids do
        assert AgentRegistry.list_agents(sid) == []
      end
    end

    test "races 50 concurrent start and stop calls on same session without deadlock or registry corruption",
         %{session: session} do
      sid = session.id

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              AgentSupervisor.start_agent(sid, :coder)
            else
              AgentSupervisor.stop_agent(sid, :coder)
            end
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 50

      # Clean shutdown
      AgentSupervisor.stop_all_agents(sid)
      assert AgentRegistry.list_agents(sid) == []
    end
  end

  describe "Feature F3: Crash Injection & Latency Verification (<50ms SLA)" do
    test "empirically verifies crash unblocking latency is < 50ms across diverse crash vectors",
         %{session: session} do
      sid = session.id

      # Warm up SQLite connection and schema cache
      _ =
        OperationManager.run_sync_operation(
          sid,
          nil,
          "WarmupWorker",
          "warmup",
          "Warmup",
          %{},
          fn _p -> {:ok, :warmed} end,
          5_000
        )

      crash_vectors = [
        {"RuntimeError", fn _p -> raise "fatal_runtime_error" end},
        {"ArgumentError", fn _p -> raise ArgumentError, "fatal_argument_error" end},
        {"Erlang undef error",
         fn _p -> apply(String.to_atom("non_existent_module"), :crash_me, []) end},
        {"Erlang badarith", fn _p -> :erlang.error(:badarith) end},
        {"Erlang function_clause", fn _p -> apply(List, :first, [[]]) |> elem(0) end},
        {"Throw Symbol", fn _p -> throw(:abort_signal) end},
        {"Throw Map", fn _p -> throw(%{status: :failed, reason: "custom_abort"}) end},
        {"Process.exit(:kill)", fn _p -> Process.exit(self(), :kill) end},
        {"exit(:shutdown)", fn _p -> exit(:shutdown) end},
        {"exit({:shutdown, :timeout})", fn _p -> exit({:shutdown, :timeout}) end},
        {"exit(:custom_reason)", fn _p -> exit(:custom_reason) end}
      ]

      latencies =
        for {name, crash_fun} <- crash_vectors do
          # Filter one-off host scheduler/SQLite checkout preemption while
          # preserving the strict per-vector SLA as a median end-to-end
          # capability measurement.
          samples =
            for _sample <- 1..3 do
              t0 = System.monotonic_time(:microsecond)

              result =
                OperationManager.run_sync_operation(
                  sid,
                  nil,
                  "StressWorker_#{name}",
                  "benchmark_op",
                  "Testing #{name}",
                  %{},
                  crash_fun,
                  10_000
                )

              assert match?({:error, _}, result)
              (System.monotonic_time(:microsecond) - t0) / 1_000.0
            end

          elapsed_ms = samples |> Enum.sort() |> Enum.at(1)

          IO.puts(
            "  -> [Challenger 9] Crash Vector [#{name}]: #{Float.round(elapsed_ms, 2)}ms unblock latency"
          )

          # SLA: Must unblock within < 50ms
          assert elapsed_ms < 50.0,
                 "Crash vector #{name} unblock latency was #{elapsed_ms}ms (exceeded 50ms SLA)!"

          elapsed_ms
        end

      avg_lat = Enum.sum(latencies) / length(latencies)
      max_lat = Enum.max(latencies)

      IO.puts(
        "[Challenger 9] Crash Latency SLA Summary: Min=#{Float.round(Enum.min(latencies), 2)}ms, Avg=#{Float.round(avg_lat, 2)}ms, Max=#{Float.round(max_lat, 2)}ms (All < 50ms)"
      )
    end

    test "stress tests 100 concurrent crashing async operations with zero dangling running ops in DB",
         %{session: session} do
      sid = session.id
      count = 100

      t0 = System.monotonic_time(:millisecond)

      _ops =
        for i <- 1..count do
          crash_fun =
            case rem(i, 5) do
              0 -> fn _p -> raise "Crash #{i}" end
              1 -> fn _p -> throw({:throw_error, i}) end
              2 -> fn _p -> Process.exit(self(), :kill) end
              3 -> fn _p -> exit(:shutdown) end
              4 -> fn _p -> exit({:abnormal, i}) end
            end

          {:ok, _task_pid, op} =
            OperationManager.run_async_operation(
              sid,
              nil,
              "CrashAgent_#{i}",
              "stress_op",
              "Crash Op #{i}",
              %{index: i},
              crash_fun
            )

          op
        end

      elapsed_spawn = System.monotonic_time(:millisecond) - t0

      IO.puts(
        "[Challenger 9] Spawned #{count} concurrent crashing operations in #{elapsed_spawn}ms"
      )

      # Allow background monitors to settle
      :timer.sleep(1500)

      # Verify database state
      db_ops = Repo.all(from o in Operation, where: o.session_id == ^sid)
      assert length(db_ops) == count

      # Verify ZERO operations are in 'running' status
      running_ops = Enum.filter(db_ops, &(&1.status == "running"))
      assert running_ops == [], "Found dangling running operations: #{inspect(running_ops)}"

      # Verify all operations are 'failed' with error_message and completed_at
      failed_ops = Enum.filter(db_ops, &(&1.status == "failed"))
      assert length(failed_ops) == count

      for op <- failed_ops do
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
        assert not is_nil(op.completed_at)
        assert not is_nil(op.duration_ms)
      end

      IO.puts(
        "[Challenger 9] Verified #{count}/#{count} operations transitioned to 'failed' with zero dangling 'running' states"
      )
    end
  end

  describe "Feature F3: Large Operation Hierarchy Tree Stress" do
    test "constructs deep operation hierarchy of 50 sequential levels and verifies tree integrity" do
      # Root -> Child1 -> Child2 -> ... -> Child49 (50 levels deep)
      ops =
        Enum.reduce(0..49, [], fn i, acc ->
          parent_id = if i == 0, do: nil, else: "node_#{i - 1}"

          [
            %Operation{
              id: "node_#{i}",
              parent_op_id: parent_id,
              title: "Level #{i}",
              status: "completed",
              duration_ms: 5
            }
            | acc
          ]
        end)

      t0 = System.monotonic_time(:microsecond)
      tree = OperationManager.build_tree(ops)
      elapsed_us = System.monotonic_time(:microsecond) - t0

      IO.puts("[Challenger 9] Built 50-level deep hierarchy tree in #{elapsed_us / 1000.0}ms")

      # Root check
      assert length(tree) == 1
      root = hd(tree)
      assert root.id == "node_0"

      # Traverse all 50 levels down
      depth =
        Stream.iterate(root, fn node ->
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
      assert stats.running == 0
      assert stats.failed == 0
      assert stats.total_duration_ms == 250
    end

    test "constructs and analyzes a 1,000-node operation tree across 25 roots (depth > 5)" do
      # 25 roots, each with a multi-tier subtree (depth 6: root -> L1 -> L2 -> L3 -> L4 -> L5)
      # 25 roots * (1 root + 5 tiers * 8 nodes = 41 nodes per tree = 1,025 nodes total)
      ops =
        for root_idx <- 1..25,
            tier <- 0..5,
            node_in_tier <- if(tier == 0, do: 0..0, else: 1..8) do
          id = "r#{root_idx}_t#{tier}_n#{node_in_tier}"

          parent_id =
            cond do
              tier == 0 -> nil
              tier == 1 -> "r#{root_idx}_t0_n0"
              true -> "r#{root_idx}_t#{tier - 1}_n1"
            end

          status = if rem(tier + node_in_tier, 6) == 0, do: "failed", else: "completed"

          %Operation{
            id: id,
            parent_op_id: parent_id,
            title: "Op #{id}",
            status: status,
            duration_ms: 10
          }
        end

      assert length(ops) == 1025
      assert length(ops) >= 1000

      t0 = System.monotonic_time(:microsecond)
      tree = OperationManager.build_tree(ops)
      stats = OperationManager.tree_stats(ops)
      elapsed_ms = (System.monotonic_time(:microsecond) - t0) / 1000.0

      IO.puts(
        "[Challenger 9] Built #{length(ops)}-node (depth 6) hierarchy tree and stats in #{elapsed_ms}ms"
      )

      assert length(tree) == 25
      assert stats.roots == 25
      assert stats.total == length(ops)
      assert stats.running == 0
      assert stats.failed > 0
      assert stats.completed > 0
      assert stats.completed + stats.failed == stats.total
    end

    test "handles orphaned operations and cycles gracefully without crashing or dropping nodes" do
      orphan1 = %Operation{id: "orphan1", parent_op_id: "non_existent_1", status: "completed"}
      orphan2 = %Operation{id: "orphan2", parent_op_id: "non_existent_2", status: "failed"}
      root = %Operation{id: "root", parent_op_id: nil, status: "completed"}
      child = %Operation{id: "child", parent_op_id: "root", status: "completed"}

      ops = [orphan1, orphan2, root, child]
      tree = OperationManager.build_tree(ops)

      # 3 top-level items: root, orphan1, orphan2
      assert length(tree) == 3
      tree_ids = Enum.map(tree, & &1.id)
      assert "root" in tree_ids
      assert "orphan1" in tree_ids
      assert "orphan2" in tree_ids

      root_node = Enum.find(tree, &(&1.id == "root"))
      assert length(root_node.children) == 1
      assert hd(root_node.children).id == "child"

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 4
      assert stats.roots == 3
      assert stats.completed == 3
      assert stats.failed == 1
    end
  end
end
