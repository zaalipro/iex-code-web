defmodule IexCodeWeb.WorkspaceComponentsSignalFoundryTest do
  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest

  @moduletag mock_llm: true

  alias IexCode.Kanban
  alias IexCode.Sessions

  test "workspace exposes one tokenized command dock with state and setup tray seam", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Chassis workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Chassis session"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#workspace-shell[phx-hook='InstrumentDeck']")
    assert has_element?(view, "#prompt-composer[data-command-dock-state='compact']")
    assert has_element?(view, "#prompt-form")

    assert has_element?(
             view,
             "#toggle-run-setup[data-run-setup-toggle][aria-controls='run-setup-tray']"
           )

    view |> element("#toggle-run-setup") |> render_click()

    assert has_element?(view, "#prompt-composer[data-command-dock-state='expanded']")
    assert has_element?(view, "#run-setup-tray")
    assert has_element?(view, "#run-setup-panel[phx-change='update_run_setup']")
    assert has_element?(view, "#run-setup-tray:has(#run-setup-panel) + #prompt-form")

    view
    |> form("#run-setup-panel", %{"run_setup" => %{"time_budget_minutes" => "17"}})
    |> render_change()

    assert has_element?(view, "#run-setup-time-budget[value='17']")
    view |> element("#toggle-run-setup") |> render_click()
    refute has_element?(view, "#run-setup-tray")
    view |> element("#toggle-run-setup") |> render_click()
    assert has_element?(view, "#run-setup-time-budget[value='17']")

    view |> element("#toggle-run-setup") |> render_click()

    for surface <- ~w(kanban swarm research calendar changes files terminal) do
      render_click(view, "switch_tab", %{"tab" => surface})
      assert has_element?(view, "#prompt-composer[data-command-dock-state='focus-expand']")
    end

    render_click(view, "switch_tab", %{"tab" => "chat"})
    assert has_element?(view, "#prompt-composer[data-command-dock-state='expanded']")

    html = render(view)
    document = LazyHTML.from_fragment(html)
    assert document |> LazyHTML.query("#prompt-composer") |> LazyHTML.to_tree() |> length() == 1
    assert document |> LazyHTML.query("#prompt-form") |> LazyHTML.to_tree() |> length() == 1
    assert document |> LazyHTML.query("#toggle-run-setup") |> LazyHTML.to_tree() |> length() == 1
    assert has_element?(view, "#prompt-form.sf-command-dock-form")
    assert has_element?(view, "#prompt-form [data-command-tools]")
    assert has_element?(view, "#prompt-form [data-command-dispatch]")
    assert has_element?(view, "#prompt-form [data-command-send]")
    refute has_element?(view, ".sf-command-dock.sf-command-dock-shell")

    render_click(view, "toggle_command_palette")

    assert has_element?(
             view,
             "#command-palette-dialog[data-sheet-close-event='close_command_palette'][phx-hook='ResponsiveSheet']"
           )

    refute has_element?(view, "#workspace-sidebar")
    refute has_element?(view, "#workspace-desktop-tabs")
  end

  test "shared dock CSS separates the vertical shell from command-grid geometry" do
    css = File.read!("assets/css/app.css")

    refute css =~ "--sf-app-bg"
    refute css =~ ".rainbow-box-wrapper"
    assert css =~ ".sf-command-dock-shell {\n  display: flex;\n  flex-direction: column;"
    assert css =~ ~S|grid-template-areas: "input tools dispatch send";|
    assert css =~ ~S|"tools tools tools"
      "input dispatch send";|
    assert css =~ ".sf-command-send"
    refute css =~ ".sf-command-dock-send"
    assert css =~ "padding-bottom: max(1rem, env(safe-area-inset-bottom))"
  end

  test "task detail activates the local mobile sheet without inerting its ancestor", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Task sheet workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Task sheet session"})

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Inspect the local signal",
        status: "todo"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=kanban")
    render_click(view, "open_task_drawer", %{"id" => task.id})

    assert has_element?(
             view,
             "#task-detail-drawer[phx-hook='ResponsiveSheet'][aria-label='Task details'][tabindex='-1'][data-sheet-close-event='close_task_drawer'][data-sheet-return-id='task-card-#{task.id}'][data-sheet-background-id='kanban-board']"
           )

    assert has_element?(view, "#task-detail-title", "Task details")
    assert has_element?(view, "#kanban-board")
    refute has_element?(view, "#task-detail-drawer[phx-update='ignore']")
    refute has_element?(view, "#task-detail-drawer[data-sheet-background-id='workspace-views']")
  end

  test "delete-session palette item opens an authorized confirmation sheet", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Delete sheet workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Delete me"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "sessions"})
    render_change(view, "command_palette_search", %{"query" => "Permanently remove"})
    assert has_element?(view, "[data-palette-item-id='delete-session-#{session.id}']")

    render_click(view, "command_palette_select_item", %{"index" => "0"})

    assert has_element?(view, "#delete-session-confirmation[phx-hook='ResponsiveSheet']")

    assert has_element?(
             view,
             "#delete-session-confirmation[data-sheet-close-event='cancel_session_delete']"
           )

    assert has_element?(
             view,
             "#delete-session-confirmation[data-sheet-return-id='command-palette-trigger'][data-sheet-background-id='workspace-shell']"
           )

    assert has_element?(view, "#delete-session-confirmation-dialog[phx-hook='ModalFocus']")
    assert has_element?(view, "#delete-session-confirm")
    refute has_element?(view, "#delete-session-confirmation [data-confirm]")

    render_click(view, "cancel_session_delete")
    refute has_element?(view, "#delete-session-confirmation")
    assert Sessions.get_session(session.id)
  end

  test "delete-session confirmation ignores forged and foreign requests, then confirms with revalidation",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{name: "Delete auth workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Authorized delete"})

    foreign_project =
      create_project_fixture(%{name: "Foreign workspace", root_path: Path.join(path, "foreign")})

    foreign = create_session_fixture(foreign_project, %{title: "Foreign delete"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "delete_session", %{"id" => foreign.id})
    refute has_element?(view, "#delete-session-confirmation")

    render_click(view, "delete_session", %{"id" => session.id})
    assert has_element?(view, "#delete-session-confirmation")
    assert Sessions.get_session(session.id)
    render_click(view, "cancel_session_delete")

    render_click(view, "toggle_command_palette", %{"category" => "sessions"})
    render_change(view, "command_palette_search", %{"query" => "Permanently remove"})
    render_click(view, "command_palette_select_item", %{"index" => "0"})
    assert has_element?(view, "#delete-session-confirmation")

    render_click(view, "confirm_session_delete", %{"id" => foreign.id})
    assert has_element?(view, "#delete-session-confirmation")
    assert Sessions.get_session(session.id)

    render_click(view, "delete_session", %{"id" => session.id})
    assert has_element?(view, "#delete-session-confirmation")
    render_click(view, "confirm_session_delete")
    refute has_element?(view, "#delete-session-confirmation")
    refute Sessions.get_session(session.id)
  end

  test "confirming the final session creates a replacement session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Final delete workspace", root_path: path})
    session = create_session_fixture(project, %{title: "Last session"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "sessions"})
    render_change(view, "command_palette_search", %{"query" => "Delete Last session"})
    render_click(view, "command_palette_select_item", %{"index" => "0"})
    render_click(view, "confirm_session_delete")

    assert_patch(view)
    replacement = Sessions.list_sessions_for_project(project.id)
    assert length(replacement) == 1
    assert hd(replacement).id != session.id
  end

  test "a stale pending delete is cleared without deleting another session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Stale delete workspace", root_path: path})
    current = create_session_fixture(project, %{title: "Current session"})
    stale = create_session_fixture(project, %{title: "Stale session"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{current.id}")

    render_click(view, "delete_session", %{"id" => stale.id})
    assert has_element?(view, "#delete-session-confirmation")
    assert {:ok, _} = Sessions.delete_session(stale)
    render_click(view, "confirm_session_delete")

    refute has_element?(view, "#delete-session-confirmation")
    assert Sessions.get_session(current.id)
  end
end
