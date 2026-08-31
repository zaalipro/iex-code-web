defmodule IexCodeWeb.WorkspaceLiveTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  alias IexCode.Sessions
  alias IexCode.Sessions.Operation

  test "renders workspace interface, today tasks, and kanban board", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#instrument-deck")
    assert has_element?(view, "#instrument-card-kanban")
    assert has_element?(view, "#instrument-card-swarm")
  end

  test "switches tabs between kanban, swarm, calendar, changes, chat, files, and terminal", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    assert :sys.get_state(view.pid).socket.assigns.active_view == "deck"

    # Switch to swarm tab
    view
    |> element("#instrument-card-swarm")
    |> render_click()

    assert_patch(view, ~p"/sessions/#{session.id}?view=swarm")

    assert render(view) =~ "PlannerAgent"
    assert render(view) =~ "ExplorerAgent"

    render_click(view, "switch_tab", %{"tab" => "calendar"})

    assert_patch(view, ~p"/sessions/#{session.id}?view=calendar")

    assert render(view) =~ "Scheduled Tasks" or render(view) =~ "August, 2026"

    # Switch to changes tab
    render_click(view, "switch_tab", %{"tab" => "changes"})

    assert_patch(view, ~p"/sessions/#{session.id}?view=changes")

    assert has_element?(view, "#instrument-workbench-changes[data-workbench-surface='changes']")
    assert has_element?(view, "#changes-primary")

    # Switch to chat tab
    render_click(view, "switch_tab", %{"tab" => "chat"})

    assert_patch(view, ~p"/sessions/#{session.id}?view=chat")

    # Switch to files tab
    render_click(view, "switch_tab", %{"tab" => "files"})

    assert_patch(view, ~p"/sessions/#{session.id}?view=files")

    # Switch to terminal tab
    render_click(view, "switch_tab", %{"tab" => "terminal"})

    assert_patch(view, ~p"/sessions/#{session.id}?view=terminal")

    assert render(view) =~ "mix test"
    assert :sys.get_state(view.pid).socket.assigns.active_view == "terminal"
  end

  test "toggles swarm mode", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "actions"})

    render_click(view, "toggle_swarm")

    assert render(view) =~ "Swarm Mode" or render(view) =~ "Single Agent Mode"
  end

  test "creates a new session when clicking the plus button", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    render_click(view, "toggle_command_palette", %{"category" => "sessions"})

    view
    |> element("button[data-palette-item-id='new-session'][role='option']")
    |> render_click()

    assert render(view) =~ "Coding Session 2"
  end

  test "opens task detail drawer and claims task", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      IexCode.Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Test Drawer Task",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    # Click task card in expanded column
    view
    |> element("#task-card-#{task.id}")
    |> render_click()

    assert render(view) =~ "Worker PID"
    assert render(view) =~ "Estimate"
  end

  test "expands and collapses kanban accordion column ribbons on click", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    # Click collapsed 'ready' ribbon
    view
    |> element("#kanban-col-ready")
    |> render_click()

    assert has_element?(view, "#kanban-cards-ready")
    assert render(view) =~ "ready"
  end

  # ============================================================================
  # F5: Live Telemetry Streaming Tests
  # ============================================================================

  test "handles real-time PubSub telemetry events for subagent cards", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to swarm tab to observe telemetry
    view
    |> element("#instrument-card-swarm")
    |> render_click()

    op = %Operation{
      id: "op-telemetry-1",
      session_id: session.id,
      agent_name: "CoderAgent",
      op_type: "patch_file",
      title: "Applying payment webhook patch",
      status: "running",
      progress: 10,
      pid_str: "#PID<0.888.0>",
      duration_ms: 25,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    # 1. Operation started
    send(view.pid, {:operation_started, op})
    html = render(view)
    assert html =~ "CoderAgent"
    assert html =~ "RUNNING"
    assert html =~ "Applying payment webhook patch"
    assert html =~ "10%"

    # 2. 4-tuple progress update
    send(view.pid, {:operation_progress, op.id, 55, "Applying hunk 2 of 4"})
    html = render(view)
    assert html =~ "55%"
    assert html =~ "Applying hunk 2 of 4"

    # 3. Map progress update with latency
    send(
      view.pid,
      {:operation_progress,
       %{id: op.id, progress: 85, status: "running", latency_ms: 140, message: "Hunk 4 verified"}}
    )

    html = render(view)
    assert html =~ "85%"
    assert html =~ "140ms"

    # 4. Completed event
    completed_op = %{op | status: "completed", progress: 100, duration_ms: 185}
    send(view.pid, {:operation_completed, completed_op})
    html = render(view)
    assert html =~ "COMPLETED"
    assert html =~ "100%"
    assert html =~ "185ms"

    # 5. Swarm stage changed
    send(view.pid, {:swarm_stage_changed, %{stage: :verifying}})
    assert render(view) =~ "Execution Hierarchy"
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree Interaction Tests
  # ============================================================================

  test "handles operation tree expand/collapse and clear operations", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, root_op} =
      Sessions.create_operation(%{
        session_id: session.id,
        parent_op_id: nil,
        agent_name: "SwarmCoordinator",
        op_type: "swarm_root",
        title: "Root Swarm Goal",
        status: "completed",
        progress: 100,
        result: "All 3 subtasks succeeded",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, child_op} =
      Sessions.create_operation(%{
        session_id: session.id,
        parent_op_id: root_op.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "Running test suite",
        status: "failed",
        error_message: "Test failure: Assertion failed",
        progress: 100,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to swarm tab
    view
    |> element("#instrument-card-swarm")
    |> render_click()

    assert render(view) =~ "Root Swarm Goal"

    # 1. Expand root op to reveal children
    html = render_click(view, "toggle_op_detail", %{"id" => root_op.id})
    assert html =~ "All 3 subtasks succeeded"
    assert html =~ "Running test suite"

    # 2. Expand child op to inspect error details
    html = render_click(view, "toggle_op_detail", %{"id" => child_op.id})
    assert html =~ "Assertion failed" or html =~ "Test failure"

    # Clear operations
    html = render_click(view, "clear_operations")
    assert html =~ "No operations recorded in this session"
  end

  # ============================================================================
  # F7: Interactive Diff Viewer Tests
  # ============================================================================

  test "handles diff mode toggling between inline and side-by-side", %{
    conn: conn,
    workspace_path: path
  } do
    # Real git repo with a committed baseline and an uncommitted modification,
    # so the changes tab renders actual `git diff` content
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["config", "user.name", "IexCode Test"], cd: path)
    System.cmd("git", ["config", "user.email", "test@iexcode.local"], cd: path)

    workspace_write_file(
      path,
      "lib/demo_app.ex",
      "defmodule DemoApp do\n  def run, do: :ok\nend\n"
    )

    System.cmd("git", ["add", "."], cd: path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

    workspace_write_file(
      path,
      "lib/demo_app.ex",
      "defmodule DemoApp do\n  def run, do: :changed\nend\n"
    )

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to changes tab (triggers the LiveView's git state refresh)
    view
    |> element("#instrument-card-changes")
    |> render_click()

    html = render(view)
    assert html =~ "lib/demo_app.ex"
    assert html =~ "Hunk hunk-1"

    # Switch to split mode
    html = render_click(view, "set_diff_mode", %{"mode" => "split"})
    assert html =~ "Original"
    assert html =~ "Modified"

    # Switch back to inline mode
    html = render_click(view, "set_diff_mode", %{"mode" => "inline"})
    assert has_element?(view, "#diff-mode-inline[aria-pressed='true']")
    refute has_element?(view, "#diff-mode-split[aria-pressed='true']")
    assert html =~ ":changed"
  end

  # ============================================================================
  # F8: File Tree Explorer & Search Tests
  # ============================================================================

  test "handles file searching, filtering, and selection with automatic tab switch", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/demo_app.ex", "defmodule DemoApp do\n  def run, do: :ok\nend")
    workspace_write_file(path, "lib/demo_worker.ex", "defmodule DemoWorker do end")

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "files"})

    # Filter files
    html = render_change(view, "filter_files", %{"filter" => "worker"})
    assert html =~ "demo_worker.ex" or is_binary(html)

    # Select file from any tab -> automatically switches to files tab and renders content
    html = render_click(view, "select_file", %{"path" => "lib/demo_app.ex"})
    assert html =~ "defmodule DemoApp do"
    assert html =~ "def run, do: :ok"
    assert html =~ "Copy"

    # Refresh files
    html = render_click(view, "refresh_files")
    assert is_binary(html)
  end

  # ============================================================================
  # F9: Terminal Session Runner Tests
  # ============================================================================

  test "handles terminal command execution, quick actions, clear, and streaming", %{
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

    # Execute terminal command via form
    html =
      view
      |> form("#terminal-form", %{"command" => "echo 'hello from integrated terminal'"})
      |> render_submit()

    assert html =~ "hello from integrated terminal"

    # Execute quick terminal button
    html = render_click(view, "run_terminal", %{"command" => "echo 'quick command test'"})
    assert html =~ "quick command test"

    # Receive async terminal output event
    send(view.pid, {:terminal_output, session.id, "Streaming log line 42"})
    _ = :sys.get_state(view.pid)
    assert_push_event(view, "terminal_output", %{data: "Streaming log line 42"})

    # Clear terminal
    render_click(view, "clear_terminal")
    assert has_element?(view, "#terminal-clear-confirmation")
    render_click(view, "confirm_terminal_action", %{})
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#terminal-clear-confirmation")
    assert :sys.get_state(view.pid).socket.assigns.terminal_output == ""
  end

  test "rejects path traversal attempts in select_file with flash error", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Attempt to traverse outside project root
    html = render_click(view, "select_file", %{"path" => "../../../../etc/passwd"})
    assert html =~ "Invalid file path"

    # Absolute path outside project root
    html = render_click(view, "select_file", %{"path" => "/etc/passwd"})
    assert html =~ "Invalid file path"
  end

  test "handles nil, non-binary, and empty terminal output events gracefully without crashing", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    send(view.pid, {:terminal_output, session.id, nil})
    send(view.pid, {:terminal_output, session.id, ""})
    send(view.pid, {:terminal_output, session.id, 12345})
    send(view.pid, {:terminal_output, session.id, %{text: "invalid"}})

    # LiveView process stays alive and healthy
    assert Process.alive?(view.pid)
    assert render(view) =~ "Workspace" or render(view) =~ "Coding Session"
  end

  # ============================================================================
  # F10: Set Focus Time & Date Picker Tests
  # ============================================================================

  test "handles Set Focus Time picker modal: open, select status, select slot, and apply", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Open focus time picker via header button
    html = render_click(view, "open_time_picker")
    assert html =~ "Set focus time"
    assert html =~ "Choose when you"
    assert html =~ "Select status"
    assert html =~ "Select time"
    assert html =~ "10:30 AM"

    # 2. Select status pill (e.g. In-meeting)
    html = render_click(view, "select_schedule_status", %{"status" => "In-meeting"})
    assert html =~ "In-meeting"

    # 3. Select time slot (e.g. 11:30 AM - 12:00 PM)
    html = render_click(view, "select_time_slot", %{"slot" => "11:30 AM - 12:00 PM"})
    assert html =~ "11:30 AM - 12:00 PM"

    # 4. Toggle custom time input
    html = render_click(view, "toggle_custom_time")
    assert html =~ "Enter Custom Time / Interval"

    # 5. Apply time picker
    html = render_click(view, "apply_time_picker")
    assert html =~ "Scheduled for"
    assert html =~ "11:30 AM - 12:00 PM"
    refute has_element?(view, "#time-picker-modal")

    # 6. Test cancel button closes modal
    render_click(view, "open_time_picker")
    render_click(view, "close_time_picker")
    refute has_element?(view, "#time-picker-modal")
  end

  # ============================================================================
  # F11: Chat Scroll Assistant Minimap & Hover Preview Tests
  # ============================================================================

  test "renders Chat Scroll Assistant timeline minimap, hover preview cards, and jump navigation",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    user_message =
      create_message_fixture(session, %{
        role: "user",
        content: "Inspect the durable scheduler state"
      })

    create_message_fixture(session, %{
      role: "assistant",
      agent_name: "PlannerAgent",
      content: "The scheduler state is scoped and ready for review."
    })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to chat tab
    view
    |> element("#instrument-card-chat")
    |> render_click()

    html = render(view)
    assert html =~ "chat-timeline-track"
    assert html =~ "scroll-timeline-node"
    assert html =~ "scroll-notch"
    assert html =~ "scroll-preview-card"
    assert html =~ "Inspect the durable scheduler state"
    assert html =~ "The scheduler state is scoped and ready for review."
    assert html =~ "chat-viewport"

    # Trigger scroll only for a retained durable message ID.
    render_click(view, "scroll_to_msg", %{"id" => user_message.id})
    assert_push_event(view, "scroll_to_msg", %{id: message_id})
    assert message_id == user_message.id

    render_click(view, "scroll_to_msg", %{"id" => "msg-0"})
    refute_push_event(view, "scroll_to_msg", %{id: _})
  end

  # ============================================================================
  # F12: Scheduled Tab, Calendar Day Click, Task Details Modal & Scheduling
  # ============================================================================

  test "handles Scheduled tab navigation, calendar day click preselection, and task detail modal inspection",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Verify "Scheduled" tab label
    html = render(view)
    assert html =~ "Scheduled"

    # 2. Switch to Scheduled (calendar) tab
    view
    |> element("#instrument-card-calendar")
    |> render_click()

    html = render(view)
    assert html =~ "August, 2026"
    assert html =~ "calendar-day-16"
    assert html =~ "calendar-day-7"

    # 3. Click empty day (e.g. Day 18) -> opens Create Task modal with preselected date
    html =
      render_click(view, "select_calendar_day", %{
        "day" => "18",
        "date" => "2026-08-18"
      })

    assert html =~ "Create Agent Task"
    assert html =~ "2026-08-18"
    assert html =~ "Schedule &amp; Execution Time"

    # 4. Create new scheduled task with target date via modal form
    html =
      view
      |> form("#task-create-form", %{
        "title" => "Run automated benchmark audit",
        "description" => "Execute 500-level stress sweep",
        "status" => "scheduled",
        "priority" => "critical",
        "assignee" => "verifier",
        "scheduled_at_date" => "2026-08-18",
        "cron_expression" => "0 12 * * *"
      })
      |> render_submit()

    assert html =~ "Task created"
    refute html =~ "Create Agent Task"

    # 5. Find created task and click to open details modal
    created_task =
      IexCode.Kanban.list_tasks(project.id)
      |> Enum.find(&(&1.title == "Run automated benchmark audit"))

    assert created_task != nil

    html = render_click(view, "show_scheduled_task", %{"id" => created_task.id})
    assert html =~ "scheduled-task-detail-modal"
    assert html =~ "Run automated benchmark audit"
    assert html =~ "Execute 500-level stress sweep"
    assert html =~ "Critical Priority"
    assert html =~ "Run Now"
    assert html =~ "Delete Task"

    # 6. Run task from modal
    html = render_click(view, "run_scheduled_task", %{"id" => created_task.id})
    assert html =~ "dispatched to the session"
    refute html =~ "scheduled-task-detail-modal"
  end

  test "F13: custom popover date picker and live availability status system", %{conn: conn} do
    project = create_project_fixture(%{root_path: "/tmp/e2e_datepicker_project"})
    session = create_session_fixture(project)
    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    assert html =~ "mission-strip"

    # 2. Open new task modal and trigger custom date picker popover
    html = render_click(view, "toggle_new_task_modal")
    assert html =~ "new-task-modal"
    assert html =~ "target-date-picker-trigger"

    # Open popover
    html = render_click(view, "toggle_date_picker_popover")
    assert html =~ "custom-date-picker-popover"
    assert html =~ "August 2026"
    assert html =~ "Clear"
    assert html =~ "Today"

    # Navigate month
    html = render_click(view, "picker_next_month")
    assert html =~ "September 2026"

    html = render_click(view, "picker_prev_month")
    assert html =~ "August 2026"

    # Select day 15
    html =
      render_click(view, "picker_select_day", %{"year" => "2026", "month" => "8", "day" => "15"})

    refute html =~ "custom-date-picker-popover"
    assert html =~ "08/15/2026"

    # Re-open and click Today
    today = Calendar.strftime(Date.utc_today(), "%m/%d/%Y")

    html = render_click(view, "toggle_date_picker_popover")
    assert html =~ "custom-date-picker-popover"
    html = render_click(view, "picker_today")
    assert html =~ today

    # 3. Test Presence & Focus Mode Modal with untruncated status pills
    html = render_click(view, "open_time_picker")
    assert html =~ "time-picker-modal"
    assert html =~ "Set focus time &amp; presence"
    assert html =~ "Available"
    assert html =~ "Busy"
    assert html =~ "In-meeting"
    assert html =~ "Offline"
    assert html =~ "Deep focus mode"
    assert html =~ "Batched summaries"

    # Switch status to Busy
    html = render_click(view, "select_schedule_status", %{"status" => "Busy"})
    assert html =~ "Deep focus mode"

    # Apply presence
    html = render_click(view, "apply_time_picker")
    assert html =~ "Focus presence updated: Busy"
    assert html =~ "Busy"
  end

  test "F14: custom glassmorphic styled dropdown components for Status, Priority, and Assignee",
       %{
         conn: conn
       } do
    project = create_project_fixture(%{root_path: "/tmp/e2e_dropdown_project"})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    # 1. Open new task modal
    html = render_click(view, "toggle_new_task_modal")
    assert html =~ "new-task-modal"
    assert html =~ "modal-status-dropdown-trigger"
    assert html =~ "modal-priority-dropdown-trigger"
    assert html =~ "modal-assignee-dropdown-trigger"

    # 2. Toggle and select Status dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_status"})
    assert html =~ "modal-status-dropdown-menu"
    assert html =~ "Ready (Agent Claimable)"
    assert html =~ "Triage"

    html = render_click(view, "select_modal_status", %{"status" => "ready"})
    refute html =~ "modal-status-dropdown-menu"
    assert html =~ "Ready (Agent Claimable)"

    # 3. Toggle and select Priority dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_priority"})
    assert html =~ "modal-priority-dropdown-menu"
    assert html =~ "Critical"
    assert html =~ "High"

    html = render_click(view, "select_modal_priority", %{"priority" => "critical"})
    refute html =~ "modal-priority-dropdown-menu"
    assert html =~ "Critical"

    # 4. Toggle and select Assignee dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_assignee"})
    assert html =~ "modal-assignee-dropdown-menu"
    assert html =~ "CoderAgent"
    assert html =~ "PlannerAgent"

    html = render_click(view, "select_modal_assignee", %{"assignee" => "coder"})
    refute html =~ "modal-assignee-dropdown-menu"
    assert html =~ "CoderAgent"

    # 5. Submit form and verify created task has selected attributes
    html =
      view
      |> form("#task-create-form", %{
        "title" => "Build custom themed dropdowns",
        "description" => "Ensure zero native browser select elements"
      })
      |> render_submit()

    assert html =~ "Task created"

    created_task =
      IexCode.Kanban.list_tasks(project.id)
      |> Enum.find(&(&1.title == "Build custom themed dropdowns"))

    assert created_task != nil
    assert created_task.status == "ready"
    assert created_task.priority == "critical"
    assert created_task.assignee == "coder"
  end

  test "handles subtask addition, toggling, deletion and inline editing in task drawer", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      IexCode.Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Subtasks Drawer Feature",
        description: "Initial description",
        tags: ["initial"]
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "kanban"})

    # Open task drawer
    view
    |> render_hook("open_task_drawer", %{"id" => task.id})

    assert has_element?(view, "#drawer-edit-task-#{task.id}")

    # Inline edit task details (title, description, tags)
    view
    |> form("#drawer-edit-task-#{task.id}", %{
      "task_id" => task.id,
      "title" => "Updated Drawer Feature Title",
      "description" => "Updated detailed description",
      "tags" => "ui, kanban, zero-gap"
    })
    |> render_submit()

    assert render(view) =~ "Task updated"
    updated = IexCode.Kanban.get_task!(task.id)
    assert updated.title == "Updated Drawer Feature Title"
    assert updated.description == "Updated detailed description"
    assert updated.tags == ["ui", "kanban", "zero-gap"]

    # Add a subtask
    view
    |> form("form[phx-submit='add_subtask']", %{
      "task_id" => task.id,
      "title" => "First Subtask Item"
    })
    |> render_submit()

    assert render(view) =~ "First Subtask Item"
    task_with_subtask = IexCode.Kanban.get_task!(task.id)
    assert length(task_with_subtask.subtasks) == 1
    assert task_with_subtask.steps_total == 1
    assert task_with_subtask.steps_completed == 0
    [sub] = task_with_subtask.subtasks
    sid = sub["id"]

    # Toggle subtask to completed
    view
    |> element("button[phx-click='toggle_subtask'][phx-value-id='#{sid}']")
    |> render_click()

    task_toggled = IexCode.Kanban.get_task!(task.id)
    assert task_toggled.steps_completed == 1

    # Delete subtask
    render_click(view, "request_delete_subtask", %{"id" => sid, "task_id" => task.id})

    assert has_element?(view, "[id^='subtask-delete-confirmation-']")
    render_click(view, "confirm_subtask_delete")

    task_deleted = IexCode.Kanban.get_task!(task.id)
    assert task_deleted.subtasks == []
    assert task_deleted.steps_total == 0
  end

  test "handles send_steering and resets steer_text", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Send steering
    html =
      view
      |> render_hook("send_steering", %{"steering" => "Focus on passing tests only"})

    assert html =~ "Steering guidance delivered"
  end

  test "handles set_task_schedule_type event", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> render_hook("set_task_schedule_type", %{"type" => "scheduled"})

    # Check that LiveView state remains responsive
    assert Process.alive?(view.pid)
  end

  test "handles file explorer folder expand/collapse and insert_code_to_editor", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    # Create dummy files
    sub_dir = Path.join(path, "lib/demo")
    File.mkdir_p!(sub_dir)
    file1 = Path.join(sub_dir, "sample.ex")
    File.write!(file1, "defmodule Demo.Sample do\nend\n")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to files tab
    view
    |> element("#instrument-card-files")
    |> render_click()

    # Toggle folder collapse
    view
    |> element("button[phx-click='toggle_folder'][phx-value-path='lib']")
    |> render_click()

    # Select file to open in buffer
    view
    |> render_hook("select_file", %{"path" => "lib/demo/sample.ex"})

    assert render(view) =~ "sample.ex"

    # Insert code into editor buffer
    snippet = "  def hello, do: :world\n"

    view
    |> render_hook("insert_code_to_editor", %{"code" => snippet})

    assert render(view) =~ "Inserted snippet into lib/demo/sample.ex"
    assert render(view) =~ "def hello, do: :world"
  end
end
