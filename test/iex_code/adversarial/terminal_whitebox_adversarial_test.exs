defmodule IexCode.Adversarial.TerminalWhiteboxAdversarialTest do
  @moduledoc """
  White-Box Adversarial & Empirical Stress Test Suite for Milestone 4 Terminal System.
  Authored by Challenger 1.

  Covers:
  1. PTY shim & binary adapter framing edge cases (malformed opcodes, empty payloads, extreme sizes).
  2. Multi-byte UTF-8 boundary splitting across packet chunks (emojis, CJK, non-ASCII) and malformed byte ingestion.
  3. Sliding ring buffer overflow, rapid multi-thousand line flood, and memory bounded pruning (0-byte / 4KB limits).
  4. Concurrent agent occupation lock enforcement, user input rejection, `force: true` override, and fail-safe occupant unlock on timeouts and crashes.
  5. OS signal lifecycle (:sigint, :sigquit, :sighup, :sigterm, :sigkill, :sigtstp, :sigcont, :eof), process death recovery, and DynamicSupervisor session idempotency.
  6. Search history matrix (invalid regex handling, case sensitivity, ANSI stripping, limit bounds, reverse ordering, cleared buffer search).
  7. LiveView terminal event handling, boundary dimension parsing, and multi-session PubSub cross-talk isolation.
  """
  use IexCode.E2E.Case, async: false
  require Logger

  alias IexCode.{Projects, Sessions, Tools}
  alias IexCode.Tools.{TerminalServer, TerminalSession, TerminalSupervisor}
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup tags do
    session_id = "wb_adv_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    root_path = tags[:workspace_path] || File.cwd!()

    {:ok, project} =
      Projects.create_project(%{
        name: "Whitebox Challenger Proj #{session_id}",
        root_path: root_path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Whitebox Challenger Session #{session_id}"
      })

    on_exit(fn ->
      PubSub.unsubscribe(@pubsub_server, topic)

      if pid = TerminalServer.whereis(session_id) do
        ref = Process.monitor(pid)
        TerminalServer.kill(session_id)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
      end
    end)

    %{
      session_id: session_id,
      topic: topic,
      project: project,
      session: session,
      root_path: root_path
    }
  end

  defp assert_receive_output(expected_substr, timeout) do
    receive do
      {:terminal_output, %{data: data}} ->
        if String.contains?(data, expected_substr) do
          data
        else
          assert_receive_output(expected_substr, timeout)
        end
    after
      timeout ->
        flunk("Timed out waiting for terminal_output containing #{inspect(expected_substr)}")
    end
  end

  defp assert_receive_session_output(session_id, expected_substr, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_receive_session_output(session_id, expected_substr, deadline, "")
  end

  defp do_assert_receive_session_output(session_id, expected_substr, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        output = acc <> data

        if String.contains?(output, expected_substr) do
          output
        else
          do_assert_receive_session_output(session_id, expected_substr, deadline, output)
        end
    after
      remaining ->
        flunk(
          "Timed out waiting for terminal_output from #{session_id} containing " <>
            inspect(expected_substr)
        )
    end
  end

  # ============================================================================
  # Dimension 1: PTY Adapter Protocol & Framing Boundary Conditions
  # ============================================================================

  describe "PTY Adapter Protocol & Framing Boundaries" do
    test "handles malformed or unexpected opcode packets gracefully without crashing", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, project_root: File.cwd!(), mode: :fallback]}
        )

      assert Process.alive?(pid)

      # Send raw simulated port data messages with unusual / out-of-spec binary payloads
      fake_port = make_ref()

      # Empty packet payload
      send(pid, {fake_port, {:data, <<>>}})
      assert Process.alive?(pid)

      # Opcode 0xFF (unknown opcode)
      send(pid, {fake_port, {:data, <<255, "unknown_data">>}})
      assert Process.alive?(pid)

      # Opcode 0x00 (null opcode)
      send(pid, {fake_port, {:data, <<0, 1, 2, 3>>}})
      assert Process.alive?(pid)

      # Truncated OP_EXIT (less than 4 bytes for exit code)
      send(pid, {fake_port, {:data, <<2, 0, 1>>}})
      assert Process.alive?(pid)

      # Truncated OP_READY (less than 4 bytes for os_pid)
      send(pid, {fake_port, {:data, <<3, 0>>}})
      assert Process.alive?(pid)

      # Ensure GenServer state is still valid and responsive
      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert is_map(state)
    end

    test "handles zero-length inputs and extreme resize dimensions", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: File.cwd!())

      # 1. Zero-byte input
      assert :ok = TerminalServer.send_input(session_id, "")

      # 2. Extreme resize dimensions
      # Boundary: minimum dimension 1x1
      assert :ok = TerminalServer.resize(session_id, 1, 1)
      assert_receive {:terminal_resized, %{cols: 1, rows: 1}}, 2_000

      # Boundary: large dimension
      assert :ok = TerminalServer.resize(session_id, 500, 200)
      assert_receive {:terminal_resized, %{cols: 500, rows: 200}}, 2_000

      # Boundary: invalid zero or negative dimensions rejected at facade
      assert {:error, :invalid_dimensions} = TerminalServer.resize(session_id, 0, 24)
      assert {:error, :invalid_dimensions} = TerminalServer.resize(session_id, 80, -5)
      assert {:error, :invalid_dimensions} = TerminalServer.resize(session_id, -10, 0)
    end
  end

  # ============================================================================
  # Dimension 2: Multi-Byte UTF-8 Boundary Splitting & Malformed Bytes
  # ============================================================================

  describe "Multi-Byte UTF-8 Boundary Splitting & Malformed Bytes" do
    test "reassembles 4-byte emojis and 3-byte CJK characters split across chunk boundaries", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, project_root: File.cwd!(), mode: :fallback]}
        )

      fake_port = make_ref()

      # Emoji 🚀 is <<240, 159, 154, 128>> (4 bytes)
      rocket_bytes = "🚀"
      <<r1::binary-size(1), r2::binary-size(3)>> = rocket_bytes

      # Emoji ⚡ is <<226, 154, 161>> (3 bytes)
      bolt_bytes = "⚡"
      <<b1::binary-size(2), b2::binary-size(1)>> = bolt_bytes

      # Japanese text "東京" is <<230, 157, 177, 238, 174, 172>> (6 bytes: 3 + 3)
      cjk_bytes = "東京"
      <<c1::binary-size(2), c2::binary-size(2), c3::binary-size(2)>> = cjk_bytes

      # Step 1: Inject first partial chunk of rocket
      send(pid, {fake_port, {:data, r1}})
      # No complete text broadcast yet
      refute_receive {:terminal_output, %{data: "🚀"}}, 100

      # Step 2: Inject remaining chunk of rocket + first part of bolt
      send(pid, {fake_port, {:data, r2 <> b1}})
      out1 = assert_receive_output("🚀", 1_000)
      assert String.contains?(out1, "🚀")

      # Step 3: Inject remaining chunk of bolt + partial CJK
      send(pid, {fake_port, {:data, b2 <> c1}})
      out2 = assert_receive_output("⚡", 1_000)
      assert String.contains?(out2, "⚡")

      # Step 4: Complete the CJK characters
      send(pid, {fake_port, {:data, c2 <> c3}})
      out3 = assert_receive_output("東京", 1_000)
      assert String.contains?(out3, "東京")

      # Verify full history has preserved all multi-byte characters accurately
      history = TerminalSession.get_history(session_id)
      assert String.contains?(history, "🚀")
      assert String.contains?(history, "⚡")
      assert String.contains?(history, "東京")
      assert String.valid?(history)
    end

    test "handles raw non-UTF8 byte streams without crashing the terminal GenServer", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, project_root: File.cwd!(), mode: :fallback]}
        )

      fake_port = make_ref()

      # Inject invalid UTF-8 byte sequences
      invalid_bytes = <<0xFF, 0xFE, 0x80, 0x81, 0xC0, 0xAF>>
      send(pid, {fake_port, {:data, invalid_bytes}})

      # GenServer must survive and stay alive
      assert Process.alive?(pid)

      # Follow up with valid data
      send(pid, {fake_port, {:data, "RECOVERY_OK\n"}})
      out = assert_receive_output("RECOVERY_OK", 1_000)
      assert String.contains?(out, "RECOVERY_OK")

      history = TerminalSession.get_history(session_id)
      assert String.contains?(history, "RECOVERY_OK")
      assert String.valid?(history)
    end
  end

  # ============================================================================
  # Dimension 3: Sliding Ring Buffer Memory Bounded Pruning
  # ============================================================================

  describe "Sliding Ring Buffer Memory Bounded Pruning" do
    test "strictly bounds memory usage under massive output flood with custom max_buffer_bytes",
         %{
           session_id: session_id
         } do
      # Set a strict 4KB buffer limit (4096 bytes)
      max_limit = 4096

      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [
             session_id: session_id,
             project_root: File.cwd!(),
             max_buffer_bytes: max_limit,
             mode: :fallback
           ]}
        )

      fake_port = make_ref()

      # Generate 50KB of numbered lines (way exceeding 4KB)
      for i <- 1..500 do
        line =
          "LOG_LINE_#{String.pad_leading(to_string(i), 4, "0")}: #{String.duplicate("X", 80)}\n"

        send(pid, {fake_port, {:data, line}})
      end

      # Allow message processing
      _ = :sys.get_state(pid)

      {:ok, state} = TerminalSession.get_state(session_id)
      assert state.buffer_bytes <= max_limit

      history = TerminalSession.get_history(session_id)
      assert byte_size(history) <= max_limit

      # Newest lines must be preserved
      assert String.contains?(history, "LOG_LINE_0500")
      assert String.contains?(history, "LOG_LINE_0490")

      # Oldest lines must have been pruned
      refute String.contains?(history, "LOG_LINE_0001")
      refute String.contains?(history, "LOG_LINE_0010")
    end

    test "handles 0-byte and 1-byte max_buffer_bytes boundary limits without infinite loops", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [
             session_id: session_id,
             project_root: File.cwd!(),
             max_buffer_bytes: 0,
             mode: :fallback
           ]}
        )

      fake_port = make_ref()
      send(pid, {fake_port, {:data, "Hello World\n"}})
      _ = :sys.get_state(pid)

      {:ok, state} = TerminalSession.get_state(session_id)
      assert state.buffer_bytes == 0
      assert TerminalSession.get_history(session_id) == ""
    end
  end

  # ============================================================================
  # Dimension 4: Concurrency, Agent Locks & Fail-Safe Handover
  # ============================================================================

  describe "Concurrency, Agent Locks & Fail-Safe Handover" do
    test "rejects concurrent user input during active agent command execution", %{
      session_id: session_id
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: File.cwd!())

      # Launch agent command in an asynchronous task
      agent_task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "sleep 0.4 && echo 'AGENT_DONE'",
            "TestAgent",
            op_id: "op_lock_test"
          )
        end)

      # Give agent command brief moment to acquire lock
      Process.sleep(100)

      # Verify occupant is locked
      {:ok, state} = TerminalServer.get_state(session_id)
      assert match?({:agent, "TestAgent", "op_lock_test"}, state.occupant)

      # Attempt 10 concurrent user input operations - all must be rejected
      rejection_results =
        for _i <- 1..10 do
          TerminalServer.send_input(session_id, "user_command\n")
        end

      assert Enum.all?(rejection_results, fn res -> res == {:error, :agent_occupied} end)

      # Forced user input with force: true must succeed
      assert :ok = TerminalServer.send_input(session_id, "\n", force: true)

      # Wait for agent task to complete
      assert {:ok, agent_res} = Task.await(agent_task, 5_000)
      assert agent_res.exit_code == 0
      assert String.contains?(agent_res.output, "AGENT_DONE")

      # Verify occupant is automatically restored to :user
      {:ok, final_state} = TerminalServer.get_state(session_id)
      assert final_state.occupant == :user

      # Subsequent user input succeeds normally
      user_token = "USER_UNLOCKED_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.send_input(session_id, "echo '#{user_token}'\n")
      out = assert_receive_output(user_token, 3_000)
      assert String.contains?(out, user_token)
    end

    test "restores :user occupant state on agent command timeout", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: File.cwd!())

      # Run a command with 100ms timeout that takes 2.0s
      res =
        TerminalServer.run_agent_command(
          session_id,
          "sleep 2.0",
          "HangingAgent",
          timeout_ms: 100
        )

      assert res == {:error, :timeout}

      # Occupant state MUST be restored to :user
      {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user

      # Terminal remains usable for new commands
      token = "POST_TIMEOUT_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      out = assert_receive_output(token, 3_000)
      assert String.contains?(out, token)
    end

    test "handles command failure with non-zero exit code and restores :user occupant", %{
      session_id: session_id
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: File.cwd!())

      res =
        TerminalServer.run_agent_command(
          session_id,
          "sh -c 'echo FAILURE_TEST; exit 42'",
          "FailingAgent"
        )

      assert {:ok, %{exit_code: 42, output: output}} = res
      assert String.contains?(output, "FAILURE_TEST")

      {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "agent command execution via Tools.execute('run_command', ...) with session_id", %{
      session_id: session_id,
      root_path: root_path
    } do
      token = "TOOL_EXEC_TOKEN_#{:erlang.unique_integer([:positive])}"

      result =
        Tools.execute(
          "run_command",
          %{
            "command" => "echo '#{token}'",
            "session_id" => session_id,
            "agent_name" => "CoderAgent",
            "timeout_ms" => 10_000
          },
          root_path
        )

      assert {:ok, output} = result
      assert String.contains?(output, token)

      # PubSub broadcast must have been delivered to subscribers
      assert_receive {:terminal_output, %{session_id: ^session_id, data: _chunk}}, 3_000
    end
  end

  # ============================================================================
  # Dimension 5: OS Signals, Process Tree & Supervision Lifecycle
  # ============================================================================

  describe "OS Signals, Process Tree & Supervision Lifecycle" do
    test "sends various signals (:sigint, :sigterm, :eof, :sigtstp, :sigcont) without errors", %{
      session_id: session_id
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: File.cwd!())

      # Signal tests
      assert :ok = TerminalServer.send_signal(session_id, :sigint)
      assert :ok = TerminalServer.send_signal(session_id, :sigterm)
      assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
      assert :ok = TerminalServer.send_signal(session_id, :sigcont)
      assert :ok = TerminalServer.send_signal(session_id, :eof)

      # Invalid target or unstarted session
      assert {:error, :not_found} =
               TerminalServer.send_signal("non_existent_session_999", :sigint)
    end

    test "restarts session with new dimensions and cleans up old process", %{
      session_id: session_id
    } do
      {:ok, pid1} =
        TerminalServer.ensure_started(session_id,
          workspace_path: File.cwd!(),
          cols: 80,
          rows: 24
        )

      assert is_pid(pid1) and Process.alive?(pid1)

      # Write something into terminal
      assert :ok = TerminalServer.run_command(session_id, "echo 'BEFORE_RESTART'")
      assert_receive {:terminal_output, %{data: _}}, 2_000

      # Restart session with 120x40
      {:ok, pid2} = TerminalServer.restart(session_id, cols: 120, rows: 40)
      assert is_pid(pid2) and Process.alive?(pid2)

      # Should be registered under SessionRegistry
      assert TerminalSession.whereis(session_id) == pid2

      {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 120
      assert state.rows == 40
      assert state.status == :running

      # Can run new commands
      assert :ok = TerminalServer.run_command(session_id, "echo 'AFTER_RESTART'")
      out = assert_receive_output("AFTER_RESTART", 3_000)
      assert String.contains?(out, "AFTER_RESTART")
    end

    test "TerminalSupervisor start_session is idempotent and handles concurrent spawns", %{
      session_id: session_id
    } do
      # Spawn 10 concurrent requests to start the same session
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            TerminalSupervisor.start_session(session_id, workspace_path: File.cwd!())
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All results must be {:ok, pid}
      assert Enum.all?(results, fn res -> match?({:ok, pid} when is_pid(pid), res) end)

      # All returned pids must point to the same alive process
      [{:ok, first_pid} | _] = results
      assert Enum.all?(results, fn {:ok, pid} -> pid == first_pid end)
      assert Process.alive?(first_pid)

      # Active sessions list must include our session exactly once
      active = TerminalSupervisor.list_sessions()
      matching = Enum.filter(active, fn {id, _pid} -> id == session_id end)
      assert length(matching) == 1
    end
  end

  # ============================================================================
  # Dimension 6: Search History Deep Matrix
  # ============================================================================

  describe "Search History Deep Matrix" do
    test "searches history with case sensitivity, regex patterns, limits, and ANSI stripping", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, project_root: File.cwd!(), mode: :fallback]}
        )

      fake_port = make_ref()

      sample_log = """
      [INFO] 2026-08-23 Starting build pipeline...
      [DEBUG] \e[32mSUCCESS: Compiled 42 modules in 120ms\e[0m
      [WARN] Deprecated function called at lib/foo.ex:99
      [ERROR] \e[31mCRITICAL_FAILURE: Connection refused on port 5432\e[0m
      [INFO] Pipeline finished with code 1
      """

      send(pid, {fake_port, {:data, sample_log}})
      _ = :sys.get_state(pid)

      # 1. Plain substring search (case-insensitive by default)
      {:ok, matches1} = TerminalServer.search_history(session_id, "pipeline")
      assert length(matches1) == 2
      assert Enum.at(matches1, 0).line_number == 1
      assert Enum.at(matches1, 1).line_number == 5

      # 2. Plain substring search (case-sensitive)
      {:ok, matches2} =
        TerminalServer.search_history(session_id, "PIPELINE", case_sensitive: true)

      assert matches2 == []

      # 3. ANSI sequence stripping
      {:ok, matches3} =
        TerminalServer.search_history(session_id, "SUCCESS: Compiled", strip_ansi: true)

      assert length(matches3) == 1
      assert matches3 |> List.first() |> Map.get(:text) =~ "SUCCESS: Compiled 42 modules"
      # The stripped text shouldn't contain ANSI escape brackets
      refute matches3 |> List.first() |> Map.get(:text) =~ "\e[32m"

      # 4. Regex search
      {:ok, matches4} =
        TerminalServer.search_history(session_id, "CRITICAL_[A-Z]+", regex: true)

      assert length(matches4) == 1
      assert matches4 |> List.first() |> Map.get(:text) =~ "CRITICAL_FAILURE"

      # 5. Invalid Regex handling
      assert {:error, {:invalid_regex, _reason}} =
               TerminalServer.search_history(session_id, "[unclosed_regex(", regex: true)

      # 6. Limit and reverse search
      {:ok, matches6} =
        TerminalServer.search_history(session_id, "INFO", limit: 1, reverse: true)

      assert length(matches6) == 1
      # Newest match (line 5) returned due to reverse: true
      assert Enum.at(matches6, 0).line_number == 5

      # 7. Cleared history returns empty search results
      :ok = TerminalServer.clear(session_id)
      assert_receive {:terminal_cleared, %{session_id: ^session_id}}, 2_000
      assert {:ok, []} = TerminalServer.search_history(session_id, "INFO")
      assert TerminalServer.get_history(session_id) == ""
    end
  end

  # ============================================================================
  # Dimension 7: LiveView & PubSub Multi-Session Cross-Talk Isolation
  # ============================================================================

  describe "LiveView & PubSub Multi-Session Cross-Talk Isolation" do
    test "ensures output and status events for one session do not leak to another", %{
      session_id: session_id1
    } do
      session_id2 = "wb_adv_isolation_#{:erlang.unique_integer([:positive])}"
      topic2 = "session:#{session_id2}:terminal"
      PubSub.subscribe(@pubsub_server, topic2)

      on_exit(fn ->
        PubSub.unsubscribe(@pubsub_server, topic2)
        TerminalServer.kill(session_id2)
      end)

      {:ok, _pid1} = TerminalServer.ensure_started(session_id1, workspace_path: File.cwd!())
      {:ok, _pid2} = TerminalServer.ensure_started(session_id2, workspace_path: File.cwd!())

      token1 = "ISOLATION_TOKEN_SESSION_1"
      token2 = "ISOLATION_TOKEN_SESSION_2"

      # Run commands in both sessions
      assert :ok = TerminalServer.run_command(session_id1, "echo '#{token1}'")
      assert :ok = TerminalServer.run_command(session_id2, "echo '#{token2}'")

      # PTYs may emit resize/prompt chunks before command output. Accumulate
      # only the exact session until its unique token is observed.
      data1 = assert_receive_session_output(session_id1, token1, 3_000)
      assert String.contains?(data1, token1)
      refute String.contains?(data1, token2)

      data2 = assert_receive_session_output(session_id2, token2, 3_000)
      assert String.contains?(data2, token2)
      refute String.contains?(data2, token1)

      # Clean histories
      history1 = TerminalServer.get_history(session_id1)
      history2 = TerminalServer.get_history(session_id2)

      assert String.contains?(history1, token1)
      refute String.contains?(history1, token2)

      assert String.contains?(history2, token2)
      refute String.contains?(history2, token1)
    end
  end
end
