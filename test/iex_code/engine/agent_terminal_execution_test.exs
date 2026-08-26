defmodule IexCode.Engine.AgentTerminalExecutionTest do
  use IexCode.DataCase, async: false
  require Logger

  alias IexCode.{Projects, Sessions}
  alias IexCode.Tools.{TerminalServer, TerminalSession}
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup do
    session_id = "agent_exec_test_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    {:ok, project} =
      Projects.create_project(%{
        name: "Agent Term Test Proj",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Agent Term Test Session"
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
  # Describe 1: Agent Command Dispatch via TerminalServer
  # ============================================================================

  describe "Agent command dispatch via VerifierAgent / CoderAgent / ExplorerAgent" do
    test "synchronously executes command for VerifierAgent with clean output", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      token = "VERIFIER_OK_#{:erlang.unique_integer([:positive])}"

      {:ok, result} =
        TerminalServer.run_agent_command(
          session_id,
          "echo '#{token}'",
          "VerifierAgent",
          op_id: "op_verify_1",
          timeout_ms: 10_000
        )

      assert is_map(result)
      assert result.exit_code == 0
      assert String.contains?(result.output, token)
      assert is_integer(result.duration_ms) and result.duration_ms >= 0

      # Occupant state is restored to :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "captures non-zero exit codes from CoderAgent commands", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      {:ok, result} =
        TerminalServer.run_agent_command(
          session_id,
          "sh -c 'exit 19'",
          "CoderAgent",
          op_id: "op_coder_err",
          timeout_ms: 10_000
        )

      assert result.exit_code == 19
    end

    test "handles command timeout gracefully and resets occupant", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Attempt command with very short timeout
      result =
        TerminalServer.run_agent_command(
          session_id,
          "sleep 10",
          "ExplorerAgent",
          timeout_ms: 200
        )

      assert result == {:error, :timeout}

      # Occupant must be reset to :user even after timeout
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "streams live terminal output chunks over PubSub during agent execution", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      token = "STREAM_AGENT_PUB_#{:erlang.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "echo '#{token}'",
            "VerifierAgent",
            timeout_ms: 8_000
          )
        end)

      # PubSub subscriber receives output chunk
      assert {:ok, output} = receive_matching_output(session_id, token, 8_000)
      assert String.contains?(output, token)

      assert {:ok, res} = Task.await(task, 10_000)
      assert res.exit_code == 0
    end
  end

  # ============================================================================
  # Describe 2: Telemetry Events Verification (All 5 Events)
  # ============================================================================

  describe "Telemetry events verification" do
    test "emits all 5 terminal telemetry events with measurements and metadata", %{
      session_id: session_id,
      project: project
    } do
      test_pid = self()
      handler_id = "test-term-telemetry-#{session_id}-#{:erlang.unique_integer([:positive])}"

      events = [
        [:iex_code, :terminal, :session_started],
        [:iex_code, :terminal, :command_dispatched],
        [:iex_code, :terminal, :output_chunk],
        [:iex_code, :terminal, :command_completed],
        [:iex_code, :terminal, :session_stopped]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          if metadata[:session_id] == session_id do
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # 1. Start Session -> [:iex_code, :terminal, :session_started]
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id,
          workspace_path: project.root_path,
          cols: 90,
          rows: 30
        )

      assert_receive {:telemetry_event, [:iex_code, :terminal, :session_started],
                      measurements_start, metadata_start},
                     5_000

      assert is_map(measurements_start)
      assert metadata_start.session_id == session_id
      assert metadata_start.cols == 90
      assert metadata_start.rows == 30

      # 2 & 3 & 4. Run Agent Command -> command_dispatched, output_chunk, command_completed
      token = "TELEMETRY_TEST_TOKEN_#{:erlang.unique_integer([:positive])}"

      {:ok, _res} =
        TerminalServer.run_agent_command(
          session_id,
          "echo '#{token}'",
          "VerifierAgent",
          op_id: "op_telem_1"
        )

      assert_receive {:telemetry_event, [:iex_code, :terminal, :command_dispatched],
                      measurements_disp, metadata_disp},
                     5_000

      assert is_map(measurements_disp)
      assert metadata_disp.session_id == session_id
      assert String.contains?(metadata_disp.command, token)

      assert_receive {:telemetry_event, [:iex_code, :terminal, :output_chunk], measurements_chunk,
                      metadata_chunk},
                     5_000

      assert is_integer(measurements_chunk.byte_size) and measurements_chunk.byte_size > 0
      assert metadata_chunk.session_id == session_id
      assert is_binary(metadata_chunk.data)

      assert_receive {:telemetry_event, [:iex_code, :terminal, :command_completed],
                      measurements_comp, metadata_comp},
                     5_000

      assert is_integer(measurements_comp.duration_ms) and measurements_comp.duration_ms >= 0
      assert metadata_comp.session_id == session_id
      assert metadata_comp.exit_code == 0

      # 5. Stop Session -> [:iex_code, :terminal, :session_stopped]
      :ok = TerminalServer.kill(session_id)

      assert_receive {:telemetry_event, [:iex_code, :terminal, :session_stopped],
                      measurements_stop, metadata_stop},
                     5_000

      assert is_map(measurements_stop)
      assert metadata_stop.session_id == session_id
    end
  end

  # ============================================================================
  # Describe 3: Visual Occupant Transitions & PubSub Broadcasts
  # ============================================================================

  describe "Visual occupant state transitions" do
    test "transitions :user -> {:agent, name, op_id} -> :user with PubSub events", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Initial state is :user
      assert {:ok, state0} = TerminalServer.get_state(session_id)
      assert state0.occupant == :user

      # Run agent command in async task
      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "echo OCCUPANT_CYCLE",
            "CoderAgent",
            op_id: "op_occ_42"
          )
        end)

      # PubSub broadcast indicates occupant changed to agent
      assert_receive {:terminal_occupant,
                      %{session_id: ^session_id, occupant: {:agent, "CoderAgent", "op_occ_42"}}},
                     5_000

      {:ok, _} = Task.await(task, 10_000)

      # PubSub broadcast indicates occupant restored to :user
      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}},
                     5_000

      assert {:ok, state_final} = TerminalServer.get_state(session_id)
      assert state_final.occupant == :user
    end

    test "explicit set_occupant transitions and broadcasts", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Set to PlannerAgent
      assert :ok =
               TerminalSession.set_occupant(session_id, {:agent, "PlannerAgent", "op_plan_1"})

      assert_receive {:terminal_occupant,
                      %{session_id: ^session_id, occupant: {:agent, "PlannerAgent", "op_plan_1"}}},
                     3_000

      assert {:ok, state1} = TerminalServer.get_state(session_id)
      assert state1.occupant == {:agent, "PlannerAgent", "op_plan_1"}

      # Reset to :user
      assert :ok = TerminalSession.set_occupant(session_id, :user)

      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}},
                     3_000

      assert {:ok, state2} = TerminalServer.get_state(session_id)
      assert state2.occupant == :user
    end
  end

  # ============================================================================
  # Describe 4: Searchable Terminal History API
  # ============================================================================

  describe "Terminal history search (search_history/3)" do
    test "exact string match in terminal scrollback", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      token = "EXACT_QUERY_ALPHA_99"
      :ok = TerminalServer.run_command(session_id, "echo '#{token}'")
      assert {:ok, _} = receive_matching_output(session_id, token)

      assert {:ok, results} = TerminalServer.search_history(session_id, "EXACT_QUERY_ALPHA")
      assert is_list(results)
      assert length(results) >= 1

      match = Enum.find(results, &String.contains?(&1.text, token))
      assert match != nil
      assert match.line_number > 0
      assert is_tuple(match.match_range)
      {start_idx, end_idx} = match.match_range
      assert String.slice(match.text, start_idx, end_idx - start_idx) == "EXACT_QUERY_ALPHA"
    end

    test "regex pattern matching in scrollback", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      err_token1 = "ERR_CODE_404_NOT_FOUND"
      err_token2 = "ERR_CODE_500_SERVER_PANIC"

      :ok = TerminalServer.run_command(session_id, "echo '#{err_token1}'")
      assert {:ok, _} = receive_matching_output(session_id, err_token1)

      :ok = TerminalServer.run_command(session_id, "echo '#{err_token2}'")
      assert {:ok, _} = receive_matching_output(session_id, err_token2)

      assert {:ok, results} =
               TerminalServer.search_history(session_id, "ERR_CODE_(\\d+)_.*", is_regex: true)

      assert length(results) >= 2
      texts = Enum.map(results, & &1.text) |> Enum.join(" ")
      assert String.contains?(texts, "404")
      assert String.contains?(texts, "500")
    end

    test "case sensitivity handling in search_history", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      mixed_token = "MiXeD_CaSe_ToKeN_77"
      :ok = TerminalServer.run_command(session_id, "echo '#{mixed_token}'")
      assert {:ok, _} = receive_matching_output(session_id, mixed_token)

      # Case insensitive search finds match
      assert {:ok, insensitive_matches} =
               TerminalServer.search_history(session_id, "mixed_case_token",
                 case_sensitive: false
               )

      assert length(insensitive_matches) >= 1

      # Case sensitive search fails to find lowercase mismatch
      assert {:ok, sensitive_matches} =
               TerminalServer.search_history(session_id, "mixed_case_token", case_sensitive: true)

      assert sensitive_matches == []
    end

    test "multi-line search results and line numbering order", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      prefix = "STEP_SEQUENCE_#{:erlang.unique_integer([:positive])}"

      cmd = """
      echo "#{prefix}_1"
      echo "#{prefix}_2"
      echo "#{prefix}_3"
      """

      :ok = TerminalServer.run_command(session_id, cmd)
      assert {:ok, _} = receive_matching_output(session_id, "#{prefix}_3")

      assert {:ok, results} = TerminalServer.search_history(session_id, prefix)
      matching_lines = Enum.filter(results, &String.contains?(&1.text, prefix))

      assert length(matching_lines) == 3
      line_numbers = Enum.map(matching_lines, & &1.line_number)
      assert line_numbers == Enum.sort(line_numbers)
    end

    test "search_history edge cases (empty buffer, cleared session, not found)", %{
      session_id: session_id,
      project: project
    } do
      # 1. Non-existent session
      assert {:error, :not_found} =
               TerminalServer.search_history("nonexistent_session", "anything")

      # 2. Fresh session with empty history
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      assert {:ok, []} = TerminalServer.search_history(session_id, "NON_EXISTENT_TOKEN_12345")

      # 3. After clear/1
      :ok = TerminalServer.run_command(session_id, "echo 'to be cleared'")
      assert {:ok, _} = receive_matching_output(session_id, "to be cleared")
      :ok = TerminalServer.clear(session_id)
      assert {:ok, []} = TerminalServer.search_history(session_id, "to be cleared")
    end
  end

  # ============================================================================
  # Describe 5: Input Lock Behavior During Agent Terminal Occupation
  # ============================================================================

  describe "Input lock behavior during agent terminal occupation" do
    test "rejects user send_input when terminal is occupied by an agent", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      # Set occupant to agent
      :ok = TerminalSession.set_occupant(session_id, {:agent, "CoderAgent", "op_locked_1"})

      # User input attempt is rejected
      assert {:error, :agent_occupied} =
               TerminalServer.send_input(session_id, "echo 'UNAUTHORIZED_KEYSTROKE'\n")

      # Restore to user
      :ok = TerminalSession.set_occupant(session_id, :user)

      # User input is accepted again
      token = "AUTHORIZED_AFTER_UNLOCK_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.send_input(session_id, "echo '#{token}'\n")
      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)
    end

    test "signal dispatch remains functional during agent lock for emergency abort", %{
      session_id: session_id,
      project: project
    } do
      {:ok, _pid} =
        TerminalServer.ensure_started(session_id, workspace_path: project.root_path)

      :ok = TerminalSession.set_occupant(session_id, {:agent, "VerifierAgent", "op_sig_1"})

      # Signals like SIGINT or SIGKILL are accepted to allow operator interruption
      assert :ok = TerminalServer.send_signal(session_id, :sigint)
    end
  end

  # --- Test Helpers ---

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
