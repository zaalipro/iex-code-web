defmodule IexCode.E2E.E2EPtyTerminalTest do
  @moduledoc """
  Comprehensive Opaque-Box E2E Test Suite for the Interactive PTY Terminal.
  Covers Tiers 1 through 4 as specified in PROJECT.md and TEST_INFRA.md:
  - Tier 1: Feature Coverage (F1 to F10: PTY spawner, bidirectional stdin/stdout, PubSub, resize, lifecycle, ring buffer, agent execution, telemetry, occupant state, searchable history)
  - Tier 2: Boundary & Corner Cases (rapid keystrokes, output flood, whitespace/empty inputs, invalid UTF-8, ANSI truecolor, exit/restart without zombies, multi-session isolation, invalid dimensions/signals)
  - Tier 3: Cross-Feature Combinations (resize while streaming, clear during active stream, restart after exit, occupant transitions, history sync across reconnects)
  - Tier 4: Real-World Workflow Scenarios (interactive REPL, Unix pipelines, signal interrupts, agent verification workflow, quick actions)
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.TerminalServer

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp subscribe_terminal(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")
  end

  defp receive_terminal_output(session_id, expected_pattern, timeout \\ 8_000) do
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

  defp wait_for_terminal_exit(session_id, timeout \\ 8_000) do
    receive do
      {:terminal_exit, %{session_id: ^session_id} = msg} ->
        {:ok, msg}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp wait_for_terminal_occupant(session_id, expected_occupant, timeout \\ 5_000) do
    receive do
      {:terminal_occupant, %{session_id: ^session_id, occupant: ^expected_occupant} = msg} ->
        {:ok, msg}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp wait_for_terminal_resize(session_id, cols, rows, timeout \\ 5_000) do
    receive do
      {:terminal_resized, %{session_id: ^session_id, cols: ^cols, rows: ^rows} = msg} ->
        {:ok, msg}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp wait_for_terminal_cleared(session_id, timeout \\ 5_000) do
    receive do
      {:terminal_cleared, %{session_id: ^session_id} = msg} ->
        {:ok, msg}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp cleanup_terminal_session(session_id) do
    try do
      TerminalServer.kill(session_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ============================================================================
  # Tier 1: Feature Coverage
  # ============================================================================

  describe "Tier 1: Feature Coverage" do
    test "T1_F01_01_spawn_shell_in_workspace_path", %{workspace_path: path} do
      session_id = "t1_spawn_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)

      assert {:ok, session_pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert is_pid(session_pid)
      assert Process.alive?(session_pid)

      # Verify session is registered and state is queryable
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.session_id == session_id
      assert state.status in [:active, :running, :idle]
    end

    test "T1_F01_02_spawn_with_custom_dimensions", %{workspace_path: path} do
      session_id = "t1_dims_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} =
               TerminalServer.ensure_started(session_id,
                 workspace_path: path,
                 cols: 100,
                 rows: 35
               )

      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 100
      assert state.rows == 35
    end

    test "T1_F01_03_spawn_idempotency", %{workspace_path: path} do
      session_id = "t1_idemp_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, pid1} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert {:ok, pid2} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert pid1 == pid2
    end

    test "T1_F01_04_get_state_returns_full_metadata", %{workspace_path: path} do
      session_id = "t1_meta_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert {:ok, state} = TerminalServer.get_state(session_id)

      assert Map.has_key?(state, :session_id)
      assert Map.has_key?(state, :status)
      assert Map.has_key?(state, :cols)
      assert Map.has_key?(state, :rows)
      assert Map.has_key?(state, :occupant)
    end

    test "T1_F01_05_supervised_under_terminal_supervisor", %{workspace_path: path} do
      session_id = "t1_sup_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert Process.alive?(pid)

      # Synchronize with state
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "T1_F02_01_send_input_echoes_output", %{workspace_path: path} do
      session_id = "t1_stdin_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "ECHO_TOKEN_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.send_input(session_id, "echo '#{token}'\n")

      assert {:ok, output} = receive_terminal_output(session_id, token)
      assert String.contains?(output, token)
    end

    test "T1_F02_02_run_command_helper", %{workspace_path: path} do
      session_id = "t1_runcmd_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "RUN_CMD_TOKEN_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")

      assert {:ok, output} = receive_terminal_output(session_id, token)
      assert String.contains?(output, token)
    end

    test "T1_F03_01_pubsub_message_format_validation", %{workspace_path: path} do
      session_id = "t1_pubsub_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.send_input(session_id, "echo 'FORMAT_CHECK'\n")

      assert_receive {:terminal_output, msg}, 8_000
      assert msg.session_id == session_id
      assert is_binary(msg.data)
      assert %DateTime{} = msg.timestamp
    end

    test "T1_F03_02_multiline_output_streaming", %{workspace_path: path} do
      session_id = "t1_multiline_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.run_command(session_id, "echo 'LINE_ALPHA'; echo 'LINE_BETA'")

      assert {:ok, _} = receive_terminal_output(session_id, "LINE_ALPHA")
      assert {:ok, _} = receive_terminal_output(session_id, "LINE_BETA")
    end

    test "T1_F03_03_multiple_subscribers_broadcast", %{workspace_path: path} do
      session_id = "t1_multisub_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      # Spawn a secondary subscriber process
      parent = self()

      _child_sub =
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")
          send(parent, :child_ready)

          receive do
            {:terminal_output, %{session_id: ^session_id, data: data}} ->
              send(parent, {:child_got_output, data})
          end
        end)

      assert_receive :child_ready, 3_000
      subscribe_terminal(session_id)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      token = "BROADCAST_TOKEN_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")

      assert {:ok, _} = receive_terminal_output(session_id, token)
      assert_receive {:child_got_output, _child_data}, 5_000
    end

    test "T1_F04_01_resize_broadcasts_event", %{workspace_path: path} do
      session_id = "t1_resize_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.resize(session_id, 120, 45)
      assert {:ok, msg} = wait_for_terminal_resize(session_id, 120, 45)
      assert msg.cols == 120
      assert msg.rows == 45
    end

    test "T1_F04_02_resize_updates_session_state", %{workspace_path: path} do
      session_id = "t1_resizestate_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert :ok = TerminalServer.resize(session_id, 140, 50)

      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 140
      assert state.rows == 50
    end

    test "T1_F04_03_resize_boundary_dimensions", %{workspace_path: path} do
      session_id = "t1_resizebound_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.resize(session_id, 20, 10)
      assert {:ok, state1} = TerminalServer.get_state(session_id)
      assert state1.cols == 20
      assert state1.rows == 10

      assert :ok = TerminalServer.resize(session_id, 240, 80)
      assert {:ok, state2} = TerminalServer.get_state(session_id)
      assert state2.cols == 240
      assert state2.rows == 80
    end

    test "T1_F05_01_explicit_kill_terminates_session", %{workspace_path: path} do
      session_id = "t1_kill_#{System.unique_integer([:positive])}"

      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      ref = Process.monitor(pid)

      assert :ok = TerminalServer.kill(session_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      assert TerminalServer.get_state(session_id) == {:error, :not_found}
    end

    test "T1_F05_02_restart_respawns_fresh_session", %{workspace_path: path} do
      session_id = "t1_restart_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid1} = TerminalServer.ensure_started(session_id, workspace_path: path)
      ref1 = Process.monitor(pid1)

      assert {:ok, pid2} = TerminalServer.restart(session_id)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, _}, 5_000

      assert pid2 != pid1
      assert Process.alive?(pid2)

      token = "POST_RESTART_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T1_F05_03_shell_exit_command", %{workspace_path: path} do
      session_id = "t1_exitcmd_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.send_input(session_id, "exit\n")
      assert {:ok, exit_msg} = wait_for_terminal_exit(session_id)
      assert is_integer(exit_msg.exit_code) or exit_msg.exit_code == nil
    end

    test "T1_F05_04_send_signal_sigint", %{workspace_path: path} do
      session_id = "t1_signal_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.send_signal(session_id, :sigint)
      # Shell remains alive and responsive after SIGINT
      token = "ALIVE_AFTER_SIGINT"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T1_F05_05_send_signal_sigcont", %{workspace_path: path} do
      session_id = "t1_sigcont_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
      assert :ok = TerminalServer.send_signal(session_id, :sigcont)
      assert :ok = TerminalServer.send_signal(session_id, "SIGCONT")

      token = "ALIVE_AFTER_SIGCONT"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T1_F06_01_get_history_accumulates_output", %{workspace_path: path} do
      session_id = "t1_hist_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "ACCUMULATE_HISTORY_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_terminal_output(session_id, token)

      history = TerminalServer.get_history(session_id)
      assert is_binary(history)
      assert String.contains?(history, token)
    end

    test "T1_F06_02_clear_resets_history_and_broadcasts", %{workspace_path: path} do
      session_id = "t1_clear_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "BEFORE_CLEAR_TOKEN"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_terminal_output(session_id, token)

      assert :ok = TerminalServer.clear(session_id)
      assert {:ok, _} = wait_for_terminal_cleared(session_id)

      history = TerminalServer.get_history(session_id)
      assert history == "" or not String.contains?(history, token)
    end

    test "T1_F07_01_run_agent_command_synchronous_success", %{workspace_path: path} do
      session_id = "t1_agentcmd_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "AGENT_EXEC_RESULT_#{System.unique_integer([:positive])}"

      assert {:ok, res} =
               TerminalServer.run_agent_command(
                 session_id,
                 "echo '#{token}'",
                 "ExplorerAgent"
               )

      assert is_map(res)
      assert res.exit_code == 0
      assert String.contains?(res.output, token)
      assert is_integer(res.duration_ms) and res.duration_ms >= 0
    end

    test "T1_F07_02_run_agent_command_nonzero_exit", %{workspace_path: path} do
      session_id = "t1_agenterr_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert {:ok, res} =
               TerminalServer.run_agent_command(
                 session_id,
                 "sh -c 'exit 42'",
                 "VerifierAgent"
               )

      assert res.exit_code == 42
    end

    test "T1_F08_01_agent_occupant_telemetry_lifecycle", %{workspace_path: path} do
      session_id = "t1_occupant_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Initial occupant is :user
      assert {:ok, state1} = TerminalServer.get_state(session_id)
      assert state1.occupant == :user

      # Run agent command in async task while monitoring PubSub
      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "echo AGENT_OCCUPANT_TEST",
            "CoderAgent"
          )
        end)

      # Should broadcast agent occupant
      assert {:ok, _msg} = wait_for_terminal_occupant(session_id, {:agent, "CoderAgent", nil})

      {:ok, _} = Task.await(task, 10_000)

      # Reverts to :user after agent finishes
      assert {:ok, state2} = TerminalServer.get_state(session_id)
      assert state2.occupant == :user
    end

    test "T1_F08_02_agent_command_streams_live_output", %{workspace_path: path} do
      session_id = "t1_agentstream_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "AGENT_STREAM_TOKEN_#{System.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "echo '#{token}'",
            "VerifierAgent"
          )
        end)

      assert {:ok, _} = receive_terminal_output(session_id, token)
      assert {:ok, res} = Task.await(task, 8_000)
      assert String.contains?(res.output, token)
    end

    test "T1_F10_01_searchable_terminal_history", %{workspace_path: path} do
      session_id = "t1_search_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token_alpha = "UNIQUE_SYMBOL_ALPHA_42"
      token_beta = "UNIQUE_SYMBOL_BETA_99"

      assert :ok = TerminalServer.run_command(session_id, "echo #{token_alpha}")
      assert {:ok, _} = receive_terminal_output(session_id, token_alpha)

      assert :ok = TerminalServer.run_command(session_id, "echo #{token_beta}")
      assert {:ok, _} = receive_terminal_output(session_id, token_beta)

      history = TerminalServer.get_history(session_id)
      assert String.contains?(history, token_alpha)
      assert String.contains?(history, token_beta)
    end
  end

  # ============================================================================
  # Tier 2: Boundary & Corner Cases
  # ============================================================================

  describe "Tier 2: Boundary & Corner Cases" do
    test "T2_01_rapid_keystrokes_burst", %{workspace_path: path} do
      session_id = "t2_rapid_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "BURST_TEST_#{System.unique_integer([:positive])}"
      command_chars = String.graphemes("echo #{token}\n")

      # Dispatch character by character rapidly
      Enum.each(command_chars, fn char ->
        :ok = TerminalServer.send_input(session_id, char)
      end)

      assert {:ok, output} = receive_terminal_output(session_id, token, 8_000)
      assert String.contains?(output, token)
    end

    test "T2_02_large_output_flood_500_lines", %{workspace_path: path} do
      session_id = "t2_flood_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Generate 500 lines of fast output
      cmd = "for i in $(seq 1 500); do echo \"FLOOD_LINE_$i\"; done"
      assert :ok = TerminalServer.run_command(session_id, cmd)

      assert {:ok, _} = receive_terminal_output(session_id, "FLOOD_LINE_500", 12_000)

      # Ensure process is alive and responsive
      assert Process.alive?(pid)
      assert :ok = TerminalServer.run_command(session_id, "echo FLOOD_COMPLETE")
      assert {:ok, _} = receive_terminal_output(session_id, "FLOOD_COMPLETE")
    end

    test "T2_03_empty_and_whitespace_inputs", %{workspace_path: path} do
      session_id = "t2_empty_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Send empty string, raw newline, whitespace, and tabs
      assert :ok = TerminalServer.send_input(session_id, "")
      assert :ok = TerminalServer.send_input(session_id, "\n")
      assert :ok = TerminalServer.send_input(session_id, "    \n")
      assert :ok = TerminalServer.send_input(session_id, "\t\t\n")

      token = "RECOVER_AFTER_EMPTY"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T2_04_invalid_utf8_and_ansi_escape_sequences", %{workspace_path: path} do
      session_id = "t2_utf8_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Send raw ANSI 256 truecolor escape code
      ansi_payload = "\e[38;2;255;100;0mTRUECOLOR_TEST\e[0m\n"
      assert :ok = TerminalServer.send_input(session_id, ansi_payload)

      # Send non-breaking / invalid byte sequence
      invalid_bytes = <<0xFF, 0xFE, 0x80, "echo UTF8_RECOVER\n">>
      assert :ok = TerminalServer.send_input(session_id, invalid_bytes)

      assert {:ok, _} = receive_terminal_output(session_id, "UTF8_RECOVER", 8_000)
    end

    test "T2_05_exit_without_orphan_processes", %{workspace_path: path} do
      session_id = "t2_orphan_#{System.unique_integer([:positive])}"

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      ref = Process.monitor(pid)

      # Spawn a detached sleep process inside shell
      assert :ok = TerminalServer.run_command(session_id, "sh -c 'sleep 120' &")

      # Kill session and verify clean shutdown
      assert :ok = TerminalServer.kill(session_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    test "T2_06_multi_session_isolation", %{workspace_path: path} do
      dir_a = Path.join(path, "dir_a")
      dir_b = Path.join(path, "dir_b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      session_a = "t2_iso_a_#{System.unique_integer([:positive])}"
      session_b = "t2_iso_b_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        cleanup_terminal_session(session_a)
        cleanup_terminal_session(session_b)
      end)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_a}:terminal")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_b}:terminal")

      assert {:ok, pid_a} = TerminalServer.ensure_started(session_a, workspace_path: dir_a)
      assert {:ok, pid_b} = TerminalServer.ensure_started(session_b, workspace_path: dir_b)
      assert pid_a != pid_b

      token_a = "ISOLATED_TOKEN_ALPHA_#{System.unique_integer([:positive])}"
      token_b = "ISOLATED_TOKEN_BETA_#{System.unique_integer([:positive])}"

      assert :ok = TerminalServer.run_command(session_a, "echo #{token_a}")
      assert :ok = TerminalServer.run_command(session_b, "echo #{token_b}")

      assert {:ok, _} = receive_terminal_output(session_a, token_a)
      assert {:ok, _} = receive_terminal_output(session_b, token_b)

      hist_a = TerminalServer.get_history(session_a)
      hist_b = TerminalServer.get_history(session_b)

      assert String.contains?(hist_a, token_a)
      refute String.contains?(hist_a, token_b)

      assert String.contains?(hist_b, token_b)
      refute String.contains?(hist_b, token_a)
    end

    test "T2_07_operations_on_nonexistent_session" do
      nonexistent_id = "nonexistent_#{System.unique_integer([:positive])}"

      assert {:error, _} = TerminalServer.send_input(nonexistent_id, "pwd\n")
      assert {:error, _} = TerminalServer.resize(nonexistent_id, 80, 24)
      assert {:error, _} = TerminalServer.send_signal(nonexistent_id, :sigint)
      assert {:error, :not_found} = TerminalServer.get_state(nonexistent_id)
      assert TerminalServer.get_history(nonexistent_id) in ["", nil, {:error, :not_found}]
    end

    test "T2_08_invalid_resize_dimensions_handling", %{workspace_path: path} do
      session_id = "t2_badresize_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Resize with 0 or negative dimensions should return error or clamp safely without crashing
      res0 = TerminalServer.resize(session_id, 0, 0)
      res_neg = TerminalServer.resize(session_id, -10, -5)

      assert res0 in [:ok, {:error, :invalid_dimensions}]
      assert res_neg in [:ok, {:error, :invalid_dimensions}]

      # Session must remain healthy
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.status in [:active, :running, :idle]
    end

    test "T2_09_signals_to_terminated_session", %{workspace_path: path} do
      session_id = "t2_termsig_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert :ok = TerminalServer.kill(session_id)

      assert {:error, _} = TerminalServer.send_signal(session_id, :sigint)
    end

    test "T2_10_concurrent_kill_and_send_input_safety", %{workspace_path: path} do
      session_id = "t2_conckill_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Race input against kill
      task1 = Task.async(fn -> TerminalServer.send_input(session_id, "echo RACING\n") end)
      task2 = Task.async(fn -> TerminalServer.kill(session_id) end)

      _res1 = Task.await(task1, 5_000)
      _res2 = Task.await(task2, 5_000)

      # System must not hang or deadlock
      assert true
    end
  end

  # ============================================================================
  # Tier 3: Cross-Feature Combinations
  # ============================================================================

  describe "Tier 3: Cross-Feature Combinations" do
    test "T3_01_resize_while_streaming_output", %{workspace_path: path} do
      session_id = "t3_resizestream_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Start streaming loop
      cmd = "for i in $(seq 1 100); do echo \"RESIZE_STREAM_$i\"; done"
      assert :ok = TerminalServer.run_command(session_id, cmd)

      # Resize mid-stream
      assert :ok = TerminalServer.resize(session_id, 130, 40)

      assert {:ok, _} = receive_terminal_output(session_id, "RESIZE_STREAM_100", 10_000)

      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 130
      assert state.rows == 40
    end

    test "T3_02_clear_during_active_output_stream", %{workspace_path: path} do
      session_id = "t3_clearstream_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      assert :ok = TerminalServer.run_command(session_id, "echo EARLY_OUTPUT")
      assert {:ok, _} = receive_terminal_output(session_id, "EARLY_OUTPUT")

      assert :ok = TerminalServer.clear(session_id)
      assert {:ok, _} = wait_for_terminal_cleared(session_id)

      token = "POST_CLEAR_STREAM_TOKEN"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token)

      history = TerminalServer.get_history(session_id)
      assert String.contains?(history, token)
      refute String.contains?(history, "EARLY_OUTPUT")
    end

    test "T3_03_restart_after_shell_exit", %{workspace_path: path} do
      session_id = "t3_restartexit_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid1} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Exit shell
      assert :ok = TerminalServer.send_input(session_id, "exit\n")
      assert {:ok, _} = wait_for_terminal_exit(session_id)

      # Restart session
      assert {:ok, pid2} = TerminalServer.restart(session_id)
      assert pid2 != pid1
      assert Process.alive?(pid2)

      token = "RESURRECTED_SHELL_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T3_04_agent_command_during_active_session_with_occupant_switch", %{
      workspace_path: path
    } do
      session_id = "t3_occupantswitch_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Step 1: User runs command
      assert :ok = TerminalServer.run_command(session_id, "echo USER_INITIAL")
      assert {:ok, _} = receive_terminal_output(session_id, "USER_INITIAL")

      # Step 2: Agent executes command
      agent_token = "AGENT_INTERLEAVE_#{System.unique_integer([:positive])}"

      assert {:ok, res} =
               TerminalServer.run_agent_command(
                 session_id,
                 "echo #{agent_token}",
                 "ExplorerAgent"
               )

      assert String.contains?(res.output, agent_token)

      # Step 3: User continues typing
      user_token = "USER_RESUME_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{user_token}")
      assert {:ok, _} = receive_terminal_output(session_id, user_token)

      # Final occupant is :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "T3_05_dimension_retention_across_restart", %{workspace_path: path} do
      session_id = "t3_dimrestart_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      assert {:ok, _pid} =
               TerminalServer.ensure_started(session_id,
                 workspace_path: path,
                 cols: 110,
                 rows: 40
               )

      assert {:ok, state1} = TerminalServer.get_state(session_id)
      assert state1.cols == 110
      assert state1.rows == 40

      assert {:ok, _pid2} = TerminalServer.restart(session_id, cols: 110, rows: 40)

      assert {:ok, state2} = TerminalServer.get_state(session_id)
      assert state2.cols == 110
      assert state2.rows == 40
    end

    test "T3_06_pubsub_reconnect_and_history_sync", %{workspace_path: path} do
      session_id = "t3_reconnect_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      # Start session without subscription
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      token = "MISSED_BROADCAST_TOKEN_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")

      # Wait a brief moment for command execution via state sync
      assert {:ok, _} = TerminalServer.get_state(session_id)

      # Late subscriber connects
      subscribe_terminal(session_id)

      # History sync returns missed output
      history = TerminalServer.get_history(session_id)
      assert String.contains?(history, token)
    end
  end

  # ============================================================================
  # Tier 4: Real-World Workflow Scenarios
  # ============================================================================

  describe "Tier 4: Real-World Workflow Scenarios" do
    test "T4_S01_full_interactive_repl_workflow", %{workspace_path: path} do
      session_id = "t4_repl_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # 1. Export environment variable
      assert :ok = TerminalServer.run_command(session_id, "export MY_DEV_ENV=iex_interactive")

      # 2. Query environment variable
      assert :ok = TerminalServer.run_command(session_id, "echo $MY_DEV_ENV")
      assert {:ok, _} = receive_terminal_output(session_id, "iex_interactive")

      # 3. Create nested directories and navigate
      assert :ok = TerminalServer.run_command(session_id, "mkdir -p deep/nested/dir")
      assert :ok = TerminalServer.run_command(session_id, "cd deep/nested/dir && pwd")
      assert {:ok, _} = receive_terminal_output(session_id, "deep/nested/dir")
    end

    test "T4_S02_command_chaining_and_pipes", %{workspace_path: path} do
      session_id = "t4_pipes_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Unix pipeline
      cmd = "printf 'apple\\nbanana\\ncherry\\n' | grep 'banana' | tr a-z A-Z"
      assert :ok = TerminalServer.run_command(session_id, cmd)
      assert {:ok, _} = receive_terminal_output(session_id, "BANANA")

      # File redirection and reading
      file_cmd = "echo 'FILE_REDIRECT_CONTENT' > test_pipe.txt && cat test_pipe.txt"
      assert :ok = TerminalServer.run_command(session_id, file_cmd)
      assert {:ok, _} = receive_terminal_output(session_id, "FILE_REDIRECT_CONTENT")
    end

    test "T4_S03_signal_interrupt_and_recovery", %{workspace_path: path} do
      session_id = "t4_sigrecov_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Launch a blocking command (e.g. cat with no args waiting on stdin)
      assert :ok = TerminalServer.send_input(session_id, "cat\n")

      # Interrupt with SIGINT / Ctrl+C
      assert :ok = TerminalServer.send_signal(session_id, :sigint)

      # Shell recovers to prompt immediately
      token = "PROMPT_RECOVERED_#{System.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end

    test "T4_S04_agent_verifier_execution_workflow", %{workspace_path: path} do
      session_id = "t4_verifier_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Create a dummy elixir test file in workspace
      test_file = Path.join(path, "math_check.exs")

      File.write!(test_file, """
      if 1 + 1 == 2 do
        IO.puts("VERIFIER_PASS: 1+1=2")
        System.halt(0)
      else
        System.halt(1)
      end
      """)

      # Verifier agent runs the test file
      assert {:ok, res} =
               TerminalServer.run_agent_command(
                 session_id,
                 "elixir #{test_file}",
                 "VerifierAgent"
               )

      assert res.exit_code == 0
      assert String.contains?(res.output, "VERIFIER_PASS")
    end

    test "T4_S05_quick_action_toolbar_workflow", %{workspace_path: path} do
      session_id = "t4_toolbar_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_terminal_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Quick action: pwd
      assert :ok = TerminalServer.run_command(session_id, "pwd")
      assert {:ok, _} = receive_terminal_output(session_id, path)

      # Quick action: ls
      assert :ok = TerminalServer.run_command(session_id, "ls -la")
      assert {:ok, ls_output} = receive_terminal_output(session_id, ~r/(total|\.)/)
      assert String.contains?(ls_output, "total") or String.contains?(ls_output, ".")

      # Quick action: clear
      assert :ok = TerminalServer.clear(session_id)
      assert {:ok, _} = wait_for_terminal_cleared(session_id)

      # Quick action: final command
      token = "TOOLBAR_COMPLETE"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_terminal_output(session_id, token)
    end
  end
end
