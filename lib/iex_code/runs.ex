defmodule IexCode.Runs do
  @moduledoc """
  Durable persistence boundary for asynchronous coding runs.

  Status changes and events are committed before they are published. Event sequence
  allocation is performed by an atomic update of the parent run inside the same
  database transaction as the event insert, making `(run_id, sequence)` monotonic
  and unique even with concurrent SQLite writers.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias IexCode.Repo

  alias IexCode.Runs.{
    Run,
    RunApproval,
    RunArtifact,
    RunAgent,
    RunAgentControl,
    RunCommand,
    RunControl,
    RunEvent,
    ExecutionEngine,
    RunStep,
    RunStepAttempt,
    WorkspaceLock
  }

  @max_event_payload_bytes 256_000
  @max_replay_events 10_000
  @max_run_agents 64
  @default_run_control_claim_ms 60_000
  @default_terminal_lease_ms 30_000
  @max_terminal_lease_ms 300_000
  @mutable_run_agent_transition_fields MapSet.new([
                                         :desired_state,
                                         :progress,
                                         :current_task,
                                         :model_provider,
                                         :model_name,
                                         :metadata,
                                         :result,
                                         :error_message,
                                         :error_details,
                                         :started_at,
                                         :last_active_at,
                                         :completed_at
                                       ])

  @run_transitions %{
    "draft" => ~w(queued cancelled),
    "queued" => ~w(running paused completed failed cancelled interrupted),
    "running" => ~w(paused completed failed cancelled interrupted),
    "paused" => ~w(running completed failed cancelled interrupted),
    "interrupted" => ~w(queued running paused failed cancelled),
    "completed" => [],
    "failed" => [],
    "cancelled" => []
  }

  @step_transitions %{
    "pending" =>
      ~w(ready running paused waiting_approval blocked completed failed cancelled skipped interrupted),
    "ready" =>
      ~w(running paused waiting_approval blocked completed failed cancelled skipped interrupted),
    "running" => ~w(paused waiting_approval blocked completed failed cancelled interrupted),
    "paused" => ~w(ready running blocked completed failed cancelled interrupted),
    "waiting_approval" => ~w(ready running blocked failed cancelled interrupted),
    "blocked" => ~w(ready running failed cancelled skipped interrupted),
    "interrupted" => ~w(pending ready running paused blocked failed cancelled skipped),
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "skipped" => []
  }

  @command_transitions %{
    "queued" => ~w(claimed running waiting_approval completed failed cancelled interrupted),
    "claimed" => ~w(running queued waiting_approval completed failed cancelled interrupted),
    "running" => ~w(waiting_approval completed failed cancelled interrupted),
    "waiting_approval" => ~w(queued claimed running failed cancelled interrupted),
    "interrupted" => ~w(queued claimed running failed cancelled),
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "uncertain" => []
  }

  @run_agent_transitions %{
    "pending" => ~w(starting cancelled),
    "starting" => ~w(idle running paused failed cancelled interrupted),
    "idle" => ~w(running paused stopping completed failed cancelled interrupted),
    "running" => ~w(idle paused stopping completed failed cancelled interrupted),
    "paused" => ~w(idle running stopping completed failed cancelled interrupted),
    "stopping" => ~w(completed failed cancelled interrupted),
    "interrupted" => ~w(pending failed cancelled),
    "completed" => [],
    "failed" => [],
    "cancelled" => []
  }

  # Runs

  def create_run(attrs) when is_map(attrs), do: create_run_with_steps(attrs, [])

  @doc "Creates a run and its initial graph nodes in one transaction."
  def create_run_with_steps(attrs, steps) when is_map(attrs) and is_list(steps) do
    with {:ok, project_id} <- required_id(attrs, :project_id),
         {:ok, session_id} <- required_id(attrs, :session_id),
         :ok <- validate_session_project(session_id, project_id),
         :ok <- ExecutionEngine.validate_manifest(attrs, steps),
         {:ok, prepared} <- ExecutionEngine.prepare_manifest(attrs, steps) do
      create_prepared_run(attrs, prepared, project_id, session_id)
    end
  end

  defp create_prepared_run(attrs, prepared, project_id, session_id) do
    with {:ok, payload} <-
           bounded_payload(%{
             "objective" => attr(attrs, :objective),
             "execution_engine" => attr(attrs, :execution_engine) || "legacy_v1"
           }) do
      steps = prepared.steps
      request_key = attr(attrs, :request_key)

      attrs =
        attrs
        |> drop_keys([:project_id, :session_id])
        |> put_attr(:manifest_hash, prepared.manifest_hash)
        |> put_request_disposition(request_key)

      with {:ok, attrs} <-
             put_request_fingerprint(attrs, steps, project_id, session_id, request_key) do
        changeset =
          %Run{project_id: project_id, session_id: session_id}
          |> Run.create_changeset(attrs)

        cond do
          not changeset.valid? ->
            {:error, changeset}

          existing = get_run_by_request_key(session_id, request_key) ->
            existing_request_result(existing, changeset)

          true ->
            result =
              Repo.retry_on_busy(fn ->
                Repo.transaction(fn ->
                  run =
                    case Repo.insert(changeset) do
                      {:ok, run} -> run
                      {:error, changeset} -> Repo.rollback(changeset)
                    end

                  created_event =
                    insert_event_in_transaction!(run.id, "run.created", "system", payload)

                  {initial_steps, step_events} =
                    steps
                    |> Enum.with_index()
                    |> Enum.map_reduce([], fn {step_attrs, position}, events ->
                      step_attrs =
                        step_attrs
                        |> drop_keys([:run_id])
                        |> put_attr_new(:position, position)

                      changeset =
                        %RunStep{run_id: run.id}
                        |> RunStep.create_changeset(step_attrs)

                      assert_parent_step_scope!(
                        run.id,
                        Changeset.get_field(changeset, :parent_step_id)
                      )

                      step =
                        case Repo.insert(changeset) do
                          {:ok, step} -> step
                          {:error, changeset} -> Repo.rollback(changeset)
                        end

                      event =
                        insert_event_in_transaction!(run.id, "run.step_created", "system", %{
                          "step_id" => step.id,
                          "key" => step.key,
                          "status" => step.status
                        })

                      {step, [event | events]}
                    end)

                  {Repo.get!(Run, run.id), initial_steps,
                   [created_event | Enum.reverse(step_events)]}
                end)
              end)

            case result do
              {:ok, {run, initial_steps, events}} ->
                broadcast(run.id, {:run_created, run})
                Enum.each(initial_steps, &broadcast(run.id, {:run_step_created, &1}))
                Enum.each(events, &broadcast(run.id, {:run_event, &1}))
                {:ok, run}

              {:error, %Changeset{} = insert_changeset} ->
                case get_run_by_request_key(session_id, request_key) do
                  %Run{} = existing -> existing_request_result(existing, changeset)
                  nil -> {:error, insert_changeset}
                end

              {:error, reason} ->
                {:error, reason}
            end
        end
      end
    end
  end

  @request_fingerprint_fields [
    :project_id,
    :session_id,
    :request_key,
    :objective,
    :kind,
    :mode,
    :priority,
    :execution_engine,
    :manifest_hash,
    :progress,
    :token_budget,
    :cost_budget_cents,
    :time_budget_ms,
    :input_tokens,
    :output_tokens,
    :cost_cents,
    :metadata,
    :error_message,
    :error_details,
    :started_at,
    :heartbeat_at,
    :completed_at,
    :lease_owner,
    :lease_expires_at,
    :cancellation_requested_at,
    :not_before,
    :attempt,
    :lease_generation,
    :max_attempts
  ]

  @request_step_fingerprint_fields [
    :parent_step_id,
    :key,
    :kind,
    :title,
    :status,
    :position,
    :progress,
    :attempt,
    :max_attempts,
    :depends_on,
    :params,
    :handler_version,
    :effect_class,
    :replay_policy,
    :resource_spec,
    :timeout_ms,
    :result,
    :error_message,
    :error_details,
    :started_at,
    :heartbeat_at,
    :completed_at
  ]

  defp existing_request_result(%Run{} = existing, %Changeset{} = changeset) do
    requested = Changeset.apply_changes(changeset)

    if is_binary(existing.request_fingerprint) and
         existing.request_fingerprint == requested.request_fingerprint do
      {:ok, existing}
    else
      {:error, :request_key_conflict}
    end
  end

  defp put_request_fingerprint(attrs, _steps, _project_id, _session_id, request_key)
       when not is_binary(request_key) or request_key == "" do
    {:ok, attrs}
  end

  defp put_request_fingerprint(attrs, steps, project_id, session_id, _request_key) do
    preview =
      %Run{project_id: project_id, session_id: session_id}
      |> Run.create_changeset(attrs)
      |> Changeset.apply_changes()

    request =
      @request_fingerprint_fields
      |> Map.new(fn field ->
        {Atom.to_string(field), request_semantic_value(Map.get(preview, field))}
      end)
      |> Map.put("initial_status", preview.status)
      |> Map.put("steps", request_step_projections(steps, session_id))

    with {:ok, canonical} <- IexCode.Runs.DagPayload.canonical_json(request) do
      fingerprint =
        :crypto.hash(:sha256, "iex-code/run-request/v1\0" <> canonical)
        |> Base.encode16(case: :lower)

      {:ok, put_attr(attrs, :request_fingerprint, fingerprint)}
    else
      {:error, _reason} -> {:error, :invalid_request_fingerprint}
    end
  end

  defp request_step_projections(steps, run_id) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {attrs, position} ->
      attrs
      |> put_attr_new(:position, position)
      |> then(&RunStep.create_changeset(%RunStep{run_id: run_id}, &1))
      |> Changeset.apply_changes()
      |> request_step_projection()
    end)
  end

  defp request_step_projection(step) do
    Map.new(
      @request_step_fingerprint_fields,
      fn field ->
        {Atom.to_string(field), request_semantic_value(attr(step, field))}
      end
    )
  end

  defp request_semantic_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp request_semantic_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp request_semantic_value(value) when is_map(value) or is_list(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, normalized} <- Jason.decode(encoded) do
      normalized
    else
      _ -> value
    end
  end

  defp request_semantic_value(value), do: value

  defp put_request_disposition(attrs, request_key)
       when is_binary(request_key) and request_key != "" do
    metadata = attr(attrs, :metadata) || %{}
    status = attr(attrs, :status) || "queued"

    if is_map(metadata) do
      put_attr(attrs, :metadata, Map.put(metadata, "request_initial_status", to_string(status)))
    else
      attrs
    end
  end

  defp put_request_disposition(attrs, _request_key), do: attrs

  def get_run(id) when is_binary(id), do: Repo.get(Run, id)
  def get_run(_id), do: nil
  def get_run!(id), do: Repo.get!(Run, id)

  @doc "Gets the run created for one session-scoped request key."
  def get_run_by_request_key(session_id, request_key)
      when is_binary(session_id) and is_binary(request_key) and request_key != "" do
    Repo.get_by(Run, session_id: session_id, request_key: request_key)
  end

  def get_run_by_request_key(_session_id, _request_key), do: nil

  def list_runs(opts \\ [])

  def list_runs(session_id) when is_binary(session_id), do: list_runs(session_id: session_id)

  def list_runs(opts) when is_list(opts) do
    Run
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:session_id, opts[:session_id])
    |> maybe_where(:status, opts[:status])
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^bounded_limit(opts[:limit], 100, 1_000))
    |> Repo.all()
  end

  def latest_run(filter \\ [])

  def latest_run(session_id) when is_binary(session_id), do: latest_run(session_id: session_id)

  def latest_run(opts) when is_list(opts) do
    opts |> Keyword.put(:limit, 1) |> list_runs() |> List.first()
  end

  def transition_run(run_or_id, new_status, attrs \\ %{})

  def transition_run(%Run{} = run, new_status, attrs) do
    new_status = to_string(new_status)

    if terminal_run_status?(new_status) do
      finalize_unleased_run(run, new_status, attrs)
    else
      do_transition_run(run, new_status, attrs)
    end
  end

  def transition_run(id, new_status, attrs) when is_binary(id) do
    case get_run(id) do
      nil -> {:error, :not_found}
      run -> transition_run(run, new_status, attrs)
    end
  end

  @doc "Transitions a run only while the exact worker attempt and lease generation are live."
  def transition_run_worker(run_or_id, new_status, attrs \\ %{}, opts \\ [])

  def transition_run_worker(run_or_id, new_status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      new_status = to_string(new_status)

      if terminal_run_status?(new_status) do
        finalize_run_worker(run, new_status, attrs, terminal_transition_opts(new_status, opts))
      else
        do_transition_run(run, new_status, attrs, opts)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def transition_run_worker(_run_or_id, _new_status, _attrs, _opts),
    do: {:error, :invalid_worker_transition}

  @doc "Validates and returns a run only while the exact worker lease is live."
  def assert_run_worker(run_or_id, opts) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_worker_authority!(current, opts, now())
            current
          end)
        end)

      case result do
        {:ok, current} -> {:ok, current}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def assert_run_worker(_run_or_id, _opts), do: {:error, :invalid_worker_authority}

  @doc """
  Atomically finalizes a worker-owned run and its current execution graph.

  The worker authority check, legacy step terminalization (or DAG attempt/step
  terminalization), parent transition, fleet terminalization, and journal
  writes share one transaction. This prevents an expired same-lineage worker
  from changing child state before its parent write is rejected.
  """
  def finalize_run_worker(run_or_id, new_status, attrs \\ %{}, opts \\ [])

  def finalize_run_worker(run_or_id, new_status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    new_status = to_string(new_status)

    with %Run{} = run <- resolve_run(run_or_id),
         true <- new_status in ["completed", "failed", "cancelled", "interrupted"],
         :ok <- validate_worker_authority_opts(opts),
         :ok <- validate_terminal_lease_opts(opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            timestamp = now()
            assert_worker_authority!(current, opts, timestamp)

            unless transition_allowed?(@run_transitions, current.status, new_status) do
              Repo.rollback({:invalid_transition, current.status, new_status})
            end

            {steps, graph_events} =
              terminalize_worker_graph_in_transaction!(
                current,
                new_status,
                attrs,
                opts,
                timestamp
              )

            terminal_attrs = transition_attrs(new_status, attrs, timestamp)

            terminal_attrs =
              if opts[:preserve_lease] do
                terminal_attrs
                |> Map.put(:lease_owner, current.lease_owner)
                |> Map.put(
                  :lease_expires_at,
                  extended_terminal_lease_expiry(current, timestamp, opts)
                )
              else
                terminal_attrs
                |> Map.put(:lease_owner, nil)
                |> Map.put(:lease_expires_at, nil)
              end

            updated =
              current
              |> Run.changeset(terminal_attrs)
              |> update_or_rollback!()

            run_event =
              insert_event_in_transaction!(updated.id, "run.status_changed", "system", %{
                "from" => current.status,
                "to" => new_status
              })

            agent_pairs =
              terminalize_run_agents_in_transaction!(updated, new_status, %{
                error_message: updated.error_message
              })

            {updated, run_event, steps, graph_events, agent_pairs}
          end)
        end)

      publish_worker_finalization(result)
    else
      nil -> {:error, :not_found}
      false -> {:error, {:invalid_terminal_status, new_status}}
      {:error, _reason} = error -> error
    end
  end

  def finalize_run_worker(_run_or_id, _new_status, _attrs, _opts),
    do: {:error, :invalid_worker_finalization}

  defp finalize_unleased_run(run_or_id, new_status, attrs)
       when is_binary(new_status) and is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id),
         true <- terminal_run_status?(new_status) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            timestamp = now()
            assert_unleased_mutation!(current)

            unless transition_allowed?(@run_transitions, current.status, new_status) do
              Repo.rollback({:invalid_transition, current.status, new_status})
            end

            {steps, graph_events} =
              terminalize_worker_graph_in_transaction!(
                current,
                new_status,
                attrs,
                [lease_generation: current.lease_generation],
                timestamp
              )

            updated =
              current
              |> Run.changeset(
                new_status
                |> transition_attrs(attrs)
                |> Map.put(:lease_owner, nil)
                |> Map.put(:lease_expires_at, nil)
              )
              |> update_or_rollback!()

            run_event =
              insert_event_in_transaction!(updated.id, "run.status_changed", "system", %{
                "from" => current.status,
                "to" => new_status
              })

            agent_pairs =
              terminalize_run_agents_in_transaction!(updated, new_status, %{
                error_message: updated.error_message
              })

            {updated, run_event, steps, graph_events, agent_pairs}
          end)
        end)

      publish_worker_finalization(result)
    else
      nil -> {:error, :not_found}
      false -> {:error, {:invalid_terminal_status, new_status}}
    end
  end

  @doc "Atomically prepares the current legacy attempt under exact worker authority."
  def prepare_run_worker(run_or_id, opts \\ [])

  def prepare_run_worker(run_or_id, opts) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_worker_authority!(current, opts, now())

            if current.execution_engine != "legacy_v1" do
              Repo.rollback({:execution_engine_unavailable, current.execution_engine})
            end

            steps = current_attempt_run_steps(current)
            prepare = Enum.find(steps, &(&1.kind == "prepare"))
            execute = Enum.find(steps, &(&1.kind == "execute"))

            cond do
              is_nil(prepare) ->
                Repo.rollback(:missing_prepare_step)

              is_nil(execute) ->
                Repo.rollback(:missing_execute_step)

              true ->
                {running_prepare, prepare_running_event} =
                  transition_step_in_transaction!(prepare, "running", %{})

                {_completed_prepare, prepare_completed_event} =
                  transition_step_in_transaction!(running_prepare, "completed", %{})

                {running_execute, execute_running_event} =
                  transition_step_in_transaction!(execute, "running", %{})

                {running_execute,
                 [prepare_running_event, prepare_completed_event, execute_running_event]}
            end
          end)
        end)

      case result do
        {:ok, {execute, events}} ->
          Enum.each(events, &broadcast(run.id, {:run_event, &1}))
          Enum.each(current_attempt_run_steps(run), &broadcast(run.id, {:run_step_updated, &1}))
          {:ok, execute}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def prepare_run_worker(_run_or_id, _opts), do: {:error, :invalid_worker_preparation}

  @doc "Atomically marks the current legacy execute step blocked under worker authority."
  def block_run_worker(run_or_id, message, opts \\ [])

  def block_run_worker(run_or_id, message, opts) when is_binary(message) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_worker_authority!(current, opts, now())

            step =
              current
              |> current_attempt_run_steps()
              |> Enum.find(&(&1.kind == "execute" and &1.status in ["pending", "ready"]))

            case step do
              nil -> {nil, nil}
              step -> transition_step_in_transaction!(step, "blocked", %{error_message: message})
            end
          end)
        end)

      case result do
        {:ok, {nil, nil}} ->
          :ok

        {:ok, {step, event}} ->
          broadcast(run.id, {:run_step_updated, step})
          broadcast(run.id, {:run_event, event})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def block_run_worker(_run_or_id, _message, _opts), do: {:error, :invalid_worker_block}

  @doc "Atomically cancels an unleased draft/queued run, its graph, and open receipts."
  def cancel_unleased_run(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            timestamp = now()

            cond do
              current.status not in ["draft", "queued"] ->
                Repo.rollback({:invalid_transition, current.status, "cancelled"})

              active_lease?(current, timestamp) ->
                Repo.rollback(:run_still_leased)

              true ->
                cancellation_requested? = not is_nil(current.cancellation_requested_at)

                current =
                  current
                  |> Run.changeset(%{
                    cancellation_requested_at: current.cancellation_requested_at || timestamp
                  })
                  |> update_or_rollback!()

                request_event =
                  if cancellation_requested? do
                    nil
                  else
                    insert_event_in_transaction!(
                      current.id,
                      "run.cancellation_requested",
                      "user",
                      %{}
                    )
                  end

                {cancelled, controls, events, steps} = reconcile_queued_cancellation!(current)
                {cancelled, controls, Enum.reject([request_event | events], &is_nil/1), steps}
            end
          end)
        end)

      case result do
        {:ok, {cancelled, controls, events, steps}} ->
          broadcast(cancelled.id, {:run_updated, cancelled})
          Enum.each(steps, &broadcast(cancelled.id, {:run_step_updated, &1}))
          Enum.each(controls, &broadcast(cancelled.id, {:run_control_updated, &1}))
          Enum.each(events, &broadcast(cancelled.id, {:run_event, &1}))
          {:ok, cancelled}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def heartbeat_run(run_or_id, attrs \\ %{}) do
    now = now()
    attrs = Map.merge(normalize_attrs(attrs), %{heartbeat_at: now})

    update_unleased_run_with_event(run_or_id, attrs, "run.heartbeat", "worker", %{})
  end

  @doc "Persists bounded progress and its journal event in one transaction."
  def record_progress(run_or_id, percent, message, source \\ "worker")

  def record_progress(run_or_id, percent, message, source)
      when is_integer(percent) and percent >= 0 and percent <= 100 do
    case resolve_run(run_or_id) do
      %Run{status: status} = run when status in ["running", "paused"] ->
        update_unleased_run_with_event(
          run,
          %{progress: percent, heartbeat_at: now()},
          "run.progress",
          to_string(source),
          %{"percent" => percent, "message" => to_string(message)}
        )

      %Run{status: status} ->
        {:error, {:run_not_active, status}}

      nil ->
        {:error, :not_found}
    end
  end

  def record_progress(_run_or_id, _percent, _message, _source),
    do: {:error, :invalid_progress}

  @doc "Persists worker progress only while the exact run attempt and lease generation are live."
  def record_progress(run_or_id, percent, message, source, opts)
      when is_integer(percent) and percent >= 0 and percent <= 100 and is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_worker_authority_opts(opts),
         {:ok, payload} <-
           bounded_payload(%{"percent" => percent, "message" => to_string(message)}) do
      timestamp = now()
      lease_ms = positive_integer(opts[:lease_ms], 30_000)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_worker_authority!(current, opts, timestamp)

            updated =
              current
              |> Run.changeset(%{
                progress: percent,
                heartbeat_at: timestamp,
                lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond)
              })
              |> update_or_rollback!()

            event =
              insert_event_in_transaction!(
                current.id,
                "run.progress",
                to_string(source),
                payload
              )

            {updated, event}
          end)
        end)

      publish_run_update_with_events(result)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def record_progress(_run_or_id, _percent, _message, _source, _opts),
    do: {:error, :invalid_progress}

  @doc "Atomically records provider-reported token usage and checks the run token budget."
  def record_usage(run_or_id, usage, source \\ "llm")

  def record_usage(run_or_id, usage, source) when is_map(usage) do
    do_record_usage(run_or_id, usage, source, nil)
  end

  def record_usage(_run_or_id, _usage, _source), do: {:error, :invalid_usage}

  def record_usage(run_or_id, usage, source, opts) when is_map(usage) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts),
         :ok <- validate_terminal_lease_opts(opts) do
      do_record_usage(run_or_id, usage, source, opts)
    end
  end

  def record_usage(_run_or_id, _usage, _source, _opts), do: {:error, :invalid_usage}

  defp do_record_usage(run_or_id, usage, source, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      input = usage_integer(usage, [:prompt_tokens, :input_tokens])
      output = usage_integer(usage, [:completion_tokens, :output_tokens])
      total_only = usage_integer(usage, [:total_tokens])

      {input, output} =
        if input + output == 0 and total_only > 0, do: {total_only, 0}, else: {input, output}

      cost = usage_integer(usage, [:cost_cents])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            timestamp = now()

            if worker_opts do
              assert_worker_authority!(current, worker_opts, timestamp)
            else
              assert_unleased_mutation!(current)
            end

            new_input = current.input_tokens + input
            new_output = current.output_tokens + output
            total = new_input + new_output
            new_cost = current.cost_cents + cost

            exhaustion =
              cond do
                is_integer(current.token_budget) and total > current.token_budget ->
                  %{budget: "tokens", limit: current.token_budget, actual: total}

                is_integer(current.cost_budget_cents) and new_cost > current.cost_budget_cents ->
                  %{budget: "cost_cents", limit: current.cost_budget_cents, actual: new_cost}

                true ->
                  nil
              end

            terminalized? = not is_nil(exhaustion) and current.status in ["running", "paused"]

            failure_attrs = %{
              error_message: usage_budget_message(exhaustion),
              error_details: %{
                "reason" => "budget_exhausted",
                "budget" => exhaustion && exhaustion.budget,
                "limit" => exhaustion && exhaustion.limit,
                "actual" => exhaustion && exhaustion.actual
              }
            }

            {steps, graph_events} =
              if terminalized? do
                terminalize_worker_graph_in_transaction!(
                  current,
                  "failed",
                  failure_attrs,
                  [lease_generation: current.lease_generation],
                  timestamp
                )
              else
                {[], []}
              end

            usage_attrs = %{
              input_tokens: new_input,
              output_tokens: new_output,
              cost_cents: new_cost
            }

            usage_attrs =
              if terminalized? do
                Map.merge(usage_attrs, %{
                  status: "failed",
                  completed_at: timestamp
                })
                |> Map.merge(failure_attrs)
                |> maybe_extend_terminal_lease(current, timestamp, worker_opts || [])
              else
                usage_attrs
              end

            updated = current |> Run.changeset(usage_attrs) |> Repo.update!()

            agent_pairs =
              if terminalized? do
                terminalize_run_agents_in_transaction!(updated, "failed", failure_attrs)
              else
                []
              end

            usage_event =
              insert_event_in_transaction!(run.id, "run.usage_recorded", to_string(source), %{
                "input_tokens" => input,
                "output_tokens" => output,
                "cost_cents" => cost,
                "total_tokens" => total,
                "token_budget" => current.token_budget,
                "cost_budget_cents" => current.cost_budget_cents
              })

            budget_event =
              if exhaustion do
                insert_event_in_transaction!(run.id, "run.budget_exhausted", "budget", %{
                  "budget" => exhaustion.budget,
                  "limit" => exhaustion.limit,
                  "actual" => exhaustion.actual
                })
              end

            status_event =
              if updated.status != current.status do
                insert_event_in_transaction!(run.id, "run.status_changed", "budget", %{
                  "from" => current.status,
                  "to" => updated.status
                })
              end

            {updated, usage_event, budget_event, status_event, exhaustion, steps, graph_events,
             agent_pairs}
          end)
        end)

      case result do
        {:ok,
         {updated, usage_event, budget_event, status_event, exhaustion, steps, graph_events,
          agent_pairs}} ->
          broadcast(updated.id, {:run_updated, updated})
          publish_terminalized_steps(updated.id, steps, graph_events)
          publish_terminalized_agents(updated.id, agent_pairs)
          broadcast(updated.id, {:run_event, usage_event})
          if budget_event, do: broadcast(updated.id, {:run_event, budget_event})
          if status_event, do: broadcast(updated.id, {:run_event, status_event})

          case exhaustion do
            %{budget: "tokens"} -> {:error, {:token_budget_exhausted, updated}}
            %{budget: "cost_cents"} -> {:error, {:cost_budget_exhausted, updated}}
            nil -> {:ok, updated}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Atomically claims the highest-priority due run for `lease_owner`.

  A project may have at most one active (`running` or `paused`) run. The
  exclusivity predicate is part of the conditional update, so competing
  dispatchers cannot both claim runs for the same project.
  """
  def claim_next_run(lease_owner, opts \\ [])

  def claim_next_run(lease_owner, opts) when is_binary(lease_owner) and is_list(opts) do
    lease_ms = positive_integer(opts[:lease_ms], 30_000)
    excluded_project_ids = Enum.filter(opts[:exclude_project_ids] || [], &is_binary/1)
    execution_engines = dispatchable_execution_engines(opts[:execution_engines])
    now = now()
    lease_expires_at = DateTime.add(now, lease_ms, :millisecond)

    if execution_engines == [] do
      :none
    else
      do_claim_next_run(
        lease_owner,
        lease_expires_at,
        now,
        excluded_project_ids,
        execution_engines
      )
    end
  end

  def claim_next_run(_lease_owner, _opts), do: {:error, :invalid_lease_owner}

  defp do_claim_next_run(
         lease_owner,
         lease_expires_at,
         now,
         excluded_project_ids,
         execution_engines
       ) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          active_projects =
            from(active in Run,
              where:
                active.status in ["running", "paused"] or
                  (not is_nil(active.lease_owner) and
                     (is_nil(active.lease_expires_at) or active.lease_expires_at > ^now)),
              select: active.project_id
            )

          candidate_query =
            from(run in Run,
              where: run.status == "queued",
              where: run.execution_engine in ^execution_engines,
              where: run.attempt < run.max_attempts,
              where: is_nil(run.cancellation_requested_at),
              where: is_nil(run.not_before) or run.not_before <= ^now,
              where: run.project_id not in subquery(active_projects),
              order_by: [
                asc:
                  fragment(
                    "CASE WHEN ? = 'critical' THEN 0 WHEN ? = 'high' THEN 1 WHEN ? = 'normal' THEN 2 ELSE 3 END",
                    run.priority,
                    run.priority,
                    run.priority
                  ),
                asc: run.inserted_at,
                asc: run.id
              ],
              limit: 1
            )

          candidate_query =
            if excluded_project_ids == [] do
              candidate_query
            else
              from(run in candidate_query, where: run.project_id not in ^excluded_project_ids)
            end

          case Repo.one(candidate_query) do
            nil ->
              nil

            candidate ->
              {updated_count, _} =
                from(run in Run,
                  where: run.id == ^candidate.id,
                  where: run.status == "queued",
                  where: run.execution_engine in ^execution_engines,
                  where: run.attempt < run.max_attempts,
                  where: is_nil(run.cancellation_requested_at),
                  where: run.project_id not in subquery(active_projects)
                )
                |> Repo.update_all(
                  set: [
                    status: "running",
                    lease_owner: lease_owner,
                    lease_expires_at: lease_expires_at,
                    heartbeat_at: now,
                    started_at: candidate.started_at || now,
                    updated_at: now
                  ],
                  inc: [attempt: 1, lease_generation: 1]
                )

              if updated_count == 1 do
                claimed = Repo.get!(Run, candidate.id)

                event =
                  insert_event_in_transaction!(claimed.id, "run.claimed", lease_owner, %{
                    "attempt" => claimed.attempt,
                    "lease_expires_at" => DateTime.to_iso8601(lease_expires_at)
                  })

                {claimed, event}
              else
                nil
              end
          end
        end)
      end)

    case result do
      {:ok, nil} ->
        :none

      {:ok, {run, event}} ->
        broadcast(run.id, {:run_updated, run})
        broadcast(run.id, {:run_event, event})
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Rejects owner-only lease renewal; worker attempt and generation are required."
  def renew_lease(run_id, lease_owner)
      when is_binary(run_id) and is_binary(lease_owner),
      do: {:error, :worker_authority_required}

  def renew_lease(run_id, lease_owner, _lease_ms)
      when is_binary(run_id) and is_binary(lease_owner),
      do: {:error, :worker_authority_required}

  @doc "Renews a lease only for the exact claimed run attempt and lease generation."
  def renew_lease(run_id, lease_owner, lease_ms, opts)
      when is_binary(run_id) and is_binary(lease_owner) and is_list(opts) do
    opts = Keyword.put(opts, :lease_owner, lease_owner)

    with :ok <- validate_worker_authority_opts(opts) do
      do_renew_lease(run_id, lease_owner, lease_ms, opts)
    end
  end

  defp do_renew_lease(run_id, lease_owner, lease_ms, worker_opts) do
    now = now()
    lease_expires_at = DateTime.add(now, positive_integer(lease_ms, 30_000), :millisecond)

    query =
      from(run in Run,
        where: run.id == ^run_id,
        where: run.status in ["running", "paused"],
        where: run.lease_owner == ^lease_owner,
        where: run.lease_expires_at > ^now,
        where: is_nil(run.cancellation_requested_at)
      )

    query = maybe_worker_authority_query(query, worker_opts)

    {count, _} =
      query
      |> Repo.update_all(
        set: [heartbeat_at: now, lease_expires_at: lease_expires_at, updated_at: now]
      )

    case count do
      1 ->
        run = Repo.get!(Run, run_id)
        broadcast(run.id, {:run_updated, run})
        {:ok, run}

      0 ->
        {:error, :lease_not_owned}
    end
  end

  @doc "Rejects owner-only lease release; worker attempt and generation are required."
  def release_lease(run_id, lease_owner) when is_binary(run_id) and is_binary(lease_owner) do
    {:error, :worker_authority_required}
  end

  @doc "Releases a lease only for the exact claimed run attempt and lease generation."
  def release_lease(run_id, lease_owner, opts)
      when is_binary(run_id) and is_binary(lease_owner) and is_list(opts) do
    opts = Keyword.put(opts, :lease_owner, lease_owner)

    with :ok <- validate_worker_authority_opts(opts) do
      do_release_lease(run_id, lease_owner, opts)
    end
  end

  defp do_release_lease(run_id, lease_owner, worker_opts) do
    now = now()

    query =
      from(run in Run,
        where: run.id == ^run_id,
        where: run.lease_owner == ^lease_owner
      )

    query = maybe_worker_authority_query(query, worker_opts)

    {count, _} =
      query
      |> Repo.update_all(
        set: [lease_owner: nil, lease_expires_at: nil, heartbeat_at: now, updated_at: now]
      )

    case count do
      1 ->
        run = Repo.get!(Run, run_id)
        broadcast(run.id, {:run_updated, run})
        {:ok, run}

      0 ->
        {:error, :lease_not_owned}
    end
  end

  @doc "Marks active runs with missing/expired leases interrupted and emits events."
  def reconcile_orphaned_runs(opts \\ []) when is_list(opts) do
    before = opts[:expired_before] || now()
    lease_owner = opts[:lease_owner]

    query =
      from(run in Run,
        where: run.status in ["running", "paused"],
        where: is_nil(run.lease_expires_at) or run.lease_expires_at <= ^before,
        order_by: [asc: run.inserted_at]
      )

    query =
      if is_binary(lease_owner) do
        from(run in query, where: run.lease_owner == ^lease_owner)
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.reduce([], fn run, interrupted ->
      case interrupt_if_orphaned(run.id, before) do
        {:ok, updated} -> [updated | interrupted]
        _ -> interrupted
      end
    end)
    |> Enum.reverse()
  end

  @doc "Retries a terminal/interrupted run and optionally appends next-attempt steps atomically."
  def retry_run(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      steps = opts[:steps] || []

      with :ok <- ExecutionEngine.validate_manifest(run, retry_validation_steps(run, steps)),
           {:ok, retry_manifest} <- prepare_retry_manifest(run, steps) do
        result =
          Repo.retry_on_busy(fn ->
            Repo.transaction(fn ->
              current = Repo.get!(Run, run.id)

              case validate_retry_manifest_in_transaction(current, retry_manifest) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              cond do
                active_lease?(current, now()) ->
                  Repo.rollback(:run_still_leased)

                current.status not in ["failed", "cancelled", "interrupted"] ->
                  Repo.rollback({:invalid_transition, current.status, "queued"})

                current.attempt >= current.max_attempts ->
                  Repo.rollback(:attempts_exhausted)

                ambiguous_command_effect?(current.id) ->
                  Repo.rollback(:command_effect_requires_review)

                true ->
                  {superseded_controls, control_events} =
                    supersede_controls_in_transaction!(current.id, %{}, "run_retried")

                  approval_pairs =
                    cancel_pending_approvals_in_transaction!(current, "run_retried")

                  cancelled_approvals = Enum.map(approval_pairs, &elem(&1, 0))
                  approval_events = Enum.map(approval_pairs, &elem(&1, 1))

                  agent_pairs =
                    terminalize_run_agents_in_transaction!(
                      current,
                      "interrupted",
                      %{error_message: "Run retried after prior attempt ended"}
                    )

                  terminalized_agents = Enum.map(agent_pairs, &elem(&1, 0))

                  terminalized_agent_controls =
                    agent_pairs
                    |> Enum.flat_map(&elem(&1, 2))
                    |> Enum.map(&elem(&1, 0))

                  agent_events =
                    Enum.flat_map(agent_pairs, fn {_agent, event, control_pairs} ->
                      Enum.map(control_pairs, &elem(&1, 1)) ++ [event]
                    end)

                  retry_attrs = %{
                    status: "queued",
                    progress: 0,
                    lease_owner: nil,
                    lease_expires_at: nil,
                    heartbeat_at: nil,
                    completed_at: nil,
                    cancellation_requested_at: nil,
                    error_message: nil,
                    error_details: nil
                  }

                  updated =
                    case current |> Run.changeset(retry_attrs) |> Repo.update() do
                      {:ok, updated} -> updated
                      {:error, changeset} -> Repo.rollback(changeset)
                    end

                  retry_event =
                    insert_event_in_transaction!(updated.id, "run.retried", "system", %{
                      "attempt" => updated.attempt,
                      "max_attempts" => updated.max_attempts
                    })

                  {reset_steps, reset_events} = reset_dag_steps_for_retry!(updated)

                  {initial_steps, step_events} =
                    insert_initial_steps!(updated.id, retry_manifest.insert_steps)

                  {Repo.get!(Run, updated.id), initial_steps, reset_steps, superseded_controls,
                   cancelled_approvals, terminalized_agents, terminalized_agent_controls,
                   control_events ++
                     approval_events ++
                     agent_events ++
                     [retry_event | reset_events ++ step_events]}
              end
            end)
          end)

        case result do
          {:ok,
           {updated, initial_steps, reset_steps, superseded_controls, cancelled_approvals,
            terminalized_agents, terminalized_agent_controls, events}} ->
            broadcast(updated.id, {:run_updated, updated})
            Enum.each(initial_steps, &broadcast(updated.id, {:run_step_created, &1}))
            Enum.each(reset_steps, &broadcast(updated.id, {:run_step_updated, &1}))
            Enum.each(superseded_controls, &broadcast(updated.id, {:run_control_updated, &1}))

            Enum.each(
              cancelled_approvals,
              &broadcast(updated.id, {:run_approval_decided, &1})
            )

            Enum.each(terminalized_agents, &broadcast(updated.id, {:run_agent_updated, &1}))

            Enum.each(
              terminalized_agent_controls,
              &broadcast(updated.id, {:run_agent_control_updated, &1})
            )

            Enum.each(events, &broadcast(updated.id, {:run_event, &1}))
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Persists cooperative cancellation intent without racing the dispatcher."
  def request_cancellation(run_or_id, source \\ "user") do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_event_label("run.cancellation_requested", source) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)

            if current.status not in ["queued", "running", "paused"] do
              Repo.rollback({:invalid_transition, current.status, "cancellation_requested"})
            end

            case current.cancellation_requested_at do
              %DateTime{} ->
                {current, nil}

              nil ->
                updated =
                  current
                  |> Run.changeset(%{cancellation_requested_at: now()})
                  |> update_or_rollback!()

                event =
                  insert_event_in_transaction!(
                    updated.id,
                    "run.cancellation_requested",
                    to_string(source),
                    %{}
                  )

                {updated, event}
            end
          end)
        end)

      case result do
        {:ok, {updated, nil}} ->
          {:ok, updated}

        {:ok, {updated, event}} ->
          broadcast(updated.id, {:run_updated, updated})
          broadcast(updated.id, {:run_event, event})
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def subscribe_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, session_topic(session_id))
  end

  # Steps

  def create_step(run_or_id, attrs) when is_map(attrs),
    do: do_create_step(run_or_id, attrs, nil)

  @doc "Creates one legacy step only while the exact parent worker lease is live."
  def create_step_worker(run_or_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts) do
      do_create_step(run_or_id, attrs, opts)
    end
  end

  def create_step_worker(_run_or_id, _attrs, _opts), do: {:error, :invalid_worker_step_creation}

  defp do_create_step(run_or_id, attrs, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs = drop_keys(attrs, [:run_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current_run = Repo.get(Run, run.id)

            if current_run && worker_opts do
              assert_worker_authority!(current_run, worker_opts, now())
            else
              if current_run, do: assert_unleased_mutation!(current_run)
            end

            cond do
              is_nil(current_run) ->
                Repo.rollback(:not_found)

              current_run.execution_engine == "dag_v1" ->
                Repo.rollback(:dag_manifest_immutable)

              true ->
                changeset =
                  %RunStep{run_id: current_run.id}
                  |> RunStep.create_changeset(attrs)

                assert_parent_step_scope!(
                  current_run.id,
                  Changeset.get_field(changeset, :parent_step_id)
                )

                step =
                  case Repo.insert(changeset) do
                    {:ok, step} -> step
                    {:error, changeset} -> Repo.rollback(changeset)
                  end

                event =
                  insert_event_in_transaction!(current_run.id, "run.step_created", "system", %{
                    "step_id" => step.id,
                    "key" => step.key,
                    "status" => step.status
                  })

                {step, event}
            end
          end)
        end)

      case result do
        {:ok, {step, event}} ->
          broadcast(run.id, {:run_step_created, step})
          broadcast(run.id, {:run_event, event})
          {:ok, step}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_step(id) when is_binary(id), do: Repo.get(RunStep, id)
  def get_step(_id), do: nil
  def get_step!(id), do: Repo.get!(RunStep, id)

  def list_steps(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunStep
      |> where([s], s.run_id == ^run.id)
      |> order_by([s], asc: s.position, asc: s.inserted_at, asc: s.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  def transition_step(step_or_id, new_status, attrs \\ %{})

  def transition_step(%RunStep{} = step, new_status, attrs),
    do: do_transition_step(step, to_string(new_status), attrs, nil)

  def transition_step(id, new_status, attrs) when is_binary(id) do
    case get_step(id) do
      nil -> {:error, :not_found}
      step -> do_transition_step(step, to_string(new_status), attrs, nil)
    end
  end

  @doc "Transitions one step only while the exact parent worker lease is live."
  def transition_step_worker(step_or_id, new_status, attrs \\ %{}, opts \\ [])

  def transition_step_worker(step_or_id, new_status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with %RunStep{} = step <- resolve_step(step_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      do_transition_step(step, to_string(new_status), attrs, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def transition_step_worker(_step_or_id, _new_status, _attrs, _opts),
    do: {:error, :invalid_worker_step_transition}

  # Events

  def append_event(run_or_id, type, payload \\ %{}, source \\ "system"),
    do: do_append_event(run_or_id, type, payload, source, nil)

  @doc "Appends an event only while the exact parent worker lease is live."
  def append_event_worker(run_or_id, type, payload, source, opts)
      when is_map(payload) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts) do
      do_append_event(run_or_id, type, payload, source, opts)
    end
  end

  def append_event_worker(_run_or_id, _type, _payload, _source, _opts),
    do: {:error, :invalid_worker_event}

  defp do_append_event(run_or_id, type, payload, source, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(payload),
         :ok <- validate_event_label(type, source) do
      transaction_result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)

            if worker_opts do
              if worker_opts[:allow_terminal] do
                assert_owned_worker_lineage!(current, worker_opts, now())
              else
                assert_worker_authority!(current, worker_opts, now())
              end
            else
              assert_unleased_mutation!(current)
            end

            {1, _} =
              from(r in Run, where: r.id == ^current.id)
              |> Repo.update_all(inc: [event_sequence: 1])

            sequence =
              from(r in Run, where: r.id == ^current.id, select: r.event_sequence)
              |> Repo.one!()

            %RunEvent{run_id: current.id}
            |> RunEvent.changeset(%{
              sequence: sequence,
              type: to_string(type),
              source: to_string(source),
              payload: payload,
              occurred_at: now()
            })
            |> Repo.insert!()
          end)
        end)

      case transaction_result do
        {:ok, event} ->
          broadcast(run.id, {:run_event, event})
          {:ok, event}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def list_events(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      after_sequence = nonnegative(opts[:after_sequence], 0)
      limit = bounded_limit(opts[:limit], 500, @max_replay_events)

      RunEvent
      |> where([e], e.run_id == ^run.id and e.sequence > ^after_sequence)
      |> maybe_where(:type, opts[:type])
      |> order_by([e], asc: e.sequence)
      |> limit(^limit)
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc """
  Returns the newest bounded window of a run journal in chronological order.

  The database query orders newest-first so the limit applies to the tail,
  then the result is reversed for rendering and replay consumers. Use
  `list_events/2` or `replay_events/3` for forward cursor traversal.
  """
  def list_latest_events(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      limit = bounded_limit(opts[:limit], 500, @max_replay_events)

      RunEvent
      |> where([e], e.run_id == ^run.id)
      |> maybe_where(:type, opts[:type])
      |> order_by([e], desc: e.sequence)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
    else
      nil -> []
    end
  end

  def latest_event(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunEvent
      |> where([e], e.run_id == ^run.id)
      |> order_by([e], desc: e.sequence)
      |> limit(1)
      |> Repo.one()
    else
      nil -> nil
    end
  end

  def replay_events(run_or_id, from_sequence \\ 1, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      from_sequence = max(nonnegative(from_sequence, 1), 1)
      to_sequence = opts[:to_sequence]
      limit = bounded_limit(opts[:limit], @max_replay_events, @max_replay_events)

      query =
        from(e in RunEvent,
          where: e.run_id == ^run.id and e.sequence >= ^from_sequence,
          order_by: [asc: e.sequence],
          limit: ^limit
        )

      query =
        if is_integer(to_sequence) and to_sequence >= from_sequence do
          from(e in query, where: e.sequence <= ^to_sequence)
        else
          query
        end

      Repo.all(query)
    else
      nil -> []
    end
  end

  def subscribe(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Phoenix.PubSub.subscribe(IexCode.PubSub, topic(run.id))
    else
      nil -> {:error, :not_found}
    end
  end

  # Durable run controls

  @doc "Enqueues a run-scoped control exactly once and appends its journal event atomically."
  def enqueue_control(run_or_id, idempotency_key, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(attr(attrs, :payload) || %{}),
         :ok <- reject_secret_shaped_control_payload(payload) do
      idempotency_key = to_string(idempotency_key)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current_run = Repo.get!(Run, run.id)

            case Repo.get_by(RunControl,
                   run_id: current_run.id,
                   idempotency_key: idempotency_key
                 ) do
              %RunControl{} = existing ->
                if run_control_semantically_equal?(existing, current_run, attrs, payload) do
                  {existing, nil}
                else
                  Repo.rollback(:idempotency_conflict)
                end

              nil ->
                case validate_run_control_target(current_run) do
                  :ok -> :ok
                  {:error, reason} -> Repo.rollback(reason)
                end

                {1, _} =
                  from(current in Run, where: current.id == ^current_run.id)
                  |> Repo.update_all(inc: [control_sequence: 1])

                sequence =
                  from(current in Run,
                    where: current.id == ^current_run.id,
                    select: current.control_sequence
                  )
                  |> Repo.one!()

                control_attrs =
                  attrs
                  |> drop_keys([
                    :run_id,
                    :idempotency_key,
                    :sequence,
                    :target_attempt,
                    :target_generation,
                    :status,
                    :payload,
                    :worker_id,
                    :claim_generation,
                    :claimed_at,
                    :claim_expires_at,
                    :applied_at,
                    :result
                  ])
                  |> put_attr(:idempotency_key, idempotency_key)
                  |> put_attr(:sequence, sequence)
                  |> put_attr(:target_attempt, current_run.attempt)
                  |> put_attr(:target_generation, current_run.lease_generation)
                  |> put_attr(:status, "pending")
                  |> put_attr(:payload, payload)

                control =
                  case %RunControl{run_id: current_run.id}
                       |> RunControl.changeset(control_attrs)
                       |> Repo.insert() do
                    {:ok, control} -> control
                    {:error, changeset} -> Repo.rollback(changeset)
                  end

                event =
                  insert_event_in_transaction!(
                    current_run.id,
                    "run.control_enqueued",
                    "control",
                    %{
                      "control_id" => control.id,
                      "control_sequence" => control.sequence,
                      "kind" => control.kind,
                      "target_attempt" => control.target_attempt,
                      "target_generation" => control.target_generation,
                      "requested_by" => control.requested_by
                    }
                  )

                {control, event}
            end
          end)
        end)

      case result do
        {:ok, {control, nil}} ->
          {:ok, control}

        {:ok, {control, event}} ->
          broadcast(run.id, {:run_control_enqueued, control})
          broadcast(run.id, {:run_event, event})
          {:ok, control}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_control(id) when is_binary(id), do: Repo.get(RunControl, id)
  def get_control(_id), do: nil

  def get_control_by_idempotency_key(run_or_id, key) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Repo.get_by(RunControl, run_id: run.id, idempotency_key: to_string(key))
    else
      nil -> nil
    end
  end

  def list_controls(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunControl
      |> where([control], control.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> maybe_where(:kind, opts[:kind])
      |> order_by([control], asc: control.sequence)
      |> limit(^bounded_limit(opts[:limit], 200, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc "Supersedes every pending/claimed control owned by a dispatcher identity."
  def supersede_claimed_controls(worker_id, reason)
      when is_binary(worker_id) and worker_id != "" and is_binary(reason) do
    supersede_controls(%{status: "claimed", worker_id: worker_id}, reason)
  end

  @doc "Supersedes every non-terminal control for one run."
  def supersede_open_controls(run_or_id, reason) when is_binary(reason) do
    with %Run{} = run <- resolve_run(run_or_id) do
      supersede_controls(%{run_id: run.id}, reason)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Reclaims one expired claimed control under the current run generation."
  def reclaim_expired_control(control_or_id, worker_id, opts \\ [])

  def reclaim_expired_control(control_or_id, worker_id, opts)
      when is_binary(worker_id) and worker_id != "" and is_list(opts) do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    cutoff = Keyword.get(opts, :expired_before, now())
    claim_ms = positive_integer(opts[:claim_ms], @default_run_control_claim_ms)

    if is_struct(cutoff, DateTime) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get(RunControl, control_id)

            if is_nil(current), do: Repo.rollback(:not_found)

            run = Repo.get!(Run, current.run_id)
            assert_control_worker_authority!(run, worker_id, now())

            cond do
              current.status != "claimed" ->
                Repo.rollback({:invalid_transition, current.status, "claimed"})

              is_nil(current.claim_expires_at) or
                  DateTime.compare(current.claim_expires_at, cutoff) == :gt ->
                Repo.rollback(:control_claim_active)

              current.target_attempt != run.attempt or
                  current.target_generation != run.lease_generation ->
                Repo.rollback(:control_target_stale)

              run.status in ["completed", "failed", "cancelled"] ->
                Repo.rollback({:run_not_controllable, run.status})

              true ->
                claimed_at = now()

                reclaimed =
                  current
                  |> RunControl.changeset(%{
                    worker_id: worker_id,
                    claim_generation: run.lease_generation,
                    claimed_at: claimed_at,
                    claim_expires_at: control_claim_expiry(claimed_at, claim_ms)
                  })
                  |> update_or_rollback!()

                event =
                  insert_event_in_transaction!(run.id, "run.control_reclaimed", "control", %{
                    "control_id" => reclaimed.id,
                    "control_sequence" => reclaimed.sequence,
                    "kind" => reclaimed.kind,
                    "worker_id" => worker_id,
                    "claim_generation" => reclaimed.claim_generation,
                    "claim_expires_at" => DateTime.to_iso8601(reclaimed.claim_expires_at)
                  })

                {reclaimed, event}
            end
          end)
        end)

      case result do
        {:ok, {control, event}} ->
          broadcast(control.run_id, {:run_control_updated, control})
          broadcast(control.run_id, {:run_event, event})
          {:ok, control}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_expiry}
    end
  end

  def reclaim_expired_control(_control_or_id, _worker_id, _opts),
    do: {:error, :invalid_worker_id}

  @doc "Reconciles stale, expired, cancelled, and terminal open run controls."
  def reconcile_run_controls(opts \\ [])

  def reconcile_run_controls(opts) when is_list(opts) do
    cutoff = Keyword.get(opts, :expired_before, now())
    run_id = opts[:run_id]
    worker_id = opts[:worker_id]
    claim_ms = positive_integer(opts[:claim_ms], @default_run_control_claim_ms)
    limit = bounded_limit(opts[:limit], 500, 2_000)

    if is_struct(cutoff, DateTime) and (is_nil(run_id) or is_binary(run_id)) and
         (is_nil(worker_id) or (is_binary(worker_id) and worker_id != "")) do
      run_ids = control_reconciliation_run_ids(run_id, cutoff, worker_id, limit)

      Enum.map(run_ids, fn id ->
        {id, reconcile_run_controls_for_run(id, cutoff, worker_id, claim_ms)}
      end)
    else
      []
    end
  end

  def reconcile_run_controls(_opts), do: []

  @doc "Claims the next pending control for a run using a conditional state update."
  def claim_next_control(run_or_id, worker_id, opts \\ [])

  def claim_next_control(run_or_id, worker_id, opts)
      when is_binary(worker_id) and worker_id != "" and is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      claim_ms = positive_integer(opts[:claim_ms], @default_run_control_claim_ms)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current_run = Repo.get!(Run, run.id)

            case validate_run_control_target(current_run) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            assert_control_worker_authority!(current_run, worker_id, now())

            candidate =
              RunControl
              |> where(
                [control],
                control.run_id == ^run.id and control.status == "pending" and
                  control.target_attempt == ^current_run.attempt and
                  control.target_generation == ^current_run.lease_generation
              )
              |> order_by([control], asc: control.sequence)
              |> limit(1)
              |> Repo.one()

            case candidate do
              nil ->
                nil

              candidate ->
                claimed_at = now()
                claim_expires_at = control_claim_expiry(claimed_at, claim_ms)

                {count, _} =
                  from(control in RunControl,
                    where: control.id == ^candidate.id and control.status == "pending"
                  )
                  |> Repo.update_all(
                    set: [
                      status: "claimed",
                      worker_id: worker_id,
                      claim_generation: current_run.lease_generation,
                      claimed_at: claimed_at,
                      claim_expires_at: claim_expires_at,
                      updated_at: claimed_at
                    ]
                  )

                if count == 1 do
                  claimed = Repo.get!(RunControl, candidate.id)

                  event =
                    insert_event_in_transaction!(run.id, "run.control_claimed", "control", %{
                      "control_id" => claimed.id,
                      "control_sequence" => claimed.sequence,
                      "kind" => claimed.kind,
                      "worker_id" => worker_id,
                      "claim_generation" => claimed.claim_generation,
                      "claim_expires_at" => DateTime.to_iso8601(claimed.claim_expires_at)
                    })

                  {claimed, event}
                else
                  Repo.rollback(:claim_race)
                end
            end
          end)
        end)

      case result do
        {:ok, nil} ->
          :none

        {:ok, {control, event}} ->
          broadcast(run.id, {:run_control_updated, control})
          broadcast(run.id, {:run_event, event})
          {:ok, control}

        {:error, :claim_race} ->
          claim_next_control(run, worker_id, opts)

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def claim_next_control(_run_or_id, _worker_id, _opts), do: {:error, :invalid_worker_id}

  @doc "Claims one exact pending control without consuming another caller's request."
  def claim_control(control_or_id, worker_id, opts \\ [])

  def claim_control(control_or_id, worker_id, opts)
      when is_binary(worker_id) and worker_id != "" and is_list(opts) do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    claim_ms = positive_integer(opts[:claim_ms], @default_run_control_claim_ms)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          case Repo.get(RunControl, control_id) do
            nil ->
              Repo.rollback(:not_found)

            %RunControl{status: "pending"} = current ->
              run = Repo.get!(Run, current.run_id)
              assert_control_worker_authority!(run, worker_id, now())

              case validate_run_control_target(run) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              if current.target_attempt != run.attempt or
                   current.target_generation != run.lease_generation do
                Repo.rollback(:control_target_stale)
              end

              claimed_at = now()
              claim_expires_at = control_claim_expiry(claimed_at, claim_ms)

              {count, _} =
                from(control in RunControl,
                  where: control.id == ^current.id and control.status == "pending"
                )
                |> Repo.update_all(
                  set: [
                    status: "claimed",
                    worker_id: worker_id,
                    claim_generation: run.lease_generation,
                    claimed_at: claimed_at,
                    claim_expires_at: claim_expires_at,
                    updated_at: claimed_at
                  ]
                )

              if count == 1 do
                claimed = Repo.get!(RunControl, current.id)

                event =
                  insert_event_in_transaction!(
                    claimed.run_id,
                    "run.control_claimed",
                    "control",
                    %{
                      "control_id" => claimed.id,
                      "control_sequence" => claimed.sequence,
                      "kind" => claimed.kind,
                      "worker_id" => worker_id,
                      "claim_generation" => claimed.claim_generation,
                      "claim_expires_at" => DateTime.to_iso8601(claimed.claim_expires_at)
                    }
                  )

                {claimed, event}
              else
                Repo.rollback(:claim_race)
              end

            %RunControl{
              status: "claimed",
              worker_id: ^worker_id,
              claim_expires_at: %DateTime{} = expires_at
            } = current ->
              run = Repo.get!(Run, current.run_id)
              assert_control_worker_authority!(run, worker_id, now())

              if current.target_attempt == run.attempt and
                   current.target_generation == run.lease_generation and
                   current.claim_generation == run.lease_generation and
                   DateTime.compare(expires_at, now()) == :gt do
                {current, nil}
              else
                Repo.rollback(:control_claim_expired)
              end

            %RunControl{} = current ->
              Repo.rollback({:invalid_transition, current.status, "claimed"})
          end
        end)
      end)

    case result do
      {:ok, {control, nil}} ->
        {:ok, control}

      {:ok, {control, event}} ->
        broadcast(control.run_id, {:run_control_updated, control})
        broadcast(control.run_id, {:run_event, event})
        {:ok, control}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_control(_control_or_id, _worker_id, _opts), do: {:error, :invalid_worker_id}

  @doc "Atomically applies a claimed legacy pause/resume to parent, active step, and receipt."
  def apply_claimed_legacy_control(control_or_id, new_status, opts \\ [])

  def apply_claimed_legacy_control(control_or_id, new_status, opts)
      when new_status in ["paused", "running"] and is_list(opts) do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    with :ok <- validate_worker_authority_opts(opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            control = Repo.get(RunControl, control_id)
            if is_nil(control), do: Repo.rollback(:not_found)

            run = Repo.get!(Run, control.run_id)
            timestamp = now()
            assert_worker_authority!(run, opts, timestamp)

            kind = if new_status == "paused", do: "pause", else: "resume"

            cond do
              run.execution_engine != "legacy_v1" ->
                Repo.rollback({:execution_engine_mismatch, run.execution_engine})

              control.status != "claimed" ->
                Repo.rollback({:invalid_transition, control.status, "applied"})

              control.worker_id != opts[:lease_owner] or control.kind != kind ->
                Repo.rollback(:control_scope_mismatch)

              control.target_attempt != run.attempt or
                control.target_generation != run.lease_generation or
                  control.claim_generation != run.lease_generation ->
                Repo.rollback(:control_target_stale)

              is_nil(control.claim_expires_at) or
                  DateTime.compare(control.claim_expires_at, timestamp) != :gt ->
                Repo.rollback(:control_claim_expired)

              not transition_allowed?(@run_transitions, run.status, new_status) ->
                Repo.rollback({:invalid_transition, run.status, new_status})

              true ->
                updated_run =
                  run
                  |> Run.changeset(transition_attrs(new_status, %{}))
                  |> update_or_rollback!()

                run_event =
                  insert_event_in_transaction!(run.id, "run.status_changed", "control", %{
                    "from" => run.status,
                    "to" => new_status
                  })

                {step, step_event} =
                  transition_active_legacy_step_in_transaction!(updated_run, new_status)

                result = %{"run_status" => updated_run.status, "engine" => "legacy_v1"}

                applied =
                  control
                  |> RunControl.changeset(%{
                    status: "applied",
                    applied_at: timestamp,
                    result: result
                  })
                  |> update_or_rollback!()

                control_event =
                  insert_event_in_transaction!(run.id, "run.control_applied", "control", %{
                    "control_id" => applied.id,
                    "control_sequence" => applied.sequence,
                    "kind" => applied.kind,
                    "result" => result
                  })

                {updated_run, step, applied,
                 Enum.reject([run_event, step_event, control_event], &is_nil/1)}
            end
          end)
        end)

      case result do
        {:ok, {run, step, control, events}} ->
          broadcast(run.id, {:run_updated, run})
          if step, do: broadcast(run.id, {:run_step_updated, step})
          broadcast(run.id, {:run_control_updated, control})
          Enum.each(events, &broadcast(run.id, {:run_event, &1}))
          {:ok, run, control}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def apply_claimed_legacy_control(_control_or_id, _new_status, _opts),
    do: {:error, :invalid_control_transition}

  @doc "Records the scoped durable outcome of a claimed control."
  def resolve_control(control_or_id, status, result \\ %{}) do
    _ = {control_or_id, result}
    {:error, {:control_scope_required, status}}
  end

  def resolve_control(control_or_id, status, result, opts)
      when status in ["applied", "rejected", "superseded"] and is_map(result) and
             is_list(opts) do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    transaction =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          case Repo.get(RunControl, control_id) do
            nil ->
              Repo.rollback(:not_found)

            %RunControl{status: current_status} = current
            when current_status == "claimed" or
                   (status == "superseded" and current_status == "pending") ->
              case validate_run_control_resolution_scope(current, opts) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              current_run = Repo.get!(Run, current.run_id)

              if current.target_attempt != current_run.attempt or
                   current.target_generation != current_run.lease_generation do
                Repo.rollback(:control_target_stale)
              end

              if current.status == "claimed" and status in ["applied", "rejected"] and
                   (is_nil(current.claim_expires_at) or
                      DateTime.compare(current.claim_expires_at, now()) != :gt) do
                Repo.rollback(:control_claim_expired)
              end

              attrs = %{status: status, applied_at: now(), result: result}

              updated =
                case current |> RunControl.changeset(attrs) |> Repo.update() do
                  {:ok, updated} -> updated
                  {:error, changeset} -> Repo.rollback(changeset)
                end

              event =
                insert_event_in_transaction!(
                  updated.run_id,
                  "run.control_#{status}",
                  "control",
                  %{
                    "control_id" => updated.id,
                    "control_sequence" => updated.sequence,
                    "kind" => updated.kind,
                    "result" => result
                  }
                )

              {updated, event}

            %RunControl{status: current_status} = current when current_status == status ->
              case validate_run_control_resolution_scope(current, opts) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              if current.result == result do
                {current, nil}
              else
                Repo.rollback(:control_resolution_conflict)
              end

            %RunControl{} = current ->
              Repo.rollback({:invalid_transition, current.status, status})
          end
        end)
      end)

    case transaction do
      {:ok, {control, nil}} ->
        {:ok, control}

      {:ok, {control, event}} ->
        broadcast(control.run_id, {:run_control_updated, control})
        broadcast(control.run_id, {:run_event, event})
        {:ok, control}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_control(_control_or_id, status, _result, _opts),
    do: {:error, {:invalid_control_status, status}}

  defp validate_run_control_resolution_scope(control, opts) do
    required =
      if is_binary(control.worker_id),
        do: [:run_id, :worker_id, :kind],
        else: [:run_id, :kind]

    case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
      nil -> :ok
      key -> {:error, {:control_scope_required, key}}
    end
    |> case do
      :ok -> validate_run_control_scope_values(control, opts)
      {:error, _reason} = error -> error
    end
  end

  defp validate_run_control_scope_values(control, opts) do
    checks = [
      {:run_id, control.run_id},
      {:worker_id, control.worker_id},
      {:kind, control.kind},
      {:target_attempt, control.target_attempt},
      {:target_generation, control.target_generation},
      {:claim_generation, control.claim_generation}
    ]

    Enum.reduce_while(checks, :ok, fn {key, actual}, :ok ->
      case Keyword.fetch(opts, key) do
        :error ->
          {:cont, :ok}

        {:ok, expected} ->
          if to_string(expected) == to_string(actual),
            do: {:cont, :ok},
            else: {:halt, {:error, {:control_scope_mismatch, key}}}
      end
    end)
  end

  defp supersede_controls(filters, reason) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          supersede_controls_in_transaction!(filters[:run_id], filters, reason)
        end)
      end)

    case result do
      {:ok, {controls, events}} ->
        Enum.each(controls, &broadcast(&1.run_id, {:run_control_updated, &1}))
        Enum.each(events, &broadcast(&1.run_id, {:run_event, &1}))
        {:ok, controls}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp supersede_controls_in_transaction!(run_id, filters, reason) do
    query =
      RunControl
      |> where([control], control.status in ["pending", "claimed"])
      |> maybe_where(:run_id, run_id)
      |> maybe_where(:status, filters[:status])
      |> maybe_where(:worker_id, filters[:worker_id])
      |> order_by([control], asc: control.run_id, asc: control.sequence)

    Enum.map_reduce(Repo.all(query), [], fn control, events ->
      updated =
        control
        |> RunControl.changeset(%{
          status: "superseded",
          applied_at: now(),
          result: %{"reason" => reason}
        })
        |> Repo.update!()

      event =
        insert_event_in_transaction!(updated.run_id, "run.control_superseded", "control", %{
          "control_id" => updated.id,
          "control_sequence" => updated.sequence,
          "kind" => updated.kind,
          "result" => updated.result
        })

      {updated, [event | events]}
    end)
    |> then(fn {controls, reversed_events} -> {controls, Enum.reverse(reversed_events)} end)
  end

  defp control_reconciliation_run_ids(run_id, cutoff, worker_id, limit) do
    query =
      Run
      |> join(:left, [run], control in RunControl, on: control.run_id == run.id)
      |> where(
        [run, control],
        (run.status == "queued" and not is_nil(run.cancellation_requested_at)) or
          (control.status in ["pending", "claimed"] and
             (run.status in ["completed", "failed", "cancelled", "interrupted"] or
                control.target_attempt != run.attempt or
                control.target_generation != run.lease_generation or
                (control.status == "claimed" and
                   (is_nil(control.claim_expires_at) or control.claim_expires_at <= ^cutoff))))
      )

    query =
      if is_binary(worker_id) do
        from [run, _control] in query,
          where:
            run.status in ["queued", "completed", "failed", "cancelled", "interrupted"] or
              (run.lease_owner == ^worker_id and run.status in ["running", "paused"])
      else
        query
      end

    query
    |> maybe_where(:id, run_id)
    |> distinct(true)
    |> order_by([run], asc: run.inserted_at, asc: run.id)
    |> limit(^limit)
    |> select([run], run.id)
    |> Repo.all()
  end

  defp reconcile_run_controls_for_run(run_id, cutoff, worker_id, claim_ms) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          run = Repo.get!(Run, run_id)

          cond do
            run.status == "queued" and not is_nil(run.cancellation_requested_at) ->
              reconcile_queued_cancellation!(run)

            run.status in ["completed", "failed", "cancelled", "interrupted"] ->
              reconcile_terminal_run_controls!(run)

            true ->
              reconcile_active_run_controls!(run, cutoff, worker_id, claim_ms)
          end
        end)
      end)

    case result do
      {:ok, {updated_run, controls, events, steps}} ->
        if updated_run, do: broadcast(updated_run.id, {:run_updated, updated_run})
        Enum.each(steps, &broadcast(&1.run_id, {:run_step_updated, &1}))
        Enum.each(controls, &broadcast(&1.run_id, {:run_control_updated, &1}))
        Enum.each(events, &broadcast(&1.run_id, {:run_event, &1}))

        {:ok,
         %{
           run: updated_run,
           controls: controls,
           reconciled: length(controls)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_queued_cancellation!(run) do
    timestamp = now()

    {steps, graph_events} =
      terminalize_worker_graph_in_transaction!(
        run,
        "cancelled",
        %{},
        [lease_generation: run.lease_generation],
        timestamp
      )

    cancelled =
      run
      |> Run.changeset(%{
        status: "cancelled",
        completed_at: timestamp,
        lease_owner: nil,
        lease_expires_at: nil
      })
      |> update_or_rollback!()

    status_event =
      insert_event_in_transaction!(run.id, "run.status_changed", "control_reconciler", %{
        "from" => run.status,
        "to" => "cancelled",
        "reason" => "queued_cancellation_recovered"
      })

    open_controls =
      RunControl
      |> where([control], control.run_id == ^run.id and control.status in ["pending", "claimed"])
      |> order_by([control], asc: control.sequence)
      |> Repo.all()

    {controls, control_events} =
      Enum.map_reduce(open_controls, [], fn control, events ->
        {updated, type, result} =
          if control.kind == "cancel" do
            applied = apply_reconciled_cancel_control!(control, cancelled, timestamp)

            {applied, "run.control_applied", applied.result}
          else
            result = %{"reason" => "queued_run_cancelled"}

            superseded =
              control
              |> RunControl.changeset(%{
                status: "superseded",
                applied_at: timestamp,
                result: result
              })
              |> update_or_rollback!()

            {superseded, "run.control_superseded", result}
          end

        event =
          insert_event_in_transaction!(run.id, type, "control_reconciler", %{
            "control_id" => updated.id,
            "control_sequence" => updated.sequence,
            "kind" => updated.kind,
            "result" => result
          })

        {updated, [event | events]}
      end)

    {cancelled, controls, graph_events ++ [status_event | Enum.reverse(control_events)], steps}
  end

  defp reconcile_terminal_run_controls!(run) do
    if run.status == "cancelled" and not is_nil(run.cancellation_requested_at) do
      timestamp = now()

      open_controls =
        RunControl
        |> where(
          [control],
          control.run_id == ^run.id and control.status in ["pending", "claimed"]
        )
        |> order_by([control], asc: control.sequence)
        |> Repo.all()

      {controls, events} =
        Enum.map_reduce(open_controls, [], fn control, events ->
          {updated, type, result} =
            if control.kind == "cancel" do
              applied = apply_reconciled_cancel_control!(control, run, timestamp)
              {applied, "run.control_applied", applied.result}
            else
              result = %{"reason" => "run_cancelled"}

              superseded =
                control
                |> RunControl.changeset(%{
                  status: "superseded",
                  applied_at: timestamp,
                  result: result
                })
                |> update_or_rollback!()

              {superseded, "run.control_superseded", result}
            end

          event =
            insert_event_in_transaction!(run.id, type, "control_reconciler", %{
              "control_id" => updated.id,
              "control_sequence" => updated.sequence,
              "kind" => updated.kind,
              "result" => result
            })

          {updated, [event | events]}
        end)

      {nil, controls, Enum.reverse(events), []}
    else
      {controls, events} =
        supersede_controls_in_transaction!(run.id, %{}, "run_#{run.status}")

      {nil, controls, events, []}
    end
  end

  defp apply_reconciled_cancel_control!(control, run, timestamp) do
    claim_attrs =
      if control.status == "pending" do
        %{
          worker_id: "control-reconciler",
          claim_generation: run.lease_generation,
          claimed_at: timestamp,
          claim_expires_at: DateTime.add(timestamp, 1, :second)
        }
      else
        %{}
      end

    control
    |> RunControl.changeset(
      Map.merge(claim_attrs, %{
        status: "applied",
        applied_at: timestamp,
        result: %{
          "run_status" => "cancelled",
          "worker_active" => false,
          "recovered" => true
        }
      })
    )
    |> update_or_rollback!()
  end

  defp reconcile_active_run_controls!(run, cutoff, worker_id, claim_ms) do
    controls =
      RunControl
      |> where(
        [control],
        control.run_id == ^run.id and control.status in ["pending", "claimed"] and
          (control.target_attempt != ^run.attempt or
             control.target_generation != ^run.lease_generation or
             (control.status == "claimed" and
                (is_nil(control.claim_expires_at) or control.claim_expires_at <= ^cutoff)))
      )
      |> order_by([control], asc: control.sequence)
      |> Repo.all()

    Enum.map_reduce(controls, [], fn control, events ->
      cond do
        control.target_attempt != run.attempt or
            control.target_generation != run.lease_generation ->
          result = %{"reason" => "stale_run_generation"}

          updated =
            control
            |> RunControl.changeset(%{
              status: "superseded",
              applied_at: now(),
              result: result
            })
            |> update_or_rollback!()

          event = control_reconciliation_event!(updated, "superseded", result)
          {updated, [event | events]}

        control.status == "claimed" and
            (is_nil(control.claim_expires_at) or
               DateTime.compare(control.claim_expires_at, cutoff) != :gt) ->
          {updated, event} = reconcile_expired_control_claim!(control, run, worker_id, claim_ms)

          {updated, [event | events]}

        true ->
          {control, events}
      end
    end)
    |> then(fn {controls, events} -> {nil, controls, Enum.reverse(events), []} end)
  end

  defp reconcile_expired_control_claim!(control, run, nil, _claim_ms) do
    updated =
      control
      |> RunControl.changeset(%{
        status: "pending",
        worker_id: nil,
        claim_generation: nil,
        claimed_at: nil,
        claim_expires_at: nil
      })
      |> update_or_rollback!()

    event =
      insert_event_in_transaction!(run.id, "run.control_requeued", "control_reconciler", %{
        "control_id" => updated.id,
        "control_sequence" => updated.sequence,
        "kind" => updated.kind,
        "reason" => "claim_expired"
      })

    {updated, event}
  end

  defp reconcile_expired_control_claim!(control, run, worker_id, claim_ms) do
    claimed_at = now()

    updated =
      control
      |> RunControl.changeset(%{
        worker_id: worker_id,
        claim_generation: run.lease_generation,
        claimed_at: claimed_at,
        claim_expires_at: control_claim_expiry(claimed_at, claim_ms)
      })
      |> update_or_rollback!()

    event =
      insert_event_in_transaction!(run.id, "run.control_reclaimed", "control_reconciler", %{
        "control_id" => updated.id,
        "control_sequence" => updated.sequence,
        "kind" => updated.kind,
        "worker_id" => worker_id,
        "claim_generation" => updated.claim_generation,
        "claim_expires_at" => DateTime.to_iso8601(updated.claim_expires_at)
      })

    {updated, event}
  end

  defp control_reconciliation_event!(control, status, result) do
    insert_event_in_transaction!(
      control.run_id,
      "run.control_#{status}",
      "control_reconciler",
      %{
        "control_id" => control.id,
        "control_sequence" => control.sequence,
        "kind" => control.kind,
        "result" => result
      }
    )
  end

  # Commands

  def enqueue_command(run_or_id, idempotency_key, attrs) when is_map(attrs),
    do: do_enqueue_command(run_or_id, idempotency_key, attrs, nil)

  @doc "Enqueues a command only while the exact parent worker lease is live."
  def enqueue_command_worker(run_or_id, idempotency_key, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts) do
      do_enqueue_command(run_or_id, idempotency_key, attrs, opts)
    end
  end

  def enqueue_command_worker(_run_or_id, _idempotency_key, _attrs, _opts),
    do: {:error, :invalid_worker_command_creation}

  defp do_enqueue_command(run_or_id, idempotency_key, attrs, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs =
        attrs
        |> drop_keys([
          :run_id,
          :idempotency_key,
          :status,
          :output,
          :error_message,
          :error_details,
          :attempt,
          :claimed_at,
          :heartbeat_at,
          :completed_at
        ])
        |> put_attr(:idempotency_key, idempotency_key)
        |> put_attr(:status, "queued")
        |> put_attr(:attempt, 0)

      candidate = %RunCommand{run_id: run.id}
      changeset = RunCommand.changeset(candidate, attrs)

      if changeset.valid? do
        result =
          Repo.retry_on_busy(fn ->
            Repo.transaction(fn ->
              current = Repo.get!(Run, run.id)

              if worker_opts do
                assert_worker_authority!(current, worker_opts, now())
              else
                assert_unleased_mutation!(current)
              end

              assert_run_step_scope!(current.id, Changeset.get_field(changeset, :run_step_id))

              case Repo.get_by(RunCommand,
                     run_id: current.id,
                     idempotency_key: to_string(idempotency_key)
                   ) do
                %RunCommand{} = existing ->
                  if run_command_semantically_equal?(existing, Changeset.apply_changes(changeset)) do
                    {existing, false, nil}
                  else
                    Repo.rollback(:idempotency_conflict)
                  end

                nil ->
                  case Repo.insert(changeset,
                         on_conflict: :nothing,
                         conflict_target: [:run_id, :idempotency_key]
                       ) do
                    {:ok, inserted} ->
                      canonical =
                        Repo.get_by!(RunCommand,
                          run_id: current.id,
                          idempotency_key: to_string(idempotency_key)
                        )

                      created? = canonical.id == inserted.id

                      if not created? and
                           not run_command_semantically_equal?(
                             canonical,
                             Changeset.apply_changes(changeset)
                           ) do
                        Repo.rollback(:idempotency_conflict)
                      end

                      event =
                        if created? do
                          insert_event_in_transaction!(
                            current.id,
                            "run.command_enqueued",
                            "system",
                            %{
                              "command_id" => canonical.id,
                              "idempotency_key" => canonical.idempotency_key,
                              "tool_name" => canonical.tool_name
                            }
                          )
                        end

                      {canonical, created?, event}

                    {:error, insert_changeset} ->
                      Repo.rollback(insert_changeset)
                  end
              end
            end)
          end)

        case result do
          {:ok, {command, created?, event}} ->
            if created? do
              broadcast(run.id, {:run_command_enqueued, command})
              broadcast(run.id, {:run_event, event})
            end

            {:ok, command}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_command_by_idempotency_key(run_or_id, key) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Repo.get_by(RunCommand, run_id: run.id, idempotency_key: to_string(key))
    else
      nil -> nil
    end
  end

  def get_command(id) when is_binary(id), do: Repo.get(RunCommand, id)
  def get_command(_id), do: nil
  def get_command!(id), do: Repo.get!(RunCommand, id)

  def list_commands(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunCommand
      |> where([c], c.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> order_by([c], asc: c.inserted_at, asc: c.id)
      |> limit(^bounded_limit(opts[:limit], 500, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  def transition_command(command_or_id, new_status, attrs \\ %{})

  def transition_command(%RunCommand{} = command, new_status, attrs),
    do: do_transition_command(command, to_string(new_status), attrs, nil)

  def transition_command(id, new_status, attrs) when is_binary(id) do
    case get_command(id) do
      nil -> {:error, :not_found}
      command -> do_transition_command(command, to_string(new_status), attrs, nil)
    end
  end

  @doc "Transitions a command only while the exact parent worker lease is live."
  def transition_command_worker(command_or_id, new_status, attrs \\ %{}, opts \\ [])

  def transition_command_worker(command_or_id, new_status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with %RunCommand{} = command <- resolve_run_command(command_or_id),
         :ok <- validate_worker_authority_opts(opts) do
      do_transition_command(command, to_string(new_status), attrs, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def transition_command_worker(_command_or_id, _new_status, _attrs, _opts),
    do: {:error, :invalid_worker_command_transition}

  # Approvals

  def request_approval(run_or_id, attrs) when is_map(attrs),
    do: do_request_approval(run_or_id, attrs, nil)

  @doc "Requests approval only while the exact parent worker lease is live."
  def request_approval_worker(run_or_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts) do
      do_request_approval(run_or_id, attrs, opts)
    end
  end

  def request_approval_worker(_run_or_id, _attrs, _opts),
    do: {:error, :invalid_worker_approval_request}

  defp do_request_approval(run_or_id, attrs, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs =
        attrs
        |> drop_keys([
          :run_id,
          :target_attempt,
          :target_generation,
          :status,
          :decided_by,
          :decision_note,
          :decided_at
        ])
        |> put_attr(:status, "pending")

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)

            if worker_opts do
              assert_worker_authority!(current, worker_opts, now())
            else
              assert_unleased_mutation!(current)
            end

            attrs =
              attrs
              |> put_attr(:target_attempt, current.attempt)
              |> put_attr(:target_generation, current.lease_generation)

            changeset =
              %RunApproval{run_id: current.id}
              |> RunApproval.changeset(attrs)

            assert_run_command_scope!(
              current.id,
              Changeset.get_field(changeset, :run_command_id)
            )

            approval =
              case Repo.insert(changeset) do
                {:ok, approval} -> approval
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(current.id, "run.approval_requested", "system", %{
                "approval_id" => approval.id,
                "key" => approval.key,
                "action" => approval.action,
                "target_attempt" => approval.target_attempt,
                "target_generation" => approval.target_generation
              })

            {approval, event}
          end)
        end)

      case result do
        {:ok, {approval, event}} ->
          broadcast(run.id, {:run_approval_requested, approval})
          broadcast(run.id, {:run_event, event})
          {:ok, approval}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_approval(id) when is_binary(id), do: Repo.get(RunApproval, id)
  def get_approval(_id), do: nil

  def list_approvals(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunApproval
      |> where([a], a.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> order_by([a], asc: a.inserted_at, asc: a.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc "Counts pending approval gates across every run in a session."
  def count_pending_approvals(session_id) when is_binary(session_id) do
    RunApproval
    |> join(:inner, [approval], run in Run, on: run.id == approval.run_id)
    |> where(
      [approval, run],
      run.session_id == ^session_id and approval.status == "pending" and
        approval.target_attempt == run.attempt and
        approval.target_generation == run.lease_generation
    )
    |> Repo.aggregate(:count, :id)
  end

  def count_pending_approvals(_session_id), do: 0

  def decide_approval(approval_or_id, decision, attrs \\ %{}) do
    approval_id =
      case approval_or_id do
        %RunApproval{id: id} -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    decision = to_string(decision)

    cond do
      is_nil(approval_id) ->
        {:error, :not_found}

      decision not in ~w(approved denied expired cancelled) ->
        {:error, {:invalid_transition, "pending", decision}}

      true ->
        result =
          Repo.retry_on_busy(fn ->
            Repo.transaction(fn ->
              case Repo.get(RunApproval, approval_id) do
                nil ->
                  Repo.rollback(:not_found)

                %RunApproval{status: "pending"} = current ->
                  run = Repo.get!(Run, current.run_id)

                  if current.target_attempt != run.attempt or
                       current.target_generation != run.lease_generation do
                    Repo.rollback(:stale_approval)
                  end

                  decision_attrs =
                    attrs
                    |> drop_keys([
                      :run_id,
                      :run_command_id,
                      :target_attempt,
                      :target_generation,
                      :key,
                      :action,
                      :resource,
                      :reason,
                      :requested_by,
                      :status,
                      :decided_at
                    ])
                    |> normalize_attrs()
                    |> Map.put(:status, decision)
                    |> Map.put(:decided_at, now())

                  updated =
                    case current |> RunApproval.changeset(decision_attrs) |> Repo.update() do
                      {:ok, updated} -> updated
                      {:error, changeset} -> Repo.rollback(changeset)
                    end

                  event =
                    insert_event_in_transaction!(
                      updated.run_id,
                      "run.approval_decided",
                      "system",
                      %{
                        "approval_id" => updated.id,
                        "decision" => decision,
                        "decided_by" => updated.decided_by
                      }
                    )

                  {updated, event}

                %RunApproval{} = current ->
                  Repo.rollback({:invalid_transition, current.status, decision})
              end
            end)
          end)

        case result do
          {:ok, {updated, event}} ->
            broadcast(updated.run_id, {:run_approval_decided, updated})
            broadcast(updated.run_id, {:run_event, event})
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Artifacts

  def create_artifact(run_or_id, attrs) when is_map(attrs),
    do: do_create_artifact(run_or_id, attrs, nil)

  @doc "Creates an artifact only while the exact parent worker lease is live."
  def create_artifact_worker(run_or_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with :ok <- validate_worker_authority_opts(opts) do
      do_create_artifact(run_or_id, attrs, opts)
    end
  end

  def create_artifact_worker(_run_or_id, _attrs, _opts),
    do: {:error, :invalid_worker_artifact_creation}

  defp do_create_artifact(run_or_id, attrs, worker_opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs = drop_keys(attrs, [:run_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)

            if worker_opts do
              assert_worker_authority!(current, worker_opts, now())
            else
              assert_unleased_mutation!(current)
            end

            changeset =
              %RunArtifact{run_id: current.id}
              |> RunArtifact.changeset(attrs)

            assert_run_step_scope!(
              current.id,
              Changeset.get_field(changeset, :run_step_id)
            )

            artifact =
              case Repo.insert(changeset) do
                {:ok, artifact} -> artifact
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(run.id, "run.artifact_created", "system", %{
                "artifact_id" => artifact.id,
                "kind" => artifact.kind,
                "name" => artifact.name
              })

            {artifact, event}
          end)
        end)

      case result do
        {:ok, {artifact, event}} ->
          broadcast(run.id, {:run_artifact_created, artifact})
          broadcast(run.id, {:run_event, event})
          {:ok, artifact}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def list_artifacts(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunArtifact
      |> where([a], a.run_id == ^run.id)
      |> maybe_where(:kind, opts[:kind])
      |> order_by([a], asc: a.inserted_at, asc: a.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  # Durable run-agent fleet

  @doc "Creates a bounded run-agent manifest atomically with its journal events."
  def create_run_agents(run_or_id, specs, opts \\ [])

  def create_run_agents(run_or_id, specs, opts) when is_list(specs) and is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_agent_manifest_size(run, specs, opts),
         {:ok, prepared} <- prepare_agent_manifest(run, specs, opts) do
      persist_agent_manifest(run, prepared, false)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def create_run_agents(_run_or_id, _specs, _opts), do: {:error, :invalid_agent_manifest}

  @doc "Idempotently ensures every logical member of a bounded run-agent manifest exists."
  def ensure_run_agents(run_or_id, specs, opts \\ [])

  def ensure_run_agents(run_or_id, specs, opts) when is_list(specs) and is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id),
         :ok <- validate_agent_manifest_size(run, specs, Keyword.put(opts, :ensure, true)),
         {:ok, prepared} <- prepare_agent_manifest(run, specs, opts) do
      persist_agent_manifest(run, prepared, true)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def ensure_run_agents(_run_or_id, _specs, _opts), do: {:error, :invalid_agent_manifest}

  def get_run_agent(id) when is_binary(id), do: Repo.get(RunAgent, id)
  def get_run_agent(_id), do: nil
  def get_run_agent!(id), do: Repo.get!(RunAgent, id)

  def get_run_agent(run_or_id, agent_id) when is_binary(agent_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Repo.get_by(RunAgent, id: agent_id, run_id: run.id)
    else
      nil -> nil
    end
  end

  def get_run_agent(_run_or_id, _agent_id), do: nil

  def get_run_agent_by_key(run_or_id, key, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attempt = Keyword.get(opts, :run_attempt, run.attempt)
      Repo.get_by(RunAgent, run_id: run.id, run_attempt: attempt, key: to_string(key))
    else
      nil -> nil
    end
  end

  def list_run_agents(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunAgent
      |> where([agent], agent.run_id == ^run.id)
      |> maybe_agent_attempt_filter(opts, run)
      |> maybe_where(:status, opts[:status])
      |> maybe_where(:role, opts[:role])
      |> maybe_where(:parent_agent_id, opts[:parent_agent_id])
      |> order_by([agent], asc: agent.position, asc: agent.inserted_at, asc: agent.id)
      |> limit(^bounded_limit(opts[:limit], @max_run_agents, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc "Transitions a run agent and journals the change; leased agents require owner/generation fencing."
  def transition_run_agent(agent_or_id, new_status, attrs \\ %{}, opts \\ [])

  def transition_run_agent(agent_or_id, new_status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    new_status = to_string(new_status)

    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id),
         true <-
           transition_allowed?(@run_agent_transitions, agent.status, new_status) ||
             {:error, {:invalid_transition, agent.status, new_status}},
         :ok <- validate_agent_fence(agent, opts),
         {:ok, safe_attrs} <- sanitize_agent_transition_attrs(attrs) do
      do_transition_run_agent(agent, new_status, safe_attrs, opts)
    else
      nil -> {:error, :not_found}
      false -> {:error, {:invalid_transition, agent_or_id, new_status}}
      {:error, _reason} = error -> error
    end
  end

  def transition_run_agent(_agent_or_id, _new_status, _attrs, _opts),
    do: {:error, :invalid_agent_transition}

  @doc "Atomically claims a pending/interrupted agent and returns its new lease generation."
  def claim_run_agent(agent_or_id, lease_owner, lease_ms \\ 30_000)

  def claim_run_agent(agent_or_id, lease_owner, lease_ms)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(lease_ms) and lease_ms > 0 do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id) do
      lease_owner_hash = fleet_owner_hash(lease_owner)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)
            run = Repo.get!(Run, current.run_id)
            timestamp = agent_now()

            cond do
              run.status not in ["running", "paused"] ->
                Repo.rollback({:run_not_active, run.status})

              current.run_attempt != run.attempt or not live_parent_run_lease?(run, timestamp) ->
                Repo.rollback(:run_lease_lost)

              current.status not in ["pending", "interrupted"] ->
                Repo.rollback({:invalid_transition, current.status, "starting"})

              current.desired_state == "stopped" ->
                Repo.rollback(:agent_stopped)

              current.attempt >= current.max_attempts ->
                Repo.rollback(:attempts_exhausted)

              true ->
                generation = current.lease_generation + 1
                status = if current.desired_state == "paused", do: "paused", else: "starting"

                requeued_controls = roll_agent_controls_to_generation!(current, generation)

                attrs = %{
                  status: status,
                  attempt: current.attempt + 1,
                  restart_count:
                    current.restart_count + if(current.status == "interrupted", do: 1, else: 0),
                  lease_owner: lease_owner_hash,
                  lease_generation: generation,
                  lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond),
                  heartbeat_at: timestamp,
                  started_at: current.started_at || timestamp,
                  last_active_at: timestamp,
                  completed_at: nil
                }

                claimed = current |> RunAgent.changeset(attrs) |> update_or_rollback!()

                event =
                  insert_event_in_transaction!(
                    current.run_id,
                    "run.agent_claimed",
                    "fleet",
                    %{
                      "run_agent_id" => claimed.id,
                      "key" => claimed.key,
                      "attempt" => claimed.attempt,
                      "lease_generation" => generation,
                      "status" => claimed.status
                    }
                  )

                {claimed, event, requeued_controls}
            end
          end)
        end)

      case result do
        {:ok, {claimed, event, requeued_controls}} ->
          broadcast(claimed.run_id, {:run_agent_updated, claimed})
          broadcast(claimed.run_id, {:run_event, event})
          publish_superseded_agent_controls(requeued_controls)
          {:ok, claimed}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def claim_run_agent(_agent_or_id, _lease_owner, _lease_ms),
    do: {:error, :invalid_agent_claim}

  @doc "Renews one live agent lease only for its current owner and generation."
  def heartbeat_run_agent(
        agent_or_id,
        lease_owner,
        lease_generation,
        lease_ms \\ 30_000,
        attrs \\ %{}
      )

  def heartbeat_run_agent(agent_or_id, lease_owner, lease_generation, lease_ms, attrs)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(lease_generation) and
             is_integer(lease_ms) and lease_ms > 0 and is_map(attrs) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id),
         {:ok, safe_attrs} <- sanitize_agent_heartbeat_attrs(attrs) do
      timestamp = agent_now()
      lease_owner_hash = fleet_owner_hash(lease_owner)

      active_runs =
        from(run in Run,
          where: run.status in ["running", "paused"],
          where: not is_nil(run.lease_owner),
          where: not is_nil(run.lease_expires_at) and run.lease_expires_at > ^timestamp,
          select: %{id: run.id, attempt: run.attempt}
        )

      {count, _} =
        from(current in RunAgent,
          where: current.id == ^agent.id,
          join: run in subquery(active_runs),
          on: run.id == current.run_id and run.attempt == current.run_attempt,
          where: current.status in ["starting", "idle", "running", "paused", "stopping"],
          where: current.lease_owner == ^lease_owner_hash,
          where: current.lease_generation == ^lease_generation,
          where: current.lease_expires_at > ^timestamp
        )
        |> Repo.update_all(
          set:
            safe_attrs
            |> Map.merge(%{
              heartbeat_at: timestamp,
              last_active_at: timestamp,
              lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond),
              updated_at: timestamp
            })
            |> Map.to_list()
        )

      if count == 1 do
        updated = Repo.get!(RunAgent, agent.id)
        broadcast(updated.run_id, {:run_agent_updated, updated})
        {:ok, updated}
      else
        {:error, :lease_lost}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def heartbeat_run_agent(_agent_or_id, _owner, _generation, _lease_ms, _attrs),
    do: {:error, :invalid_agent_heartbeat}

  @doc "Validates a live run-agent lease without exposing its bearer credential."
  def assert_run_agent_lease(agent_or_id, lease_owner, lease_generation)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(lease_generation) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)

            case validate_agent_fence(current,
                   lease_owner: lease_owner,
                   lease_generation: lease_generation
                 ) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            assert_current_agent_parent!(current, require_live_lease: true)
            current
          end)
        end)

      case result do
        {:ok, current} -> {:ok, current}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def assert_run_agent_lease(_agent_or_id, _owner, _generation),
    do: {:error, :invalid_agent_lease}

  @doc "Releases a fenced live lease into interrupted or a terminal status."
  def release_run_agent_lease(
        agent_or_id,
        lease_owner,
        lease_generation,
        status \\ "interrupted",
        attrs \\ %{}
      ) do
    status = to_string(status)

    if status in ["interrupted", "completed", "failed", "cancelled"] do
      transition_run_agent(agent_or_id, status, attrs,
        lease_owner: lease_owner,
        lease_generation: lease_generation
      )
    else
      {:error, {:invalid_release_status, status}}
    end
  end

  @doc "Marks every expired live agent lease interrupted and journals each reconciliation."
  def reconcile_orphaned_run_agents(opts \\ []) when is_list(opts) do
    timestamp = agent_now()
    requested_before = Keyword.get(opts, :expired_before, timestamp)

    before =
      if is_struct(requested_before, DateTime) and
           DateTime.compare(requested_before, timestamp) == :lt,
         do: requested_before,
         else: timestamp

    query =
      RunAgent
      |> where(
        [agent],
        agent.status in ["starting", "idle", "running", "paused", "stopping"] and
          agent.lease_expires_at <= ^before
      )
      |> maybe_where(:run_id, opts[:run_id])
      |> maybe_where(:lease_owner, optional_fleet_owner_hash(opts[:lease_owner]))
      |> order_by([agent], asc: agent.lease_expires_at, asc: agent.id)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          Enum.map(Repo.all(query), fn agent ->
            {count, _} =
              from(current in RunAgent,
                where: current.id == ^agent.id,
                where: current.status == ^agent.status,
                where: current.lease_owner == ^agent.lease_owner,
                where: current.lease_generation == ^agent.lease_generation,
                where: current.lease_expires_at == ^agent.lease_expires_at,
                where: current.lease_expires_at <= ^before
              )
              |> Repo.update_all(
                set: [
                  status: "interrupted",
                  lease_owner: nil,
                  lease_expires_at: nil,
                  completed_at: nil,
                  current_task: nil,
                  last_active_at: timestamp,
                  error_message: "Agent lease expired",
                  updated_at: timestamp
                ]
              )

            if count == 1 do
              updated = Repo.get!(RunAgent, agent.id)

              requeued_controls =
                requeue_expired_agent_controls_in_transaction!(updated)

              event =
                insert_event_in_transaction!(agent.run_id, "run.agent_interrupted", "fleet", %{
                  "run_agent_id" => agent.id,
                  "key" => agent.key,
                  "lease_generation" => agent.lease_generation,
                  "reason" => "lease_expired"
                })

              {updated, event, requeued_controls}
            end
          end)
          |> Enum.reject(&is_nil/1)
        end)
      end)

    case result do
      {:ok, pairs} ->
        Enum.each(pairs, fn {agent, event, requeued_controls} ->
          broadcast(agent.run_id, {:run_agent_updated, agent})
          broadcast(agent.run_id, {:run_event, event})
          publish_superseded_agent_controls(requeued_controls)
        end)

        Enum.map(pairs, &elem(&1, 0))

      {:error, _reason} ->
        []
    end
  end

  @doc "Records agent usage and latency while atomically adding usage to its parent run."
  def record_run_agent_usage(agent_or_id, usage, source \\ "agent", opts \\ [])

  def record_run_agent_usage(agent_or_id, usage, source, opts)
      when is_map(usage) and is_list(opts) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id),
         :ok <- validate_agent_fence(agent, opts),
         :ok <- validate_terminal_lease_opts(opts),
         :ok <- validate_event_label("run.agent_usage_recorded", source) do
      input = usage_integer(usage, [:prompt_tokens, :input_tokens])
      output = usage_integer(usage, [:completion_tokens, :output_tokens])
      total_only = usage_integer(usage, [:total_tokens])

      {input, output} =
        if input + output == 0 and total_only > 0, do: {total_only, 0}, else: {input, output}

      cost = usage_integer(usage, [:cost_cents])
      latency = usage_integer(usage, [:latency_ms])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)

            case validate_agent_fence(current, opts) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            run = Repo.get!(Run, current.run_id)

            timestamp = agent_now()

            cond do
              run.status not in ["running", "paused"] ->
                Repo.rollback({:run_not_active, run.status})

              run.attempt != current.run_attempt or
                not is_struct(run.lease_expires_at, DateTime) or
                  DateTime.compare(run.lease_expires_at, timestamp) != :gt ->
                Repo.rollback(:run_lease_lost)

              true ->
                :ok
            end

            request_count = current.request_count + 1
            total_latency = current.latency_ms + latency

            updated_agent =
              current
              |> RunAgent.changeset(%{
                input_tokens: current.input_tokens + input,
                output_tokens: current.output_tokens + output,
                cost_cents: current.cost_cents + cost,
                latency_ms: total_latency,
                request_count: request_count,
                last_latency_ms: latency,
                average_latency_ms: div(total_latency, request_count),
                last_active_at: agent_now()
              })
              |> update_or_rollback!()

            new_input = run.input_tokens + input
            new_output = run.output_tokens + output
            total_tokens = new_input + new_output
            new_cost = run.cost_cents + cost

            exhaustion = run_agent_budget_exhaustion(run, total_tokens, new_cost)

            {steps, graph_events} =
              if exhaustion do
                terminalize_worker_graph_in_transaction!(
                  run,
                  "failed",
                  %{
                    error_message: exhaustion.message,
                    error_details: %{
                      "reason" => "budget_exhausted",
                      "budget" => exhaustion.budget,
                      "limit" => exhaustion.limit,
                      "actual" => exhaustion.actual
                    }
                  },
                  [lease_generation: run.lease_generation],
                  now()
                )
              else
                {[], []}
              end

            run_attrs = %{
              input_tokens: new_input,
              output_tokens: new_output,
              cost_cents: new_cost
            }

            run_attrs =
              if exhaustion do
                Map.merge(run_attrs, %{
                  status: "failed",
                  completed_at: timestamp,
                  error_message: exhaustion.message,
                  error_details: %{
                    "reason" => "budget_exhausted",
                    "budget" => exhaustion.budget,
                    "limit" => exhaustion.limit,
                    "actual" => exhaustion.actual
                  }
                })
                |> maybe_extend_terminal_lease(run, timestamp, opts)
              else
                run_attrs
              end

            updated_run = run |> Run.changeset(run_attrs) |> update_or_rollback!()

            agent_pairs =
              if exhaustion do
                terminalize_run_agents_in_transaction!(updated_run, "failed", %{
                  error_message: updated_run.error_message,
                  error_details: updated_run.error_details
                })
              else
                []
              end

            event =
              insert_event_in_transaction!(
                run.id,
                "run.agent_usage_recorded",
                to_string(source),
                %{
                  "run_agent_id" => current.id,
                  "input_tokens" => input,
                  "output_tokens" => output,
                  "cost_cents" => cost,
                  "latency_ms" => latency,
                  "request_count" => request_count
                }
              )

            budget_event =
              if exhaustion do
                insert_event_in_transaction!(run.id, "run.budget_exhausted", "budget", %{
                  "budget" => exhaustion.budget,
                  "limit" => exhaustion.limit,
                  "actual" => exhaustion.actual,
                  "run_agent_id" => current.id
                })
              end

            status_event =
              if exhaustion do
                insert_event_in_transaction!(run.id, "run.status_changed", "budget", %{
                  "from" => run.status,
                  "to" => "failed"
                })
              end

            {updated_agent, updated_run, event, budget_event, status_event, exhaustion, steps,
             graph_events, agent_pairs}
          end)
        end)

      case result do
        {:ok,
         {updated_agent, updated_run, event, budget_event, status_event, exhaustion, steps,
          graph_events, agent_pairs}} ->
          if is_nil(exhaustion),
            do: broadcast(updated_agent.run_id, {:run_agent_updated, updated_agent})

          broadcast(updated_agent.run_id, {:run_updated, updated_run})
          publish_terminalized_steps(updated_agent.run_id, steps, graph_events)
          publish_terminalized_agents(updated_agent.run_id, agent_pairs)
          broadcast(updated_agent.run_id, {:run_event, event})
          if budget_event, do: broadcast(updated_agent.run_id, {:run_event, budget_event})
          if status_event, do: broadcast(updated_agent.run_id, {:run_event, status_event})

          case exhaustion do
            %{budget: "tokens"} -> {:error, {:token_budget_exhausted, updated_run}}
            %{budget: "cost_cents"} -> {:error, {:cost_budget_exhausted, updated_run}}
            nil -> {:ok, updated_agent}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def record_run_agent_usage(_agent_or_id, _usage, _source, _opts), do: {:error, :invalid_usage}

  @doc "Terminalizes every open agent for one exact parent-run lineage in one transaction."
  def terminalize_run_agents(run_or_id, status, attrs \\ %{}, opts \\ [])

  def terminalize_run_agents(run_or_id, status, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    status = to_string(status)

    with %Run{} = run <- resolve_run(run_or_id),
         true <-
           status in ["completed", "failed", "cancelled", "interrupted"] ||
             {:error, {:invalid_terminal_status, status}},
         {:ok, authority} <- terminalize_run_agent_authority(run_or_id, run, opts) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_run_agent_terminalization_authority!(current, authority)
            terminalize_run_agents_in_transaction!(current, status, attrs)
          end)
        end)

      case result do
        {:ok, pairs} ->
          Enum.each(pairs, fn {agent, event, superseded_controls} ->
            broadcast(run.id, {:run_agent_updated, agent})
            broadcast(run.id, {:run_event, event})
            publish_superseded_agent_controls(superseded_controls)
          end)

          {:ok, Enum.map(pairs, &elem(&1, 0))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def terminalize_run_agents(_run_or_id, _status, _attrs, _opts),
    do: {:error, :invalid_agent_terminalization}

  @doc "Reconciles live-looking fleet rows whose parent run is already terminal."
  def reconcile_terminal_run_agents(opts \\ [])

  def reconcile_terminal_run_agents(opts) when is_list(opts) do
    limit = bounded_limit(opts[:limit], 1_000, 5_000)

    RunAgent
    |> join(:inner, [agent], run in Run, on: run.id == agent.run_id)
    |> where(
      [agent, run],
      agent.run_attempt == run.attempt and
        agent.status in [
          "pending",
          "starting",
          "idle",
          "running",
          "paused",
          "stopping",
          "interrupted"
        ] and run.status in ["completed", "failed", "cancelled", "interrupted"]
    )
    |> select([_agent, run], run)
    |> distinct(true)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn run ->
      {run.id,
       terminalize_run_agents(run, run.status, %{},
         run_attempt: run.attempt,
         lease_generation: run.lease_generation,
         reconcile_terminal: true
       )}
    end)
  end

  def reconcile_terminal_run_agents(_opts), do: []

  @doc "Resolves open controls whose durable agent is already terminal or stopped."
  def reconcile_terminal_run_agent_controls(opts \\ [])

  def reconcile_terminal_run_agent_controls(opts) when is_list(opts) do
    limit = bounded_limit(opts[:limit], 200, 1_000)

    candidates =
      RunAgentControl
      |> join(:inner, [control], agent in RunAgent, on: agent.id == control.run_agent_id)
      |> where(
        [control, agent],
        control.status in ["pending", "claimed"] and
          (agent.status in ["completed", "failed", "cancelled"] or
             agent.desired_state == "stopped")
      )
      |> maybe_where(:run_id, opts[:run_id])
      |> order_by([control, _agent], asc: control.inserted_at, asc: control.id)
      |> limit(^limit)
      |> select([control, _agent], control.id)
      |> Repo.all()

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          Enum.flat_map(candidates, fn control_id ->
            control = Repo.get!(RunAgentControl, control_id)
            agent = Repo.get!(RunAgent, control.run_agent_id)

            if control.status in ["pending", "claimed"] and
                 (agent.status in RunAgent.terminal_statuses() or
                    agent.desired_state == "stopped") do
              timestamp = agent_now()

              {status, attrs, event_type} =
                if recoverable_terminal_cancel?(control, agent) do
                  {"applied",
                   %{
                     result: %{
                       "action" => "cancel",
                       "status" => "cancelled",
                       "reason" => "terminal_agent_reconciliation"
                     },
                     resolved_at: timestamp
                   }, "run.agent_control_applied"}
                else
                  {"superseded",
                   %{
                     claim_owner: nil,
                     claim_generation: nil,
                     claimed_at: nil,
                     result: %{"reason" => "agent_terminal_or_stopped"},
                     resolved_at: timestamp
                   }, "run.agent_control_superseded"}
                end

              updated =
                control
                |> RunAgentControl.changeset(Map.put(attrs, :status, status))
                |> update_or_rollback!()

              event =
                insert_event_in_transaction!(agent.run_id, event_type, "fleet_reconciler", %{
                  "run_agent_id" => agent.id,
                  "control_id" => updated.id,
                  "control_sequence" => updated.sequence,
                  "kind" => updated.kind,
                  "result" => updated.result
                })

              [{updated, event}]
            else
              []
            end
          end)
        end)
      end)

    case result do
      {:ok, pairs} ->
        publish_superseded_agent_controls(pairs)
        Enum.map(pairs, &elem(&1, 0))

      {:error, _reason} ->
        []
    end
  end

  def reconcile_terminal_run_agent_controls(_opts), do: []

  # Durable targeted agent controls

  def enqueue_run_agent_control(agent_or_id, idempotency_key, attrs) when is_map(attrs) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id),
         {:ok, payload} <- bounded_agent_map(attr(attrs, :payload) || %{}) do
      key = to_string(idempotency_key)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)
            run = Repo.get!(Run, current.run_id)

            if run.status not in ["running", "paused"] do
              Repo.rollback({:run_not_active, run.status})
            end

            assert_current_agent_parent!(current, run: run, require_live_lease: true)

            case Repo.get_by(RunAgentControl, run_agent_id: current.id, idempotency_key: key) do
              %RunAgentControl{} = existing ->
                requested_kind = attr(attrs, :kind) && to_string(attr(attrs, :kind))
                requested_by = attr(attrs, :requested_by) || "local-user"

                if existing.kind == requested_kind and
                     existing.target_generation == current.lease_generation and
                     existing.payload == payload and existing.requested_by == requested_by do
                  {existing, nil}
                else
                  Repo.rollback(:idempotency_conflict)
                end

              nil ->
                if current.status in RunAgent.terminal_statuses() or
                     current.desired_state == "stopped" do
                  Repo.rollback({:agent_not_controllable, current.status})
                end

                requested_kind = attr(attrs, :kind) && to_string(attr(attrs, :kind))

                target_agent =
                  case desired_state_for_agent_control(requested_kind) do
                    nil ->
                      current

                    desired_state ->
                      current
                      |> RunAgent.changeset(%{desired_state: desired_state})
                      |> update_or_rollback!()
                  end

                {1, _} =
                  from(candidate in RunAgent, where: candidate.id == ^current.id)
                  |> Repo.update_all(inc: [control_sequence: 1])

                sequence =
                  from(candidate in RunAgent,
                    where: candidate.id == ^current.id,
                    select: candidate.control_sequence
                  )
                  |> Repo.one!()

                control_attrs =
                  attrs
                  |> sanitize_agent_attrs()
                  |> drop_keys([:run_id, :run_agent_id, :sequence, :idempotency_key, :status])
                  |> put_attr(:target_generation, target_agent.lease_generation)
                  |> put_attr(:sequence, sequence)
                  |> put_attr(:idempotency_key, key)
                  |> put_attr(:status, "pending")
                  |> put_attr(:payload, payload)

                control =
                  %RunAgentControl{run_id: current.run_id, run_agent_id: current.id}
                  |> RunAgentControl.changeset(control_attrs)
                  |> insert_or_rollback!()

                event =
                  insert_event_in_transaction!(
                    current.run_id,
                    "run.agent_control_enqueued",
                    "fleet",
                    %{
                      "run_agent_id" => current.id,
                      "control_id" => control.id,
                      "control_sequence" => control.sequence,
                      "target_generation" => control.target_generation,
                      "kind" => control.kind
                    }
                  )

                {control, event}
            end
          end)
        end)

      publish_agent_control_result(result, :run_agent_control_enqueued)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_run_agent_control(_agent_or_id, _key, _attrs),
    do: {:error, :invalid_agent_control}

  def get_run_agent_control(id, opts \\ [])

  def get_run_agent_control(id, opts) when is_binary(id) and is_list(opts),
    do: Repo.get(RunAgentControl, id, opts)

  def get_run_agent_control(_id, _opts), do: nil

  def list_run_agent_controls(agent_or_id, opts \\ []) when is_list(opts) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id) do
      RunAgentControl
      |> where([control], control.run_agent_id == ^agent.id)
      |> maybe_where(:status, opts[:status])
      |> maybe_where(:kind, opts[:kind])
      |> order_by([control], asc: control.sequence)
      |> limit(^bounded_limit(opts[:limit], 200, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc """
  Returns a bounded newest-first control window for every agent and control kind
  in one run.

  The limit is applied per `{run_agent_id, kind}` partition so a noisy worker
  cannot starve quieter workers out of Mission Control receipts.
  """
  def list_run_agent_controls_for_run(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      per_kind_limit = bounded_limit(opts[:limit], 1, 20)

      ranked =
        RunAgentControl
        |> where([control], control.run_id == ^run.id)
        |> join(:inner, [control], agent in RunAgent,
          on: agent.id == control.run_agent_id and agent.run_attempt == ^run.attempt
        )
        |> maybe_where(:status, opts[:status])
        |> maybe_where(:kind, opts[:kind])
        |> select([control, _agent], %{
          id: control.id,
          receipt_rank:
            over(row_number(),
              partition_by: [control.run_agent_id, control.kind],
              order_by: [desc: control.sequence, desc: control.id]
            )
        })

      receipt_ids =
        from receipt in subquery(ranked),
          where: receipt.receipt_rank <= ^per_kind_limit,
          select: receipt.id

      RunAgentControl
      |> where([control], control.id in subquery(receipt_ids))
      |> order_by([control], desc: control.sequence, desc: control.inserted_at, desc: control.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  def claim_next_run_agent_control(agent_or_id, claim_owner, claim_generation, opts \\ [])

  def claim_next_run_agent_control(agent_or_id, claim_owner, claim_generation, opts)
      when is_binary(claim_owner) and claim_owner != "" and is_integer(claim_generation) and
             is_list(opts) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id) do
      claim_timeout_ms = positive_integer(opts[:claim_timeout_ms], 30_000)
      claim_owner_hash = fleet_owner_hash(claim_owner)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)
            assert_current_agent_parent!(current, require_live_lease: true)
            timestamp = agent_now()

            if current.status not in RunAgent.leased_statuses() or
                 not secure_fleet_owner?(current.lease_owner, claim_owner) or
                 current.lease_generation != claim_generation or
                 is_nil(current.lease_expires_at) or
                 DateTime.compare(current.lease_expires_at, timestamp) != :gt do
              Repo.rollback(:lease_lost)
            end

            candidate =
              RunAgentControl
              |> where(
                [control],
                control.run_agent_id == ^current.id and control.status in ["pending", "claimed"]
              )
              |> order_by([control], asc: control.sequence)
              |> limit(1)
              |> Repo.one()

            case candidate do
              nil ->
                nil

              %RunAgentControl{status: "claimed"} = control ->
                cond do
                  control.target_generation != claim_generation ->
                    supersede_agent_control_candidate!(control, current, "stale_generation")

                  expired_agent_control_claim?(control, timestamp, claim_timeout_ms) ->
                    reclaimed =
                      control
                      |> RunAgentControl.changeset(%{
                        claim_owner: claim_owner_hash,
                        claim_generation: claim_generation,
                        claimed_at: timestamp
                      })
                      |> update_or_rollback!()

                    event =
                      insert_event_in_transaction!(
                        current.run_id,
                        "run.agent_control_reclaimed",
                        "fleet",
                        %{
                          "run_agent_id" => current.id,
                          "control_id" => reclaimed.id,
                          "control_sequence" => reclaimed.sequence,
                          "kind" => reclaimed.kind,
                          "claim_generation" => claim_generation
                        }
                      )

                    {reclaimed, event}

                  true ->
                    nil
                end

              %RunAgentControl{target_generation: target_generation} = control
              when target_generation != claim_generation ->
                supersede_agent_control_candidate!(control, current, "stale_generation")

              %RunAgentControl{} = control ->
                claimed =
                  control
                  |> RunAgentControl.changeset(%{
                    status: "claimed",
                    claim_owner: claim_owner_hash,
                    claim_generation: claim_generation,
                    claimed_at: timestamp
                  })
                  |> update_or_rollback!()

                event =
                  insert_event_in_transaction!(
                    current.run_id,
                    "run.agent_control_claimed",
                    "fleet",
                    %{
                      "run_agent_id" => current.id,
                      "control_id" => claimed.id,
                      "control_sequence" => claimed.sequence,
                      "kind" => claimed.kind,
                      "claim_generation" => claim_generation
                    }
                  )

                {claimed, event}
            end
          end)
        end)

      case result do
        {:ok, nil} ->
          :none

        {:ok, {:superseded, control, event}} ->
          broadcast(control.run_id, {:run_agent_control_updated, control})
          broadcast(control.run_id, {:run_event, event})
          claim_next_run_agent_control(agent, claim_owner, claim_generation, opts)

        other ->
          publish_agent_control_result(other, :run_agent_control_updated)
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def claim_next_run_agent_control(_agent_or_id, _owner, _generation, _opts),
    do: {:error, :invalid_agent_control_claim}

  @doc "Atomically claims an interrupted agent's head restart control and its next lease generation."
  def claim_restart_run_agent_control(agent_or_id, claim_owner, lease_ms \\ 30_000, opts \\ [])

  def claim_restart_run_agent_control(agent_or_id, claim_owner, lease_ms, opts)
      when is_binary(claim_owner) and claim_owner != "" and is_integer(lease_ms) and
             lease_ms > 0 and is_list(opts) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id) do
      claim_owner_hash = fleet_owner_hash(claim_owner)
      claim_timeout_ms = positive_integer(opts[:claim_timeout_ms], 30_000)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)
            run = Repo.get!(Run, current.run_id)
            timestamp = agent_now()

            cond do
              run.status not in ["running", "paused"] ->
                Repo.rollback({:run_not_active, run.status})

              current.run_attempt != run.attempt or not live_parent_run_lease?(run, timestamp) ->
                Repo.rollback(:run_lease_lost)

              current.status != "interrupted" ->
                Repo.rollback({:invalid_transition, current.status, "starting"})

              current.desired_state != "active" ->
                Repo.rollback({:agent_not_restartable, current.desired_state})

              current.attempt >= current.max_attempts ->
                Repo.rollback(:attempts_exhausted)

              true ->
                control =
                  RunAgentControl
                  |> where(
                    [candidate],
                    candidate.run_agent_id == ^current.id and
                      candidate.status in ["pending", "claimed"]
                  )
                  |> order_by([candidate], asc: candidate.sequence)
                  |> limit(1)
                  |> Repo.one()

                cond do
                  is_nil(control) ->
                    Repo.rollback(:restart_control_not_found)

                  control.kind != "restart" or
                      control.target_generation != current.lease_generation ->
                    Repo.rollback(:restart_control_not_at_head)

                  control.status == "claimed" and
                    not expired_agent_control_claim?(control, timestamp, claim_timeout_ms) and
                      not secure_fleet_owner?(control.claim_owner, claim_owner) ->
                    Repo.rollback(:control_claim_active)

                  true ->
                    generation = current.lease_generation + 1

                    claimed_agent =
                      current
                      |> RunAgent.changeset(%{
                        status: "starting",
                        attempt: current.attempt + 1,
                        restart_count: current.restart_count + 1,
                        lease_owner: claim_owner_hash,
                        lease_generation: generation,
                        lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond),
                        heartbeat_at: timestamp,
                        started_at: current.started_at || timestamp,
                        last_active_at: timestamp,
                        completed_at: nil
                      })
                      |> update_or_rollback!()

                    claimed_control =
                      control
                      |> RunAgentControl.changeset(%{
                        status: "claimed",
                        target_generation: current.lease_generation,
                        claim_owner: claim_owner_hash,
                        claim_generation: generation,
                        claimed_at: timestamp,
                        resolved_at: nil,
                        result: nil
                      })
                      |> update_or_rollback!()

                    agent_event =
                      insert_event_in_transaction!(
                        current.run_id,
                        "run.agent_claimed",
                        "fleet",
                        %{
                          "run_agent_id" => claimed_agent.id,
                          "key" => claimed_agent.key,
                          "attempt" => claimed_agent.attempt,
                          "lease_generation" => generation,
                          "status" => claimed_agent.status,
                          "reason" => "restart_control"
                        }
                      )

                    control_event =
                      insert_event_in_transaction!(
                        current.run_id,
                        "run.agent_control_reclaimed",
                        "fleet",
                        %{
                          "run_agent_id" => current.id,
                          "control_id" => claimed_control.id,
                          "control_sequence" => claimed_control.sequence,
                          "kind" => claimed_control.kind,
                          "claim_generation" => generation
                        }
                      )

                    {claimed_agent, claimed_control, agent_event, control_event}
                end
            end
          end)
        end)

      case result do
        {:ok, {claimed_agent, claimed_control, agent_event, control_event}} ->
          broadcast(claimed_agent.run_id, {:run_agent_updated, claimed_agent})
          broadcast(claimed_agent.run_id, {:run_agent_control_updated, claimed_control})
          broadcast(claimed_agent.run_id, {:run_event, agent_event})
          broadcast(claimed_agent.run_id, {:run_event, control_event})
          {:ok, {claimed_agent, claimed_control}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def claim_restart_run_agent_control(_agent_or_id, _owner, _lease_ms, _opts),
    do: {:error, :invalid_restart_control_claim}

  def resolve_run_agent_control(control_or_id, status, result, claim_owner, claim_generation)
      when status in ["applied", "rejected"] and is_map(result) and is_binary(claim_owner) and
             is_integer(claim_generation) do
    with %RunAgentControl{} = control <- resolve_run_agent_control(control_or_id),
         {:ok, result} <- bounded_agent_map(result) do
      transaction =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgentControl, control.id)
            agent = Repo.get!(RunAgent, current.run_agent_id)
            timestamp = agent_now()

            assert_current_agent_parent!(agent, require_live_lease: true)

            if current.status != "claimed" or
                 not secure_fleet_owner?(current.claim_owner, claim_owner) or
                 current.claim_generation != claim_generation or
                 not valid_agent_control_resolution_fence?(
                   current,
                   agent,
                   claim_owner,
                   claim_generation,
                   timestamp
                 ) do
              Repo.rollback(:control_claim_lost)
            end

            resolved =
              current
              |> RunAgentControl.changeset(%{
                status: status,
                result: result,
                resolved_at: timestamp
              })
              |> update_or_rollback!()

            reconciled_agent =
              if status == "rejected" do
                desired_state = desired_state_for_agent_status(agent.status)

                if agent.desired_state == desired_state do
                  nil
                else
                  agent
                  |> RunAgent.changeset(%{desired_state: desired_state})
                  |> update_or_rollback!()
                end
              end

            event =
              insert_event_in_transaction!(
                resolved.run_id,
                "run.agent_control_#{status}",
                "fleet",
                %{
                  "run_agent_id" => resolved.run_agent_id,
                  "control_id" => resolved.id,
                  "control_sequence" => resolved.sequence,
                  "kind" => resolved.kind,
                  "result" => result
                }
              )

            {resolved, event, reconciled_agent}
          end)
        end)

      case transaction do
        {:ok, {resolved, event, reconciled_agent}} ->
          broadcast(resolved.run_id, {:run_agent_control_updated, resolved})
          broadcast(resolved.run_id, {:run_event, event})

          if reconciled_agent,
            do: broadcast(resolved.run_id, {:run_agent_updated, reconciled_agent})

          {:ok, resolved}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def resolve_run_agent_control(_control, status, _result, _owner, _generation),
    do: {:error, {:invalid_agent_control_status, status}}

  @doc "Consumes applied-but-undelivered steering exactly once under the live agent lease."
  def consume_run_agent_steering_controls(
        agent_or_id,
        lease_owner,
        lease_generation,
        limit \\ 50
      )

  def consume_run_agent_steering_controls(agent_or_id, lease_owner, lease_generation, limit)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(lease_generation) and
             is_integer(limit) do
    with %RunAgent{} = agent <- resolve_run_agent(agent_or_id),
         :ok <-
           validate_agent_fence(agent,
             lease_owner: lease_owner,
             lease_generation: lease_generation
           ) do
      limit = limit |> max(1) |> min(100)

      transaction =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(RunAgent, agent.id)

            assert_current_agent_parent!(current, require_live_lease: true)

            case validate_agent_fence(current,
                   lease_owner: lease_owner,
                   lease_generation: lease_generation
                 ) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            consumed_at = agent_now()

            RunAgentControl
            |> where(
              [control],
              control.run_agent_id == ^current.id and control.status == "applied" and
                control.kind == "steer" and control.target_generation <= ^lease_generation
            )
            |> order_by([control], asc: control.sequence)
            |> limit(1_000)
            |> Repo.all()
            |> Enum.filter(fn control ->
              is_map(control.result) and control.result["status"] == "queued" and
                is_binary(control.payload["guidance"] || control.payload[:guidance])
            end)
            |> Enum.take(limit)
            |> Enum.map(fn control ->
              guidance = control.payload["guidance"] || control.payload[:guidance]

              result = %{
                "action" => "steer",
                "status" => "consumed",
                "consumed_at" => DateTime.to_iso8601(consumed_at)
              }

              updated =
                control
                |> RunAgentControl.changeset(%{result: result})
                |> update_or_rollback!()

              event =
                insert_event_in_transaction!(
                  current.run_id,
                  "run.agent_steering_consumed",
                  "fleet",
                  %{
                    "run_agent_id" => current.id,
                    "control_id" => updated.id,
                    "control_sequence" => updated.sequence,
                    "lease_generation" => lease_generation
                  }
                )

              {%{"control_id" => updated.id, "guidance" => guidance}, updated, event}
            end)
          end)
        end)

      case transaction do
        {:ok, rows} ->
          Enum.each(rows, fn {_item, control, event} ->
            broadcast(control.run_id, {:run_agent_control_updated, control})
            broadcast(control.run_id, {:run_event, event})
          end)

          {:ok, Enum.map(rows, &elem(&1, 0))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def consume_run_agent_steering_controls(_agent, _owner, _generation, _limit),
    do: {:error, :invalid_agent_steering_consumer}

  # Workspace locks

  @default_workspace_lock_lease_seconds 60
  @max_workspace_lock_lease_seconds 86_400

  @doc "Acquires or durably queues one workspace lock as a one-row atomic batch."
  def acquire_workspace_lock(attrs) when is_map(attrs), do: acquire_workspace_locks([attrs])
  def acquire_workspace_lock(_attrs), do: {:error, :invalid_lock_attrs}

  @doc """
  Atomically persists an all-or-none lock batch in deterministic resource order.

  If any requested resource conflicts with an external holder, every row is
  stored as waiting. Otherwise every row is held and receives a fencing token.
  A raw batch capability is returned once and is never exposed by read APIs.
  """
  def acquire_workspace_locks(attrs_list) when is_list(attrs_list) and attrs_list != [] do
    with {:ok, normalized} <- normalize_workspace_lock_batch(attrs_list) do
      do_acquire_workspace_lock_batch(normalized)
    end
  end

  def acquire_workspace_locks(_attrs_list), do: {:error, :invalid_lock_batch}

  def get_workspace_lock(id) when is_binary(id) do
    WorkspaceLock |> Repo.get(id) |> redact_workspace_lock()
  end

  def get_workspace_lock(_id), do: nil
  def get_workspace_lock!(id), do: WorkspaceLock |> Repo.get!(id) |> redact_workspace_lock()

  def list_workspace_locks(opts \\ []) when is_list(opts) do
    WorkspaceLock
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:run_id, opts[:run_id])
    |> maybe_where(:session_id, opts[:session_id])
    |> maybe_where(:batch_id, opts[:batch_id])
    |> maybe_where(:owner_id, opts[:owner_id])
    |> maybe_where(:resource_type, opts[:resource_type])
    |> maybe_where(:resource_key, opts[:resource_key])
    |> maybe_where(:mode, opts[:mode])
    |> maybe_where(:status, opts[:status])
    |> maybe_active_lock_filter(opts[:active])
    |> order_by([lock], desc: lock.requested_at, desc: lock.id)
    |> limit(^bounded_limit(opts[:limit], 200, 1_000))
    |> Repo.all()
    |> Enum.map(&redact_workspace_lock/1)
  end

  def subscribe_workspace_locks(project_id) when is_binary(project_id) and project_id != "" do
    Phoenix.PubSub.subscribe(IexCode.PubSub, workspace_locks_topic(project_id))
  end

  def subscribe_workspace_locks(_project_id), do: {:error, :invalid_project_id}

  @doc "Verifies a complete held batch immediately before a protected effect, without renewal."
  def assert_workspace_lock(lock_or_id, capability_token)
      when is_binary(capability_token) and capability_token != "" do
    with %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
        if Enum.all?(locks, fn current ->
             current.status == "held" and
               DateTime.compare(current.lease_expires_at, now) == :gt and
               is_integer(current.fencing_token)
           end) do
          locks
        else
          {:invalid, Enum.map(locks, & &1.status)}
        end
      end)
      |> case do
        {:ok, {:invalid, statuses}} -> {:error, {:lock_batch_not_held, statuses}}
        {:ok, locks} -> {:ok, lock_envelope(locks, nil)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def assert_workspace_lock(_lock_or_id, _capability_token),
    do: {:error, :invalid_capability}

  def assert_workspace_locks(lock_or_id, capability_token),
    do: assert_workspace_lock(lock_or_id, capability_token)

  @doc "Renews every held lock in a batch using its opaque capability."
  def heartbeat_workspace_lock(lock_or_id, capability_token, lease_seconds \\ nil)

  def heartbeat_workspace_lock(lock_or_id, capability_token, lease_seconds)
      when is_binary(capability_token) and capability_token != "" do
    with {:ok, lease_seconds} <- lock_lease_seconds(lease_seconds),
         %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
        cond do
          Enum.all?(locks, &(&1.status in WorkspaceLock.terminal_statuses())) ->
            {:expired, locks}

          Enum.any?(locks, &(&1.status != "held")) ->
            Repo.rollback({:lock_batch_not_held, Enum.map(locks, & &1.status)})

          Enum.any?(locks, &(DateTime.compare(&1.lease_expires_at, now) != :gt)) ->
            expired = Enum.map(locks, &expire_workspace_lock!(&1, now))
            {:expired, expired}

          true ->
            expires_at = DateTime.add(now, lease_seconds, :second)

            Enum.map(locks, fn held ->
              update_workspace_lock!(held, %{heartbeat_at: now, lease_expires_at: expires_at})
            end)
        end
      end)
      |> case do
        {:ok, {:expired, expired}} ->
          {:error, {:lock_expired, Enum.map(expired, &redact_workspace_lock/1)}}

        {:ok, locks} ->
          broadcast_workspace_locks(locks)
          # The caller already possesses the capability used to authorize this
          # renewal. Never echo that secret back after the initial acquire.
          {:ok, lock_envelope(locks, nil)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat_workspace_lock(_lock_or_id, _capability_token, _lease_seconds),
    do: {:error, :invalid_capability}

  @doc "Rechecks and promotes a complete waiting batch, or renews a held batch."
  def retry_workspace_lock(lock_or_id, capability_token, lease_seconds \\ nil)

  def retry_workspace_lock(lock_or_id, capability_token, lease_seconds)
      when is_binary(capability_token) and capability_token != "" do
    with {:ok, lease_seconds} <- lock_lease_seconds(lease_seconds),
         %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      do_retry_workspace_lock_batch(lock.batch_id, capability_token, lease_seconds)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def retry_workspace_lock(_lock_or_id, _capability_token, _lease_seconds),
    do: {:error, :invalid_capability}

  @doc "Releases or cancels a complete lock batch, retaining every row as history."
  def release_workspace_lock(lock_or_id, capability_token)
      when is_binary(capability_token) and capability_token != "" do
    case resolve_workspace_lock(lock_or_id) do
      nil ->
        :ok

      %WorkspaceLock{} = lock ->
        transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
          Enum.map(locks, fn current ->
            if current.status in WorkspaceLock.terminal_statuses() do
              current
            else
              status = if current.status == "waiting", do: "cancelled", else: "released"

              update_workspace_lock!(current, %{
                status: status,
                released_at: now,
                conflict_lock_id: nil,
                conflict_owner_id: nil,
                wait_reason: nil
              })
            end
          end)
        end)
        |> case do
          {:ok, locks} ->
            broadcast_workspace_locks(locks)
            {:ok, %{batch_id: lock.batch_id, locks: Enum.map(locks, &redact_workspace_lock/1)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def release_workspace_lock(_lock_or_id, _capability_token),
    do: {:error, :invalid_capability}

  @doc "Expires held leases and cancels waiting leases at or before `before`."
  def release_expired_workspace_locks(before \\ nil) do
    before =
      if match?(%DateTime{}, before),
        do: DateTime.truncate(before, :microsecond),
        else: lock_now()

    Repo.retry_on_busy(fn ->
      Repo.transaction(
        fn -> expire_workspace_locks_in_transaction!(before) end,
        mode: :immediate
      )
    end)
    |> case do
      {:ok, expired} ->
        broadcast_workspace_locks(expired)
        {:ok, length(expired)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_acquire_workspace_lock_batch(normalized) do
    token = normalized.capability_token || generate_lock_capability()
    token_hash = hash_lock_capability(token)
    batch_id = Ecto.UUID.generate()

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(
          fn ->
            now = lock_now()
            expired = expire_workspace_locks_in_transaction!(now)
            matching = active_identity_locks(normalized.locks)

            acquired =
              if matching == [] and not is_nil(normalized.capability_token) do
                :lock_batch_not_active
              else
                if matching == [] do
                  insert_workspace_lock_batch!(
                    normalized.locks,
                    batch_id,
                    token_hash,
                    now
                  )
                else
                  existing_batch_ids = matching |> Enum.map(& &1.batch_id) |> Enum.uniq()

                  existing =
                    case existing_batch_ids do
                      [existing_batch_id] -> workspace_lock_batch(existing_batch_id)
                      _batch_ids -> matching
                    end

                  cond do
                    length(existing_batch_ids) != 1 or
                        not same_lock_identities?(existing, normalized.locks) ->
                      Repo.rollback(:lock_already_requested)

                    is_nil(normalized.capability_token) or
                        not valid_lock_batch_capability?(existing, normalized.capability_token) ->
                      Repo.rollback(:invalid_capability)

                    true ->
                      recheck_workspace_lock_batch!(existing, now, normalized.lease_seconds)
                  end
                end
              end

            {acquired, expired}
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, {:lock_batch_not_active, expired}} ->
        broadcast_workspace_locks(expired)
        {:error, :lock_batch_not_active}

      {:ok, {locks, expired}} ->
        broadcast_workspace_locks(expired)
        broadcast_workspace_locks(locks)

        returned_token =
          if is_nil(normalized.capability_token), do: token, else: nil

        {:ok, lock_envelope(locks, returned_token)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_retry_workspace_lock_batch(batch_id, capability_token, lease_seconds) do
    transact_workspace_lock_batch(batch_id, capability_token, fn locks, now ->
      if Enum.all?(locks, &(&1.status in WorkspaceLock.terminal_statuses())) do
        {:inactive, locks}
      else
        recheck_workspace_lock_batch!(locks, now, lease_seconds)
      end
    end)
    |> case do
      {:ok, {:inactive, locks}} ->
        {:error, {:lock_batch_not_active, Enum.map(locks, & &1.status)}}

      {:ok, locks} ->
        broadcast_workspace_locks(locks)
        # Retry is capability-authorized but must not become another secret
        # distribution channel. The gateway retains its original token.
        {:ok, lock_envelope(locks, nil)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transact_workspace_lock_batch(batch_id, capability_token, callback) do
    Repo.retry_on_busy(fn ->
      Repo.transaction(
        fn ->
          now = lock_now()
          expired = expire_workspace_locks_in_transaction!(now)
          locks = workspace_lock_batch(batch_id)

          cond do
            locks == [] ->
              Repo.rollback(:not_found)

            not valid_lock_batch_capability?(locks, capability_token) ->
              Repo.rollback(:invalid_capability)

            true ->
              {callback.(locks, now), expired}
          end
        end,
        mode: :immediate
      )
    end)
    |> case do
      {:ok, {value, expired}} ->
        broadcast_workspace_locks(expired)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_workspace_lock_batch!(locks, batch_id, token_hash, now) do
    conflicts = batch_lock_conflicts(locks, [])
    first_conflict = conflicts |> Map.values() |> Enum.find(& &1)
    held? = is_nil(first_conflict)

    same_owner_conflict =
      conflicts
      |> Map.values()
      |> Enum.find(&(&1 && &1.owner_id == hd(locks).owner_id))

    if same_owner_conflict, do: Repo.rollback(:lock_upgrade_not_supported)

    fence_start = if held?, do: next_workspace_fencing_token(hd(locks).workspace_key), else: nil

    locks
    |> Enum.with_index()
    |> Enum.map(fn {attrs, index} ->
      direct_conflict = Map.get(conflicts, lock_identity(attrs))

      lifecycle_attrs =
        if held? do
          %{
            status: "held",
            acquired_at: now,
            heartbeat_at: now,
            lease_expires_at: DateTime.add(now, attrs.lease_seconds, :second),
            fencing_token: fence_start + index
          }
        else
          conflict = direct_conflict || first_conflict

          %{
            status: "waiting",
            lease_expires_at: DateTime.add(now, attrs.lease_seconds, :second),
            conflict_lock_id: conflict.id,
            conflict_owner_id: conflict.owner_id,
            wait_reason: conflict_wait_reason(direct_conflict, conflict)
          }
        end

      struct = %WorkspaceLock{
        project_id: attrs.project_id,
        run_id: attrs.run_id,
        session_id: attrs.session_id
      }

      changes =
        attrs
        |> Map.drop([:lease_seconds, :capability_token])
        |> Map.merge(lifecycle_attrs)
        |> Map.merge(%{
          batch_id: batch_id,
          capability_token_hash: token_hash,
          requested_at: now
        })

      case struct |> WorkspaceLock.changeset(changes) |> Repo.insert() do
        {:ok, inserted} -> inserted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp recheck_workspace_lock_batch!(locks, now, lease_seconds) do
    cond do
      Enum.all?(locks, &(&1.status == "held")) ->
        expires_at = DateTime.add(now, lease_seconds, :second)

        Enum.map(
          locks,
          &update_workspace_lock!(&1, %{heartbeat_at: now, lease_expires_at: expires_at})
        )

      Enum.all?(locks, &(&1.status == "waiting")) ->
        conflicts = batch_lock_conflicts(locks, Enum.map(locks, & &1.id))
        first_conflict = conflicts |> Map.values() |> Enum.find(& &1)

        if first_conflict do
          Enum.map(locks, fn waiting ->
            direct_conflict = Map.get(conflicts, lock_identity(waiting))
            conflict = direct_conflict || first_conflict

            update_workspace_lock!(waiting, %{
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              conflict_lock_id: conflict.id,
              conflict_owner_id: conflict.owner_id,
              wait_reason: conflict_wait_reason(direct_conflict, conflict)
            })
          end)
        else
          fence_start = next_workspace_fencing_token(hd(locks).workspace_key)

          locks
          |> Enum.with_index()
          |> Enum.map(fn {waiting, index} ->
            update_workspace_lock!(waiting, %{
              status: "held",
              acquired_at: now,
              heartbeat_at: now,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              fencing_token: fence_start + index,
              conflict_lock_id: nil,
              conflict_owner_id: nil,
              wait_reason: nil
            })
          end)
        end

      true ->
        Repo.rollback(:inconsistent_lock_batch)
    end
  end

  defp normalize_workspace_lock_batch(attrs_list) do
    with {:ok, locks} <- map_lock_attrs(attrs_list),
         [first | _] <- locks,
         true <-
           Enum.all?(locks, &(&1.project_id == first.project_id)) ||
             {:error, :mixed_lock_projects},
         true <-
           Enum.all?(locks, &(&1.owner_id == first.owner_id)) || {:error, :mixed_lock_owners},
         true <- Enum.all?(locks, &(&1.run_id == first.run_id)) || {:error, :mixed_lock_runs},
         true <-
           Enum.all?(locks, &(&1.session_id == first.session_id)) ||
             {:error, :mixed_lock_sessions},
         {:ok, capability_token} <- common_batch_capability(attrs_list) do
      locks =
        locks
        |> Enum.group_by(&{&1.resource_type, &1.resource_key})
        |> Enum.map(fn {_resource, duplicates} ->
          Enum.max_by(duplicates, &lock_mode_rank(&1.mode))
        end)
        |> Enum.sort_by(&{&1.project_id, &1.resource_type, &1.resource_key, &1.mode})

      lease_seconds = Enum.map(locks, & &1.lease_seconds) |> Enum.min()
      locks = Enum.map(locks, &Map.put(&1, :lease_seconds, lease_seconds))

      {:ok,
       %{
         locks: locks,
         capability_token: capability_token,
         lease_seconds: lease_seconds
       }}
    else
      [] -> {:error, :invalid_lock_batch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_lock_attrs(attrs_list) do
    Enum.reduce_while(attrs_list, {:ok, []}, fn attrs, {:ok, locks} ->
      case normalize_workspace_lock_attrs(attrs) do
        {:ok, lock} -> {:cont, {:ok, [lock | locks]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, locks} -> {:ok, Enum.reverse(locks)}
      error -> error
    end
  end

  defp normalize_workspace_lock_attrs(attrs) when is_map(attrs) do
    with {:ok, project_id} <- required_id(attrs, :project_id),
         {:ok, owner_id} <- required_id(attrs, :owner_id),
         {:ok, project} <- fetch_lock_project(project_id),
         {:ok, workspace_key} <- IexCode.WorkspacePath.resolve(project.root_path, ""),
         {:ok, resource_type} <- lock_label(attrs, :resource_type),
         {:ok, resource_key} <-
           canonical_lock_key(project, resource_type, attr(attrs, :resource_key)),
         {:ok, mode} <- lock_label(attrs, :mode),
         true <-
           resource_type in WorkspaceLock.resource_types() || {:error, :invalid_resource_type},
         true <- mode in WorkspaceLock.modes() || {:error, :invalid_lock_mode},
         {:ok, lease_seconds} <- lock_lease_seconds(attr(attrs, :lease_seconds)),
         {:ok, identities} <- validate_lock_identities(project_id, attrs) do
      {:ok,
       %{
         project_id: project_id,
         workspace_key: workspace_key,
         run_id: identities.run_id,
         session_id: identities.session_id,
         owner_id: owner_id,
         resource_type: resource_type,
         resource_key: resource_key,
         mode: mode,
         lease_seconds: lease_seconds
       }}
    end
  end

  defp normalize_workspace_lock_attrs(_attrs), do: {:error, :invalid_lock_attrs}

  defp common_batch_capability(attrs_list) do
    tokens =
      attrs_list
      |> Enum.map(&attr(&1, :capability_token))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case tokens do
      [] -> {:ok, nil}
      [token] when is_binary(token) and token != "" -> {:ok, token}
      _tokens -> {:error, :mixed_lock_capabilities}
    end
  end

  defp active_identity_locks(locks) do
    identities = MapSet.new(Enum.map(locks, &lock_identity/1))

    WorkspaceLock
    |> where([lock], lock.status in ["waiting", "held"])
    |> where([lock], lock.workspace_key == ^hd(locks).workspace_key)
    |> Repo.all()
    |> Enum.filter(&MapSet.member?(identities, lock_identity(&1)))
  end

  defp same_lock_identities?(existing, requested) do
    MapSet.new(Enum.map(existing, &lock_request_identity/1)) ==
      MapSet.new(Enum.map(requested, &lock_request_identity/1))
  end

  defp batch_lock_conflicts(candidates, excluded_ids) do
    batch_order =
      candidates
      |> Enum.map(&{Map.get(&1, :requested_at), Map.get(&1, :id) || ""})
      |> Enum.reject(fn {requested_at, _id} -> is_nil(requested_at) end)
      |> Enum.min_by(
        fn {requested_at, id} ->
          {DateTime.to_unix(requested_at, :microsecond), id}
        end,
        fn -> nil end
      )

    blockers =
      WorkspaceLock
      |> where([lock], lock.status in ["waiting", "held"])
      |> order_by([lock], asc: lock.requested_at, asc: lock.id)
      |> Repo.all()
      |> Enum.filter(&workspaces_overlap?(&1.workspace_key, hd(candidates).workspace_key))
      |> Enum.reject(&(&1.id in excluded_ids))
      |> Enum.filter(fn blocker ->
        blocker.status == "held" or is_nil(batch_order) or
          older_lock_request?({blocker.requested_at, blocker.id}, batch_order)
      end)

    Map.new(candidates, fn candidate ->
      {lock_identity(candidate), Enum.find(blockers, &workspace_locks_conflict?(candidate, &1))}
    end)
  end

  defp workspace_locks_conflict?(left, right) do
    cond do
      left.resource_type == "project" and left.mode in ["write", "exclusive"] ->
        true

      right.resource_type == "project" and right.mode in ["write", "exclusive"] ->
        true

      left.resource_type == "project" ->
        right.mode in ["write", "exclusive"]

      right.resource_type == "project" ->
        left.mode in ["write", "exclusive"]

      left.resource_type == "git" and left.mode in ["write", "exclusive"] ->
        true

      right.resource_type == "git" and right.mode in ["write", "exclusive"] ->
        true

      left.resource_type == "git" ->
        right.mode in ["write", "exclusive"]

      right.resource_type == "git" ->
        left.mode in ["write", "exclusive"]

      left.resource_type == right.resource_type and left.resource_key == right.resource_key ->
        not (left.mode == "read" and right.mode == "read")

      true ->
        false
    end
  end

  defp older_lock_request?({left_at, left_id}, {right_at, right_id}) do
    case DateTime.compare(left_at, right_at) do
      :lt -> true
      :gt -> false
      :eq -> left_id < right_id
    end
  end

  # Canonical exact roots are the durable identity. Ancestor/descendant roots
  # also coordinate, while hard-link identity remains outside this slice.
  defp workspaces_overlap?(left, right) do
    path_contains?(left, right) or path_contains?(right, left)
  end

  defp path_contains?(parent, child) do
    relative = Path.relative_to(child, parent)
    child == parent or (Path.type(relative) == :relative and ".." not in Path.split(relative))
  end

  defp lock_identity(lock),
    do: {lock.owner_id, lock.workspace_key, lock.resource_type, lock.resource_key, lock.mode}

  defp lock_request_identity(lock),
    do: {lock_identity(lock), Map.get(lock, :run_id), Map.get(lock, :session_id)}

  defp conflict_wait_reason(nil, _batch_conflict), do: "batch_blocked"
  defp conflict_wait_reason(%WorkspaceLock{status: "waiting"}, _conflict), do: "queue_predecessor"
  defp conflict_wait_reason(%WorkspaceLock{}, _conflict), do: "external_conflict"

  defp lock_mode_rank("read"), do: 1
  defp lock_mode_rank("write"), do: 2
  defp lock_mode_rank("exclusive"), do: 3

  defp next_workspace_fencing_token(_workspace_key) do
    from(lock in WorkspaceLock, select: max(lock.fencing_token))
    |> Repo.one()
    |> case do
      nil -> 1
      token -> token + 1
    end
  end

  defp expire_workspace_locks_in_transaction!(before) do
    WorkspaceLock
    |> where(
      [lock],
      lock.status in ["waiting", "held"] and lock.lease_expires_at <= ^before
    )
    |> order_by([lock], asc: lock.requested_at, asc: lock.id)
    |> Repo.all()
    |> Enum.map(fn lock ->
      update_workspace_lock!(lock, %{
        status: if(lock.status == "waiting", do: "cancelled", else: "expired"),
        released_at: before,
        conflict_lock_id: nil,
        conflict_owner_id: nil,
        wait_reason: nil
      })
    end)
  end

  defp expire_workspace_lock!(lock, at) do
    update_workspace_lock!(lock, %{
      status: "expired",
      released_at: at,
      conflict_lock_id: nil,
      conflict_owner_id: nil,
      wait_reason: nil
    })
  end

  defp update_workspace_lock!(lock, attrs) do
    case lock |> WorkspaceLock.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp workspace_lock_batch(batch_id) do
    WorkspaceLock
    |> where([lock], lock.batch_id == ^batch_id)
    |> order_by([lock], asc: lock.resource_type, asc: lock.resource_key, asc: lock.mode)
    |> Repo.all()
  end

  defp lock_envelope(locks, capability_token) do
    %{
      batch_id: hd(locks).batch_id,
      capability_token: capability_token,
      locks: Enum.map(locks, &redact_workspace_lock/1)
    }
  end

  defp redact_workspace_lock(nil), do: nil

  defp redact_workspace_lock(lock),
    do: %{lock | capability_token_hash: "[REDACTED]", capability_token: nil}

  defp generate_lock_capability do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash_lock_capability(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp valid_lock_capability?(lock, token) when is_binary(token) do
    Plug.Crypto.secure_compare(lock.capability_token_hash, hash_lock_capability(token))
  end

  defp valid_lock_capability?(_lock, _token), do: false

  defp valid_lock_batch_capability?([first | rest], token) do
    valid_lock_capability?(first, token) and
      Enum.all?(rest, fn lock ->
        lock.batch_id == first.batch_id and lock.project_id == first.project_id and
          lock.workspace_key == first.workspace_key and lock.owner_id == first.owner_id and
          lock.capability_token_hash == first.capability_token_hash and
          valid_lock_capability?(lock, token)
      end)
  end

  defp valid_lock_batch_capability?([], _token), do: false

  defp fetch_lock_project(project_id) do
    case Repo.get(IexCode.Projects.Project, project_id) do
      nil -> {:error, {:invalid, :project_id}}
      project -> {:ok, project}
    end
  end

  defp validate_lock_identities(project_id, attrs) do
    run_id = optional_id(attrs, :run_id)
    session_id = optional_id(attrs, :session_id)

    with :ok <- validate_lock_run(run_id, project_id, session_id),
         :ok <- validate_lock_session(session_id, project_id) do
      {:ok, %{run_id: run_id, session_id: session_id}}
    end
  end

  defp validate_lock_run(nil, _project_id, _session_id), do: :ok

  defp validate_lock_run(run_id, project_id, session_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, {:invalid, :run_id}}

      %Run{project_id: ^project_id, session_id: run_session_id}
      when is_nil(session_id) or run_session_id == session_id ->
        :ok

      %Run{project_id: ^project_id} ->
        {:error, :run_session_mismatch}

      %Run{} ->
        {:error, :run_project_mismatch}
    end
  end

  defp validate_lock_session(nil, _project_id), do: :ok

  defp validate_lock_session(session_id, project_id) do
    case Repo.get(IexCode.Sessions.Session, session_id) do
      nil -> {:error, {:invalid, :session_id}}
      %{project_id: ^project_id} -> :ok
      _session -> {:error, :session_project_mismatch}
    end
  end

  defp canonical_lock_key(project, "project", _resource_key) do
    IexCode.WorkspacePath.resolve(project.root_path, "")
  end

  defp canonical_lock_key(project, "file", resource_key) do
    IexCode.WorkspacePath.resolve(project.root_path, resource_key)
  end

  defp canonical_lock_key(project, "git", resource_key) when is_binary(resource_key) do
    with {:ok, root} <- IexCode.WorkspacePath.resolve(project.root_path, ""),
         {:ok, candidate} <- IexCode.WorkspacePath.resolve(project.root_path, resource_key) do
      if candidate == root, do: {:ok, root}, else: {:error, :invalid_git_resource}
    end
  end

  defp canonical_lock_key(_project, _resource_type, resource_key)
       when is_binary(resource_key) and resource_key != "",
       do: {:ok, resource_key}

  defp canonical_lock_key(_project, _resource_type, _resource_key),
    do: {:error, {:missing, :resource_key}}

  defp lock_label(attrs, key) do
    case attr(attrs, key) do
      value when key == :resource_type and value in [:workspace, "workspace"] -> {:ok, "project"}
      value when is_atom(value) or is_binary(value) -> {:ok, to_string(value)}
      _value -> {:error, {:missing, key}}
    end
  end

  defp lock_lease_seconds(nil), do: {:ok, @default_workspace_lock_lease_seconds}

  defp lock_lease_seconds(seconds)
       when is_integer(seconds) and seconds >= 1 and seconds <= @max_workspace_lock_lease_seconds,
       do: {:ok, seconds}

  defp lock_lease_seconds(_seconds), do: {:error, :invalid_lease_seconds}

  defp optional_id(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp resolve_workspace_lock(%WorkspaceLock{id: id}), do: Repo.get(WorkspaceLock, id)
  defp resolve_workspace_lock(id) when is_binary(id), do: Repo.get(WorkspaceLock, id)
  defp resolve_workspace_lock(_lock_or_id), do: nil

  defp maybe_active_lock_filter(query, true),
    do: where(query, [lock], lock.status in ["waiting", "held"])

  defp maybe_active_lock_filter(query, false),
    do: where(query, [lock], lock.status in ["released", "expired", "cancelled"])

  defp maybe_active_lock_filter(query, _active), do: query

  defp broadcast_workspace_locks([]), do: :ok

  defp broadcast_workspace_locks(locks) do
    locks
    |> Enum.group_by(& &1.project_id)
    |> Enum.each(fn {project_id, project_locks} ->
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        workspace_locks_topic(project_id),
        {:workspace_locks_updated, Enum.map(project_locks, &redact_workspace_lock/1)}
      )
    end)
  end

  defp workspace_locks_topic(project_id), do: "workspace_locks:project:#{project_id}"

  defp insert_initial_steps!(run_id, steps) do
    steps
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {step_attrs, position}, events ->
      step_attrs =
        step_attrs
        |> drop_keys([:run_id])
        |> put_attr_new(:position, position)

      changeset =
        %RunStep{run_id: run_id}
        |> RunStep.create_changeset(step_attrs)

      assert_parent_step_scope!(
        run_id,
        Changeset.get_field(changeset, :parent_step_id)
      )

      step =
        case Repo.insert(changeset) do
          {:ok, step} -> step
          {:error, changeset} -> Repo.rollback(changeset)
        end

      event =
        insert_event_in_transaction!(run_id, "run.step_created", "system", %{
          "step_id" => step.id,
          "key" => step.key,
          "status" => step.status
        })

      {step, [event | events]}
    end)
    |> then(fn {steps, reversed_events} -> {steps, Enum.reverse(reversed_events)} end)
  end

  defp prepare_retry_manifest(%Run{execution_engine: "dag_v1"} = run, []) do
    steps = run |> list_steps() |> Enum.map(&dag_manifest_step/1)

    with {:ok, prepared} <- ExecutionEngine.prepare_manifest(run, steps),
         true <- prepared.manifest_hash == run.manifest_hash or {:error, :manifest_drift} do
      {:ok, %{manifest_hash: prepared.manifest_hash, insert_steps: []}}
    end
  end

  defp prepare_retry_manifest(%Run{execution_engine: "dag_v1"} = run, steps) do
    with {:ok, prepared} <- ExecutionEngine.prepare_manifest(run, steps),
         true <- prepared.manifest_hash == run.manifest_hash or {:error, :manifest_drift} do
      {:ok, %{manifest_hash: prepared.manifest_hash, insert_steps: []}}
    end
  end

  defp prepare_retry_manifest(%Run{} = run, steps) do
    with {:ok, prepared} <- ExecutionEngine.prepare_manifest(run, steps) do
      {:ok, %{manifest_hash: nil, insert_steps: prepared.steps}}
    end
  end

  defp retry_validation_steps(%Run{execution_engine: "dag_v1"} = run, []),
    do: run |> list_steps() |> Enum.map(&dag_manifest_step/1)

  defp retry_validation_steps(%Run{}, steps), do: steps

  defp reset_dag_steps_for_retry!(%Run{execution_engine: "dag_v1"} = run) do
    run
    |> list_steps()
    |> Enum.map_reduce([], fn step, events ->
      status = if step.depends_on == [], do: "ready", else: "pending"

      reset =
        step
        |> RunStep.changeset(%{
          status: status,
          progress: 0,
          attempt: 0,
          result: nil,
          error_message: nil,
          error_details: nil,
          started_at: nil,
          heartbeat_at: nil,
          completed_at: nil
        })
        |> update_or_rollback!()

      event =
        insert_event_in_transaction!(run.id, "run.step_reset", "dag", %{
          "step_id" => reset.id,
          "key" => reset.key,
          "status" => reset.status
        })

      {reset, [event | events]}
    end)
    |> then(fn {steps, events} -> {steps, Enum.reverse(events)} end)
  end

  defp reset_dag_steps_for_retry!(%Run{}), do: {[], []}

  defp cancel_pending_approvals_in_transaction!(%Run{} = run, reason) do
    timestamp = now()

    RunApproval
    |> where([approval], approval.run_id == ^run.id and approval.status == "pending")
    |> order_by([approval], asc: approval.inserted_at, asc: approval.id)
    |> Repo.all()
    |> Enum.map(fn approval ->
      updated =
        approval
        |> RunApproval.changeset(%{
          status: "cancelled",
          decided_by: "system",
          decision_note: reason,
          decided_at: timestamp
        })
        |> update_or_rollback!()

      event =
        insert_event_in_transaction!(updated.run_id, "run.approval_decided", "system", %{
          "approval_id" => updated.id,
          "decision" => "cancelled",
          "reason" => reason
        })

      {updated, event}
    end)
  end

  defp validate_retry_manifest_in_transaction(%Run{execution_engine: "dag_v1"} = run, retry) do
    persisted = run |> list_steps() |> Enum.map(&dag_manifest_step/1)

    with {:ok, prepared} <- ExecutionEngine.prepare_manifest(run, persisted),
         true <- prepared.manifest_hash == run.manifest_hash or {:error, :manifest_drift},
         true <- prepared.manifest_hash == retry.manifest_hash or {:error, :manifest_drift} do
      :ok
    end
  end

  defp validate_retry_manifest_in_transaction(%Run{} = run, retry) do
    case ExecutionEngine.prepare_manifest(run, retry.insert_steps) do
      {:ok, _prepared} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp dag_manifest_step(step) do
    %{
      key: step.key,
      kind: step.kind,
      title: step.title,
      depends_on: step.depends_on,
      params: step.params,
      max_attempts: step.max_attempts
    }
  end

  # Run-agent internal helpers

  defp validate_agent_manifest_size(%Run{} = run, specs, opts) do
    maximum =
      case Keyword.get(opts, :max_agents, @max_run_agents) do
        value when is_integer(value) and value > 0 -> min(value, @max_run_agents)
        _value -> @max_run_agents
      end

    existing = Repo.aggregate(from(agent in RunAgent, where: agent.run_id == ^run.id), :count)

    existing_keys =
      if Keyword.get(opts, :ensure, false) do
        keys =
          specs
          |> Enum.map(&(attr(&1, :key) && to_string(attr(&1, :key))))
          |> Enum.reject(&is_nil/1)

        Repo.aggregate(
          from(agent in RunAgent, where: agent.run_id == ^run.id and agent.key in ^keys),
          :count
        )
      else
        0
      end

    cond do
      specs == [] ->
        {:error, :empty_agent_manifest}

      length(specs) > maximum ->
        {:error, {:agent_manifest_too_large, maximum}}

      existing + length(specs) - existing_keys > maximum ->
        {:error, {:agent_manifest_too_large, maximum}}

      true ->
        :ok
    end
  end

  defp prepare_agent_manifest(%Run{} = run, specs, opts) do
    run_attempt = Keyword.get(opts, :run_attempt, run.attempt)

    if is_integer(run_attempt) and run_attempt >= 0 and Enum.all?(specs, &is_map/1) do
      keys = Enum.map(specs, &(attr(&1, :key) && to_string(attr(&1, :key))))

      cond do
        Enum.any?(keys, &is_nil/1) ->
          {:error, {:missing, :key}}

        length(Enum.uniq(keys)) != length(keys) ->
          {:error, :duplicate_agent_key}

        true ->
          ids =
            Map.new(keys, fn key ->
              id =
                case Repo.get_by(RunAgent,
                       run_id: run.id,
                       run_attempt: run_attempt,
                       key: key
                     ) do
                  %RunAgent{id: existing_id} -> existing_id
                  nil -> Ecto.UUID.generate()
                end

              {key, id}
            end)

          specs
          |> Enum.with_index()
          |> Enum.reduce_while({:ok, []}, fn {spec, position}, {:ok, prepared} ->
            key = to_string(attr(spec, :key))
            parent_key = attr(spec, :parent_key)
            requested_parent_id = attr(spec, :parent_agent_id)

            with {:ok, parent_id} <-
                   manifest_parent_id(
                     run,
                     run_attempt,
                     parent_key,
                     requested_parent_id,
                     ids,
                     prepared
                   ),
                 {:ok, attrs} <- sanitize_run_agent_spec(spec) do
              attrs =
                attrs
                |> drop_keys([:id, :run_id, :parent_key])
                |> put_attr_new(:role, key)
                |> put_attr_new(:adapter, to_string(attr(attrs, :role) || key))
                |> put_attr_new(:display_name, humanize_agent_key(key))
                |> put_attr(:run_attempt, run_attempt)
                |> put_attr_new(:position, position)
                |> put_attr(:parent_agent_id, parent_id)

              candidate = %RunAgent{id: Map.fetch!(ids, key), run_id: run.id}
              changeset = RunAgent.changeset(candidate, attrs)

              if changeset.valid? do
                {:cont, {:ok, prepared ++ [{candidate, attrs}]}}
              else
                {:halt, {:error, changeset}}
              end
            else
              {:error, _reason} = error -> {:halt, error}
            end
          end)
      end
    else
      {:error, :invalid_agent_manifest}
    end
  end

  defp manifest_parent_id(_run, _attempt, nil, nil, _ids, _prepared), do: {:ok, nil}

  defp manifest_parent_id(run, attempt, parent_key, nil, ids, prepared)
       when is_binary(parent_key) or is_atom(parent_key) do
    parent_key = to_string(parent_key)
    parent_id = Map.get(ids, parent_key)

    cond do
      is_nil(parent_id) ->
        case Repo.get_by(RunAgent, run_id: run.id, run_attempt: attempt, key: parent_key) do
          %RunAgent{id: id} -> {:ok, id}
          nil -> {:error, {:unknown_parent_agent_key, parent_key}}
        end

      Enum.any?(prepared, fn {%RunAgent{id: id}, _attrs} -> id == parent_id end) ->
        {:ok, parent_id}

      true ->
        {:error, {:parent_agent_must_precede_child, parent_key}}
    end
  end

  defp manifest_parent_id(run, attempt, nil, parent_id, _ids, _prepared)
       when is_binary(parent_id) do
    case Repo.get(RunAgent, parent_id) do
      %RunAgent{run_id: run_id, run_attempt: ^attempt} when run_id == run.id -> {:ok, parent_id}
      %RunAgent{} -> {:error, :parent_agent_scope_mismatch}
      nil -> {:error, :parent_agent_not_found}
    end
  end

  defp manifest_parent_id(_run, _attempt, _parent_key, _parent_id, _ids, _prepared),
    do: {:error, :invalid_parent_agent}

  defp sanitize_run_agent_spec(spec) do
    spec = sanitize_agent_attrs(spec)

    with {:ok, config} <- bounded_agent_map(attr(spec, :config) || %{}),
         {:ok, metadata} <- bounded_agent_map(attr(spec, :metadata) || %{}),
         {:ok, result} <- bounded_optional_agent_map(attr(spec, :result)),
         {:ok, error_details} <- bounded_optional_agent_map(attr(spec, :error_details)) do
      {:ok,
       spec
       |> drop_keys([
         :status,
         :desired_state,
         :lease_owner,
         :lease_generation,
         :lease_expires_at,
         :heartbeat_at,
         :control_sequence,
         :attempt,
         :restart_count,
         :started_at,
         :last_active_at,
         :completed_at
       ])
       |> put_attr(:status, "pending")
       |> put_attr(:desired_state, "active")
       |> put_attr(:config, config)
       |> put_attr(:metadata, metadata)
       |> put_attr(:result, result)
       |> put_attr(:error_details, error_details)}
    end
  end

  defp humanize_agent_key(key) do
    key
    |> String.replace(~r/[-_.:]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp persist_agent_manifest(run, prepared, ensure?) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          Enum.map(prepared, fn {%RunAgent{} = candidate, attrs} ->
            existing =
              Repo.get_by(RunAgent,
                run_id: run.id,
                run_attempt: attr(attrs, :run_attempt),
                key: to_string(attr(attrs, :key))
              )

            cond do
              ensure? and existing ->
                if run_agent_manifest_matches?(existing, attrs) do
                  {existing, nil}
                else
                  Repo.rollback({:agent_manifest_conflict, existing.key})
                end

              existing ->
                Repo.rollback({:agent_already_exists, existing.key})

              true ->
                assert_run_agent_parent_scope!(
                  run.id,
                  attr(attrs, :run_attempt),
                  attr(attrs, :parent_agent_id)
                )

                agent = candidate |> RunAgent.changeset(attrs) |> insert_or_rollback!()

                event =
                  insert_event_in_transaction!(run.id, "run.agent_created", "fleet", %{
                    "run_agent_id" => agent.id,
                    "run_attempt" => agent.run_attempt,
                    "key" => agent.key,
                    "role" => agent.role,
                    "adapter" => agent.adapter,
                    "status" => agent.status
                  })

                {agent, event}
            end
          end)
        end)
      end)

    case result do
      {:ok, pairs} ->
        Enum.each(pairs, fn
          {_agent, nil} ->
            :ok

          {agent, event} ->
            broadcast(run.id, {:run_agent_created, agent})
            broadcast(run.id, {:run_event, event})
        end)

        {:ok, Enum.map(pairs, &elem(&1, 0))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_transition_run_agent(agent, new_status, attrs, opts) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(RunAgent, agent.id)

          run = Repo.get!(Run, current.run_id)

          if new_status in RunAgent.leased_statuses() and
               run.status not in ["running", "paused"] do
            Repo.rollback({:run_not_active, run.status})
          end

          assert_current_agent_parent!(current,
            run: run,
            require_live_lease: new_status in RunAgent.leased_statuses()
          )

          unless transition_allowed?(@run_agent_transitions, current.status, new_status) do
            Repo.rollback({:invalid_transition, current.status, new_status})
          end

          case validate_agent_fence(current, opts) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          superseded_controls =
            if new_status in ["completed", "failed", "cancelled"] do
              preserve_kind =
                case new_status do
                  "cancelled" -> "cancel"
                  "interrupted" -> "restart"
                  _status -> nil
                end

              supersede_agent_controls_in_transaction!(current, "agent_#{new_status}",
                preserve_claimed_kind: preserve_kind
              )
            else
              []
            end

          updated =
            current
            |> RunAgent.changeset(agent_transition_attrs(current, new_status, attrs))
            |> update_or_rollback!()

          event =
            insert_event_in_transaction!(updated.run_id, "run.agent_status_changed", "fleet", %{
              "run_agent_id" => updated.id,
              "key" => updated.key,
              "from" => current.status,
              "to" => new_status,
              "lease_generation" => updated.lease_generation
            })

          {updated, event, superseded_controls}
        end)
      end)

    case result do
      {:ok, {updated, event, superseded_controls}} ->
        broadcast(updated.run_id, {:run_agent_updated, updated})
        broadcast(updated.run_id, {:run_event, event})
        publish_superseded_agent_controls(superseded_controls)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  defp terminalize_run_agents_in_transaction!(run, status, attrs) do
    open_statuses = ~w(pending starting idle running paused stopping interrupted)

    RunAgent
    |> where(
      [agent],
      agent.run_id == ^run.id and agent.run_attempt == ^run.attempt and
        agent.status in ^open_statuses
    )
    |> order_by([agent], asc: agent.position, asc: agent.id)
    |> Repo.all()
    |> Enum.map(fn agent ->
      target =
        if agent.status == "interrupted" and status == "interrupted",
          do: nil,
          else: status

      if target do
        superseded_controls =
          supersede_agent_controls_in_transaction!(agent, "agent_terminalized")

        updated =
          agent
          |> RunAgent.changeset(agent_transition_attrs(agent, target, attrs))
          |> update_or_rollback!()

        event =
          insert_event_in_transaction!(run.id, "run.agent_#{target}", "system", %{
            "run_agent_id" => agent.id,
            "key" => agent.key,
            "from" => agent.status,
            "to" => target
          })

        {updated, event, superseded_controls}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp sanitize_agent_transition_attrs(attrs) do
    normalized = attrs |> sanitize_agent_attrs() |> normalize_attrs()

    rejected =
      normalized
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@mutable_run_agent_transition_fields, &1))
      |> Enum.sort_by(&to_string/1)

    if rejected == [] do
      try do
        {:ok, sanitize_agent_transition_maps!(normalized)}
      rescue
        error in ArgumentError -> {:error, error.message}
      end
    else
      {:error, {:immutable_agent_fields, rejected}}
    end
  end

  defp run_agent_manifest_matches?(agent, attrs) do
    canonical =
      %RunAgent{run_id: agent.run_id}
      |> RunAgent.changeset(attrs)
      |> Changeset.apply_changes()

    immutable_fields = [
      :run_attempt,
      :parent_agent_id,
      :key,
      :role,
      :adapter,
      :display_name,
      :position,
      :required,
      :max_attempts,
      :model_provider,
      :model_name,
      :capabilities,
      :config
    ]

    Enum.all?(immutable_fields, fn field -> Map.get(agent, field) == Map.get(canonical, field) end)
  end

  defp run_agent_budget_exhaustion(%Run{status: status}, _tokens, _cost)
       when status not in ["running", "paused"],
       do: nil

  defp run_agent_budget_exhaustion(%Run{} = run, tokens, cost) do
    cond do
      is_integer(run.token_budget) and tokens > run.token_budget ->
        %{
          budget: "tokens",
          limit: run.token_budget,
          actual: tokens,
          message: "Run exceeded its #{run.token_budget}-token provider-reported budget"
        }

      is_integer(run.cost_budget_cents) and cost > run.cost_budget_cents ->
        %{
          budget: "cost_cents",
          limit: run.cost_budget_cents,
          actual: cost,
          message: "Run exceeded its #{run.cost_budget_cents}-cent provider-reported budget"
        }

      true ->
        nil
    end
  end

  defp agent_transition_attrs(agent, status, attrs) do
    attrs = attrs |> normalize_attrs() |> Map.put(:status, status)
    timestamp = agent_now()

    cond do
      status == "pending" ->
        attrs
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:heartbeat_at, nil)
        |> Map.put(:completed_at, nil)
        |> Map.put(:current_task, nil)

      status in ["completed", "failed", "cancelled"] ->
        attrs
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:completed_at, timestamp)
        |> Map.put(:last_active_at, timestamp)
        |> Map.put(:current_task, nil)
        |> maybe_complete_agent_progress(status)

      status == "interrupted" ->
        attrs
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:completed_at, nil)
        |> Map.put(:last_active_at, timestamp)
        |> Map.put(:current_task, nil)

      status in RunAgent.leased_statuses() ->
        attrs
        |> Map.put_new(:lease_owner, agent.lease_owner)
        |> Map.put_new(:lease_generation, agent.lease_generation)
        |> Map.put_new(:lease_expires_at, agent.lease_expires_at)
        |> Map.put_new(:heartbeat_at, agent.heartbeat_at)
        |> Map.put_new(:started_at, agent.started_at || timestamp)
        |> Map.put(:completed_at, nil)
        |> Map.put(:last_active_at, timestamp)

      true ->
        attrs
    end
  end

  defp maybe_complete_agent_progress(attrs, "completed"), do: Map.put(attrs, :progress, 100)
  defp maybe_complete_agent_progress(attrs, _status), do: attrs

  defp validate_agent_fence(%RunAgent{status: status}, opts)
       when status in ["pending", "interrupted"] do
    if Keyword.has_key?(opts, :lease_owner) or Keyword.has_key?(opts, :lease_generation),
      do: validate_agent_fence_values(opts),
      else: :ok
  end

  defp validate_agent_fence(%RunAgent{} = agent, opts) do
    with :ok <- validate_agent_fence_values(opts),
         true <- secure_fleet_owner?(agent.lease_owner, Keyword.fetch!(opts, :lease_owner)),
         true <- Keyword.fetch!(opts, :lease_generation) == agent.lease_generation,
         true <-
           is_struct(agent.lease_expires_at, DateTime) and
             DateTime.compare(agent.lease_expires_at, agent_now()) == :gt do
      :ok
    else
      _ -> {:error, :lease_lost}
    end
  end

  defp validate_agent_fence_values(opts) do
    owner = Keyword.get(opts, :lease_owner)
    generation = Keyword.get(opts, :lease_generation)

    if is_binary(owner) and owner != "" and is_integer(generation) and generation >= 0,
      do: :ok,
      else: {:error, :lease_lost}
  end

  # A run-agent lease is subordinate to exactly one parent run attempt. Agent
  # generations may be recycled within that attempt, but they must never make a
  # historical fleet row authoritative after the parent has been retried.
  defp assert_current_agent_parent!(%RunAgent{} = agent, opts) do
    run = Keyword.get(opts, :run) || Repo.get!(Run, agent.run_id)
    require_live_lease? = Keyword.get(opts, :require_live_lease, false)
    timestamp = agent_now()

    valid? =
      run.id == agent.run_id and run.attempt == agent.run_attempt and
        (not require_live_lease? or
           (run.status in ["running", "paused"] and live_parent_run_lease?(run, timestamp)))

    if valid?, do: :ok, else: Repo.rollback(:run_lease_lost)
  end

  defp live_parent_run_lease?(
         %Run{lease_owner: owner, lease_expires_at: %DateTime{} = expires_at},
         timestamp
       )
       when is_binary(owner) and owner != "" do
    DateTime.compare(expires_at, timestamp) == :gt
  end

  defp live_parent_run_lease?(%Run{}, _timestamp), do: false

  defp terminalize_run_agent_authority(run_or_id, %Run{} = run, opts) do
    attempt = opts[:run_attempt]
    generation = opts[:lease_generation]
    owner = opts[:lease_owner]

    cond do
      is_binary(owner) and owner != "" and is_integer(attempt) and attempt >= 1 and
        is_integer(generation) and generation >= 1 ->
        {:ok, {:owned, owner, attempt, generation}}

      opts[:reconcile_terminal] == true and is_integer(attempt) and attempt >= 0 and
        is_integer(generation) and generation >= 0 ->
        {:ok, {:reconcile_terminal, attempt, generation}}

      opts == [] and match?(%Run{}, run_or_id) ->
        {:ok, {:unleased, run.attempt, run.lease_generation}}

      true ->
        {:error, :run_agent_authority_required}
    end
  end

  defp assert_run_agent_terminalization_authority!(
         %Run{} = run,
         {:owned, owner, attempt, generation}
       ) do
    valid? =
      run.lease_owner == owner and run.attempt == attempt and
        run.lease_generation == generation and live_parent_run_lease?(run, agent_now())

    if valid?, do: :ok, else: Repo.rollback(:lease_not_owned)
  end

  defp assert_run_agent_terminalization_authority!(
         %Run{} = run,
         {:reconcile_terminal, attempt, generation}
       ) do
    valid? =
      run.attempt == attempt and run.lease_generation == generation and
        run.status in ["completed", "failed", "cancelled", "interrupted"] and
        not active_lease?(run, now())

    if valid?, do: :ok, else: Repo.rollback(:lease_not_owned)
  end

  defp assert_run_agent_terminalization_authority!(
         %Run{} = run,
         {:unleased, attempt, generation}
       ) do
    valid? =
      run.attempt == attempt and run.lease_generation == generation and
        not active_lease?(run, now())

    if valid?, do: :ok, else: Repo.rollback(:run_agent_authority_required)
  end

  defp publish_agent_control_result({:ok, {control, nil}}, _tuple), do: {:ok, control}

  defp publish_agent_control_result({:ok, {control, event}}, tuple) do
    broadcast(control.run_id, {tuple, control})
    broadcast(control.run_id, {:run_event, event})
    {:ok, control}
  end

  defp publish_agent_control_result({:error, reason}, _tuple), do: {:error, reason}

  defp supersede_agent_controls_in_transaction!(agent, reason, opts \\ []) do
    before_generation = Keyword.get(opts, :before_generation)
    preserve_claimed_kind = Keyword.get(opts, :preserve_claimed_kind)

    query =
      RunAgentControl
      |> where(
        [control],
        control.run_agent_id == ^agent.id and control.status in ["pending", "claimed"]
      )
      |> order_by([control], asc: control.sequence)

    query =
      if is_integer(before_generation) do
        where(query, [control], control.target_generation < ^before_generation)
      else
        query
      end

    query =
      if is_binary(preserve_claimed_kind) do
        where(
          query,
          [control],
          not (control.status == "claimed" and control.kind == ^preserve_claimed_kind)
        )
      else
        query
      end

    Enum.map(Repo.all(query), fn control ->
      result = %{"reason" => reason}

      updated =
        control
        |> RunAgentControl.changeset(%{
          status: "superseded",
          result: result,
          resolved_at: agent_now()
        })
        |> update_or_rollback!()

      event =
        insert_event_in_transaction!(agent.run_id, "run.agent_control_superseded", "fleet", %{
          "run_agent_id" => agent.id,
          "control_id" => updated.id,
          "control_sequence" => updated.sequence,
          "kind" => updated.kind,
          "result" => result
        })

      {updated, event}
    end)
  end

  defp roll_agent_controls_to_generation!(agent, generation) do
    RunAgentControl
    |> where(
      [control],
      control.run_agent_id == ^agent.id and control.status in ["pending", "claimed"] and
        control.target_generation < ^generation
    )
    |> order_by([control], asc: control.sequence)
    |> Repo.all()
    |> Enum.map(fn control ->
      updated =
        control
        |> RunAgentControl.changeset(%{
          status: "pending",
          target_generation: generation,
          claim_owner: nil,
          claim_generation: nil,
          claimed_at: nil,
          resolved_at: nil,
          result: nil
        })
        |> update_or_rollback!()

      event =
        insert_event_in_transaction!(agent.run_id, "run.agent_control_requeued", "fleet", %{
          "run_agent_id" => agent.id,
          "control_id" => updated.id,
          "control_sequence" => updated.sequence,
          "kind" => updated.kind,
          "target_generation" => generation,
          "reason" => "agent_generation_replaced"
        })

      {updated, event}
    end)
  end

  # A claimed control is fenced by the same lease as its agent. Once that lease
  # expires there is no live owner that can resolve the receipt, so return it to
  # the queue together with the interrupted agent. Restart controls are retargeted
  # to the interrupted generation; the replacement manager can then atomically
  # claim the restart instead of excluding the stale claimed receipt forever.
  defp requeue_expired_agent_controls_in_transaction!(agent) do
    RunAgentControl
    |> where(
      [control],
      control.run_agent_id == ^agent.id and control.status == "claimed"
    )
    |> order_by([control], asc: control.sequence)
    |> Repo.all()
    |> Enum.map(fn control ->
      updated =
        control
        |> RunAgentControl.changeset(%{
          status: "pending",
          target_generation: agent.lease_generation,
          claim_owner: nil,
          claim_generation: nil,
          claimed_at: nil,
          resolved_at: nil,
          result: nil
        })
        |> update_or_rollback!()

      event =
        insert_event_in_transaction!(agent.run_id, "run.agent_control_requeued", "fleet", %{
          "run_agent_id" => agent.id,
          "control_id" => updated.id,
          "control_sequence" => updated.sequence,
          "kind" => updated.kind,
          "target_generation" => agent.lease_generation,
          "reason" => "agent_lease_expired"
        })

      {updated, event}
    end)
  end

  defp supersede_agent_control_candidate!(control, agent, reason) do
    result = %{"reason" => reason}

    updated =
      control
      |> RunAgentControl.changeset(%{
        status: "superseded",
        result: result,
        resolved_at: agent_now()
      })
      |> update_or_rollback!()

    event =
      insert_event_in_transaction!(agent.run_id, "run.agent_control_superseded", "fleet", %{
        "run_agent_id" => agent.id,
        "control_id" => updated.id,
        "control_sequence" => updated.sequence,
        "kind" => updated.kind,
        "result" => result
      })

    {:superseded, updated, event}
  end

  defp publish_superseded_agent_controls(pairs) do
    Enum.each(pairs, fn {control, event} ->
      broadcast(control.run_id, {:run_agent_control_updated, control})
      broadcast(control.run_id, {:run_event, event})
    end)
  end

  defp desired_state_for_agent_control("pause"), do: "paused"
  defp desired_state_for_agent_control(kind) when kind in ["resume", "restart"], do: "active"
  defp desired_state_for_agent_control("cancel"), do: "stopped"
  defp desired_state_for_agent_control(_kind), do: nil

  defp desired_state_for_agent_status("paused"), do: "paused"

  defp desired_state_for_agent_status(status)
       when status in ["stopping", "completed", "failed", "cancelled"],
       do: "stopped"

  defp desired_state_for_agent_status(_status), do: "active"

  defp valid_agent_control_resolution_fence?(
         %RunAgentControl{kind: "cancel", target_generation: generation},
         %RunAgent{status: "cancelled", desired_state: "stopped", lease_generation: generation},
         _claim_owner,
         generation,
         _timestamp
       ),
       do: true

  defp valid_agent_control_resolution_fence?(
         %RunAgentControl{kind: "restart", target_generation: target_generation},
         %RunAgent{} = agent,
         claim_owner,
         claim_generation,
         timestamp
       ) do
    agent.status in RunAgent.leased_statuses() and
      secure_fleet_owner?(agent.lease_owner, claim_owner) and
      claim_generation == target_generation + 1 and agent.lease_generation == claim_generation and
      live_agent_lease?(agent, timestamp)
  end

  defp valid_agent_control_resolution_fence?(
         %RunAgentControl{target_generation: generation},
         %RunAgent{} = agent,
         claim_owner,
         generation,
         timestamp
       ) do
    agent.status in RunAgent.leased_statuses() and
      secure_fleet_owner?(agent.lease_owner, claim_owner) and
      agent.lease_generation == generation and live_agent_lease?(agent, timestamp)
  end

  defp valid_agent_control_resolution_fence?(_control, _agent, _owner, _generation, _timestamp),
    do: false

  defp recoverable_terminal_cancel?(
         %RunAgentControl{
           status: "claimed",
           kind: "cancel",
           target_generation: generation,
           claim_generation: generation
         },
         %RunAgent{
           status: "cancelled",
           desired_state: "stopped",
           lease_generation: generation
         }
       ),
       do: true

  defp recoverable_terminal_cancel?(_control, _agent), do: false

  defp live_agent_lease?(%RunAgent{lease_expires_at: %DateTime{} = expires_at}, timestamp),
    do: DateTime.compare(expires_at, timestamp) == :gt

  defp live_agent_lease?(_agent, _timestamp), do: false

  defp expired_agent_control_claim?(
         %RunAgentControl{claimed_at: %DateTime{} = claimed_at},
         timestamp,
         timeout_ms
       ) do
    DateTime.compare(DateTime.add(claimed_at, timeout_ms, :millisecond), timestamp) != :gt
  end

  defp expired_agent_control_claim?(_control, _timestamp, _timeout_ms), do: true

  defp fleet_owner_hash(owner) when is_binary(owner) and owner != "" do
    :crypto.hash(:sha256, owner) |> Base.encode16(case: :lower)
  end

  defp optional_fleet_owner_hash(owner) when is_binary(owner) and owner != "",
    do: fleet_owner_hash(owner)

  defp optional_fleet_owner_hash(_owner), do: nil

  defp secure_fleet_owner?(stored_hash, raw_owner)
       when is_binary(stored_hash) and is_binary(raw_owner) and byte_size(stored_hash) == 64 do
    Plug.Crypto.secure_compare(stored_hash, fleet_owner_hash(raw_owner))
  end

  defp secure_fleet_owner?(_stored_hash, _raw_owner), do: false

  defp sanitize_agent_heartbeat_attrs(attrs) do
    allowed = [:progress, :current_task, :latency_ms, :last_latency_ms, :average_latency_ms]
    safe = attrs |> sanitize_agent_attrs() |> normalize_attrs() |> Map.take(allowed)

    cond do
      Map.get(safe, :progress, 0) not in 0..100 ->
        {:error, :invalid_progress}

      Enum.any?([:latency_ms, :last_latency_ms, :average_latency_ms], fn key ->
        value = Map.get(safe, key, 0)
        not is_integer(value) or value < 0
      end) ->
        {:error, :invalid_latency}

      true ->
        {:ok, safe}
    end
  end

  defp sanitize_agent_transition_maps!(attrs) do
    Enum.reduce([:config, :metadata, :result, :error_details], attrs, fn key, acc ->
      if Map.has_key?(acc, key) do
        case bounded_optional_agent_map(Map.get(acc, key)) do
          {:ok, value} -> Map.put(acc, key, value)
          {:error, reason} -> raise ArgumentError, inspect(reason)
        end
      else
        acc
      end
    end)
  end

  defp sanitize_agent_attrs(attrs) when is_map(attrs), do: IexCode.Sessions.sanitize_utf8(attrs)

  defp bounded_agent_map(value) when is_map(value) do
    sanitized = IexCode.Sessions.sanitize_utf8(value)

    cond do
      secret_shaped_agent_payload?(sanitized) ->
        {:error, :secret_payload_forbidden}

      true ->
        case Jason.encode(sanitized) do
          {:ok, encoded} when byte_size(encoded) <= @max_event_payload_bytes -> {:ok, sanitized}
          {:ok, _encoded} -> {:error, :payload_too_large}
          {:error, _reason} -> {:error, :invalid_payload}
        end
    end
  end

  defp bounded_agent_map(_value), do: {:error, :invalid_payload}
  defp bounded_optional_agent_map(nil), do: {:ok, nil}
  defp bounded_optional_agent_map(value), do: bounded_agent_map(value)

  defp secret_shaped_agent_payload?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      secret_shaped_agent_key?(key) or secret_shaped_agent_payload?(value)
    end)
  end

  defp secret_shaped_agent_payload?(list) when is_list(list),
    do: Enum.any?(list, &secret_shaped_agent_payload?/1)

  defp secret_shaped_agent_payload?(_value), do: false

  defp secret_shaped_agent_key?(key) when is_atom(key) or is_binary(key) do
    key = key |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    key in ~w(secret secrets password passwords credential credentials capability capabilities token api_key private_key access_token auth_token capability_token) or
      String.ends_with?(key, "_secret") or String.ends_with?(key, "_password") or
      String.ends_with?(key, "_credential") or String.ends_with?(key, "_capability") or
      String.ends_with?(key, "_token") or String.ends_with?(key, "_api_key") or
      String.ends_with?(key, "_private_key")
  end

  defp secret_shaped_agent_key?(_key), do: false

  defp insert_or_rollback!(changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp resolve_run_agent(%RunAgent{id: id}), do: Repo.get(RunAgent, id)
  defp resolve_run_agent(id) when is_binary(id), do: Repo.get(RunAgent, id)
  defp resolve_run_agent(_agent_or_id), do: nil

  defp resolve_run_agent_control(%RunAgentControl{id: id}), do: Repo.get(RunAgentControl, id)
  defp resolve_run_agent_control(id) when is_binary(id), do: Repo.get(RunAgentControl, id)
  defp resolve_run_agent_control(_control_or_id), do: nil

  defp maybe_agent_attempt_filter(query, opts, run) do
    cond do
      opts[:all_attempts] -> query
      is_integer(opts[:run_attempt]) -> maybe_where(query, :run_attempt, opts[:run_attempt])
      true -> maybe_where(query, :run_attempt, run.attempt)
    end
  end

  defp interrupt_if_orphaned(run_id, before) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(Run, run_id)

          {count, _} =
            from(run in Run,
              where: run.id == ^run_id,
              where: run.status in ["running", "paused"],
              where: is_nil(run.lease_expires_at) or run.lease_expires_at <= ^before
            )
            |> Repo.update_all(
              set: [
                status: "interrupted",
                lease_owner: nil,
                lease_expires_at: nil,
                completed_at: nil,
                updated_at: now()
              ]
            )

          if count == 1 do
            updated = Repo.get!(Run, run_id)

            {steps, graph_events} =
              terminalize_worker_graph_in_transaction!(
                current,
                "interrupted",
                %{error_message: "Parent run lease expired"},
                [lease_generation: current.lease_generation],
                now()
              )

            {controls, control_events} =
              supersede_controls_in_transaction!(run_id, %{}, "run_interrupted")

            agent_pairs =
              terminalize_run_agents_in_transaction!(updated, "interrupted", %{
                error_message: "Parent run lease expired"
              })

            agent_events =
              Enum.flat_map(agent_pairs, fn {_agent, agent_event, control_pairs} ->
                Enum.map(control_pairs, &elem(&1, 1)) ++ [agent_event]
              end)

            event = insert_event_in_transaction!(run_id, "run.interrupted", "reconciler", %{})

            {updated, controls, steps, agent_pairs,
             graph_events ++ control_events ++ agent_events ++ [event]}
          else
            Repo.rollback(:not_orphaned)
          end
        end)
      end)

    case result do
      {:ok, {run, controls, steps, agent_pairs, events}} ->
        broadcast(run.id, {:run_updated, run})
        Enum.each(steps, &broadcast(run.id, {:run_step_updated, &1}))
        Enum.each(controls, &broadcast(run.id, {:run_control_updated, &1}))

        Enum.each(agent_pairs, fn {agent, _event, control_pairs} ->
          broadcast(run.id, {:run_agent_updated, agent})

          Enum.each(
            control_pairs,
            fn {control, _control_event} ->
              broadcast(run.id, {:run_agent_control_updated, control})
            end
          )
        end)

        Enum.each(events, &broadcast(run.id, {:run_event, &1}))
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Internal transition helpers

  defp do_transition_run(%Run{} = run, new_status, attrs) do
    do_transition_run(run, new_status, attrs, nil)
  end

  defp do_transition_run(%Run{} = run, new_status, attrs, worker_opts) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(Run, run.id)

          if worker_opts do
            assert_worker_authority!(current, worker_opts, now())
          else
            assert_unleased_mutation!(current)
          end

          if transition_allowed?(@run_transitions, current.status, new_status) do
            attrs = transition_attrs(new_status, attrs)

            updated =
              case current |> Run.changeset(attrs) |> Repo.update() do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(updated.id, "run.status_changed", "system", %{
                "from" => current.status,
                "to" => new_status
              })

            agent_pairs =
              if worker_opts &&
                   new_status in ["completed", "failed", "cancelled", "interrupted"] do
                terminalize_run_agents_in_transaction!(updated, new_status, %{
                  error_message: updated.error_message
                })
              else
                []
              end

            {updated, event, agent_pairs}
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event, agent_pairs}} ->
        broadcast(updated.id, {:run_updated, updated})
        broadcast(updated.id, {:run_event, event})

        Enum.each(agent_pairs, fn {agent, agent_event, superseded_controls} ->
          broadcast(updated.id, {:run_agent_updated, agent})
          broadcast(updated.id, {:run_event, agent_event})
          publish_superseded_agent_controls(superseded_controls)
        end)

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminalize_worker_graph_in_transaction!(
         %Run{execution_engine: "dag_v1"} = run,
         status,
         _attrs,
         opts,
         timestamp
       ) do
    attempt_status = if status == "cancelled", do: "cancelled", else: "interrupted"
    step_status = if status == "cancelled", do: "cancelled", else: "interrupted"

    attempts =
      RunStepAttempt
      |> where(
        [attempt],
        attempt.run_id == ^run.id and attempt.run_attempt == ^run.attempt and
          attempt.run_lease_generation == ^opts[:lease_generation] and
          attempt.status in ["running", "paused"]
      )
      |> Repo.all()

    Enum.each(attempts, fn attempt ->
      attempt
      |> RunStepAttempt.changeset(%{
        status: attempt_status,
        lease_owner: nil,
        lease_expires_at: nil,
        completed_at: timestamp,
        error_message: "run_#{status}",
        error_details: %{"code" => "run_#{status}"}
      })
      |> update_or_rollback!()
    end)

    steps =
      RunStep
      |> where(
        [step],
        step.run_id == ^run.id and
          step.status not in ["completed", "failed", "cancelled", "skipped", "interrupted"]
      )
      |> order_by([step], asc: step.position, asc: step.id)
      |> Repo.all()
      |> Enum.map(fn step ->
        step
        |> Changeset.change(%{
          status: step_status,
          completed_at: if(step_status == "cancelled", do: timestamp, else: nil),
          heartbeat_at: timestamp
        })
        |> update_or_rollback!()
      end)

    event =
      insert_event_in_transaction!(run.id, "run.dag_terminalized", "dag", %{
        "status" => status,
        "active_attempt_count" => length(attempts)
      })

    {steps, [event]}
  end

  defp terminalize_worker_graph_in_transaction!(run, status, attrs, _opts, _timestamp) do
    open_statuses = ~w(pending ready running paused waiting_approval blocked)
    open_steps = Enum.filter(current_attempt_run_steps(run), &(&1.status in open_statuses))

    {steps, events} =
      Enum.map_reduce(open_steps, [], fn step, events ->
        {step_status, step_attrs} = legacy_step_terminal_state(step, status, attrs)

        updated =
          step
          |> Changeset.change(
            transition_attrs(step_status, step_attrs)
            |> Map.take([
              :status,
              :progress,
              :attempt,
              :result,
              :error_message,
              :error_details,
              :started_at,
              :heartbeat_at,
              :completed_at
            ])
          )
          |> update_or_rollback!()

        event =
          insert_event_in_transaction!(run.id, "run.step_status_changed", "system", %{
            "step_id" => updated.id,
            "from" => step.status,
            "to" => step_status
          })

        {updated, [event | events]}
      end)

    {steps, Enum.reverse(events)}
  end

  defp legacy_step_terminal_state(%RunStep{kind: "execute"}, status, attrs) do
    step_status =
      case status do
        "completed" -> "completed"
        "interrupted" -> "interrupted"
        "cancelled" -> "cancelled"
        _failed -> "failed"
      end

    {step_status, attrs |> normalize_attrs() |> Map.drop([:metadata, :status])}
  end

  defp legacy_step_terminal_state(step, "failed", _attrs) do
    status =
      cond do
        step.status == "running" -> "failed"
        step.status in ["paused", "waiting_approval"] -> "cancelled"
        true -> "skipped"
      end

    {status, %{error_message: "Upstream run failed"}}
  end

  defp legacy_step_terminal_state(step, "interrupted", _attrs) do
    status =
      if step.status in ["running", "paused", "waiting_approval"],
        do: "interrupted",
        else: "skipped"

    {status, %{error_message: "Run interrupted"}}
  end

  defp legacy_step_terminal_state(_step, "cancelled", _attrs), do: {"cancelled", %{}}

  # A successful legacy executor should have completed any auxiliary stages.
  # Preserve the old behavior for an unexpectedly open non-execute step rather
  # than manufacturing a success result for work that did not finish.
  defp legacy_step_terminal_state(_step, "completed", _attrs), do: {"skipped", %{}}

  defp current_attempt_run_steps(%Run{} = run) do
    suffix = if run.attempt <= 1, do: "", else: ".#{run.attempt}"

    keys =
      ["prepare#{suffix}", "execute#{suffix}"] ++
        if(run.kind == "deep_research",
          do:
            Enum.map(
              ~w(research.plan research.search research.fetch research.synthesize),
              &"#{&1}#{suffix}"
            ),
          else: []
        )

    RunStep
    |> where([step], step.run_id == ^run.id and step.key in ^keys)
    |> order_by([step], asc: step.position, asc: step.id)
    |> Repo.all()
  end

  defp transition_step_in_transaction!(step, status, attrs) do
    unless transition_allowed?(@step_transitions, step.status, status) do
      Repo.rollback({:invalid_transition, step.status, status})
    end

    updated =
      step
      |> RunStep.changeset(transition_attrs(status, attrs))
      |> update_or_rollback!()

    event =
      insert_event_in_transaction!(updated.run_id, "run.step_status_changed", "system", %{
        "step_id" => updated.id,
        "from" => step.status,
        "to" => status
      })

    {updated, event}
  end

  defp transition_active_legacy_step_in_transaction!(run, run_status) do
    desired = if run_status == "paused", do: "paused", else: "running"

    step =
      run
      |> current_attempt_run_steps()
      |> Enum.find(&(&1.kind == "execute" and &1.status in ["running", "paused"]))

    case step do
      nil -> {nil, nil}
      %RunStep{status: ^desired} = current -> {current, nil}
      current -> transition_step_in_transaction!(current, desired, %{})
    end
  end

  defp publish_worker_finalization({:ok, {updated, run_event, steps, graph_events, agent_pairs}}) do
    broadcast(updated.id, {:run_updated, updated})
    publish_terminalized_steps(updated.id, steps, graph_events)
    broadcast(updated.id, {:run_event, run_event})
    publish_terminalized_agents(updated.id, agent_pairs)

    {:ok, updated}
  end

  defp publish_worker_finalization({:error, reason}), do: {:error, reason}

  defp publish_terminalized_steps(run_id, steps, graph_events) do
    Enum.each(steps, &broadcast(run_id, {:run_step_updated, &1}))
    Enum.each(graph_events, &broadcast(run_id, {:run_event, &1}))

    :ok
  end

  defp publish_terminalized_agents(run_id, agent_pairs) do
    Enum.each(agent_pairs, fn {agent, agent_event, superseded_controls} ->
      broadcast(run_id, {:run_agent_updated, agent})
      broadcast(run_id, {:run_event, agent_event})
      publish_superseded_agent_controls(superseded_controls)
    end)

    :ok
  end

  defp update_unleased_run_with_event(run_or_id, attrs, event_type, source, payload) do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(payload) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            assert_unleased_mutation!(current)

            updated =
              case current |> Run.changeset(attrs) |> Repo.update() do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event = insert_event_in_transaction!(updated.id, event_type, source, payload)
            {updated, event}
          end)
        end)

      publish_run_update_with_events(result)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp do_transition_step(%RunStep{} = step, new_status, attrs, worker_opts) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(RunStep, step.id)
          parent = Repo.get!(Run, current.run_id)

          if worker_opts do
            assert_worker_authority!(parent, worker_opts, now())
          else
            assert_unleased_mutation!(parent)
          end

          if transition_allowed?(@step_transitions, current.status, new_status) do
            case current
                 |> RunStep.changeset(transition_attrs(new_status, attrs))
                 |> Repo.update() do
              {:ok, updated} ->
                event =
                  insert_event_in_transaction!(
                    updated.run_id,
                    "run.step_status_changed",
                    "system",
                    %{
                      "step_id" => updated.id,
                      "from" => current.status,
                      "to" => new_status
                    }
                  )

                {updated, event}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event}} ->
        broadcast(updated.run_id, {:run_step_updated, updated})
        broadcast(updated.run_id, {:run_event, event})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_transition_command(%RunCommand{} = command, new_status, attrs, worker_opts) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(RunCommand, command.id)
          run = Repo.get!(Run, current.run_id)

          if worker_opts do
            assert_worker_authority!(run, worker_opts, now())
          else
            assert_unleased_mutation!(run)
          end

          if transition_allowed?(@command_transitions, current.status, new_status) do
            case current
                 |> RunCommand.changeset(transition_attrs(new_status, attrs))
                 |> Repo.update() do
              {:ok, updated} ->
                event =
                  insert_event_in_transaction!(
                    updated.run_id,
                    "run.command_status_changed",
                    "system",
                    %{
                      "command_id" => updated.id,
                      "from" => current.status,
                      "to" => new_status
                    }
                  )

                {updated, event}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event}} ->
        broadcast(updated.run_id, {:run_command_updated, updated})
        broadcast(updated.run_id, {:run_event, event})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_event_in_transaction!(run_id, type, source, payload) do
    {1, _} =
      from(r in Run, where: r.id == ^run_id)
      |> Repo.update_all(inc: [event_sequence: 1])

    sequence =
      from(r in Run, where: r.id == ^run_id, select: r.event_sequence)
      |> Repo.one!()

    %RunEvent{run_id: run_id}
    |> RunEvent.changeset(%{
      sequence: sequence,
      type: type,
      source: source,
      payload: payload,
      occurred_at: now()
    })
    |> Repo.insert!()
  end

  defp transition_attrs(status, attrs), do: transition_attrs(status, attrs, now())

  defp transition_attrs(status, attrs, now) do
    attrs = normalize_attrs(attrs)
    attrs = Map.put(attrs, :status, status)

    cond do
      status == "running" ->
        attrs
        |> Map.put_new(:started_at, now)
        |> Map.put(:heartbeat_at, now)
        |> Map.put(:completed_at, nil)

      status in ~w(completed failed skipped) ->
        attrs
        |> Map.put(:completed_at, now)
        |> maybe_clear_terminal_lease()
        |> maybe_complete_progress(status)

      status == "cancelled" ->
        attrs
        |> Map.put(:completed_at, now)
        |> maybe_complete_progress(status)

      status == "interrupted" ->
        Map.put(attrs, :heartbeat_at, now)

      true ->
        attrs
    end
  end

  defp maybe_complete_progress(attrs, "completed"), do: Map.put(attrs, :progress, 100)
  defp maybe_complete_progress(attrs, _status), do: attrs

  defp terminal_run_status?(status),
    do: status in ["completed", "failed", "cancelled", "interrupted"]

  defp terminal_transition_opts(_status, opts) do
    terminal_lease_ms =
      case opts[:terminal_lease_ms] do
        value when is_integer(value) ->
          value |> max(@default_terminal_lease_ms) |> min(@max_terminal_lease_ms)

        _missing_or_invalid ->
          @default_terminal_lease_ms
      end

    opts
    |> Keyword.put(:preserve_lease, true)
    |> Keyword.put(:terminal_lease_ms, terminal_lease_ms)
  end

  defp maybe_clear_terminal_lease(attrs) do
    if Map.has_key?(attrs, :lease_owner) do
      attrs
    else
      attrs |> Map.put(:lease_owner, nil) |> Map.put(:lease_expires_at, nil)
    end
  end

  defp active_lease?(%Run{lease_owner: nil}, _now), do: false
  defp active_lease?(%Run{lease_expires_at: nil}, _now), do: true

  defp active_lease?(%Run{lease_expires_at: lease_expires_at}, now) do
    DateTime.compare(lease_expires_at, now) == :gt
  end

  defp validate_worker_authority_opts(opts) do
    owner = opts[:lease_owner]
    attempt = opts[:run_attempt]
    generation = opts[:lease_generation]

    if is_binary(owner) and owner != "" and is_integer(attempt) and attempt >= 1 and
         is_integer(generation) and generation >= 1 do
      :ok
    else
      {:error, :invalid_worker_authority}
    end
  end

  defp validate_terminal_lease_opts(opts) do
    preserve_lease = Keyword.get(opts, :preserve_lease, false)
    terminal_lease_ms = Keyword.get(opts, :terminal_lease_ms, @default_terminal_lease_ms)

    if is_boolean(preserve_lease) and is_integer(terminal_lease_ms) and
         terminal_lease_ms >= 1 and terminal_lease_ms <= @max_terminal_lease_ms do
      :ok
    else
      {:error, :invalid_terminal_lease}
    end
  end

  defp maybe_extend_terminal_lease(attrs, %Run{} = run, timestamp, opts) do
    if is_binary(run.lease_owner) and is_struct(run.lease_expires_at, DateTime) do
      Map.put(attrs, :lease_expires_at, extended_terminal_lease_expiry(run, timestamp, opts))
    else
      attrs
    end
  end

  defp extended_terminal_lease_expiry(%Run{} = run, timestamp, opts) do
    minimum =
      DateTime.add(
        timestamp,
        Keyword.get(opts, :terminal_lease_ms, @default_terminal_lease_ms),
        :millisecond
      )

    case run.lease_expires_at do
      %DateTime{} = current ->
        if DateTime.compare(current, minimum) == :gt, do: current, else: minimum

      _missing ->
        minimum
    end
  end

  defp assert_worker_authority!(run, opts, timestamp) do
    valid? =
      run.status in ["running", "paused"] and run.lease_owner == opts[:lease_owner] and
        run.attempt == opts[:run_attempt] and run.lease_generation == opts[:lease_generation] and
        is_struct(run.lease_expires_at, DateTime) and
        DateTime.compare(run.lease_expires_at, timestamp) == :gt

    if valid?, do: :ok, else: Repo.rollback(:lease_not_owned)
  end

  defp assert_owned_worker_lineage!(run, opts, timestamp) do
    valid? =
      run.lease_owner == opts[:lease_owner] and run.attempt == opts[:run_attempt] and
        run.lease_generation == opts[:lease_generation] and
        is_struct(run.lease_expires_at, DateTime) and
        DateTime.compare(run.lease_expires_at, timestamp) == :gt

    if valid?, do: :ok, else: Repo.rollback(:lease_not_owned)
  end

  defp assert_control_worker_authority!(%Run{lease_owner: nil}, _worker_id, _timestamp), do: :ok

  defp assert_control_worker_authority!(%Run{} = run, worker_id, timestamp) do
    valid? =
      run.status in ["running", "paused"] and run.lease_owner == worker_id and
        is_struct(run.lease_expires_at, DateTime) and
        DateTime.compare(run.lease_expires_at, timestamp) == :gt

    if valid?, do: :ok, else: Repo.rollback(:control_worker_not_authorized)
  end

  defp assert_unleased_mutation!(%Run{lease_owner: nil}), do: :ok
  defp assert_unleased_mutation!(%Run{}), do: Repo.rollback(:worker_authority_required)

  defp maybe_worker_authority_query(query, nil), do: query

  defp maybe_worker_authority_query(query, opts) do
    from(run in query,
      where: run.attempt == ^opts[:run_attempt],
      where: run.lease_generation == ^opts[:lease_generation]
    )
  end

  defp publish_run_update_with_events({:ok, {updated, event}}) do
    broadcast(updated.id, {:run_updated, updated})
    broadcast(updated.id, {:run_event, event})
    {:ok, updated}
  end

  defp publish_run_update_with_events({:error, reason}), do: {:error, reason}

  defp transition_allowed?(transitions, old, new) do
    new in Map.get(transitions, old, [])
  end

  defp resolve_run(%Run{} = run), do: run
  defp resolve_run(id) when is_binary(id), do: get_run(id)
  defp resolve_run(_), do: nil

  defp resolve_step(%RunStep{id: id}), do: Repo.get(RunStep, id)
  defp resolve_step(id) when is_binary(id), do: Repo.get(RunStep, id)
  defp resolve_step(_), do: nil

  defp resolve_run_command(%RunCommand{id: id}), do: Repo.get(RunCommand, id)
  defp resolve_run_command(id) when is_binary(id), do: Repo.get(RunCommand, id)
  defp resolve_run_command(_), do: nil

  defp assert_run_step_scope!(_run_id, nil), do: :ok

  defp assert_run_step_scope!(run_id, run_step_id) do
    scoped? =
      Repo.exists?(
        from(step in RunStep,
          where: step.id == ^run_step_id and step.run_id == ^run_id
        )
      )

    if scoped?, do: :ok, else: Repo.rollback(:run_step_scope_mismatch)
  end

  defp assert_parent_step_scope!(_run_id, nil), do: :ok

  defp assert_parent_step_scope!(run_id, parent_step_id) do
    scoped? =
      Repo.exists?(
        from(step in RunStep,
          where: step.id == ^parent_step_id and step.run_id == ^run_id
        )
      )

    if scoped?, do: :ok, else: Repo.rollback(:parent_step_scope_mismatch)
  end

  defp assert_run_command_scope!(_run_id, nil), do: :ok

  defp assert_run_command_scope!(run_id, run_command_id) do
    scoped? =
      Repo.exists?(
        from(command in RunCommand,
          where: command.id == ^run_command_id and command.run_id == ^run_id
        )
      )

    if scoped?, do: :ok, else: Repo.rollback(:run_command_scope_mismatch)
  end

  defp assert_run_agent_parent_scope!(_run_id, _run_attempt, nil), do: :ok

  defp assert_run_agent_parent_scope!(run_id, run_attempt, parent_agent_id) do
    scoped? =
      Repo.exists?(
        from(agent in RunAgent,
          where:
            agent.id == ^parent_agent_id and agent.run_id == ^run_id and
              agent.run_attempt == ^run_attempt
        )
      )

    if scoped?, do: :ok, else: Repo.rollback(:parent_agent_scope_mismatch)
  end

  defp bounded_payload(payload) when is_map(payload) do
    payload = IexCode.Sessions.sanitize_utf8(payload)

    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_event_payload_bytes -> {:ok, payload}
      {:ok, _encoded} -> {:error, :payload_too_large}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp bounded_payload(_payload), do: {:error, :invalid_payload}

  defp validate_run_control_target(%Run{status: status})
       when status in ["completed", "failed", "cancelled"],
       do: {:error, {:run_not_controllable, status}}

  defp validate_run_control_target(%Run{}), do: :ok

  defp reject_secret_shaped_control_payload(payload) do
    if secret_shaped_agent_payload?(payload),
      do: {:error, :secret_payload_forbidden},
      else: :ok
  end

  defp run_control_semantically_equal?(%RunControl{} = existing, %Run{} = run, attrs, payload) do
    requested_kind = attr(attrs, :kind) && to_string(attr(attrs, :kind))
    requested_by = attr(attrs, :requested_by) || "local-user"

    is_binary(requested_kind) and existing.kind == requested_kind and
      existing.payload == payload and existing.requested_by == requested_by and
      existing.target_attempt == run.attempt and
      existing.target_generation == run.lease_generation
  end

  defp control_claim_expiry(%DateTime{} = claimed_at, claim_ms) do
    claim_seconds = claim_ms |> Kernel.+(999) |> div(1_000) |> max(1)
    DateTime.add(claimed_at, claim_seconds, :second)
  end

  defp run_command_semantically_equal?(%RunCommand{} = existing, %RunCommand{} = requested) do
    fields = [:run_step_id, :tool_name, :arguments, :max_attempts, :not_before]
    Enum.all?(fields, &(Map.get(existing, &1) == Map.get(requested, &1)))
  end

  # A native tool can finish immediately before its worker loses authority. A
  # command left running or explicitly uncertain therefore cannot be replayed
  # safely under a new run attempt without human review.
  defp ambiguous_command_effect?(run_id) do
    Repo.exists?(
      from(command in RunCommand,
        where:
          command.run_id == ^run_id and command.status in ["running", "interrupted", "uncertain"]
      )
    )
  end

  defp validate_event_label(type, source) when is_atom(type) or is_binary(type) do
    type = to_string(type)
    source = to_string(source)

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_.:-]{0,119}$/, type) -> {:error, :invalid_event_type}
      byte_size(source) < 1 or byte_size(source) > 160 -> {:error, :invalid_event_source}
      true -> :ok
    end
  end

  defp validate_event_label(_type, _source), do: {:error, :invalid_event_type}

  defp validate_session_project(session_id, project_id) do
    case Repo.one(
           from(session in IexCode.Sessions.Session,
             where: session.id == ^session_id,
             select: session.project_id
           )
         ) do
      ^project_id -> :ok
      nil -> {:error, {:invalid, :session_id}}
      _other_project_id -> {:error, :session_project_mismatch}
    end
  end

  defp required_id(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp drop_keys(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      acc |> Map.delete(key) |> Map.delete(Atom.to_string(key))
    end)
  end

  defp put_attr(attrs, key, value) do
    attrs |> Map.delete(Atom.to_string(key)) |> Map.put(key, value)
  end

  defp put_attr_new(attrs, key, value) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    allowed = %{
      "status" => :status,
      "progress" => :progress,
      "objective" => :objective,
      "kind" => :kind,
      "mode" => :mode,
      "priority" => :priority,
      "execution_engine" => :execution_engine,
      "token_budget" => :token_budget,
      "cost_budget_cents" => :cost_budget_cents,
      "time_budget_ms" => :time_budget_ms,
      "input_tokens" => :input_tokens,
      "output_tokens" => :output_tokens,
      "cost_cents" => :cost_cents,
      "metadata" => :metadata,
      "error_message" => :error_message,
      "error_details" => :error_details,
      "started_at" => :started_at,
      "heartbeat_at" => :heartbeat_at,
      "completed_at" => :completed_at,
      "lease_owner" => :lease_owner,
      "lease_expires_at" => :lease_expires_at,
      "not_before" => :not_before,
      "cancellation_requested_at" => :cancellation_requested_at,
      "result" => :result,
      "output" => :output,
      "attempt" => :attempt,
      "max_attempts" => :max_attempts,
      "claimed_at" => :claimed_at,
      "decided_by" => :decided_by,
      "decision_note" => :decision_note,
      "decided_at" => :decided_at,
      "desired_state" => :desired_state,
      "current_task" => :current_task,
      "lease_generation" => :lease_generation,
      "control_sequence" => :control_sequence,
      "latency_ms" => :latency_ms,
      "request_count" => :request_count,
      "last_latency_ms" => :last_latency_ms,
      "average_latency_ms" => :average_latency_ms,
      "restart_count" => :restart_count,
      "last_active_at" => :last_active_at,
      "config" => :config,
      "capabilities" => :capabilities,
      "model_provider" => :model_provider,
      "model_name" => :model_name
    }

    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {Map.get(allowed, key, key), value}
    end)
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, _field, ""), do: query
  defp maybe_where(query, field, value), do: where(query, [q], field(q, ^field) == ^value)

  defp bounded_limit(value, _default, maximum) when is_integer(value),
    do: value |> max(1) |> min(maximum)

  defp bounded_limit(_value, default, _maximum), do: default

  defp dispatchable_execution_engines(nil), do: ExecutionEngine.available_ids()

  defp dispatchable_execution_engines(requested) when is_list(requested) do
    available = MapSet.new(ExecutionEngine.available_ids())

    requested
    |> Enum.filter(&(is_binary(&1) and MapSet.member?(available, &1)))
    |> Enum.uniq()
  end

  defp dispatchable_execution_engines(_requested), do: []

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, default), do: default

  defp usage_integer(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
      if is_integer(value) and value >= 0, do: value
    end)
  end

  defp usage_budget_message(%{budget: "tokens", limit: limit}),
    do: "Run exceeded its #{limit}-token provider-reported budget"

  defp usage_budget_message(%{budget: "cost_cents", limit: limit}),
    do: "Run exceeded its #{limit}-cent provider-reported budget"

  defp usage_budget_message(nil), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp agent_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp lock_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp topic(run_id), do: "run:#{run_id}"
  defp session_topic(session_id), do: "runs:session:#{session_id}"

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, topic(run_id), event)

    case Repo.one(from(run in Run, where: run.id == ^run_id, select: run.session_id)) do
      nil -> :ok
      session_id -> Phoenix.PubSub.broadcast(IexCode.PubSub, session_topic(session_id), event)
    end
  rescue
    _ -> :ok
  end
end
