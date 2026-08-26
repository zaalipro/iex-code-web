defmodule IexCode.Tools.TerminalSessionTest do
  use ExUnit.Case, async: false
  require Logger

  alias IexCode.Tools.TerminalSession
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup do
    session_id = "test_sess_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    on_exit(fn ->
      PubSub.unsubscribe(@pubsub_server, topic)

      if pid = TerminalSession.whereis(session_id) do
        ref = Process.monitor(pid)
        TerminalSession.stop(session_id)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
      end
    end)

    %{session_id: session_id, topic: topic}
  end

  describe "initialization & registry" do
    test "starts successfully and registers in SessionRegistry under {:terminal, session_id}", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert TerminalSession.whereis(session_id) == pid

      _ = :sys.get_state(pid)

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.session_id == session_id
      assert state.status in [:starting, :running]
      assert state.occupant == :user
      assert state.cols == 80
      assert state.rows == 24
    end

    test "broadcasts initial status over PubSub upon startup", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert_receive {:terminal_status, %{session_id: ^session_id, status: :running}}, 5_000
    end
  end

  describe "bidirectional streaming & PubSub output" do
    test "dispatches stdin and broadcasts raw stdout chunk", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)
      assert_receive {:terminal_status, _}, 5_000

      unique_token = "PTY_ECHO_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{unique_token}\n")

      assert {:ok, output} = receive_matching_output(session_id, unique_token)
      assert String.contains?(output, unique_token)
    end

    test "handles split multibyte UTF-8 stream safely without crashes", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Inject 4-byte emoji 🚀 (<<240, 159, 154, 128>>) split across two chunks
      send(pid, {nil, {:data, <<240, 159>>}})
      _ = :sys.get_state(pid)

      send(pid, {nil, {:data, <<154, 128>>}})
      _ = :sys.get_state(pid)

      assert_receive {:terminal_output, %{data: data}}, 3_000
      assert data =~ "🚀"
    end

    test "supports fallback mode execution", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, mode: :fallback, project_root: File.cwd!()]}
        )

      _ = :sys.get_state(pid)

      token = "FALLBACK_TEST_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)
    end
  end

  describe "window resizing & dimensions" do
    test "updates dimensions and broadcasts resized event", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, cols: 80, rows: 24]})

      _ = :sys.get_state(pid)

      assert :ok = TerminalSession.resize(session_id, 120, 45)
      _ = :sys.get_state(pid)

      assert_receive {:terminal_resized, %{session_id: ^session_id, cols: 120, rows: 45}}, 3_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.cols == 120
      assert state.rows == 45
    end
  end

  describe "signals & occupant management" do
    test "sends signals and manages occupant transitions", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Change occupant to agent
      assert :ok =
               TerminalSession.set_occupant(session_id, {:agent, "TestAgent", "test_op_1"})

      assert_receive {:terminal_occupant,
                      %{session_id: ^session_id, occupant: {:agent, "TestAgent", "test_op_1"}}},
                     3_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.occupant == {:agent, "TestAgent", "test_op_1"}

      # Send signal
      assert :ok = TerminalSession.send_signal(session_id, :sigint)

      # Revert occupant to user
      assert :ok = TerminalSession.set_occupant(session_id, :user)
      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}}, 3_000
    end

    test "interrupt holds a raw-input workspace reservation until a shell boundary", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [
             session_id: session_id,
             project_root: File.cwd!(),
             interrupt_signal_delay_ms: 10_000
           ]}
        )

      _ = :sys.get_state(pid)
      assert :ok = TerminalSession.send_input(session_id, "printf raw-lock\n")
      locked = :sys.get_state(pid)
      assert locked.raw_input_lock?
      assert %IexCode.WorkspaceLocks{} = locked.workspace_lock_handle

      assert :ok = TerminalSession.send_signal(session_id, :sigint)
      scheduled = :sys.get_state(pid)
      assert scheduled.raw_input_lock?
      assert scheduled.workspace_lock_handle == locked.workspace_lock_handle
      assert %{delivered?: false} = scheduled.pending_interrupt

      delivered =
        :sys.replace_state(pid, fn state ->
          cancel_test_timer(state.pending_interrupt.signal_timer)

          %{
            state
            | pending_interrupt: %{
                state.pending_interrupt
                | signal_timer: nil,
                  delivered?: true
              }
          }
        end)

      # The shim sends this protocol acknowledgement only after tcgetpgrp/1
      # reports that the original shell owns the PTY foreground again.
      send(
        pid,
        {delivered.adapter.port,
         {:data, <<4, delivered.pending_interrupt.boundary_id::unsigned-big-64>>}}
      )

      settled = :sys.get_state(pid)

      refute settled.raw_input_lock?
      assert is_nil(settled.pending_interrupt)
      assert is_nil(settled.workspace_lock_handle)
    end

    test "ignored interrupt keeps the lock until the bounded forced-restart boundary", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [
             session_id: session_id,
             project_root: File.cwd!(),
             interrupt_signal_delay_ms: 10_000,
             interrupt_force_timeout_ms: 10_000
           ]}
        )

      original = :sys.get_state(pid)
      ready_token = "IGNORING_SIGINT_#{System.unique_integer([:positive])}"

      assert :ok =
               TerminalSession.send_input(
                 session_id,
                 "trap '' INT; printf #{ready_token}; sleep 30\n"
               )

      assert {:ok, _output} = receive_matching_output(session_id, ready_token)
      assert :ok = TerminalSession.send_signal(session_id, :sigint)

      scheduled = :sys.get_state(pid)
      cancel_test_timer(scheduled.pending_interrupt.signal_timer)

      send(
        pid,
        {:deferred_signal, scheduled.pending_interrupt.request_id, :sigint,
         scheduled.pending_interrupt.generation, scheduled.pending_interrupt.port}
      )

      delivered = :sys.get_state(pid)

      assert delivered.raw_input_lock?
      assert delivered.pending_interrupt.delivered?
      assert %IexCode.WorkspaceLocks{} = delivered.workspace_lock_handle

      send(
        pid,
        {:interrupt_force_timeout, delivered.pending_interrupt.request_id,
         delivered.pending_interrupt.generation, delivered.pending_interrupt.port}
      )

      restarted = :sys.get_state(pid)
      assert restarted.status == :running
      assert restarted.adapter_generation > original.adapter_generation
      refute restarted.adapter.port == original.adapter.port
      refute restarted.raw_input_lock?
      assert is_nil(restarted.pending_interrupt)
      assert is_nil(restarted.workspace_lock_handle)
    end
  end

  describe "ring buffer history management" do
    test "records real structured command history and preserves it across shell restart", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)
      command = "printf structured-history"
      assert {:ok, command_id} = TerminalSession.run_command(session_id, command)

      assert_receive {:terminal_command_completed,
                      %{
                        session_id: ^session_id,
                        command_id: ^command_id,
                        command: ^command,
                        exit_code: 0
                      }},
                     8_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert [%{command: ^command, exit_code: 0, status: :ok} | _] = state.command_history

      # Restart is a shell lifecycle action, not a privacy clear; the already
      # bounded/redacted structured history intentionally remains available.
      assert {:ok, ^pid} = TerminalSession.restart(session_id)
      assert {:ok, restarted} = TerminalSession.get_state(session_id)
      assert [%{command: ^command} | _] = restarted.command_history
    end

    test "accumulates history and supports clear", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      token = "HIST_TEST_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert {:ok, _} = receive_matching_output(session_id, token)

      history = TerminalSession.get_history(session_id)
      assert is_binary(history)
      assert String.contains?(history, token)

      assert :ok = TerminalSession.clear_history(session_id)
      assert_receive {:terminal_cleared, %{session_id: ^session_id}}, 3_000
      assert TerminalSession.get_history(session_id) == ""
    end

    test "enforces max_buffer_bytes capacity and drops oldest tail chunks", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [session_id: session_id, max_buffer_bytes: 500, project_root: File.cwd!()]}
        )

      _ = :sys.get_state(pid)

      # Inject 1000 bytes in 200-byte chunks
      for idx <- 1..5 do
        chunk = "CHUNK_#{idx}_" <> String.duplicate("A", 185) <> "\n"
        send(pid, {nil, {:data, chunk}})
      end

      _ = :sys.get_state(pid)

      history = TerminalSession.get_history(session_id)
      assert byte_size(history) <= 500
      assert String.contains?(history, "CHUNK_5_")
      refute String.contains?(history, "CHUNK_1_")
    end

    test "command input is strictly bounded and multibyte truncation stays valid UTF-8", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      oversized = "printf x # " <> String.duplicate("界", 11_000)
      assert byte_size(oversized) > 32 * 1_024

      assert {:error, :terminal_command_too_large} =
               TerminalSession.run_command(session_id, oversized)

      assert {:error, :invalid_terminal_command_encoding} =
               TerminalSession.run_command(session_id, <<255, 254, 128>>)

      assert {:error, :invalid_terminal_command_characters} =
               TerminalSession.run_command(session_id, "printf ok\0")

      assert TerminalSession.command_summary(oversized) |> String.valid?()
      assert byte_size(TerminalSession.command_summary(oversized)) <= 4 * 1_024

      state = :sys.get_state(pid)
      assert state.active_command == nil
      assert :queue.is_empty(state.command_queue)
      refute state.raw_input_lock?
    end

    test "raw input preserves binary controls but rejects huge paste before locking", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert :ok = TerminalSession.validate_raw_input(<<255, 254, 128, 3, 4>>)

      assert {:error, :terminal_input_too_large} =
               TerminalSession.send_input(session_id, :binary.copy(<<0>>, 256 * 1_024 + 1))

      state = :sys.get_state(pid)
      refute state.raw_input_lock?
      assert state.buffer_bytes == 0
    end

    test "structured history redacts secrets and enforces per-entry and total byte caps", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      oversized_history =
        Enum.map(1..100, fn index ->
          %{
            command_id: "legacy-#{index}",
            command: "printf ok # " <> String.duplicate("a", 8_000),
            exit_code: 0,
            status: :ok,
            duration_ms: 1,
            completed_at: DateTime.utc_now()
          }
        end)

      :sys.replace_state(pid, &%{&1 | command_history: oversized_history})

      secret = "super-secret-value"
      command = "printf history-safe # OPENAI_API_KEY=#{secret}"
      assert {:ok, command_id} = TerminalSession.run_command(session_id, command)

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^command_id, command: public_command}},
                     8_000

      refute public_command =~ secret
      assert public_command =~ "[REDACTED]"

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert length(state.command_history) <= 100
      assert Enum.all?(state.command_history, &(byte_size(&1.command) <= 4 * 1_024))
      assert Enum.sum(Enum.map(state.command_history, &byte_size(&1.command))) <= 128 * 1_024
      refute inspect(state.command_history) =~ secret
    end

    test "command summaries redact common authentication headers without broad matches" do
      secret = "sensitive-value"

      cases = [
        {"curl -H 'X-API-Key: #{secret}' https://example.test",
         "curl -H 'X-API-Key: [REDACTED]' https://example.test"},
        {"curl -H \"API-Key: #{secret}\" https://example.test",
         "curl -H \"API-Key: [REDACTED]\" https://example.test"},
        {"curl -H 'X-Goog-API-Key: #{secret}' https://example.test",
         "curl -H 'X-Goog-API-Key: [REDACTED]' https://example.test"},
        {"curl -H Ocp-Apim-Subscription-Key:#{secret} https://example.test",
         "curl -H Ocp-Apim-Subscription-Key:[REDACTED] https://example.test"},
        {"curl -H 'Authorization: Basic #{secret}' https://example.test",
         "curl -H 'Authorization: Basic [REDACTED]' https://example.test"},
        {"curl -H 'Proxy-Authorization: Bearer #{secret}' https://example.test",
         "curl -H 'Proxy-Authorization: Bearer [REDACTED]' https://example.test"}
      ]

      for {command, expected} <- cases do
        assert TerminalSession.command_summary(command) == expected
        refute TerminalSession.command_summary(command) =~ secret
      end

      harmless = "echo api-keyboard:layout authorization:custom x-api-key-note:public"
      assert TerminalSession.command_summary(harmless) == harmless
    end

    test "clear removes structured history and suppresses an active command from reappearing", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)
      assert {:ok, completed_id} = TerminalSession.run_command(session_id, "printf before-clear")

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^completed_id}},
                     8_000

      assert {:ok, %{command_history: [_ | _]}} = TerminalSession.get_state(session_id)
      assert :ok = TerminalSession.clear_history(session_id)

      assert {:ok, %{command_history: []}} = TerminalSession.get_state(session_id)

      assert {:ok, active_id} =
               TerminalSession.run_command(session_id, "sleep 0.2; printf after-clear")

      assert_receive {:terminal_command_started,
                      %{session_id: ^session_id, command_id: ^active_id}},
                     3_000

      assert :ok = TerminalSession.clear_history(session_id)

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^active_id}},
                     8_000

      assert {:ok, %{command_history: []}} = TerminalSession.get_state(session_id)
    end
  end

  describe "restart and process lifecycle" do
    test "restarts session with new shell process", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert {:ok, ^pid} = TerminalSession.restart(session_id)
      _ = :sys.get_state(pid)

      token = "POST_RESTART_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end

    test "a deferred SIGINT from an old adapter generation cannot interrupt its replacement", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      original = :sys.get_state(pid)
      assert is_port(original.adapter.port)
      assert is_integer(original.adapter_generation)

      # This schedules the real delayed signal for the original adapter.
      assert :ok = TerminalSession.send_signal(session_id, :sigint)
      assert {:ok, ^pid} = TerminalSession.restart(session_id)

      replacement = :sys.get_state(pid)
      assert replacement.adapter_generation > original.adapter_generation
      refute replacement.adapter.port == original.adapter.port

      assert {:ok, command_id} = TerminalSession.run_command(session_id, "sleep 2")

      assert_receive {:terminal_command_started,
                      %{session_id: ^session_id, command_id: ^command_id}},
                     3_000

      # Reproduce delivery after the restart and force GenServer synchronization.
      send(
        pid,
        {:deferred_signal, make_ref(), :sigint, original.adapter_generation,
         original.adapter.port}
      )

      _ = :sys.get_state(pid)

      refute_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^command_id}},
                     300

      # A signal bound to the current adapter still works and cleans up quickly.
      assert :ok = TerminalSession.send_signal(session_id, :sigint)

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command_id: ^command_id}},
                     5_000
    end

    test "handles shell exit command cleanly", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert :ok = TerminalSession.send_input(session_id, "exit\n")
      assert_receive {:terminal_exit, %{session_id: ^session_id}}, 8_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.status == :stopped
    end
  end

  describe "input locking & force bypass" do
    test "rejects send_input when occupied by agent unless forced", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      :ok = TerminalSession.set_occupant(session_id, {:agent, "CoderAgent", "op_1"})

      # Rejected without force
      assert {:error, :agent_occupied} =
               TerminalSession.send_input(session_id, "echo blocked\n")

      # Accepted with force: true
      token = "FORCED_PASS_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n", force: true)
      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)

      # Accepted when restored to :user
      :ok = TerminalSession.set_occupant(session_id, :user)
      user_token = "USER_PASS_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{user_token}\n")
      assert {:ok, user_output} = receive_matching_output(session_id, user_token)
      assert String.contains?(user_output, user_token)
    end
  end

  describe "history search (search_history/3)" do
    test "searches scrollback with substring, regex, and ANSI stripping", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Plain and colored input
      token1 = "SEARCHABLE_LINE_ONE"
      token2 = "SEARCHABLE_LINE_TWO"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token1}\n")
      assert {:ok, _} = receive_matching_output(session_id, token1)

      assert :ok = TerminalSession.send_input(session_id, "echo #{token2}\n")
      assert {:ok, _} = receive_matching_output(session_id, token2)

      # Substring search
      assert {:ok, results} = TerminalSession.search_history(session_id, "SEARCHABLE_LINE")
      assert length(results) >= 2

      # Regex search
      assert {:ok, regex_results} =
               TerminalSession.search_history(session_id, "SEARCHABLE_LINE_(ONE|TWO)",
                 regex: true
               )

      assert length(regex_results) >= 2

      # Reverse option
      assert {:ok, rev_results} =
               TerminalSession.search_history(session_id, "SEARCHABLE_LINE", reverse: true)

      assert length(rev_results) >= 2
    end
  end

  describe "telemetry events emission" do
    test "emits session_started, output_chunk, and session_stopped", %{session_id: session_id} do
      test_pid = self()
      handler_id = "session-telem-#{session_id}-#{:erlang.unique_integer([:positive])}"

      events = [
        [:iex_code, :terminal, :session_started],
        [:iex_code, :terminal, :output_chunk],
        [:iex_code, :terminal, :session_stopped]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:session_telem, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert_receive {:session_telem, [:iex_code, :terminal, :session_started], measurements,
                      metadata},
                     5_000

      assert is_map(measurements)
      assert metadata.session_id == session_id

      # Output chunk
      token = "TELEMETRY_CHUNK_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert_receive {:session_telem, [:iex_code, :terminal, :output_chunk], chunk_meas,
                      chunk_meta},
                     5_000

      assert chunk_meas.byte_size > 0
      assert chunk_meta.session_id == session_id

      # Stop
      :ok = TerminalSession.stop(session_id)

      assert_receive {:session_telem, [:iex_code, :terminal, :session_stopped], stop_meas,
                      stop_meta},
                     5_000

      assert is_map(stop_meas)
      assert stop_meta.session_id == session_id
    end
  end

  # Helper to accumulate chunks until token is found
  defp cancel_test_timer(nil), do: :ok

  defp cancel_test_timer(timer) do
    _ = Process.cancel_timer(timer, async: false, info: false)
    :ok
  end

  defp receive_matching_output(session_id, token, acc \\ "", timeout \\ 8_000) do
    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        new_acc = acc <> data

        if String.contains?(new_acc, token) do
          {:ok, new_acc}
        else
          receive_matching_output(session_id, token, new_acc, timeout)
        end
    after
      timeout ->
        {:error, {:timeout, acc}}
    end
  end
end
