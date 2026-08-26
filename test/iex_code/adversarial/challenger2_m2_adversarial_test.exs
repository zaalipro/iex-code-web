defmodule IexCode.Adversarial.Challenger2M2AdversarialTest do
  @moduledoc """
  Adversarial Challenge Test Suite for Milestone 2 (Agent Terminal Execution & Telemetry Verification).
  Conducted by Challenger 2.

  Adversarial dimensions tested:
  1. Telemetry Stream Integrity under rapid command bursts and concurrency:
     - Full event pipeline verification (session_started, command_dispatched, output_chunk, command_completed, session_stopped)
     - Rapid sequential and concurrent bursts with zero dropped events
     - Telemetry payload metadata and measurement validation
  2. Agent Command Timeout & Occupant State Restoration Guarantee:
     - Forced timeout on long-running/hanging processes
     - Session termination / kill during in-flight agent execution
     - Caller crash recovery
     - Strict guarantee that occupant state is restored to :user and terminal is unlocked
  3. Subagent Tool Execution via `Tools.execute("run_command", ...)`:
     - Live PubSub chunk streaming to listeners
     - Real-time occupant transition broadcasting (:user -> {:agent, ...} -> :user)
     - Progress callback hooks
     - Exit code and error encapsulation
     - Fallback port mode (without session_id)
     - Concurrent multi-session subagent executions
  4. Delimiter Injection, Malicious Strings, and Large Payload Bursts:
     - Malicious fake delimiter strings in command output
     - High-volume binary/text burst handling without collector hangs
  """
  use IexCode.E2E.Case, async: false
  require Logger

  alias IexCode.{Projects, Sessions, Tools}
  alias IexCode.Tools.TerminalServer
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup tags do
    session_id = "chal2_m2_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    root_path = tags[:workspace_path] || File.cwd!()

    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger2 M2 Test Proj",
        root_path: root_path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger2 M2 Test Session"
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
      session: session,
      project: project,
      topic: topic,
      root_path: root_path
    }
  end

  # ============================================================================
  # Section 1: Telemetry Stream Integrity & Concurrency Stress Testing
  # ============================================================================

  describe "Telemetry stream integrity under rapid command bursts" do
    test "zero dropped telemetry events during rapid sequential burst of 15 agent commands", %{
      session_id: session_id,
      root_path: root_path
    } do
      test_pid = self()
      handler_id = "chal2-burst-seq-#{session_id}"

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
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      assert_receive {:telemetry_event, [:iex_code, :terminal, :session_started], _, _}, 5_000

      command_count = 15

      for i <- 1..command_count do
        token = "BURST_SEQ_#{i}_#{:erlang.unique_integer([:positive])}"

        {:ok, res} =
          TerminalServer.run_agent_command(
            session_id,
            "echo '#{token}'",
            "VerifierAgent",
            op_id: "op_burst_#{i}",
            timeout_ms: 5_000
          )

        assert res.exit_code == 0
        assert String.contains?(res.output, token)
      end

      # Collect all telemetry events received
      all_events = collect_all_telemetry_events([])

      dispatched_events =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :command_dispatched]
        end)

      completed_events =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :command_completed]
        end)

      output_chunks =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :output_chunk]
        end)

      assert length(dispatched_events) == command_count,
             "Expected #{command_count} dispatched events, got #{length(dispatched_events)}"

      assert length(completed_events) == command_count,
             "Expected #{command_count} completed events, got #{length(completed_events)}"

      assert length(output_chunks) >= command_count,
             "Expected at least #{command_count} output chunks, got #{length(output_chunks)}"

      # Match each dispatched with completed
      for i <- 1..command_count do
        op_id = "op_burst_#{i}"

        disp =
          Enum.find(dispatched_events, fn {_, _, meta} -> meta.op_id == op_id end)

        comp =
          Enum.find(completed_events, fn {_, _, meta} -> meta.op_id == op_id end)

        assert disp != nil, "Missing command_dispatched for #{op_id}"
        assert comp != nil, "Missing command_completed for #{op_id}"

        {_, _disp_meas, disp_meta} = disp
        {_, comp_meas, comp_meta} = comp

        assert disp_meta.session_id == session_id
        assert disp_meta.agent_name == "VerifierAgent"
        assert comp_meta.session_id == session_id
        assert comp_meta.agent_name == "VerifierAgent"
        assert comp_meta.exit_code == 0
        assert comp_meta.status == :ok
        assert is_integer(comp_meas.duration_ms) and comp_meas.duration_ms >= 0
      end
    end

    test "parallel multi-session telemetry concurrency without event corruption", %{
      root_path: root_path
    } do
      test_pid = self()
      unique_id = :erlang.unique_integer([:positive])
      handler_id = "chal2-parallel-sessions-#{unique_id}"

      events = [
        [:iex_code, :terminal, :session_started],
        [:iex_code, :terminal, :command_dispatched],
        [:iex_code, :terminal, :command_completed],
        [:iex_code, :terminal, :session_stopped]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      num_sessions = 6
      commands_per_session = 4

      session_ids =
        for s <- 1..num_sessions do
          sid = "chal2_par_sess_#{s}_#{unique_id}"
          {:ok, _pid} = TerminalServer.ensure_started(sid, workspace_path: root_path)
          sid
        end

      # Run concurrent commands across all sessions in parallel tasks
      tasks =
        for sid <- session_ids, cmd_idx <- 1..commands_per_session do
          Task.async(fn ->
            token = "PAR_#{sid}_CMD_#{cmd_idx}"
            op_id = "op_par_#{sid}_#{cmd_idx}"

            res =
              TerminalServer.run_agent_command(
                sid,
                "echo '#{token}'",
                "CoderAgent",
                op_id: op_id,
                timeout_ms: 8_000
              )

            {sid, cmd_idx, token, op_id, res}
          end)
        end

      results = Task.await_many(tasks, 15_000)

      for {sid, cmd_idx, token, _op_id, res} <- results do
        assert {:ok, cmd_res} = res,
               "Execution failed for #{sid} cmd #{cmd_idx}: #{inspect(res)}"

        assert cmd_res.exit_code == 0
        assert String.contains?(cmd_res.output, token)
      end

      # Cleanup sessions
      for sid <- session_ids do
        TerminalServer.kill(sid)
      end

      all_events = collect_all_telemetry_events([])

      total_dispatches = num_sessions * commands_per_session

      dispatches =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :command_dispatched]
        end)

      completions =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :command_completed]
        end)

      starts =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :session_started]
        end)

      stops =
        Enum.filter(all_events, fn {ev, _, _} ->
          ev == [:iex_code, :terminal, :session_stopped]
        end)

      assert length(starts) >= num_sessions
      assert length(stops) >= num_sessions
      assert length(dispatches) == total_dispatches
      assert length(completions) == total_dispatches
    end
  end

  # ============================================================================
  # Section 2: Agent Command Timeout & Occupant State Restoration
  # ============================================================================

  describe "Agent command timeout and occupant state restoration" do
    test "hard timeout on blocking command emits error telemetry and restores occupant to :user",
         %{session_id: session_id, root_path: root_path} do
      test_pid = self()
      handler_id = "chal2-timeout-telem-#{session_id}"

      events = [
        [:iex_code, :terminal, :command_dispatched],
        [:iex_code, :terminal, :command_completed]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      # Ensure occupant is initially :user
      assert {:ok, s0} = TerminalServer.get_state(session_id)
      assert s0.occupant == :user

      # Run a command that blocks longer than the timeout
      result =
        TerminalServer.run_agent_command(
          session_id,
          "sleep 10",
          "ExplorerAgent",
          op_id: "op_timeout_test",
          timeout_ms: 300
        )

      assert result == {:error, :timeout}

      # Verify command_completed telemetry is emitted with error status
      assert_receive {:telemetry_event, [:iex_code, :terminal, :command_dispatched], _,
                      disp_meta},
                     2_000

      assert disp_meta.op_id == "op_timeout_test"

      assert_receive {:telemetry_event, [:iex_code, :terminal, :command_completed], comp_meas,
                      comp_meta},
                     2_000

      assert comp_meta.op_id == "op_timeout_test"
      assert comp_meta.status == :error
      assert comp_meta.exit_code == -1
      assert is_integer(comp_meas.duration_ms) and comp_meas.duration_ms >= 200

      # Check occupant is restored to :user immediately
      assert {:ok, state_after} = TerminalServer.get_state(session_id)
      assert state_after.occupant == :user

      # User input can immediately succeed (lock removed)
      token = "UNBLOCKED_USER_INPUT_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.send_input(session_id, "echo '#{token}'\n")
      assert {:ok, _} = receive_matching_output(session_id, token, 5_000)
    end

    test "occupant restored to :user when terminal session is forcibly killed during agent execution",
         %{session_id: session_id, root_path: root_path} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      # Start long running agent command in background task
      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session_id,
            "sleep 30",
            "PlannerAgent",
            op_id: "op_killed_midflight",
            timeout_ms: 10_000
          )
        end)

      # Wait until occupant is set to agent
      assert_receive {:terminal_occupant,
                      %{
                        session_id: ^session_id,
                        occupant: {:agent, "PlannerAgent", "op_killed_midflight"}
                      }},
                     3_000

      # Now forcibly kill the terminal session
      :ok = TerminalServer.kill(session_id)

      # The task should complete with timeout or error or exit
      res = Task.await(task, 12_000)
      assert match?({:error, _}, res)

      # Restart session to verify clean start with :user occupant
      {:ok, _} = TerminalServer.ensure_started(session_id, workspace_path: root_path)
      assert {:ok, state_restarted} = TerminalServer.get_state(session_id)
      assert state_restarted.occupant == :user
    end

    test "caller process exception during agent execution triggers after block cleanup", %{
      session_id: session_id,
      root_path: root_path
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      # Spawn a task that runs run_agent_command with a short timeout and catches it
      task =
        Task.async(fn ->
          try do
            TerminalServer.run_agent_command(
              session_id,
              "sleep 10",
              "VerifierAgent",
              op_id: "op_caller_exc",
              timeout_ms: 300
            )
          rescue
            _ -> :rescued
          end
        end)

      # Wait for occupant lock to be established
      assert_receive {:terminal_occupant,
                      %{
                        session_id: ^session_id,
                        occupant: {:agent, "VerifierAgent", "op_caller_exc"}
                      }},
                     3_000

      # Task finishes via timeout and triggers 'after' block cleanup
      {:error, :timeout} = Task.await(task, 5_000)

      # Occupant is restored to :user
      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}}, 3_000

      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end
  end

  # ============================================================================
  # Section 3: Subagent Tool Execution (Tools.execute("run_command", ...))
  # ============================================================================

  describe "Subagent tool execution via Tools.execute('run_command', ...)" do
    test "executes in terminal session with live PubSub streaming and progress callbacks", %{
      session_id: session_id,
      root_path: root_path
    } do
      test_pid = self()
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      token = "SUBAGENT_STREAM_#{:erlang.unique_integer([:positive])}"

      progress_fn = fn pct, msg ->
        send(test_pid, {:tool_progress, pct, msg})
      end

      task =
        Task.async(fn ->
          Tools.execute(
            "run_command",
            %{
              "command" => "echo '#{token}'",
              "session_id" => session_id,
              "agent_name" => "VerifierAgent",
              "op_id" => "op_tool_exec_1",
              "timeout_ms" => 8_000
            },
            root_path,
            progress_fn
          )
        end)

      # 1. Verify occupant transition to VerifierAgent
      assert_receive {:terminal_occupant,
                      %{
                        session_id: ^session_id,
                        occupant: {:agent, "VerifierAgent", "op_tool_exec_1"}
                      }},
                     4_000

      # 2. Verify live PubSub output stream
      assert {:ok, output_stream} = receive_matching_output(session_id, token, 8_000)
      assert String.contains?(output_stream, token)

      # 3. Verify occupant restored to :user
      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}}, 4_000

      # 4. Verify progress notifications
      assert_receive {:tool_progress, 20, _msg_start}, 4_000
      assert_receive {:tool_progress, 100, _msg_end}, 4_000

      # 5. Verify tool result
      assert {:ok, tool_res} = Task.await(task, 10_000)
      assert String.contains?(tool_res, token)
    end

    test "handles non-zero exit codes in subagent tool execution", %{
      session_id: session_id,
      root_path: root_path
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      res =
        Tools.execute(
          "run_command",
          %{
            "command" => "sh -c 'echo FAIL_MSG; exit 42'",
            "session_id" => session_id,
            "agent_name" => "CoderAgent",
            "op_id" => "op_tool_err"
          },
          root_path,
          fn _, _ -> :ok end
        )

      assert {:ok, output} = res
      assert String.contains?(output, "Exit Code 42:")
      assert String.contains?(output, "FAIL_MSG")

      # Terminal is unlocked
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "handles subagent tool command timeout", %{
      session_id: session_id,
      root_path: root_path
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      res =
        Tools.execute(
          "run_command",
          %{
            "command" => "sleep 5",
            "session_id" => session_id,
            "agent_name" => "ExplorerAgent",
            "timeout_ms" => 250
          },
          root_path,
          fn _, _ -> :ok end
        )

      assert {:error, msg} = res
      assert String.contains?(msg, "timed out")

      # Terminal occupant restored
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "fallback to standalone Port when session_id is omitted or empty", %{
      root_path: root_path
    } do
      test_pid = self()

      progress_fn = fn pct, msg ->
        send(test_pid, {:fallback_progress, pct, msg})
      end

      token = "PORT_FALLBACK_#{:erlang.unique_integer([:positive])}"

      res =
        Tools.execute(
          "run_command",
          %{"command" => "echo '#{token}'"},
          root_path,
          progress_fn
        )

      assert {:ok, output} = res
      assert String.contains?(output, token)
      assert_receive {:fallback_progress, 20, _}, 3_000
      assert_receive {:fallback_progress, 100, _}, 3_000
    end

    test "concurrent subagent tool executions across 4 distinct sessions", %{
      root_path: root_path
    } do
      unique = :erlang.unique_integer([:positive])

      tasks =
        for i <- 1..4 do
          sid = "chal2_tool_par_#{i}_#{unique}"
          {:ok, _pid} = TerminalServer.ensure_started(sid, workspace_path: root_path)

          Task.async(fn ->
            token = "CONCURRENT_TOOL_TOKEN_#{i}_#{unique}"

            res =
              Tools.execute(
                "run_command",
                %{
                  "command" => "echo '#{token}'",
                  "session_id" => sid,
                  "agent_name" => "Agent_#{i}",
                  "op_id" => "op_par_tool_#{i}",
                  "timeout_ms" => 10_000
                },
                root_path,
                fn _, _ -> :ok end
              )

            {sid, token, res}
          end)
        end

      results = Task.await_many(tasks, 15_000)

      for {sid, token, res} <- results do
        assert {:ok, output} = res
        assert String.contains?(output, token)

        assert {:ok, state} = TerminalServer.get_state(sid)
        assert state.occupant == :user

        TerminalServer.kill(sid)
      end
    end
  end

  # ============================================================================
  # Section 4: Delimiter Injection & Stress Output Bursts
  # ============================================================================

  describe "Adversarial delimiter injection and massive output handling" do
    test "adversarial echo attempting to forge exit delimiter string does not corrupt parsing",
         %{session_id: session_id, root_path: root_path} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      # Attempt to forge an exit delimiter with a fake token and fake exit code
      fake_token = "CMD_FIN_99999999"
      cmd = "echo '__AGENT_EXIT:0:TOKEN:#{fake_token}__'; echo 'GENUINE_AFTER_FAKE'"

      {:ok, res} =
        TerminalServer.run_agent_command(
          session_id,
          cmd,
          "CoderAgent",
          timeout_ms: 8_000
        )

      assert res.exit_code == 0
      assert String.contains?(res.output, "GENUINE_AFTER_FAKE")
    end

    test "handles high-volume command output burst without hanging or buffer corruption", %{
      session_id: session_id,
      root_path: root_path
    } do
      {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root_path)

      # Generate ~1000 lines of structured output
      cmd =
        "python3 -c 'for i in range(500): print(f\"LINE_{i:04d}_DATA_PADDING_1234567890\")'"

      {:ok, res} =
        TerminalServer.run_agent_command(
          session_id,
          cmd,
          "ExplorerAgent",
          timeout_ms: 10_000
        )

      assert res.exit_code == 0
      assert String.contains?(res.output, "LINE_0000_DATA")
      assert String.contains?(res.output, "LINE_0499_DATA")
      assert byte_size(res.output) > 10_000
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp collect_all_telemetry_events(acc) do
    receive do
      {:telemetry_event, event, meas, meta} ->
        collect_all_telemetry_events([{event, meas, meta} | acc])
    after
      500 ->
        Enum.reverse(acc)
    end
  end

  defp receive_matching_output(session_id, token, timeout) do
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
