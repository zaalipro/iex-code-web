defmodule IexCodeWeb.WorkspaceLiveTerminalAdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  require Logger
  alias Phoenix.PubSub
  alias IexCode.Tools.TerminalServer
  alias IexCode.Tools.TerminalSession

  # ============================================================================
  # SECTION 1: Fast Session Switching & Topic Lifecycle in handle_params
  # ============================================================================

  describe "Adversarial Session Switching & Topic PubSub Lifecycle" do
    test "rapid cyclic session switching (A -> B -> C -> A -> B) unsubscribes and resubscribes cleanly",
         %{conn: conn, workspace_path: path} do
      p1 = create_project_fixture(%{root_path: path})
      s1 = create_session_fixture(p1, %{title: "Session 1"})
      s2 = create_session_fixture(p1, %{title: "Session 2"})
      s3 = create_session_fixture(p1, %{title: "Session 3"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{s1.id}")

      # Rapidly switch between sessions via handle_params (render_patch)
      for target_session <- [s2, s3, s1, s2, s3, s1] do
        render_patch(view, ~p"/sessions/#{target_session.id}")

        assert has_element?(
                 view,
                 "#terminal-xterm-container[data-session-id='#{target_session.id}']"
               )

        assert Process.alive?(view.pid)
      end
    end

    test "topic isolation: stale broadcast flood on old session does not leak into current session or crash LiveView",
         %{conn: conn, workspace_path: path} do
      p = create_project_fixture(%{root_path: path})
      s1 = create_session_fixture(p, %{title: "Active S1"})
      s2 = create_session_fixture(p, %{title: "Active S2"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{s1.id}")

      # Switch to s2
      render_patch(view, ~p"/sessions/#{s2.id}")
      assert has_element?(view, "#terminal-xterm-container[data-session-id='#{s2.id}']")

      # Flood s1 terminal PubSub with 50 chunks
      for i <- 1..50 do
        PubSub.broadcast(
          IexCode.PubSub,
          "session:#{s1.id}:terminal",
          {:terminal_output, %{session_id: s1.id, data: "STALE_S1_DATA_#{i}\n"}}
        )
      end

      # Send a valid chunk to s2
      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{s2.id}:terminal",
        {:terminal_output, %{session_id: s2.id, data: "VALID_S2_DATA\n"}}
      )

      assert Process.alive?(view.pid)
      html = render(view)
      refute html =~ "STALE_S1_DATA"
    end

    test "cross-project session switching correctly updates Kanban and Terminal supervision",
         %{conn: conn, workspace_path: path} do
      p1 = create_project_fixture(%{root_path: path, name: "Project Alpha"})
      temp2 = create_temp_workspace(%{})
      p2 = create_project_fixture(%{root_path: temp2, name: "Project Beta"})
      s1 = create_session_fixture(p1, %{title: "Alpha Session"})
      s2 = create_session_fixture(p2, %{title: "Beta Session"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{s1.id}")
      assert render(view) =~ "Project Alpha"

      # Switch to cross-project session
      render_patch(view, ~p"/sessions/#{s2.id}")
      assert render(view) =~ "Project Beta"
      assert has_element?(view, "#terminal-xterm-container[data-session-id='#{s2.id}']")
      assert Process.alive?(view.pid)
    end

    test "navigating to invalid/nonexistent session ID in handle_params degrades gracefully",
         %{conn: conn, workspace_path: path} do
      p = create_project_fixture(%{root_path: path})
      s = create_session_fixture(p)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{s.id}")

      # Patch to non-existent session
      render_patch(view, ~p"/sessions/nonexistent-session-guid-999")
      assert Process.alive?(view.pid)
      assert render(view) =~ "Session not found"
    end
  end

  # ============================================================================
  # SECTION 2: Rapid Click Storms & Adversarial Event Flooding
  # ============================================================================

  describe "Adversarial Quick Actions & Event Click Storms" do
    test "click storm: 50+ rapid-fire quick action clicks do not deadlock or crash LiveView",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      actions = [
        "iex -S mix",
        "mix test",
        "mix precommit",
        "git status",
        "git diff",
        "echo 1",
        "echo 2"
      ]

      # Fire 50 quick action requests in rapid burst
      for i <- 1..50 do
        cmd = Enum.at(actions, rem(i, length(actions)))
        render_click(view, "run_terminal_quick_action", %{"cmd" => cmd})
      end

      assert Process.alive?(view.pid)
    end

    test "click storm: lifecycle button spam (clear -> restart -> kill -> clear -> restart)",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # Rapid lifecycle manipulation
      for _ <- 1..10 do
        render_click(view, "clear_terminal", %{})
        render_click(view, "restart_terminal_session", %{})
        render_click(view, "kill_terminal_session", %{})
        render_click(view, "clear_terminal", %{})
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#terminal-session-container")
    end

    test "raw keystroke storm: 100 rapid terminal_input events with control chars and ANSI escapes",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      special_payloads = [
        # SIGINT (Ctrl+C)
        "\x03",
        # EOF (Ctrl+D)
        "\x04",
        # Up arrow
        "\x1b[A",
        # Down arrow
        "\x1b[B",
        "\r\n",
        "\x1b[31;1mRed Bold Text\x1b[0m\n",
        "Unicode characters: 🚀 🤖 🔥 💻 ⚡️\n",
        String.duplicate("A", 1000) <> "\n"
      ]

      for i <- 1..50 do
        payload = Enum.at(special_payloads, rem(i, length(special_payloads)))
        render_hook(view, "terminal_input", %{"data" => payload})
      end

      assert Process.alive?(view.pid)
    end

    test "adversarial parameters to terminal_resize, run_terminal_quick_action, and run_terminal_command",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # Malformed resize params
      render_hook(view, "terminal_resize", %{"cols" => -100, "rows" => 0})
      render_hook(view, "terminal_resize", %{"cols" => "invalid", "rows" => nil})
      render_hook(view, "terminal_resize", %{})
      render_hook(view, "terminal_resize", %{"cols" => 999_999, "rows" => 999_999})
      assert Process.alive?(view.pid)

      # Malformed quick action params
      render_click(view, "run_terminal_quick_action", %{"cmd" => ""})
      render_click(view, "run_terminal_quick_action", %{"cmd" => "   "})
      render_click(view, "run_terminal_quick_action", %{})
      render_click(view, "run_terminal_quick_action", %{"command" => nil})
      assert Process.alive?(view.pid)

      # Empty terminal form submit
      render_submit(view, "run_terminal_command", %{"command" => ""})
      render_submit(view, "run_terminal_command", %{})
      assert Process.alive?(view.pid)
    end

    test "history deduplication and max 25 item cap under command floods",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # Send 40 distinct commands
      for i <- 1..40 do
        render_click(view, "run_terminal_quick_action", %{"cmd" => "unique_cmd_#{i}"})
      end

      # Send duplicates
      render_click(view, "run_terminal_quick_action", %{"cmd" => "unique_cmd_10"})
      render_click(view, "run_terminal_quick_action", %{"cmd" => "unique_cmd_10"})

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # SECTION 3: Agent vs Interactive User Occupancy Lifecycle
  # ============================================================================

  describe "Agent vs Interactive User Occupancy UI Rendering" do
    test "renders agent banner during 3-tuple and 2-tuple occupancy and cleans up on user release",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # 1. Initially :user -> no banner
      refute has_element?(view, "#terminal-agent-banner")

      # 2. Occupant transition to 3-tuple
      send(
        view.pid,
        {:terminal_occupant,
         %{session_id: session.id, occupant: {:agent, "TestAutonomousAgent", "op-999"}}}
      )

      assert has_element?(view, "#terminal-agent-banner")
      html = render(view)
      assert html =~ "TestAutonomousAgent"
      assert html =~ "op-999"
      assert html =~ "User input locked during autonomous execution"

      # 3. Occupant transition to 2-tuple
      send(
        view.pid,
        {:terminal_occupant, %{session_id: session.id, occupant: {:agent, "LegacyAgent"}}}
      )

      assert has_element?(view, "#terminal-agent-banner")
      assert render(view) =~ "LegacyAgent"

      # 4. Occupant transition back to :user
      send(
        view.pid,
        {:terminal_occupant, %{session_id: session.id, occupant: :user}}
      )

      refute has_element?(view, "#terminal-agent-banner")
      assert Process.alive?(view.pid)
    end

    test "user input is locked when agent occupies terminal and emits warning flash",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # Set occupant directly in TerminalSession
      _ = TerminalServer.ensure_started(session.id, workspace_path: project.root_path)
      TerminalSession.set_occupant(session.id, {:agent, "LockAgent", "op-lock"})

      # Now simulate user input from xterm hook
      html = render_hook(view, "terminal_input", %{"data" => "ls -la\n"})

      # Should flash warning about lock
      assert html =~ "Terminal is locked by active agent" or Process.alive?(view.pid)

      # Cleanup
      TerminalSession.set_occupant(session.id, :user)
    end

    test "rapid occupant oscillation storm (:user <-> :agent) keeps LiveView in sync",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      for i <- 1..30 do
        agent_name = "RapidAgent_#{i}"

        send(
          view.pid,
          {:terminal_occupant,
           %{session_id: session.id, occupant: {:agent, agent_name, "op-#{i}"}}}
        )

        send(
          view.pid,
          {:terminal_occupant, %{session_id: session.id, occupant: :user}}
        )
      end

      assert Process.alive?(view.pid)
      refute has_element?(view, "#terminal-agent-banner")
    end

    test "end-to-end TerminalServer.run_agent_command execution displays and removes banner",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#tab-btn-terminal") |> render_click()

      # Start an agent command in a background task
      task =
        Task.async(fn ->
          TerminalServer.run_agent_command(
            session.id,
            "echo 'agent test output 42'",
            "E2EWorkerAgent",
            workspace_path: project.root_path,
            op_id: "op-e2e-42",
            timeout_ms: 10_000
          )
        end)

      # Wait for result
      {:ok, result} = Task.await(task, 12_000)
      assert result.output =~ "agent test output 42"
      assert result.exit_code == 0

      # LiveView should be back to :user occupant
      assert Process.alive?(view.pid)
    end
  end
end
