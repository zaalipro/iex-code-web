defmodule IexCodeWeb.WorkspaceLiveSmokeRegressionTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.{Kanban, Runs, Sessions}
  alias IexCode.Kanban.Scheduler

  test "mounting an empty workspace never persists or dispatches demo data", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Empty workspace regression", root_path: path})
    session = create_session_fixture(project, %{title: "Empty session regression"})

    assert Kanban.list_tasks(project.id) == []
    assert Sessions.list_messages(session.id) == []
    assert Runs.list_runs(project_id: project.id) == []

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})
    assert has_element?(view, "#kanban-empty-state")
    assert has_element?(view, "#kanban-empty-create-task")
    assert Kanban.list_tasks(project.id) == []
    assert Sessions.list_messages(session.id) == []
    assert Runs.list_runs(project_id: project.id) == []

    render_click(view, "switch_tab", %{"tab" => "chat"})
    assert has_element?(view, "#chat-empty-state")

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert %{claimed: 0, enqueued: 0, errors: [], results: []} =
             Scheduler.dispatch_due(
               now: now,
               dispatcher: self(),
               worker_id: "empty-workspace-regression"
             )

    refute_receive {:"$gen_cast", :dispatch}, 50
    assert Kanban.list_tasks(project.id) == []
    assert Sessions.list_messages(session.id) == []
    assert Runs.list_runs(project_id: project.id) == []
  end

  test "a zero-result Kanban filter offers clear filters without claiming the board is empty", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Filtered board regression", root_path: path})
    session = create_session_fixture(project, %{title: "Filtered board session"})

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Persisted task outside the search",
        status: "running",
        priority: "medium",
        assignee: "coder"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    view
    |> form("#kanban-filter-form", %{"search" => "definitely-no-match"})
    |> render_change()

    assert has_element?(view, "#kanban-filter-empty-state", "No tasks match these filters")
    assert has_element?(view, "#kanban-clear-filters[phx-click='clear_kanban_filters']")
    refute has_element?(view, "#kanban-empty-state")
    refute has_element?(view, "#kanban-empty-create-task")

    view |> element("#kanban-clear-filters") |> render_click()

    refute has_element?(view, "#kanban-filter-empty-state")
    refute has_element?(view, "#kanban-empty-state")
    assert has_element?(view, "#task-card-#{task.id}")
  end

  test "workspace search forms filter projects and sessions without mutating messages", %{
    conn: conn,
    workspace_path: path
  } do
    alpha_project =
      create_project_fixture(%{name: "Alpha Regression Workspace", root_path: path})

    beta_path = Path.join(path, "beta-regression-workspace")
    File.mkdir_p!(beta_path)

    beta_project =
      create_project_fixture(%{name: "Beta Regression Workspace", root_path: beta_path})

    alpha_session = create_session_fixture(alpha_project, %{title: "Alpha Regression Session"})
    _beta_session = create_session_fixture(alpha_project, %{title: "Beta Regression Session"})

    alpha_message =
      create_message_fixture(alpha_session, %{content: "Alpha chat content must remain visible"})

    beta_message =
      create_message_fixture(alpha_session, %{content: "Beta chat content must remain visible"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{alpha_session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "projects"})
    render_change(view, "command_palette_search", %{"query" => "Beta Regression"})
    assert has_element?(view, "[data-palette-item-id='project-#{beta_project.id}']")
    refute has_element?(view, "[data-palette-item-id='project-#{alpha_project.id}']")
    render_click(view, "close_command_palette")

    assert MapSet.new(Enum.map(live_assigns(view).messages, & &1.id)) ==
             MapSet.new([alpha_message.id, beta_message.id])
  end

  test "late run messages cannot cross a session switch or authorize foreign agent controls", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Run message scope", root_path: path})
    old_session = create_session_fixture(project, %{title: "Old Session"})
    current_session = create_session_fixture(project, %{title: "Current Session"})

    assert {:ok, old_run} =
             Runs.create_run(%{
               project_id: project.id,
               session_id: old_session.id,
               objective: "Old session run"
             })

    assert {:ok, [old_agent]} = Runs.create_run_agents(old_run, [%{key: "old-agent"}])

    assert {:ok, current_run} =
             Runs.create_run(%{
               project_id: project.id,
               session_id: current_session.id,
               objective: "Current session run"
             })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{old_session.id}")
    render_patch(view, ~p"/sessions/#{current_session.id}")

    send(view.pid, {:async_run_started, old_run, self()})
    send(view.pid, {:async_run_updated, old_run})
    _ = render(view)

    assigns = live_assigns(view)
    assert assigns.session.id == current_session.id
    assert assigns.selected_run.id == current_run.id

    render_click(view, "update_run_agent_guidance", %{
      "agent_id" => old_agent.id,
      "agent_control" => %{"guidance" => "cross-session guidance"}
    })

    render_click(view, "control_run_agent", %{"id" => old_agent.id, "action" => "cancel"})

    refute Map.has_key?(live_assigns(view).run_agent_guidance, old_agent.id)
    assert Runs.list_run_agent_controls(old_agent) == []
    assert Runs.get_run_agent(old_agent.id).status == "pending"
  end

  test "file filter form is wired and renders only matching project files", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/alpha_regression.ex", "defmodule AlphaRegression do\nend\n")
    workspace_write_file(path, "lib/beta_regression.ex", "defmodule BetaRegression do\nend\n")

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "switch_tab", %{"tab" => "files"})

    assert has_element?(view, "#file-filter-form[phx-change='filter_files']")

    view
    |> form("#file-filter-form", %{"filter" => "alpha_regression"})
    |> render_change()

    assert live_assigns(view).file_filter == "alpha_regression"

    assert has_element?(
             view,
             "#file-tree-panel button[phx-click='select_file'][phx-value-path='lib/alpha_regression.ex']"
           )

    refute has_element?(
             view,
             "#file-tree-panel button[phx-click='select_file'][phx-value-path='lib/beta_regression.ex']"
           )
  end

  test "model buttons persist the matching provider as an atomic pair", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_dropdown", %{"name" => "model"})

    view
    |> element("button[phx-click='change_model'][phx-value-model='claude-3.7-sonnet']")
    |> render_click()

    updated = Sessions.get_session!(session.id)
    assert updated.model_name == "claude-3.7-sonnet"
    assert updated.model_provider == "anthropic"

    render_click(view, "toggle_dropdown", %{"name" => "model"})

    view
    |> element("button[phx-click='change_model'][phx-value-model='ox-alpha']")
    |> render_click()

    updated = Sessions.get_session!(session.id)
    assert updated.model_name == "ox-alpha"
    assert updated.model_provider == "openai"

    render_click(view, "toggle_dropdown", %{"name" => "model"})

    view
    |> element("button[phx-click='change_model'][phx-value-model='deepseek-v4-pro']")
    |> render_click()

    updated = Sessions.get_session!(session.id)
    assert updated.model_name == "deepseek-v4-pro"
    assert updated.model_provider == "openai"
  end

  test "session Settings route renders scoped provider-reported usage", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    usage_message =
      create_message_fixture(session, %{
        role: "assistant",
        input_tokens: 777,
        output_tokens: 333,
        cost_cents: 12,
        content: "Usage regression record"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings")

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-session-context", session.title)
    assert has_element?(view, "#settings-usage-ready")
    assert has_element?(view, "#settings-usage-row-#{usage_message.id}")
    assert has_element?(view, "#settings-return-workspace[href='/sessions/#{session.id}']")
  end

  test "focus-time cancel reverts drafts while custom Apply commits status and interval", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "open_time_picker")
    render_click(view, "select_schedule_status", %{"status" => "Busy"})
    render_click(view, "select_time_slot", %{"slot" => "02:00 PM - 03:00 PM"})

    draft = live_assigns(view)
    assert draft.selected_schedule_status == "Busy"
    assert draft.user_availability == "Available"

    render_click(view, "close_time_picker")
    reverted = live_assigns(view)
    assert reverted.selected_schedule_status == "Available"
    assert reverted.selected_time_slot == "10:30 AM - 11:00 AM"
    assert reverted.user_availability == "Available"

    render_click(view, "open_time_picker")
    render_click(view, "select_schedule_status", %{"status" => "In-meeting"})
    render_click(view, "toggle_custom_time")

    assert has_element?(view, "#custom-time-form[phx-change='update_custom_time']")

    view
    |> form("#custom-time-form", %{"custom_time" => "03:15 PM - 04:00 PM"})
    |> render_change()

    render_click(view, "apply_time_picker")

    committed = live_assigns(view)
    refute committed.show_time_picker
    assert committed.selected_time_slot == "03:15 PM - 04:00 PM"
    assert committed.user_availability == "In-meeting"
    assert committed.user_availability_subtext == "Collaboration window · batched summaries"
  end

  test "task creation uses the submitted schedule date and selected slot start", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_submit(view, "create_task", %{
      "title" => "Scheduled slot regression task",
      "status" => "scheduled",
      "scheduled_at_date" => "2026-09-17",
      "scheduled_at_time_slot" => "02:45 PM - 03:30 PM"
    })

    task =
      project.id
      |> Kanban.list_tasks()
      |> Enum.find(&(&1.title == "Scheduled slot regression task"))

    assert task.scheduled_at == ~U[2026-09-17 14:45:00Z]
  end

  test "calendar cells match a task's full date rather than day-of-month only", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()
    current_month_date = Date.new!(today.year, today.month, 12)

    {other_year, other_month} =
      if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}

    other_month_date = Date.new!(other_year, other_month, 12)

    {:ok, current_month_task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Current-month full-date task",
        status: "scheduled",
        scheduled_at: DateTime.new!(current_month_date, ~T[09:00:00], "Etc/UTC")
      })

    {:ok, other_month_task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Other-month same-day task",
        status: "scheduled",
        scheduled_at: DateTime.new!(other_month_date, ~T[09:00:00], "Etc/UTC")
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "calendar"})

    assert has_element?(view, "#calendar-day-12 #calendar-task-12-#{current_month_task.id}")
    refute has_element?(view, "#calendar-day-12 #calendar-task-12-#{other_month_task.id}")
  end

  test "command palette is globally mounted, accessible, and its Swarm action functions", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{swarm_mode: false})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#command-palette-controller[phx-hook='CommandPalette']")
    refute has_element?(view, "#command-palette-modal")

    render_click(view, "toggle_command_palette")

    assert has_element?(
             view,
             "#command-palette-dialog[role='dialog'][aria-modal='true'][aria-labelledby='command-palette-title']"
           )

    assert has_element?(
             view,
             "#command-palette-input[role='combobox'][aria-controls='command-palette-results']"
           )

    assert has_element?(view, "#command-palette-results[role='listbox']")

    render_click(view, "command_palette_set_category", %{"category" => "actions"})
    render_change(view, "command_palette_search", %{"query" => "Toggle Swarm Mode"})

    view |> element("#palette-item-0[role='option']") |> render_click()

    refute has_element?(view, "#command-palette-modal")

    assert Sessions.get_session!(session.id).swarm_mode
  end

  test "responsive panels and interactive header controls expose stable accessible contracts", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(
      path,
      "lib/responsive_contract.ex",
      "defmodule ResponsiveContract do\nend\n"
    )

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Responsive drawer contract",
        status: "ready"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#mission-strip")
    assert has_element?(view, "#project-switchboard-trigger[aria-label='Choose project']")
    assert has_element?(view, "#runtime-switchboard-trigger[aria-label='Open runtime settings']")

    render_click(view, "switch_tab", %{"tab" => "changes"})
    assert has_element?(view, "#changes-toolbar")
    assert has_element?(view, "#changes-layout #changes-staging-panel")
    assert has_element?(view, "#changes-layout #changes-diff-panel")

    render_click(view, "switch_tab", %{"tab" => "files"})

    assert has_element?(
             view,
             "#file-explorer-container #file-tree-panel[aria-label='Project files']"
           )

    assert has_element?(view, "#file-explorer-container #file-editor-panel")

    render_click(view, "switch_tab", %{"tab" => "kanban"})
    render_click(view, "open_task_drawer", %{"id" => task.id})

    assert has_element?(
             view,
             "aside#task-detail-drawer[aria-label='Task details'][data-sheet-dialog='true'].sf-task-detail-drawer.w-full.max-w-none"
           )
  end

  test "workspace dialogs expose focus, Escape, and labelling contracts", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    message = create_message_fixture(session, %{role: "assistant"})

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Dialog contract task",
        status: "scheduled",
        scheduled_at: ~U[2026-08-25 10:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "open_goal_modal")
    assert_modal(view, "goal-modal", "close_goal_modal")
    render_click(view, "close_goal_modal")

    render_click(view, "open_cancel_modal")
    assert_modal(view, "cancel-session-modal", "close_cancel_modal")
    render_click(view, "close_cancel_modal")

    render_click(view, "expand_message", %{"id" => message.id})
    assert_modal(view, "expanded-message-modal", "close_expand_message")
    render_click(view, "close_expand_message")

    render_click(view, "toggle_command_palette", %{"category" => "settings_account"})
    assert has_element?(view, "[data-palette-item-id='settings-models']")
    assert has_element?(view, "[data-palette-item-id='settings-execution']")
    assert has_element?(view, "#workspace-logout-form[action='/logout'][method='post']")

    render_click(view, "toggle_project_modal")
    assert_modal(view, "project-modal", "close_project_modal")
    render_click(view, "close_project_modal")

    render_click(view, "show_scheduled_task", %{"id" => task.id})
    assert_modal(view, "scheduled-task-detail-modal", "close_scheduled_task_modal")

    render_click(view, "open_edit_scheduled_task", %{"id" => task.id})
    assert_modal(view, "edit-scheduled-task-modal", "close_edit_scheduled_task")

    assert has_element?(
             view,
             ".workspace-modal-backdrop[class~='overflow-y-auto'][class~='p-3'] #edit-scheduled-task-modal.workspace-modal-panel[class~='my-auto'][class~='max-h-[calc(100dvh-1.5rem)]'][class~='overflow-y-auto']"
           )

    assert has_element?(
             view,
             "#edit-scheduled-task-modal #edit-scheduled-task-form button[type='submit']"
           )

    render_click(view, "close_edit_scheduled_task")
    render_click(view, "close_scheduled_task_modal")

    render_click(view, "toggle_new_task_modal")
    assert_modal(view, "new-task-modal", "toggle_new_task_modal")
    assert has_element?(view, ".workspace-modal-backdrop #new-task-modal.workspace-modal-panel")
    render_click(view, "toggle_new_task_modal")

    render_click(view, "open_time_picker")
    assert_modal(view, "time-picker-modal", "close_time_picker")

    assert has_element?(
             view,
             ".workspace-modal-backdrop #time-picker-modal.workspace-modal-panel"
           )
  end

  defp assert_modal(view, id, cancel_event) do
    assert has_element?(
             view,
             "##{id}[phx-hook='ModalFocus'][data-modal-focus][data-cancel-event='#{cancel_event}'][role='dialog'][aria-modal='true'][aria-labelledby='#{id}-title'][tabindex='-1']"
           )

    assert has_element?(view, "##{id}-title")
  end

  defp live_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> then(& &1.socket.assigns)
  end
end
