defmodule IexCode.Kanban.SchedulerTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Kanban, Projects, Repo, Runs, Sessions}
  alias IexCode.Kanban.Scheduler

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-scheduler-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, project} = Projects.create_project(%{name: "Scheduled project", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Scheduled"})
    {:ok, project: project, session: session}
  end

  test "claims each due occurrence once and enqueues a typed durable run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Verify the release",
        description: "Run the full release verification",
        priority: "high",
        scheduled_at: due
      })

    result =
      Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "scheduler-test")

    assert %{claimed: 1, enqueued: 1, errors: []} = result
    assert_receive {:"$gen_cast", :dispatch}

    [run] = Runs.list_runs(project_id: context.project.id)
    assert run.kind == "coding_swarm"
    assert run.mode == "swarm"
    assert run.priority == "high"
    assert run.request_key == Kanban.schedule_occurrence_key(task)
    assert run.metadata["source"] == "kanban_schedule"
    assert run.metadata["kanban_task_id"] == task.id

    dispatched = Kanban.get_task!(task.id)
    assert dispatched.status == "running"
    assert dispatched.worker_pid == "run:#{run.id}"

    assert %{claimed: 0, enqueued: 0} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "scheduler-test-2")

    assert length(Runs.list_runs(project_id: context.project.id)) == 1
  end

  test "concurrent workers cannot both claim the same due occurrence", context do
    due = ~U[2026-08-23 10:00:00Z]
    assert {:ok, _task} = scheduled_task(context, %{title: "Claim once", scheduled_at: due})

    results =
      1..2
      |> Task.async_stream(
        fn worker -> Kanban.claim_due_scheduled_tasks("worker-#{worker}", now: due, limit: 1) end,
        ordered: false,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sum(Enum.map(results, fn {:ok, tasks} -> length(tasks) end)) == 1
  end

  test "supervised worker dispatches due work without a LiveView", context do
    due = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    assert {:ok, _task} = scheduled_task(context, %{title: "Background run", scheduled_at: due})

    name = :"kanban-scheduler-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Scheduler,
         name: name, dispatcher: self(), worker_id: "supervised-test", poll_interval: 60_000}
      )

    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert_receive {:"$gen_cast", :dispatch}
    assert [_run] = Runs.list_runs(project_id: context.project.id)
  end

  test "advances a recurring schedule only after its run is durable", context do
    due = ~U[2026-08-24 09:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Weekday maintenance",
        scheduled_at: due,
        cron_expression: "0 9 * * 1-5"
      })

    assert %{claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "recurring")

    updated = Kanban.get_task!(task.id)
    assert updated.status == "scheduled"
    assert updated.worker_pid == nil
    assert updated.claimed_at == nil
    assert updated.scheduled_at == ~U[2026-08-25 09:00:00Z]
  end

  test "recovers only stale scheduler claims and reuses an already-created run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} = scheduled_task(context, %{title: "Recover me", scheduled_at: due})
    assert {:ok, [claimed]} = Kanban.claim_due_scheduled_tasks("old", now: due)

    schedule_key = Kanban.schedule_occurrence_key(claimed)

    assert {:ok, existing} =
             IexCode.Runs.RunDispatcher.enqueue(
               %{
                 project_id: context.project.id,
                 session_id: context.session.id,
                 objective: claimed.title,
                 kind: "coding_swarm",
                 mode: "swarm",
                 priority: "normal",
                 metadata: %{
                   "source" => "kanban_schedule",
                   "kanban_task_id" => task.id,
                   "schedule_key" => schedule_key,
                   "scheduled_for" => DateTime.to_iso8601(due)
                 }
               },
               self()
             )

    stale_time = DateTime.add(due, -600, :second)

    from(t in IexCode.Kanban.Task, where: t.id == ^task.id)
    |> Repo.update_all(set: [claimed_at: stale_time])

    assert 1 == Kanban.recover_stale_schedule_claims(now: due, stale_after: 300_000)

    assert %{recovered: 0, claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "new")

    assert [run] = Runs.list_runs(project_id: context.project.id)
    assert run.id == existing.id
    assert run.request_key == nil
    assert Kanban.get_task!(task.id).worker_pid == "run:#{existing.id}"
  end

  test "malformed run metadata cannot poison occurrence lookup", context do
    due = ~U[2026-08-23 10:00:00Z]
    {:ok, task} = scheduled_task(context, %{title: "Reject poison", scheduled_at: due})
    schedule_key = Kanban.schedule_occurrence_key(task)

    assert {:ok, poison} =
             Runs.create_run(%{
               project_id: context.project.id,
               session_id: context.session.id,
               objective: "Not a scheduler run",
               kind: "analysis",
               mode: "workflow",
               metadata: %{
                 "source" => "manual",
                 "kanban_task_id" => task.id,
                 "schedule_key" => schedule_key,
                 "scheduled_for" => DateTime.to_iso8601(due)
               }
             })

    assert %{claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "not-poisoned")

    runs = Runs.list_runs(project_id: context.project.id)
    assert length(runs) == 2
    scheduled = Enum.find(runs, &(&1.id != poison.id))
    assert scheduled.request_key == schedule_key
    assert Kanban.get_task!(task.id).worker_pid == "run:#{scheduled.id}"
  end

  test "old and recovered claims racing enqueue converge on one request-key run", context do
    due = ~U[2026-08-23 10:00:00Z]
    {:ok, task} = scheduled_task(context, %{title: "Exactly once", scheduled_at: due})
    {:ok, [old_claim]} = Kanban.claim_due_scheduled_tasks("old", now: due)

    from(t in IexCode.Kanban.Task, where: t.id == ^task.id)
    |> Repo.update_all(set: [claimed_at: DateTime.add(due, -600, :second)])

    assert 1 == Kanban.recover_stale_schedule_claims(now: due, stale_after: 300_000)
    {:ok, [recovered_claim]} = Kanban.claim_due_scheduled_tasks("new", now: due)

    results =
      [old_claim, recovered_claim]
      |> Task.async_stream(
        &Scheduler.dispatch_claimed_task(&1, due, self()),
        ordered: false,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _run}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :schedule_claim_lost})) == 1

    assert [run] = Runs.list_runs(project_id: context.project.id)
    assert run.request_key == Kanban.schedule_occurrence_key(task)
    assert Kanban.get_task!(task.id).worker_pid == "run:#{run.id}"
  end

  test "blocks an invalid recurring expression without creating a run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Bad recurrence",
        scheduled_at: due,
        cron_expression: "@daily"
      })

    assert %{claimed: 1, enqueued: 0, errors: [:invalid_cron]} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "invalid")

    assert Runs.list_runs(project_id: context.project.id) == []
    assert Kanban.get_task!(task.id).status == "blocked"
  end

  test "creates and durably attaches a session when a scheduled task has none", context do
    due = ~U[2026-08-23 10:00:00Z]

    assert {:ok, task} =
             Kanban.create_task(%{
               project_id: context.project.id,
               title: "Unattached schedule",
               status: "scheduled",
               scheduled_at: due
             })

    assert task.session_id == nil

    assert %{claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "session-maker")

    updated = Kanban.get_task!(task.id)
    assert is_binary(updated.session_id)
    assert Sessions.get_session!(updated.session_id).project_id == context.project.id
    assert [run] = Runs.list_runs(project_id: context.project.id)
    assert run.session_id == updated.session_id
  end

  test "attaching a scheduler session enforces same-project scope", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, _task} =
      Kanban.create_task(%{
        project_id: context.project.id,
        title: "Attach safely",
        status: "scheduled",
        scheduled_at: due
      })

    {:ok, [claimed]} = Kanban.claim_due_scheduled_tasks("attach", now: due)
    assert {:ok, attached} = Kanban.attach_schedule_session(claimed, context.session.id)
    assert attached.session_id == context.session.id

    foreign_root = Path.join(System.tmp_dir!(), "foreign-attach-#{Ecto.UUID.generate()}")
    File.mkdir_p!(foreign_root)
    on_exit(fn -> File.rm_rf!(foreign_root) end)

    {:ok, foreign_project} =
      Projects.create_project(%{name: "Foreign attach", root_path: foreign_root})

    {:ok, foreign_session} =
      Sessions.create_session(%{project_id: foreign_project.id, title: "Foreign"})

    assert {:error, :schedule_session_project_mismatch} =
             Kanban.attach_schedule_session(claimed, foreign_session.id)
  end

  test "losing the claim while attaching removes the just-created scheduler session", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, stale_task} =
      Kanban.create_task(%{
        project_id: context.project.id,
        title: "Lost before attach",
        status: "scheduled",
        scheduled_at: due
      })

    session_count = length(Sessions.list_sessions_for_project(context.project.id))

    lost_claim = %{stale_task | status: "running", worker_pid: "schedule:lost-owner"}
    assert {:error, :schedule_claim_lost} = Scheduler.resolve_schedule_session(lost_claim)

    assert length(Sessions.list_sessions_for_project(context.project.id)) == session_count
    assert Kanban.get_task!(stale_task.id).session_id == nil
  end

  test "mismatched existing sessions block instead of creating orphan-session loops", context do
    foreign_root = Path.join(System.tmp_dir!(), "foreign-schedule-#{Ecto.UUID.generate()}")
    File.mkdir_p!(foreign_root)
    on_exit(fn -> File.rm_rf!(foreign_root) end)

    {:ok, foreign_project} =
      Projects.create_project(%{name: "Foreign schedule", root_path: foreign_root})

    {:ok, foreign_session} =
      Sessions.create_session(%{project_id: foreign_project.id, title: "Foreign"})

    corrupt_legacy_task = %IexCode.Kanban.Task{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      session_id: foreign_session.id,
      title: "Legacy invalid scope"
    }

    assert {:error, :schedule_session_project_mismatch} =
             Scheduler.resolve_schedule_session(corrupt_legacy_task)

    assert Runs.list_runs(project_id: context.project.id) == []
  end

  test "schedule acknowledgement rejects a run from another occurrence", context do
    due = ~U[2026-08-23 10:00:00Z]
    {:ok, task} = scheduled_task(context, %{title: "Bind receipt", scheduled_at: due})
    {:ok, [claimed]} = Kanban.claim_due_scheduled_tasks("receipt", now: due)

    assert {:ok, unrelated} =
             Runs.create_run(%{
               project_id: context.project.id,
               session_id: context.session.id,
               request_key: "unrelated-occurrence",
               objective: "Unrelated",
               kind: "analysis",
               mode: "workflow",
               metadata: %{
                 "kanban_task_id" => task.id,
                 "schedule_key" => "unrelated-occurrence",
                 "scheduled_for" => DateTime.to_iso8601(due)
               }
             })

    assert {:error, :schedule_run_mismatch} =
             Kanban.mark_schedule_dispatched(claimed, unrelated.id, nil)

    still_claimed = Kanban.get_task!(task.id)
    assert still_claimed.worker_pid == claimed.worker_pid
    assert still_claimed.status == "running"
  end

  test "stale recovery never releases ordinary agent task claims", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      Kanban.create_task(%{
        project_id: context.project.id,
        session_id: context.session.id,
        title: "Agent-owned work",
        status: "ready"
      })

    assert {:ok, claimed} = Kanban.claim_task(task, "coder")

    from(t in IexCode.Kanban.Task, where: t.id == ^claimed.id)
    |> Repo.update_all(set: [claimed_at: DateTime.add(due, -600, :second)])

    assert 0 == Kanban.recover_stale_schedule_claims(now: due, stale_after: 300_000)
    assert Kanban.get_task!(task.id).status == "running"
  end

  test "delayed old occurrence cannot release or fail a newer claim owned by the same worker",
       context do
    due = ~U[2026-08-23 10:00:00Z]
    next_due = ~U[2026-08-24 10:00:00Z]
    {:ok, task} = scheduled_task(context, %{title: "Fence callbacks", scheduled_at: due})
    {:ok, [old_claim]} = Kanban.claim_due_scheduled_tasks("same-worker", now: due)

    from(t in IexCode.Kanban.Task, where: t.id == ^task.id)
    |> Repo.update_all(
      set: [status: "scheduled", scheduled_at: next_due, worker_pid: nil, claimed_at: nil]
    )

    {:ok, [new_claim]} = Kanban.claim_due_scheduled_tasks("same-worker", now: next_due)
    assert old_claim.worker_pid == new_claim.worker_pid

    assert {:error, :schedule_claim_lost} = Kanban.release_schedule_claim(old_claim, :late_error)
    assert {:error, :schedule_claim_lost} = Kanban.fail_schedule_claim(old_claim, :late_failure)

    persisted = Kanban.get_task!(task.id)
    assert persisted.status == "running"
    assert persisted.worker_pid == new_claim.worker_pid
    assert persisted.scheduled_at == next_due
    assert persisted.claimed_at == new_claim.claimed_at
  end

  defp scheduled_task(context, attrs) do
    Kanban.create_task(
      Map.merge(
        %{
          project_id: context.project.id,
          session_id: context.session.id,
          status: "scheduled",
          priority: "medium"
        },
        attrs
      )
    )
  end
end
