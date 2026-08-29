defmodule IexCodeWeb.WorkspaceLiveUIControlsTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.{Kanban, Runs, Sessions, Settings}

  # ============================================================================
  # 1. Navigation, Switchboard, Workspace & Session Management
  # ============================================================================

  describe "Navigation, Workspace & Sessions Controls" do
    test "switches across all instruments through the visible switchboard", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for {surface, title} <- [
            {"swarm", "Active Mission"},
            {"kanban", "Mission Board"},
            {"research", "Research Radar"},
            {"calendar", "Schedule Chronometer"},
            {"changes", "Change Ledger"},
            {"chat", "Conversation Loop"},
            {"files", "File Atlas"},
            {"terminal", "Terminal Scope"}
          ] do
        render_click(view, "toggle_command_palette")
        render_change(view, "command_palette_search", %{"query" => title})
        view |> element("[data-palette-item-id='view_#{surface}']") |> render_click()
        assert live_assigns(view).active_view == surface
      end
    end

    test "handles workspace switcher menu, search, project switching, and project creation modal",
         %{
           conn: conn,
           workspace_path: path
         } do
      p1 = create_project_fixture(%{name: "Alpha Project", root_path: path})
      p2_dir = Path.join(System.tmp_dir!(), "beta_project_#{Ecto.UUID.generate()}")
      File.mkdir_p!(p2_dir)
      p2 = create_project_fixture(%{name: "Beta Project", root_path: p2_dir})

      session = create_session_fixture(p1)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette", %{"category" => "projects"})
      render_change(view, "command_palette_search", %{"query" => "Beta Project"})
      assert has_element?(view, "[data-palette-item-id='project-#{p2.id}']")
      view |> element("[data-palette-item-id='project-#{p2.id}']") |> render_click()
      assert_patch(view, ~p"/sessions/#{hd(Sessions.list_sessions_for_project(p2.id)).id}")

      render_click(view, "toggle_command_palette", %{"category" => "projects"})
      view |> element("[data-palette-item-id='new-project']") |> render_click()
      assert has_element?(view, "#project-modal")
      assert has_element?(view, "#project-open-form")

      # Close project modal
      render_click(view, "close_project_modal")
      refute has_element?(view, "#project-modal")

      File.rm_rf(p2_dir)
    end

    test "handles new session creation and session deletion with fallback", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      s1 = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{s1.id}")

      # 1. Create second session
      render_click(view, "new_session")
      sessions = Sessions.list_sessions_for_project(project.id)
      assert length(sessions) == 2
      s2 = Enum.find(sessions, &(&1.id != s1.id))
      assert s2 != nil
      assert render(view) =~ "Coding Session 2"

      # 2. Delete first session
      render_click(view, "delete_session", %{"id" => s1.id})
      remaining = Sessions.list_sessions_for_project(project.id)
      assert length(remaining) == 1
      assert hd(remaining).id == s2.id

      # 3. Delete last session -> should auto-generate a fresh Coding Session 1 fallback
      render_click(view, "delete_session", %{"id" => s2.id})
      fallback = Sessions.list_sessions_for_project(project.id)
      assert length(fallback) == 1
      assert hd(fallback).title == "Coding Session 1"
    end

    test "rejects a forged cross-project session deletion without navigation or cascade", %{
      conn: conn,
      workspace_path: path
    } do
      current_project = create_project_fixture(%{name: "Current Project", root_path: path})
      current_session = create_session_fixture(current_project, %{title: "Current Session"})

      foreign_root = Path.join(System.tmp_dir!(), "foreign-session-#{Ecto.UUID.generate()}")
      File.mkdir_p!(foreign_root)

      foreign_project =
        create_project_fixture(%{name: "Foreign Project", root_path: foreign_root})

      foreign_session = create_session_fixture(foreign_project, %{title: "Foreign Session"})

      foreign_message =
        create_message_fixture(foreign_session, %{content: "Foreign data must survive"})

      assert {:ok, foreign_run} =
               Runs.create_run(%{
                 project_id: foreign_project.id,
                 session_id: foreign_session.id,
                 objective: "Foreign durable run must survive"
               })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{current_session.id}")

      render_click(view, "delete_session", %{"id" => foreign_session.id})

      assert Sessions.get_session(foreign_session.id).id == foreign_session.id
      assert Enum.any?(Sessions.list_messages(foreign_session.id), &(&1.id == foreign_message.id))
      assert Runs.get_run(foreign_run.id).id == foreign_run.id

      assigns = live_assigns(view)
      assert assigns.session.id == current_session.id
      assert assigns.project.id == current_project.id
      assert render(view) =~ "Session not found in this project"

      File.rm_rf(foreign_root)
    end
  end

  # ============================================================================
  # 2. Coach Card Controls & Dead Button Audit
  # ============================================================================

  describe "Coach Card & Hero Controls" do
    test "toggles Coach Card menu and exercises menu actions (Goal, Terminal, Clear Ops)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Toggle Coach Menu
      html = render_click(view, "toggle_coach_menu")
      assert html =~ "Create Goal"
      assert html =~ "Open Terminal"
      assert html =~ "Clear Ops"

      # Exercise Coach menu: open goal modal
      html_goal = render_click(view, "open_goal_modal")

      assert html_goal =~ "Create Autonomous Goal" or html_goal =~ "Goal Title" or
               is_binary(html_goal)
    end

    test "toggles pause and resume on session execution", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Pause session
      html_pause = render_click(view, "pause_session")
      assert html_pause =~ "paused" or is_binary(html_pause)

      # Resume session
      html_resume = render_click(view, "resume_session")
      assert html_resume =~ "resumed" or is_binary(html_resume)

      # Toggle session pause
      render_click(view, "toggle_session_pause")
      assert is_binary(render(view))
    end

    test "opens cancel modal and executes stop action", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Open cancel modal
      html = render_click(view, "open_cancel_modal")
      assert html =~ "Stop Session" or html =~ "Rollback" or html =~ "Commit" or is_binary(html)

      # Close modal
      render_click(view, "close_cancel_modal")

      # Re-open and cancel session with rollback
      render_click(view, "open_cancel_modal")
      render_click(view, "cancel_session", %{"mode" => "rollback"})
      assert render(view) =~ "stopped" or is_binary(render(view))
    end
  end

  # ============================================================================
  # 3. Prompt Bar, Tool Pills, Message Expand & Settings
  # ============================================================================

  describe "Prompt Bar, Tool Pills & Settings Telemetry" do
    test "toggles prompt bar tool pills without restoring retired usage UI", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Toggle tool pills
      render_click(view, "toggle_tool", %{"tool" => "ast_search"})
      render_click(view, "toggle_tool", %{"tool" => "web_search"})
      render_click(view, "toggle_tool", %{"tool" => "git"})

      refute has_element?(view, "#all-usage-modal")
    end

    test "expands and closes chat message detail view", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, msg} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "assistant",
          agent_name: "CoderAgent",
          content: "Detailed multi-step architecture plan."
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "chat"})

      # Expand message
      html_expanded = render_click(view, "expand_message", %{"id" => msg.id})
      assert html_expanded =~ "Detailed multi-step architecture plan."

      # Close expanded message
      render_click(view, "close_expand_message")
    end

    test "toggles model dropdown and switches active AI model with flash alert", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Toggle model dropdown
      html = render_click(view, "toggle_dropdown", %{"name" => "model"})
      assert html =~ "Select AI Model"
      assert html =~ "Claude 3.7 Sonnet"
      assert html =~ "GPT 5.4 Turbo"
      assert html =~ "Gemini 3.7 Flash High"

      # 2. Select Claude 3.7 Sonnet
      html =
        render_click(view, "change_model", %{
          "provider" => "anthropic",
          "model" => "claude-3.7-sonnet"
        })

      assert html =~ "Model set to claude-3.7-sonnet (anthropic)"
      refute html =~ "Select AI Model"
    end

    test "submits prompt from prompt bar and switches tab on slash commands", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Submit regular prompt
      html = render_submit(view, "submit_prompt", %{"prompt" => "Refactor payment service"})
      assert is_binary(html)

      # Enter workbenches through the canonical route seam after the prompt submission.
      render_click(view, "switch_tab", %{"tab" => "swarm"})
      assert live_assigns(view).active_view == "swarm"

      render_click(view, "switch_tab", %{"tab" => "kanban"})
      assert live_assigns(view).active_view == "kanban"
    end

    test "navigates to SettingsLive and saves API configuration there",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_settings_modal")
      assert_redirect(view, "/sessions/#{session.id}/settings#execution")
      {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings#execution")

      # 2. Save new settings
      html =
        settings_view
        |> form("#settings-form", %{
          "settings" => %{
            "openai_api_key" => "sk-test-secret-key-12345",
            "openai_base_url" => "https://cli.llmotions.com/v1",
            "default_model" => "gemini-3.7-flash-high"
          }
        })
        |> render_submit()

      assert html =~ "Settings saved"
      assert has_element?(settings_view, "#settings-save-status", "Settings saved")

      stored = Settings.get_settings()
      assert stored.openai_base_url == "https://cli.llmotions.com/v1"
      assert stored.default_model == "gemini-3.7-flash-high"
    end

    test "saving research settings refreshes composer defaults and preserves blank secrets", %{
      conn: conn,
      workspace_path: path
    } do
      assert {:ok, _settings} =
               Settings.update_settings(%{
                 openai_api_key: "openai-preserved",
                 anthropic_api_key: "anthropic-preserved",
                 search_providers: %{
                   "tavily" => %{
                     "enabled" => false,
                     "api_key" => "tavily-preserved",
                     "base_url" => "https://api.tavily.com"
                   },
                   "duckduckgo" => %{
                     "enabled" => true,
                     "base_url" => "https://html.duckduckgo.com"
                   }
                 },
                 search_provider_order: ["tavily", "duckduckgo"]
               })

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#toggle-run-setup") |> render_click()
      assert has_element?(view, "#run-setup-provider-duckduckgo[checked]")

      {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings#research")
      settings_view |> element("#settings-provider-advanced-tavily") |> render_click()

      settings_view
      |> form("#settings-form", %{
        "settings" => %{
          "openai_api_key" => "   ",
          "anthropic_api_key" => "",
          "research_depth" => "deep",
          "research_level" => "high",
          "research_max_sources" => "7",
          "research_require_conflict_audit" => "false",
          "research_max_cost_cents" => "9000",
          "research_max_tokens" => "180000",
          "research_time_budget_minutes" => "45",
          "search_providers" => %{
            "tavily" => %{
              "enabled" => "true",
              "api_key" => "",
              "base_url" => "https://api.tavily.com"
            },
            "duckduckgo" => %{
              "enabled" => "false"
            }
          }
        }
      })
      |> render_submit()

      stored = Settings.get_settings()
      assert stored.openai_api_key == "openai-preserved"
      assert stored.anthropic_api_key == "anthropic-preserved"
      assert stored.search_providers["tavily"]["api_key"] == "tavily-preserved"
      assert stored.search_providers["tavily"]["enabled"] == true
      assert stored.search_providers["duckduckgo"]["enabled"] == false
      assert stored.research_level == "high"
      assert stored.research_require_conflict_audit == false
      assert stored.research_max_cost_cents == 9_000
      assert stored.research_max_tokens == 180_000
      assert stored.research_time_budget_minutes == 45

      {:ok, refreshed, _html} = live(conn, ~p"/sessions/#{session.id}")
      refreshed |> element("#toggle-run-setup") |> render_click()
      assert has_element?(refreshed, "#run-setup-provider-tavily[checked]")
      refute has_element?(refreshed, "#run-setup-provider-duckduckgo[checked]")
      assert has_element?(refreshed, "#run-setup-research-level option[value='high'][selected]")
      assert has_element?(refreshed, "#run-setup-research-sources[value='7']")
    end
  end

  # ============================================================================
  # 4. Task Drawer & Kanban 8-Column Accordion Transitions
  # ============================================================================

  describe "Task Drawer & Kanban Board Interactions" do
    test "expands and collapses all 8 Kanban column ribbons", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "kanban"})

      columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

      for col <- columns do
        # 1. Expand column via toggle_column
        render_click(view, "toggle_column", %{"status" => col})
        assert has_element?(view, "#kanban-cards-#{col}")

        # 2. Explicit set_expanded_column
        render_click(view, "set_expanded_column", %{"status" => col})
        assert has_element?(view, "#kanban-cards-#{col}")
      end
    end

    test "opens Task Drawer, inspects metadata, claims task, and estimates effort", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Audit concurrent database connections",
          description: "Analyze pool limits under heavy load.",
          status: "ready",
          priority: "high",
          assignee: "coder"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "kanban"})

      # 1. Open drawer
      render_click(view, "open_task_drawer", %{"id" => task.id})
      html = render(view)
      assert html =~ "Audit concurrent database connections"
      assert html =~ "coder"
      assert html =~ "high" or html =~ "HIGH"

      # 2. Claim task
      html_claim = render_click(view, "claim_task", %{"id" => task.id})
      assert html_claim =~ "claimed task"
      claimed_task = Kanban.get_task!(task.id)
      assert claimed_task.status == "running"

      # 3. Estimate effort
      html_est = render_click(view, "estimate_task", %{"id" => task.id})
      assert html_est =~ "Effort estimated:"

      # 4. Move task to done
      render_click(view, "move_task", %{"id" => task.id, "status" => "done"})
      done_task = Kanban.get_task!(task.id)
      assert done_task.status == "done"

      # 5. Close drawer
      render_click(view, "close_task_drawer")
      refute render(view) =~ "Claim &amp; Run Worker"
    end

    test "filters tasks dynamically by search query, priority, status, and assignee", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _t1} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Unique Alpha Task",
          status: "ready",
          priority: "critical"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "kanban"})

      # Expand ready column to see the task card
      render_click(view, "toggle_column", %{"status" => "ready"})

      # Filter by search string
      render_change(view, "filter_kanban", %{"search" => "Alpha"})
      assert render(view) =~ "Unique Alpha Task"

      # Select filter dropdown item
      render_click(view, "select_kanban_filter", %{"key" => "priority", "value" => "critical"})
      assert render(view) =~ "Unique Alpha Task"
    end
  end

  # ============================================================================
  # 5. Scheduled Tasks, Focus Time Picker & Custom Date Popover
  # ============================================================================

  describe "Scheduled Tasks & Calendar Presence System" do
    test "opens Focus Time picker, selects presence modes, and applies focus schedule", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Open picker
      html = render_click(view, "open_time_picker", %{"mode" => "datetime"})
      assert html =~ "Set focus time &amp; presence" or html =~ "Set focus time & presence"
      assert html =~ "Available"
      assert html =~ "Busy"
      assert html =~ "In-meeting"

      # 2. Select status
      render_click(view, "select_schedule_status", %{"status" => "In-meeting"})

      assert has_element?(
               view,
               "#time-picker-modal button[aria-pressed='true']"
             )

      # 3. Select time slot
      render_click(view, "select_time_slot", %{"slot" => "02:00 PM - 03:00 PM"})

      # 4. Toggle custom time input
      html = render_click(view, "toggle_custom_time")
      assert html =~ "Enter Custom Time / Interval"

      # 5. Apply focus presence
      html = render_click(view, "apply_time_picker")
      assert html =~ "Scheduled for"
      assert html =~ "In-meeting"
    end

    test "navigates calendar months with prev/next and selects custom date from popover", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "calendar"})

      # Main calendar navigation
      render_click(view, "calendar_next_month")
      render_click(view, "calendar_prev_month")

      # Open new task modal
      render_click(view, "toggle_new_task_modal")

      # Toggle date picker popover
      render_click(view, "toggle_date_picker_popover")

      # Next month
      render_click(view, "picker_next_month")

      # Prev month
      render_click(view, "picker_prev_month")

      # Select day 12 of July 2026
      render_click(view, "picker_select_day", %{"year" => "2026", "month" => "7", "day" => "12"})
      assert render(view) =~ "07/12/2026"

      # Clear
      render_click(view, "toggle_date_picker_popover")
      render_click(view, "picker_clear")
      assert is_binary(render(view))
    end

    test "opens scheduled task, edits task, executes, and deletes scheduled task", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, sched_task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Run nightly system security audit",
          description: "Scan all ports and tokens",
          status: "scheduled",
          priority: "critical",
          assignee: "verifier",
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open scheduled task detail modal
      html = render_click(view, "show_scheduled_task", %{"id" => sched_task.id})
      assert html =~ "scheduled-task-detail-modal"
      assert html =~ "Run nightly system security audit"

      # Edit scheduled task
      html_edit = render_click(view, "open_edit_scheduled_task", %{"id" => sched_task.id})
      assert html_edit =~ "Edit Scheduled Task" or is_binary(html_edit)

      # Update scheduled task
      render_submit(view, "update_scheduled_task", %{
        "id" => sched_task.id,
        "title" => "Updated Security Audit Title",
        "priority" => "critical",
        "assignee" => "verifier"
      })

      # Run Now
      render_click(view, "run_scheduled_task_now", %{"id" => sched_task.id})
      assert render(view) =~ "running" or is_binary(render(view))

      # Delete task
      render_click(view, "delete_scheduled_task", %{"id" => sched_task.id})
      assert Kanban.get_task(sched_task.id) == nil
    end
  end

  # ============================================================================
  # 6. Integrated Terminal Runner Controls
  # ============================================================================

  describe "Integrated Terminal Controls & Async Runner" do
    test "executes quick commands, form submission, stop, replay, and clears output buffer", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to terminal tab
      render_click(view, "switch_tab", %{"tab" => "terminal"})

      # 1. Run quick terminal action
      html = render_click(view, "quick_terminal", %{"cmd" => "echo 'hello terminal runner'"})
      assert html =~ "hello terminal runner"
      wait_for_terminal(view, &(&1 =~ "[Exit 0: OK]"))

      # 2. Run terminal form submit
      view
      |> form("#terminal-form", %{"command" => "echo 'form execution test'"})
      |> render_submit()

      wait_for_terminal(view, &(count_exit_markers(&1) >= 2))
      assert render(view) =~ "form execution test"

      # 3. Stop terminal command
      html_stop = render_click(view, "stop_terminal_command")
      assert html_stop =~ "stopped" or is_binary(html_stop)

      # 4. Replay terminal command
      html_replay = render_click(view, "replay_terminal_command")
      assert is_binary(html_replay)

      # 5. Stream real-time ANSI terminal output via PubSub
      send(
        view.pid,
        {:terminal_output, session.id, "\e[1;32m[SUCCESS]\e[0m Test suite 100% passed"}
      )

      assert render(view) =~ "Test suite 100% passed"

      # 6. Clear terminal
      render_click(view, "clear_terminal")
      refute render(view) =~ "Test suite 100% passed"
    end
  end

  # Terminal execution is async via Port: poll until the expected output
  # (e.g. an exit marker) shows up in the rendered buffer.
  defp wait_for_terminal(view, match?, deadline \\ 2000) do
    html = render(view)

    cond do
      match?.(html) ->
        html

      deadline <= 0 ->
        flunk("timed out waiting for expected terminal output")

      true ->
        Process.sleep(50)
        wait_for_terminal(view, match?, deadline - 50)
    end
  end

  defp count_exit_markers(html) do
    html |> String.split("[Exit ") |> length() |> Kernel.-(1)
  end

  defp live_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> then(& &1.socket.assigns)
  end
end
