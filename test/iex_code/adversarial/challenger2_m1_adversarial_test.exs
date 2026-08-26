defmodule IexCode.Adversarial.Challenger2M1AdversarialTest do
  @moduledoc """
  Adversarial Challenge Test Suite for Milestone 1 (PTY Backend, Multi-Session Concurrency & Buffer Integrity).
  Conducted by Challenger 2.

  Adversarial dimensions tested:
  1. Multi-Session Isolation (15 concurrent workspace terminal sessions executing parallel commands,
     verifying directory, environment, history, and PubSub message isolation without cross-talk).
  2. DynamicSupervisor & Registry churn under parallel lifecycle operations.
  3. Agent Command Concurrency & Race Conditions:
     - `run_agent_command/4` interleaved with rapid `kill/1` and `restart/2`
     - Concurrent agent commands on distinct sessions
     - Timeout handling on blocking shell commands
     - Occupant state recovery under unexpected failures
  4. Malformed UTF-8, Null Bytes, and Non-ASCII Binary Bursts:
     - Multi-byte code points split across packet boundaries (1-byte chunk streaming)
     - Invalid byte sequences (0xFF, 0xFE, overlong encodings, high ASCII)
     - Embedded null bytes (`<<0>>`) and non-printable control bytes
     - Ring buffer capacity, UTF-8 alignment, and sliding window eviction under flood
  5. OS Process & Signal Lifecycle:
     - Boundary dimension resizing (1x1 to 1000x1000, zero/negative rejection)
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

  # ============================================================================
  # 1. Multi-Session Isolation & Parallel Concurrency (15 sessions)
  # ============================================================================

  describe "Multi-Session Isolation & Parallel Concurrency" do
    test "ADV_01_15_concurrent_sessions_isolated_workspaces_env_and_history", %{
      workspace_path: root_path
    } do
      session_count = 15

      sessions =
        for i <- 1..session_count do
          sid = "adv_iso_#{i}_#{System.unique_integer([:positive])}"
          dir = Path.join(root_path, "ws_#{i}")
          File.mkdir_p!(dir)
          # Create a distinct file in each directory
          File.write!(Path.join(dir, "marker_#{i}.txt"), "MARKER_CONTENT_#{i}")
          {sid, dir, i}
        end

      on_exit(fn ->
        Enum.each(sessions, fn {sid, _, _} -> cleanup_session(sid) end)
      end)

      # Start all 15 sessions in parallel
      start_results =
        sessions
        |> Task.async_stream(
          fn {sid, dir, _i} ->
            TerminalServer.ensure_started(sid, workspace_path: dir)
          end,
          max_concurrency: 15,
          timeout: 20_000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(start_results, fn res -> match?({:ok, pid} when is_pid(pid), res) end)

      # Dispatch unique commands simultaneously across all 15 sessions
      exec_results =
        sessions
        |> Task.async_stream(
          fn {sid, _dir, i} ->
            subscribe_terminal(sid)

            token = "CONC_ISOLATION_TOKEN_#{i}_#{System.unique_integer([:positive])}"
            var_name = "VAR_CONC_#{i}"
            var_val = "VAL_#{i}_#{System.unique_integer([:positive])}"

            # Export distinct env var, print pwd, list marker file using wildcard, and echo token
            # Note: The wildcard 'ls marker_*.txt' ensures the filename is produced by the command execution, not the command echo
            cmd =
              "export #{var_name}=#{var_val}; ls marker_*.txt; echo \"$#{var_name}\"; echo \"FIN_#{token}\""

            :ok = TerminalServer.run_command(sid, cmd)

            # The PTY may split one command's output across multiple packets. Wait for
            # the command's final sentinel rather than returning as soon as the first
            # `ls` line arrives, otherwise later env/token assertions race the shell.
            final_line = ~r/(?:^|\r?\n)FIN_#{Regex.escape(token)}\r?(?:\n|$)/

            case receive_terminal_output(sid, final_line, 15_000) do
              {:ok, output} ->
                {:ok, sid, i, var_val, token, output}

              {:error, reason} ->
                {:error, sid, i, reason}
            end
          end,
          max_concurrency: 15,
          timeout: 25_000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert length(exec_results) == session_count

      # Verify each session's output and cross-check history for ZERO cross-talk
      Enum.each(exec_results, fn
        {:ok, sid, i, var_val, token, output} ->
          assert String.contains?(output, token),
                 "Session #{sid} missing token in #{inspect(output)}"

          assert String.contains?(output, var_val),
                 "Session #{sid} missing env value in #{inspect(output)}"

          assert String.contains?(output, "marker_#{i}.txt"),
                 "Session #{sid} wrong directory in #{inspect(output)}"

          # Verify history buffer strictly contains its own token and NO OTHER session's token
          history = TerminalServer.get_history(sid)
          assert String.contains?(history, token)
          assert String.contains?(history, "marker_#{i}.txt")

          # Check against other sessions
          Enum.each(sessions, fn {_other_sid, _, other_i} ->
            if other_i != i do
              refute String.contains?(history, "marker_#{other_i}.txt"),
                     "Crosstalk detected: Session #{sid} history contains marker_#{other_i}.txt"
            end
          end)

        {:error, sid, i, reason} ->
          flunk("Session #{sid} (idx #{i}) failed to execute: #{inspect(reason)}")
      end)
    end

    test "ADV_02_dynamic_supervisor_registry_resilience_under_parallel_churn", %{
      workspace_path: path
    } do
      session_ids =
        for i <- 1..10 do
          "adv_sup_churn_#{i}_#{System.unique_integer([:positive])}"
        end

      on_exit(fn ->
        Enum.each(session_ids, &cleanup_session/1)
      end)

      # Parallel starts
      pids =
        session_ids
        |> Enum.map(fn sid ->
          {:ok, pid} = TerminalServer.ensure_started(sid, workspace_path: path)
          pid
        end)

      assert length(pids) == 10
      assert Enum.all?(pids, &Process.alive?/1)

      # Check DynamicSupervisor listing
      active = TerminalSupervisor.list_sessions()
      active_ids = Enum.map(active, &elem(&1, 0))

      Enum.each(session_ids, fn sid ->
        assert sid in active_ids, "Session #{sid} should be registered in TerminalSupervisor"
      end)

      # Kill half in parallel while querying get_state on the other half
      {to_kill, to_keep} = Enum.split(session_ids, 5)

      kill_tasks =
        to_kill
        |> Enum.map(fn sid ->
          Task.async(fn -> TerminalServer.kill(sid) end)
        end)

      query_tasks =
        to_keep
        |> Enum.map(fn sid ->
          Task.async(fn -> TerminalServer.get_state(sid) end)
        end)

      Task.await_many(kill_tasks, 5_000)
      query_results = Task.await_many(query_tasks, 5_000)

      # Ensure kept sessions are still alive and healthy
      Enum.each(query_results, fn res ->
        assert match?({:ok, %{status: :running}}, res)
      end)

      # Ensure killed sessions are removed from registry
      Enum.each(to_kill, fn sid ->
        assert TerminalServer.whereis(sid) == nil
        assert TerminalServer.get_state(sid) == {:error, :not_found}
      end)
    end
  end

  # ============================================================================
  # 2. Agent Command Concurrency & Interleaved Kill / Restart Races
  # ============================================================================

  describe "Agent Command Dispatch & Race Conditions" do
    test "ADV_03_agent_command_interleaved_with_concurrent_kill", %{workspace_path: path} do
      # Test racing run_agent_command against TerminalServer.kill/1
      for i <- 1..5 do
        session_id = "adv_agent_kill_race_#{i}_#{System.unique_integer([:positive])}"
        on_exit(fn -> cleanup_session(session_id) end)

        assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

        # Launch a long-running agent command in task
        agent_task =
          Task.async(fn ->
            TerminalServer.run_agent_command(
              session_id,
              "sleep 10; echo AGENT_SHOULD_BE_KILLED",
              "CoderAgent",
              timeout_ms: 2_000
            )
          end)

        # Allow command to dispatch, then immediately kill session
        Process.sleep(50)
        :ok = TerminalServer.kill(session_id)

        # Agent task should return {:error, :timeout} or {:error, _} without crashing the caller
        result = Task.await(agent_task, 4_000)
        assert match?({:error, _}, result)

        # Ensure session is terminated and supervisor is clean
        assert TerminalServer.whereis(session_id) == nil
      end
    end

    test "ADV_04_agent_command_interleaved_with_concurrent_restart", %{workspace_path: path} do
      session_id = "adv_agent_restart_race_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Race run_agent_command against restart
      agent_task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "sleep 5; echo SLOW_DONE",
            "ExplorerAgent",
            timeout_ms: 1_500
          )
        end)

      Process.sleep(30)
      assert {:ok, new_pid} = TerminalServer.restart(session_id)
      assert is_pid(new_pid)
      assert Process.alive?(new_pid)

      # Agent command terminates with timeout/error cleanly
      agent_res = Task.await(agent_task, 3_000)
      assert match?({:error, _}, agent_res)

      # New session is completely usable
      token = "NEW_SESSION_OPERATIONAL_#{System.unique_integer([:positive])}"

      assert {:ok, cmd_res} =
               TerminalServer.run_agent_command(session_id, "echo #{token}", "VerifierAgent")

      assert cmd_res.exit_code == 0
      assert String.contains?(cmd_res.output, token)

      # Occupant state is restored to :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "ADV_05_parallel_agent_commands_across_multiple_sessions", %{workspace_path: path} do
      # 8 parallel agents running commands on 8 distinct sessions concurrently
      session_count = 8

      tasks =
        for i <- 1..session_count do
          sid = "adv_agent_par_#{i}_#{System.unique_integer([:positive])}"
          agent_name = "Agent_#{i}"
          token = "PAR_AGENT_TOKEN_#{i}_#{System.unique_integer([:positive])}"

          Task.async(fn ->
            {:ok, _} = TerminalServer.ensure_started(sid, workspace_path: path)

            res =
              TerminalServer.run_agent_command(
                sid,
                "echo '#{token}'",
                agent_name,
                timeout_ms: 10_000
              )

            cleanup_session(sid)
            {sid, token, res}
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert length(results) == session_count

      Enum.each(results, fn {sid, token, res} ->
        assert {:ok, data} = res, "Session #{sid} failed agent command: #{inspect(res)}"
        assert data.exit_code == 0
        assert String.contains?(data.output, token)
        assert data.duration_ms >= 0
      end)
    end

    test "ADV_06_agent_command_timeout_on_hanging_process", %{workspace_path: path} do
      session_id = "adv_agent_timeout_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Run command with 600ms timeout on a command that takes 5 seconds
      start_t = System.monotonic_time(:millisecond)

      result =
        TerminalServer.run_agent_command(
          session_id,
          "sleep 5; echo DONE",
          "VerifierAgent",
          timeout_ms: 600
        )

      elapsed = System.monotonic_time(:millisecond) - start_t

      assert result == {:error, :timeout}
      # Should return close to timeout duration (between 500ms and 2500ms)
      assert elapsed >= 500 and elapsed < 2_500

      # Occupant state is restored to :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user

      # Interrupt the lingering sleep so the shell is immediately available
      :ok = TerminalServer.send_signal(session_id, :sigint)

      token = "RESUMED_AFTER_TIMEOUT"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      subscribe_terminal(session_id)
      assert {:ok, _} = receive_terminal_output(session_id, token, 8_000)
    end
  end

  # ============================================================================
  # 3. Malformed UTF-8, Null Bytes, and Non-ASCII Binary Bursts
  # ============================================================================

  describe "Malformed UTF-8, Null Bytes & Binary Buffer Integrity" do
    test "ADV_07_multibyte_utf8_split_across_packet_chunks", %{workspace_path: path} do
      session_id = "adv_utf8_split_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # 4-byte emoji 🚀 (<<240, 159, 154, 128>>) split into 4 individual 1-byte chunks
      bytes = [<<240>>, <<159>>, <<154>>, <<128>>]

      # Send a prefix
      assert :ok = TerminalServer.send_input(session_id, "echo '")

      # Send the split emoji byte by byte
      Enum.each(bytes, fn b ->
        assert :ok = TerminalServer.send_input(session_id, b)
      end)

      assert :ok = TerminalServer.send_input(session_id, "'\n")

      # Shell output should successfully reconstruct the emoji 🚀 without replacement or crash
      assert {:ok, output} = receive_terminal_output(session_id, "🚀", 8_000)
      assert String.contains?(output, "🚀")

      # History buffer should also contain the valid UTF-8 emoji
      history = TerminalServer.get_history(session_id)
      assert String.valid?(history)
      assert String.contains?(history, "🚀")
    end

    test "ADV_08_invalid_utf8_and_raw_binary_bursts_resilience", %{workspace_path: path} do
      session_id = "adv_bin_burst_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Construct an adversarial binary payload containing:
      # - Invalid leading bytes (0xFF, 0xFE)
      # - Orphaned continuation bytes (0x80, 0x90, 0xBF)
      # - Overlong 2-byte sequence (0xC0, 0xAF)
      # - Mixed non-printable binary bytes (0x80..0xFF)
      adversarial_binary =
        <<0xFF, 0xFE, 0xC0, 0xAF, 0x80, 0xBF>> <>
          :binary.list_to_bin(Enum.to_list(128..255))

      # Send bursts of invalid binary wrapped in safe echo commands so shell does not hang on raw stdin
      for _ <- 1..10 do
        assert :ok =
                 TerminalServer.send_input(
                   session_id,
                   "echo '" <> adversarial_binary <> "' > /dev/null\n"
                 )
      end

      # Verify process is completely alive and healthy
      assert Process.alive?(pid)

      # Verify get_history returns a strictly valid UTF-8 string without raising
      history = TerminalServer.get_history(session_id)
      assert is_binary(history)
      assert String.valid?(history), "History buffer must be valid UTF-8 after binary bursts"

      # Invalid bytes can leave an interactive shell's line editor holding an
      # intentionally incomplete command. Reset that editor state through the
      # same raw-input path, then prove the PTY remains responsive.
      assert :ok = TerminalServer.send_input(session_id, <<3>>)

      # Shell must remain fully responsive to standard commands
      recovery_token = "RECOVERED_AFTER_BINARY_BURST_#{System.unique_integer([:positive])}"
      subscribe_terminal(session_id)
      assert :ok = TerminalServer.run_command(session_id, "echo '#{recovery_token}'")
      assert {:ok, output} = receive_terminal_output(session_id, recovery_token, 8_000)
      assert String.contains?(output, recovery_token)
    end

    test "ADV_09_ring_buffer_sliding_window_eviction_and_utf8_boundary_integrity", %{
      workspace_path: path
    } do
      session_id = "adv_ring_evict_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)

      # Start session with small max_buffer_bytes (e.g. 10KB) to aggressively test sliding window
      assert {:ok, _pid} =
               TerminalServer.ensure_started(session_id,
                 workspace_path: path,
                 max_buffer_bytes: 10 * 1024
               )

      # Stream 100KB of multi-byte Japanese and Unicode text
      unicode_line = "【テスト】日本語UTF-8文字列_絵文字🔥⚡️✨_行番号:"

      cmd =
        "for i in $(seq 1 300); do echo \"#{unicode_line}$i\"; done"

      assert :ok = TerminalServer.run_command(session_id, cmd)

      assert {:ok, _} = receive_terminal_output(session_id, "#{unicode_line}300", 15_000)

      # History buffer must be within 15KB limit and strictly valid UTF-8
      history = TerminalServer.get_history(session_id)
      assert byte_size(history) <= 15 * 1024
      assert String.valid?(history), "History must be valid UTF-8 after sliding window eviction"

      # Latest lines must be preserved
      assert String.contains?(history, "#{unicode_line}300")
    end

    test "ADV_10_extreme_dimensions_and_zero_values", %{workspace_path: path} do
      session_id = "adv_dims_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # 1x1 dimensions (minimum boundary)
      assert :ok = TerminalServer.resize(session_id, 1, 1)
      assert {:ok, state1} = TerminalServer.get_state(session_id)
      assert state1.cols == 1
      assert state1.rows == 1

      # Very large dimensions (1000x1000)
      assert :ok = TerminalServer.resize(session_id, 1000, 1000)
      assert {:ok, state2} = TerminalServer.get_state(session_id)
      assert state2.cols == 1000
      assert state2.rows == 1000

      # Zero and negative dimensions should return {:error, :invalid_dimensions}
      assert TerminalServer.resize(session_id, 0, 24) == {:error, :invalid_dimensions}
      assert TerminalServer.resize(session_id, 80, 0) == {:error, :invalid_dimensions}
      assert TerminalServer.resize(session_id, -50, -20) == {:error, :invalid_dimensions}

      # Session state remains undamaged
      assert {:ok, state3} = TerminalServer.get_state(session_id)
      assert state3.cols == 1000
      assert state3.rows == 1000
    end
  end
end
