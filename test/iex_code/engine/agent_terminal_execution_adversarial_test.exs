defmodule IexCode.Engine.AgentTerminalExecutionAdversarialTest do
  @moduledoc """
  Adversarial stress-test suite for Milestone 2:
  - search_history/3 with invalid regex, complex patterns, ANSI escapes, case sensitivity, limits, edge cases.
  - Concurrency stress tests on input lock under aggressive user keystroke floods during agent execution.
  """
  use IexCode.DataCase, async: false
  require Logger

  alias IexCode.{Projects, Sessions}
  alias IexCode.Tools.TerminalServer
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup do
    session_id = "adv_test_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    {:ok, project} =
      Projects.create_project(%{
        name: "Adversarial Test Proj",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Adversarial Test Session"
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

    %{session_id: session_id, session: session, project: project, topic: topic}
  end

  # ============================================================================
  # SECTION 1: Adversarial search_history/3 - Regex & Syntax Handling
  # ============================================================================

  describe "Adversarial search_history/3 - Regex syntax and complex patterns" do
    test "invalid regex syntax returns {:error, {:invalid_regex, _}} without crashing GenServer",
         %{session_id: session_id, project: project} do
      {:ok, pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      :ok = TerminalServer.run_command(session_id, "echo 'hello world test'")
      assert {:ok, _} = receive_matching_output(session_id, "hello world test")

      # 1. Unclosed bracket
      assert {:error, {:invalid_regex, _reason}} =
               TerminalServer.search_history(session_id, "[unclosed bracket", is_regex: true)

      # 2. Invalid group syntax
      assert {:error, {:invalid_regex, _reason}} =
               TerminalServer.search_history(session_id, "(?<invalid_group", is_regex: true)

      # 3. Leading repetition operator
      assert {:error, {:invalid_regex, _reason}} =
               TerminalServer.search_history(session_id, "*leading_star", is_regex: true)

      # 4. Unmatched parenthesis
      assert {:error, {:invalid_regex, _reason}} =
               TerminalServer.search_history(session_id, "hello(world", regex: true)

      # Crucial: verify GenServer process is still alive and responsive after multiple invalid queries
      assert Process.alive?(pid)
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.status == :running

      # Subsequent valid search still works immediately
      assert {:ok, matches} = TerminalServer.search_history(session_id, "hello world")
      assert length(matches) >= 1
    end

    test "handles complex regex patterns (lookarounds, lazy quantifiers, boundary assertions)",
         %{session_id: session_id, project: project} do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      token_data = """
      [INFO] 2026-08-23 12:00:01 worker_1: processed 45 items in 120ms
      [WARN] 2026-08-23 12:00:02 worker_2: processed 0 items in 5ms
      [ERROR] 2026-08-23 12:00:03 worker_3: failed code=503 reason=timeout
      [FATAL] 2026-08-23 12:00:04 supervisor: crashed with exit_status=1
      """

      for line <- String.split(token_data, "\n", trim: true) do
        :ok = TerminalServer.run_command(session_id, "echo '#{line}'")
      end

      assert {:ok, _} = receive_matching_output(session_id, "exit_status=1")

      # Pattern 1: Non-capturing group with alternatives
      assert {:ok, results1} =
               TerminalServer.search_history(
                 session_id,
                 "\\[(?:ERROR|FATAL)\\]\\s+\\d{4}-\\d{2}-\\d{2}",
                 is_regex: true
               )

      assert length(results1) == 2
      texts1 = Enum.map(results1, & &1.text) |> Enum.join(" ")
      assert String.contains?(texts1, "ERROR")
      assert String.contains?(texts1, "FATAL")

      # Pattern 2: Word boundary + digits matching
      assert {:ok, results2} =
               TerminalServer.search_history(session_id, "\\bworker_\\d+\\b", regex: true)

      assert length(results2) >= 3

      # Pattern 3: Pre-compiled %Regex{} struct
      compiled_re = ~r/code=(\d+)\s+reason=(\w+)/
      assert {:ok, results3} = TerminalServer.search_history(session_id, compiled_re)
      assert length(results3) == 1
      match3 = List.first(results3)
      assert String.contains?(match3.text, "503")
      {s, e} = match3.match_range
      assert String.slice(match3.text, s, e - s) == "code=503 reason=timeout"
    end

    test "special regex characters are escaped when is_regex: false (plain text query)", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      raw_str = "Price: $100.00 (tax incl.) [item*] ^start+end?"
      :ok = TerminalServer.run_command(session_id, "echo '#{raw_str}'")
      assert {:ok, _} = receive_matching_output(session_id, "$100.00")

      # Exact match with special characters without regex mode
      assert {:ok, results} = TerminalServer.search_history(session_id, "$100.00 (tax incl.)")
      assert length(results) >= 1
      match = List.first(results)
      {s, e} = match.match_range
      assert String.slice(match.text, s, e - s) == "$100.00 (tax incl.)"

      # Search for brackets and asterisks
      assert {:ok, results2} = TerminalServer.search_history(session_id, "[item*]")
      assert length(results2) >= 1
    end
  end

  # ============================================================================
  # SECTION 2: Adversarial search_history/3 - Case Sensitivity & Unicode
  # ============================================================================

  describe "Adversarial search_history/3 - Case sensitivity and Unicode characters" do
    test "case_sensitive toggling across plain text and regex modes", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      payload = "DATABASE_CONNECTION_POOL_OVERFLOW_CRITICAL"
      :ok = TerminalServer.run_command(session_id, "echo '#{payload}'")
      assert {:ok, _} = receive_matching_output(session_id, payload)

      # 1. Plain text case_sensitive: false -> matches
      assert {:ok, res_ci} =
               TerminalServer.search_history(session_id, "database_connection_pool",
                 case_sensitive: false
               )

      assert length(res_ci) >= 1

      # 2. Plain text case_sensitive: true -> does not match lowercase
      assert {:ok, res_cs_fail} =
               TerminalServer.search_history(session_id, "database_connection_pool",
                 case_sensitive: true
               )

      assert res_cs_fail == []

      # 3. Plain text case_sensitive: true -> matches exact uppercase
      assert {:ok, res_cs_ok} =
               TerminalServer.search_history(session_id, "DATABASE_CONNECTION_POOL",
                 case_sensitive: true
               )

      assert length(res_cs_ok) >= 1

      # 4. Regex mode case_sensitive: false -> matches
      assert {:ok, res_re_ci} =
               TerminalServer.search_history(session_id, "pool_overflow_[a-z]+",
                 is_regex: true,
                 case_sensitive: false
               )

      assert length(res_re_ci) >= 1

      # 5. Regex mode case_sensitive: true -> does not match
      assert {:ok, res_re_cs} =
               TerminalServer.search_history(session_id, "pool_overflow_[a-z]+",
                 is_regex: true,
                 case_sensitive: true
               )

      assert res_re_cs == []
    end

    test "handles multi-byte UTF-8, emojis, and non-ASCII character matching", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      unicode_line = "🚀 Deploying 測試 release v2.5.0 in München 🇩🇪"
      :ok = TerminalServer.run_command(session_id, "echo '#{unicode_line}'")
      assert {:ok, _} = receive_matching_output(session_id, "release v2.5.0")

      # Search Chinese characters
      assert {:ok, res_zh} = TerminalServer.search_history(session_id, "測試")
      assert length(res_zh) >= 1
      assert String.contains?(List.first(res_zh).text, "測試")

      # Search emoji
      assert {:ok, res_emoji} = TerminalServer.search_history(session_id, "🚀")
      assert length(res_emoji) >= 1

      # Search umlaut
      assert {:ok, res_de} = TerminalServer.search_history(session_id, "München")
      assert length(res_de) >= 1
    end
  end

  # ============================================================================
  # SECTION 3: Adversarial search_history/3 - Heavy ANSI Color & Escapes
  # ============================================================================

  describe "Adversarial search_history/3 - Heavy ANSI escapes (truecolor, 256-color, bold, cursor)" do
    test "strips complex truecolor, 256-color, bold, and cursor escapes for clean matching", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Construct heavy ANSI escaped strings:
      # Truecolor: \x1b[38;2;255;100;50m
      # 256-color background: \x1b[48;5;235m
      # Bold + Underline: \x1b[1;4m
      # Cursor move / erase: \x1b[2K
      # Reset: \x1b[0m
      ansi_cmd =
        "printf '\\033[38;2;255;80;80m\\033[48;2;20;20;20m\\033[1mTRUECOLOR_BOLD_TOKEN\\033[0m \\033[38;5;46m256COLOR_TOKEN\\033[0m\\n'"

      {:ok, _} =
        TerminalServer.run_agent_command(
          session_id,
          ansi_cmd,
          "VerifierAgent",
          timeout_ms: 5_000
        )

      # 1. Default search with strip_ansi: true matches cleanly
      assert {:ok, results} =
               TerminalServer.search_history(session_id, "TRUECOLOR_BOLD_TOKEN", strip_ansi: true)

      assert length(results) >= 1
      match = List.first(results)
      assert match.text =~ "TRUECOLOR_BOLD_TOKEN"
      assert match.text =~ "256COLOR_TOKEN"
      refute match.text =~ "\e["
      refute match.text =~ "\x1b["

      # Verify match_range points to exact stripped substring
      {start_idx, end_idx} = match.match_range
      matched_sub = String.slice(match.text, start_idx, end_idx - start_idx)
      assert matched_sub == "TRUECOLOR_BOLD_TOKEN"

      # 2. Searching with strip_ansi: false preserves raw escape sequences
      assert {:ok, raw_results} =
               TerminalServer.search_history(session_id, "TRUECOLOR_BOLD_TOKEN",
                 strip_ansi: false
               )

      assert length(raw_results) >= 1
      # Find the match with actual escape bytes in text
      raw_match = Enum.find(raw_results, fn m -> m.text =~ "\e[" or m.text =~ "\x1b[" end)

      assert raw_match != nil,
             "Expected at least one match containing ANSI escape bytes in raw mode, got: #{inspect(raw_results)}"
    end
  end

  # ============================================================================
  # SECTION 4: Adversarial search_history/3 - History Limits, Reverse, Clear, Not Found
  # ============================================================================

  describe "Adversarial search_history/3 - Edge cases, limits, reverse, cleared and missing sessions" do
    test "non-existent session returns {:error, :not_found}", %{session_id: _session_id} do
      missing_id = "completely_nonexistent_session_#{:erlang.unique_integer([:positive])}"
      assert {:error, :not_found} = TerminalServer.search_history(missing_id, "query")
    end

    test "empty buffer returns {:ok, []}", %{session_id: session_id, project: project} do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      assert {:ok, []} = TerminalServer.search_history(session_id, "SOME_QUERY")
      assert {:ok, []} = TerminalServer.search_history(session_id, "")
    end

    test "cleared session history returns {:ok, []} and correctly indexes subsequent output", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      token_before = "BEFORE_CLEAR_TOKEN_111"
      :ok = TerminalServer.run_command(session_id, "echo '#{token_before}'")
      assert {:ok, _} = receive_matching_output(session_id, token_before)

      # Verify searchable before clear
      assert {:ok, res_before} = TerminalServer.search_history(session_id, token_before)
      assert length(res_before) >= 1

      # Clear terminal history
      :ok = TerminalServer.clear(session_id)

      # Immediately after clear, search returns empty
      assert {:ok, []} = TerminalServer.search_history(session_id, token_before)

      # Post-clear output is recorded and searchable
      token_after = "AFTER_CLEAR_TOKEN_222"
      :ok = TerminalServer.run_command(session_id, "echo '#{token_after}'")
      assert {:ok, _} = receive_matching_output(session_id, token_after)

      assert {:ok, res_after} = TerminalServer.search_history(session_id, token_after)
      assert length(res_after) >= 1

      # Old token remains cleared
      assert {:ok, []} = TerminalServer.search_history(session_id, token_before)
    end

    test "respects limit / max_results and reverse ordering", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      batch_token = "BATCH_ITEM_#{:erlang.unique_integer([:positive])}"

      cmd =
        1..10
        |> Enum.map(fn i -> "echo '#{batch_token}_#{i}'" end)
        |> Enum.join("\n")

      :ok = TerminalServer.run_command(session_id, cmd)
      assert {:ok, _} = receive_matching_output(session_id, "#{batch_token}_10")

      # Limit to 3 items
      assert {:ok, limited_results} =
               TerminalServer.search_history(session_id, batch_token, limit: 3)

      assert length(limited_results) == 3

      # Reverse ordering (newest first)
      assert {:ok, normal_results} =
               TerminalServer.search_history(session_id, batch_token, limit: 10, reverse: false)

      assert {:ok, reverse_results} =
               TerminalServer.search_history(session_id, batch_token, limit: 10, reverse: true)

      normal_line_nums = Enum.map(normal_results, & &1.line_number)
      reverse_line_nums = Enum.map(reverse_results, & &1.line_number)

      assert normal_line_nums == Enum.sort(normal_line_nums)
      assert reverse_line_nums == Enum.sort(reverse_line_nums, :desc)
    end
  end

  # ============================================================================
  # SECTION 5: Adversarial Concurrency - Input Lock vs Aggressive User Typing
  # ============================================================================

  describe "Adversarial input lock under concurrent user typing vs agent command execution" do
    test "concurrent user keystroke flood is 100% rejected with {:error, :agent_occupied} without leaking into shell",
         %{session_id: session_id, project: project} do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Drain initial shell prompt
      :ok = TerminalServer.run_command(session_id, "echo 'WARMUP'")
      assert {:ok, _} = receive_matching_output(session_id, "WARMUP")

      agent_token = "AGENT_PROTECTED_EXEC_#{:erlang.unique_integer([:positive])}"
      user_pollute_token = "USER_POLLUTION_LEAK_#{:erlang.unique_integer([:positive])}"

      flood_count = 30

      # A FIFO provides an explicit completion barrier: once occupancy is
      # observed, the agent remains blocked until every flood result is
      # collected. This tests the lock rather than scheduler timing.
      barrier_path =
        Path.join(
          System.tmp_dir!(),
          "iex-code-agent-lock-#{:erlang.unique_integer([:positive])}.fifo"
        )

      {_output, 0} = System.cmd("mkfifo", [barrier_path])
      on_exit(fn -> File.rm(barrier_path) end)

      escaped_barrier_path = barrier_path |> String.replace("'", "'\\''")

      agent_task =
        Task.async(fn ->
          cmd = "read _ < '#{escaped_barrier_path}'; echo '#{agent_token}'"
          TerminalServer.run_agent_command(session_id, cmd, "VerifierAgent", timeout_ms: 10_000)
        end)

      assert_receive {:terminal_occupant,
                      %{
                        session_id: ^session_id,
                        occupant: {:agent, "VerifierAgent", _operation_id}
                      }},
                     5_000

      # Verify state reflects agent occupancy
      {:ok, state_mid} = TerminalServer.get_state(session_id)
      assert match?({:agent, "VerifierAgent", _}, state_mid.occupant)

      # Launch 30 concurrent user input attempts trying to pollute stdin
      user_flood_tasks =
        for i <- 1..flood_count do
          Task.async(fn ->
            res =
              TerminalServer.send_input(
                session_id,
                "echo '#{user_pollute_token}_#{i}'\n"
              )

            res
          end)
        end

      # Collect all user flood responses
      user_results = Task.await_many(user_flood_tasks, 5_000)

      # Every send occurs before the barrier is released, so 100% rejection is
      # required. An accepted input would prove an occupant-lock regression.
      assert Enum.all?(user_results, &(&1 == {:error, :agent_occupied})),
             "Expected every user input to be rejected with :agent_occupied, got: #{inspect(user_results)}"

      assert :ok = File.write(barrier_path, "continue\n")

      # Wait for agent command to finish
      assert {:ok, agent_res} = Task.await(agent_task, 10_000)
      assert agent_res.exit_code == 0
      assert String.contains?(agent_res.output, agent_token)

      # Verify agent output was NOT corrupted by user pollution
      refute String.contains?(agent_res.output, user_pollute_token)

      # Verify occupant state is restored to :user
      assert {:ok, state_final} = TerminalServer.get_state(session_id)
      assert state_final.occupant == :user

      # Verify user input is accepted again after unlock
      unlock_token = "USER_POST_UNLOCK_OK_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.send_input(session_id, "echo '#{unlock_token}'\n")
      assert {:ok, post_output} = receive_matching_output(session_id, unlock_token)
      assert String.contains?(post_output, unlock_token)
    end

    test "occupant lock is reliably released on agent command timeout, non-zero exit, and errors",
         %{session_id: session_id, project: project} do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # 1. Non-zero exit code
      assert {:ok, err_res} =
               TerminalServer.run_agent_command(
                 session_id,
                 "sh -c 'exit 33'",
                 "CoderAgent",
                 timeout_ms: 5_000
               )

      assert err_res.exit_code == 33
      assert {:ok, st1} = TerminalServer.get_state(session_id)
      assert st1.occupant == :user

      # 2. Timeout
      assert {:error, :timeout} =
               TerminalServer.run_agent_command(
                 session_id,
                 "sleep 5",
                 "ExplorerAgent",
                 timeout_ms: 100
               )

      assert {:ok, st2} = TerminalServer.get_state(session_id)
      assert st2.occupant == :user

      # User can immediately execute commands after timeout recovery
      token = "RECOVERED_AFTER_TIMEOUT_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end

    test "rapidly alternating user keystrokes and agent commands preserve lock integrity", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      for i <- 1..5 do
        # Step A: User command
        user_tok = "USER_STEP_#{i}_#{:erlang.unique_integer([:positive])}"
        assert :ok = TerminalServer.run_command(session_id, "echo '#{user_tok}'")
        assert {:ok, _} = receive_matching_output(session_id, user_tok)

        # Step B: Agent command
        agent_tok = "AGENT_STEP_#{i}_#{:erlang.unique_integer([:positive])}"

        assert {:ok, agent_res} =
                 TerminalServer.run_agent_command(
                   session_id,
                   "echo '#{agent_tok}'",
                   "CoderAgent",
                   op_id: "op_step_#{i}"
                 )

        assert agent_res.exit_code == 0
        assert String.contains?(agent_res.output, agent_tok)

        # Step C: Verify occupant is :user
        assert {:ok, st} = TerminalServer.get_state(session_id)
        assert st.occupant == :user
      end
    end

    test "session kill mid-agent-execution terminates after timeout and does not deadlock", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      agent_task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "sleep 10",
            "VerifierAgent",
            timeout_ms: 1_000
          )
        end)

      # Wait for command to start
      Process.sleep(100)

      # Kill session abruptly
      :ok = TerminalServer.kill(session_id)

      # Agent task should return {:error, :timeout} (or exit) within timeout + margin
      res = Task.await(agent_task, 3_000)
      assert match?({:error, :timeout}, res) or match?({:ok, _}, res)
    end
  end

  # ============================================================================
  # SECTION 6: High Volume History & ReDoS Stress Testing
  # ============================================================================

  describe "Adversarial search_history/3 - High volume buffer and ReDoS resistance" do
    test "searches through high volume scrollback buffer efficiently", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Generate 500 lines of log output via fast shell loop
      target_token = "NEEDLE_IN_HAYSTACK_#{:erlang.unique_integer([:positive])}"

      loop_cmd =
        "for i in $(seq 1 500); do if [ $i -eq 250 ]; then echo \"LOG_ENTRY_250: #{target_token}\"; else echo \"LOG_ENTRY_$i: regular status report\"; fi; done"

      {:ok, _} =
        TerminalServer.run_agent_command(session_id, loop_cmd, "VerifierAgent",
          timeout_ms: 10_000
        )

      # Search for the needle
      {time_us, result} =
        :timer.tc(fn ->
          TerminalServer.search_history(session_id, target_token)
        end)

      assert {:ok, matches} = result
      assert length(matches) >= 1
      assert String.contains?(List.first(matches).text, target_token)

      # Performance check: search over 500 lines must complete in under 50ms
      assert time_us < 50_000, "Search took #{time_us / 1000}ms, expected < 50ms"
    end

    test "handles complex regex with greedy backtracking safely", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      payload = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX"
      :ok = TerminalServer.run_command(session_id, "echo '#{payload}'")
      assert {:ok, _} = receive_matching_output(session_id, payload)

      # Search with nested quantifier
      assert {:ok, res} =
               TerminalServer.search_history(session_id, "(a+)+X", is_regex: true)

      assert length(res) >= 1
    end
  end

  # --- Helpers ---

  defp receive_matching_output(session_id, token, timeout \\ 5_000) do
    start_time = System.monotonic_time(:millisecond)
    collect_matching(session_id, token, "", start_time, timeout)
  end

  defp collect_matching(session_id, token, acc, start_time, timeout) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout - elapsed, 0)

    receive do
      {:terminal_output, %{session_id: ^session_id, data: chunk}} ->
        new_acc = acc <> chunk

        if String.contains?(new_acc, token) do
          {:ok, new_acc}
        else
          collect_matching(session_id, token, new_acc, start_time, timeout)
        end
    after
      remaining ->
        {:error, :timeout, acc}
    end
  end
end
