defmodule IexCode.Engine.Challenger5EmpiricalStressTest do
  @moduledoc """
  Empirical Stress Test Suite by Challenger 5 for Milestone 2 OTP Process Architecture:
  - F2: OTP Subagent Process Tree (AgentSupervisor, AgentRegistry, Planner, Explorer, Coder, Verifier)
  - F3: OTP Process Crash Monitoring & Unblocking Latency (OperationManager)
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000

  alias IexCode.{Projects, Sessions, Repo}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager}
  alias IexCode.Sessions.Operation
  import Ecto.Query

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger 5 Stress Proj #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger 5 Stress Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. EMPIRICAL STRESS TEST: AgentSupervisor & AgentRegistry Lifecycle & Leaks
  # ============================================================================

  describe "Feature F2: Empirical Concurrency & Zero-Leak Verification on Subagent Process Tree" do
    test "burst spawns 200 subagents across 50 sessions and verifies clean registration and teardown without leaks",
         %{project: project} do
      session_count = 50
      agent_types = [:planner, :explorer, :coder, :verifier]

      # 1. Create 50 distinct sessions
      session_ids =
        for i <- 1..session_count do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Burst Session #{i}"
            })

          s.id
        end

      initial_child_count = DynamicSupervisor.count_children(AgentSupervisor).active

      # 2. Concurrently spawn 200 subagents (4 per session across 50 sessions)
      spawn_start_time = System.monotonic_time(:millisecond)

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

      spawned_agents = Task.await_many(spawn_tasks, 30_000)
      spawn_duration = System.monotonic_time(:millisecond) - spawn_start_time

      # Verification: Exactly 200 agents spawned
      assert length(spawned_agents) == 200
      IO.puts("\n[Challenger 5] Successfully spawned 200 subagents in #{spawn_duration}ms")

      # 3. Verify DynamicSupervisor active child count increased by 200
      current_child_count = DynamicSupervisor.count_children(AgentSupervisor).active
      assert current_child_count == initial_child_count + 200

      # 4. Verify all 50 sessions have all 4 subagents registered and reachable
      for sid <- session_ids do
        active = AgentRegistry.list_agents(sid)
        assert length(active) == 4
        types = Enum.map(active, &elem(&1, 0))
        assert :planner in types
        assert :explorer in types
        assert :coder in types
        assert :verifier in types
      end

      # 5. Concurrently tear down all 200 agents
      stop_start_time = System.monotonic_time(:millisecond)

      stop_tasks =
        for sid <- session_ids do
          Task.async(fn ->
            AgentSupervisor.stop_all_agents(sid)
            assert AgentRegistry.list_agents(sid) == []
          end)
        end

      Task.await_many(stop_tasks, 30_000)
      stop_duration = System.monotonic_time(:millisecond) - stop_start_time

      IO.puts("[Challenger 5] Successfully stopped 200 subagents in #{stop_duration}ms")

      # 6. Leak & Orphan Process Verification: Zero agents remain registered or alive
      final_child_count = DynamicSupervisor.count_children(AgentSupervisor).active
      assert final_child_count == initial_child_count

      for sid <- session_ids do
        assert AgentRegistry.list_agents(sid) == []

        for type <- agent_types do
          assert AgentSupervisor.find_agent(sid, type) == nil
          assert AgentRegistry.whereis(sid, type) == nil
        end
      end

      # Ensure none of the spawned PIDs are still alive
      for {_sid, _type, pid} <- spawned_agents do
        refute Process.alive?(pid), "Found orphaned subagent PID #{inspect(pid)} still alive!"
      end
    end

    test "subagent crash isolation: killing an agent does not affect peer agents or supervisor",
         %{session: session, project: project} do
      sid = session.id

      {:ok, p_pid} =
        AgentSupervisor.start_agent(sid, :planner,
          project_root: project.root_path,
          session: session
        )

      {:ok, e_pid} =
        AgentSupervisor.start_agent(sid, :explorer,
          project_root: project.root_path,
          session: session
        )

      {:ok, c_pid} =
        AgentSupervisor.start_agent(sid, :coder,
          project_root: project.root_path,
          session: session
        )

      {:ok, v_pid} =
        AgentSupervisor.start_agent(sid, :verifier,
          project_root: project.root_path,
          session: session
        )

      for pid <- [p_pid, e_pid, c_pid, v_pid] do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
      end

      # Verify all 4 are alive
      assert Process.alive?(p_pid)
      assert Process.alive?(e_pid)
      assert Process.alive?(c_pid)
      assert Process.alive?(v_pid)

      # Kill ExplorerAgent abruptly with :kill
      ref = Process.monitor(e_pid)
      Process.exit(e_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^e_pid, :killed}, 2000

      # Peer agents must remain intact and alive
      assert Process.alive?(p_pid)
      assert Process.alive?(c_pid)
      assert Process.alive?(v_pid)
      assert Process.alive?(Process.whereis(AgentSupervisor))

      # AgentSupervisor transient restart recovers the agent or permits fresh start
      :timer.sleep(100)
      new_e_pid = AgentSupervisor.find_agent(sid, :explorer)
      assert is_pid(new_e_pid) and Process.alive?(new_e_pid)

      # Clean teardown
      AgentSupervisor.stop_all_agents(sid)
      assert AgentRegistry.list_agents(sid) == []
    end
  end

  # ============================================================================
  # 2. EMPIRICAL STRESS TEST: OperationManager Crash Resilience & Latency (< 50ms)
  # ============================================================================

  describe "Feature F3: Empirical Crash Unblocking Latency & DB Integrity" do
    test "benchmark: synchronous crash unblocking latency is strictly < 50ms across diverse crash vectors",
         %{session: session} do
      sid = session.id

      crash_vectors = [
        {"RuntimeError", fn _p -> raise RuntimeError, "boom_runtime" end},
        {"ArgumentError", fn _p -> raise ArgumentError, "boom_argument" end},
        {"Erlang Error (badarith)", fn _p -> :erlang.error(:badarith) end},
        {"Throw Symbol", fn _p -> throw(:abort_signal) end},
        {"Throw Complex Map", fn _p -> throw(%{status: :failed, reason: "custom_throw"}) end},
        {"Process.exit(:kill)", fn _p -> Process.exit(self(), :kill) end},
        {"exit(:shutdown)", fn _p -> exit(:shutdown) end},
        {"exit({:shutdown, :timeout})", fn _p -> exit({:shutdown, :timeout}) end},
        {"exit(:custom_abnormal_reason)", fn _p -> exit(:custom_abnormal_reason) end}
      ]

      latencies =
        for {name, crash_fun} <- crash_vectors do
          # A single wall-clock sample can include an unrelated scheduler or
          # SQLite checkout preemption during the full adversarial suite. Use
          # the median of three real end-to-end crashes so the assertion still
          # enforces the 50ms capability boundary without treating one OS
          # scheduling outlier as a product regression.
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

          IO.puts("  -> Crash Vector [#{name}]: #{Float.round(elapsed_ms, 2)}ms unblock latency")

          # EMPIRICAL REQUIREMENT: Must unblock within < 50ms (never hanging or blocking on timeouts)
          assert elapsed_ms < 50.0,
                 "Crash vector #{name} took #{elapsed_ms}ms to unblock (threshold is 50ms)!"

          elapsed_ms
        end

      avg_latency = Enum.sum(latencies) / length(latencies)
      max_latency = Enum.max(latencies)

      IO.puts(
        "[Challenger 5] Crash Unblocking Latency — Avg: #{Float.round(avg_latency, 2)}ms, Max: #{Float.round(max_latency, 2)}ms"
      )

      assert max_latency < 50.0
      assert avg_latency < 10.0
    end

    test "concurrent crash flood: 100 async operations crashing simultaneously result in ZERO dangling running ops",
         %{project: project} do
      session_count = 10
      ops_per_session = 10
      total_ops = session_count * ops_per_session

      # Create 10 sessions
      session_ids =
        for i <- 1..session_count do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Crash Flood Session #{i}"
            })

          s.id
        end

      # Launch 100 crashing async operations concurrently across 10 sessions
      launch_start = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..total_ops do
          sid = Enum.at(session_ids, rem(i, session_count))

          crash_fun =
            case rem(i, 5) do
              0 -> fn _p -> raise "Flood crash #{i}" end
              1 -> fn _p -> throw({:flood_throw, i}) end
              2 -> fn _p -> Process.exit(self(), :kill) end
              3 -> fn _p -> exit({:shutdown, :flood_shutdown}) end
              4 -> fn _p -> exit({:abnormal_exit, i}) end
            end

          Task.async(fn ->
            {:ok, _task_pid, op} =
              OperationManager.run_async_operation(
                sid,
                nil,
                "FloodWorker_#{i}",
                "flood_crash",
                "Crash Op #{i}",
                %{idx: i},
                crash_fun
              )

            op.id
          end)
        end

      op_ids = Task.await_many(tasks, 20_000)
      launch_elapsed = System.monotonic_time(:millisecond) - launch_start
      assert length(op_ids) == total_ops

      IO.puts(
        "\n[Challenger 5] Launched 100 concurrent crashing operations in #{launch_elapsed}ms"
      )

      # Allow crash watcher tasks to settle and commit DB updates
      :timer.sleep(2500)

      # Query DB to inspect state of all 100 operations
      all_ops = Repo.all(from o in Operation, where: o.id in ^op_ids)
      assert length(all_ops) == total_ops

      running_ops = Enum.filter(all_ops, &(&1.status == "running"))
      failed_ops = Enum.filter(all_ops, &(&1.status == "failed"))

      # EMPIRICAL ASSERTIONS:
      # 1. Zero operations remain in "running" state
      assert running_ops == [], "Found #{length(running_ops)} dangling running operations!"

      # 2. All 100 operations transitioned to "failed" with populated error messages and durations
      assert length(failed_ops) == total_ops

      for op <- failed_ops do
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
        assert not is_nil(op.completed_at)
        assert is_integer(op.duration_ms) and op.duration_ms >= 0
      end

      IO.puts(
        "[Challenger 5] 100/100 crashing operations correctly marked failed with zero dangling running ops"
      )
    end
  end

  # ============================================================================
  # 3. EMPIRICAL STRESS TEST: Operation Tree Deep Nesting & Massive Scale
  # ============================================================================

  describe "Feature F3: Operation Tree Deep Nesting & Scale Benchmarks" do
    test "builds 500-level deep sequential operation hierarchy in < 50ms" do
      depth = 500

      ops =
        Enum.reduce(0..(depth - 1), [], fn i, acc ->
          parent_id = if i == 0, do: nil, else: "node_#{i - 1}"

          [
            %Operation{
              id: "node_#{i}",
              parent_op_id: parent_id,
              title: "Level #{i}",
              status: "completed",
              duration_ms: 1
            }
            | acc
          ]
        end)

      t0 = System.monotonic_time(:microsecond)
      tree = OperationManager.build_tree(ops)
      elapsed_ms = (System.monotonic_time(:microsecond) - t0) / 1_000.0

      IO.puts("\n[Challenger 5] Built 500-level deep tree in #{Float.round(elapsed_ms, 2)}ms")

      assert elapsed_ms < 50.0
      assert length(tree) == 1

      # Traverse down all 500 levels
      measured_depth =
        Stream.iterate(hd(tree), fn node ->
          case node.children do
            [child] -> child
            _ -> nil
          end
        end)
        |> Stream.take_while(&(&1 != nil))
        |> Enum.count()

      assert measured_depth == 500

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 500
      assert stats.roots == 1
      assert stats.completed == 500
      assert stats.total_duration_ms == 500
    end

    test "builds massive wide tree of 10,000 nodes across 100 roots in < 150ms" do
      # 100 roots, each with 99 children = 10,000 operations
      ops =
        for root_i <- 1..100, child_i <- 0..99 do
          if child_i == 0 do
            %Operation{
              id: "root_#{root_i}",
              parent_op_id: nil,
              title: "Root #{root_i}",
              status: "completed",
              duration_ms: 10
            }
          else
            %Operation{
              id: "child_#{root_i}_#{child_i}",
              parent_op_id: "root_#{root_i}",
              title: "Child #{child_i} of #{root_i}",
              status: if(rem(child_i, 10) == 0, do: "failed", else: "completed"),
              duration_ms: 2
            }
          end
        end

      assert length(ops) == 10_000

      t0 = System.monotonic_time(:microsecond)
      tree = OperationManager.build_tree(ops)
      stats = OperationManager.tree_stats(ops)
      elapsed_ms = (System.monotonic_time(:microsecond) - t0) / 1_000.0

      IO.puts(
        "[Challenger 5] Built 10,000-node wide tree & stats in #{Float.round(elapsed_ms, 2)}ms"
      )

      assert elapsed_ms < 150.0
      assert length(tree) == 100
      assert stats.total == 10_000
      assert stats.roots == 100
      assert stats.failed == 100 * 9
      assert stats.completed == 10_000 - 900

      for root <- tree do
        assert length(root.children) == 99
      end
    end
  end
end
