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

    newest = List.last(messages)
    render_click(view, "expand_message", %{"id" => newest.id})
    assert live_assigns(view).expanded_message.content == newest.content

    render_click(view, "close_expand_message")
    assert is_nil(live_assigns(view).expanded_message)
  end

  test "calendar only shows tasks scheduled on the cell's full date", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, _task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "August target task",
        status: "scheduled",
        scheduled_at: ~U[2026-08-14 09:00:00Z]
      })

    {:ok, _task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "September same-day task",
        status: "scheduled",
        scheduled_at: ~U[2026-09-14 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "calendar"})

    calendar_grid =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#calendar-grid")
      |> LazyHTML.text()

    assert calendar_grid =~ "August target task"
    refute calendar_grid =~ "September same-day task"
  end

  defp live_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> then(& &1.socket.assigns)
  end
end
