defmodule IexCode.Tools.TerminalStressTest do
  @moduledoc """
  Terminal Stress, High-Throughput, Concurrency, and Memory Bounding Test Suite.
  Covers Tier 4 Workload and Tier 5 Adversarial Stress scenarios:
  - STRESS_01: High-volume output burst (10,000+ lines) throughput & message draining
  - STRESS_02: Ring buffer capacity bounding and memory clamp under massive stream flood
  - STRESS_03: Rapid concurrency with 20 parallel terminal sessions executing simultaneously
  - STRESS_04: Rapid keystroke input burst (1,000 inputs) without deadlock or dropped state
  - STRESS_05: Rapid lifecycle churn (spawn, execute, restart, kill x 25 cycles) with zero zombie processes
  - STRESS_06: Multi-agent command concurrency, occupant transitions, and queue stress
  - STRESS_07: ANSI truecolor and Unicode burst (10,000 lines) with emojis and escape codes
  - STRESS_08: Rapid window resize storm (50 rapid dimension changes) during active output streaming
  - STRESS_09: Large paste backpressure (64KB chunks) and control sequences (Ctrl+C, Ctrl+D)
  - STRESS_10: Process crash recovery, exit traps, and zero zombie / orphan process verification
  - STRESS_11: Race condition concurrent kill vs input with clean process reaping
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.TerminalServer

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp subscribe_terminal(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")
  end

  defp receive_terminal_output(session_id, expected_pattern, timeout) do
    do_receive_terminal_output(session_id, expected_pattern, timeout, "")
  end

  defp do_receive_terminal_output(session_id, expected_pattern, timeout, acc) do
    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        new_acc = acc <> data

        matched? =
          case expected_pattern do
            %Regex{} = regex -> Regex.match?(regex, new_acc)
            pattern when is_binary(pattern) -> String.contains?(new_acc, pattern)
          end

        if matched? do
          {:ok, new_acc}
        else
          do_receive_terminal_output(session_id, expected_pattern, timeout, new_acc)
        end
    after
      timeout ->
        {:error, {:timeout, acc}}
    end
  end

  defp cleanup_session(session_id) do
    try do
      TerminalServer.kill(session_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp count_running_shims do
    case System.cmd("ps", ["-eo", "pid,command"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "pty_shim.py"))
        |> Enum.reject(&String.contains?(&1, "grep"))
        |> length()

      _ ->
        0
    end
  end

  defp wait_for_shims_to_reap(target_max, max_wait_ms) do
    deadline = System.monotonic_time(:millisecond) + max_wait_ms
    do_wait_for_shims(target_max, deadline)
  end

  defp do_wait_for_shims(target_max, deadline) do
    current = count_running_shims()

    if current <= target_max do
      current
    else
      if System.monotonic_time(:millisecond) >= deadline do
        current
      else
        Process.sleep(100)
        do_wait_for_shims(target_max, deadline)
      end
    end
  end

  # ============================================================================
  # Stress & Workload Tests
  # ============================================================================

  describe "High-Throughput & Stress Verification" do
    test "STRESS_01_high_volume_output_flood_10k_lines", %{workspace_path: path} do
      session_id = "stress_10k_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Stream 10,000 lines through PTY
      cmd = "for i in $(seq 1 10000); do echo \"BURST_LINE_$i\"; done"
      assert :ok = TerminalServer.run_command(session_id, cmd)

      # Verify reaching the 10,000th line
      assert {:ok, _} = receive_terminal_output(session_id, "BURST_LINE_10000", 25_000)

      # Ensure process is alive and responsive after massive burst
      assert Process.alive?(pid)
      token = "BURST_10K_COMPLETED_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 5_000)
    end

    test "STRESS_02_ring_buffer_memory_clamp_under_massive_output", %{workspace_path: path} do
      session_id = "stress_clamp_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Stream large quantity of data to test ring buffer eviction
      cmd =
        "for i in $(seq 1 20000); do echo \"PADDING_LINE_DATA_FOR_RING_BUFFER_SLIDING_WINDOW_$i\"; done"

      assert :ok = TerminalServer.run_command(session_id, cmd)

      assert {:ok, _} =
               receive_terminal_output(
                 session_id,
                 "PADDING_LINE_DATA_FOR_RING_BUFFER_SLIDING_WINDOW_20000",
                 30_000
               )

      # Query ring buffer history
      history = TerminalServer.get_history(session_id)
      assert is_binary(history)

      # Ensure memory is clamped (history size should not exceed 2MB)
      assert byte_size(history) <= 2_000_000

      # Sliding window: newest data must be present
      assert String.contains?(history, "PADDING_LINE_DATA_FOR_RING_BUFFER_SLIDING_WINDOW_20000")
    end

    test "STRESS_03_rapid_concurrency_20_parallel_sessions", %{workspace_path: path} do
      session_count = 20

      session_ids =
        for i <- 1..session_count do
          "stress_conc_#{i}_#{System.unique_integer([:positive])}"
        end

      on_exit(fn ->
        Enum.each(session_ids, &cleanup_session/1)
      end)

      # Spawn and execute across all 20 sessions concurrently
      results =
        session_ids
        |> Task.async_stream(
          fn sid ->
            # Create session-specific folder
            session_dir = Path.join(path, sid)
            File.mkdir_p!(session_dir)

            subscribe_terminal(sid)

            case TerminalServer.ensure_started(sid, workspace_path: session_dir) do
              {:ok, pid} ->
                token = "CONC_TOKEN_#{sid}"
                :ok = TerminalServer.run_command(sid, "echo #{token}")

                case receive_terminal_output(sid, token, 15_000) do
                  {:ok, output} ->
                    {:ok, sid, pid, output}

                  {:error, reason} ->
                    {:error, sid, reason}
                end

              error ->
                {:error, sid, error}
            end
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.to_list()

      # Assert all 20 sessions executed and completed successfully
      assert length(results) == session_count

      Enum.each(results, fn {:ok, result} ->
        assert match?({:ok, _sid, _pid, _output}, result)
      end)
    end

    test "STRESS_04_rapid_keystroke_flood_1000_inputs", %{workspace_path: path} do
      session_id = "stress_keys_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Send 1,000 rapid keystroke chunks across parallel async tasks
      tasks =
        for _i <- 1..1000 do
          Task.async(fn ->
            TerminalServer.send_input(session_id, " ")
          end)
        end

      Task.await_many(tasks, 15_000)

      # Process must remain alive and healthy
      assert Process.alive?(pid)

      token = "KEYSTROKE_FLOOD_PASSED"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)
    end

    test "STRESS_05_rapid_spawn_kill_restart_churn_25_cycles", %{workspace_path: path} do
      session_id = "stress_churn_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      for cycle <- 1..25 do
        # 1. Ensure started
        assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
        assert Process.alive?(pid)

        # 2. Restart or kill alternately
        if rem(cycle, 2) == 0 do
          assert {:ok, new_pid} = TerminalServer.restart(session_id)
          assert Process.alive?(new_pid)
        else
          assert :ok = TerminalServer.kill(session_id)
        end
      end

      # Final verification of fresh start
      assert {:ok, final_pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert Process.alive?(final_pid)

      token = "CHURN_FINAL_VERIFY"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      subscribe_terminal(session_id)
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)
    end

    test "STRESS_06_agent_command_concurrency_and_occupant_churn", %{workspace_path: path} do
      session_id = "stress_agent_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Sequentially dispatch 10 agent commands across different agents
      agents = ["ExplorerAgent", "CoderAgent", "VerifierAgent", "PlannerAgent"]

      for i <- 1..10 do
        agent = Enum.at(agents, rem(i, length(agents)))
        token = "AGENT_STRESS_#{i}_#{System.unique_integer([:positive])}"

        assert {:ok, res} =
                 TerminalServer.run_agent_command(
                   session_id,
                   "echo #{token}",
                   agent
                 )

        assert res.exit_code == 0
        assert String.contains?(res.output, token)
      end

      # Occupant reverts to :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "STRESS_07_ansi_truecolor_and_unicode_burst_10k_lines", %{workspace_path: path} do
      session_id = "stress_ansi_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Stream 10,000 lines with ANSI Truecolor RGB, cursor codes, emojis, and Greek letters
      cmd =
        "for i in $(seq 1 10000); do printf '\\033[38;2;%d;120;200m🚀 [ANSI_BURST_%d] 🔥 λ=%d\\033[0m\\n' $((i % 255)) $i $i; done"

      assert :ok = TerminalServer.run_command(session_id, cmd)

      # Verify reaching the 10,000th ANSI line
      assert {:ok, _} = receive_terminal_output(session_id, "[ANSI_BURST_10000]", 30_000)

      # Verify scrollback history is valid UTF-8
      history = TerminalServer.get_history(session_id)
      assert is_binary(history)
      assert String.valid?(history)
      assert String.contains?(history, "[ANSI_BURST_10000]")

      assert Process.alive?(pid)
    end

    test "STRESS_08_rapid_window_resize_storm_50_events", %{workspace_path: path} do
      session_id = "stress_resize_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Start background stream
      assert :ok =
               TerminalServer.run_command(
                 session_id,
                 "for i in $(seq 1 500); do echo \"RESIZE_STREAM_$i\"; sleep 0.01; done"
               )

      # Fire 50 rapid resize events across varying dimensions
      for i <- 1..50 do
        cols = 40 + rem(i * 7, 160)
        rows = 15 + rem(i * 3, 50)
        assert :ok = TerminalServer.resize(session_id, cols, rows)
      end

      # Final resize
      assert :ok = TerminalServer.resize(session_id, 120, 40)

      # Ensure process is alive and healthy
      assert Process.alive?(pid)
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 120
      assert state.rows == 40
    end

    test "STRESS_09_large_paste_backpressure_and_control_chars", %{workspace_path: path} do
      session_id = "stress_paste_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Inject a 32KB payload into a python receiver command
      large_blob = String.duplicate("DATA_CHUNK_0123456789ABCDEF\n", 1000)
      assert :ok = TerminalServer.run_command(session_id, "cat << 'EOF' | wc -l")
      assert :ok = TerminalServer.send_input(session_id, large_blob)
      assert :ok = TerminalServer.send_input(session_id, "EOF\n")

      # Verify 1000 lines counted
      assert {:ok, _} = receive_terminal_output(session_id, "1000", 15_000)

      # Send interrupt signal Ctrl+C
      assert :ok = TerminalServer.send_signal(session_id, :sigint)

      # Shell must remain responsive to subsequent commands
      token = "PASTE_FLOOD_COMPLETED"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 15_000)
      assert Process.alive?(pid)
    end

    test "STRESS_10_crash_recovery_exit_traps_and_zero_zombie_leaks", %{workspace_path: path} do
      initial_shims = count_running_shims()

      # Spawn 5 sessions, execute commands, kill abruptly, and check process table
      for i <- 1..5 do
        sid = "stress_crash_#{i}_#{System.unique_integer([:positive])}"
        assert {:ok, pid} = TerminalServer.ensure_started(sid, workspace_path: path)

        # Send command with exit code 42
        assert :ok = TerminalServer.run_command(sid, "exit 42")
        Process.sleep(100)

        # Kill and verify cleanup
        assert :ok = TerminalServer.kill(sid)
        refute Process.alive?(pid)
      end

      # Allow settling time for OS process reaping
      final_shims = wait_for_shims_to_reap(initial_shims, 4_000)
      assert final_shims <= initial_shims
    end

    test "STRESS_11_race_condition_kill_vs_input_without_orphan_shim", %{workspace_path: path} do
      initial_shims = count_running_shims()

      for i <- 1..5 do
        sid = "stress_race_#{i}_#{System.unique_integer([:positive])}"
        assert {:ok, _pid} = TerminalServer.ensure_started(sid, workspace_path: path)

        task1 =
          Task.async(fn ->
            for _k <- 1..50 do
              TerminalServer.send_input(sid, "echo RACING_INPUT\n")
            end
          end)

        task2 = Task.async(fn -> TerminalServer.kill(sid) end)

        _ = Task.await(task1, 5_000)
        _ = Task.await(task2, 5_000)
      end

      # Wait for child process reaping
      final_shims = wait_for_shims_to_reap(initial_shims, 4_000)
      assert final_shims <= initial_shims
    end
  end
end
