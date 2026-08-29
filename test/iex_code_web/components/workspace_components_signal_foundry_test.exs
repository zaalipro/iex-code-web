defmodule IexCodeWeb.WorkspaceComponentsSignalFoundryTest do
  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest

  @moduletag mock_llm: true

  alias IexCode.Kanban

  test "CommandPalette delegates mobile Escape and Tab to ResponsiveSheet without dead flags" do
    source = File.read!("assets/js/app.js")

    assert source =~
             ~S|dialog?.dataset?.responsiveSheetActive === "true" &&
          window.matchMedia("(max-width: 639px)").matches|

    assert source =~
             ~S|if (e.key === "Escape") {
          if (mobileSheetOwnsFocus) return|

    assert source =~
             ~S|} else if (e.key === "Tab") {
          if (mobileSheetOwnsFocus) return|

    assert source =~
             ~S|dialog?.dataset?.sheetReturnOwner === "controller" &&
            window.matchMedia("(max-width: 639px)").matches|

    refute source =~ "__responsiveSheetClosing"
  end

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
    render_click(view, "switch_tab", %{"tab" => "chat"})
    assert has_element?(view, "#prompt-composer[data-command-dock-state='expanded']")
    render_click(view, "switch_tab", %{"tab" => "files"})
    assert has_element?(view, "#prompt-composer[data-command-dock-state='focus-expand']")

    render_click(view, "toggle_command_palette")

    assert has_element?(
             view,
             "#command-palette-dialog[data-sheet-close-event='close_command_palette'][phx-hook='ResponsiveSheet']"
           )

    refute has_element?(view, "#workspace-sidebar")
    refute has_element?(view, "#workspace-desktop-tabs")
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
             "#task-detail-drawer[phx-hook='ResponsiveSheet'][role='dialog'][aria-modal='true'][aria-labelledby='task-detail-title'][tabindex='-1'][data-sheet-close-event='close_task_drawer'][data-sheet-return-id='task-card-#{task.id}'][data-sheet-background-id='kanban-board']"
           )

    assert has_element?(view, "#task-detail-title", "Inspect the local signal")
    assert has_element?(view, "#kanban-board")
    refute has_element?(view, "#task-detail-drawer[phx-update='ignore']")
    refute has_element?(view, "#task-detail-drawer[data-sheet-background-id='workspace-views']")
  end
end
