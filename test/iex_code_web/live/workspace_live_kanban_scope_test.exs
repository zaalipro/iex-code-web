defmodule IexCodeWeb.WorkspaceLiveKanbanScopeTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.{Kanban, Runs}

  test "forged foreign-project task ids cannot read, mutate, claim, delete, or dispatch", %{
    conn: conn,
    workspace_path: path
  } do
    current_project = create_project_fixture(%{root_path: path})
    current_session = create_session_fixture(current_project)

    foreign_project =
      create_project_fixture(%{
        root_path: Path.join(path, "foreign-project")
      })

    foreign_session = create_session_fixture(foreign_project)

    {:ok, foreign_task} =
      Kanban.create_task(%{
        project_id: foreign_project.id,
        session_id: foreign_session.id,
        title: "FOREIGN PROJECT SECRET TASK",
        description: "Must never be rendered or dispatched from another project",
        status: "scheduled",
        priority: "high",
        assignee: "verifier",
        scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        subtasks: [
          %{"id" => "foreign-subtask", "title" => "Private subtask", "completed" => false}
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{current_session.id}")

    html = render_click(view, "show_scheduled_task", %{"id" => foreign_task.id})
    refute html =~ "FOREIGN PROJECT SECRET TASK"
    refute has_element?(view, "#scheduled-task-detail-modal")

    html = render_click(view, "open_edit_scheduled_task", %{"id" => foreign_task.id})
    refute html =~ "FOREIGN PROJECT SECRET TASK"
    refute has_element?(view, "#edit-scheduled-task-modal")

    render_click(view, "open_task_drawer", %{"id" => foreign_task.id})
    refute has_element?(view, "#task-detail-drawer")

    render_submit(view, "update_scheduled_task", %{
      "id" => foreign_task.id,
      "title" => "hijacked scheduled task",
      "priority" => "low",
      "assignee" => "coder"
    })

    render_click(view, "move_task", %{"id" => foreign_task.id, "status" => "done"})
    render_click(view, "update_task_priority", %{"id" => foreign_task.id, "priority" => "low"})
    render_click(view, "update_task_assignee", %{"id" => foreign_task.id, "assignee" => "coder"})

    render_click(view, "update_task", %{
      "id" => foreign_task.id,
      "task" => %{"title" => "hijacked task", "status" => "done"}
    })

    render_click(view, "add_subtask", %{
      "task_id" => foreign_task.id,
      "title" => "Injected subtask"
    })

    render_click(view, "toggle_subtask", %{
      "task_id" => foreign_task.id,
      "id" => "foreign-subtask"
    })

    render_click(view, "delete_subtask", %{
      "task_id" => foreign_task.id,
      "id" => "foreign-subtask"
    })

    render_click(view, "claim_task", %{"id" => foreign_task.id})
    render_click(view, "estimate_task", %{"id" => foreign_task.id})
    render_click(view, "run_scheduled_task", %{"id" => foreign_task.id})
    render_click(view, "delete_scheduled_task", %{"id" => foreign_task.id})
    render_click(view, "delete_task", %{"id" => foreign_task.id})

    persisted = Kanban.get_task!(foreign_task.id)
    assert persisted.title == "FOREIGN PROJECT SECRET TASK"
    assert persisted.status == "scheduled"
    assert persisted.priority == "high"
    assert persisted.assignee == "verifier"
    assert persisted.worker_pid == nil
    assert persisted.estimate == nil

    assert persisted.subtasks == [
             %{"id" => "foreign-subtask", "title" => "Private subtask", "completed" => false}
           ]

    assert Runs.list_runs(project_id: current_project.id) == []
    assert Runs.list_runs(project_id: foreign_project.id) == []
  end

  test "manual task dispatch is idempotent and cannot select its run from another session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    first_session = create_session_fixture(project)
    second_session = create_session_fixture(project)

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: first_session.id,
        title: "Dispatch exactly once",
        description: "Two rapid clicks must converge on one durable run",
        status: "scheduled",
        scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })

    {:ok, first_view, _html} = live(conn, ~p"/sessions/#{first_session.id}")
    {:ok, duplicate_view, _html} = live(conn, ~p"/sessions/#{first_session.id}")

    [first_view, duplicate_view]
    |> Task.async_stream(
      &render_click(&1, "run_scheduled_task", %{"id" => task.id}),
      ordered: false,
      max_concurrency: 2,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, html} -> assert is_binary(html) end)

    assert [run] = Runs.list_runs(session_id: first_session.id)
    assert run.request_key =~ "kanban:manual:#{task.id}:"
    assert Kanban.get_task!(task.id).worker_pid == "run:#{run.id}"

    {:ok, second_view, _html} = live(conn, ~p"/sessions/#{second_session.id}")
    html = render_click(second_view, "run_scheduled_task", %{"id" => task.id})

    assert html =~ "already linked to a durable run in another session"
    assert Runs.list_runs(session_id: second_session.id) == []
    assert [same_run] = Runs.list_runs(session_id: first_session.id)
    assert same_run.id == run.id
    assert Kanban.get_task!(task.id).worker_pid == "run:#{run.id}"

    assert {:ok, failed} = Runs.transition_run(run, "failed")

    terminal_task =
      case Kanban.get_task!(task.id) do
        %{status: "blocked"} = projected ->
          projected

        _running ->
          assert {:ok, projected} = Kanban.project_run_terminal(failed.id, failed.status)
          projected
      end

    assert terminal_task.status == "blocked"
    assert terminal_task.worker_pid == nil

    render_click(first_view, "run_scheduled_task", %{"id" => task.id})

    runs = Runs.list_runs(session_id: first_session.id)
    assert length(runs) == 2
    assert Enum.any?(runs, &(&1.id == run.id))
    new_run = Enum.find(runs, &(&1.id != run.id))
    refute new_run.request_key == run.request_key
    assert Kanban.get_task!(task.id).worker_pid == "run:#{new_run.id}"
  end
end
