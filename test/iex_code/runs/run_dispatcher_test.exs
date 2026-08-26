defmodule IexCode.Runs.RunDispatcherTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Runs, Sessions, WorkspaceLocks}
  alias IexCode.Engine.{AgentRegistry, FleetManager, FleetSupervisor}
  alias IexCode.Runs.{DagScheduler, ExecutionEngine, Run, RunDispatcher, RunStep}

  @dispatcher IexCode.RunDispatcherUnderTest

  setup do
    Process.register(self(), IexCode.RunDispatcherTestReceiver)

    {:ok, project} =
      Projects.create_project(%{
        name: "dispatcher-#{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Durable run dispatcher"})

    :ok = Runs.subscribe_session(session.id)
    :ok = IexCode.Kanban.subscribe(project.id)

    start_supervised!({RunDispatcher, dispatcher_options()})

    on_exit(fn ->
      if Process.whereis(IexCode.RunDispatcherTestReceiver) == self() do
        Process.unregister(IexCode.RunDispatcherTestReceiver)
      end
    end)

    %{project: project, session: session}
  end

  test "persists typed runs, executes durable prepare/execute steps, and completes", context do
    {:ok, queued} = enqueue(context, "complete run")
    assert queued.status == "queued"

    assert_receive {:test_run_started, run_id, worker_pid}, 2_000
    assert run_id == queued.id
    assert is_pid(worker_pid)

    running = Runs.get_run!(run_id)
    assert running.status == "running"
    assert running.attempt == 1
    assert running.lease_owner == "dispatcher-test"

    assert [prepare, execute] = Runs.list_steps(running)
    assert {prepare.key, prepare.status} == {"prepare", "completed"}
    assert {execute.key, execute.status} == {"execute", "running"}
    {:ok, task} = linked_task(context, running)

    send(worker_pid, {:finish, run_id, {:ok, %{summary: "done"}}})

    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
    assert Runs.get_run!(run_id).progress == 100
    assert Enum.at(Runs.list_steps(run_id), 1).status == "completed"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "done"
    assert projected.worker_pid == nil
    assert projected.claimed_at == nil
    assert projected.latest_summary =~ "completed successfully"
    assert :noop = IexCode.Kanban.project_run_terminal(run_id, "completed")
    assert IexCode.Kanban.get_task!(task.id) == projected
  end

  test "durable drafts remain unclaimed until explicitly started", context do
    assert {:ok, draft} = RunDispatcher.create_draft(run_attrs(context, "draft run"))
    assert draft.status == "draft"
    assert draft.attempt == 0
    refute_receive {:test_run_started, _, _}, 100

    assert {:ok, queued} = RunDispatcher.resume(draft, @dispatcher)
    assert queued.status == "queued"
    assert_receive {:test_run_started, run_id, worker_pid}, 2_000
    assert run_id == draft.id

    send(worker_pid, {:finish, run_id, {:ok, :done}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000

    assert {:ok, cancellable} = RunDispatcher.create_draft(run_attrs(context, "cancel draft"))
    assert {:ok, cancelled} = RunDispatcher.cancel(cancellable, @dispatcher)
    assert cancelled.status == "cancelled"
    assert cancelled.attempt == 0
    assert Enum.all?(Runs.list_steps(cancelled), &(&1.status == "cancelled"))
    cancelled_id = cancelled.id
    refute_receive {:test_run_started, ^cancelled_id, _}, 100
  end

  test "periodically reconciles bounded research results and provider effects" do
    name = Module.concat(__MODULE__, PeriodicReconciliation)

    opts =
      dispatcher_options()
      |> Keyword.put(:name, name)
      |> Keyword.put(:worker_id, "reconciliation-test")
      |> Keyword.put(:research_finalizer, IexCode.RunDispatcherReconciliationStub)
      |> Keyword.put(:provider_effect, IexCode.RunDispatcherReconciliationStub)
      |> Keyword.put(:research_reconcile_interval, 60_000)

    start_supervised!(%{id: name, start: {RunDispatcher, :start_link, [opts]}})

    assert_receive {:provider_effect_reconcile, [limit: 100]}
    assert_receive {:research_result_reconcile, [limit: 100]}

    send(name, :reconcile_research_results)

    assert_receive {:provider_effect_reconcile, [limit: 100]}
    assert_receive {:research_result_reconcile, [limit: 100]}
    assert Process.whereis(name)
  end

  test "enforces global capacity and one active run per project", context do
    {:ok, first} = enqueue(context, "first project run")
    assert_receive {:test_run_started, first_id, first_pid}, 2_000
    assert first_id == first.id

    {:ok, second} = enqueue(context, "second same-project run")
    second_run_id = second.id
    refute_receive {:test_run_started, ^second_run_id, _pid}, 100

    {:ok, project_two} =
      Projects.create_project(%{
        name: "dispatcher-second-#{System.unique_integer([:positive])}",
        root_path: Path.join(File.cwd!(), "tmp")
      })

    {:ok, session_two} =
      Sessions.create_session(%{project_id: project_two.id, title: "Second project"})

    {:ok, third} = enqueue(%{project: project_two, session: session_two}, "parallel project run")
    assert_receive {:test_run_started, third_id, third_pid}, 2_000
    assert third_id == third.id

    stats = RunDispatcher.get_stats(@dispatcher)
    assert stats.active == 2
    assert stats.capacity == 0
    assert Enum.sort(stats.projects) == Enum.sort([context.project.id, project_two.id])

    send(first_pid, {:finish, first.id, {:ok, :done}})
    assert_receive {:test_run_started, second_id, second_pid}, 2_000
    assert second_id == second.id

    send(second_pid, {:finish, second.id, {:ok, :done}})
    send(third_pid, {:finish, third.id, {:ok, :done}})
  end

  test "pause and resume preserve the worker while cancel records intent before hard-stop",
       context do
    {:ok, run} = enqueue(context, "controlled run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert {:ok, paused} = RunDispatcher.pause(run, @dispatcher)
    assert paused.status == "paused"
    assert_receive {:test_run_paused, ^run_id}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "paused"
    assert Process.alive?(worker_pid)

    assert {:ok, steered} =
             RunDispatcher.steer(run, "Keep public APIs backwards compatible", @dispatcher)

    assert steered.id == run.id
    assert_receive {:test_run_steered, ^run_id, "Keep public APIs backwards compatible"}, 2_000

    assert {:ok, resumed} = RunDispatcher.resume(run, @dispatcher)
    assert resumed.status == "running"
    assert_receive {:test_run_resumed, ^run_id}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "running"

    assert [%{kind: "pause"}, %{kind: "steer"}, %{kind: "resume"}] =
             Runs.list_controls(run)

    {:ok, task} = linked_task(context, Runs.get_run!(run_id))

    assert {:ok, cancelled} = RunDispatcher.cancel(run, @dispatcher)
    assert cancelled.status == "cancelled"
    assert cancelled.cancellation_requested_at != nil
    assert_receive {:test_run_cancelled, ^run_id}, 2_000

    assert List.last(Runs.list_controls(run)).kind == "cancel"

    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "cancelled"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.latest_summary =~ "Cancelled by user"
  end

  test "cancelling an inactive queued run does not broadcast session rollback control", context do
    {:ok, active} = enqueue(context, "active run")
    active_id = active.id
    assert_receive {:test_run_started, ^active_id, active_worker}, 2_000

    {:ok, queued} = enqueue(context, "queued run")
    queued_id = queued.id
    refute_receive {:test_run_started, ^queued_id, _pid}, 100

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{context.session.id}:steer")
    assert {:ok, cancelled} = RunDispatcher.cancel(queued, @dispatcher)
    assert cancelled.status == "cancelled"
    assert Enum.all?(Runs.list_steps(cancelled), &(&1.status == "cancelled"))
    refute_receive {:cancel, _, _}, 100
    assert Process.alive?(active_worker)

    send(active_worker, {:finish, active_id, {:ok, :done}})
  end

  test "failed runs retry as a new durable attempt and are not auto-retried", context do
    {:ok, run} = enqueue(context, "retry run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, first_pid}, 2_000
    send(first_pid, {:finish, run.id, {:error, :first_attempt_failed}})

    assert_receive {:async_run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100

    assert {:ok, retried} = RunDispatcher.retry(run, @dispatcher)
    assert retried.status == "queued"
    assert_receive {:test_run_started, ^run_id, second_pid}, 2_000

    running = Runs.get_run!(run.id)
    assert running.attempt == 2

    assert Enum.map(Runs.list_steps(run), & &1.key) ==
             ["prepare", "execute", "prepare.2", "execute.2"]

    send(second_pid, {:finish, run.id, {:ok, :recovered}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
  end

  test "enqueue canonicalizes atom and string status overrides to queued", context do
    request_key = Ecto.UUID.generate()

    attrs =
      context
      |> run_attrs("canonical queued disposition")
      |> Map.merge(%{"status" => "running", status: "draft", request_key: request_key})

    assert {:ok, first} = RunDispatcher.enqueue(attrs, @dispatcher)
    assert first.status == "queued"
    assert first.metadata["request_initial_status"] == "queued"

    assert {:ok, duplicate} =
             attrs
             |> Map.put(:status, "cancelled")
             |> Map.put("status", "paused")
             |> RunDispatcher.enqueue(@dispatcher)

    assert duplicate.id == first.id

    assert_receive {:test_run_started, run_id, worker_pid}, 2_000
    send(worker_pid, {:finish, run_id, {:ok, :done}})
  end

  test "wall-clock exhaustion holds its lease until worker cleanup", context do
    restart_dispatcher(cancel_grace_ms: 3_000, lease_ms: 2_000, heartbeat_interval: 60_000)

    attrs = run_attrs(context, "bounded run") |> Map.put(:time_budget_ms, 500)
    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    original_expiry =
      DateTime.utc_now()
      |> DateTime.add(2, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(candidate in Run, where: candidate.id == ^run_id)
      |> Repo.update_all(set: [lease_expires_at: original_expiry])

    assert {:ok, queued} = enqueue(context, "same-project work after time budget")
    queued_id = queued.id
    ref = Process.monitor(worker_pid)
    assert_receive {:run_updated, %Run{id: ^run_id, status: "failed"}}, 2_000

    assert %Run{status: "failed", lease_owner: "dispatcher-test"} =
             failed_with_lease =
             Runs.get_run!(run_id)

    assert DateTime.compare(failed_with_lease.lease_expires_at, original_expiry) == :gt
    assert :none = Runs.claim_next_run("foreign-dispatcher")
    assert Process.alive?(worker_pid)
    refute_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 50

    Process.send_after(self(), :original_time_lease_elapsed, 2_200)
    assert_receive :original_time_lease_elapsed, 3_000
    assert Process.alive?(worker_pid)
    assert :none = Runs.claim_next_run("foreign-dispatcher")

    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 3_000
    _ = RunDispatcher.get_stats(@dispatcher)

    failed = Runs.get_run!(run_id)
    assert is_nil(failed.lease_owner)
    assert failed.error_details["reason"] == "budget_exhausted"
    assert failed.error_details["budget"] == "time"
    assert Enum.any?(Runs.list_events(run), &(&1.type == "run.budget_exhausted"))

    assert_receive {:test_run_started, ^queued_id, queued_worker}, 2_000
    send(queued_worker, {:finish, queued_id, {:ok, :done}})
  end

  test "token exhaustion holds its lease until the reporting worker exits", context do
    attrs = run_attrs(context, "provider-token bounded run") |> Map.put(:token_budget, 1)
    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    original_expiry =
      DateTime.utc_now()
      |> DateTime.add(2, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(candidate in Run, where: candidate.id == ^run_id)
      |> Repo.update_all(set: [lease_expires_at: original_expiry])

    assert {:ok, queued} = enqueue(context, "same-project work after token budget")
    queued_id = queued.id
    ref = Process.monitor(worker_pid)
    send(worker_pid, {:record_usage, run_id, %{input_tokens: 2}})

    assert_receive {
                     :test_run_usage_result,
                     ^run_id,
                     {:error,
                      {:token_budget_exhausted,
                       %Run{status: "failed", lease_owner: "dispatcher-test"}}}
                   },
                   2_000

    assert %Run{status: "failed", lease_owner: "dispatcher-test"} =
             failed_with_lease =
             Runs.get_run!(run_id)

    assert DateTime.compare(failed_with_lease.lease_expires_at, original_expiry) == :gt
    assert :none = Runs.claim_next_run("foreign-dispatcher")
    assert Process.alive?(worker_pid)

    Process.send_after(self(), :original_token_lease_elapsed, 2_200)
    assert_receive :original_token_lease_elapsed, 3_000
    assert Process.alive?(worker_pid)
    assert :none = Runs.claim_next_run("foreign-dispatcher")

    send(worker_pid, {:finish, run_id, {:error, :token_budget_exhausted}})
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)
    assert is_nil(Runs.get_run!(run_id).lease_owner)

    assert_receive {:test_run_started, ^queued_id, queued_worker}, 2_000
    send(queued_worker, {:finish, queued_id, {:ok, :done}})
  end

  test "an abnormal monitored worker exit is persisted as interrupted", context do
    {:ok, run} = enqueue(context, "crashing run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    {:ok, task} = linked_task(context, Runs.get_run!(run_id))

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000

    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000
    assert Runs.get_run!(run_id).status == "interrupted"
    assert Enum.at(Runs.list_steps(run_id), 1).status == "interrupted"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.latest_summary =~ "interrupted"
    assert projected.latest_summary =~ "killed"
    refute_receive {:test_run_started, ^run_id, _pid}, 100
  end

  test "a foreign interactive lock blocks coding execution until it is released", context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project],
        owner_id: "interactive:test",
        project_id: context.project.id,
        session_id: context.session.id,
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000
      )

    attrs =
      context
      |> run_attrs("workspace-exclusive coding")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id

    refute_receive {:test_run_started, ^run_id, _pid}, 150

    assert %Run{status: "running", attempt: 1} = Runs.get_run!(run_id)
    assert Enum.at(Runs.list_steps(run_id), 1).status == "blocked"

    assert [%{status: "waiting", owner_id: owner}] =
             Runs.list_workspace_locks(run_id: run_id, active: true)

    assert owner == "run:#{run_id}"
    assert :ok = WorkspaceLocks.release(blocker)

    assert_receive {:test_run_delegation, ^run_id, :present}, 2_000
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert Enum.at(Runs.list_steps(run_id), 1).status == "running"

    send(worker_pid, {:finish, run_id, {:ok, :done}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)

    assert [%{status: "released", capability_token_hash: "[REDACTED]"}] =
             Runs.list_workspace_locks(run_id: run_id)

    finished = Runs.get_run!(run_id)
    refute inspect(finished.metadata) =~ "capability"

    refute Enum.any?(Runs.list_events(run_id), fn event ->
             inspect(event.payload) =~ "capability"
           end)
  end

  test "cancelling a lock-waiting coding run cancels its opaque lock batch", context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project],
        owner_id: "interactive:cancel-test",
        project_id: context.project.id,
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000
      )

    attrs =
      context
      |> run_attrs("cancel while waiting")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100

    assert {:ok, %Run{status: "cancelled"}} = RunDispatcher.cancel(run_id, @dispatcher)

    assert [%{status: "cancelled"}] = Runs.list_workspace_locks(run_id: run_id)
    refute_receive {:test_run_started, ^run_id, _pid}, 100
    assert :ok = WorkspaceLocks.release(blocker)
  end

  test "daemon poll applies durable cancellation while a coding run waits for its lock",
       context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project],
        owner_id: "interactive:offline-cancel-test",
        project_id: context.project.id,
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000
      )

    attrs =
      context
      |> run_attrs("offline cancel while waiting")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100
    assert Runs.get_run!(run_id).status == "running"
    assert Map.has_key?(:sys.get_state(@dispatcher).lock_waiters, run_id)

    assert {:ok, requested} = Runs.request_cancellation(run_id, "local-cli")
    assert %DateTime{} = requested.cancellation_requested_at

    send(@dispatcher, :poll)
    _ = :sys.get_state(@dispatcher)

    assert Runs.get_run!(run_id).status == "cancelled"
    assert [%{status: "cancelled"}] = Runs.list_workspace_locks(run_id: run_id)
    refute_receive {:test_run_started, ^run_id, _pid}, 100
    assert :ok = WorkspaceLocks.release(blocker)
  end

  test "a crashed coding worker releases its workspace lock after process exit", context do
    attrs =
      context
      |> run_attrs("crashing coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)

    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)

    assert {:ok, interactive} =
             WorkspaceLocks.acquire(context.project, [:project],
               owner_id: "interactive:after-crash",
               project_id: context.project.id,
               lease_seconds: 60,
               heartbeat_interval_ms: 20_000
             )

    assert :ok = WorkspaceLocks.release(interactive)
  end

  test "expired same-lineage worker completion leaves controls and fleet for reconciliation",
       context do
    attrs =
      context
      |> run_attrs("expired coding worker completion")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    running = Runs.get_run!(run_id)

    on_exit(fn -> FleetSupervisor.stop(run_id) end)

    assert {:ok, fleet} =
             FleetSupervisor.attach(running,
               agent_count: 4,
               project_root: context.project.root_path
             )

    fleet_supervisor = AgentRegistry.whereis_fleet(run_id, :supervisor)
    fleet_pids = Enum.map(fleet, & &1.pid)

    assert {:ok, pending} =
             Runs.enqueue_control(running, "expired-worker-control", %{
               kind: "steer",
               payload: %{"guidance" => "must remain claimed"},
               requested_by: "test"
             })

    assert {:ok, claimed} = Runs.claim_control(pending, "dispatcher-test", claim_ms: 60_000)

    expired_at =
      DateTime.utc_now()
      |> DateTime.add(-1, :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(candidate in Run, where: candidate.id == ^run_id)
      |> Repo.update_all(set: [lease_expires_at: expired_at])

    worker_ref = Process.monitor(worker_pid)
    send(worker_pid, {:finish, run_id, {:ok, :stale_result}})
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 2_000

    stats = RunDispatcher.get_stats(@dispatcher)
    assert stats.active == 0

    assert %{status: "running", lease_owner: "dispatcher-test"} = Runs.get_run!(run_id)
    assert Runs.get_control(claimed.id).status == "claimed"
    assert AgentRegistry.whereis_fleet(run_id, :supervisor) == fleet_supervisor
    assert Enum.all?(fleet_pids, &Process.alive?/1)
    assert length(FleetManager.list_agents(run_id)) == 4
    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)
  end

  test "dispatcher shutdown cleans up a coding worker and its outer lock", context do
    attrs =
      context
      |> run_attrs("dispatcher shutdown coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)
    assert :ok = Runs.subscribe_workspace_locks(context.project.id)

    worker_ref = Process.monitor(worker_pid)
    stop_supervised!(RunDispatcher)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 2_000

    assert_receive {:workspace_locks_updated, locks}, 2_000
    assert Enum.any?(locks, &(&1.run_id == run_id and &1.status == "released"))
    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)
  end

  test "a coding run keeps its exclusive workspace lock while paused", context do
    attrs =
      context
      |> run_attrs("paused coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert {:ok, %Run{status: "paused"}} = RunDispatcher.pause(run_id, @dispatcher)
    assert_receive {:test_run_paused, ^run_id}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             WorkspaceLocks.acquire(context.project, [:project],
               owner_id: "interactive:while-paused",
               project_id: context.project.id,
               lease_seconds: 60,
               heartbeat_interval_ms: 20_000
             )

    assert {:ok, %Run{status: "running"}} = RunDispatcher.resume(run_id, @dispatcher)
    send(worker_pid, {:finish, run_id, {:ok, :done}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
  end

  test "cancelling an active coding worker releases only after worker cleanup", context do
    restart_dispatcher(cancel_grace_ms: 500)

    attrs =
      context
      |> run_attrs("cancel active coding")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    queued_attrs = %{attrs | objective: "same-project coding after cancellation"}
    assert {:ok, queued} = RunDispatcher.enqueue(queued_attrs, @dispatcher)
    queued_id = queued.id
    worker_ref = Process.monitor(worker_pid)

    assert {:ok, %Run{status: "cancelled", lease_owner: "dispatcher-test"}} =
             RunDispatcher.cancel(run_id, @dispatcher)

    assert %Run{status: "cancelled", lease_owner: "dispatcher-test"} =
             Runs.get_run!(run_id)

    assert :none = Runs.claim_next_run("foreign-dispatcher")
    assert Process.alive?(worker_pid)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 50

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)
    assert is_nil(Runs.get_run!(run_id).lease_owner)
    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)

    assert_receive {:test_run_started, ^queued_id, queued_worker}, 2_000
    send(queued_worker, {:finish, queued_id, {:ok, :done}})
  end

  test "near-expiry cancellation keeps same-project work fenced until worker DOWN", context do
    restart_dispatcher(cancel_grace_ms: 3_000, lease_ms: 2_000, heartbeat_interval: 60_000)

    assert {:ok, run} = enqueue(context, "near-expiry cancellation fence")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    original_expiry =
      DateTime.utc_now()
      |> DateTime.add(2, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(candidate in Run, where: candidate.id == ^run_id)
      |> Repo.update_all(set: [lease_expires_at: original_expiry])

    assert {:ok, queued} = enqueue(context, "queued behind cancelling worker")
    queued_id = queued.id
    worker_ref = Process.monitor(worker_pid)

    assert {:ok, %Run{status: "cancelled", lease_owner: "dispatcher-test"} = cancelled} =
             RunDispatcher.cancel(run_id, @dispatcher)

    assert DateTime.compare(cancelled.lease_expires_at, original_expiry) == :gt

    Process.send_after(self(), :original_lease_elapsed, 2_200)
    assert_receive :original_lease_elapsed, 3_000

    assert Process.alive?(worker_pid)
    assert :none = Runs.claim_next_run("foreign-dispatcher")
    refute_receive {:test_run_started, ^queued_id, _pid}, 50

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 3_000
    _ = RunDispatcher.get_stats(@dispatcher)
    assert is_nil(Runs.get_run!(run_id).lease_owner)

    assert_receive {:test_run_started, ^queued_id, queued_worker}, 2_000
    send(queued_worker, {:finish, queued_id, {:ok, :done}})
  end

  test "an interrupted research worker terminalizes pending descendants", context do
    attrs =
      context
      |> run_attrs("interrupted research")
      |> Map.merge(%{kind: "deep_research", mode: "research"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000

    refute Enum.any?(Runs.list_steps(run), fn step ->
             step.status in ~w(pending ready running paused waiting_approval blocked)
           end)
  end

  test "startup supersedes controls claimed by the previous dispatcher", context do
    stop_supervised!(RunDispatcher)
    {:ok, run} = create_run(context, "claimed before restart")
    {:ok, pending} = Runs.enqueue_control(run, "restart:steer", %{kind: "steer"})
    assert {:ok, claimed} = Runs.claim_control(pending, "dispatcher-test")

    start_supervised!({RunDispatcher, dispatcher_options()})

    superseded = Runs.get_control(claimed.id)
    assert superseded.status == "superseded"
    assert superseded.result == %{"reason" => "dispatcher_restarted"}
  end

  test "rejects untyped executable payloads before persistence", context do
    attrs = run_attrs(context, "invalid run") |> Map.delete(:kind)
    assert {:error, :invalid_typed_run} = RunDispatcher.enqueue(attrs, @dispatcher)
    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "dag enqueue persists the explicit immutable engine manifest", context do
    manifest = dag_manifest()

    attrs =
      context
      |> run_attrs("reserved DAG")
      |> Map.put(:mode, "workflow")
      |> Map.put(:status, "draft")
      |> Map.put("status", "running")

    assert "dag_v1" in ExecutionEngine.available_ids()

    assert {:ok, %Run{execution_engine: "dag_v1", status: "queued"}} =
             RunDispatcher.enqueue_dag(attrs, manifest, @dispatcher)
  end

  test "available dag runs fan out, pause, resume and finalize without legacy shell steps",
       context do
    attrs = run_attrs(context, "dispatch DAG") |> Map.put(:mode, "workflow")
    assert {:ok, run} = RunDispatcher.enqueue_dag(attrs, dag_manifest(), @dispatcher)
    assert_receive {:async_run_started, %Run{id: run_id}, runner_pid}, 2_000
    assert run_id == run.id

    first = assert_dag_step_started()
    second = assert_dag_step_started()
    refute first.key == second.key

    assert {:error, :dag_steering_unsupported} =
             RunDispatcher.steer(run, "unsupported guidance", @dispatcher)

    assert Runs.list_controls(run, kind: "steer") == []
    assert {:ok, paused} = RunDispatcher.pause(run, @dispatcher)
    assert paused.status == "paused"
    assert Enum.all?(DagScheduler.list_attempts(run), &(&1.status == "paused"))

    send(first.pid, :release)
    send(second.pid, :release)
    refute_receive {:dag_step_started, "join", _pid}, 50
    assert Process.alive?(runner_pid)

    assert {:ok, resumed} = RunDispatcher.resume(run, @dispatcher)
    assert resumed.status == "running"
    join = assert_dag_step_started()
    assert join.key == "join"
    send(join.pid, :release)

    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
    assert Enum.all?(Runs.list_steps(run), &(&1.status == "completed"))
    refute Enum.any?(Runs.list_steps(run), &(&1.kind in ["prepare", "execute"]))
    assert Runs.list_workspace_locks(project_id: context.project.id, status: "held") == []
  end

  test "available dag cancellation and abnormal runner exit terminalize child attempts",
       context do
    attrs = run_attrs(context, "cancel DAG") |> Map.put(:mode, "workflow")

    assert {:ok, cancel_run} =
             RunDispatcher.enqueue_dag(attrs, [hd(dag_manifest())], @dispatcher)

    assert_receive {:async_run_started, %Run{id: cancel_id}, cancel_runner}, 2_000
    assert cancel_id == cancel_run.id
    started = assert_dag_step_started()
    step_ref = Process.monitor(started.pid)
    runner_ref = Process.monitor(cancel_runner)
    assert {:ok, %Run{status: "cancelled"}} = RunDispatcher.cancel(cancel_run, @dispatcher)
    assert_receive {:DOWN, ^step_ref, :process, _, _}, 2_000
    assert_receive {:DOWN, ^runner_ref, :process, ^cancel_runner, _}, 2_000
    assert Runs.get_run!(cancel_id).status == "cancelled"
    refute Enum.any?(DagScheduler.list_attempts(cancel_run), &(&1.status == "running"))

    crash_root =
      Path.join(System.tmp_dir!(), "dag-dispatch-crash-#{System.unique_integer([:positive])}")

    File.mkdir_p!(crash_root)
    on_exit(fn -> File.rm_rf(crash_root) end)

    {:ok, other_project} =
      Projects.create_project(%{
        name: "dag-crash-#{System.unique_integer([:positive])}",
        root_path: crash_root
      })

    {:ok, other_session} =
      Sessions.create_session(%{project_id: other_project.id, title: "DAG crash"})

    :ok = Runs.subscribe_session(other_session.id)

    crash_context = %{project: other_project, session: other_session}
    crash_attrs = run_attrs(crash_context, "crash DAG") |> Map.put(:mode, "workflow")
    stop_supervised!(RunDispatcher)

    start_supervised!(
      {RunDispatcher,
       Keyword.put(dispatcher_options(), :dag_runner, IexCode.RunDispatcherTestDagRunner)}
    )

    assert {:ok, crash_run} =
             RunDispatcher.enqueue_dag(crash_attrs, [hd(dag_manifest())], @dispatcher)

    assert_receive {:async_run_started, %Run{id: crash_id}, crash_runner}, 2_000
    assert crash_id == crash_run.id
    _started = assert_dag_step_started()
    ref = Process.monitor(crash_runner)
    Process.exit(crash_runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^crash_runner, :killed}, 2_000
    assert_receive {:async_run_updated, %Run{id: ^crash_id, status: "interrupted"}}, 2_000
    refute Enum.any?(DagScheduler.list_attempts(crash_run), &(&1.status == "running"))
  end

  test "claimed dag manifest drift fails preflight before any handler starts", context do
    stop_supervised!(RunDispatcher)
    attrs = run_attrs(context, "corrupt DAG") |> Map.put(:mode, "workflow")
    assert {:ok, run} = RunDispatcher.enqueue_dag(attrs, dag_manifest(), self())
    assert_receive {:"$gen_cast", :dispatch}

    {1, _} =
      from(step in RunStep, where: step.run_id == ^run.id and step.key == "left")
      |> Repo.update_all(set: [title: "tampered title"])

    start_supervised!({RunDispatcher, dispatcher_options()})
    refute_receive {:dag_step_started, _, _}, 100
    assert_receive {:async_run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    assert Runs.get_run!(run.id).error_details["reason"] == "dag_manifest_drift"
  end

  test "malformed forged dag fails without head-of-line blocking valid legacy work", context do
    stop_supervised!(RunDispatcher)

    {:ok, forged} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "forged empty DAG",
        kind: "analysis",
        mode: "workflow",
        priority: "critical",
        execution_engine: "dag_v1",
        manifest_hash: String.duplicate("0", 64)
      })
      |> Repo.insert()

    legacy_attrs = run_attrs(context, "valid work after forged DAG") |> Map.put(:priority, "low")

    assert {:ok, legacy} =
             Runs.create_run_with_steps(legacy_attrs, [
               %{
                 key: "prepare",
                 kind: "prepare",
                 title: "Validate durable run inputs",
                 status: "ready"
               },
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute analysis",
                 depends_on: ["prepare"]
               }
             ])

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert_receive {:async_run_updated, %Run{id: forged_id, status: "failed"}}, 2_000
    assert forged_id == forged.id
    assert_receive {:test_run_started, legacy_id, legacy_worker}, 2_000
    assert legacy_id == legacy.id
    send(legacy_worker, {:finish, legacy.id, {:ok, :done}})
  end

  test "dispatcher restart reconciles expired dag attempts under an orphaned parent", context do
    attrs = run_attrs(context, "orphan DAG") |> Map.put(:mode, "workflow")
    assert {:ok, run} = RunDispatcher.enqueue_dag(attrs, [hd(dag_manifest())], @dispatcher)
    assert_receive {:async_run_started, %Run{id: run_id}, _runner}, 2_000
    assert run_id == run.id
    started = assert_dag_step_started()
    ref = Process.monitor(started.pid)
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    from(candidate in Run, where: candidate.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: past])

    from(attempt in IexCode.Runs.RunStepAttempt, where: attempt.run_id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: past])

    stop_supervised!(RunDispatcher)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    start_supervised!({RunDispatcher, dispatcher_options()})

    assert Runs.get_run!(run.id).status == "interrupted"

    refute Enum.any?(
             DagScheduler.list_attempts(run),
             &(&1.status in ["running", "paused"])
           )

    refute Enum.any?(Runs.list_steps(run), &(&1.status in ["running", "paused", "ready"]))
  end

  test "claimed manifests are revalidated before legacy preparation or execution", context do
    stop_supervised!(RunDispatcher)

    assert {:ok, run} =
             Runs.create_run_with_steps(run_attrs(context, "corrupt persisted manifest"), [
               %{
                 key: "prepare",
                 kind: "prepare",
                 title: "Validate durable run inputs",
                 status: "ready"
               },
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute analysis",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    {1, _} =
      from(step in RunStep, where: step.run_id == ^run.id and step.key == "execute")
      |> Repo.update_all(set: [kind: ""])

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert_receive {:async_run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100

    failed = Runs.get_run!(run.id)
    assert failed.error_details["reason"] =~ "invalid_execution_manifest"
    assert is_nil(failed.lease_owner)
  end

  test "startup reconciliation interrupts expired work and never executes it", context do
    stop_supervised!(RunDispatcher)

    {:ok, run} = create_run(context, "orphaned run")
    run_id = run.id
    :ok = create_steps(run)
    assert {:ok, claimed} = Runs.claim_next_run("dead-worker", lease_ms: 30_000)
    assert claimed.id == run.id
    assert {:ok, [fleet_agent]} = Runs.create_run_agents(claimed, [%{key: "planner"}])
    assert {:ok, fleet_agent} = Runs.claim_run_agent(fleet_agent, "dead-fleet", 60_000)

    [prepare, _execute] = Runs.list_steps(run)

    assert {:ok, _} =
             Runs.transition_step_worker(prepare, "running", %{},
               lease_owner: "dead-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation
             )

    {:ok, task} = linked_task(context, claimed)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    from(r in Run, where: r.id == ^run_id)
    |> Repo.update_all(set: [lease_expires_at: past])

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert Runs.get_run!(run.id).status == "interrupted"
    assert hd(Runs.list_steps(run)).status == "interrupted"
    assert Runs.get_run_agent(fleet_agent.id).status == "interrupted"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    refute_receive {:test_run_started, ^run_id, _pid}, 100
  end

  test "prepare failure blocks a linked one-off task", context do
    stop_supervised!(RunDispatcher)

    missing_root =
      Path.join(System.tmp_dir!(), "missing-dispatch-root-#{System.unique_integer([:positive])}")

    {:ok, project} = Projects.update_project(context.project, %{root_path: missing_root})
    failed_context = %{context | project: project}

    assert {:ok, run} =
             RunDispatcher.enqueue(run_attrs(failed_context, "invalid workspace"), self())

    assert_receive {:"$gen_cast", :dispatch}
    {:ok, task} = linked_task(failed_context, run)

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert_receive {:run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    assert_receive {:task_updated, %{id: task_id, status: "blocked"}}, 2_000
    assert task_id == task.id
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.claimed_at == nil
    assert projected.latest_summary =~ "project_root_not_found"
  end

  test "recurring rows and stale run links are never consumed", context do
    run_id = Ecto.UUID.generate()
    owner = "run:#{run_id}"

    {:ok, recurring} =
      IexCode.Kanban.create_task(%{
        project_id: context.project.id,
        session_id: context.session.id,
        title: "Next recurring occurrence",
        status: "scheduled",
        cron_expression: "0 9 * * 1-5",
        scheduled_at: DateTime.utc_now(),
        worker_pid: nil,
        latest_summary: "next occurrence scheduled"
      })

    {:ok, moved} = linked_task(context, %{id: run_id})
    {:ok, moved} = IexCode.Kanban.update_task(moved, %{status: "review"})

    assert :noop = IexCode.Kanban.project_run_terminal(run_id, "completed")
    assert IexCode.Kanban.get_task!(recurring.id).status == "scheduled"
    assert IexCode.Kanban.get_task!(recurring.id).latest_summary == "next occurrence scheduled"
    assert IexCode.Kanban.get_task!(moved.id).status == "review"
    assert IexCode.Kanban.get_task!(moved.id).worker_pid == owner
  end

  defp enqueue(context, objective) do
    RunDispatcher.enqueue(run_attrs(context, objective), @dispatcher)
  end

  defp create_run(context, objective), do: Runs.create_run(run_attrs(context, objective))

  defp run_attrs(context, objective) do
    %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: objective,
      kind: "analysis",
      mode: "single",
      max_attempts: 3
    }
  end

  defp create_steps(run) do
    with {:ok, _} <-
           Runs.create_step(run, %{
             key: "prepare",
             kind: "prepare",
             title: "Validate durable run inputs",
             status: "ready"
           }),
         {:ok, _} <-
           Runs.create_step(run, %{
             key: "execute",
             kind: "execute",
             title: "Execute analysis",
             status: "pending",
             position: 1,
             depends_on: ["prepare"]
           }) do
      :ok
    end
  end

  defp linked_task(context, run) do
    IexCode.Kanban.create_task(%{
      project_id: context.project.id,
      session_id: context.session.id,
      title: "Linked one-off run",
      status: "running",
      worker_pid: "run:#{run.id}",
      claimed_at: DateTime.utc_now(),
      latest_summary: "run active"
    })
  end

  defp dispatcher_options do
    [
      name: @dispatcher,
      worker_id: "dispatcher-test",
      executor: IexCode.RunDispatcherTestExecutor,
      max_concurrency: 2,
      poll_interval: 60_000,
      heartbeat_interval: 60_000,
      lease_ms: 120_000,
      cancel_grace_ms: 20,
      workspace_lock_retry_interval: 20,
      workspace_lock_lease_seconds: 60,
      dag_max_concurrency: 2,
      dag_runner_opts: [
        poll_ms: 10,
        heartbeat_ms: 10,
        internal_step_executor: &dag_test_executor/2
      ]
    ]
  end

  defp restart_dispatcher(overrides) do
    stop_supervised!(RunDispatcher)

    options =
      Enum.reduce(overrides, dispatcher_options(), fn {key, value}, options ->
        Keyword.put(options, key, value)
      end)

    start_supervised!({RunDispatcher, options})
  end

  defp dag_manifest do
    [
      %{
        key: "left",
        kind: "project_inventory",
        title: "Left root",
        params: %{},
        depends_on: [],
        max_attempts: 1
      },
      %{
        key: "right",
        kind: "project_inventory",
        title: "Right root",
        params: %{},
        depends_on: [],
        max_attempts: 1
      },
      %{
        key: "join",
        kind: "aggregate",
        title: "Join roots",
        params: %{},
        depends_on: ["left", "right"],
        max_attempts: 1
      }
    ]
  end

  defp dag_test_executor(claim, context) do
    receiver = Process.whereis(IexCode.RunDispatcherTestReceiver)
    send(receiver, {:dag_step_started, claim.step.key, self()})

    receive do
      :release ->
        with {:ok, _attempt} <- context.checkpoint_callback.(%{"released" => true}, 50) do
          {:ok, %{"key" => claim.step.key}}
        end
    end
  end

  defp assert_dag_step_started do
    assert_receive {:dag_step_started, key, pid}, 2_000
    %{key: key, pid: pid}
  end
end
