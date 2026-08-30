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

  test "switchboard controls are semantic and content selection is not disabled globally", %{
    view: view,
    session: session
  } do
    refute has_element?(view, "#workspace-shell.select-none")
    view |> element("#all-instruments-trigger") |> render_click()
    assert has_element?(view, "#command-palette-dialog[role='dialog'][aria-modal='true']")

    assert has_element?(
             view,
             "[data-palette-item-id='delete-session-#{session.id}']"
           )

    refute has_element?(
             view,
             "[data-palette-item-id='delete-session-#{session.id}'][data-confirm]"
           )

    assert has_element?(view, "#workspace-logout-form[action='/logout'][method='post']")
    refute has_element?(view, "#workspace-sidebar")
    refute has_element?(view, "#workspace-desktop-tabs")
  end

  test "kanban channels and sibling task movement controls are keyboard semantic", %{
    view: view,
    task: task
  } do
    view |> element("#instrument-card-kanban") |> render_click()

    assert has_element?(view, "#kanban-board[role='region'][aria-label='Task status board']")

    assert has_element?(
             view,
             "#kanban-col-scheduled[data-channel-state='quiet'][aria-expanded='false'] button#kanban-channel-trigger-scheduled"
           )

    view
    |> element("#kanban-channel-trigger-ready")
    |> render_click()

    assert has_element?(
             view,
             "#kanban-col-ready[data-channel-state='selected'][aria-expanded='true'] #kanban-cards-ready"
           )

    assert has_element?(view, "article#task-row-#{task.id} > button#task-card-#{task.id}")

    assert has_element?(
             view,
             "article#task-row-#{task.id} > button#move-task-trigger-#{task.id}[aria-expanded='false']"
           )

    refute has_element?(view, "button#task-card-#{task.id} button")
    refute has_element?(view, "button#task-card-#{task.id} form")
  end

  test "calendar day selectors and scheduled tasks are separate native buttons", %{
    view: view,
    task: task
  } do
    view |> element("#instrument-card-calendar") |> render_click()

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
    view |> element("#instrument-card-calendar") |> render_click()

    first_of_month = %{Date.utc_today() | day: 1}

    assert has_element?(view, "#calendar-weekdays > #calendar-weekday-mon:first-child")
    assert has_element?(view, "#calendar-weekdays > #calendar-weekday-sun:last-child")

    assert has_element?(
             view,
             "#calendar-grid > #calendar-day-1:nth-child(#{Date.day_of_week(first_of_month)})"
           )
  end

  test "calendar agenda actions are sibling controls and delete returns focus to its source", %{
    view: view,
    task: task
  } do
    view |> element("#instrument-card-calendar") |> render_click()

    row = "#calendar-mobile-agenda-item-#{task.id}"
    assert has_element?(view, "#{row} > button[aria-label='Open Keyboard accessible card']")

    assert has_element?(
             view,
             "#{row} > div > button[aria-label='Run Keyboard accessible card now']"
           )

    assert has_element?(view, "#{row} > div > button[aria-label='Edit Keyboard accessible card']")

    assert has_element?(
             view,
             "#{row} > div > button[aria-label='Delete Keyboard accessible card']"
           )

    refute has_element?(view, "#{row} button button")

    view |> element("#calendar-mobile-agenda-delete-trigger-#{task.id}") |> render_click()

    assert has_element?(
             view,
             "#calendar-delete-confirmation-#{task.id}[data-sheet-return-id='calendar-mobile-agenda-delete-trigger-#{task.id}'][data-sheet-background-id='workspace-shell'][data-sheet-close-event='cancel_calendar_task_delete']"
           )

    assert has_element?(
             view,
             "#calendar-delete-confirmation-dialog-#{task.id}[role='dialog'][aria-modal='true'][aria-labelledby='calendar-delete-confirmation-title']"
           )
  end

  test "chat minimap nodes and schedule triggers are keyboard controls", %{
    view: view,
    message: message
  } do
    view |> element("#instrument-card-chat") |> render_click()
    assert has_element?(view, "button#scroll-node-#{message.id}[aria-label]")

    render_click(view, "toggle_new_task_modal")

    assert has_element?(view, "button#target-date-picker-trigger[aria-haspopup='dialog']")
    assert has_element?(view, "button#target-time-slot-trigger[aria-haspopup='dialog']")
  end

  test "chat phone jump trigger exposes dialog semantics", %{view: view} do
    view |> element("#instrument-card-chat") |> render_click()

    assert has_element?(
             view,
             "button#chat-jump-to-message[type='button'][aria-haspopup='dialog'][aria-controls='chat-jump-sheet'][aria-expanded='false']"
           )
  end

  test "chat jump sheet owns its lifecycle and only jumps to retained messages", %{
    view: view,
    session: session,
    message: message
  } do
    view |> element("#instrument-card-chat") |> render_click()
    view |> element("#chat-jump-to-message") |> render_click()

    assert has_element?(
             view,
             "#chat-jump-sheet[phx-hook='ResponsiveSheet'][role='dialog'][aria-modal='true'][aria-labelledby='chat-jump-sheet-title'][tabindex='-1'][data-sheet-close-event='close_chat_jump_sheet'][data-sheet-return-id='chat-jump-to-message'][data-sheet-background-id='chat-viewport']"
           )

    assert has_element?(view, "#chat-jump-sheet-title", "Jump to message")
    assert has_element?(view, "#chat-jump-message-#{message.id}")
    assert live_assigns(view).chat_jump_sheet_open?

    retained_ids = Enum.map(live_assigns(view).messages, & &1.id)
    document = view |> render() |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#chat-jump-sheet button[phx-click='jump_to_message']")
           |> Enum.count() == length(retained_ids)

    assert Enum.all?(retained_ids, &has_element?(view, "#chat-jump-message-#{&1}"))

    render_click(view, "jump_to_message", %{"id" => ""})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    assert live_assigns(view).chat_jump_sheet_open?

    render_click(view, "jump_to_message", %{})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    assert live_assigns(view).chat_jump_sheet_open?

    render_click(view, "jump_to_message", %{"id" => "msg-0"})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    assert live_assigns(view).chat_jump_sheet_open?

    foreign_session = create_session_fixture(live_assigns(view).project)
    foreign_message = create_message_fixture(foreign_session, %{content: "Foreign jump"})
    render_click(view, "jump_to_message", %{"id" => foreign_message.id})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    assert live_assigns(view).chat_jump_sheet_open?

    off_page = create_message_fixture(session, %{content: "Not in the retained DOM"})
    render_click(view, "jump_to_message", %{"id" => off_page.id})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    assert live_assigns(view).chat_jump_sheet_open?

    render_click(view, "jump_to_message", %{"id" => message.id})
    assert_push_event(view, "scroll_to_msg", %{id: message_id})
    assert message_id == message.id
    refute live_assigns(view).chat_jump_sheet_open?
    refute has_element?(view, "#chat-jump-sheet")

    render_click(view, "scroll_to_msg", %{"id" => off_page.id})
    refute_push_event(view, "scroll_to_msg", %{id: _})
    render_click(view, "scroll_to_msg", %{"id" => message.id})
    assert_push_event(view, "scroll_to_msg", %{id: message_id})
    assert message_id == message.id

    view |> element("#chat-jump-to-message") |> render_click()
    view |> element("#chat-jump-sheet-close") |> render_click()
    refute live_assigns(view).chat_jump_sheet_open?
  end

  test "empty conversation keeps phone jump disabled and refuses to open", %{
    conn: conn,
    view: view
  } do
    empty_session = create_session_fixture(live_assigns(view).project)
    {:ok, empty_view, _html} = live(conn, ~p"/sessions/#{empty_session.id}?view=chat")

    assert has_element?(empty_view, "#chat-jump-to-message[disabled][aria-expanded='false']")
    render_click(empty_view, "open_chat_jump_sheet")
    refute live_assigns(empty_view).chat_jump_sheet_open?
    refute has_element?(empty_view, "#chat-jump-sheet")
  end

  defp live_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> then(& &1.socket.assigns)
  end
end
