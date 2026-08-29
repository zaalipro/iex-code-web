defmodule IexCodeWeb.WorkspaceLiveSignalFoundryKanbanTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Kanban

  setup %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=kanban")
    %{view: view, project: project, session: session}
  end

  test "kanban exposes one focus host and live region", %{view: view} do
    assert has_element?(view, "#kanban-board[role='region'][aria-label='Task status board']")
    assert has_element?(view, "#task-move-focus-host[phx-hook='TaskMoveFocus']")
    refute has_element?(view, "#task-move-focus-host[phx-update='ignore']")

    assert has_element?(
             view,
             "#task-move-live-region[role='status'][aria-live='polite'][aria-atomic='true']"
           )

    document = view |> render() |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#instrument-workbench-kanban")
           |> LazyHTML.to_tree()
           |> length() == 1

    assert document |> LazyHTML.query("#task-move-focus-host") |> LazyHTML.to_tree() |> length() ==
             1

    assert document |> LazyHTML.query("#task-move-live-region") |> LazyHTML.to_tree() |> length() ==
             1

    assert document |> LazyHTML.query("#prompt-composer") |> LazyHTML.to_tree() |> length() == 1
  end

  test "empty boards select triage and activation selects exactly one channel", %{view: view} do
    assert has_element?(
             view,
             "#kanban-col-triage[data-channel-state='selected'][aria-expanded='true']"
           )

    render_click(view, "expand_task_status", %{"status" => "review"})

    assert has_element?(
             view,
             "#kanban-col-review[data-channel-state='selected'][aria-expanded='true']"
           )

    assert has_element?(
             view,
             "#kanban-col-triage[data-channel-state='quiet'][aria-expanded='false']"
           )

    document = view |> render() |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("[data-channel-state='selected'][aria-expanded='true']")
           |> LazyHTML.to_tree()
           |> length() == 1
  end

  test "initial selected channel is first non-empty canonical status", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: Path.join(path, "selected-channel")})
    session = create_session_fixture(project)

    {:ok, _} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Blocked",
        status: "blocked"
      })

    {:ok, _} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Ready",
        status: "ready"
      })

    {:ok, view, _} = live(conn, ~p"/sessions/#{session.id}?view=kanban")

    assert has_element?(
             view,
             "#kanban-col-ready[data-channel-state='selected'][aria-expanded='true']"
           )
  end

  test "move trigger opens a sibling native form and valid move announces and focuses", %{
    view: view,
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Move me",
        status: "todo"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "expand_task_status", %{"status" => "todo"})
    assert has_element?(view, "#task-row-#{task.id}")
    assert has_element?(view, "article#task-row-#{task.id} > button#task-card-#{task.id}")

    assert has_element?(
             view,
             "article#task-row-#{task.id} > button#move-task-trigger-#{task.id}"
           )

    refute has_element?(view, "button#task-card-#{task.id} button")
    refute has_element?(view, "button#task-card-#{task.id} form")
    render_click(view, "open_task_move", %{"id" => task.id})
    assert has_element?(view, "#move-task-form-#{task.id}")
    assert has_element?(view, "#move-task-form-#{task.id}[phx-window-keydown][phx-key='Escape']")

    assert has_element?(
             view,
             "#move-task-form-#{task.id}[phx-window-keydown*='move-task-trigger-#{task.id}']"
           )

    assert has_element?(view, "select[name='move_task[status]']")
    assert has_element?(view, "input[type='hidden'][name='move_task[id]'][value='#{task.id}']")

    for status <- Kanban.Task.statuses() do
      assert has_element?(
               view,
               "#move-task-status-#{task.id} option[value='#{status}']"
             )
    end

    html =
      view
      |> form("#move-task-form-#{task.id}", %{
        "move_task" => %{"id" => task.id, "status" => "done"}
      })
      |> render_submit()

    assert html =~ "Moved Move me to done"
    assert Kanban.get_task!(task.id).status == "done"
    assert has_element?(view, "#kanban-col-done[data-channel-state='selected']")
    expected_id = "task-card-#{task.id}"
    assert_push_event(view, "focus_task", %{id: ^expected_id})
  end

  test "invalid nested move preserves open movement state", %{
    view: view,
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Stay",
        status: "todo"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "expand_task_status", %{"status" => "todo"})
    render_click(view, "open_task_move", %{"id" => task.id})
    render_submit(view, "move_task", %{"move_task" => %{"id" => task.id, "status" => "bogus"}})
    assert has_element?(view, "#move-task-form-#{task.id}")
    assert Kanban.get_task!(task.id).status == "todo"
    refute_push_event(view, "focus_task", %{id: _})
  end

  test "cancel clears only movement UI", %{view: view, project: project, session: session} do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Cancel",
        status: "todo"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "open_task_move", %{"id" => task.id})
    render_click(view, "cancel_task_move", %{"id" => task.id})
    refute has_element?(view, "#move-task-form-#{task.id}")
    assert Kanban.get_task!(task.id).status == "todo"
  end

  test "foreign and malformed ids cannot open or move tasks", %{
    view: view,
    workspace_path: path
  } do
    foreign_project = create_project_fixture(%{root_path: Path.join(path, "foreign-kanban")})
    foreign_session = create_session_fixture(foreign_project)

    {:ok, foreign_task} =
      Kanban.create_task(%{
        project_id: foreign_project.id,
        session_id: foreign_session.id,
        title: "Foreign",
        status: "todo"
      })

    render_click(view, "open_task_move", %{"id" => foreign_task.id})
    refute has_element?(view, "#move-task-form-#{foreign_task.id}")

    render_submit(view, "move_task", %{
      "move_task" => %{"id" => foreign_task.id, "status" => "done"}
    })

    render_click(view, "open_task_move", %{"id" => "NOT-A-UUID"})
    refute has_element?(view, "[id^='move-task-form-']")
    assert Kanban.get_task!(foreign_task.id).status == "todo"
    refute_push_event(view, "focus_task", %{id: _})
  end

  test "task detail consumes the shared responsive sheet contract", %{
    view: view,
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Inspect me",
        status: "triage"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "open_task_drawer", %{"id" => task.id})

    assert has_element?(
             view,
             "#task-detail-drawer[phx-hook='ResponsiveSheet'][role='dialog'][aria-modal='true'][aria-labelledby='task-detail-title'][tabindex='-1'][data-sheet-close-event='close_task_drawer'][data-sheet-return-id='task-card-#{task.id}'][data-sheet-background-id='kanban-board']"
           )

    assert has_element?(view, "#task-detail-title")
    refute has_element?(view, "#task-detail-drawer[phx-update='ignore']")
    refute has_element?(view, "#task-detail-drawer[phx-hook='ModalFocus']")
  end
end
