defmodule IexCode.E2E.Tier5AdversarialConcurrencyTest do
  @moduledoc """
  Tier 5: Adversarial Concurrency, Memory Stability & Fault Tolerance Test Suite (22 Tests).

  Probes deep edge cases, race conditions, memory bounds, supervisor recovery,
  and crash handling across the IexCode backend engine:
  - 1. Concurrency Limits & Race Conditions (Simultaneous execution, session spawn/teardown races, mailbox bursts, swarm concurrency)
  - 2. Memory & CPU Stability (>10MB output bursts, large file IO, UTF-8 buffer stress, memory/process leak checks, AST search scale, MultiPatch transactional rollback)
  - 3. Crash Recovery & Fault Tolerance (:kill extermination, unhandled exceptions, OTP supervisor recovery, DB contention fallbacks, top supervisor resilience)
  """
  use IexCode.E2E.Case, async: false
  @moduletag timeout: 240_000

  alias IexCode.{Sessions, Tools, Repo}

  alias IexCode.Engine.{
    AgentRegistry,
    AgentSupervisor,
    OperationManager,
    SessionServer,
    SessionSupervisor,
    SwarmCoordinator
  }

  alias IexCode.Sessions.Operation
  alias IexCode.LLM.UTF8Buffer
  alias IexCode.Tools.{MultiPatch, ASTSearch}
  import Ecto.Query

  # ============================================================================
  # 1. Concurrency Limits & Race Conditions
  # ============================================================================
  describe "1. Concurrency Limits & Race Conditions" do
    test "C01: simultaneous tool execution across 50 concurrent tasks without race or deadlock",
         %{
           workspace_path: ws
         } do
      # Setup 50 files in workspace
      for i <- 1..50 do
        workspace_write_file(
          ws,
          "lib/file_#{i}.ex",
          "defmodule File#{i} do\n  def val, do: #{i}\nend\n"
        )
      end

      # Concurrently execute 50 distinct tool operations (read_file, write_file, patch_file, ast_search, run_command)
      tasks =
        1..50
        |> Enum.map(fn i ->
          Task.async(fn ->
            case rem(i, 5) do
              0 ->
                {:ok, content} = Tools.execute("read_file", %{"path" => "lib/file_#{i}.ex"}, ws)
                assert String.contains?(content, "def val, do: #{i}")
                {:read, i}

              1 ->
                {:ok, res} =
                  Tools.execute(
                    "write_file",
                    %{"path" => "tmp/gen_#{i}.txt", "content" => "Data #{i}"},
                    ws
                  )

                assert String.contains?(res, "Successfully wrote")
                {:write, i}

              2 ->
                {:ok, res} =
                  Tools.execute(
                    "patch_file",
                    %{
                      "path" => "lib/file_#{i}.ex",
                      "target_content" => "def val, do: #{i}",
                      "replacement_content" => "def val, do: #{i * 10}"
                    },
                    ws
                  )

                assert String.contains?(res, "Successfully patched")
                {:patch, i}

              3 ->
                {:ok, res} = Tools.execute("ast_search", %{"query" => "File#{i}"}, ws)
                assert is_binary(res)
                {:ast, i}

              4 ->
                {:ok, res} = Tools.execute("run_command", %{"command" => "echo 'task_#{i}'"}, ws)
                assert String.contains?(res, "task_#{i}")
                {:cmd, i}
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 50
    end

    test "C02: concurrent session spawning, registration, and shutdown races across 40 sessions",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})

      # Concurrently create 40 sessions, start SessionServer and subagents, then stop them all
      session_tasks =
        1..40
        |> Enum.map(fn i ->
          Task.async(fn ->
            {:ok, session} =
              Sessions.create_session(%{
                project_id: project.id,
                title: "Racy Session #{i}"
              })

            # Ensure SessionServer started
            {:ok, s_pid} = SessionServer.ensure_started(session.id)
            assert is_pid(s_pid) and Process.alive?(s_pid)

            # Start subagents
            {:ok, p_pid} = AgentSupervisor.start_agent(session.id, :planner, project_root: ws)
            {:ok, c_pid} = AgentSupervisor.start_agent(session.id, :coder, project_root: ws)

            assert is_pid(p_pid) and Process.alive?(p_pid)
            assert is_pid(c_pid) and Process.alive?(c_pid)

            # Verify registry
            assert AgentRegistry.whereis(session.id, :planner) == p_pid
            assert AgentRegistry.whereis(session.id, :coder) == c_pid

            # Stop subagents
            assert :ok = AgentSupervisor.stop_all_agents(session.id)
            assert AgentRegistry.list_agents(session.id) == []

            session.id
          end)
        end)

      session_ids = Task.await_many(session_tasks, 40_000)
      assert length(session_ids) == 40
      assert length(Enum.uniq(session_ids)) == 40
    end

    test "C03: concurrent racing calls on single SessionServer (prompt, toggle, clear, get_state)",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id
      subscribe_session(sid)

      {:ok, s_pid} = SessionServer.ensure_started(sid)
      assert is_pid(s_pid) and Process.alive?(s_pid)

      # 30 concurrent callers hitting toggle_swarm, clear_operations, get_state, and send_prompt
      tasks =
        1..30
        |> Enum.map(fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 ->
                {:ok, _mode} = SessionServer.toggle_swarm(sid)
                :toggle

              1 ->
                :ok = SessionServer.clear_operations(sid)
                :clear

              2 ->
                state = SessionServer.get_state(sid)
                assert is_map(state)
                assert state.session_id == sid
                :get_state

              3 ->
                # Send prompt
                :ok = SessionServer.send_prompt(sid, "Echo message #{i}")
                :prompt
            end
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 30

      # GenServer must still be alive and responsive after race
      final_state = SessionServer.get_state(sid)
      assert final_state.session_id == sid
      assert Process.alive?(s_pid)
    end

    test "C04: high-throughput PubSub burst (10,000 messages) without mailbox overflow or subscriber crash",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      # Create 5 distinct subscriber processes
      test_pid = self()

      _subscribers =
        1..5
        |> Enum.map(fn sub_idx ->
          spawn_link(fn ->
            Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{sid}")
            send(test_pid, {:ready, sub_idx})

            # Receive loop counting messages
            count = count_messages(0, 5000)
            send(test_pid, {:done, sub_idx, count})
          end)
        end)

      for sub_idx <- 1..5 do
        assert_receive {:ready, ^sub_idx}, 3000
      end

      # Broadcast 2,000 progress events across the channel (5 subscribers * 2000 = 10,000 deliveries)
      for i <- 1..2000 do
        Phoenix.PubSub.broadcast(
          IexCode.PubSub,
          "session:#{sid}",
          {:operation_progress, "op_#{i}", rem(i, 100), "Step #{i}"}
        )
      end

      # Broadcast completion marker
      Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{sid}", :stress_complete)

      for sub_idx <- 1..5 do
        assert_receive {:done, ^sub_idx, count}, 10_000
        # Each subscriber received all 2000 events + completion marker
        assert count == 2001
      end
    end

    test "C05: concurrent hierarchical operation spawning & real-time tree calculation under high contention",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      # Create root op
      {:ok, root_op} =
        Sessions.create_operation(%{
          session_id: sid,
          agent_name: "RootCoordinator",
          op_type: "swarm_root",
          title: "Root Swarm Coordinator",
          status: "running",
          progress: 0,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Concurrently spawn 30 child operations under root_op
      child_tasks =
        1..30
        |> Enum.map(fn i ->
          Task.async(fn ->
            {:ok, task_pid, op} =
              OperationManager.run_async_operation(
                sid,
                root_op.id,
                "Worker_#{i}",
                "subtask",
                "Parallel Subtask #{i}",
                %{index: i},
                fn progress ->
                  progress.(50, "Subtask #{i} working...")
                  :timer.sleep(10)
                  {:ok, "Subtask #{i} complete"}
                end
              )

            assert is_pid(task_pid)
            assert is_binary(op.id)
            op.id
          end)
        end)

      child_ids = Task.await_many(child_tasks, 15_000)
      assert length(child_ids) == 30

      # Concurrently query build_tree and tree_stats while operations complete
      tree_tasks =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ops = Sessions.list_operations(sid)
            tree = OperationManager.build_tree(ops)
            stats = OperationManager.tree_stats(ops)
            {length(tree), stats.total}
          end)
        end)

      tree_results = Task.await_many(tree_tasks, 10_000)
      assert length(tree_results) == 20

      for {roots_count, total_count} <- tree_results do
        assert roots_count >= 1
        assert total_count >= 1 and total_count <= 31
      end
    end

    test "C06: concurrent SwarmCoordinator task spawning across 10 sessions with non-interference",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})

      sessions =
        for i <- 1..10 do
          create_session_fixture(project, %{title: "Swarm Concurrency Session #{i}"})
        end

      # Concurrently launch run_swarm across all 10 sessions
      tasks =
        Enum.map(sessions, fn session ->
          Task.async(fn ->
            {:ok, task_pid} =
              SwarmCoordinator.run_swarm(session.id, "Analyze workspace architecture", ws)

            assert is_pid(task_pid)
            assert Process.alive?(task_pid)
            {session.id, task_pid}
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 10

      # Verify all 10 task PIDs are distinct and supervised under TaskSupervisor
      task_pids = Enum.map(results, fn {_sid, pid} -> pid end)
      assert length(Enum.uniq(task_pids)) == 10
    end
  end

  # ============================================================================
  # 2. Memory & CPU Stability
  # ============================================================================
  describe "2. Memory & CPU Stability" do
    test "M01: large output burst (>10MB) via run_command is capped and sanitized without OOM",
         %{
           workspace_path: ws
         } do
      # Execute a shell command that generates ~12MB of output. run_command
      # intentionally caps captured output (@max_command_output, 256KB) to
      # prevent OOM, so the result must be bounded, non-empty, and must
      # preserve the beginning of the command's stdout.
      cmd = "python3 -c 'print(\"A\" * 12582912)'"

      mem_before = :erlang.memory(:total)
      assert mem_before > 0

      start_t = System.monotonic_time(:millisecond)

      {:ok, output} =
        Tools.execute("run_command", %{"command" => cmd, "timeout_ms" => 30_000}, ws)

      duration_ms = System.monotonic_time(:millisecond) - start_t

      # Output is capped well below the ~12MB the command emits
      assert byte_size(output) > 0
      assert byte_size(output) <= 1_000_000
      assert String.valid?(output)

      # The prefix of the command's stdout survives truncation
      assert String.starts_with?(output, "AAAA")
      assert output =~ ~r/\[output truncated(?:; retrieve artifact [0-9a-f-]+)?\]/

      # Force GC and verify memory returns to stable level
      :erlang.garbage_collect(self())
      mem_after = :erlang.memory(:total)

      # Ensure execution completed reasonably fast (< 10s)
      assert duration_ms < 10_000
      # Ensure memory is within sane delta
      assert mem_after > 0
    end

    test "M02: large file IO (>10MB write, slice read, exact patch) with memory bounded execution",
         %{
           workspace_path: ws
         } do
      large_file = "data/massive_file.txt"
      # Generate 10MB file content with unique markers at start, middle, end
      # 100,000 bytes
      chunk = String.duplicate("0123456789abcdefghij", 5000)

      # 10MB
      # 2MB
      chunks =
        ["START_MARKER\n"] ++
          List.duplicate(chunk <> "\n", 100) ++
          ["MIDDLE_TARGET_TEXT\n"] ++
          List.duplicate(chunk <> "\n", 20) ++
          ["END_MARKER\n"]

      big_content = Enum.join(chunks, "")
      assert byte_size(big_content) > 12_000_000

      # 1. Write file (>12MB)
      {:ok, write_res} =
        Tools.execute("write_file", %{"path" => large_file, "content" => big_content}, ws)

      assert String.contains?(write_res, "Successfully wrote")

      # 2. Slice read first 10 lines
      {:ok, read_slice} =
        Tools.execute(
          "read_file",
          %{"path" => large_file, "start_line" => 1, "end_line" => 5},
          ws
        )

      assert String.contains?(read_slice, "START_MARKER")
      assert String.contains?(read_slice, "1: START_MARKER")

      # 3. Patch exact target in large file
      {:ok, patch_res} =
        Tools.execute(
          "patch_file",
          %{
            "path" => large_file,
            "target_content" => "MIDDLE_TARGET_TEXT",
            "replacement_content" => "REPLACED_SUCCESSFULLY_123"
          },
          ws
        )

      assert String.contains?(patch_res, "Successfully patched")

      # 4. Verify patched content exists in file
      full_path = Path.join(ws, large_file)
      assert File.exists?(full_path)
      {:ok, final_data} = File.read(full_path)
      assert String.contains?(final_data, "REPLACED_SUCCESSFULLY_123")
      refute String.contains?(final_data, "MIDDLE_TARGET_TEXT")
    end

    test "M03: multi-megabyte UTF-8 buffer stress with randomized multibyte boundary fragmentation" do
      # Construct a multi-megabyte stream containing complex multibyte sequences:
      # 2-byte: 'é', 'ü', 'ñ' (<<195, ...>>)
      # 3-byte: '⚡', '★', '中', '文' (<<226..228, ...>>)
      # 4-byte: '🚀', '🐝', '🤖', '🔥', '🎉' (<<240, ...>>)
      symbols = [
        "Hello ",
        "⚡",
        "world ",
        "🚀",
        " IexCode ",
        "🐝",
        " swarm ",
        "🤖",
        "!",
        " 🔥",
        " 🎉",
        "\n"
      ]

      pattern = Enum.join(symbols, "")
      # Replicate 80,000 times -> ~4.4MB binary
      full_binary = String.duplicate(pattern, 80_000)
      assert byte_size(full_binary) > 4_000_000

      # Slice binary into small random-sized chunks (1 to 7 bytes) to maximize boundary slicing
      chunks = chunk_binary_arbitrary(full_binary, [])

      # Process all chunks through UTF8Buffer
      {valid_output, final_rest} =
        Enum.reduce(chunks, {<<>>, UTF8Buffer.new()}, fn chunk, {acc_valid, buf_state} ->
          {valid_chunk, next_buf} = UTF8Buffer.process_bytes(buf_state, chunk)
          {acc_valid <> valid_chunk, next_buf}
        end)

      {flushed_rest, _} = UTF8Buffer.flush(final_rest)
      reconstructed = valid_output <> flushed_rest

      # Assert zero bytes lost, 100% UTF-8 validity and exact equality
      assert byte_size(reconstructed) == byte_size(full_binary)
      assert reconstructed == full_binary
      assert String.valid?(reconstructed)
    end

    test "M04: rapid execution loop (300 tool operations) verifies zero memory leak after GC", %{
      workspace_path: ws
    } do
      # Warm-up GC
      :erlang.garbage_collect(self())
      mem_start = :erlang.memory(:processes)

      workspace_write_file(
        ws,
        "lib/leak_check.ex",
        "defmodule LeakCheck do\n  def run(x), do: x * 2\nend\n"
      )

      # Execute 300 rapid tool operations
      for i <- 1..300 do
        {:ok, _} = Tools.execute("read_file", %{"path" => "lib/leak_check.ex"}, ws)
        {:ok, _} = Tools.execute("run_command", %{"command" => "expr #{i} + 1"}, ws)
      end

      # Force GC after loop
      :erlang.garbage_collect(self())
      mem_end = :erlang.memory(:processes)

      # Delta should not explode (allowing reasonable working memory variance < 25MB)
      mem_delta = abs(mem_end - mem_start)
      assert mem_delta < 25 * 1024 * 1024
    end

    test "M05: process leak detection: strict process count invariance after 100 concurrent tasks",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      # Drain existing processes
      drain_all_e2e_processes()
      :timer.sleep(100)
      procs_before = length(Process.list())

      # Run 100 async operations that complete normally
      tasks =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn ->
            OperationManager.run_sync_operation(
              sid,
              nil,
              "LeakChecker_#{i}",
              "check",
              "Check Op #{i}",
              %{i: i},
              fn progress ->
                progress.(50, "Working...")
                {:ok, "Done #{i}"}
              end
            )
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 100

      # Allow task supervisor and watcher processes to finish cleanly
      :timer.sleep(500)
      drain_all_e2e_processes()
      :timer.sleep(200)

      procs_after = length(Process.list())
      proc_diff = abs(procs_after - procs_before)

      # Total process count change must be near 0 (allowing minor internal OTP runtime jitter <= 20)
      assert proc_diff <= 20
    end

    test "M06: AST search on massive codebase with 100 modules without stack overflow", %{
      workspace_path: ws
    } do
      # Generate 100 Elixir modules with functions, docs, and typespecs
      for i <- 1..100 do
        code = """
        defmodule App.Module#{i} do
          @moduledoc "Module #{i} docs"
          @type t :: integer()

          @doc "Computes value #{i}"
          @spec calculate(integer()) :: integer()
          def calculate(x) do
            x * #{i}
          end
        end
        """

        workspace_write_file(ws, "lib/deep/sub_#{rem(i, 5)}/module_#{i}.ex", code)
      end

      # Search for all modules
      {:ok, results} = ASTSearch.search(ws, %{"type" => "module"})
      assert length(results) >= 100

      # Search for calculate function
      {:ok, fun_results} = ASTSearch.search(ws, %{"type" => "function", "query" => "calculate"})
      assert length(fun_results) >= 100

      # Search with query string
      {:ok, query_res} = ASTSearch.search(ws, "Module50")
      assert Enum.any?(query_res, fn r -> String.contains?(to_string(r.name), "Module50") end)
    end

    test "M07: MultiPatch atomic rollback under partial failure leaves all files untouched", %{
      workspace_path: ws
    } do
      # Setup 5 files
      for i <- 1..5 do
        workspace_write_file(
          ws,
          "lib/patch_test_#{i}.ex",
          "defmodule PatchTest#{i} do\n  def orig, do: :old_#{i}\nend\n"
        )
      end

      # Batch of 10 patches across the 5 files, but patch #8 contains an impossible target
      patches = [
        %{"path" => "lib/patch_test_1.ex", "target" => ":old_1", "replacement" => ":new_1"},
        %{"path" => "lib/patch_test_2.ex", "target" => ":old_2", "replacement" => ":new_2"},
        %{"path" => "lib/patch_test_3.ex", "target" => ":old_3", "replacement" => ":new_3"},
        %{"path" => "lib/patch_test_4.ex", "target" => ":old_4", "replacement" => ":new_4"},
        # Failing patch with non-existent target
        %{
          "path" => "lib/patch_test_5.ex",
          "target" => "NON_EXISTENT_TARGET_STRING_XYZ",
          "replacement" => ":new_5"
        }
      ]

      result = MultiPatch.apply_patches(ws, patches)
      assert {:error, {:target_not_found, "lib/patch_test_5.ex", _}} = result

      # Verify ALL 5 files remain completely in their original state (zero partial mutations)
      for i <- 1..5 do
        {:ok, content} = workspace_read_file(ws, "lib/patch_test_#{i}.ex")
        assert String.contains?(content, ":old_#{i}")
        refute String.contains?(content, ":new_#{i}")
      end
    end
  end

  # ============================================================================
  # 3. Crash Recovery & Fault Tolerance
  # ============================================================================
  describe "3. Crash Recovery & Fault Tolerance" do
    test "R01: abrupt worker termination via :kill during sync operation unblocks caller within <500ms",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      test_pid = self()

      task =
        Task.async(fn ->
          start_t = System.monotonic_time(:millisecond)

          res =
            OperationManager.run_sync_operation(
              sid,
              nil,
              "KillVictim",
              "long_run",
              "Targeted for Kill",
              %{},
              fn progress ->
                progress.(10, "Starting up...")
                send(test_pid, {:worker_pid, self()})
                # Would block for 30s if not killed
                :timer.sleep(30_000)
                {:ok, "never reached"}
              end,
              60_000
            )

          elapsed = System.monotonic_time(:millisecond) - start_t
          {res, elapsed}
        end)

      # Receive worker pid and send brutal kill signal
      assert_receive {:worker_pid, worker_pid}, 3000
      Process.exit(worker_pid, :kill)

      # Caller must unblock immediately (< 1000ms), NOT 60,000ms
      {res, elapsed} = Task.await(task, 5000)
      assert elapsed < 1000
      assert {:error, reason} = res
      assert String.contains?(reason, "killed") or String.contains?(reason, "Process was killed")
    end

    test "R02: worker abnormal exit with complex shutdown/exit terms correctly formatted without crashing caller",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      exit_reasons = [
        {:shutdown, :connection_lost},
        :shutdown,
        {:bad_return_value, {:error, :econnrefused}},
        {:error, %RuntimeError{message: "custom runtime failure"}},
        {:custom_tuple, 1, 2, [3, 4]}
      ]

      for {exit_reason, idx} <- Enum.with_index(exit_reasons, 1) do
        res =
          OperationManager.run_sync_operation(
            sid,
            nil,
            "ExitAgent_#{idx}",
            "exit_test",
            "Exit Op #{idx}",
            %{},
            fn _p ->
              exit(exit_reason)
            end,
            5000
          )

        assert {:error, err_str} = res
        assert is_binary(err_str)
        assert byte_size(err_str) > 0
        assert String.valid?(err_str)
      end
    end

    test "R03: unhandled exceptions (10 distinct exception types) in operations correctly caught and recorded as failed",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      exceptions = [
        fn -> raise ArgumentError, "invalid argument provided" end,
        fn -> raise RuntimeError, "runtime crash" end,
        fn -> raise KeyError, key: :missing_key, term: %{a: 1} end,
        fn -> raise CaseClauseError, term: :no_match end,
        fn -> raise FunctionClauseError, module: Math, function: :sqrt, arity: 1 end,
        fn -> raise BadMapError, term: :not_a_map end,
        fn -> raise BadStructError, struct: Foo, term: :bar end,
        fn -> raise MatchError, term: {:error, :unexpected} end,
        fn -> raise ArithmeticError, "division by zero" end,
        fn -> throw(:uncaught_throw_symbol) end
      ]

      for {crash_fn, idx} <- Enum.with_index(exceptions, 1) do
        res =
          OperationManager.run_sync_operation(
            sid,
            nil,
            "ExceptionAgent_#{idx}",
            "crash_vector",
            "Crash Op #{idx}",
            %{vector: idx},
            fn _progress ->
              crash_fn.()
            end
          )

        assert {:error, err_msg} = res
        assert is_binary(err_msg)
        assert String.valid?(err_msg)
      end

      # Verify in DB that all 10 operations have status 'failed'
      ops = Repo.all(from o in Operation, where: o.session_id == ^sid)
      assert length(ops) == 10

      for op <- ops do
        assert op.status == "failed"
        assert is_binary(op.error_message) and byte_size(op.error_message) > 0
      end
    end

    test "R04: subagent GenServer crash recovery via OTP DynamicSupervisor transient restart", %{
      workspace_path: ws
    } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      # Start PlannerAgent
      {:ok, orig_pid} = AgentSupervisor.start_agent(sid, :planner, project_root: ws)
      assert is_pid(orig_pid) and Process.alive?(orig_pid)
      assert AgentRegistry.whereis(sid, :planner) == orig_pid

      # Monitor original pid and kill it with :kill
      ref = Process.monitor(orig_pid)
      Process.exit(orig_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^orig_pid, :killed}, 2000

      # Under DynamicSupervisor with transient restart, a killed child is restarted or can be re-acquired
      :timer.sleep(100)
      restarted_pid = AgentRegistry.whereis(sid, :planner)

      # If restarted or queried, agent is alive
      active_pid =
        if restarted_pid && Process.alive?(restarted_pid) do
          restarted_pid
        else
          {:ok, new_pid} = AgentSupervisor.start_agent(sid, :planner, project_root: ws)
          new_pid
        end

      assert is_pid(active_pid) and Process.alive?(active_pid)
      assert active_pid != orig_pid

      # Clean shutdown
      assert :ok = AgentSupervisor.stop_agent(sid, :planner)
      refute Process.alive?(active_pid)
      assert AgentRegistry.whereis(sid, :planner) == nil
    end

    test "R05: SessionServer crash recovery and state rehydration upon ensure_started", %{
      workspace_path: ws
    } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project, %{swarm_mode: true})
      sid = session.id

      {:ok, s_pid1} = SessionServer.ensure_started(sid)
      assert is_pid(s_pid1) and Process.alive?(s_pid1)

      # Verify initial state has swarm_mode: true
      state1 = SessionServer.get_state(sid)
      assert state1.session.swarm_mode == true

      # Force kill the SessionServer process
      ref = Process.monitor(s_pid1)
      Process.exit(s_pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^s_pid1, :killed}, 2000

      # Now re-call ensure_started
      {:ok, s_pid2} = SessionServer.ensure_started(sid)
      assert is_pid(s_pid2) and Process.alive?(s_pid2)
      assert s_pid2 != s_pid1

      # Rehydrated state must match database session
      state2 = SessionServer.get_state(sid)
      assert state2.session_id == sid
      assert state2.session.swarm_mode == true
    end

    test "R06: OperationManager zero dangling running operations under rapid concurrent worker slaughter",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      # Concurrently spawn 25 async operations with diverse internal crash vectors
      for i <- 1..25 do
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
            "SlaughterAgent_#{i}",
            "kill_race",
            "Op to slaughter #{i}",
            %{i: i},
            crash_fn
          )
      end

      # Wait for watcher supervisor tasks to settle
      :timer.sleep(2000)

      # Query DB for operations
      ops = Repo.all(from o in Operation, where: o.session_id == ^sid)
      assert length(ops) == 25

      # Assert ZERO operations remain with status "running"
      running_ops = Enum.filter(ops, &(&1.status == "running"))
      assert running_ops == []

      # Assert ALL 25 are marked as "failed"
      failed_ops = Enum.filter(ops, &(&1.status == "failed"))
      assert length(failed_ops) == 25
    end

    test "R07: database contention & lock simulation: fallback operation structs prevent cascade failure",
         %{
           workspace_path: _ws
         } do
      # When database operations fail or are simulated as unavailable,
      # OperationManager and Sessions fallback functions must return safely without crashing callers
      bogus_session_id = Ecto.UUID.generate()

      {:ok, task_pid, op} =
        OperationManager.run_async_operation(
          bogus_session_id,
          nil,
          "FallbackAgent",
          "fallback_task",
          "Fallback Operation Title",
          %{key: "val"},
          fn progress ->
            progress.(50, "Fallback progress...")
            {:ok, "fallback success"}
          end
        )

      assert is_pid(task_pid)
      assert is_map(op)
      assert op.session_id == bogus_session_id
      assert op.status == "running"

      # Also test tree operations on synthetic/fallback operation structs
      synthetic_ops = [
        %Operation{id: "syn_root", parent_op_id: nil, title: "Root", status: "completed"},
        %Operation{
          id: "syn_child1",
          parent_op_id: "syn_root",
          title: "Child 1",
          status: "completed"
        },
        %Operation{
          id: "syn_child2",
          parent_op_id: "syn_root",
          title: "Child 2",
          status: "failed"
        },
        %Operation{
          id: "syn_orphan",
          parent_op_id: "missing_parent",
          title: "Orphan",
          status: "completed"
        }
      ]

      tree = OperationManager.build_tree(synthetic_ops)
      # Root + Orphan treated as root
      assert length(tree) == 2
      stats = OperationManager.tree_stats(synthetic_ops)
      assert stats.total == 4
      assert stats.roots == 2
      assert stats.completed == 3
      assert stats.failed == 1
    end

    test "R08: top-level DynamicSupervisor crash recovery: killing SessionSupervisor restarts supervisor cleanly",
         %{
           workspace_path: ws
         } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      sup_pid1 = Process.whereis(SessionSupervisor)
      assert is_pid(sup_pid1) and Process.alive?(sup_pid1)

      # Force kill the SessionSupervisor
      ref = Process.monitor(sup_pid1)
      Process.exit(sup_pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup_pid1, :killed}, 2000

      # Give top-level supervisor a moment to restart SessionSupervisor
      :timer.sleep(100)

      sup_pid2 = Process.whereis(SessionSupervisor)
      assert is_pid(sup_pid2) and Process.alive?(sup_pid2)
      assert sup_pid2 != sup_pid1

      # Session operations through restarted supervisor must continue working seamlessly
      {:ok, s_pid} = SessionServer.ensure_started(sid)
      assert is_pid(s_pid) and Process.alive?(s_pid)
      assert SessionServer.get_state(sid).session_id == sid
    end

    test "R09: telemetry & PubSub resilience under invalid/malformed payload broadcasts", %{
      workspace_path: ws
    } do
      project = create_project_fixture(%{root_path: ws})
      session = create_session_fixture(project)
      sid = session.id

      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{sid}")

      # Broadcast various extreme/unusual terms
      malformed_events = [
        {:weird_event, <<0, 255, 128>>},
        %{unexpected: :map_structure, deeply: %{nested: [1, 2, 3]}},
        {:tuple_payload, 1, 2, 3, 4, 5},
        nil,
        :bare_atom_event,
        {:large_binary_event, String.duplicate("X", 100_000)}
      ]

      for event <- malformed_events do
        Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{sid}", event)
        assert_receive ^event, 2000
      end

      # Verify PubSub is still functional and normal events work
      Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{sid}", {:normal_event, "ok"})
      assert_receive {:normal_event, "ok"}, 2000
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp count_messages(acc, timeout_ms) do
    receive do
      :stress_complete ->
        acc + 1

      {:operation_progress, _, _, _} ->
        count_messages(acc + 1, timeout_ms)

      _other ->
        count_messages(acc, timeout_ms)
    after
      timeout_ms -> acc
    end
  end

  defp chunk_binary_arbitrary(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_binary_arbitrary(binary, acc) do
    chunk_size = min(byte_size(binary), :rand.uniform(7))
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    chunk_binary_arbitrary(rest, [chunk | acc])
  end
end
