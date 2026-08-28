defmodule IexCode.KanbanSummaryTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Kanban, Projects, Sessions}
  alias IexCode.Kanban.Task

  test "returns bounded project aggregate with UTC boundaries and zero statuses" do
    root_a = Path.join(System.tmp_dir!(), "kanban-summary-a-#{Ecto.UUID.generate()}")
    root_b = Path.join(System.tmp_dir!(), "kanban-summary-b-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      File.rm_rf!(root_a)
      File.rm_rf!(root_b)
    end)

    {:ok, project_a} = Projects.create_project(%{name: "A", root_path: root_a})
    {:ok, project_b} = Projects.create_project(%{name: "B", root_path: root_b})
    {:ok, session_a} = Sessions.create_session(%{project_id: project_a.id, title: "A"})

    today = ~D[2026-08-28]
    now = ~U[2026-08-28 12:00:00Z]
    day_start = ~U[2026-08-28 00:00:00Z]
    day_end = ~U[2026-08-28 23:59:59Z]
    past = ~U[2026-08-27 23:59:59Z]
    future_1 = ~U[2026-08-28 12:00:01Z]
    future_2 = ~U[2026-08-29 09:00:00Z]

    Enum.each(Task.statuses(), fn status ->
      scheduled_at =
        case status do
          "triage" -> day_start
          "todo" -> day_end
          "scheduled" -> past
          "ready" -> future_1
          "running" -> future_2
          "blocked" -> nil
          "review" -> now
          "done" -> nil
        end

      assert {:ok, _} =
               Kanban.create_task(%{
                 project_id: project_a.id,
                 session_id: session_a.id,
                 title: "A #{status}",
                 description: "A secret description #{status}",
                 status: status,
                 scheduled_at: scheduled_at
               })
    end)

    assert {:ok, _} =
             Kanban.create_task(%{
               project_id: project_a.id,
               session_id: session_a.id,
               title: "A duplicate",
               status: "ready",
               scheduled_at: future_2
             })

    assert {:ok, _} =
             Kanban.create_task(%{
               project_id: project_b.id,
               title: "B secret marker",
               description: "B secret description",
               status: "triage",
               scheduled_at: ~U[2026-08-28 00:00:00Z]
             })

    summary = Kanban.summary(project_a.id, today: today, now: now)

    assert Map.keys(summary) |> Enum.sort() == [:next_scheduled_at, :status_counts, :today_count]

    assert summary.status_counts == %{
             "triage" => 1,
             "todo" => 1,
             "scheduled" => 1,
             "ready" => 2,
             "running" => 1,
             "blocked" => 1,
             "review" => 1,
             "done" => 1
           }

    assert summary.today_count == 4
    assert summary.next_scheduled_at == future_1
    refute inspect(summary) =~ "A secret"
    refute inspect(summary) =~ "B secret"
    refute inspect(summary) =~ "%IexCode.Kanban.Task"

    assert Kanban.summary(project_b.id, today: today, now: now) == %{
             status_counts: %{
               "triage" => 1,
               "todo" => 0,
               "scheduled" => 0,
               "ready" => 0,
               "running" => 0,
               "blocked" => 0,
               "review" => 0,
               "done" => 0
             },
             today_count: 1,
             next_scheduled_at: nil
           }

    assert Kanban.summary(Ecto.UUID.generate(), today: today, now: now) == %{
             status_counts: Map.new(Task.statuses(), &{&1, 0}),
             today_count: 0,
             next_scheduled_at: nil
           }
  end
end
