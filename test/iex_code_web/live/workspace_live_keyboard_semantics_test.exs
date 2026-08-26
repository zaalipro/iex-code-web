defmodule IexCodeWeb.WorkspaceLiveKeyboardSemanticsTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCode.{Kanban, Sessions}

  setup %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, message} =
      Sessions.create_message(%{
        session_id: session.id,
        role: "assistant",
        agent_name: "VerifierAgent",
        content: "Keyboard navigation verification"
      })

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Keyboard accessible card",
        status: "ready",
        priority: "medium",
        assignee: "verifier",
        scheduled_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    %{view: view, session: session, message: message, task: task}
  end

  test "sidebar controls are semantic and content selection is not disabled globally", %{
    view: view,
    session: session
  } do
    assert has_element?(
             view,
             "a#profile-settings-card[href='/sessions/#{session.id}/settings#runtime'][data-phx-link='redirect']"
           )

    refute has_element?(view, "#workspace-shell.select-none")

    assert has_element?(
             view,
             "button[phx-click='delete_session'][phx-value-id='#{session.id}'][aria-label]"
           )
  end

  test "kanban ribbons and cards are native buttons", %{view: view, task: task} do
    assert has_element?(view, "#kanban-board[role='region'][aria-label='Task status board']")

    assert has_element?(
             view,
             "button#kanban-col-scheduled[data-column-variant='collapsed'][aria-expanded='false'] .kanban-column__label"
           )

    view
    |> element("#kanban-col-ready")
    |> render_click()

    assert has_element?(view, "#kanban-col-ready[data-column-variant='expanded']")

    assert has_element?(
             view,
             "button#kanban-collapse-ready[aria-expanded='true'][aria-controls='kanban-cards-ready']"
           )

    assert has_element?(view, "button#task-card-#{task.id}")
  end

  test "calendar day selectors and scheduled tasks are separate native buttons", %{
    view: view,
    task: task
  } do
    view |> element("#sidebar-tab-calendar") |> render_click()

    today = Date.utc_today()
    day_id = "calendar-day-#{today.day}"

    assert has_element?(
             view,
             "##{day_id} > button##{day_id}-select[aria-label][aria-pressed]"
           )

    assert has_element?(view, "##{day_id} > div button#calendar-task-#{today.day}-#{task.id}")
    refute has_element?(view, "[id^='calendar-day-'][role='button']")

    refute has_element?(
             view,
             "button##{day_id}-select button#calendar-task-#{today.day}-#{task.id}"
           )

    view |> element("##{day_id}-select") |> render_click()
    assert has_element?(view, "#new-task-modal")

    render_click(view, "toggle_new_task_modal")
    view |> element("#calendar-task-#{today.day}-#{task.id}") |> render_click()
    assert has_element?(view, "#scheduled-task-detail-modal")
  end

  test "calendar Monday-first headings align with month dates", %{view: view} do
    view |> element("#sidebar-tab-calendar") |> render_click()

    first_of_month = %{Date.utc_today() | day: 1}

    assert has_element?(view, "#calendar-weekdays > #calendar-weekday-mon:first-child")
    assert has_element?(view, "#calendar-weekdays > #calendar-weekday-sun:last-child")

    assert has_element?(
             view,
             "#calendar-grid > #calendar-day-1:nth-child(#{Date.day_of_week(first_of_month)})"
           )
  end

  test "chat minimap nodes and schedule triggers are keyboard controls", %{
    view: view,
    message: message
  } do
    view |> element("#sidebar-tab-chat") |> render_click()
    assert has_element?(view, "button#scroll-node-#{message.id}[aria-label]")

    render_click(view, "toggle_new_task_modal")

    assert has_element?(view, "button#target-date-picker-trigger[aria-haspopup='dialog']")
    assert has_element?(view, "button#target-time-slot-trigger[aria-haspopup='dialog']")
  end
end
