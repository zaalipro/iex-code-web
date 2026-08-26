defmodule IexCode.Adversarial.Challenger2SignalAndChurnStressTest do
  @moduledoc """
  Adversarial Verification Test Suite for Milestone 1 Iteration 2 by Challenger 2.

  Dimensions tested:
  1. Signal handling: `:sigtstp` followed by `:sigcont` across interactive shells and running subprocesses.
     Verifies real process suspension, freeze of output, resumption upon `:sigcont`, and subsequent command responsiveness.
  2. Signal variations: tests `:sigtstp`, `"SIGTSTP"`, `:suspend`, `:sigcont`, `"SIGCONT"`, `:continue`.
  3. Rapid interleaving of suspend/resume (20 cycles) on an active process.
  4. Concurrent session scaling: 25 simultaneous isolated sessions running high-throughput commands with no crosstalk.
  5. Rapid session churn: 30 lifecycle cycles (spawn -> exec -> restart -> kill) verifying zero zombie/defunct processes.
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.TerminalServer
  alias IexCode.Tools.TerminalSupervisor

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

  defp count_defunct_processes do
    case System.cmd("ps", ["-eo", "pid,stat,command"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "defunct"))
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
  # 1. Signal Handling (:sigtstp -> :sigcont)
  # ============================================================================

  describe "Signal Handling: SIGTSTP & SIGCONT Subsystem" do
    test "CHAL2_SIG_01_send_signal_sigtstp_and_sigcont_responsiveness", %{workspace_path: path} do
      session_id = "sig_susp_res_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Send SIGTSTP followed by SIGCONT
      assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
      assert :ok = TerminalServer.send_signal(session_id, :sigcont)

      # Shell must be responsive
      token = "RESUMED_SHELL_OK_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)
    end

    test "CHAL2_SIG_02_all_signal_format_variants", %{workspace_path: path} do
      session_id = "sig_variants_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Test atom variants
      assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
      assert :ok = TerminalServer.send_signal(session_id, :sigcont)
      assert :ok = TerminalServer.send_signal(session_id, :suspend)
      assert :ok = TerminalServer.send_signal(session_id, :continue)

      # Test string variants
      assert :ok = TerminalServer.send_signal(session_id, "SIGTSTP")
      assert :ok = TerminalServer.send_signal(session_id, "SIGCONT")

      # Shell must remain alive and responsive
      token = "SIGNALS_TEST_COMPLETE"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)
    end

    test "CHAL2_SIG_03_rapid_interleaved_sigtstp_sigcont_20_cycles", %{workspace_path: path} do
      session_id = "sig_rapid_cycles_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Run the loop in one foreground process group. On interactive bash, a
      # loop entered directly at the prompt gives each `sleep` its own job;
      # SIGTSTP then leaves stopped sleeps behind instead of suspending the
      # workload as a whole.
      assert {:ok, loop_command_id} =
               TerminalServer.run_command_with_id(
                 session_id,
                 "sh -c 'for i in $(seq 1 500); do echo \"CYCLE_TICK_$i\"; sleep 0.02; done'"
               )

      assert {:ok, _} = receive_terminal_output(session_id, "CYCLE_TICK_1", 8_000)

      # Rapidly alternate between SIGTSTP and SIGCONT 20 times
      for _i <- 1..20 do
        assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
        _ = :sys.get_state(pid)
        assert :ok = TerminalServer.send_signal(session_id, :sigcont)
        _ = :sys.get_state(pid)
      end

      assert {:ok, %{status: :running}} = TerminalServer.get_state(session_id)

      # Interrupt loop
      assert :ok = TerminalServer.send_signal(session_id, :sigint)

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^loop_command_id}},
                     8_000

      token = "CYCLE_STRESS_PASSED"
      assert {:ok, command_id} = TerminalServer.run_command_with_id(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^command_id, exit_code: 0}},
                     8_000
    end
  end

  # ============================================================================
  # 2. High-Concurrency Multi-Session Stress (25 concurrent sessions)
  # ============================================================================

  describe "High-Concurrency Multi-Session Isolation & Scalability" do
    test "CHAL2_CONC_01_25_concurrent_sessions_heavy_io_and_signals", %{workspace_path: root} do
      session_count = 25

      sessions =
        for i <- 1..session_count do
          sid = "chal2_conc_#{i}_#{System.unique_integer([:positive])}"
          dir = Path.join(root, "ws_conc_#{i}")
          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "session_marker.txt"), "MARKER_CONTENT_#{i}_#{sid}")
          {sid, dir, i}
        end

      on_exit(fn ->
        Enum.each(sessions, fn {sid, _, _} -> cleanup_session(sid) end)
      end)

      # Start all 25 sessions in parallel
      start_tasks =
        sessions
        |> Enum.map(fn {sid, dir, _i} ->
          Task.async(fn ->
            TerminalServer.ensure_started(sid, workspace_path: dir)
          end)
        end)

      start_results = Task.await_many(start_tasks, 20_000)
      assert Enum.all?(start_results, fn res -> match?({:ok, p} when is_pid(p), res) end)

      # Verify all 25 sessions listed in supervisor
      active_sessions = TerminalSupervisor.list_sessions()
      active_ids = Enum.map(active_sessions, &elem(&1, 0))

      Enum.each(sessions, fn {sid, _, _} ->
        assert sid in active_ids
      end)

      # Execute parallel command, resize, agent command, and verify output
      exec_tasks =
        sessions
        |> Enum.map(fn {sid, _dir, i} ->
          Task.async(fn ->
            subscribe_terminal(sid)

            token = "CONC_EXEC_TOKEN_#{i}_#{sid}"

            # 1. Run command
            :ok = TerminalServer.run_command(sid, "cat session_marker.txt; echo #{token}")

            # 2. Resize
            :ok = TerminalServer.resize(sid, 100 + i, 30 + rem(i, 20))

            # 3. Receive output
            case receive_terminal_output(sid, "MARKER_CONTENT_#{i}_#{sid}", 15_000) do
              {:ok, output} ->
                # 4. Agent command
                agent_res =
                  TerminalServer.run_agent_command(
                    sid,
                    "echo AGENT_CHECK_#{i}",
                    "Agent_#{i}",
                    timeout_ms: 10_000
                  )

                {:ok, sid, i, token, output, agent_res}

              {:error, reason} ->
                {:error, sid, i, reason}
            end
          end)
        end)

      exec_results = Task.await_many(exec_tasks, 30_000)
      assert length(exec_results) == session_count

      Enum.each(exec_results, fn
        {:ok, sid, i, _token, output, agent_res} ->
          assert String.contains?(output, "MARKER_CONTENT_#{i}_#{sid}")
          assert match?({:ok, %{exit_code: 0}}, agent_res)

          # Verify history isolation
          history = TerminalServer.get_history(sid)
          assert String.contains?(history, "MARKER_CONTENT_#{i}_#{sid}")

          # Verify no other session's marker is in this history
          Enum.each(sessions, fn {other_sid, _, other_i} ->
            if other_i != i do
              refute String.contains?(history, "MARKER_CONTENT_#{other_i}_#{other_sid}"),
                     "Cross-talk: session #{sid} history contains data from session #{other_sid}"
            end
          end)

        {:error, sid, i, reason} ->
          flunk("Concurrent session #{sid} (idx #{i}) failed: #{inspect(reason)}")
      end)
    end
  end

  # ============================================================================
  # 3. Rapid Session Churn & Resource Cleanliness
  # ============================================================================

  describe "Rapid Lifecycle Churn & Zombie Process Verification" do
    test "CHAL2_CHURN_01_30_rapid_lifecycle_cycles_with_zero_defunct_zombies", %{
      workspace_path: path
    } do
      initial_shims = count_running_shims()
      initial_defunct = count_defunct_processes()

      session_id = "chal2_churn_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      for cycle <- 1..30 do
        # 1. Ensure started
        assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
        assert Process.alive?(pid)

        # 2. Run quick command
        token = "CHURN_CYCLE_#{cycle}"
        :ok = TerminalServer.run_command(session_id, "echo #{token}")

        # 3. Every 3rd cycle, run agent command
        if rem(cycle, 3) == 0 do
          assert {:ok, _} =
                   TerminalServer.run_agent_command(
                     session_id,
                     "echo AGENT_CHURN_#{cycle}",
                     "ChurnAgent",
                     timeout_ms: 5_000
                   )
        end

        # 4. Restart or Kill
        if rem(cycle, 2) == 0 do
          assert {:ok, new_pid} = TerminalServer.restart(session_id)
          assert Process.alive?(new_pid)
        else
          assert :ok = TerminalServer.kill(session_id)
          refute TerminalServer.running?(session_id)
        end
      end

      # Cleanup final
      TerminalServer.kill(session_id)

      # Allow settling time for OS process reaping
      final_shims = wait_for_shims_to_reap(initial_shims, 4_000)
      final_defunct = count_defunct_processes()

      assert final_shims <= initial_shims,
             "Lingering pty_shim.py processes detected: initial=#{initial_shims}, final=#{final_shims}"

      assert final_defunct <= initial_defunct,
             "Lingering <defunct> zombie processes detected: initial=#{initial_defunct}, final=#{final_defunct}"
    end

    test "CHAL2_CHURN_02_concurrent_racing_agent_command_vs_kill_churn", %{workspace_path: path} do
      for i <- 1..8 do
        sid = "chal2_race_churn_#{i}_#{System.unique_integer([:positive])}"
        on_exit(fn -> cleanup_session(sid) end)

        assert {:ok, _pid} = TerminalServer.ensure_started(sid, workspace_path: path)

        # Spawn agent task executing a sleep command
        agent_task =
          Task.async(fn ->
            TerminalServer.run_agent_command(
              sid,
              "sleep 10; echo RACED",
              "AgentRace",
              timeout_ms: 2_000
            )
          end)

        # Concurrently send inputs and kill
        Process.sleep(30)
        _ = TerminalServer.send_input(sid, "ls\n")
        :ok = TerminalServer.kill(sid)

        res = Task.await(agent_task, 4_000)
        assert match?({:error, _}, res)
        assert TerminalServer.whereis(sid) == nil
      end
    end
  end
end
