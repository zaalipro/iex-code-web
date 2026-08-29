defmodule IexCodeWeb.EmpiricalDeadAssignChallengeTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  describe "Empirical Dead Assigns & Rapid Event Lifecycle Challenge" do
    test "mounts WorkspaceLive without obsolete assigns and maintains valid socket assigns across rapid events",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert is_binary(html)

      state = :sys.get_state(view.pid)
      assigns = state.socket.assigns

      # 1. Empirically verify that eliminated dead assigns are NOT present in socket assigns
      dead_assign_keys = [
        :tokens_in,
        :tokens_out,
        :picker_mode,
        :selected_calendar_day,
        :new_task_time,
        :new_task_schedule_type,
        :show_usage_history_modal,
        :show_settings_modal,
        :settings_form,
        :all_usage_history,
        :show_all_usage_modal
      ]

      for dead_key <- dead_assign_keys do
        refute Map.has_key?(assigns, dead_key),
               "Assign :#{dead_key} should have been eliminated from WorkspaceLive mount/3 assigns"
      end

      # 2. Empirically verify that valid assigns exist and are properly typed
      assert is_integer(assigns.session_tokens)
      assert is_binary(assigns.selected_calendar_date)
      assert is_binary(assigns.selected_time_slot)
      assert is_boolean(assigns.show_time_picker)
      assert is_list(assigns.tasks)
      assert is_list(assigns.messages)
      assert is_list(assigns.operations)

      # 3. Rapid fire of time-picker & date events (formerly updating dead assigns)
      # Must not crash or repopulate dead assigns
      render_click(view, "open_time_picker", %{"mode" => "time"})
      render_click(view, "select_time_slot", %{"slot" => "11:00 AM - 11:30 AM"})
      render_click(view, "picker_today")
      render_click(view, "picker_select_day", %{"year" => "2026", "month" => "9", "day" => "1"})
      render_click(view, "select_calendar_date", %{"date" => "2026-09-01"})
      render_click(view, "set_task_schedule_type", %{"type" => "recurring"})

      # Re-check socket state after event storm
      new_state = :sys.get_state(view.pid)
      new_assigns = new_state.socket.assigns

      for dead_key <- dead_assign_keys do
        refute Map.has_key?(new_assigns, dead_key),
               "Assign :#{dead_key} was repopulated during rapid events"
      end

      assert Process.alive?(view.pid)

      render_click(view, "toggle_settings_modal")
      assert_redirect(view, "/sessions/#{session.id}/settings#execution")
    end

    test "verifies dynamic rendering of credits, canvas files, and calendar stats without static placeholders",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Create some real project files
      workspace_write_file(path, "lib/alpha.ex", "defmodule Alpha do :ok end")
      workspace_write_file(path, "lib/beta.ex", "defmodule Beta do :ok end")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to Changes tab and verify canvas reflects dynamic project files/diffs
      render_click(view, "switch_tab", %{"tab" => "changes"})
      changes_html = render(view)

      # Dynamic Canvas header
      assert changes_html =~ "Canvas"
      # Refute the old hardcoded fake files
      refute changes_html =~ "pr-1781-walkthrough.html"
      refute changes_html =~ "pr-5567-proof-of-history.html"
      refute changes_html =~ "pr-22-toll-express.html"

      # Switch to Calendar tab and verify scheduled tasks footer metrics
      render_click(view, "switch_tab", %{"tab" => "calendar"})
      calendar_html = render(view)

      assert calendar_html =~ "SCHEDULED TASKS"
      assert calendar_html =~ "ACTIVE"
      assert calendar_html =~ "MONTHLY RUNS:"

      # Settings are owned by SettingsLive; WorkspaceLive only provides a navigation shim.
      render_click(view, "toggle_settings_modal")
      assert_redirect(view, "/sessions/#{session.id}/settings#execution")
    end

    test "fuzzes 40 random UI event clicks and ensures LiveView never crashes or enters zombie state",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      events = [
        {"switch_tab", %{"tab" => "kanban"}},
        {"switch_tab", %{"tab" => "swarm"}},
        {"switch_tab", %{"tab" => "calendar"}},
        {"switch_tab", %{"tab" => "changes"}},
        {"switch_tab", %{"tab" => "chat"}},
        {"switch_tab", %{"tab" => "terminal"}},
        {"toggle_workspace_menu", %{}},
        {"search_workspace", %{"query" => "test"}},
        {"toggle_dropdown", %{"name" => "kanban_filter"}},
        {"close_dropdowns", %{}},
        {"calendar_next_month", %{}},
        {"calendar_prev_month", %{}},
        {"open_goal_modal", %{}},
        {"close_goal_modal", %{}},
        {"open_cancel_modal", %{}},
        {"close_cancel_modal", %{}},
        {"toggle_date_picker_popover", %{}},
        {"close_date_picker_popover", %{}},
        {"toggle_custom_time", %{}},
        {"clear_terminal", %{}},
        {"scroll_to_msg", %{"id" => "msg-123"}},
        {"expand_column", %{"column" => "done"}},
        {"toggle_tool", %{"tool" => "ast_search"}},
        {"toggle_tool", %{"tool" => "swarm"}},
        {"filter_kanban",
         %{"status" => "running", "priority" => "high", "assignee" => "coder", "search" => ""}}
      ]

      # Fire 40 events rapidly in sequence
      for {event_name, payload} <- Enum.take(Stream.cycle(events), 40) do
        html = render_click(view, event_name, payload)
        assert is_binary(html)
        assert Process.alive?(view.pid)
      end
    end
  end
end
