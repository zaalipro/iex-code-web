defmodule IexCode.Runs.DagScheduler do
  @moduledoc """
  Durable, generation-fenced scheduler authority for static `dag_v1` graphs.

  SQLite transactions own readiness, claims, terminalization and event order.
  PubSub is notification only. The closed registry is mutation-free: project
  handlers are replay-safe reads or pure aggregation, while registered research
  provider effects cross a separate fenced reservation and replay boundary.
  Mutation handlers remain unavailable.
  """

  import Ecto.Query, warn: false

  alias IexCode.Repo

  alias IexCode.Runs.{
    DagManifest,
    DagPayload,
    DagStepRegistry,
    Run,
    RunEvent,
    RunStep,
    RunStepAttempt
  }

  @default_lease_ms 30_000
  @max_lease_ms 300_000
  # A manifest has at most 32 direct dependencies and every registered handler
  # is capped at 256 KiB. This is the absolute per-claim dependency envelope;
  # callers can request lazy hydration so queued work retains none of it.
  @max_dependency_result_bytes 32 * 256_000
  @terminal_step_statuses ~w(completed failed cancelled skipped)

  def initialize(run_or_id, lease_owner, run_generation)
      when is_binary(lease_owner) and is_integer(run_generation) do
    transaction(fn ->
      run = load_run!(run_or_id)
      steps = load_steps(run.id)
      assert_run_authority!(run, steps)
      assert_parent_authority!(run, lease_owner, run_generation)
      promote_ready!(run, steps)
      {Repo.get!(Run, run.id), []}
    end)
    |> publish_result()
  end

  def initialize(_run, _owner, _generation), do: {:error, :invalid_dag_initialization}

  def claim_ready(run_or_id, lease_owner, run_generation, opts \\ [])

  def claim_ready(run_or_id, lease_owner, run_generation, opts)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(run_generation) and
             is_list(opts) do
    lease_ms = opts |> Keyword.get(:lease_ms, @default_lease_ms) |> max(1) |> min(@max_lease_ms)
    load_dependencies? = Keyword.get(opts, :load_dependencies?, true) == true

    transaction(fn ->
      run = load_run!(run_or_id)
      steps = load_steps(run.id)
      assert_run_authority!(run, steps)
      assert_running!(run)
      assert_parent_authority!(run, lease_owner, run_generation)
      promote_ready!(run, steps)

      candidate =
        RunStep
        |> where([step], step.run_id == ^run.id and step.status == "ready")
        |> where([step], step.attempt < step.max_attempts)
        |> order_by([step], asc: step.position, asc: step.key, asc: step.id)
        |> Repo.all()
        |> Enum.find(&retry_due?(&1, now()))

      if is_nil(candidate) do
        {:none, []}
      else
        claim_step!(run, candidate, lease_owner, lease_ms, load_dependencies?)
      end
    end)
    |> publish_result()
  end

  def claim_ready(_run_or_id, _lease_owner, _run_generation, _opts),
    do: {:error, :invalid_step_claim}

  @doc """
  Hydrates the direct dependency payloads for an already fenced active claim.

  `DagRunner` calls this only after ResourceGovernor admission, preventing queued
  tasks from retaining up to the full bounded fan-in envelope.
  """
  def load_dependency_results(attempt_or_id, lease_owner, run_generation, generation)
      when is_binary(lease_owner) and is_integer(run_generation) and is_integer(generation) do
    transaction(fn ->
      {run, step, _attempt} =
        load_active_authority!(attempt_or_id, lease_owner, run_generation, generation)

      results = fetch_dependency_results(run.id, step.depends_on)
      assert_dependency_results_bounded!(results)
      {{:ok, results}, []}
    end)
    |> publish_result()
  end

  def load_dependency_results(_attempt, _owner, _run_generation, _generation),
    do: {:error, :invalid_dependency_load}

  def heartbeat(
        attempt_or_id,
        lease_owner,
        run_generation,
        generation,
        lease_ms \\ @default_lease_ms
      )

  def heartbeat(attempt_or_id, lease_owner, run_generation, generation, lease_ms)
      when is_binary(lease_owner) and lease_owner != "" and is_integer(run_generation) and
             is_integer(generation) do
    lease_ms = lease_ms |> max(1) |> min(@max_lease_ms)

    transaction(fn ->
      {_run, step, attempt} =
        load_active_authority!(attempt_or_id, lease_owner, run_generation, generation)

      timestamp = now()

      {count, _} =
        from(current in RunStepAttempt,
          where: current.id == ^attempt.id,
          where: current.status in ["running", "paused"],
          where: current.lease_owner == ^owner_hash(lease_owner),
          where: current.lease_generation == ^generation,
          where: current.lease_expires_at > ^timestamp
        )
        |> Repo.update_all(
          set: [
            heartbeat_at: timestamp,
            lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond),
            updated_at: timestamp
          ]
        )

      if count != 1, do: Repo.rollback(:step_lease_lost)

      _ =
        Repo.update_all(from(current in RunStep, where: current.id == ^step.id),
          set: [heartbeat_at: timestamp]
        )

      {{:ok, Repo.get!(RunStepAttempt, attempt.id)}, []}
    end)
    |> publish_result()
  end

  def heartbeat(_attempt, _owner, _run_generation, _generation, _lease_ms),
    do: {:error, :invalid_step_heartbeat}

  def checkpoint(attempt_or_id, lease_owner, run_generation, generation, checkpoint, progress)
      when is_binary(lease_owner) and is_integer(run_generation) and is_integer(generation) and
             is_integer(progress) and
             progress in 0..99 do
    with {:ok, checkpoint} <- DagPayload.validate(checkpoint, max_bytes: 64_000) do
      transaction(fn ->
        {run, step, attempt} =
          load_active_authority!(attempt_or_id, lease_owner, run_generation, generation)

        descriptor = assert_descriptor!(step, attempt)

        if descriptor.replay_policy == :never do
          Repo.rollback(:checkpoint_not_supported)
        end

        timestamp = now()

        updated =
          attempt
          |> RunStepAttempt.changeset(%{
            checkpoint: checkpoint,
            checkpoint_version: descriptor.checkpoint_version,
            checkpointed_at: timestamp,
            progress: progress,
            heartbeat_at: timestamp
          })
          |> update!()

        _ =
          step
          |> RunStep.changeset(%{progress: progress, heartbeat_at: timestamp})
          |> update!()

        event =
          event!(run, "run.step_checkpointed", %{
            "step_id" => step.id,
            "attempt_id" => attempt.id,
            "progress" => progress
          })

        {{:ok, updated}, [event]}
      end)
      |> publish_result()
    end
  end

  def checkpoint(_attempt, _owner, _run_generation, _generation, _checkpoint, _progress),
    do: {:error, :invalid_step_checkpoint}

  def complete(attempt_or_id, lease_owner, run_generation, generation, result)
      when is_binary(lease_owner) and is_integer(run_generation) and is_integer(generation) and
             is_map(result) do
    transaction(fn ->
      attempt = load_attempt!(attempt_or_id)
      {run, step} = load_terminal_authority!(attempt, lease_owner, run_generation, generation)
      descriptor = assert_descriptor!(step, attempt)

      with {:ok, result} <- DagPayload.validate(result, max_bytes: descriptor.max_output_bytes),
           {:ok, digest} <- DagPayload.digest(result) do
        cond do
          attempt.status == "completed" and attempt.result_digest == digest ->
            {{:ok, attempt}, []}

          attempt.status == "completed" ->
            Repo.rollback(:completion_result_conflict)

          true ->
            {_run, _step, attempt} =
              load_active_authority!(attempt, lease_owner, run_generation, generation)

            timestamp = now()

            completed =
              attempt
              |> RunStepAttempt.changeset(%{
                status: "completed",
                progress: 100,
                result: result,
                result_digest: digest,
                lease_owner: nil,
                lease_expires_at: nil,
                completed_at: timestamp
              })
              |> update!()

            _ =
              step
              |> RunStep.changeset(%{
                status: "completed",
                progress: 100,
                result: result,
                heartbeat_at: timestamp,
                completed_at: timestamp
              })
              |> update!()

            steps = load_steps(run.id)
            promote_ready!(run, steps)
            {run, terminal_events} = finalize_run!(run)

            event =
              event!(run, "run.step_completed", %{
                "step_id" => step.id,
                "attempt_id" => attempt.id
              })

            {{:ok, completed}, [event | terminal_events]}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> publish_result()
  end

  def complete(_attempt, _owner, _run_generation, _generation, _result),
    do: {:error, :invalid_step_completion}

  def fail(attempt_or_id, lease_owner, run_generation, generation, reason)
      when is_binary(lease_owner) and is_integer(run_generation) and is_integer(generation) do
    error = error_code(reason)
    error_details = %{"code" => error}

    with {:ok, error_details} <- DagPayload.validate(error_details, max_bytes: 64_000) do
      transaction(fn ->
        {run, step, attempt} =
          load_active_authority!(attempt_or_id, lease_owner, run_generation, generation)

        descriptor = assert_descriptor!(step, attempt)
        timestamp = now()

        failed =
          attempt
          |> RunStepAttempt.changeset(%{
            status: "failed",
            error_message: error,
            error_details: error_details,
            lease_owner: nil,
            lease_expires_at: nil,
            completed_at: timestamp
          })
          |> update!()

        retry? = step.attempt < step.max_attempts and descriptor.replay_policy == :safe

        failed =
          if retry? do
            retry_at = retry_not_before(step.attempt, timestamp)

            retriable =
              failed
              |> RunStepAttempt.changeset(%{retry_not_before: retry_at})
              |> update!()

            step |> RunStep.changeset(%{status: "ready", heartbeat_at: timestamp}) |> update!()
            retriable
          else
            step
            |> RunStep.changeset(%{
              status: "failed",
              error_message: failed.error_message,
              error_details: error_details,
              heartbeat_at: timestamp,
              completed_at: timestamp
            })
            |> update!()

            skip_descendants!(run.id, [step.key], timestamp)
            failed
          end

        {run, terminal_events} = finalize_run!(run)

        event =
          event!(run, "run.step_failed", %{
            "step_id" => step.id,
            "attempt_id" => attempt.id,
            "retrying" => retry?
          })

        {{:ok, failed}, [event | terminal_events]}
      end)
      |> publish_result()
    end
  end

  def fail(_attempt, _owner, _run_generation, _generation, _reason),
    do: {:error, :invalid_step_failure}

  def reconcile_expired(before \\ nil) do
    before = before || now()

    RunStepAttempt
    |> where(
      [attempt],
      attempt.status in ["running", "paused"] and attempt.lease_expires_at <= ^before
    )
    |> order_by([attempt], asc: attempt.lease_expires_at, asc: attempt.id)
    |> Repo.all()
    |> Enum.map(&reconcile_one(&1, before))
    |> Enum.filter(&match?({:ok, _attempt}, &1))
  end

  @doc "Reconciles active DAG attempts and logical nodes after the parent is durably terminal."
  def reconcile_terminal_run(run_or_id) do
    transaction(fn ->
      run = load_run!(run_or_id)
      steps = load_steps(run.id)

      if run.execution_engine != "dag_v1", do: Repo.rollback(:not_a_dag_run)

      if run.status not in ["completed", "failed", "cancelled", "interrupted"] do
        Repo.rollback({:run_not_terminal, run.status})
      end

      assert_manifest_hash!(run, steps)
      timestamp = now()
      attempt_status = if run.status == "cancelled", do: "cancelled", else: "interrupted"

      active_attempts =
        Repo.all(
          from attempt in RunStepAttempt,
            where: attempt.run_id == ^run.id,
            where: attempt.run_attempt == ^run.attempt,
            where: attempt.run_lease_generation == ^run.lease_generation,
            where: attempt.status in ["running", "paused"]
        )

      Enum.each(active_attempts, fn attempt ->
        attempt
        |> RunStepAttempt.changeset(%{
          status: attempt_status,
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: timestamp,
          error_message: "parent_run_#{run.status}",
          error_details: %{"code" => "parent_run_#{run.status}"}
        })
        |> update!()
      end)

      reset_steps =
        Enum.filter(
          steps,
          &(&1.status not in ["completed", "failed", "cancelled", "skipped", "interrupted"])
        )

      updated_steps =
        Enum.map(reset_steps, fn step ->
          step_status =
            cond do
              run.status == "cancelled" -> "cancelled"
              step.status in ["running", "paused", "interrupted"] -> "interrupted"
              true -> "skipped"
            end

          step
          |> RunStep.changeset(%{
            status: step_status,
            heartbeat_at: timestamp,
            completed_at: if(step_status in ["cancelled", "skipped"], do: timestamp, else: nil),
            error_message: "Parent run #{run.status}"
          })
          |> update!()
        end)

      changed? = active_attempts != [] or reset_steps != []

      events =
        if changed? do
          step_events =
            Enum.map(updated_steps, fn step ->
              event!(run, "run.step_reconciled", %{
                "step_id" => step.id,
                "status" => step.status
              })
            end)

          step_events ++
            [
              event!(run, "run.dag_terminal_reconciled", %{
                "status" => run.status,
                "attempt_count" => length(active_attempts),
                "step_count" => length(reset_steps)
              })
            ]
        else
          []
        end

      {{:ok,
        %{status: run.status, attempts: length(active_attempts), steps: length(reset_steps)}},
       events}
    end)
    |> publish_result()
  end

  def terminalize_active(run_or_id, lease_owner, run_generation, terminal_status)
      when is_binary(lease_owner) and is_integer(run_generation) and
             terminal_status in ["cancelled", "failed", "interrupted"] do
    transaction(fn ->
      run = load_run!(run_or_id)
      steps = load_steps(run.id)
      assert_run_authority!(run, steps)
      timestamp = now()
      attempt_status = if terminal_status == "cancelled", do: "cancelled", else: "interrupted"

      active_attempts =
        Repo.all(
          from attempt in RunStepAttempt,
            where: attempt.run_id == ^run.id,
            where: attempt.run_attempt == ^run.attempt,
            where: attempt.run_lease_generation == ^run_generation,
            where: attempt.status in ["running", "paused"]
        )

      authorize_terminalization!(run, active_attempts, lease_owner, run_generation)

      Enum.each(active_attempts, fn attempt ->
        attempt
        |> RunStepAttempt.changeset(%{
          status: attempt_status,
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: timestamp,
          error_message: "run_#{terminal_status}",
          error_details: %{"code" => "run_#{terminal_status}"}
        })
        |> update!()
      end)

      Enum.each(steps, fn step ->
        if step.status not in @terminal_step_statuses do
          step_status = if terminal_status == "cancelled", do: "cancelled", else: "interrupted"

          step
          |> RunStep.changeset(%{
            status: step_status,
            completed_at: if(step_status == "cancelled", do: timestamp, else: nil),
            heartbeat_at: timestamp
          })
          |> update!()
        end
      end)

      event =
        event!(run, "run.dag_terminalized", %{
          "status" => terminal_status,
          "active_attempt_count" => length(active_attempts)
        })

      {{:ok, %{attempts: length(active_attempts), status: terminal_status}}, [event]}
    end)
    |> publish_result()
  end

  def terminalize_active(_run, _owner, _generation, _status),
    do: {:error, :invalid_dag_terminalization}

  def set_paused(run_or_id, lease_owner, run_generation, paused?)
      when is_binary(lease_owner) and is_integer(run_generation) and is_boolean(paused?) do
    transaction(fn ->
      run = load_run!(run_or_id)
      steps = load_steps(run.id)
      assert_run_authority!(run, steps)
      assert_parent_authority!(run, lease_owner, run_generation)
      expected_run_status = if paused?, do: "paused", else: "running"

      if run.status == expected_run_status do
        set_attempt_pause_state!(run, run_generation, paused?)
      else
        if run.status in ["running", "paused"] do
          {{:ok, %{paused: run.status == "paused", attempts: 0, stale: true}}, []}
        else
          Repo.rollback({:run_status_mismatch, run.status})
        end
      end
    end)
    |> publish_result()
  end

  def set_paused(_run, _owner, _generation, _paused), do: {:error, :invalid_dag_pause}

  defp set_attempt_pause_state!(run, run_generation, paused?) do
    from_attempt = if paused?, do: "running", else: "paused"
    to_attempt = if paused?, do: "paused", else: "running"
    timestamp = now()

    attempts =
      Repo.all(
        from attempt in RunStepAttempt,
          where: attempt.run_id == ^run.id,
          where: attempt.run_attempt == ^run.attempt,
          where: attempt.run_lease_generation == ^run_generation,
          where: attempt.status == ^from_attempt
      )

    updated_steps =
      Enum.map(attempts, fn attempt ->
        attempt
        |> RunStepAttempt.changeset(%{status: to_attempt, heartbeat_at: timestamp})
        |> update!()

        step = Repo.get!(RunStep, attempt.run_step_id)
        step |> RunStep.changeset(%{status: to_attempt, heartbeat_at: timestamp}) |> update!()
      end)

    events =
      if attempts == [] do
        []
      else
        step_events =
          Enum.map(updated_steps, fn step ->
            event!(run, "run.step_pause_changed", %{
              "step_id" => step.id,
              "paused" => paused?
            })
          end)

        step_events ++
          [
            event!(run, "run.dag_pause_changed", %{
              "paused" => paused?,
              "active_attempt_count" => length(attempts)
            })
          ]
      end

    {{:ok, %{paused: paused?, attempts: length(attempts), stale: false}}, events}
  end

  def list_attempts(run_or_id, opts \\ []) do
    run_id = id(run_or_id)

    RunStepAttempt
    |> where([attempt], attempt.run_id == ^run_id)
    |> order_by([attempt], desc: attempt.inserted_at, desc: attempt.id)
    |> limit(^bounded_limit(opts[:limit], 200, 1_000))
    |> Repo.all()
  end

  def projection(run_or_id) do
    run_id = id(run_or_id)
    timestamp = now()

    attempts =
      list_attempts(run_id, limit: 1_000)
      |> Enum.group_by(& &1.run_step_id)
      |> Map.new(fn {step_id, values} -> {step_id, List.first(values)} end)

    steps = load_steps(run_id)
    by_key = Map.new(steps, &{&1.key, &1.status})

    Enum.map(steps, fn step ->
      latest = Map.get(attempts, step.id)

      %{
        id: step.id,
        key: step.key,
        kind: step.kind,
        title: step.title,
        position: step.position,
        status: step.status,
        progress: step.progress,
        attempt: step.attempt,
        max_attempts: step.max_attempts,
        depends_on: step.depends_on,
        readiness_reason: readiness_reason(step, by_key),
        lease_health: lease_health(latest, timestamp),
        latest_attempt: redact_attempt(latest)
      }
    end)
  end

  defp claim_step!(run, step, raw_owner, lease_ms, load_dependencies?) do
    descriptor = assert_descriptor!(step)
    owner_hash = owner_hash(raw_owner)
    attempt_number = step.attempt + 1
    generation = attempt_number
    timestamp = now()
    execution_key = "#{run.attempt}:#{step.key}:#{attempt_number}"

    {count, _} =
      from(current in RunStep,
        where: current.id == ^step.id,
        where: current.run_id == ^run.id,
        where: current.status == "ready",
        where: current.attempt == ^step.attempt
      )
      |> Repo.update_all(
        set: [
          status: "running",
          heartbeat_at: timestamp,
          started_at: step.started_at || timestamp,
          updated_at: timestamp
        ],
        inc: [attempt: 1]
      )

    if count != 1, do: Repo.rollback(:step_claim_race)

    attempt =
      %RunStepAttempt{run_id: run.id, run_step_id: step.id}
      |> RunStepAttempt.changeset(%{
        run_attempt: run.attempt,
        run_lease_generation: run.lease_generation,
        attempt: attempt_number,
        execution_key: execution_key,
        manifest_hash: run.manifest_hash,
        handler_kind: step.kind,
        handler_version: descriptor.version,
        effect_class: Atom.to_string(descriptor.effect_class),
        replay_policy: Atom.to_string(descriptor.replay_policy),
        status: "running",
        run_owner: owner_hash,
        claim_owner: owner_hash,
        lease_owner: owner_hash,
        lease_generation: generation,
        lease_expires_at: DateTime.add(timestamp, lease_ms, :millisecond),
        heartbeat_at: timestamp,
        started_at: timestamp
      })
      |> insert!()

    dependencies =
      if load_dependencies? do
        results = fetch_dependency_results(run.id, step.depends_on)
        assert_dependency_results_bounded!(results)
        results
      else
        %{}
      end

    event =
      event!(run, "run.step_claimed", %{
        "step_id" => step.id,
        "attempt_id" => attempt.id,
        "generation" => generation
      })

    {{:ok,
      %{
        attempt: attempt,
        step: Repo.get!(RunStep, step.id),
        dependency_results: dependencies,
        dependency_results_loaded?: load_dependencies? or step.depends_on == []
      }}, [event]}
  end

  defp load_active_authority!(attempt_or_id, lease_owner, run_generation, generation) do
    attempt = load_attempt!(attempt_or_id)
    run = Repo.get!(Run, attempt.run_id)
    step = Repo.get!(RunStep, attempt.run_step_id)
    timestamp = now()

    cond do
      step.run_id != run.id ->
        Repo.rollback(:attempt_scope_mismatch)

      run.execution_engine != "dag_v1" ->
        Repo.rollback(:not_a_dag_run)

      run.status not in ["running", "paused"] ->
        Repo.rollback({:run_not_active, run.status})

      not live_parent_authority?(run, attempt, lease_owner, run_generation) ->
        Repo.rollback(:run_lease_lost)

      run.attempt != attempt.run_attempt ->
        Repo.rollback(:stale_run_attempt)

      run.lease_generation != run_generation or run_generation != attempt.run_lease_generation ->
        Repo.rollback(:stale_run_generation)

      run.manifest_hash != attempt.manifest_hash ->
        Repo.rollback(:manifest_drift)

      attempt.status not in ["running", "paused"] ->
        Repo.rollback(:step_attempt_not_active)

      attempt.lease_generation != generation ->
        Repo.rollback(:step_lease_lost)

      not secure_owner?(attempt.lease_owner, lease_owner) ->
        Repo.rollback(:step_lease_lost)

      not secure_owner?(attempt.claim_owner, lease_owner) ->
        Repo.rollback(:step_lease_lost)

      DateTime.compare(attempt.lease_expires_at, timestamp) != :gt ->
        Repo.rollback(:step_lease_expired)

      true ->
        assert_manifest_hash!(run, load_steps(run.id))
        _ = assert_descriptor!(step, attempt)
        {run, step, attempt}
    end
  end

  defp load_terminal_authority!(attempt, lease_owner, run_generation, generation) do
    run = Repo.get!(Run, attempt.run_id)
    step = Repo.get!(RunStep, attempt.run_step_id)

    cond do
      step.run_id != run.id ->
        Repo.rollback(:attempt_scope_mismatch)

      run.execution_engine != "dag_v1" ->
        Repo.rollback(:not_a_dag_run)

      run.attempt != attempt.run_attempt ->
        Repo.rollback(:stale_run_attempt)

      run.lease_generation != run_generation or run_generation != attempt.run_lease_generation ->
        Repo.rollback(:stale_run_generation)

      run.manifest_hash != attempt.manifest_hash ->
        Repo.rollback(:manifest_drift)

      attempt.lease_generation != generation ->
        Repo.rollback(:step_lease_lost)

      not secure_owner?(attempt.run_owner, lease_owner) ->
        Repo.rollback(:run_lease_lost)

      not secure_owner?(attempt.claim_owner, lease_owner) ->
        Repo.rollback(:step_lease_lost)

      true ->
        if attempt.status != "completed" do
          assert_parent_authority!(run, lease_owner, run_generation)
        end

        assert_manifest_hash!(run, load_steps(run.id))
        {run, step}
    end
  end

  defp reconcile_one(attempt, before) do
    transaction(fn ->
      timestamp = now()

      {count, _} =
        from(current in RunStepAttempt,
          where: current.id == ^attempt.id,
          where: current.status in ["running", "paused"],
          where: current.lease_owner == ^attempt.lease_owner,
          where: current.lease_generation == ^attempt.lease_generation,
          where: current.lease_expires_at <= ^before
        )
        |> Repo.update_all(
          set: [
            status: "interrupted",
            lease_owner: nil,
            lease_expires_at: nil,
            completed_at: timestamp,
            error_message: "lease_expired",
            error_details: %{"code" => "lease_expired"},
            updated_at: timestamp
          ]
        )

      if count != 1, do: Repo.rollback(:not_expired)

      interrupted = Repo.get!(RunStepAttempt, attempt.id)
      step = Repo.get!(RunStep, interrupted.run_step_id)
      run = Repo.get!(Run, interrupted.run_id)

      parent_current? =
        step.run_id == run.id and run.execution_engine == "dag_v1" and
          run.status in ["running", "paused"] and run.attempt == interrupted.run_attempt and
          run.lease_generation == interrupted.run_lease_generation and
          run.manifest_hash == interrupted.manifest_hash and not is_nil(run.lease_owner) and
          secure_owner?(interrupted.run_owner, run.lease_owner) and
          is_struct(run.lease_expires_at, DateTime) and
          DateTime.compare(run.lease_expires_at, now()) == :gt

      lineage_current? =
        step.run_id == run.id and run.execution_engine == "dag_v1" and
          run.attempt == interrupted.run_attempt and
          run.lease_generation == interrupted.run_lease_generation and
          run.manifest_hash == interrupted.manifest_hash

      if parent_current? do
        assert_manifest_hash!(run, load_steps(run.id))
        descriptor = assert_descriptor!(step, interrupted)
        retry? = step.attempt < step.max_attempts and descriptor.replay_policy == :safe

        if retry? do
          retry_at = retry_not_before(step.attempt, timestamp)

          interrupted
          |> RunStepAttempt.changeset(%{retry_not_before: retry_at})
          |> update!()

          step |> RunStep.changeset(%{status: "ready", heartbeat_at: timestamp}) |> update!()
        else
          step |> RunStep.changeset(%{status: "failed", completed_at: timestamp}) |> update!()
          skip_descendants!(run.id, [step.key], timestamp)
        end

        {run, terminal_events} = finalize_run!(run)

        event =
          event!(run, "run.step_interrupted", %{
            "step_id" => step.id,
            "attempt_id" => interrupted.id,
            "retrying" => retry?
          })

        {{:ok, interrupted}, [event | terminal_events]}
      else
        if lineage_current? and step.status in ["running", "paused"] do
          step
          |> RunStep.changeset(%{
            status: "interrupted",
            heartbeat_at: timestamp,
            error_message: "Parent run lease is not active"
          })
          |> update!()
        end

        {{:ok, interrupted}, []}
      end
    end)
    |> publish_result()
  end

  defp assert_run_authority!(run, steps) do
    if run.execution_engine != "dag_v1", do: Repo.rollback(:not_a_dag_run)
    if run.attempt < 1, do: Repo.rollback(:run_not_claimed)
    if run.lease_generation < 1, do: Repo.rollback(:run_generation_missing)
    assert_manifest_hash!(run, steps)
  end

  defp assert_parent_authority!(run, lease_owner, generation) do
    timestamp = now()

    cond do
      run.lease_generation != generation -> Repo.rollback(:run_lease_lost)
      run.lease_owner != lease_owner -> Repo.rollback(:run_lease_lost)
      not is_struct(run.lease_expires_at, DateTime) -> Repo.rollback(:run_lease_lost)
      DateTime.compare(run.lease_expires_at, timestamp) != :gt -> Repo.rollback(:run_lease_lost)
      true -> :ok
    end
  end

  defp authorize_terminalization!(run, attempts, lease_owner, generation) do
    if run.status in ["running", "paused"] do
      assert_parent_authority!(run, lease_owner, generation)
    else
      valid? =
        run.lease_generation == generation and attempts != [] and
          Enum.all?(attempts, fn attempt ->
            attempt.run_attempt == run.attempt and attempt.run_lease_generation == generation and
              attempt.manifest_hash == run.manifest_hash and
              secure_owner?(attempt.run_owner, lease_owner)
          end)

      if valid?, do: :ok, else: Repo.rollback(:run_lease_lost)
    end
  end

  defp live_parent_authority?(run, attempt, lease_owner, run_generation) do
    timestamp = now()

    run.lease_owner == lease_owner and run.lease_generation == run_generation and
      run_generation == attempt.run_lease_generation and
      secure_owner?(attempt.run_owner, lease_owner) and is_struct(run.lease_expires_at, DateTime) and
      DateTime.compare(run.lease_expires_at, timestamp) == :gt
  end

  defp assert_manifest_hash!(run, steps) do
    manifest = Enum.map(steps, &manifest_step/1)

    case DagManifest.hash(manifest) do
      {:ok, hash} when hash == run.manifest_hash -> :ok
      {:ok, _hash} -> Repo.rollback(:manifest_drift)
      {:error, reason} -> Repo.rollback({:invalid_manifest, reason})
    end
  end

  defp manifest_step(step) do
    %{
      key: step.key,
      kind: step.kind,
      title: step.title,
      depends_on: step.depends_on,
      params: step.params,
      max_attempts: step.max_attempts
    }
  end

  defp assert_descriptor!(step, attempt \\ nil) do
    descriptor = DagStepRegistry.descriptor!(step.kind)

    valid_step? =
      step.handler_version == descriptor.version and
        step.effect_class == Atom.to_string(descriptor.effect_class) and
        step.replay_policy == Atom.to_string(descriptor.replay_policy) and
        step.resource_spec == %{"contract" => descriptor.resource_contract} and
        step.timeout_ms == descriptor.default_timeout_ms

    valid_attempt? =
      is_nil(attempt) or
        (attempt.handler_kind == step.kind and attempt.handler_version == descriptor.version and
           attempt.effect_class == Atom.to_string(descriptor.effect_class) and
           attempt.replay_policy == Atom.to_string(descriptor.replay_policy))

    if valid_step? and valid_attempt?,
      do: descriptor,
      else: Repo.rollback(:handler_descriptor_drift)
  rescue
    MatchError -> Repo.rollback(:handler_unavailable)
  end

  defp promote_ready!(run, steps) do
    statuses = Map.new(steps, &{&1.key, &1.status})
    timestamp = now()

    steps
    |> Enum.filter(&(&1.status in ["pending", "blocked"]))
    |> Enum.each(fn step ->
      dependency_statuses = Enum.map(step.depends_on, &Map.get(statuses, &1))

      cond do
        Enum.any?(dependency_statuses, &(&1 in ["failed", "cancelled", "skipped"])) ->
          step |> RunStep.changeset(%{status: "skipped", completed_at: timestamp}) |> update!()

        Enum.all?(dependency_statuses, &(&1 == "completed")) ->
          step |> RunStep.changeset(%{status: "ready"}) |> update!()

        true ->
          :ok
      end
    end)

    update_run_progress!(run)
  end

  defp skip_descendants!(run_id, failed_keys, timestamp) do
    steps = load_steps(run_id)

    newly_skipped =
      steps
      |> Enum.filter(fn step ->
        step.status not in @terminal_step_statuses and
          Enum.any?(step.depends_on, &(&1 in failed_keys))
      end)
      |> Enum.map(fn step ->
        step |> RunStep.changeset(%{status: "skipped", completed_at: timestamp}) |> update!()
        step.key
      end)

    if newly_skipped != [], do: skip_descendants!(run_id, newly_skipped, timestamp)
  end

  defp finalize_run!(run) do
    steps = load_steps(run.id)
    update_run_progress!(run)

    if run.status in ["completed", "failed", "cancelled", "interrupted"] do
      {Repo.get!(Run, run.id), []}
    else
      finalize_active_run!(run, steps)
    end
  end

  defp finalize_active_run!(run, steps) do
    if steps != [] and Enum.all?(steps, &(&1.status in @terminal_step_statuses)) do
      failed? = Enum.any?(steps, &(&1.status in ["failed", "cancelled"]))
      status = if failed?, do: "failed", else: "completed"
      timestamp = now()

      updated =
        run
        |> Run.changeset(%{
          status: status,
          progress: 100,
          completed_at: timestamp,
          lease_owner: nil,
          lease_expires_at: nil,
          error_message: if(failed?, do: "One or more DAG steps failed", else: nil),
          error_details: if(failed?, do: %{"reason" => "dag_step_failed"}, else: nil)
        })
        |> update!()

      event = event!(updated, "run.status_changed", %{"from" => run.status, "to" => status})
      {updated, [event]}
    else
      {run, []}
    end
  end

  defp retry_not_before(attempt_number, timestamp) do
    backoff_ms = min(250 * Integer.pow(2, max(attempt_number - 1, 0)), 30_000)
    DateTime.add(timestamp, backoff_ms, :millisecond)
  end

  defp retry_due?(%RunStep{attempt: 0}, _timestamp), do: true

  defp retry_due?(step, timestamp) do
    latest =
      Repo.one(
        from attempt in RunStepAttempt,
          where: attempt.run_step_id == ^step.id,
          order_by: [desc: attempt.attempt],
          limit: 1
      )

    is_nil(latest) or is_nil(latest.retry_not_before) or
      DateTime.compare(latest.retry_not_before, timestamp) != :gt
  end

  defp update_run_progress!(run) do
    steps = load_steps(run.id)

    progress =
      if steps == [] do
        0
      else
        div(Enum.sum(Enum.map(steps, &(&1.progress || 0))), length(steps))
      end

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [progress: progress, updated_at: now()]
    )
  end

  defp fetch_dependency_results(_run_id, []), do: %{}

  defp fetch_dependency_results(run_id, keys) do
    RunStep
    |> where([step], step.run_id == ^run_id and step.key in ^keys and step.status == "completed")
    |> select([step], {step.key, step.result})
    |> Repo.all()
    |> Map.new()
  end

  defp assert_dependency_results_bounded!(results) do
    total_bytes =
      Enum.reduce(results, 0, fn {_key, result}, total ->
        case DagPayload.canonical_json(result) do
          {:ok, encoded} -> total + byte_size(encoded)
          {:error, reason} -> Repo.rollback({:invalid_dependency_result, reason})
        end
      end)

    if total_bytes > @max_dependency_result_bytes,
      do: Repo.rollback({:dependency_results_too_large, @max_dependency_result_bytes}),
      else: :ok
  end

  defp readiness_reason(%RunStep{status: "ready"}, _statuses), do: :ready
  defp readiness_reason(%RunStep{status: "running"}, _statuses), do: :running
  defp readiness_reason(%RunStep{status: "failed"}, _statuses), do: :failed
  defp readiness_reason(%RunStep{status: "skipped"}, _statuses), do: :dependency_failed

  defp readiness_reason(%RunStep{status: status}, _statuses)
       when status in @terminal_step_statuses,
       do: :terminal

  defp readiness_reason(step, statuses) do
    if Enum.any?(step.depends_on, &(Map.get(statuses, &1) in ["failed", "cancelled", "skipped"])),
      do: :dependency_failed,
      else: :waiting_dependencies
  end

  defp lease_health(nil, _timestamp), do: :none

  defp lease_health(%RunStepAttempt{status: status}, _timestamp)
       when status not in ["running", "paused"],
       do: :terminal

  defp lease_health(%RunStepAttempt{lease_expires_at: expiry}, timestamp),
    do: if(DateTime.compare(expiry, timestamp) == :gt, do: :live, else: :expired)

  defp redact_attempt(nil), do: nil

  defp redact_attempt(attempt) do
    Map.take(attempt, [
      :id,
      :run_step_id,
      :run_attempt,
      :attempt,
      :status,
      :lease_generation,
      :lease_expires_at,
      :heartbeat_at,
      :progress,
      :checkpoint_version,
      :checkpointed_at,
      :retry_not_before,
      :started_at,
      :completed_at
    ])
  end

  defp event!(run, type, payload) do
    {1, _} =
      Repo.update_all(from(current in Run, where: current.id == ^run.id),
        inc: [event_sequence: 1]
      )

    sequence =
      Repo.one!(from current in Run, where: current.id == ^run.id, select: current.event_sequence)

    %RunEvent{run_id: run.id}
    |> RunEvent.changeset(%{
      sequence: sequence,
      type: type,
      source: "dag",
      payload: payload,
      occurred_at: now_second()
    })
    |> insert!()
  end

  defp transaction(fun), do: Repo.retry_on_busy(fn -> Repo.transaction(fun) end)

  defp publish_result({:ok, {reply, events}}) do
    events = Enum.sort_by(events, & &1.sequence)

    Enum.each(events, fn event ->
      Phoenix.PubSub.broadcast(IexCode.PubSub, "run:#{event.run_id}", {:run_event, event})

      case Map.get(event.payload, "step_id") do
        step_id when is_binary(step_id) ->
          if step = Repo.get(RunStep, step_id) do
            Phoenix.PubSub.broadcast(
              IexCode.PubSub,
              "run:#{event.run_id}",
              {:run_step_updated, step}
            )
          end

        _step_id ->
          :ok
      end
    end)

    events
    |> Enum.map(& &1.run_id)
    |> Enum.uniq()
    |> Enum.each(fn run_id ->
      if run = Repo.get(Run, run_id) do
        Phoenix.PubSub.broadcast(IexCode.PubSub, "run:#{run_id}", {:run_updated, run})

        Phoenix.PubSub.broadcast(
          IexCode.PubSub,
          "runs:session:#{run.session_id}",
          {:run_updated, run}
        )
      end
    end)

    reply
  end

  defp publish_result({:error, reason}), do: {:error, reason}

  defp load_run!(%Run{id: id}), do: Repo.get!(Run, id)
  defp load_run!(id) when is_binary(id), do: Repo.get!(Run, id)
  defp load_attempt!(%RunStepAttempt{id: id}), do: Repo.get!(RunStepAttempt, id)
  defp load_attempt!(id) when is_binary(id), do: Repo.get!(RunStepAttempt, id)

  defp load_steps(run_id),
    do:
      Repo.all(
        from step in RunStep,
          where: step.run_id == ^run_id,
          order_by: [asc: step.position, asc: step.key],
          # Scheduler authority needs manifest/lifecycle metadata, never prior
          # result bodies. Dependency payloads cross only the explicit bounded
          # loader above.
          select:
            struct(step, [
              :id,
              :run_id,
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
              :error_message,
              :started_at,
              :heartbeat_at,
              :completed_at
            ])
      )

  defp assert_running!(%Run{status: "running"}), do: :ok
  defp assert_running!(%Run{status: status}), do: Repo.rollback({:run_not_running, status})
  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp owner_hash(owner), do: :crypto.hash(:sha256, owner) |> Base.encode16(case: :lower)

  defp secure_owner?(stored_hash, owner) when is_binary(stored_hash) do
    presented = owner_hash(owner)

    byte_size(stored_hash) == byte_size(presented) and
      Plug.Crypto.secure_compare(stored_hash, presented)
  end

  defp secure_owner?(_stored, _owner), do: false
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp now_second, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp bounded_limit(value, _default, maximum) when is_integer(value),
    do: value |> max(1) |> min(maximum)

  defp bounded_limit(_value, default, _maximum), do: default

  defp error_code(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 160)

  defp error_code({code, _details}) when is_atom(code),
    do: code |> Atom.to_string() |> String.slice(0, 160)

  defp error_code(_reason), do: "step_execution_failed"

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, error} -> Repo.rollback(error)
    end
  end
end
