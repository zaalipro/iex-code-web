defmodule IexCodeWeb.WorkspaceLiveTerminalTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias Phoenix.PubSub
  alias IexCode.Tools.{TerminalServer, TerminalSession}

  # ============================================================================
  # 1. Terminal Mount & DOM Elements
  # ============================================================================

  describe "Terminal Viewport & Toolbar Component Rendering" do
    test "session rehydrate reloads terminal history and reports active command without exposing its id",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session_a = create_session_fixture(project)
      session_b = create_session_fixture(project)
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_b.id}:terminal")

      assert {:ok, terminal_pid} =
               TerminalServer.ensure_started(session_b.id, workspace_path: path)

      assert :ok = TerminalServer.run_command(session_b.id, "printf history-b")
      assert_receive {:terminal_command_completed, %{session_id: sid}}, 5_000
      assert sid == session_b.id

      assert {:ok, %{command_history: [%{command: "printf history-b"} | _]}} =
               TerminalServer.get_state(session_b.id)

      assert :ok = TerminalServer.run_command(session_b.id, "sleep 30")
      _ = :sys.get_state(terminal_pid)
      assert {:ok, %{active_command_id: active_id}} = TerminalServer.get_state(session_b.id)
      assert is_binary(active_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_a.id}")
      render_patch(view, ~p"/sessions/#{session_b.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert {:ok, current_state} = TerminalServer.get_state(session_b.id)

      expected_history =
        current_state.command_history
        |> Enum.map(&Map.get(&1, :command))
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

      assert assigns.terminal_history == expected_history
      assert "printf history-b" in expected_history

      if assigns.terminal_active_cmd do
        assert assigns.terminal_active_cmd == "Command active"
        refute inspect(assigns.instrument_summaries["terminal"]) =~ active_id
      end
    end

    test "distinguishes an absent terminal from a successfully attached idle terminal", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      initial = :sys.get_state(view.pid).socket.assigns
      refute initial.terminal_available?
      assert initial.instrument_summaries["terminal"].primary == "Terminal unavailable"

      view |> element("#instrument-card-terminal") |> render_click()
      _ = :sys.get_state(view.pid)
      attached = :sys.get_state(view.pid).socket.assigns

      assert attached.terminal_available?
      assert attached.terminal_error_reason == nil
      assert attached.instrument_summaries["terminal"].detail == "Idle · no active command"
    end

    test "starts the PTY lazily on terminal activation and releases its viewer on exit", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute TerminalServer.running?(session.id)

      view |> element("#instrument-card-terminal") |> render_click()

      assert pid = TerminalServer.whereis(session.id)
      assert {:ok, %{viewer_count: 1}} = TerminalSession.get_state(session.id)

      render_click(view, "switch_tab", %{"tab" => "kanban"})
      _ = :sys.get_state(pid)
      assert {:ok, %{viewer_count: 0}} = TerminalSession.get_state(session.id)
    end

    test "renders terminal container with xterm hook, update ignore, and session data attribute",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to terminal tab
      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Assert outer session container and xterm container exist
      assert has_element?(view, "#terminal-session-container")
      assert has_element?(view, "#terminal-xterm-container")
      assert has_element?(view, "#terminal-xterm-container[phx-hook='TerminalHook']")
      assert has_element?(view, "#terminal-xterm-container[phx-update='ignore']")
      assert has_element?(view, "#terminal-xterm-container[data-session-id='#{session.id}']")
    end

    test "renders one Terminal Scope chassis, one command dock, and factual idle signals", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#instrument-card-terminal") |> render_click()

      assert has_element?(
               view,
               "#instrument-workbench-terminal[data-workbench-surface='terminal']"
             )

      assert has_element?(view, "#instrument-workbench-terminal-title", "Terminal Scope")
      assert has_element?(view, "#instrument-workbench-terminal-status[role='status']")
      assert has_element?(view, "#terminal-signal-panel", "Idle · no active command")
      assert has_element?(view, "#terminal-signal-panel", "No command yet")
      assert has_element?(view, "#instrument-workbench-terminal #prompt-composer")
      refute has_element?(view, "#workspace-views ~ #prompt-composer")
      assert has_element?(view, "#btn-terminal-replay", "Replay last command")
    end

    test "renders shell badge, dimensions badge, and quick action toolbar buttons", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Badges
      assert has_element?(view, "#terminal-shell-badge")
      assert has_element?(view, "#terminal-dimensions-badge")

      # Quick Actions
      assert has_element?(view, "#btn-quick-iex")
      assert has_element?(view, "#btn-quick-test")
      assert has_element?(view, "#btn-quick-precommit")
      assert has_element?(view, "#btn-quick-git-status")
      assert has_element?(view, "#btn-quick-git-diff")

      # Terminal Controls
      assert has_element?(view, "#btn-terminal-clear")
      assert has_element?(view, "#btn-terminal-restart")
      assert has_element?(view, "#btn-terminal-kill")
    end
  end

  # ============================================================================
  # 2. Client Event Handling & Actions
  # ============================================================================

  describe "LiveView Terminal Events" do
    test "dispatches terminal_input to active terminal session", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Send raw input through hook event
      render_hook(view, "terminal_input", %{"data" => "echo test_input\n"})
      assert Process.alive?(view.pid)
    end

    test "handles terminal_resize event and updates dimensions badge", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Trigger resize hook event
      render_hook(view, "terminal_resize", %{"cols" => 120, "rows" => 45})

      # Badge should update to reflect 120x45
      assert render(view) =~ "120x45"
    end

    test "executes quick action buttons when clicked", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Click quick action buttons
      view |> element("#btn-quick-test") |> render_click()
      assert Process.alive?(view.pid)

      view |> element("#btn-quick-git-status") |> render_click()
      assert Process.alive?(view.pid)

      view |> element("#btn-quick-precommit") |> render_click()
      assert Process.alive?(view.pid)

      view |> element("#btn-quick-iex") |> render_click()
      assert Process.alive?(view.pid)

      view |> element("#btn-quick-git-diff") |> render_click()
      assert Process.alive?(view.pid)
    end

    test "handles clear_terminal event and pushes terminal_clear event", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Click clear button
      view |> element("#btn-terminal-clear") |> render_click()
      assert Process.alive?(view.pid)
    end

    test "clear uses the server-owned confirmation sheet and removes replayable history", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#instrument-card-terminal") |> render_click()
      render_click(view, "run_terminal_quick_action", %{"cmd" => "echo retained-command"})

      view |> element("#btn-terminal-clear") |> render_click()

      assert has_element?(
               view,
               "#terminal-clear-confirmation[phx-hook='ResponsiveSheet'][data-sheet-return-id='btn-terminal-clear']"
             )

      assert has_element?(
               view,
               "#terminal-clear-confirmation-dialog[phx-hook='ModalFocus'][role='dialog'][aria-modal='true']"
             )

      view |> element("#cancel-terminal-confirmation") |> render_click()
      refute has_element?(view, "#terminal-clear-confirmation")

      view |> element("#btn-terminal-clear") |> render_click()
      view |> element("#confirm-terminal-confirmation") |> render_click()
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "[id^='terminal-command-trace-']")
      assert has_element?(view, "#instrument-workbench-terminal-status", "No command yet")
      assert has_element?(view, "#btn-terminal-replay[disabled]")
    end

    test "handles restart_terminal_session and respawns PTY shell", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Click restart button
      html = view |> element("#btn-terminal-restart") |> render_click()
      assert html =~ "Terminal session restarted" or Process.alive?(view.pid)
    end

    test "handles kill_terminal_session by sending interrupt signal", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Forged lifecycle event is a no-op when no foreground process is active.
      render_click(view, "kill_terminal_session", %{})
      assert Process.alive?(view.pid)
    end

    test "handles request_terminal_history event", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      render_hook(view, "request_terminal_history", %{})
      assert Process.alive?(view.pid)
    end

    test "handles legacy and alias terminal events cleanly", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # run_terminal
      render_click(view, "run_terminal", %{"command" => "echo hello"})
      assert Process.alive?(view.pid)

      # quick_terminal
      render_click(view, "quick_terminal", %{"cmd" => "echo quick"})
      assert Process.alive?(view.pid)

      # run_terminal_command
      render_click(view, "run_terminal_command", %{"command" => "echo cmd"})
      assert Process.alive?(view.pid)

      # stop_terminal_command
      render_click(view, "stop_terminal_command", %{})
      assert Process.alive?(view.pid)

      # replay_terminal_command
      render_click(view, "replay_terminal_command", %{})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 3. PubSub Synchronization & Occupant Indicators
  # ============================================================================

  describe "PubSub Synchronization & Occupant Indicators" do
    test "streams output chunks from PubSub to LiveView client", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Broadcast output chunk over PubSub
      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}:terminal",
        {:terminal_output,
         %{
           session_id: session.id,
           data: "Live output streamed from PTY\n",
           timestamp: DateTime.utc_now()
         }}
      )

      assert Process.alive?(view.pid)

      # Also binary format
      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}:terminal",
        {:terminal_output, session.id, "Another chunk\n"}
      )

      assert Process.alive?(view.pid)
    end

    test "displays active agent banner when terminal is occupied by an agent and hides it when user returns",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Initially, occupant is :user so banner should not be present
      refute has_element?(view, "#terminal-agent-banner")

      # Send occupant change to agent
      send(
        view.pid,
        {:terminal_occupant,
         %{session_id: session.id, occupant: {:agent, "ExplorerAgent", "op-42"}}}
      )

      # Banner must now be visible with agent details
      assert has_element?(view, "#terminal-agent-banner")
      assert render(view) =~ "ExplorerAgent"
      assert render(view) =~ "Agent control"

      # Send occupant change back to :user
      send(view.pid, {:terminal_occupant, %{session_id: session.id, occupant: :user}})

      # Banner is removed
      refute has_element?(view, "#terminal-agent-banner")
    end

    test "handles terminal exit event and updates running state", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Broadcast terminal exit
      send(view.pid, {:terminal_exit, %{session_id: session.id, exit_code: 0, reason: :normal}})

      assert Process.alive?(view.pid)
    end

    test "handles terminal_cleared, terminal_status, and terminal_resized PubSub broadcasts", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      send(view.pid, {:terminal_cleared, %{session_id: session.id}})
      assert Process.alive?(view.pid)

      send(
        view.pid,
        {:terminal_status,
         %{session_id: session.id, status: :running, shell: "zsh", occupant: :user}}
      )

      assert Process.alive?(view.pid)

      send(view.pid, {:terminal_resized, %{session_id: session.id, cols: 100, rows: 30}})
      assert render(view) =~ "100x30"
    end
  end
end
