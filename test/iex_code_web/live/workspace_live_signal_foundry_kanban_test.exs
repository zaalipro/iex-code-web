defmodule IexCodeWeb.WorkspaceLiveSignalFoundryKanbanTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Kanban

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

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

    assert has_element?(
             view,
             "#instrument-workbench-kanban [data-workbench-command-dock] #prompt-composer"
           )

    refute has_element?(view, "#kanban-command-dock-slot")
  end

  test "deck retains exactly one functional shared composer at the persistent seam", %{
    conn: conn,
    session: session
  } do
    {:ok, deck, _html} = live(conn, ~p"/sessions/#{session.id}")
    document = deck |> render() |> LazyHTML.from_fragment()
    assert document |> LazyHTML.query("#prompt-composer") |> LazyHTML.to_tree() |> length() == 1
    refute has_element?(deck, "[data-workbench-command-dock]")
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
    assert has_element?(view, "#move-task-form-#{task.id}[phx-keydown][phx-key='Escape']")

    assert has_element?(
             view,
             "#move-task-form-#{task.id}[phx-keydown*='move-task-trigger-#{task.id}']"
           )

    assert has_element?(view, "select[name='move_task[status]']")
    assert has_element?(view, "input[type='hidden'][name='move_task[id]'][value='#{task.id}']")

    for status <- Kanban.Task.statuses() do
      assert has_element?(
               view,
               "#move-task-status-#{task.id} option[value='#{status}']"
             )
    end

    view
    |> form("#move-task-form-#{task.id}", %{
      "move_task" => %{"id" => task.id, "status" => "done"}
    })
    |> render_submit()

    assert has_element?(view, "#task-move-live-region", "Moved Move me to done")
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
    render_click(view, "expand_task_status", %{"status" => "todo"})
    render_click(view, "open_task_move", %{"id" => task.id})
    prior_status = assigns(view).expanded_task_status
    prior_announcement = assigns(view).task_move_announcement
    render_click(view, "cancel_task_move", %{"id" => Ecto.UUID.generate()})
    assert has_element?(view, "#move-task-form-#{task.id}")
    render_click(view, "cancel_task_move", %{"id" => task.id})
    refute has_element?(view, "#move-task-form-#{task.id}")
    assert Kanban.get_task!(task.id).status == "todo"
    assert assigns(view).expanded_task_status == prior_status
    assert assigns(view).task_move_announcement == prior_announcement

    render_click(view, "open_task_drawer", %{"id" => task.id})
    refute has_element?(view, "#move-task-form-#{task.id}")
    render_click(view, "close_task_drawer")
    render_click(view, "open_task_move", %{"id" => task.id})
    render_click(view, "toggle_command_palette")
    refute has_element?(view, "#move-task-form-#{task.id}")
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
             "aside#task-detail-drawer[phx-hook='ResponsiveSheet'][data-sheet-dialog='true'][aria-labelledby='task-detail-title'][tabindex='-1'][data-sheet-close-event='close_task_drawer'][data-sheet-return-id='task-card-#{task.id}'][data-sheet-background-id='kanban-board']"
           )

    refute has_element?(view, "#task-detail-drawer[aria-modal='true']")

    assert has_element?(view, "#task-detail-title")
    refute has_element?(view, "#task-detail-drawer[phx-update='ignore']")
    refute has_element?(view, "#task-detail-drawer[phx-hook='ModalFocus']")
  end

  test "task and subtask delete controls use authorized confirmation sheets", %{
    view: view,
    project: project,
    session: session
  } do
    subtask_id = Ecto.UUID.generate()

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Delete carefully",
        status: "triage",
        subtasks: [%{"id" => subtask_id, "title" => "Keep until confirmed", "completed" => false}]
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "open_task_drawer", %{"id" => task.id})
    refute has_element?(view, "#task-detail-drawer [data-confirm]")

    render_click(view, "request_delete_subtask", %{"task_id" => task.id, "id" => subtask_id})
    assert has_element?(view, "[id^='subtask-delete-confirmation-'][phx-hook='ResponsiveSheet']")
    assert Kanban.get_task!(task.id).subtasks != []
    render_click(view, "cancel_subtask_delete")
    refute has_element?(view, "[id^='subtask-delete-confirmation-']")

    render_click(view, "request_delete_subtask", %{"task_id" => task.id, "id" => subtask_id})
    render_click(view, "confirm_subtask_delete")
    assert Kanban.get_task!(task.id).subtasks == []

    render_click(view, "request_delete_task", %{"id" => task.id})
    assert has_element?(view, "[id^='task-delete-confirmation-'][phx-hook='ResponsiveSheet']")
    render_click(view, "cancel_task_delete")
    assert Kanban.get_task!(task.id)

    render_click(view, "request_delete_task", %{"id" => task.id})
    render_click(view, "confirm_task_delete")
    assert Kanban.get_task(task.id) == nil
  end

  test "stale and PubSub-updated confirmations clear without deleting by client data", %{
    view: view,
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Stale confirmation",
        status: "triage"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "request_delete_task", %{"id" => task.id})
    assert has_element?(view, "[id^='task-delete-confirmation-']")
    {:ok, _updated} = Kanban.update_task(task, %{title: "Changed elsewhere"})
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "[id^='task-delete-confirmation-']")
    assert Kanban.get_task!(task.id).title == "Changed elsewhere"

    render_click(view, "request_delete_task", %{"id" => task.id})
    assert {:ok, _deleted} = Kanban.delete_task(Kanban.get_task!(task.id))
    _ = :sys.get_state(view.pid)
    render_click(view, "confirm_task_delete")
    refute has_element?(view, "[id^='task-delete-confirmation-']")
  end

  test "malformed and foreign drawer or delete ids never create state", %{
    view: view,
    workspace_path: path
  } do
    foreign_project = create_project_fixture(%{root_path: Path.join(path, "drawer-foreign")})
    foreign_session = create_session_fixture(foreign_project)

    {:ok, foreign_task} =
      Kanban.create_task(%{
        project_id: foreign_project.id,
        session_id: foreign_session.id,
        title: "Foreign drawer task",
        status: "triage"
      })

    render_click(view, "open_task_drawer", %{"id" => String.upcase(foreign_task.id)})
    render_click(view, "request_delete_task", %{"id" => foreign_task.id})
    refute has_element?(view, "#task-detail-drawer")
    refute has_element?(view, "[id^='task-delete-confirmation-']")
    assert Kanban.get_task!(foreign_task.id)

    {:ok, local_task} =
      Kanban.create_task(%{
        project_id: assigns(view).project.id,
        session_id: assigns(view).session.id,
        title: "Canonical only",
        status: "triage"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "open_task_drawer", %{"id" => String.upcase(local_task.id)})
    refute has_element?(view, "#task-detail-drawer")
  end

  test "filtered-out destination retains filters and emits card focus safely", %{
    view: view,
    project: project,
    session: session
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Filtered move",
        status: "todo"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "expand_task_status", %{"status" => "todo"})
    render_click(view, "open_task_move", %{"id" => task.id})

    render_change(view, "filter_kanban", %{
      "search" => "Filtered",
      "status" => "todo",
      "priority" => "",
      "assignee" => ""
    })

    render_submit(view, "move_task", %{"move_task" => %{"id" => task.id, "status" => "done"}})
    assert assigns(view).kanban_filter["status"] == "todo"
    assert assigns(view).expanded_task_status == "done"
    refute has_element?(view, "#task-card-#{task.id}")
  end

  test "leaving Kanban clears movement form and project rehydrate clears stale state", %{
    view: view,
    project: project,
    session: session,
    workspace_path: path
  } do
    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Lifecycle",
        status: "todo"
      })

    _ = :sys.get_state(view.pid)
    render_click(view, "expand_task_status", %{"status" => "todo"})
    render_click(view, "open_task_move", %{"id" => task.id})
    render_click(view, "switch_tab", %{"tab" => "chat"})
    refute has_element?(view, "#move-task-form-#{task.id}")

    project_two = create_project_fixture(%{root_path: Path.join(path, "lifecycle-two")})
    session_two = create_session_fixture(project_two)
    render_click(view, "switch_tab", %{"tab" => "kanban"})
    render_click(view, "expand_task_status", %{"status" => "todo"})
    render_click(view, "open_task_move", %{"id" => task.id})
    render_click(view, "switch_project", %{"id" => project_two.id})
    assert_patch(view, ~p"/sessions/#{session_two.id}")
    refute assigns(view).moving_task_id
    assert assigns(view).expanded_task_status == "triage"
    assert assigns(view).project.id == project_two.id
    assert assigns(view).session.id == session_two.id
  end
end
