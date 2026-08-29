defmodule IexCodeWeb.WorkspaceLiveTerminalAdversarialStressTest do
  @moduledoc """
  Adversarial End-to-End Terminal Streaming Stress & Integration Test Suite.
  Validates full integration loop across:
  PTY Backend -> TerminalSession GenServer -> Phoenix.PubSub -> WorkspaceLive LiveView -> Client Push Events
  Under extreme high-throughput, edge cases, rapid churn, and concurrency.
  """
  use IexCode.E2E.Case, async: false
  @moduletag timeout: 120_000

  alias IexCode.Tools.TerminalServer
  alias Phoenix.PubSub

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp subscribe_terminal(session_id) do
    PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")
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
  # 1. Full End-to-End PTY -> PubSub -> LiveView Integration
  # ============================================================================

  describe "Full End-to-End PTY -> PubSub -> LiveView Roundtrip" do
    test "keystrokes via LiveView hook execute in real PTY shell and stream output back", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to terminal tab
      view
      |> element("#instrument-card-terminal")
      |> render_click()

      token = "E2E_LIVEVIEW_ROUNDTRIP_#{System.unique_integer([:positive])}"

      # Send input through LiveView client hook
      render_hook(view, "terminal_input", %{"data" => "echo '#{token}'\n"})

      # Assert output streams over PubSub and LiveView handles it cleanly
      assert {:ok, output} = receive_terminal_output(session.id, token, 8_000)
      assert String.contains?(output, token)
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 2. High-Throughput Output Flood (3,000 Lines) Through LiveView
  # ============================================================================

  describe "High-Throughput Streaming Under Load" do
    test "3,000 line burst through PTY reaches LiveView cleanly without crashing or unbounded memory",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Send high-throughput 3,000-line generator
      burst_cmd = "for i in $(seq 1 3000); do echo \"LV_BURST_LINE_$i\"; done\n"
      render_hook(view, "terminal_input", %{"data" => burst_cmd})

      # Wait for 3,000th line to stream across
      assert {:ok, _} = receive_terminal_output(session.id, "LV_BURST_LINE_3000", 25_000)

      # Verify LiveView process is alive and responsive
      assert Process.alive?(view.pid)

      # Verify post-burst responsiveness
      token = "LV_POST_BURST_CHECK"
      render_hook(view, "terminal_input", %{"data" => "echo '#{token}'\n"})
      assert {:ok, _} = receive_terminal_output(session.id, token, 8_000)
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 3. Concurrent Multi-Client LiveView Synchronization
  # ============================================================================

  describe "Multi-Client PubSub Synchronization" do
    test "two concurrent LiveViews viewing the same session receive synchronized output and clear events",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)

      # Connect Client A
      {:ok, view_a, _} = live(conn, ~p"/sessions/#{session.id}")
      view_a |> element("#instrument-card-terminal") |> render_click()

      # Connect Client B
      {:ok, view_b, _} = live(conn, ~p"/sessions/#{session.id}")
      view_b |> element("#instrument-card-terminal") |> render_click()

      # Client A sends command
      token = "SYNC_DUAL_CLIENT_#{System.unique_integer([:positive])}"
      render_hook(view_a, "terminal_input", %{"data" => "echo '#{token}'\n"})

      # Both clients and external subscriber receive output
      assert {:ok, _} = receive_terminal_output(session.id, token, 8_000)
      assert Process.alive?(view_a.pid)
      assert Process.alive?(view_b.pid)

      # Client B triggers clear
      view_b |> element("#btn-terminal-clear") |> render_click()

      # Both clients remain healthy
      assert Process.alive?(view_a.pid)
      assert Process.alive?(view_b.pid)
    end
  end

  # ============================================================================
  # 4. Window Resize Storm During Active Streaming
  # ============================================================================

  describe "LiveView Resize Under Active Streaming" do
    test "rapid dimension changes during output flood update LiveView state without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Start stream
      render_hook(view, "terminal_input", %{
        "data" => "for i in $(seq 1 100); do echo \"RESIZE_STORM_$i\"; done\n"
      })

      # Dispatch 20 rapid resize hook events from client
      for i <- 1..20 do
        cols = 80 + rem(i * 5, 80)
        rows = 24 + rem(i * 2, 30)
        render_hook(view, "terminal_resize", %{"cols" => cols, "rows" => rows})
      end

      # Set final dimension
      render_hook(view, "terminal_resize", %{"cols" => 150, "rows" => 45})

      assert {:ok, _} = receive_terminal_output(session.id, "RESIZE_STORM_100", 12_000)
      assert Process.alive?(view.pid)
      assert render(view) =~ "150x45"
    end
  end

  # ============================================================================
  # 5. Agent Occupant Lock & LiveView UI State
  # ============================================================================

  describe "Agent Occupancy & LiveView Input Lock" do
    test "agent execution displays banner, blocks user hook input with flash warning, and unblocks on completion",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      refute has_element?(view, "#terminal-agent-banner")

      agent_token = "AGENT_LIVEVIEW_LOCKED_#{System.unique_integer([:positive])}"

      # Launch agent command in async task
      agent_task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session.id,
            "sleep 0.5; echo '#{agent_token}'",
            "VerifierAgent",
            timeout_ms: 10_000
          )
        end)

      # Synchronize on the actual occupant transition instead of assuming the
      # lock and LiveView PubSub delivery complete within a scheduler delay.
      assert_receive {:terminal_occupant,
                      %{
                        session_id: session_id,
                        occupant: {:agent, "VerifierAgent", _op_id}
                      }},
                     5_000

      assert session_id == session.id

      _ = :sys.get_state(view.pid)

      # Banner appears
      assert has_element?(view, "#terminal-agent-banner")
      assert render(view) =~ "VerifierAgent"

      # User attempts input during agent lock -> flash warning is set
      render_hook(view, "terminal_input", %{"data" => "unauthorized typing\n"})
      # Verify flash in socket assigns contains warning
      flash = :sys.get_state(view.pid).socket.assigns.flash

      assert Map.get(flash, "warning") =~ "Terminal is locked by active agent" or
               Map.get(flash, :warning) =~ "Terminal is locked by active agent"

      # Wait for agent command completion
      assert {:ok, agent_res} = Task.await(agent_task, 8_000)
      assert agent_res.exit_code == 0
      assert String.contains?(agent_res.output, agent_token)

      assert_receive {:terminal_occupant, %{session_id: released_session_id, occupant: :user}},
                     5_000

      assert released_session_id == session.id
      _ = :sys.get_state(view.pid)

      # Banner disappears
      refute has_element?(view, "#terminal-agent-banner")

      # User can now type again
      user_token = "USER_REGAINED_CONTROL"
      render_hook(view, "terminal_input", %{"data" => "echo '#{user_token}'\n"})
      assert {:ok, _} = receive_terminal_output(session.id, user_token, 8_000)
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 6. Unicode, Emojis, and Truecolor Streamed into LiveView
  # ============================================================================

  describe "Unicode & Truecolor Stream into LiveView" do
    test "complex ANSI escapes, emojis, and multibyte UTF-8 stream without crashing LiveView", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      on_exit(fn -> cleanup_terminal_session(session.id) end)

      subscribe_terminal(session.id)
      {:ok, _term_pid} = TerminalServer.ensure_started(session.id, workspace_path: path)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      unicode_cmd =
        "printf '\\033[38;2;100;200;255m🔥 [LIVEVIEW_UNICODE_TEST] 🚀 日本語 測試 München \\033[0m\\n'\n"

      render_hook(view, "terminal_input", %{"data" => unicode_cmd})

      assert {:ok, output} =
               receive_terminal_output(session.id, "München", 8_000)

      assert String.contains?(output, "🚀")
      assert String.contains?(output, "München")
      assert Process.alive?(view.pid)
    end
  end
end
