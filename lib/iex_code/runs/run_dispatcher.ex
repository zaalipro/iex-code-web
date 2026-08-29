defmodule IexCode.Runs.RunDispatcher do
  @moduledoc """
  Supervised dispatcher for durable asynchronous coding runs.

  Runs are claimed atomically through `IexCode.Runs`, are bounded by a global
  concurrency limit, and are exclusive per project. Workers are monitored and
  all observable state is persisted before PubSub notifications are emitted.
  A dispatcher restart marks abandoned work interrupted; it never replays a
  partially executed coding run automatically.
  """

  use GenServer

  require Logger

  alias IexCode.{Kanban, Projects, Runs, Sessions, WorkspaceLocks}
  alias IexCode.Engine.{AgentRegistry, FleetManager}
  alias IexCode.Research.{DagAdapter, DagFinalizer, Launch, LevelPolicy, ProviderEffect, Results}
  alias IexCode.Runs.{DagRunner, DagScheduler, Run}
  alias IexCode.Runs.ExecutionEngine

  @default_poll_interval 1_000
  @default_heartbeat_interval 5_000
  @default_lease_ms 15_000
  @default_cancel_grace_ms 1_500
  @max_cancel_grace_ms 60_000
  @terminal_lease_margin_ms 1_000
  @max_terminal_lease_ms 300_000
  @default_workspace_lock_retry_interval 1_000
  @default_workspace_lock_lease_seconds 60
  @default_research_reconcile_interval 60_000
  @research_reconcile_limit 100
  @max_finalization_retries 8
  @finalization_retry_base_ms 50
  @finalization_retry_max_ms 5_000

  defstruct [
    :name,
    :worker_id,
    :executor,
    :task_supervisor,
    :max_concurrency,
    :poll_interval,
    :heartbeat_interval,
    :lease_ms,
    :cancel_grace_ms,
    :workspace_lock_retry_interval,
    :workspace_lock_lease_seconds,
    :execution_engines,
    :dag_runner,
    :dag_runner_opts,
    :dag_max_concurrency,
    :research_finalizer,
    :provider_effect,
    :research_reconcile_interval,
    workers: %{},
    lock_waiters: %{},
    run_refs: %{},
    cancelling: MapSet.new(),
    finalization_retries: %{}
  ]

  @type server :: GenServer.server()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Persists and schedules a typed run."
  def enqueue(attrs, server \\ __MODULE__) when is_map(attrs) do
    with {:ok, run} <- persist(attrs) do
      dispatch(server)
      {:ok, run}
    end
  end

  @doc "Persists queued work without waking a process-local dispatcher."
  def persist(attrs) when is_map(attrs) do
    attrs = force_queued(attrs)
    steps = initial_steps(attrs)

    with :ok <- validate_typed_attrs(attrs),
         :ok <- ExecutionEngine.validate_manifest(attrs, steps),
         {:ok, run} <- Runs.create_run_with_steps(attrs, steps) do
      {:ok, run}
    end
  end

  def persist(_attrs), do: {:error, :invalid_run}

  @doc "Persists a durable draft without making it claimable."
  def create_draft(attrs) when is_map(attrs) do
    attrs = attrs |> Map.delete("status") |> Map.put(:status, "draft")
    steps = initial_steps(attrs)

    with :ok <- validate_typed_attrs(attrs),
         :ok <- ExecutionEngine.validate_manifest(attrs, steps),
         {:ok, run} <- Runs.create_run_with_steps(attrs, steps) do
      {:ok, run}
    end
  end

  def create_draft(_attrs), do: {:error, :invalid_run_draft}

  @doc "Persists an immutable DAG run when the dag_v1 engine is available."
  def enqueue_dag(attrs, steps, server \\ __MODULE__)

  def enqueue_dag(attrs, steps, server) when is_map(attrs) and is_list(steps) do
    with {:ok, run} <- persist_dag(attrs, steps) do
      dispatch(server)
      {:ok, run}
    end
  end

  def enqueue_dag(_attrs, _steps, _server), do: {:error, :invalid_dag_run}

  @doc "Persists a queued typed DAG without waking a process-local dispatcher."
  def persist_dag(attrs, steps) when is_map(attrs) and is_list(steps) do
    attrs =
      attrs
      |> force_queued()
      |> Map.delete("execution_engine")
      |> Map.put(:execution_engine, "dag_v1")

    with :ok <- execution_engine_available("dag_v1"),
         :ok <- validate_typed_attrs(attrs),
         :ok <- ExecutionEngine.validate_manifest(attrs, steps),
         {:ok, run} <- Runs.create_run_with_steps(attrs, steps) do
      {:ok, run}
    else
      false -> {:error, {:execution_engine_unavailable, "dag_v1"}}
      {:error, _reason} = error -> error
    end
  end

  def persist_dag(_attrs, _steps), do: {:error, :invalid_dag_run}

  @doc "Builds, persists, and schedules an exact finite deep-research DAG."
  def enqueue_research(attrs, research, server \\ __MODULE__)

  def enqueue_research(attrs, research, server) when is_map(attrs) and is_map(research) do
    with {:ok, run} <- persist_research(attrs, research) do
      dispatch(server)
      {:ok, run}
    end
  end

  def enqueue_research(_attrs, _research, _server), do: {:error, :invalid_research_run}

  @doc "Persists queued exact research without waking a process-local dispatcher."
  def persist_research(attrs, research) when is_map(attrs) and is_map(research) do
    objective = Map.get(attrs, :objective) || Map.get(attrs, "objective")
    session_id = Map.get(attrs, :session_id) || Map.get(attrs, "session_id")
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}

    attachment_ids =
      Map.get(metadata, "research_result_ids", Map.get(metadata, :research_result_ids, []))

    with {:ok, launch} <- Launch.normalize_request(research),
         :ok <- Launch.validate_new_snapshot_ref(launch.provider_snapshot_ref),
         {:ok, policy} <- LevelPolicy.fetch(launch.level),
         {:ok, attachment_refs} <- Results.attachment_refs(attachment_ids, session_id),
         {:ok, steps} <-
           DagAdapter.build(objective,
             ranked_providers: launch.ranked_providers,
             grounded_providers: launch.grounded_providers,
             level: launch.level,
             max_sources: launch.max_sources,
             fetch_parallelism: launch.fetch_parallelism,
             require_conflict_audit: launch.require_conflict_audit,
             provider_snapshot_ref: launch.provider_snapshot_ref,
             attachment_refs: attachment_refs
           ),
         requirements <- Launch.manifest_budget_requirements(steps),
         :ok <- Launch.validate_explicit_budgets(attrs, requirements) do
      attrs =
        research_run_attrs(
          attrs,
          policy,
          launch.ranked_providers,
          launch.grounded_providers,
          launch.max_sources,
          launch.fetch_parallelism,
          launch.require_conflict_audit,
          launch.provider_snapshot_ref,
          attachment_refs,
          requirements
        )

      persist_dag(attrs, steps)
    end
  end

  def persist_research(_attrs, _research), do: {:error, :invalid_research_run}

  @doc "Wakes the dispatcher without blocking the caller."
  def dispatch(server \\ __MODULE__) do
    GenServer.cast(server, :dispatch)
  end

  @doc "Cancels a queued, paused, or active run."
  def cancel(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:cancel, run_id(run_or_id)}, 30_000)
  end

  @doc "Requeues an eligible terminal/interrupted run as a new attempt."
  def retry(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:retry, run_id(run_or_id)}, 30_000)
  end

  @doc "Requeues a run durably without waking or starting a process-local dispatcher."
  def retry_offline(run_or_id) do
    case Runs.get_run(run_id(run_or_id)) do
      %Run{} = run -> retry_run(run)
      nil -> {:error, :not_found}
    end
  end

  @doc "Validates and queues a durable draft without waking a local dispatcher."
  def start_draft_offline(run_or_id) do
    case Runs.get_run(run_id(run_or_id)) do
      %Run{status: "draft", attempt: 0, lease_owner: nil} = run ->
        with :ok <- ExecutionEngine.validate_manifest(run, persisted_manifest(run)) do
          Runs.transition_run(run, "queued")
        end

      %Run{} = run ->
        {:error, {:invalid_transition, run.status, "queued"}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Pauses an active worker without discarding its process or context."
  def pause(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:pause, run_id(run_or_id)})
  end

  @doc "Resumes a paused active worker."
  def resume(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:resume, run_id(run_or_id)})
  end

  @doc "Persists run-scoped guidance and delivers it only to the selected worker."
  def steer(run_or_id, guidance, server \\ __MODULE__) when is_binary(guidance) do
    GenServer.call(server, {:steer, run_id(run_or_id), guidance})
  end

  def get_stats(server \\ __MODULE__), do: GenServer.call(server, :get_stats)
  def active_runs(server \\ __MODULE__), do: GenServer.call(server, :active_runs)
  def subscribe(run_or_id), do: Runs.subscribe(run_or_id)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    process_name = Keyword.get(opts, :name, __MODULE__)

    state = %__MODULE__{
      name: process_name,
      worker_id: Keyword.get(opts, :worker_id, default_worker_id()),
      executor:
        Keyword.get(
          opts,
          :executor,
          Application.get_env(:iex_code, :run_executor, IexCode.Runs.Executor)
        ),
      task_supervisor: Keyword.get(opts, :task_supervisor, IexCode.TaskSupervisor),
      max_concurrency:
        positive(
          Keyword.get(
            opts,
            :max_concurrency,
            Application.get_env(:iex_code, :run_dispatcher_max_concurrency, 2)
          ),
          2
        ),
      poll_interval: positive(Keyword.get(opts, :poll_interval, @default_poll_interval), 1_000),
      heartbeat_interval:
        positive(Keyword.get(opts, :heartbeat_interval, @default_heartbeat_interval), 5_000),
      lease_ms: positive(Keyword.get(opts, :lease_ms, @default_lease_ms), 15_000),
      cancel_grace_ms:
        positive(Keyword.get(opts, :cancel_grace_ms, @default_cancel_grace_ms), 1_500)
        |> min(@max_cancel_grace_ms),
      workspace_lock_retry_interval:
        positive(
          Keyword.get(
            opts,
            :workspace_lock_retry_interval,
            @default_workspace_lock_retry_interval
          ),
          @default_workspace_lock_retry_interval
        ),
      workspace_lock_lease_seconds:
        positive(
          Keyword.get(
            opts,
            :workspace_lock_lease_seconds,
            @default_workspace_lock_lease_seconds
          ),
          @default_workspace_lock_lease_seconds
        ),
      execution_engines: ExecutionEngine.available_ids(),
      dag_runner: Keyword.get(opts, :dag_runner, DagRunner),
      dag_runner_opts: Keyword.get(opts, :dag_runner_opts, []),
      dag_max_concurrency: positive(Keyword.get(opts, :dag_max_concurrency, 4), 4) |> min(32),
      research_finalizer: Keyword.get(opts, :research_finalizer, DagFinalizer),
      provider_effect: Keyword.get(opts, :provider_effect, ProviderEffect),
      research_reconcile_interval:
        positive(
          Keyword.get(
            opts,
            :research_reconcile_interval,
            @default_research_reconcile_interval
          ),
          @default_research_reconcile_interval
        )
        |> max(1_000)
    }

    # A new dispatcher identity cannot safely resume writes abandoned by an old
    # worker. Reconciliation deliberately ends at `interrupted`.
    owned_cutoff =
      DateTime.utc_now()
      |> DateTime.add(state.lease_ms, :millisecond)
      |> DateTime.truncate(:second)

    _ = DagScheduler.reconcile_expired()
    _ = Runs.reconcile_orphaned_run_agents()
    _ = Runs.reconcile_terminal_run_agents()
    _ = Runs.reconcile_terminal_run_agent_controls()

    interrupted =
      Runs.reconcile_orphaned_runs(
        lease_owner: state.worker_id,
        expired_before: owned_cutoff
      ) ++ Runs.reconcile_orphaned_runs([])

    _ = Runs.reconcile_run_controls(worker_id: state.worker_id)
    _ = Runs.supersede_claimed_controls(state.worker_id, "dispatcher_restarted")
    Enum.each(interrupted, &reconcile_terminal_dag/1)
    Enum.each(interrupted, &project_terminal_task/1)
    # Reconcile provider intents only after orphaned runs have been made
    # terminal, so their abandoned reservations become uncertain immediately
    # instead of waiting for the periodic pass.
    reconcile_provider_effects(state)
    reconcile_research_results(state)
    schedule_poll(state.poll_interval)
    schedule_heartbeat(state.heartbeat_interval)
    schedule_research_reconciliation(state.research_reconcile_interval)
    send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_cast(:dispatch, state) do
    send(self(), :drain)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active = active_count(state)
    queued = state |> queued_count()

    {:reply,
     %{
       queued: queued,
       active: active,
       capacity: max(state.max_concurrency - active, 0),
       max_concurrency: state.max_concurrency,
       projects: active_project_ids(state),
       worker_id: state.worker_id,
       finalization_retries: finalization_retry_state(state)
     }, state}
  end

  def handle_call(:active_runs, _from, state) do
    runs =
      (Map.values(state.workers) ++ Map.values(state.lock_waiters))
      |> Enum.map(&Runs.get_run(&1.run_id))
      |> Enum.reject(&is_nil/1)

    {:reply, runs, state}
  end

  def handle_call({:cancel, nil}, _from, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:cancel, run_id}, _from, state) do
    case Runs.get_run(run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Run{status: status} when status in ~w(completed failed cancelled) ->
        {:reply, {:error, {:invalid_transition, status, "cancelled"}}, state}

      %Run{status: "draft"} = run ->
        case Runs.cancel_unleased_run(run) do
          {:ok, cancelled} -> {:reply, {:ok, cancelled}, state}
          {:error, _reason} = error -> {:reply, error, state}
        end

      %Run{} = run ->
        active? = Map.has_key?(state.run_refs, run_id)
        claimed? = active? or Map.has_key?(state.lock_waiters, run_id)

        case persist_and_claim_control(run, "cancel", %{}, state.worker_id) do
          {:ok, control} ->
            cancellation =
              if active? do
                apply_cancellation(state, run, true, claimed?, control)
              else
                if claimed? do
                  apply_cancellation(state, run, false, true, control)
                else
                  Runs.cancel_unleased_run(run)
                end
              end

            case cancellation do
              {:ok, cancelled} ->
                if active? do
                  worker = state.workers[Map.fetch!(state.run_refs, run_id)]
                  stop_durable_fleet(cancelled, "cancelled", worker, state.worker_id)
                end

                project_terminal_task(cancelled)

                new_state =
                  state
                  |> remove_lock_waiter(run_id)
                  |> begin_worker_cancellation(run_id)

                send(self(), :drain)
                {:reply, {:ok, cancelled}, new_state}

              {:error, reason} = error ->
                _ = resolve_owned_control(control, "rejected", %{"reason" => inspect(reason)})
                {:reply, error, state}
            end

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:retry, nil}, _from, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:retry, run_id}, _from, state) do
    result = retry_offline(run_id)

    if match?({:ok, _}, result), do: send(self(), :drain)
    {:reply, result, state}
  end

  def handle_call({:pause, run_id}, _from, state) do
    result = transition_controlled_run(state, run_id, "paused", :pause)
    {:reply, result, state}
  end

  def handle_call({:resume, run_id}, _from, state) do
    case Runs.get_run(run_id) do
      %Run{status: "draft", attempt: 0, lease_owner: nil} = run ->
        case Runs.transition_run(run, "queued") do
          {:ok, queued} ->
            send(self(), :drain)
            {:reply, {:ok, queued}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      _active_or_missing ->
        result = transition_controlled_run(state, run_id, "running", :resume)
        {:reply, result, state}
    end
  end

  def handle_call({:steer, run_id, guidance}, _from, state) do
    guidance = String.trim(guidance)

    result =
      with %Run{} = run <- Runs.get_run(run_id),
           :ok <- dag_steering_supported(run),
           true <- Map.has_key?(state.run_refs, run_id),
           true <- run.status in ["running", "paused"],
           true <- guidance != "",
           {:ok, control} <-
             persist_and_claim_control(run, "steer", %{"guidance" => guidance}, state.worker_id),
           :ok <- broadcast_run_control(run, control, :steer, %{"guidance" => guidance}) do
        {:ok, Runs.get_run!(run.id)}
      else
        nil -> {:error, :not_found}
        false -> {:error, :not_active}
        {:error, _} = error -> error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:drain, state) do
    {:noreply, drain_capacity(state)}
  end

  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval)
    _ = DagScheduler.reconcile_expired()
    _ = Runs.reconcile_orphaned_run_agents()
    _ = Runs.reconcile_terminal_run_agents()
    _ = Runs.reconcile_terminal_run_agent_controls()
    interrupted = Runs.reconcile_orphaned_runs([])
    _ = Runs.reconcile_run_controls(worker_id: state.worker_id)
    Enum.each(interrupted, &reconcile_terminal_dag/1)
    Enum.each(interrupted, &project_terminal_task/1)

    {:noreply,
     state
     |> drain_external_cancellations()
     |> drain_pending_controls()
     |> reconcile_finalization_retry_state()
     |> drain_capacity()}
  end

  def handle_info(:reconcile_research_results, state) do
    schedule_research_reconciliation(state.research_reconcile_interval)
    reconcile_provider_effects(state)
    reconcile_research_results(state)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    schedule_heartbeat(state.heartbeat_interval)
    state = drain_external_cancellations(state)

    Enum.each(state.workers, fn {_ref, worker} ->
      unless MapSet.member?(state.cancelling, worker.run_id) or
               Map.has_key?(state.finalization_retries, worker.run_id) do
        case Runs.renew_lease(worker.run_id, state.worker_id, state.lease_ms,
               run_attempt: worker.run_attempt,
               lease_generation: worker.run_generation
             ) do
          {:ok, _run} -> :ok
          {:error, reason} -> send(self(), {:run_lease_heartbeat_failed, worker.run_id, reason})
        end
      end
    end)

    Enum.each(state.lock_waiters, fn {run_id, waiter} ->
      case Runs.renew_lease(run_id, state.worker_id, state.lease_ms,
             run_attempt: waiter.run_attempt,
             lease_generation: waiter.run_generation
           ) do
        {:ok, _run} -> :ok
        {:error, reason} -> send(self(), {:run_lease_heartbeat_failed, run_id, reason})
      end
    end)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.workers, ref) do
      {:ok, worker} ->
        # A Task sends its result immediately before it exits. Keep the workspace
        # lock until the corresponding DOWN arrives so cleanup cannot race the
        # next lock holder.
        if worker[:budget_timer], do: Process.cancel_timer(worker.budget_timer)
        worker = worker |> Map.put(:result, result) |> Map.put(:budget_timer, nil)
        {:noreply, put_in(state.workers[ref], worker)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.workers, ref) do
      {:ok, worker} ->
        result =
          cond do
            Map.has_key?(worker, :result) ->
              worker.result

            Map.has_key?(worker, :lock_failure) ->
              {:worker_exit, {:workspace_lock_heartbeat_failed, worker.lock_failure}}

            true ->
              {:worker_exit, reason}
          end

        finish_worker_or_retry(state, ref, worker, result)

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:force_cancel, run_id, pid}, state) do
    if Map.has_key?(state.run_refs, run_id) and Process.alive?(pid) do
      _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    end

    {:noreply, state}
  end

  def handle_info({:retry_finish_worker, ref, worker, result, attempt}, state) do
    finish_worker_or_retry(state, ref, worker, result, attempt)
  end

  def handle_info({:retry_workspace_lock, run_id}, state) do
    case Map.fetch(state.lock_waiters, run_id) do
      {:ok, waiter} ->
        state = retry_workspace_lock(state, waiter)
        send(self(), :drain)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:workspace_lock_heartbeat_failed, lock_id, reason}, state) do
    case Enum.find(state.workers, fn {_ref, worker} -> worker.lock_id == lock_id end) do
      {ref, worker} ->
        Logger.error(
          "Coding run #{worker.run_id} lost its workspace lock heartbeat: #{inspect(reason)}"
        )

        if Process.alive?(worker.pid) do
          _ = Task.Supervisor.terminate_child(state.task_supervisor, worker.pid)
        end

        {:noreply, put_in(state.workers[ref], Map.put(worker, :lock_failure, reason))}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:run_lease_heartbeat_failed, run_id, reason}, state) do
    case Runs.get_run(run_id) do
      %Run{cancellation_requested_at: %DateTime{}} ->
        {:noreply, drain_external_cancellations(state)}

      _not_cancelled ->
        handle_run_lease_heartbeat_failure(state, run_id, reason)
    end
  end

  def handle_info({:run_time_budget_exceeded, run_id, pid}, state) do
    ref = Map.get(state.run_refs, run_id)

    case {ref && Map.get(state.workers, ref), Runs.get_run(run_id)} do
      {%{pid: ^pid} = worker, %Run{status: status} = run}
      when status in ["running", "paused"] ->
        if not worker_authority_current?(run, worker, state.worker_id) do
          {:noreply, state}
        else
          transition =
            Runs.finalize_run_worker(
              run,
              "failed",
              %{
                error_message: "Run exceeded its #{run.time_budget_ms}ms time budget",
                error_details: %{
                  "reason" => "budget_exhausted",
                  "budget" => "time",
                  "limit_ms" => run.time_budget_ms
                },
                lease_owner: run.lease_owner,
                lease_expires_at: run.lease_expires_at
              },
              lease_owner: state.worker_id,
              run_attempt: worker.run_attempt,
              lease_generation: worker.run_generation,
              preserve_lease: true,
              terminal_lease_ms: terminal_lease_ms(state)
            )

          case transition do
            {:ok, failed} ->
              _ =
                Runs.append_event_worker(
                  failed,
                  "run.budget_exhausted",
                  %{"budget" => "time", "limit_ms" => failed.time_budget_ms},
                  "dispatcher",
                  lease_owner: state.worker_id,
                  run_attempt: worker.run_attempt,
                  lease_generation: worker.run_generation,
                  allow_terminal: true
                )

              stop_durable_fleet(failed, "failed", worker, state.worker_id)
              project_terminal_task(failed)
              broadcast_run_control(failed, :cancel, %{"reason" => "time_budget_exhausted"})

            _ ->
              :ok
          end

          new_state = begin_worker_cancellation(state, run_id)
          {:noreply, new_state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_run_lease_heartbeat_failure(state, run_id, reason) do
    case Map.get(state.run_refs, run_id) do
      nil ->
        if Map.has_key?(state.lock_waiters, run_id) do
          Logger.warning(
            "Run #{run_id} lost its lease while waiting for a workspace lock: #{inspect(reason)}"
          )

          {:noreply, remove_lock_waiter(state, run_id)}
        else
          {:noreply, state}
        end

      ref ->
        worker = Map.fetch!(state.workers, ref)

        if Process.alive?(worker.pid) do
          _ = Task.Supervisor.terminate_child(state.task_supervisor, worker.pid)
        end

        {:noreply,
         put_in(state.workers[ref], Map.put(worker, :lock_failure, {:run_lease_lost, reason}))}
    end
  end

  defp drain_capacity(state) do
    if active_count(state) < state.max_concurrency do
      opts = [
        lease_ms: state.lease_ms,
        exclude_project_ids: active_project_ids(state),
        execution_engines: state.execution_engines
      ]

      case Runs.claim_next_run(state.worker_id, opts) do
        {:ok, %Run{} = run} ->
          state |> start_validated_claimed_run(run) |> drain_capacity()

        :none ->
          state

        {:error, reason} ->
          Logger.warning("RunDispatcher claim failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp start_validated_claimed_run(state, %Run{} = run) do
    manifest = persisted_manifest(run)

    case validate_claimed_manifest_hash(run, manifest) do
      :ok ->
        start_claimed_run(state, run)

      {:error, reason} ->
        fail_claimed_run(state, run, {:invalid_execution_manifest, reason})
    end
  end

  defp validate_claimed_manifest_hash(run, manifest) do
    with :ok <- ExecutionEngine.validate_manifest(run, manifest),
         {:ok, prepared} <- ExecutionEngine.prepare_manifest(run, manifest),
         true <- prepared.manifest_hash == run.manifest_hash || {:error, :manifest_drift} do
      :ok
    end
  end

  defp persisted_manifest(%Run{execution_engine: "dag_v1"} = run) do
    Enum.map(Runs.list_steps(run), fn step ->
      %{
        key: step.key,
        kind: step.kind,
        title: step.title,
        depends_on: step.depends_on,
        params: step.params,
        max_attempts: step.max_attempts
      }
    end)
  end

  defp persisted_manifest(%Run{} = run), do: Runs.list_steps(run)

  defp start_claimed_run(state, %Run{execution_engine: "dag_v1"} = run),
    do: start_dag_worker(state, run)

  defp start_claimed_run(state, %Run{kind: kind} = run)
       when kind in ["coding_swarm", "coding_agent"] do
    case acquire_coding_lock(state, run) do
      {:ok, handle} -> start_worker(state, run, handle)
      {:waiting, handle} -> wait_for_workspace_lock(state, run, handle)
      {:error, reason} -> fail_claimed_run(state, run, reason)
    end
  end

  defp start_claimed_run(state, %Run{} = run), do: start_worker(state, run, nil)

  defp start_dag_worker(state, run) do
    project = Projects.get_project!(run.project_id)
    dag_runner = state.dag_runner

    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        dag_runner.run(
          run,
          Keyword.merge(
            state.dag_runner_opts,
            lease_owner: state.worker_id,
            lease_generation: run.lease_generation,
            project_root: project.root_path,
            lease_ms: state.lease_ms,
            heartbeat_ms: min(state.heartbeat_interval, max(div(state.lease_ms, 3), 1)),
            max_concurrency: state.dag_max_concurrency
          )
        )
      end)

    worker = %{
      engine: "dag_v1",
      run_id: run.id,
      run_attempt: run.attempt,
      run_generation: run.lease_generation,
      project_id: run.project_id,
      pid: task.pid,
      execute_step_id: nil,
      budget_timer: schedule_time_budget(run, task.pid),
      lock_handle: nil,
      lock_delegation: nil,
      lock_id: nil
    }

    broadcast_session(run, {:async_run_started, run, task.pid})

    %{
      state
      | workers: Map.put(state.workers, task.ref, worker),
        run_refs: Map.put(state.run_refs, run.id, task.ref)
    }
  rescue
    error -> fail_claimed_run(state, run, {:dag_worker_start_failed, error})
  end

  defp start_worker(state, run, lock_handle) do
    case prepare_claimed_run(run, state) do
      {:ok, execute_step} ->
        executor = state.executor
        delegation = workspace_lock_delegation(lock_handle)

        task =
          Task.Supervisor.async(state.task_supervisor, fn ->
            progress = fn percent, message ->
              report_progress(
                run.id,
                state.worker_id,
                run.attempt,
                run.lease_generation,
                state.lease_ms,
                percent,
                message
              )
            end

            with_workspace_lock_delegation(delegation, fn ->
              case assert_workspace_lock(lock_handle) do
                :ok ->
                  execute(executor, run, progress, delegation,
                    run_lease_owner: state.worker_id,
                    run_attempt: run.attempt,
                    run_lease_generation: run.lease_generation,
                    run_lease_ms: state.lease_ms,
                    run_terminal_lease_ms: terminal_lease_ms(state)
                  )

                {:error, reason} ->
                  {:error, {:workspace_lock_lost_before_execute, reason}}
              end
            end)
          end)

        worker = %{
          run_id: run.id,
          run_attempt: run.attempt,
          run_generation: run.lease_generation,
          project_id: run.project_id,
          pid: task.pid,
          execute_step_id: execute_step.id,
          budget_timer: schedule_time_budget(run, task.pid),
          lock_handle: lock_handle,
          lock_delegation: delegation,
          lock_id: WorkspaceLocks.handle_id(lock_handle)
        }

        workers = Map.put(state.workers, task.ref, worker)
        run_refs = Map.put(state.run_refs, run.id, task.ref)

        broadcast_session(run, {:async_run_started, run, task.pid})
        %{state | workers: workers, run_refs: run_refs}

      {:error, reason} ->
        release_workspace_lock(lock_handle)

        case Runs.finalize_run_worker(run, "failed", error_attrs(reason),
               lease_owner: state.worker_id,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             ) do
          {:ok, failed} -> project_terminal_task(failed)
          _ -> :ok
        end

        state
    end
  end

  defp acquire_coding_lock(state, run) do
    project = Projects.get_project!(run.project_id)

    WorkspaceLocks.acquire_or_wait(project, [:project],
      owner_id: "run:#{run.id}",
      run_id: run.id,
      session_id: run.session_id,
      project_id: run.project_id,
      lease_seconds: coding_lock_lease_seconds(state, run),
      heartbeat_interval_ms: coding_lock_heartbeat_interval(state, run),
      heartbeat_failure: :notify
    )
  rescue
    error -> {:error, {:workspace_lock_acquire_failed, error}}
  catch
    kind, reason -> {:error, {:workspace_lock_acquire_failed, kind, reason}}
  end

  defp wait_for_workspace_lock(state, run, handle) do
    _ =
      Runs.block_run_worker(run, "Waiting for exclusive project workspace access",
        lease_owner: state.worker_id,
        run_attempt: run.attempt,
        lease_generation: run.lease_generation
      )

    timer =
      Process.send_after(
        self(),
        {:retry_workspace_lock, run.id},
        state.workspace_lock_retry_interval
      )

    waiter = %{
      run_id: run.id,
      run_attempt: run.attempt,
      run_generation: run.lease_generation,
      project_id: run.project_id,
      lock_handle: handle,
      lock_id: WorkspaceLocks.handle_id(handle),
      retry_timer: timer
    }

    state = %{state | lock_waiters: Map.put(state.lock_waiters, run.id, waiter)}

    # A durable cancellation can arrive after the run claim but before this
    # waiter is installed. Close that registration window immediately instead
    # of waiting for a later poll/heartbeat.
    case Runs.get_run(run.id) do
      %Run{cancellation_requested_at: %DateTime{}} -> drain_external_cancellations(state)
      _current -> state
    end
  end

  defp retry_workspace_lock(state, waiter) do
    case Runs.get_run(waiter.run_id) do
      %Run{status: status} = run
      when status in ["running", "paused"] and run.attempt == waiter.run_attempt and
             run.lease_generation == waiter.run_generation and
             run.lease_owner == state.worker_id ->
        case Runs.renew_lease(run.id, state.worker_id, state.lease_ms,
               run_attempt: waiter.run_attempt,
               lease_generation: waiter.run_generation
             ) do
          {:ok, renewed} ->
            case WorkspaceLocks.retry(waiter.lock_handle) do
              {:ok, handle} ->
                state
                |> remove_lock_waiter(renewed.id, release?: false)
                |> start_worker(renewed, handle)

              {:waiting, handle} ->
                wait_for_workspace_lock(
                  remove_lock_waiter(state, renewed.id, release?: false),
                  renewed,
                  handle
                )

              {:error, reason} ->
                state
                |> remove_lock_waiter(renewed.id)
                |> fail_claimed_run(renewed, reason)
            end

          {:error, _lease_reason} ->
            remove_lock_waiter(state, waiter.run_id)
        end

      _ ->
        remove_lock_waiter(state, waiter.run_id)
    end
  end

  defp fail_claimed_run(state, run, reason) do
    attrs =
      if run.execution_engine == "dag_v1",
        do: dag_preflight_attrs(reason),
        else: error_attrs(reason)

    case Runs.finalize_run_worker(run, "failed", attrs,
           lease_owner: state.worker_id,
           run_attempt: run.attempt,
           lease_generation: run.lease_generation
         ) do
      {:ok, failed} ->
        project_terminal_task(failed)
        broadcast_session(failed, {:async_run_updated, failed})

      {:error, finalize_reason} ->
        Logger.warning("Claimed run preflight finalization failed: #{inspect(finalize_reason)}")
    end

    state
  end

  defp execute(executor, run, progress, delegation, authority) do
    if Code.ensure_loaded?(executor) and function_exported?(executor, :execute, 3) do
      executor.execute(
        run,
        progress,
        [workspace_lock_delegation: delegation] ++ authority
      )
    else
      executor.execute(run, progress)
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp report_progress(
         run_id,
         worker_id,
         run_attempt,
         run_generation,
         lease_ms,
         percent,
         message
       ) do
    percent = percent |> max(0) |> min(100)

    with {:ok, run} <-
           Runs.record_progress(run_id, percent, message, "worker",
             lease_owner: worker_id,
             run_attempt: run_attempt,
             lease_generation: run_generation,
             lease_ms: lease_ms
           ) do
      broadcast_session(run, {:async_run_updated, run})
      :ok
    else
      error -> exit({:run_lease_lost, error})
    end
  end

  defp finish_worker(state, ref, %{engine: "dag_v1"} = worker, result) do
    if worker[:budget_timer], do: Process.cancel_timer(worker.budget_timer)
    run = Runs.get_run(worker.run_id)
    cancelling? = MapSet.member?(state.cancelling, worker.run_id)

    authoritative_run =
      cond do
        is_nil(run) ->
          nil

        authoritative_terminal_run?(run, worker) ->
          project_terminal_task(run)
          broadcast_session(run, {:async_run_updated, run})
          run

        cancelling? ->
          nil

        not worker_authority_current?(run, worker, state.worker_id) ->
          Logger.info("Ignoring stale DAG worker finalization for run #{worker.run_id}")
          nil

        true ->
          attrs = dag_interruption_attrs(result)

          case Runs.finalize_run_worker(run, "interrupted", attrs,
                 lease_owner: state.worker_id,
                 run_attempt: worker.run_attempt,
                 lease_generation: worker.run_generation
               ) do
            {:ok, interrupted} ->
              project_terminal_task(interrupted)
              broadcast_session(interrupted, {:async_run_updated, interrupted})
              interrupted

            {:error, {:invalid_transition, _, _}} ->
              verified_terminal_run(worker)

            {:error, reason} ->
              Logger.warning("DAG run interruption failed: #{inspect(reason)}")
              nil
          end
      end

    if authoritative_run do
      reject_unapplied_controls(authoritative_run)
      release_terminal_run_lease(authoritative_run, worker, state.worker_id)
    end

    %{
      state
      | workers: Map.delete(state.workers, ref),
        run_refs: Map.delete(state.run_refs, worker.run_id),
        cancelling: MapSet.delete(state.cancelling, worker.run_id)
    }
  end

  defp finish_worker(state, ref, worker, result) do
    if worker[:budget_timer], do: Process.cancel_timer(worker.budget_timer)
    run = Runs.get_run(worker.run_id)
    cancelling? = MapSet.member?(state.cancelling, worker.run_id)

    authoritative_run =
      cond do
        is_nil(run) ->
          nil

        authoritative_terminal_run?(run, worker) ->
          project_terminal_task(run)
          broadcast_session(run, {:async_run_updated, run})
          run

        cancelling? ->
          nil

        not worker_authority_current?(run, worker, state.worker_id) ->
          Logger.info("Ignoring stale worker finalization for run #{worker.run_id}")
          nil

        true ->
          {status, attrs} = terminal_result(result)

          attrs =
            case attrs do
              %{metadata: result_metadata} ->
                %{attrs | metadata: Map.merge(run.metadata || %{}, result_metadata)}

              _ ->
                attrs
            end

          case Runs.finalize_run_worker(run, status, attrs,
                 lease_owner: state.worker_id,
                 run_attempt: worker.run_attempt,
                 lease_generation: worker.run_generation
               ) do
            {:ok, updated} ->
              project_terminal_task(updated)
              broadcast_session(updated, {:async_run_updated, updated})
              updated

            {:error, {:invalid_transition, _, _}} ->
              verified_terminal_run(worker)

            {:error, reason} ->
              Logger.warning("RunDispatcher finalization failed: #{inspect(reason)}")
              nil
          end
      end

    if authoritative_run do
      reject_unapplied_controls(authoritative_run)
      stop_durable_fleet(authoritative_run, authoritative_run.status, worker, state.worker_id)
    end

    release_workspace_lock(worker.lock_handle)

    if authoritative_run do
      release_terminal_run_lease(authoritative_run, worker, state.worker_id)
    end

    %{
      state
      | workers: Map.delete(state.workers, ref),
        run_refs: Map.delete(state.run_refs, worker.run_id),
        cancelling: MapSet.delete(state.cancelling, worker.run_id)
    }
  end

  defp finish_worker_or_retry(state, ref, worker, result) do
    finish_worker_or_retry(state, ref, worker, result, 1)
  end

  defp finish_worker_or_retry(state, ref, worker, result, attempt) do
    try do
      next_state = finish_worker(state, ref, worker, result)
      send(self(), :drain)
      {:noreply, clear_finalization_retry(next_state, worker.run_id)}
    rescue
      error in [DBConnection.ConnectionError, Exqlite.Error] ->
        retry_worker_finalization(
          state,
          ref,
          worker,
          result,
          attempt,
          Exception.message(error)
        )
    catch
      :exit, reason ->
        retry_worker_finalization(state, ref, worker, result, attempt, inspect(reason))
    end
  end

  defp retry_worker_finalization(state, ref, worker, result, attempt, reason) do
    Logger.warning(
      "Run #{worker.run_id} finalization attempt #{attempt} hit a transient database disconnect: #{reason}"
    )

    if attempt >= @max_finalization_retries do
      release_workspace_lock(worker.lock_handle)

      if terminal_run = verified_terminal_run(worker) do
        reject_unapplied_controls(terminal_run)
        stop_durable_fleet(terminal_run, terminal_run.status, worker, state.worker_id)
        release_terminal_run_lease(terminal_run, worker, state.worker_id)
      end

      send(self(), :drain)

      retry = %{
        attempt: attempt,
        status: :exhausted,
        last_error: String.slice(reason, 0, 500),
        next_retry_in_ms: nil
      }

      {:noreply,
       %{
         state
         | workers: Map.delete(state.workers, ref),
           run_refs: Map.delete(state.run_refs, worker.run_id),
           cancelling: MapSet.delete(state.cancelling, worker.run_id),
           finalization_retries: Map.put(state.finalization_retries, worker.run_id, retry)
       }}
    else
      delay = finalization_retry_delay(attempt)

      Process.send_after(
        self(),
        {:retry_finish_worker, ref, worker, result, attempt + 1},
        delay
      )

      retry = %{
        attempt: attempt,
        status: :scheduled,
        last_error: String.slice(reason, 0, 500),
        next_retry_in_ms: delay
      }

      {:noreply,
       %{state | finalization_retries: Map.put(state.finalization_retries, worker.run_id, retry)}}
    end
  end

  defp finalization_retry_delay(attempt) do
    min(
      @finalization_retry_base_ms * Integer.pow(2, max(attempt - 1, 0)),
      @finalization_retry_max_ms
    )
  end

  defp clear_finalization_retry(state, run_id) do
    %{state | finalization_retries: Map.delete(state.finalization_retries, run_id)}
  end

  defp finalization_retry_state(state) do
    Map.new(state.finalization_retries, fn {run_id, retry} ->
      {run_id, Map.take(retry, [:attempt, :status, :last_error, :next_retry_in_ms])}
    end)
  end

  defp reconcile_finalization_retry_state(state) do
    retries =
      Map.reject(state.finalization_retries, fn
        {run_id, %{status: :exhausted}} ->
          case Runs.get_run(run_id) do
            nil -> true
            %Run{status: status} -> status in ["completed", "failed", "cancelled", "interrupted"]
          end

        {_run_id, _retry} ->
          false
      end)

    %{state | finalization_retries: retries}
  end

  defp stop_durable_fleet(run, status, worker, worker_id) do
    case AgentRegistry.whereis_fleet(run.id, :manager) do
      nil ->
        :ok

      _manager ->
        _ =
          FleetManager.stop(run.id, status,
            lease_owner: worker_id,
            run_attempt: worker.run_attempt,
            lease_generation: worker.run_generation
          )
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_fleet_control(run_id, kind) when kind in [:pause, :resume] do
    if AgentRegistry.whereis_fleet(run_id, :manager) do
      _ = FleetManager.control_all(run_id, kind)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_fleet_control(_run_id, _kind), do: :ok

  defp terminal_result({:ok, result}),
    do: {"completed", %{metadata: %{"result" => inspect(result)}}}

  defp terminal_result(:ok), do: {"completed", %{}}

  defp terminal_result({:error, reason}),
    do: {"failed", error_attrs(reason)}

  defp terminal_result({:worker_exit, reason}),
    do: {"interrupted", error_attrs(reason)}

  defp terminal_result(other), do: {"completed", %{metadata: %{"result" => inspect(other)}}}

  defp error_attrs(reason) do
    %{error_message: format_reason(reason), error_details: %{"reason" => inspect(reason)}}
  end

  defp format_reason({exception, stacktrace}) when is_exception(exception),
    do: Exception.format(:error, exception, stacktrace)

  defp format_reason({kind, reason}) when kind in [:exit, :throw],
    do: "#{kind}: #{inspect(reason)}"

  defp format_reason(reason), do: inspect(reason)

  defp begin_worker_cancellation(state, run_id) do
    case Map.fetch(state.run_refs, run_id) do
      {:ok, ref} ->
        worker = Map.fetch!(state.workers, ref)
        Process.send_after(self(), {:force_cancel, run_id, worker.pid}, state.cancel_grace_ms)
        %{state | cancelling: MapSet.put(state.cancelling, run_id)}

      :error ->
        state
    end
  end

  defp transition_controlled_run(state, run_id, status, kind) do
    with %Run{} = run <- Runs.get_run(run_id),
         true <- Map.has_key?(state.run_refs, run_id),
         {:ok, control} <-
           persist_and_claim_control(run, Atom.to_string(kind), %{}, state.worker_id) do
      apply_claimed_state_control(state, run, control, status, kind)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_active}
      {:error, _} = error -> error
    end
  end

  defp apply_claimed_state_control(state, run, control, status, kind) do
    transition =
      if run.execution_engine == "legacy_v1" do
        case Runs.apply_claimed_legacy_control(control, status,
               lease_owner: state.worker_id,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             ) do
          {:ok, updated, _applied} -> {:ok, updated}
          {:error, _reason} = error -> error
        end
      else
        Runs.transition_run_worker(run, status, %{},
          lease_owner: state.worker_id,
          run_attempt: run.attempt,
          lease_generation: run.lease_generation
        )
      end

    case transition do
      {:ok, updated} ->
        case apply_execution_control(state, updated, control, kind) do
          :ok ->
            broadcast_session(updated, {:async_run_updated, updated})
            {:ok, updated}

          {:error, reason} = error ->
            _ = resolve_owned_control(control, "rejected", %{"reason" => inspect(reason)})
            error
        end

      {:error, reason} = error ->
        _ = resolve_owned_control(control, "rejected", %{"reason" => inspect(reason)})
        error
    end
  end

  defp drain_pending_controls(state) do
    state.run_refs
    |> Map.keys()
    |> Enum.each(&drain_pending_controls_for_run(state, &1, 32))

    state
  end

  defp drain_external_cancellations(state) do
    state =
      Enum.reduce(state.run_refs, state, fn {run_id, ref}, current_state ->
        case {Runs.get_run(run_id), Map.get(current_state.workers, ref)} do
          {%Run{status: status, cancellation_requested_at: %DateTime{}} = run, worker}
          when status in ["running", "paused"] and is_map(worker) ->
            :ok = broadcast_run_control(run, :cancel, %{"source" => "durable_request"})

            case transition_cancelled_run(current_state, run, true, true) do
              {:ok, cancelled} ->
                stop_durable_fleet(cancelled, "cancelled", worker, current_state.worker_id)
                project_terminal_task(cancelled)
                begin_worker_cancellation(current_state, run_id)

              {:error, _reason} ->
                current_state
            end

          _not_cancelled_or_missing ->
            current_state
        end
      end)

    state =
      Enum.reduce(Map.keys(state.lock_waiters), state, fn run_id, current_state ->
        case Runs.get_run(run_id) do
          %Run{status: status, cancellation_requested_at: %DateTime{}} = run
          when status in ["running", "paused"] ->
            case transition_cancelled_run(current_state, run, true, false) do
              {:ok, cancelled} ->
                project_terminal_task(cancelled)
                remove_lock_waiter(current_state, run_id)

              {:error, _reason} ->
                current_state
            end

          _not_cancelled_or_missing ->
            current_state
        end
      end)

    # A retry-lock timer can observe cancellation and remove its in-memory
    # waiter immediately before the poll arrives. The database lease remains
    # authoritative, so close any such owner-scoped cancellation orphan here.
    ["running", "paused"]
    |> Enum.flat_map(&Runs.list_runs(status: &1, limit: 1_000))
    |> Enum.filter(fn run ->
      run.lease_owner == state.worker_id and match?(%DateTime{}, run.cancellation_requested_at) and
        not Map.has_key?(state.run_refs, run.id) and not Map.has_key?(state.lock_waiters, run.id)
    end)
    |> Enum.each(fn run ->
      case transition_cancelled_run(state, run, true, false) do
        {:ok, cancelled} -> project_terminal_task(cancelled)
        {:error, _reason} -> :ok
      end
    end)

    state
  end

  defp drain_pending_controls_for_run(_state, _run_id, 0), do: :ok

  defp drain_pending_controls_for_run(state, run_id, remaining) do
    case Runs.get_run(run_id) do
      %Run{} = run ->
        case Runs.list_controls(run, status: "claimed", limit: 1) do
          [%{kind: "steer"} = control] ->
            guidance = Map.get(control.payload || %{}, "guidance")
            :ok = broadcast_run_control(run, control, :steer, %{"guidance" => guidance})
            :ok

          [_claimed_control] ->
            :ok

          [] ->
            drain_next_pending_control(state, run, remaining)
        end

      nil ->
        :ok
    end
  end

  defp drain_next_pending_control(state, run, remaining) do
    case Runs.claim_next_control(run, state.worker_id) do
      {:ok, %{kind: "pause"} = control} ->
        _ = apply_claimed_state_control(state, run, control, "paused", :pause)
        drain_pending_controls_for_run(state, run.id, remaining - 1)

      {:ok, %{kind: "resume"} = control} ->
        _ = apply_claimed_state_control(state, run, control, "running", :resume)
        drain_pending_controls_for_run(state, run.id, remaining - 1)

      {:ok, %{kind: "steer"} = control} ->
        guidance = Map.get(control.payload || %{}, "guidance")
        :ok = broadcast_run_control(run, control, :steer, %{"guidance" => guidance})
        :ok

      {:ok, control} ->
        _ = resolve_owned_control(control, "rejected", %{"reason" => "unsupported_control"})
        drain_pending_controls_for_run(state, run.id, remaining - 1)

      :none ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp queued_count(_state) do
    Runs.list_runs(status: "queued", limit: 1_000) |> length()
  rescue
    _ -> 0
  end

  defp active_project_ids(state) do
    (Map.values(state.workers) ++ Map.values(state.lock_waiters))
    |> Enum.map(& &1.project_id)
    |> Enum.uniq()
  end

  defp active_count(state), do: map_size(state.workers) + map_size(state.lock_waiters)

  defp worker_authority_current?(%Run{} = run, worker, worker_id) do
    run.attempt == worker.run_attempt and run.lease_generation == worker.run_generation and
      run.lease_owner == worker_id and live_run_lease?(run)
  end

  defp authoritative_terminal_run?(%Run{status: status} = run, worker)
       when status in ["completed", "failed", "cancelled", "interrupted"] do
    run.attempt == worker.run_attempt and run.lease_generation == worker.run_generation
  end

  defp authoritative_terminal_run?(%Run{}, _worker), do: false

  defp verified_terminal_run(worker) do
    case Runs.get_run(worker.run_id) do
      %Run{} = run -> if authoritative_terminal_run?(run, worker), do: run
      nil -> nil
    end
  end

  defp live_run_lease?(%Run{lease_expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp live_run_lease?(%Run{}), do: false

  defp release_terminal_run_lease(%Run{lease_owner: worker_id} = run, worker, worker_id) do
    _ =
      Runs.release_lease(run.id, worker_id,
        run_attempt: worker.run_attempt,
        lease_generation: worker.run_generation
      )

    :ok
  end

  defp release_terminal_run_lease(%Run{}, _worker, _worker_id), do: :ok

  defp remove_lock_waiter(state, run_id, opts \\ []) do
    case Map.pop(state.lock_waiters, run_id) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        if waiter.retry_timer, do: Process.cancel_timer(waiter.retry_timer)
        if Keyword.get(opts, :release?, true), do: release_workspace_lock(waiter.lock_handle)
        %{state | lock_waiters: waiters}
    end
  end

  defp release_workspace_lock(nil), do: :ok

  defp release_workspace_lock(handle) do
    case WorkspaceLocks.release(handle) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Workspace lock release failed: #{inspect(reason)}")
    end
  end

  defp assert_workspace_lock(nil), do: :ok
  defp assert_workspace_lock(handle), do: WorkspaceLocks.assert(handle)

  defp workspace_lock_delegation(nil), do: nil

  defp workspace_lock_delegation(handle) do
    case WorkspaceLocks.delegate(handle) do
      {:ok, delegation} -> delegation
      {:error, reason} -> {:workspace_lock_delegation_error, reason}
    end
  end

  defp with_workspace_lock_delegation(nil, fun), do: fun.()

  defp with_workspace_lock_delegation({:workspace_lock_delegation_error, reason}, _fun) do
    {:error, {:workspace_lock_delegation_failed, reason}}
  end

  defp with_workspace_lock_delegation(delegation, fun) do
    WorkspaceLocks.with_delegation(delegation, fun)
  end

  defp coding_lock_lease_seconds(state, %Run{time_budget_ms: budget_ms})
       when is_integer(budget_ms) and budget_ms > 0 do
    budget_seconds = div(budget_ms + 999, 1_000) + 5
    max(state.workspace_lock_lease_seconds, budget_seconds) |> min(86_400)
  end

  defp coding_lock_lease_seconds(state, _run), do: state.workspace_lock_lease_seconds

  defp coding_lock_heartbeat_interval(state, run) do
    state
    |> coding_lock_lease_seconds(run)
    |> Kernel.*(1_000)
    |> div(3)
    |> max(250)
  end

  defp validate_typed_attrs(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind")
    mode = Map.get(attrs, :mode) || Map.get(attrs, "mode")
    objective = Map.get(attrs, :objective) || Map.get(attrs, "objective")
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    session_id = Map.get(attrs, :session_id) || Map.get(attrs, "session_id")

    if Enum.all?([kind, mode, objective, project_id, session_id], &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, :invalid_typed_run}
    end
  end

  defp research_run_attrs(
         attrs,
         policy,
         ranked,
         grounded,
         max_sources,
         fetch_parallelism,
         require_conflict_audit,
         provider_snapshot_ref,
         attachment_refs,
         budget_requirements
       ) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}

    research = %{
      "level" => policy.level,
      "level_policy" => LevelPolicy.durable(policy),
      "ranked_providers" => ranked,
      "grounded_providers" => grounded,
      "max_sources" => max_sources,
      "fetch_parallelism" => fetch_parallelism,
      "require_conflict_audit" => require_conflict_audit,
      "provider_snapshot_ref" => provider_snapshot_ref,
      "attachment_refs" => attachment_refs,
      "run_retry_policy" => Launch.retry_policy(),
      "budget_requirements" => %{
        "tokens" => budget_requirements.tokens,
        "cost_cents" => budget_requirements.cost_cents
      }
    }

    attrs
    |> normalized_research_attrs()
    |> Map.merge(%{
      kind: "deep_research",
      mode: "research",
      execution_engine: "dag_v1",
      metadata:
        metadata
        |> Map.put("projection", "dag_v1")
        |> Map.put("research", research),
      max_attempts: 1
    })
    |> put_default_budget(:token_budget, budget_requirements.tokens)
    |> put_default_budget(:cost_budget_cents, budget_requirements.cost_cents)
    |> put_default_budget(:time_budget_ms, research_time_ceiling(policy.level))
  end

  defp put_default_budget(attrs, field, value) do
    current = Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))
    if is_nil(current), do: Map.put(attrs, field, value), else: attrs
  end

  defp research_time_ceiling("low"), do: 10 * 60_000
  defp research_time_ceiling("medium"), do: 20 * 60_000
  defp research_time_ceiling("high"), do: 40 * 60_000
  defp research_time_ceiling("ultra"), do: 90 * 60_000

  # Accept either atom- or string-keyed external maps without ever creating
  # atoms from caller input or passing a mixed-key map into Ecto.
  defp normalized_research_attrs(attrs) do
    Enum.reduce(
      ~w(project_id session_id objective priority token_budget cost_budget_cents time_budget_ms not_before request_key)a,
      %{},
      fn field, normalized ->
        case Map.fetch(attrs, field) do
          {:ok, value} -> Map.put(normalized, field, value)
          :error -> maybe_copy_string_attr(normalized, attrs, field)
        end
      end
    )
  end

  defp maybe_copy_string_attr(normalized, attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> Map.put(normalized, field, value)
      :error -> normalized
    end
  end

  defp execution_engine_available(engine) do
    if engine in ExecutionEngine.available_ids(),
      do: :ok,
      else: {:error, {:execution_engine_unavailable, engine}}
  end

  defp metadata_kind(attrs) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    Map.get(metadata, :kind) || Map.get(metadata, "kind")
  end

  defp run_id(%Run{id: id}), do: id
  defp run_id(id) when is_binary(id), do: id
  defp run_id(_), do: nil

  defp maybe_broadcast_cancel(true, %Run{} = run) do
    broadcast_run_control(run, :cancel, %{"action" => "rollback"})
  end

  defp maybe_broadcast_cancel(false, %Run{}), do: :ok

  defp apply_cancellation(state, run, worker_active?, claimed?, control) do
    with {:ok, requested} <- Runs.request_cancellation(run),
         :ok <- maybe_broadcast_cancel(worker_active?, requested),
         {:ok, cancelled} <-
           transition_cancelled_run(state, requested, claimed?, worker_active?),
         {:ok, _control} <-
           resolve_owned_control(control, "applied", %{
             "run_status" => "cancelled",
             "worker_active" => worker_active?
           }) do
      {:ok, cancelled}
    end
  end

  defp transition_cancelled_run(state, run, true, worker_active?) do
    Runs.finalize_run_worker(run, "cancelled", %{},
      lease_owner: state.worker_id,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation,
      preserve_lease: worker_active?,
      terminal_lease_ms: terminal_lease_ms(state)
    )
  end

  defp transition_cancelled_run(_state, run, false, _worker_active?),
    do: Runs.transition_run(run, "cancelled")

  defp broadcast_run_control(%Run{} = run, kind, payload) do
    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "run:#{run.id}:control",
      {:run_control, run.id, kind, payload}
    )
  end

  defp broadcast_run_control(%Run{} = run, control, kind, payload) do
    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "run:#{run.id}:control",
      {:run_control, run.id, control.id, kind, payload}
    )
  end

  defp persist_and_claim_control(%Run{} = run, kind, payload, worker_id) do
    idempotency_key =
      "dispatcher:#{kind}:#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, pending} <-
           Runs.enqueue_control(run, idempotency_key, %{
             kind: kind,
             payload: payload,
             requested_by: "local-user"
           }),
         {:ok, claimed} <- Runs.claim_control(pending, worker_id) do
      {:ok, claimed}
    end
  end

  defp reject_unapplied_controls(run) do
    run
    |> Runs.list_controls(status: "claimed")
    |> Enum.each(fn control ->
      _ =
        resolve_owned_control(control, "rejected", %{
          "reason" => "run_terminated_before_ack"
        })
    end)
  end

  defp resolve_owned_control(control, status, result) do
    Runs.resolve_control(control, status, result,
      run_id: control.run_id,
      worker_id: control.worker_id,
      kind: control.kind
    )
  end

  defp broadcast_session(%Run{} = run, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{run.session_id}", event)
    Phoenix.PubSub.broadcast(IexCode.PubSub, "runs:session:#{run.session_id}", event)
  rescue
    _ -> :ok
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
  defp schedule_heartbeat(interval), do: Process.send_after(self(), :heartbeat, interval)

  defp schedule_research_reconciliation(interval),
    do: Process.send_after(self(), :reconcile_research_results, interval)

  defp reconcile_research_results(state) do
    _ = state.research_finalizer.reconcile(limit: @research_reconcile_limit)
    :ok
  rescue
    error ->
      Logger.warning("Research result reconciliation failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Research result reconciliation failed: #{inspect({kind, reason})}")
      :ok
  end

  defp reconcile_provider_effects(state) do
    _ = state.provider_effect.reconcile_claimed(limit: @research_reconcile_limit)
    :ok
  rescue
    error ->
      Logger.warning("Provider effect reconciliation failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Provider effect reconciliation failed: #{inspect({kind, reason})}")
      :ok
  end

  defp schedule_time_budget(%Run{id: run_id, time_budget_ms: budget_ms}, pid)
       when is_integer(budget_ms) and budget_ms >= 0 do
    Process.send_after(self(), {:run_time_budget_exceeded, run_id, pid}, budget_ms)
  end

  defp schedule_time_budget(_run, _pid), do: nil

  defp terminal_lease_ms(state) do
    max(state.lease_ms, state.cancel_grace_ms + @terminal_lease_margin_ms)
    |> min(@max_terminal_lease_ms)
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp force_queued(attrs) do
    attrs |> Map.delete("status") |> Map.delete(:status) |> Map.put(:status, "queued")
  end

  defp dag_steering_supported(%Run{execution_engine: "dag_v1"}),
    do: {:error, :dag_steering_unsupported}

  defp dag_steering_supported(%Run{}), do: :ok

  defp dag_interruption_attrs(result) do
    code =
      case result do
        {:worker_exit, _reason} -> "dag_worker_exit"
        {:error, _reason} -> "dag_runner_error"
        _other -> "dag_runner_stopped_without_terminal_parent"
      end

    %{
      error_message: "DAG execution interrupted before durable parent terminalization",
      error_details: %{"reason" => code}
    }
  end

  defp dag_preflight_attrs({:invalid_execution_manifest, :manifest_drift}) do
    %{
      error_message: "DAG manifest no longer matches its immutable digest",
      error_details: %{"reason" => "dag_manifest_drift"}
    }
  end

  defp dag_preflight_attrs(_reason) do
    %{
      error_message: "DAG execution failed its typed preflight checks",
      error_details: %{"reason" => "dag_preflight_failed"}
    }
  end

  defp default_worker_id do
    incarnation = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    "#{node()}:run-dispatcher:#{incarnation}"
  end

  defp project_terminal_task(%Run{status: status} = run)
       when status in ["completed", "failed", "cancelled", "interrupted"] do
    _ = Kanban.project_run_terminal(run.id, status, run.error_message)
    :ok
  end

  defp project_terminal_task(_run), do: :ok

  defp retry_attempt_steps(%Run{} = run) do
    {prepare_key, execute_key} = attempt_step_keys(run)
    attempt_width = if run.kind == "deep_research", do: 6, else: 2
    base_position = run.attempt * attempt_width

    base_steps = [
      %{
        key: prepare_key,
        kind: "prepare",
        title: "Validate durable run inputs",
        status: "ready",
        position: base_position
      },
      %{
        key: execute_key,
        kind: "execute",
        title: "Execute #{run.kind}",
        status: "pending",
        position: base_position + 1,
        depends_on: [prepare_key]
      }
    ]

    if run.kind == "deep_research" do
      base_steps ++ research_steps(run.attempt + 1, prepare_key, base_position + 2)
    else
      base_steps
    end
  end

  defp retry_run(%Run{} = run) do
    steps = if run.execution_engine == "dag_v1", do: [], else: retry_attempt_steps(run)

    validation_steps =
      if run.execution_engine == "dag_v1", do: persisted_manifest(run), else: steps

    with :ok <- ExecutionEngine.validate_manifest(run, validation_steps) do
      Runs.retry_run(run, steps: steps)
    end
  end

  defp initial_steps(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind") || metadata_kind(attrs)

    base_steps = [
      %{
        key: "prepare",
        kind: "prepare",
        title: "Validate durable run inputs",
        status: "ready",
        position: 0
      },
      %{
        key: "execute",
        kind: "execute",
        title: "Execute #{kind}",
        status: "pending",
        position: 1,
        depends_on: ["prepare"]
      }
    ]

    if kind == "deep_research" do
      base_steps ++ research_steps(1, "prepare", 2)
    else
      base_steps
    end
  end

  defp research_steps(attempt, prepare_key, position) do
    suffix = if attempt > 1, do: ".#{attempt}", else: ""
    plan = "research.plan#{suffix}"
    search = "research.search#{suffix}"
    fetch = "research.fetch#{suffix}"

    [
      %{
        key: plan,
        kind: "research_plan",
        title: "Plan research strategy",
        status: "pending",
        position: position,
        depends_on: [prepare_key]
      },
      %{
        key: search,
        kind: "research_search",
        title: "Federate evidence search",
        status: "pending",
        position: position + 1,
        depends_on: [plan]
      },
      %{
        key: fetch,
        kind: "research_fetch",
        title: "Fetch public sources safely",
        status: "pending",
        position: position + 2,
        depends_on: [search]
      },
      %{
        key: "research.synthesize#{suffix}",
        kind: "research_synthesize",
        title: "Synthesize cited report",
        status: "pending",
        position: position + 3,
        depends_on: [fetch]
      }
    ]
  end

  defp attempt_step_keys(%Run{attempt: 0}), do: {"prepare", "execute"}

  defp attempt_step_keys(%Run{attempt: attempt}) do
    next_attempt = attempt + 1
    {"prepare.#{next_attempt}", "execute.#{next_attempt}"}
  end

  defp prepare_claimed_run(%Run{} = run, state) do
    with :ok <- validate_relationships(run) do
      Runs.prepare_run_worker(run,
        lease_owner: state.worker_id,
        run_attempt: run.attempt,
        lease_generation: run.lease_generation
      )
    end
  end

  defp validate_relationships(%Run{} = run) do
    project = Projects.get_project!(run.project_id)
    session = Sessions.get_session!(run.session_id)

    cond do
      session.project_id != project.id -> {:error, :session_project_mismatch}
      not File.dir?(project.root_path) -> {:error, :project_root_not_found}
      true -> :ok
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_project_or_session}
  end

  defp reconcile_terminal_dag(%Run{execution_engine: "dag_v1"} = run) do
    _ = DagScheduler.reconcile_terminal_run(run)
    :ok
  end

  defp reconcile_terminal_dag(%Run{}), do: :ok

  defp apply_execution_control(state, %Run{execution_engine: "dag_v1"} = run, control, kind)
       when kind in [:pause, :resume] do
    paused? = kind == :pause

    with {:ok, _summary} <-
           DagScheduler.set_paused(run, state.worker_id, run.lease_generation, paused?),
         {:ok, _resolved} <-
           resolve_owned_control(control, "applied", %{
             "run_status" => run.status,
             "engine" => "dag_v1"
           }) do
      :ok
    else
      {:error, reason} ->
        _ = compensate_dag_pause(state, run, paused?)
        {:error, {:dag_pause_control_failed, reason}}
    end
  end

  defp apply_execution_control(_state, %Run{} = run, control, kind) do
    :ok = broadcast_run_control(run, control, kind, %{})
    signal_fleet_control(run.id, kind)
    :ok
  end

  defp compensate_dag_pause(state, run, attempted_pause?) do
    rollback_status = if attempted_pause?, do: "running", else: "paused"

    with {:ok, rolled_back} <-
           Runs.transition_run_worker(run, rollback_status, %{},
             lease_owner: state.worker_id,
             run_attempt: run.attempt,
             lease_generation: run.lease_generation
           ),
         {:ok, _summary} <-
           DagScheduler.set_paused(
             rolled_back,
             state.worker_id,
             rolled_back.lease_generation,
             not attempted_pause?
           ) do
      :ok
    end
  end
end
