defmodule IexCodeWeb.WorkspaceLiveSignalFoundryCalendarTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCode.Kanban

  defp create_task!(project, session, attrs) do
    {:ok, task} =
      attrs
      |> Map.merge(%{project_id: project.id, session_id: session.id})
      |> Kanban.create_task()

    task
  end

  defp open_calendar(conn, session) do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=calendar")
    view
  end

  defp utc_at(date, time \\ ~T[09:00:00]) do
    DateTime.new!(date, time, "Etc/UTC")
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "one calendar chassis presents one bounded real agenda in both responsive variants", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()

    later =
      create_task!(project, session, %{
        title: "Later factual action",
        status: "todo",
        scheduled_at: utc_at(Date.add(today, 2), ~T[18:30:00])
      })

    earlier =
      create_task!(project, session, %{
        title: "Earlier factual action",
        status: "done",
        scheduled_at: utc_at(today, ~T[00:01:00])
      })

    same_time_a =
      create_task!(project, session, %{
        title: "Equal instant A",
        status: "ready",
        scheduled_at: utc_at(Date.add(today, 1), ~T[12:00:00])
      })

    same_time_b =
      create_task!(project, session, %{
        title: "Equal instant B",
        status: "blocked",
        scheduled_at: same_time_a.scheduled_at
      })

    _nil_time =
      create_task!(project, session, %{
        title: "Scheduled label only",
        status: "scheduled"
      })

    _synthetic =
      create_task!(project, session, %{
        title: "Cron metadata fiction",
        status: "scheduled",
        cron_expression: "0 9 * * *",
        metadata: %{"date" => Date.to_iso8601(Date.add(today, 3))}
      })

    _past =
      create_task!(project, session, %{
        title: "Previous UTC date",
        status: "scheduled",
        scheduled_at: utc_at(Date.add(today, -1))
      })

    view = open_calendar(conn, session)

    assert has_element?(view, "#instrument-workbench-calendar[data-workbench-surface='calendar']")
    assert has_element?(view, "#calendar-mobile-agenda[data-mobile-default='true'].sm\\:hidden")
    assert has_element?(view, "#calendar-month-view.hidden.sm\\:block")
    assert has_element?(view, "#calendar-month-view #calendar-desktop-agenda")
    assert has_element?(view, "#calendar-month-view #calendar-weekdays")
    assert has_element?(view, "#calendar-month-view #calendar-grid")

    document = view |> render() |> LazyHTML.from_fragment()

    ids =
      document
      |> LazyHTML.query("[id]")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

    assert Enum.uniq(ids) == ids

    assert document
           |> LazyHTML.query("#instrument-workbench-calendar")
           |> LazyHTML.to_tree()
           |> length() == 1

    assert document |> LazyHTML.query("#calendar-grid") |> LazyHTML.to_tree() |> length() == 1

    assert document
           |> LazyHTML.query("#calendar-grid > .calendar-day")
           |> LazyHTML.to_tree()
           |> length() == 42

    assert document |> LazyHTML.query("#prompt-composer") |> LazyHTML.to_tree() |> length() == 1

    assert has_element?(
             view,
             "#instrument-workbench-calendar [data-workbench-command-dock] #prompt-composer"
           )

    equal_order = Enum.sort_by([same_time_a, same_time_b], & &1.id)
    expected_titles = [earlier.title | Enum.map(equal_order, & &1.title)] ++ [later.title]

    for container <- ["#calendar-mobile-agenda-items", "#calendar-desktop-agenda-items"] do
      agenda_text = document |> LazyHTML.query(container) |> LazyHTML.text()

      positions =
        Enum.map(expected_titles, fn title -> :binary.match(agenda_text, title) |> elem(0) end)

      assert positions == Enum.sort(positions)
      refute agenda_text =~ "Scheduled label only"
      refute agenda_text =~ "Cron metadata fiction"
      refute agenda_text =~ "Previous UTC date"
    end

    for task <- [earlier, same_time_a, same_time_b, later] do
      iso = DateTime.to_iso8601(task.scheduled_at)

      assert has_element?(
               view,
               "#calendar-local-time-#{task.id}[phx-hook='LocalTime'][phx-update='ignore'][data-utc='#{iso}']",
               "#{iso} UTC"
             )

      assert has_element?(
               view,
               "#calendar-local-time-desktop-#{task.id}[phx-hook='LocalTime'][phx-update='ignore'][data-utc='#{iso}']",
               "#{iso} UTC"
             )
    end

    refute has_element?(view, "#instrument-workbench-calendar", "MONTHLY RUNS")
    refute has_element?(view, "[data-calendar-monthly-runs]")
  end

  test "empty agendas use the exact factual fallback in both presentations", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    view = open_calendar(conn, session)

    assert has_element?(
             view,
             "#calendar-mobile-agenda-items > #calendar-mobile-agenda-empty",
             "No scheduled actions"
           )

    assert has_element?(
             view,
             "#calendar-desktop-agenda-items > #calendar-desktop-agenda-empty",
             "No scheduled actions"
           )

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#calendar-mobile-agenda-empty")
           |> LazyHTML.text()
           |> String.trim() == "No scheduled actions"

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#calendar-desktop-agenda-empty")
           |> LazyHTML.text()
           |> String.trim() == "No scheduled actions"
  end

  test "agenda sorts the complete eligible input before taking the earliest 100", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()

    tasks =
      for offset <- Enum.to_list(0..100) |> Enum.reverse() do
        create_task!(project, session, %{
          title: "Bound action #{offset}",
          status: "ready",
          scheduled_at: utc_at(Date.add(today, offset), ~T[11:00:00])
        })
      end

    view = open_calendar(conn, session)

    chronologically = Enum.sort_by(tasks, &DateTime.to_unix(&1.scheduled_at, :microsecond))

    for task <- Enum.take(chronologically, 100) do
      assert has_element?(view, "#calendar-mobile-agenda-item-#{task.id}")
    end

    latest = List.last(chronologically)
    refute has_element?(view, "#calendar-mobile-agenda-item-#{latest.id}")
    refute has_element?(view, "#calendar-desktop-agenda-item-#{latest.id}")
  end

  test "calendar controls preserve month anatomy and expose sibling agenda actions", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()

    task =
      create_task!(project, session, %{
        title: "Action controls",
        status: "scheduled",
        scheduled_at: utc_at(today)
      })

    view = open_calendar(conn, session)
    day_id = "calendar-day-#{today.day}"

    assert has_element?(
             view,
             "#calendar-today[phx-click='select_calendar_day'][phx-value-date='#{Date.to_iso8601(today)}']"
           )

    assert has_element?(view, "#calendar-prev-month[phx-click='calendar_prev_month']")
    assert has_element?(view, "#calendar-next-month[phx-click='calendar_next_month']")
    assert has_element?(view, "#calendar-focus-time-btn[phx-click='open_time_picker']")
    assert has_element?(view, "##{day_id} > button##{day_id}-select[aria-label][aria-pressed]")
    assert has_element?(view, "##{day_id} > div button#calendar-task-#{today.day}-#{task.id}")

    refute has_element?(
             view,
             "button##{day_id}-select button#calendar-task-#{today.day}-#{task.id}"
           )

    for variant <- ~w(mobile desktop) do
      row = "#calendar-#{variant}-agenda-item-#{task.id}"

      assert has_element?(
               view,
               "#{row} > button#calendar-#{variant}-agenda-open-#{task.id}[phx-click='show_scheduled_task']"
             )

      assert has_element?(
               view,
               "#{row} > div button#calendar-#{variant}-agenda-run-#{task.id}[phx-click='run_scheduled_task'][phx-disable-with='Running…']"
             )

      assert has_element?(
               view,
               "#{row} > div button#calendar-#{variant}-agenda-edit-#{task.id}[phx-click='open_edit_scheduled_task']"
             )

      assert has_element?(
               view,
               "#{row} > div button#calendar-#{variant}-agenda-delete-trigger-#{task.id}[phx-click='request_calendar_task_delete']"
             )

      refute has_element?(view, "#{row} button button")
    end
  end

  test "today and month navigation update authoritative calendar state", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    view = open_calendar(conn, session)
    initial = assigns(view)

    render_click(view, "calendar_next_month")
    next = assigns(view)

    assert {next.calendar_year, next.calendar_month} !=
             {initial.calendar_year, initial.calendar_month}

    render_click(view, "calendar_prev_month")
    restored = assigns(view)

    assert {restored.calendar_year, restored.calendar_month} ==
             {initial.calendar_year, initial.calendar_month}

    today = Date.utc_today() |> Date.to_iso8601()
    render_click(view, "select_calendar_day", %{"date" => today})
    assert assigns(view).selected_calendar_date == today
    assert assigns(view).new_task_date == today
    assert has_element?(view, "#new-task-modal")
  end

  test "server-owned calendar delete confirmation is scoped, source-sensitive, cancellable, and cleans up",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()

    task = create_task!(project, session, %{title: "Delete safely", scheduled_at: utc_at(today)})
    view = open_calendar(conn, session)

    for {source, return_id, background_id} <- [
          {"mobile", "calendar-mobile-agenda-delete-trigger-#{task.id}", "workspace-shell"},
          {"desktop", "calendar-desktop-agenda-delete-trigger-#{task.id}", "workspace-shell"}
        ] do
      render_click(view, "request_calendar_task_delete", %{"id" => task.id, "source" => source})

      assert has_element?(
               view,
               "#calendar-delete-confirmation-#{task.id}[phx-hook='ResponsiveSheet'][data-sheet-close-event='cancel_calendar_task_delete'][data-sheet-return-id='#{return_id}'][data-sheet-background-id='#{background_id}']"
             )

      assert has_element?(
               view,
               "#calendar-delete-confirmation-dialog-#{task.id}[phx-hook='ModalFocus'][role='dialog'][aria-modal='true'][aria-labelledby='calendar-delete-confirmation-title'][tabindex='-1']"
             )

      assert has_element?(
               view,
               "#confirm-calendar-task-delete[phx-click*='confirm_calendar_task_delete'][phx-click*='calendar-focus-return-target'][phx-disable-with='Deleting…']"
             )

      render_click(view, "cancel_calendar_task_delete")
      refute has_element?(view, "#calendar-delete-confirmation-#{task.id}")
      assert Kanban.get_task(project.id, task.id)
    end

    render_click(view, "show_scheduled_task", %{"id" => task.id})
    render_click(view, "request_calendar_task_delete", %{"id" => task.id, "source" => "detail"})
    assert has_element?(view, "#scheduled-task-detail-modal")

    assert has_element?(
             view,
             "#calendar-delete-confirmation-#{task.id}[data-sheet-return-id='calendar-detail-delete-trigger-#{task.id}'][data-sheet-background-id='scheduled-task-detail-modal']"
           )

    refute has_element?(view, "#calendar-detail-delete-trigger-#{task.id}[data-confirm]")
    assert has_element?(view, "#calendar-delete-confirmation-#{task.id}", "Delete safely")
    refute has_element?(view, "#confirm-calendar-task-delete[phx-value-id]")

    render_click(view, "confirm_calendar_task_delete")
    refute has_element?(view, "#calendar-delete-confirmation-#{task.id}")
    refute has_element?(view, "#scheduled-task-detail-modal")
    assert Kanban.get_task(project.id, task.id) == nil
  end

  test "scheduled edit uses an assigned task form with stable inputs and visible pending copy", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    task =
      create_task!(project, session, %{
        title: "Edit safely",
        description: "Original instructions",
        status: "scheduled",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)
    render_click(view, "open_edit_scheduled_task", %{"id" => task.id})

    assert has_element?(
             view,
             "#edit-scheduled-task-form input[name='task[id]'][value='#{task.id}']"
           )

    assert has_element?(
             view,
             "#edit-scheduled-task-title[name='task[title]'][value='Edit safely']"
           )

    assert has_element?(view, "#edit-scheduled-task-description[name='task[description]']")
    assert has_element?(view, "#edit-scheduled-task-priority[name='task[priority]']")
    assert has_element?(view, "#edit-scheduled-task-assignee[name='task[assignee]']")
    assert has_element?(view, "#edit-scheduled-task-cron[name='task[cron_expression]']")

    assert has_element?(
             view,
             "#edit-scheduled-task-form button[type='submit'][phx-disable-with='Saving…']"
           )

    view
    |> form("#edit-scheduled-task-form", %{
      "task" => %{
        "id" => task.id,
        "title" => "Edited factual title",
        "description" => "Updated instructions",
        "priority" => "high",
        "assignee" => "planner",
        "cron_expression" => ""
      }
    })
    |> render_submit()

    assert Kanban.get_task(project.id, task.id).title == "Edited factual title"
    refute has_element?(view, "#edit-scheduled-task-modal")
  end

  test "historical selected month remains factual while forward agenda stays date bounded", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    today = Date.utc_today()
    previous_month_last = Date.add(%{today | day: 1}, -1)
    historical = %{previous_month_last | day: min(14, previous_month_last.day)}

    task =
      create_task!(project, session, %{
        title: "Historical month task",
        status: "scheduled",
        scheduled_at: utc_at(historical)
      })

    view = open_calendar(conn, session)

    render_click(view, "calendar_prev_month")
    assert has_element?(view, "#calendar-grid #calendar-task-#{historical.day}-#{task.id}")
    refute has_element?(view, "#calendar-mobile-agenda-item-#{task.id}")
  end

  test "running a scheduled task from calendar navigates one canonical swarm surface", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    task =
      create_task!(project, session, %{
        title: "Canonical run",
        status: "scheduled",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)

    render_click(view, "run_scheduled_task", %{"id" => task.id})
    assert_patch(view, ~p"/sessions/#{session.id}?view=swarm")
    _ = :sys.get_state(view.pid)
    state = assigns(view)
    assert state.active_view == "swarm"
    assert state.active_tab == "swarm"
    refute has_element?(view, "#instrument-workbench-calendar")
    assert has_element?(view, "#interactive-operation-history-note")
    document = view |> render() |> LazyHTML.from_fragment()
    assert document |> LazyHTML.query("#prompt-composer") |> LazyHTML.to_tree() |> length() == 1
  end

  test "calendar deletion is authoritative to retained pending state", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    first =
      create_task!(project, session, %{
        title: "First retained",
        scheduled_at: utc_at(Date.utc_today())
      })

    second =
      create_task!(project, session, %{
        title: "Second forged",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)

    render_click(view, "confirm_calendar_task_delete")
    assert Kanban.get_task(project.id, first.id)

    render_click(view, "delete_scheduled_task", %{"id" => first.id})
    assert Kanban.get_task(project.id, first.id)

    render_click(view, "request_calendar_task_delete", %{"id" => first.id, "source" => "mobile"})
    render_click(view, "confirm_calendar_task_delete", %{"id" => second.id})
    assert Kanban.get_task(project.id, first.id)
    assert Kanban.get_task(project.id, second.id)
    assert has_element?(view, "#calendar-delete-confirmation-#{first.id}")

    render_click(view, "confirm_calendar_task_delete")
    refute Kanban.get_task(project.id, first.id)
    assert Kanban.get_task(project.id, second.id)
  end

  test "calendar confirmation title is bounded and exclusively server-derived", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    title = String.duplicate("Server title ", 20)
    task = create_task!(project, session, %{title: title, scheduled_at: utc_at(Date.utc_today())})
    view = open_calendar(conn, session)

    render_click(view, "request_calendar_task_delete", %{
      "id" => task.id,
      "source" => "mobile",
      "title" => "FORGED CLIENT TITLE"
    })

    pending = assigns(view).pending_calendar_task_delete
    assert pending.title == String.slice(title, 0, 160)
    assert String.length(pending.title) == 160
    refute has_element?(view, "#calendar-delete-confirmation-#{task.id}", "FORGED CLIENT TITLE")
    assert has_element?(view, "#calendar-delete-confirmation-#{task.id}", pending.title)
  end

  test "calendar and Kanban confirmation requests cannot stack owners", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    task =
      create_task!(project, session, %{
        title: "Stack guard",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)

    render_click(view, "request_delete_task", %{"id" => task.id})
    assert has_element?(view, "#task-delete-confirmation-#{task.id}")
    render_click(view, "request_calendar_task_delete", %{"id" => task.id, "source" => "mobile"})
    refute has_element?(view, "#task-delete-confirmation-#{task.id}")
    assert has_element?(view, "#calendar-delete-confirmation-#{task.id}")

    render_click(view, "request_delete_task", %{"id" => task.id})
    assert has_element?(view, "#task-delete-confirmation-#{task.id}")
    refute has_element?(view, "#calendar-delete-confirmation-#{task.id}")

    render_click(view, "delete_session", %{"id" => session.id})
    assert has_element?(view, "#delete-session-confirmation")
    refute has_element?(view, "#task-delete-confirmation-#{task.id}")

    render_click(view, "request_calendar_task_delete", %{"id" => task.id, "source" => "desktop"})
    refute has_element?(view, "#delete-session-confirmation")
    assert has_element?(view, "#calendar-delete-confirmation-#{task.id}")
  end

  test "stale retained calendar deletion closes safely without mutating another task", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    stale =
      create_task!(project, session, %{
        title: "Stale retained",
        scheduled_at: utc_at(Date.utc_today())
      })

    survivor =
      create_task!(project, session, %{title: "Survivor", scheduled_at: utc_at(Date.utc_today())})

    view = open_calendar(conn, session)
    render_click(view, "request_calendar_task_delete", %{"id" => stale.id, "source" => "desktop"})
    IexCode.Repo.delete!(stale)

    render_click(view, "confirm_calendar_task_delete")
    refute has_element?(view, "#calendar-delete-confirmation-#{stale.id}")
    assert Kanban.get_task(project.id, survivor.id)
  end

  test "malformed and foreign task IDs cannot open a calendar confirmation", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_project = create_project_fixture(%{root_path: Path.join(path, "foreign-calendar")})
    foreign_session = create_session_fixture(foreign_project)

    foreign_task =
      create_task!(foreign_project, foreign_session, %{
        title: "Foreign secret title",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)

    for id <- ["not-a-uuid", foreign_task.id] do
      render_click(view, "request_calendar_task_delete", %{"id" => id, "source" => "mobile"})
      refute has_element?(view, "[id^='calendar-delete-confirmation-']")
    end

    refute assigns(view).pending_calendar_task_delete
  end

  test "matching project PubSub deletion clears calendar modal and pending confirmation state", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    task =
      create_task!(project, session, %{
        title: "PubSub cleanup",
        scheduled_at: utc_at(Date.utc_today())
      })

    view = open_calendar(conn, session)

    render_click(view, "show_scheduled_task", %{"id" => task.id})
    render_click(view, "request_calendar_task_delete", %{"id" => task.id, "source" => "detail"})
    assert has_element?(view, "#calendar-delete-confirmation-#{task.id}")

    send(view.pid, {:task_deleted, task})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#calendar-delete-confirmation-#{task.id}")
    refute has_element?(view, "#scheduled-task-detail-modal")
    assert assigns(view).selected_scheduled_task == nil
    render_click(view, "confirm_calendar_task_delete")
    assert Kanban.get_task(project.id, task.id)
  end

  test "calendar visual contracts use neutral tokens, readable type, coarse targets and safe areas" do
    template = File.read!("lib/iex_code_web/live/workspace_live.html.heex")
    css = File.read!("assets/css/app.css")

    detail =
      template
      |> String.split("Scheduled Task Details Modal", parts: 2)
      |> List.last()
      |> String.split("Create Agent Task Modal", parts: 2)
      |> hd()

    for forbidden <- [
          "bg-[#",
          "text-white",
          "text-gray-",
          "text-cyan-",
          "text-orange-",
          "shadow-orange",
          "✕"
        ] do
      refute detail =~ forbidden
    end

    assert detail =~ "var(--sf-instrument-raised)"
    assert detail =~ ~s|<.icon name="hero-x-mark"|
    assert css =~ ".calendar-agenda-row"
    assert css =~ "border-bottom: 1px solid var(--sf-hairline)"
    assert css =~ ".calendar-agenda-time"
    assert css =~ "font-size: 0.875rem"
    assert css =~ "@media (pointer: coarse) and (min-width: 40rem)"
    assert css =~ ".calendar-day-task { min-height: 44px; }"
    assert css =~ "env(safe-area-inset-top)"
    assert css =~ "env(safe-area-inset-right)"
    assert css =~ "env(safe-area-inset-bottom)"
    assert css =~ "env(safe-area-inset-left)"
    assert css =~ ".sf-chassis.calendar-confirmation-dialog"
    assert css =~ "max-height: calc(100dvh"
  end
end
