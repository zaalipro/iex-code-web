defmodule IexCode.Engine.Challenger7EmpiricalStressTest do
  @moduledoc """
  Comprehensive Empirical Stress & Resilience Test Suite by Challenger 7 for Milestone 2:
  - Feature F2: OTP Subagent Process Tree (AgentSupervisor, AgentRegistry, Planner, Explorer, Coder, Verifier)
  - Feature F3: OTP Process Crash Monitoring, Telemetry, and <50ms Unblocking SLA (OperationManager)
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions, Repo}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager}
  alias IexCode.Sessions.Operation
  import Ecto.Query

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger 7 Stress Project #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger 7 Stress Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. EMPIRICAL STRESS TESTS: AgentSupervisor & AgentRegistry (Feature F2)
  # ============================================================================

  describe "Feature F2: Empirical Concurrency, Lifecycle, and Zero-Leak Verification" do
    test "burst spawn and teardown of 400 subagents across 100 sessions with zero process or registry leaks",
         %{project: project} do
      session_count = 100
      agent_types = [:planner, :explorer, :coder, :verifier]
      total_expected = session_count * length(agent_types)

      # 1. Create 100 sessions
      session_ids =
        for i <- 1..session_count do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Burst Session C7 #{i}"
            })

          s.id
        end

      baseline_child_count = DynamicSupervisor.count_children(AgentSupervisor).active
      _baseline_process_count = :erlang.system_info(:process_count)

      # 2. Concurrently spawn 400 subagents (100 sessions * 4 subagent types)
      t0 = System.monotonic_time(:millisecond)

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

      spawned = Task.await_many(spawn_tasks, 40_000)
      spawn_duration = System.monotonic_time(:millisecond) - t0

      assert length(spawned) == total_expected

      IO.puts(
        "\n[Challenger 7] Concurrently spawned #{total_expected} subagents across #{session_count} sessions in #{spawn_duration}ms"
      )

      # 3. Verify DynamicSupervisor active child count exactly matches
      active_child_count = DynamicSupervisor.count_children(AgentSupervisor).active
      assert active_child_count == baseline_child_count + total_expected

      # 4. Verify all 100 sessions have all 4 subagents registered and alive
      for sid <- session_ids do
        active_list = AgentRegistry.list_agents(sid)
        assert length(active_list) == 4
        types = Enum.map(active_list, &elem(&1, 0))
        assert :planner in types
        assert :explorer in types
        assert :coder in types
        assert :verifier in types
      end

      # 5. Concurrently terminate all subagents across all 100 sessions
      t1 = System.monotonic_time(:millisecond)

      stop_tasks =
        for sid <- session_ids do
          Task.async(fn ->
            assert :ok = AgentSupervisor.stop_all_agents(sid)
            _ = :sys.get_state(AgentRegistry)
            assert AgentRegistry.list_agents(sid) == []
          end)
        end

      Task.await_many(stop_tasks, 40_000)
      stop_duration = System.monotonic_time(:millisecond) - t1

      IO.puts(
        "[Challenger 7] Concurrently stopped #{total_expected} subagents in #{stop_duration}ms"
      )

      # 6. Empirical Zero-Leak Verification
      final_child_count = DynamicSupervisor.count_children(AgentSupervisor).active

      assert final_child_count == baseline_child_count,
             "Leaked supervisor children: before=#{baseline_child_count}, after=#{final_child_count}"

      # Verify all 400 PIDs are dead (zero orphaned processes)
      for {_sid, _type, pid} <- spawned do
        refute Process.alive?(pid), "Orphaned subagent process #{inspect(pid)} is still alive!"
      end

      # Verify registry is completely clean for all sessions
      _ = :sys.get_state(AgentRegistry)

      for sid <- session_ids do
        assert AgentRegistry.list_agents(sid) == []

        for type <- agent_types do
          assert AgentRegistry.whereis(sid, type) == nil
          assert AgentSupervisor.find_agent(sid, type) == nil
        end
      end
    end

    test "rapid spawn-and-stop thrashing loop (50 iterations per agent type) without registry corruption",
         %{session: session} do
      sid = session.id
      agent_types = [:planner, :explorer, :coder, :verifier]
      iterations = 50

      t0 = System.monotonic_time(:millisecond)

      for i <- 1..iterations do
        type = Enum.at(agent_types, rem(i, length(agent_types)))

        # Start
        {:ok, pid} = AgentSupervisor.start_agent(sid, type)
        assert is_pid(pid) and Process.alive?(pid)
        assert AgentRegistry.whereis(sid, type) == pid

        # Stop
        assert :ok = AgentSupervisor.stop_agent(sid, type)
        refute Process.alive?(pid)
        assert AgentRegistry.whereis(sid, type) == nil
      end

      duration = System.monotonic_time(:millisecond) - t0

      IO.puts(
        "[Challenger 7] Completed #{iterations} rapid spawn-and-stop cycles in #{duration}ms"
      )

      _ = :sys.get_state(AgentRegistry)
      assert AgentRegistry.list_agents(sid) == []
    end

    test "adversarial process kill matrix: kills with :kill, abnormal exits, and shutdown do not crash peers or supervisor",
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

      sup_pid = Process.whereis(AgentSupervisor)
      assert is_pid(sup_pid) and Process.alive?(sup_pid)

      # 1. Kill Explorer with :kill
      ref_e = Process.monitor(e_pid)
      Process.exit(e_pid, :kill)
      assert_receive {:DOWN, ^ref_e, :process, ^e_pid, :killed}, 2000

      # Peers must stay alive
      assert Process.alive?(p_pid)
      assert Process.alive?(c_pid)
      assert Process.alive?(v_pid)
      assert Process.alive?(sup_pid)

      # 2. Kill Coder with exit({:shutdown, :test_exit})
      ref_c = Process.monitor(c_pid)
      Process.exit(c_pid, {:shutdown, :test_exit})
      assert_receive {:DOWN, ^ref_c, :process, ^c_pid, {:shutdown, :test_exit}}, 2000

      # Planner & Verifier must stay alive
      assert Process.alive?(p_pid)
      assert Process.alive?(v_pid)
      assert Process.alive?(sup_pid)

      # 3. Clean teardown
      AgentSupervisor.stop_all_agents(sid)
      _ = :sys.get_state(AgentRegistry)
      assert AgentRegistry.list_agents(sid) == []
    end

    test "exhaustively normalizes agent type formats (atoms, strings, mixed case, and via-tuples)",
         %{session: session} do
      sid = session.id

      # Atoms
      assert AgentRegistry.normalize_type(:planner) == :planner
      assert AgentRegistry.normalize_type(:explorer) == :explorer
      assert AgentRegistry.normalize_type(:coder) == :coder
      assert AgentRegistry.normalize_type(:verifier) == :verifier

      # Lowercase binaries
      assert AgentRegistry.normalize_type("planner") == :planner
      assert AgentRegistry.normalize_type("explorer") == :explorer
      assert AgentRegistry.normalize_type("coder") == :coder
      assert AgentRegistry.normalize_type("verifier") == :verifier

      # PascalCase Module Strings
      assert AgentRegistry.normalize_type("PlannerAgent") == :planner
      assert AgentRegistry.normalize_type("ExplorerAgent") == :explorer
      assert AgentRegistry.normalize_type("CoderAgent") == :coder
      assert AgentRegistry.normalize_type("VerifierAgent") == :verifier

      # Via Tuples
      assert {:via, Registry, {AgentRegistry, {^sid, :planner}}} =
               AgentRegistry.via_tuple(sid, "PlannerAgent")

      assert {:via, Registry, {AgentRegistry, {^sid, :explorer}}} =
               AgentRegistry.via_tuple(sid, "EXPLORER")

      assert {:via, Registry, {AgentRegistry, {^sid, :coder}}} =
               AgentRegistry.via_tuple(sid, :coder)

      assert {:via, Registry, {AgentRegistry, {^sid, :verifier}}} =
               AgentRegistry.via_tuple(sid, "verifier")
    end
  end

  # ============================================================================
  # 2. EMPIRICAL STRESS TESTS: OperationManager Crash Resilience & SLA (Feature F3)
  # ============================================================================

  describe "Feature F3: Empirical Crash Unblocking Latency (< 50ms SLA) and Database Integrity" do
    test "rigorous SLA benchmark: all 15 diverse crash vectors unblock in strictly < 50ms",
         %{session: session} do
      sid = session.id

      crash_vectors = [
        {"1. RuntimeError", fn _p -> raise RuntimeError, "c7_runtime_error" end},
        {"2. ArgumentError", fn _p -> raise ArgumentError, "c7_argument_error" end},
        {"3. KeyError", fn _p -> raise KeyError, key: :missing_key, term: %{} end},
        {"4. ArithmeticError", fn _p -> raise ArithmeticError, "c7_arithmetic" end},
        {"5. Erlang undef", fn _p -> :erlang.error(:undef) end},
        {"6. Erlang function_clause", fn _p -> :erlang.error(:function_clause) end},
        {"7. Erlang badarith", fn _p -> :erlang.error(:badarith) end},
        {"8. Throw Atom", fn _p -> throw(:abort_turn) end},
        {"9. Throw Complex Struct",
         fn _p -> throw(%{status: :unrecoverable, code: 500, detail: "fatal"}) end},
        {"10. Process.exit(:kill)", fn _p -> Process.exit(self(), :kill) end},
        {"11. exit(:shutdown)", fn _p -> exit(:shutdown) end},
        {"12. exit({:shutdown, :timeout})", fn _p -> exit({:shutdown, :timeout}) end},
        {"13. exit({:shutdown, :conn_lost})", fn _p -> exit({:shutdown, :conn_lost}) end},
        {"14. exit(:custom_abnormal)", fn _p -> exit(:custom_abnormal) end},
        {"15. exit({:badmatch, :unmatched})", fn _p -> exit({:badmatch, :unmatched}) end}
      ]

      latencies =
        for {name, crash_fun} <- crash_vectors do
          t0 = System.monotonic_time(:microsecond)

          result =
            OperationManager.run_sync_operation(
              sid,
              nil,
              "CrashWorker_#{name}",
              "benchmark",
              "Testing #{name}",
              %{},
              crash_fun,
              10_000
            )

          elapsed_us = System.monotonic_time(:microsecond) - t0
          elapsed_ms = elapsed_us / 1_000.0

          IO.puts(
            "  -> [C7 Benchmark] #{String.pad_trailing(name, 35)}: #{Float.round(elapsed_ms, 2)}ms unblock latency"
          )

          # STRICT EMPIRICAL SLA: < 50ms unblocking time
          assert elapsed_ms < 50.0,
                 "Crash vector #{name} took #{elapsed_ms}ms to unblock (threshold is 50.0ms)!"

          # Result must be an error tuple with informative message
          assert {:error, err_msg} = result
          assert is_binary(err_msg) and byte_size(err_msg) > 0

          elapsed_ms
        end

      avg_latency = Enum.sum(latencies) / length(latencies)
      max_latency = Enum.max(latencies)
      min_latency = Enum.min(latencies)

      IO.puts(
        "[Challenger 7] Unblock Latency Summary — Min: #{Float.round(min_latency, 2)}ms, Avg: #{Float.round(avg_latency, 2)}ms, Max: #{Float.round(max_latency, 2)}ms (All < 50ms SLA)"
      )

      assert max_latency < 50.0
      assert avg_latency < 10.0
    end

    test "concurrent crash flood: 200 async operations crashing across 20 sessions leave ZERO dangling running ops",
         %{project: project} do
      session_count = 20
      ops_per_session = 10
      total_ops = session_count * ops_per_session

      # Create 20 sessions
      session_ids =
        for i <- 1..session_count do
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Crash Flood C7 Session #{i}"
            })

          s.id
        end

      t0 = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..total_ops do
          sid = Enum.at(session_ids, rem(i, session_count))

          crash_fun =
            case rem(i, 6) do
              0 -> fn _p -> raise RuntimeError, "Crash flood #{i}" end
              1 -> fn _p -> throw({:flood_throw, i}) end
              2 -> fn _p -> Process.exit(self(), :kill) end
              3 -> fn _p -> exit(:shutdown) end
              4 -> fn _p -> exit({:shutdown, :timeout_flood}) end
              5 -> fn _p -> exit({:abnormal_exit_flood, i}) end
            end

          Task.async(fn ->
            {:ok, _task_pid, op} =
              OperationManager.run_async_operation(
                sid,
                nil,
                "FloodWorkerC7_#{i}",
                "flood_crash",
                "Crash Op C7 #{i}",
                %{idx: i},
                crash_fun
              )

            op.id
          end)
        end

      op_ids = Task.await_many(tasks, 30_000)
      launch_duration = System.monotonic_time(:millisecond) - t0

      assert length(op_ids) == total_ops

      IO.puts(
        "\n[Challenger 7] Launched #{total_ops} concurrent crashing operations in #{launch_duration}ms"
      )

      # Allow crash watcher tasks to settle and commit DB updates
      :timer.sleep(3000)

      # Query DB for state of all 200 operations
      all_ops = Repo.all(from o in Operation, where: o.id in ^op_ids)
      assert length(all_ops) == total_ops

      running_ops = Enum.filter(all_ops, &(&1.status == "running"))
      failed_ops = Enum.filter(all_ops, &(&1.status == "failed"))

      # EMPIRICAL DB ASSERTIONS:
      # 1. Zero operations remain in "running" state
      assert running_ops == [], "Found #{length(running_ops)} dangling running operations!"

      # 2. Exactly 200 operations are marked as "failed"
      assert length(failed_ops) == total_ops

      for op <- failed_ops do
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
        assert not is_nil(op.completed_at)
        assert is_integer(op.duration_ms) and op.duration_ms >= 0
      end

      IO.puts(
        "[Challenger 7] Verified 200/200 operations transitioned to 'failed' with zero dangling 'running' states"
      )
    end

    test "synchronous timeout precision: timeout is strictly enforced without blocking indefinitely",
         %{session: session} do
      sid = session.id
      t0 = System.monotonic_time(:millisecond)

      result =
        OperationManager.run_sync_operation(
          sid,
          nil,
          "TimeoutWorker",
          "sleep_task",
          "Sleeping Task",
          %{},
          fn _progress ->
            :timer.sleep(10_000)
            {:ok, "should not return"}
          end,
          120
        )

      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 110 and elapsed < 800,
             "Expected timeout around 120ms, took #{elapsed}ms"

      assert result == {:error, "Operation timed out after 120ms"}
    end

    test "full telemetry and PubSub event lifecycle verification for both success and crash paths",
         %{session: session} do
      sid = session.id
      test_pid = self()

      stop_handler_id = "test-c7-stop-#{sid}"
      crash_handler_id = "test-c7-crash-#{sid}"

      :telemetry.attach(
        stop_handler_id,
        [:iex_code, :operation, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_stop, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        crash_handler_id,
        [:iex_code, :operation, :crash],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_crash, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(stop_handler_id)
        :telemetry.detach(crash_handler_id)
      end)

      # 1. Test Successful Operation Lifecycle
      {:ok, _tpid1, op1} =
        OperationManager.run_async_operation(
          sid,
          nil,
          "SuccessWorker",
          "task_success",
          "Success Task",
          %{},
          fn progress ->
            progress.(50, "Halfway done")
            {:ok, "completed_payload"}
          end
        )

      assert_receive {:operation_started, started_op1}, 3000
      assert started_op1.id == op1.id

      assert_receive {:operation_progress, op_id1, 50, "Halfway done"}, 3000
      assert op_id1 == op1.id

      assert_receive {:operation_completed, comp_op1}, 3000
      assert comp_op1.id == op1.id
      assert comp_op1.status == "completed"

      assert_receive {:telemetry_stop, [:iex_code, :operation, :stop], %{duration_ms: _dur},
                      meta_stop},
                     3000

      assert meta_stop.operation_id == op1.id
      assert meta_stop.session_id == sid

      # 2. Test Crashing Operation Lifecycle
      {:ok, _tpid2, op2} =
        OperationManager.run_async_operation(
          sid,
          op1.id,
          "CrashWorker",
          "task_crash",
          "Crash Task",
          %{},
          fn _progress ->
            raise RuntimeError, "telemetry_crash_test"
          end
        )

      assert_receive {:operation_started, started_op2}, 3000
      assert started_op2.id == op2.id

      assert_receive {:operation_failed, failed_op2}, 3000
      assert failed_op2.id == op2.id
      assert failed_op2.status == "failed"
      assert failed_op2.parent_op_id == op1.id

      assert_receive {:telemetry_crash, [:iex_code, :operation, :crash], %{duration_ms: _},
                      meta_crash},
                     3000

      assert meta_crash.operation_id == op2.id
      assert meta_crash.session_id == sid
      assert meta_crash.parent_op_id == op1.id
    end
  end

  # ============================================================================
  # 3. EMPIRICAL OPERATION TREE TESTS: Deep Hierarchy & Scale
  # ============================================================================

  describe "Feature F3: Operation Tree Deep Nesting, Orphan Handling, and Scale" do
    test "builds 100-level deep operation tree and calculates exact hierarchical statistics" do
      depth = 100

      ops =
        Enum.reduce(0..(depth - 1), [], fn i, acc ->
          parent_id = if i == 0, do: nil, else: "node_c7_#{i - 1}"

          [
            %Operation{
              id: "node_c7_#{i}",
              parent_op_id: parent_id,
              title: "Level #{i}",
              status: if(rem(i, 10) == 0, do: "failed", else: "completed"),
              duration_ms: 5
            }
            | acc
          ]
        end)

      t0 = System.monotonic_time(:microsecond)
      tree = OperationManager.build_tree(ops)
      elapsed_ms = (System.monotonic_time(:microsecond) - t0) / 1_000.0

      IO.puts("\n[Challenger 7] Built 100-level deep tree in #{Float.round(elapsed_ms, 2)}ms")

      assert elapsed_ms < 20.0
      assert length(tree) == 1

      stats = OperationManager.tree_stats(ops)
      assert stats.total == 100
      assert stats.roots == 1
      assert stats.failed == 10
      assert stats.completed == 90
      assert stats.total_duration_ms == 500
    end

    test "handles disconnected orphan operations gracefully by promoting them to roots" do
      root_id = Ecto.UUID.generate()
      orphan_1 = Ecto.UUID.generate()
      orphan_2 = Ecto.UUID.generate()
      non_existent = Ecto.UUID.generate()

      ops = [
        %Operation{id: root_id, parent_op_id: nil, title: "Legit Root", status: "completed"},
        %Operation{
          id: orphan_1,
          parent_op_id: non_existent,
          title: "Dangling Orphan",
          status: "failed"
        },
        %Operation{id: orphan_2, parent_op_id: "", title: "Empty Parent", status: "completed"}
      ]

      tree = OperationManager.build_tree(ops)
      assert length(tree) == 3

      tree_ids = Enum.map(tree, & &1.id)
      assert root_id in tree_ids
      assert orphan_1 in tree_ids
      assert orphan_2 in tree_ids
    end
  end
end
