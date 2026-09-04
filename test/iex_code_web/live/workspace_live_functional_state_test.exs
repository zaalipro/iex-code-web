defmodule IexCodeWeb.WorkspaceLiveFunctionalStateTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.{Kanban, Sessions}

  test "workspace search filters navigation data without filtering chat history", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Primary Workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Release Planning"})
    second_session = create_session_fixture(project, %{title: "Payments Refactor"})
    message = create_message_fixture(session, %{content: "needle only in chat history"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_change(view, "search_workspace", %{"query" => "payments"})
    assigns = live_assigns(view)

    assert Enum.map(assigns.sessions, & &1.id) == [second_session.id]
    assert assigns.projects == []
    assert Enum.map(assigns.messages, & &1.id) == [message.id]

    render_change(view, "search_workspace", %{"query" => "needle only"})
    assigns = live_assigns(view)

    assert assigns.projects == []
    assert assigns.sessions == []
    assert Enum.map(assigns.messages, & &1.id) == [message.id]

    render_click(view, "toggle_command_palette")
    assert has_element?(view, "#command-palette-results", "Payments Refactor")

    render_click(view, "command_palette_set_category", %{"category" => "sessions"})
    assert has_element?(view, "#command-palette-results", "Payments Refactor")

    render_change(view, "command_palette_search", %{"query" => "Payments Refactor"})
    assert has_element?(view, "#command-palette-results", "Payments Refactor")

    render_click(view, "close_command_palette")

    render_change(view, "search_workspace", %{"query" => ""})
    assigns = live_assigns(view)

    assert Enum.any?(assigns.projects, &(&1.id == project.id))

    assert MapSet.new(Enum.map(assigns.sessions, & &1.id)) ==
             MapSet.new([session.id, second_session.id])
  end

  test "focus time edits are drafts, custom intervals validate, and cancel reverts", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "open_time_picker")
    render_click(view, "select_schedule_status", %{"status" => "Busy"})

    refute has_element?(view, "#flash-info")
    assert live_assigns(view).user_availability == "Available"

    render_click(view, "select_time_slot", %{"slot" => "02:00 PM - 03:00 PM"})
    render_click(view, "close_time_picker")

    assigns = live_assigns(view)
    assert assigns.selected_schedule_status == "Available"
    assert assigns.user_availability == "Available"
    assert assigns.selected_time_slot == "10:30 AM - 11:00 AM"

    render_click(view, "open_time_picker")
    render_click(view, "select_schedule_status", %{"status" => "Busy"})
    render_click(view, "toggle_custom_time")
    render_change(view, "update_custom_time", %{"custom_time" => "not a time"})
    html = render_click(view, "apply_time_picker")

    assert html =~ "Enter a valid time interval"
    assert live_assigns(view).show_time_picker

    render_change(view, "update_custom_time", %{"custom_time" => "3:15 pm - 4:00 PM"})
    render_click(view, "apply_time_picker")

    assigns = live_assigns(view)
    refute assigns.show_time_picker
    assert assigns.selected_time_slot == "03:15 PM - 04:00 PM"
    assert assigns.user_availability == "Busy"
    assert assigns.user_availability_subtext == "Deep focus · autonomous background mode"

    assert has_element?(
             view,
             "#flash-info",
             "Focus presence updated: Busy"
           )
  end

  test "model-only selection pairs its provider and task creation uses the selected start time",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})

    session =
      create_session_fixture(project, %{model_provider: "openai", model_name: "gpt-5.4-turbo"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "change_model", %{"model" => "claude-3.7-sonnet"})
    updated_session = Sessions.get_session!(session.id)
    assert updated_session.model_name == "claude-3.7-sonnet"
    assert updated_session.model_provider == "anthropic"

    render_click(view, "create_task", %{
      "title" => "Afternoon verification",
      "status" => "scheduled",
      "scheduled_at_date" => "2026-09-14",
      "scheduled_at_time_slot" => "02:45 PM - 03:30 PM"
    })

    task = Enum.find(Kanban.list_tasks(project.id), &(&1.title == "Afternoon verification"))
    assert task.scheduled_at == ~U[2026-09-14 14:45:00Z]
  end

  test "usage view-all has real open/close state and file inventory excludes generated data", %{
    conn: conn,
    workspace_path: path
  } do
    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "lib/visible.ex"), "defmodule Visible do\nend\n")
    File.mkdir_p!(Path.join(path, "node_modules/pkg"))
    File.write!(Path.join(path, "node_modules/pkg/index.js"), "generated")
    File.mkdir_p!(Path.join(path, "tmp/cache"))
    File.write!(Path.join(path, "tmp/cache/data.txt"), "temporary")
    File.write!(Path.join(path, "app.sqlite3"), "database")
    File.write!(Path.join(path, "app.db-wal"), "database journal")
    File.write!(Path.join(path, "erl_crash.dump"), "crash")

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # File discovery is intentionally lazy so every connected workspace does
    # not retain a full tree while the user is working in another tab.
    assert live_assigns(view).project_files == []
    refute live_assigns(view).files_loaded?
    assert has_element?(view, "#instrument-card-files", "Standby · files not loaded")
    render_click(view, "switch_tab", %{"tab" => "files"})
    files = live_assigns(view).project_files
    assert live_assigns(view).files_loaded?
    assert "lib/visible.ex" in files
    refute Enum.any?(files, &String.starts_with?(&1, "node_modules/"))
    refute Enum.any?(files, &String.starts_with?(&1, "tmp/"))
    refute "app.sqlite3" in files
    refute "app.db-wal" in files
    refute "erl_crash.dump" in files

    refute Map.has_key?(live_assigns(view), :show_all_usage_modal)
    {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings#usage")
    assert has_element?(settings_view, "#usage")
  end

  test "chat retains a byte-bounded preview while the inspector retrieves the durable body", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    body = String.duplicate("large-message-", 20_000)

    messages =
      for index <- 1..100 do
        {:ok, message} =
          Sessions.create_message(%{
            session_id: session.id,
            role: "assistant",
            content: "#{index}:" <> body
          })

        message
      end

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    previews = live_assigns(view).messages

    assert Enum.sum(Enum.map(previews, &byte_size(&1.content))) <= 1_000_000
    assert Enum.all?(previews, &(String.length(&1.content) <= 12_000))

    retained_message = List.last(previews)
    durable_message = Enum.find(messages, &(&1.id == retained_message.id))
    render_click(view, "expand_message", %{"id" => retained_message.id})
    assert live_assigns(view).expanded_message.content == durable_message.content
    assert has_element?(view, "#expanded-message-modal.sf-chassis")
    assert has_element?(view, "#expanded-message-body.sf-chat-prose")

    foreign_session = create_session_fixture(project)
    foreign_message = create_message_fixture(foreign_session, %{content: "Foreign body"})
    render_click(view, "expand_message", %{"id" => foreign_message.id})
    assert is_nil(live_assigns(view).expanded_message)

    render_click(view, "close_expand_message")
    assert is_nil(live_assigns(view).expanded_message)
  end

  test "conversation loop renders the Signal Foundry chat chassis and readable message field", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    create_message_fixture(session, %{role: "user", content: "A readable prompt"})
    create_message_fixture(session, %{role: "assistant", content: "A readable response"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=chat")

    assert has_element?(view, "#instrument-workbench-chat")
    assert has_element?(view, "#conversation-loop-field.flex.min-h-0.flex-1")
    assert has_element?(view, "#chat-viewport.flex-1.min-h-0.overflow-y-auto")
    assert has_element?(view, ".sf-chat-prose")
    refute has_element?(view, ".sf-chat-prose.sf-display")
    assert has_element?(view, "#prompt-composer[data-command-dock-state='expanded']")

    document = view |> render() |> LazyHTML.from_fragment()

    for selector <- [
          "#instrument-workbench-chat",
          "#chat-viewport",
          "#prompt-composer[data-command-dock-state='expanded']"
        ] do
      assert document |> LazyHTML.query(selector) |> Enum.count() == 1
    end
  end

  test "newer page availability uses the exact conversation copy", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    for index <- 1..601 do
      create_message_fixture(session, %{role: "assistant", content: "Message #{index}"})
    end

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=chat")

    for _page <- 1..5 do
      render_click(view, "load_older_messages")
    end

    assert has_element?(view, "#chat-viewport #load-newer-messages", "Newer messages available")

    assert has_element?(
             view,
             "#instrument-workbench-chat [data-workbench-command-dock] #prompt-composer"
           )

    render_click(view, "load_newer_messages")
    refute has_element?(view, "#load-newer-messages")
  end

  test "conversation paging does not claim newer messages at the retained boundary", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    for index <- 1..500 do
      create_message_fixture(session, %{role: "assistant", content: "Boundary #{index}"})
    end

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=chat")

    for _page <- 1..4 do
      render_click(view, "load_older_messages")
    end

    refute has_element?(view, "#load-newer-messages")
  end

  test "calendar only shows tasks scheduled on the cell's full date", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    today = Date.utc_today()
    this_month_dt = DateTime.new!(Date.new!(today.year, today.month, 14), ~T[09:00:00], "Etc/UTC")

    {next_year, next_month} =
      if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}

    next_month_dt = DateTime.new!(Date.new!(next_year, next_month, 14), ~T[09:00:00], "Etc/UTC")

    {:ok, _task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Current month target task",
        status: "scheduled",
        scheduled_at: this_month_dt
      })

    {:ok, _task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Next month same-day task",
        status: "scheduled",
        scheduled_at: next_month_dt
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "calendar"})

    calendar_grid =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#calendar-grid")
      |> LazyHTML.text()

    assert calendar_grid =~ "Current month target task"
    refute calendar_grid =~ "Next month same-day task"
  end

  test "file atlas workbench exposes bounded inventory and focus controls", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=files")
    assert has_element?(view, "#instrument-workbench-files")
    assert has_element?(view, "#files-focus-mode-toggle[aria-pressed='false']")
    assert has_element?(view, "#file-atlas-primary-field[data-files-focus-mode='false']")
    assert has_element?(view, "#instrument-workbench-files-status", "No files discovered")
    assert has_element?(view, "#file-tree-empty", "No files discovered")

    File.mkdir_p!(Path.join(path, "bulk"))

    for index <- 1..501 do
      File.write!(
        Path.join(path, "bulk/#{String.pad_leading(to_string(index), 4, "0")}.txt"),
        "x"
      )
    end

    render_click(view, "refresh_files")
    assert has_element?(view, "#instrument-workbench-files-status", "500+ files indexed")
    assert has_element?(view, "#load-more-files")
    assert file_tree_count(view) == 500

    render_click(view, "load_more_files")
    assert has_element?(view, "#instrument-workbench-files-status", "501 files indexed")
    refute has_element?(view, "#load-more-files")
    assert file_tree_count(view) == 501

    for index <- 502..2_001 do
      File.write!(
        Path.join(path, "bulk/#{String.pad_leading(to_string(index), 4, "0")}.txt"),
        "x"
      )
    end

    render_click(view, "refresh_files")
    render_click(view, "load_more_files")
    render_click(view, "load_more_files")
    render_click(view, "load_more_files")

    assert has_element?(view, "#instrument-workbench-files-status", "500+ files indexed")
    refute has_element?(view, "#load-more-files")
    assert has_element?(view, "#file-tree-list [phx-value-path='bulk/2000.txt']")
    refute has_element?(view, "#file-tree-list [phx-value-path='bulk/2001.txt']")
  end

  defp live_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> then(& &1.socket.assigns)
  end

  defp file_tree_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#file-tree-list [phx-click='select_file']")
    |> LazyHTML.to_tree()
    |> length()
  end
end
