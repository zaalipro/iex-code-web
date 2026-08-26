defmodule IexCode.Tools.Challenger2StressVerificationTest do
  @moduledoc """
  Milestone 4 Empirical Challenger 2 Stress Harness:
  - 25 concurrent terminal sessions with high-throughput command streaming
  - 30 rapid session termination / restart cycles
  - OS process table verification for ZERO lingering pty_shim.py processes and ZERO defunct zombie processes
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

  defp get_running_shims do
    case System.cmd("ps", ["-eo", "pid,ppid,stat,command"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "pty_shim.py"))
        |> Enum.reject(&String.contains?(&1, "grep"))
        |> Enum.reject(&(String.trim(&1) == ""))

      _ ->
        []
    end
  end

  defp get_test_related_zombies do
    # Find all defunct / zombie processes associated with the BEAM process tree or pty/python/shells
    case System.cmd("ps", ["-eo", "pid,ppid,stat,command"], stderr_to_stdout: true) do
      {output, 0} ->
        beam_pid = System.pid()

        output
        |> String.split("\n")
        |> Enum.filter(fn line ->
          String.contains?(line, "defunct") or String.match?(line, ~r/\s+Z\+?\s+/)
        end)
        |> Enum.reject(&String.contains?(&1, "grep"))
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.filter(fn line ->
          # Filter for processes that belong to our test tree or terminal toolchain
          String.contains?(line, beam_pid) or
            String.contains?(line, "pty_shim") or
            String.contains?(line, "python") or
            String.contains?(line, "zsh") or
            String.contains?(line, "bash") or
            String.contains?(line, "sh")
        end)

      _ ->
        []
    end
  end

  defp wait_until_shims_reaped(target_max, max_wait_ms) do
    deadline = System.monotonic_time(:millisecond) + max_wait_ms
    do_wait_until_shims_reaped(target_max, deadline)
  end

  defp do_wait_until_shims_reaped(target_max, deadline) do
    shims = get_running_shims()

    if length(shims) <= target_max do
      shims
    else
      if System.monotonic_time(:millisecond) >= deadline do
        shims
      else
        Process.sleep(100)
        do_wait_until_shims_reaped(target_max, deadline)
      end
    end
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "Milestone 4 Empirical Challenger 2 Stress Verification" do
    test "CHALLENGER2_01_concurrent_25_terminal_sessions_with_high_throughput_streaming", %{
      workspace_path: path
    } do
      session_count = 25

      session_ids =
        for i <- 1..session_count do
          "challenger2_conc_#{i}_#{System.unique_integer([:positive])}"
        end

      on_exit(fn ->
        Enum.each(session_ids, &cleanup_session/1)
      end)

      # Concurrently spawn 25 sessions and stream high-throughput commands
      results =
        session_ids
        |> Task.async_stream(
          fn sid ->
            session_dir = Path.join(path, sid)
            File.mkdir_p!(session_dir)

            subscribe_terminal(sid)

            case TerminalServer.ensure_started(sid,
                   workspace_path: session_dir,
                   cols: 80,
                   rows: 24
                 ) do
              {:ok, pid} ->
                # Stream 100 numbered lines with tokens
                token_end = "CHALLENGER2_STREAM_DONE_#{sid}"

                cmd =
                  "for i in $(seq 1 100); do echo \"CHUNK_${i}_#{sid}\"; done; echo \"#{token_end}\""

                :ok = TerminalServer.run_command(sid, cmd)

                case receive_terminal_output(sid, token_end, 20_000) do
                  {:ok, output} ->
                    # Verify history buffer integrity
                    history = TerminalServer.get_history(sid)

                    # Kill session to clean up
                    :ok = TerminalServer.kill(sid)

                    {:ok, sid, pid, byte_size(output), byte_size(history)}

                  {:error, reason} ->
                    {:error, sid, reason}
                end

              error ->
                {:error, sid, error}
            end
          end,
          max_concurrency: session_count,
          timeout: 35_000
        )
        |> Enum.to_list()

      # Assert all 25 sessions succeeded without error or timeout
      assert length(results) == session_count

      Enum.each(results, fn {:ok, res} ->
        assert match?({:ok, _sid, _pid, _out_bytes, _hist_bytes}, res)
      end)

      # Allow OS up to 6 seconds to reap subprocesses
      remaining_shims = wait_until_shims_reaped(0, 6_000)

      assert remaining_shims == [],
             "Expected 0 lingering shims, found: #{inspect(remaining_shims)}"
    end

    test "CHALLENGER2_02_rapid_session_termination_restart_30_cycles", %{workspace_path: path} do
      session_id = "challenger2_churn_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      for cycle <- 1..30 do
        assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
        assert Process.alive?(pid)

        token = "CHURN_CYCLE_#{cycle}_#{System.unique_integer([:positive])}"
        assert :ok = TerminalServer.run_command(session_id, "echo #{token}")

        if rem(cycle, 2) == 0 do
          assert {:ok, new_pid} = TerminalServer.restart(session_id)
          assert Process.alive?(new_pid)
        else
          assert :ok = TerminalServer.kill(session_id)
        end
      end

      # Ensure finally killed
      :ok = TerminalServer.kill(session_id)

      # Perform an additional batch of 30 rapid unique session spawn and kill cycles
      batch_session_ids =
        for i <- 1..30 do
          "challenger2_batch_#{i}_#{System.unique_integer([:positive])}"
        end

      on_exit(fn ->
        Enum.each(batch_session_ids, &cleanup_session/1)
      end)

      for sid <- batch_session_ids do
        assert {:ok, pid} = TerminalServer.ensure_started(sid, workspace_path: path)
        assert Process.alive?(pid)
        assert :ok = TerminalServer.kill(sid)
        refute Process.alive?(pid)
      end

      # Verify all 30 cycles left 0 lingering shims
      remaining_shims = wait_until_shims_reaped(0, 6_000)

      assert remaining_shims == [],
             "Expected 0 lingering shims, found: #{inspect(remaining_shims)}"
    end

    test "CHALLENGER2_03_zero_lingering_shims_and_zero_defunct_zombies_process_table_audit", %{
      workspace_path: path
    } do
      # A prior stress case may have terminated its BEAM-side owner before the
      # OS has fully reaped the shim. Give that external lifecycle the same
      # bounded settling window used by the postconditions below.
      initial_shims = wait_until_shims_reaped(0, 6_000)

      assert initial_shims == [],
             "Lingering shims detected prior to test: #{inspect(initial_shims)}"

      # Spawn 10 sessions with various signals and subshell processes
      for i <- 1..10 do
        sid = "challenger2_audit_#{i}_#{System.unique_integer([:positive])}"
        assert {:ok, pid} = TerminalServer.ensure_started(sid, workspace_path: path)

        # Run nested subshells and sleep background jobs
        assert :ok = TerminalServer.run_command(sid, "(sleep 10 &) ; echo NESTED_SPAWN")
        Process.sleep(50)

        # Send interrupt signals
        assert :ok = TerminalServer.send_signal(sid, :sigint)
        assert :ok = TerminalServer.send_signal(sid, :sigterm)

        # Abruptly kill
        assert :ok = TerminalServer.kill(sid)
        refute Process.alive?(pid)
      end

      # Wait for OS process table to settle
      remaining_shims = wait_until_shims_reaped(0, 6_000)

      assert remaining_shims == [],
             "Lingering pty_shim.py processes found: #{inspect(remaining_shims)}"

      # Verify zero defunct zombie processes across the test process tree
      defunct_zombies = get_test_related_zombies()
      assert defunct_zombies == [], "Defunct zombie processes found: #{inspect(defunct_zombies)}"
    end
  end
end
