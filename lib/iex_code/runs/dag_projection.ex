defmodule IexCode.Runs.DagProjection do
  @moduledoc """
  Builds the bounded, redacted Mission Control projection for a `dag_v1` run.

  This presenter is deliberately strict. Missing dependencies, duplicate keys,
  cycles, cross-run rows, and malformed attempt scope fail closed rather than
  producing a plausible but incorrect execution graph. Executor params,
  results, checkpoint payloads, lease owners, and execution keys never cross
  this boundary.
  """

  alias IexCode.Runs.{ExecutionEngine, Run}

  @max_steps 128
  @max_attempt_rows 2_048
  @terminal_statuses ~w(completed failed cancelled skipped)
  @failed_dependency_statuses ~w(failed cancelled interrupted)
  @safe_error_code ~r/^[A-Za-z0-9_.:-]{1,120}$/

  @type projection :: %{
          engine: String.t(),
          available?: boolean(),
          revision: non_neg_integer(),
          summary: map(),
          layers: [[map()]]
        }

  @spec build(Run.t() | map(), [map()], [map()], keyword()) ::
          {:ok, projection()} | {:error, term()}
  def build(run, steps, attempts, opts \\ [])

  def build(run, steps, attempts, opts)
      when is_map(run) and is_list(steps) and is_list(attempts) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_ms = positive_integer(Keyword.get(opts, :stale_after_ms), 30_000)

    with {:ok, run_scope} <- validate_run(run),
         :ok <- validate_bounds(steps, attempts),
         {:ok, normalized_steps} <- normalize_steps(steps, run_scope.id),
         :ok <- validate_dependencies(normalized_steps),
         {:ok, layers} <- topological_layers(normalized_steps),
         {:ok, latest_attempts} <-
           normalize_latest_attempts(attempts, normalized_steps, run_scope),
         nodes <-
           project_nodes(normalized_steps, latest_attempts, now, stale_after_ms),
         layered_nodes <- map_layers(layers, nodes) do
      {:ok,
       %{
         engine: run_scope.engine,
         available?: engine_available?(run_scope.engine),
         revision: run_scope.revision,
         summary: summarize(nodes),
         layers: layered_nodes
       }}
    end
  end

  def build(_run, _steps, _attempts, _opts), do: {:error, :invalid_dag_projection_input}

  defp validate_run(run) do
    id = value(run, :id)
    engine = value(run, :execution_engine, "legacy_v1")
    attempt = value(run, :attempt, 0)
    revision = value(run, :event_sequence, 0)

    cond do
      not bounded_string?(id, 1, 160) -> {:error, :invalid_run_scope}
      engine != "dag_v1" -> {:error, {:not_dag_run, engine}}
      not is_integer(attempt) or attempt < 0 -> {:error, :invalid_run_attempt}
      not is_integer(revision) or revision < 0 -> {:error, :invalid_run_revision}
      true -> {:ok, %{id: id, engine: engine, attempt: attempt, revision: revision}}
    end
  end

  defp validate_bounds(steps, attempts) do
    cond do
      steps == [] ->
        {:error, :empty_dag_projection}

      length(steps) > @max_steps ->
        {:error, {:dag_projection_too_large, @max_steps}}

      length(attempts) > @max_attempt_rows ->
        {:error, {:dag_attempt_projection_too_large, @max_attempt_rows}}

      true ->
        :ok
    end
  end

  defp normalize_steps(steps, run_id) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, fallback_position}, {:ok, acc} ->
      case normalize_step(step, run_id, fallback_position) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        normalized = Enum.reverse(reversed)
        keys = Enum.map(normalized, & &1.key)
        ids = Enum.map(normalized, & &1.id)

        cond do
          length(keys) != MapSet.size(MapSet.new(keys)) -> {:error, :duplicate_dag_step_key}
          length(ids) != MapSet.size(MapSet.new(ids)) -> {:error, :duplicate_dag_step_id}
          true -> {:ok, normalized}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_step(step, run_id, fallback_position) when is_map(step) do
    id = value(step, :id)
    row_run_id = value(step, :run_id, run_id)
    key = value(step, :key)
    title = value(step, :title)
    kind = value(step, :kind)
    status = normalize_status(value(step, :status, "pending"))
    dependencies = value(step, :depends_on, [])
    position = value(step, :position, fallback_position)

    cond do
      row_run_id != run_id ->
        {:error, {:dag_step_scope_mismatch, id}}

      not bounded_string?(id, 1, 160) ->
        {:error, :invalid_dag_step_id}

      not bounded_string?(key, 1, 160) ->
        {:error, {:invalid_dag_step_key, id}}

      not bounded_string?(title, 1, 500) ->
        {:error, {:invalid_dag_step_title, key}}

      not bounded_string?(kind, 1, 80) ->
        {:error, {:invalid_dag_step_kind, key}}

      status == nil ->
        {:error, {:invalid_dag_step_status, key}}

      not is_integer(position) or position < 0 ->
        {:error, {:invalid_dag_step_position, key}}

      not valid_dependencies?(dependencies) ->
        {:error, {:invalid_dag_dependencies, key}}

      true ->
        {:ok,
         %{
           id: id,
           key: key,
           title: title,
           kind: kind,
           status: status,
           position: position,
           progress: bounded_percent(value(step, :progress, 0)),
           attempt: nonnegative_integer(value(step, :attempt, 0)),
           max_attempts: max(nonnegative_integer(value(step, :max_attempts, 1)), 1),
           depends_on: dependencies
         }}
    end
  end

  defp normalize_step(_step, _run_id, _position), do: {:error, :invalid_dag_step}

  defp validate_dependencies(steps) do
    keys = MapSet.new(Enum.map(steps, & &1.key))

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      missing = Enum.reject(step.depends_on, &MapSet.member?(keys, &1))

      cond do
        step.key in step.depends_on -> {:halt, {:error, {:self_dependency, step.key}}}
        missing != [] -> {:halt, {:error, {:missing_dependencies, step.key, missing}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp topological_layers(steps) do
    by_key = Map.new(steps, &{&1.key, &1})
    indegree = Map.new(steps, &{&1.key, length(&1.depends_on)})

    dependants =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(step.depends_on, acc, fn dependency, nested ->
          Map.update(nested, dependency, [step.key], &[step.key | &1])
        end)
      end)

    initial =
      steps
      |> Enum.filter(&(Map.fetch!(indegree, &1.key) == 0))
      |> sort_steps()
      |> Enum.map(& &1.key)

    do_topological_layers(initial, indegree, dependants, by_key, [], 0)
  end

  defp do_topological_layers([], indegree, _dependants, _by_key, layers, visited) do
    if visited == map_size(indegree),
      do: {:ok, Enum.reverse(layers)},
      else: {:error, :cyclic_dag_projection}
  end

  defp do_topological_layers(current, indegree, dependants, by_key, layers, visited) do
    {next_indegree, next_keys} =
      Enum.reduce(current, {indegree, []}, fn key, {degrees, ready} ->
        Enum.reduce(Map.get(dependants, key, []), {degrees, ready}, fn dependant,
                                                                       {nested_degrees,
                                                                        nested_ready} ->
          degree = Map.fetch!(nested_degrees, dependant) - 1
          nested_degrees = Map.put(nested_degrees, dependant, degree)
          {nested_degrees, if(degree == 0, do: [dependant | nested_ready], else: nested_ready)}
        end)
      end)

    layer = current |> Enum.map(&Map.fetch!(by_key, &1)) |> sort_steps() |> Enum.map(& &1.key)

    next =
      next_keys
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(by_key, &1))
      |> sort_steps()
      |> Enum.map(& &1.key)

    do_topological_layers(
      next,
      next_indegree,
      dependants,
      by_key,
      [layer | layers],
      visited + length(current)
    )
  end

  defp normalize_latest_attempts(attempts, steps, run_scope) do
    step_ids = MapSet.new(Enum.map(steps, & &1.id))

    attempts
    |> Enum.reduce_while({:ok, %{}}, fn attempt, {:ok, latest} ->
      with {:ok, normalized} <- normalize_attempt(attempt, step_ids, run_scope) do
        if normalized.run_attempt == run_scope.attempt do
          {:cont,
           {:ok,
            Map.update(latest, normalized.run_step_id, normalized, fn current ->
              if normalized.attempt > current.attempt, do: normalized, else: current
            end)}}
        else
          {:cont, {:ok, latest}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_attempt(attempt, step_ids, run_scope) when is_map(attempt) do
    run_id = value(attempt, :run_id)
    step_id = value(attempt, :run_step_id)
    run_attempt = value(attempt, :run_attempt)
    attempt_number = value(attempt, :attempt)
    status = normalize_attempt_status(value(attempt, :status))

    cond do
      run_id != run_scope.id ->
        {:error, {:dag_attempt_scope_mismatch, value(attempt, :id)}}

      not MapSet.member?(step_ids, step_id) ->
        {:error, {:unknown_dag_attempt_step, step_id}}

      not is_integer(run_attempt) or run_attempt < 0 ->
        {:error, :invalid_dag_attempt_scope}

      not is_integer(attempt_number) or attempt_number < 1 ->
        {:error, :invalid_dag_attempt_number}

      status == nil ->
        {:error, :invalid_dag_attempt_status}

      true ->
        {:ok,
         %{
           id: safe_id(value(attempt, :id)),
           run_step_id: step_id,
           run_attempt: run_attempt,
           attempt: attempt_number,
           status: status,
           progress: bounded_percent(value(attempt, :progress, 0)),
           lease_expires_at: safe_timestamp(value(attempt, :lease_expires_at)),
           heartbeat_at: safe_timestamp(value(attempt, :heartbeat_at)),
           retry_not_before: safe_timestamp(value(attempt, :retry_not_before)),
           checkpoint_version: positive_integer_or_nil(value(attempt, :checkpoint_version)),
           checkpointed_at: safe_timestamp(value(attempt, :checkpointed_at)),
           started_at: safe_timestamp(value(attempt, :started_at)),
           completed_at: safe_timestamp(value(attempt, :completed_at)),
           error_code: safe_attempt_error_code(value(attempt, :error_details))
         }}
    end
  end

  defp normalize_attempt(_attempt, _step_ids, _run_scope), do: {:error, :invalid_dag_attempt}

  defp project_nodes(steps, attempts, now, stale_after_ms) do
    statuses = Map.new(steps, &{&1.key, &1.status})

    Map.new(steps, fn step ->
      attempt = Map.get(attempts, step.id)
      blocked_by = blocked_by(step, statuses)
      readiness = readiness(step, attempt, statuses, now)

      latest_attempt =
        if attempt do
          %{
            id: attempt.id,
            run_attempt: attempt.run_attempt,
            attempt: attempt.attempt,
            status: attempt.status,
            progress: attempt.progress,
            retry_not_before: attempt.retry_not_before,
            checkpoint_version: attempt.checkpoint_version,
            checkpointed_at: attempt.checkpointed_at,
            heartbeat_at: attempt.heartbeat_at,
            started_at: attempt.started_at,
            completed_at: attempt.completed_at
          }
        end

      node = %{
        id: step.id,
        key: step.key,
        title: step.title,
        kind: step.kind,
        status: step.status,
        position: step.position,
        progress: max(step.progress, (attempt && attempt.progress) || 0),
        attempt: max(step.attempt, (attempt && attempt.attempt) || 0),
        max_attempts: step.max_attempts,
        depends_on: step.depends_on,
        blocked_by: blocked_by,
        readiness: readiness,
        lease_health: lease_health(attempt, now, stale_after_ms),
        latest_attempt: latest_attempt,
        error_code: attempt && attempt.error_code
      }

      {step.key, node}
    end)
  end

  defp map_layers(layers, nodes) do
    Enum.map(layers, fn layer -> Enum.map(layer, &Map.fetch!(nodes, &1)) end)
  end

  defp readiness(step, attempt, statuses, now) do
    failed = failed_dependencies(step, statuses)
    waiting = blocked_by(step, statuses)

    cond do
      retry_waiting?(attempt, now) ->
        "retry_backoff"

      step.status in @terminal_statuses ->
        "terminal"

      step.status == "waiting_approval" ->
        "approval"

      step.status == "paused" or (attempt && attempt.status == "paused") ->
        "paused"

      attempt && attempt.status == "interrupted" ->
        "interrupted"

      not is_nil(attempt) and attempt.status == "running" and
          timestamp_past?(attempt.lease_expires_at, now) ->
        "lease_expired"

      attempt && attempt.status == "running" ->
        "leased"

      failed != [] ->
        "dependency_failed"

      waiting != [] ->
        "waiting_dependencies"

      step.status in ["ready", "pending", "blocked"] ->
        "ready"

      true ->
        normalize_readiness(step.status)
    end
  end

  defp blocked_by(step, statuses) do
    Enum.reject(step.depends_on, &(Map.get(statuses, &1) == "completed"))
  end

  defp failed_dependencies(step, statuses) do
    Enum.filter(step.depends_on, &(Map.get(statuses, &1) in @failed_dependency_statuses))
  end

  defp retry_waiting?(nil, _now), do: false

  defp retry_waiting?(attempt, now) do
    timestamp_future?(attempt.retry_not_before, now)
  end

  defp lease_health(nil, _now, _stale_after_ms), do: nil

  defp lease_health(attempt, now, stale_after_ms) do
    cond do
      attempt.status not in ["running", "paused"] -> nil
      timestamp_past?(attempt.lease_expires_at, now) -> "expired"
      stale_heartbeat?(attempt.heartbeat_at, now, stale_after_ms) -> "stale"
      true -> "healthy"
    end
  end

  defp summarize(nodes) do
    values = Map.values(nodes)

    %{
      total: length(values),
      ready: Enum.count(values, &(&1.readiness == "ready")),
      running: Enum.count(values, &(&1.readiness == "leased")),
      blocked:
        Enum.count(
          values,
          &(&1.readiness in ~w(waiting_dependencies dependency_failed lease_expired interrupted))
        ),
      approval: Enum.count(values, &(&1.readiness == "approval")),
      retrying: Enum.count(values, &(&1.readiness == "retry_backoff")),
      completed: Enum.count(values, &(&1.status == "completed")),
      failed: Enum.count(values, &(&1.status in ~w(failed cancelled)))
    }
  end

  defp engine_available?(engine) do
    case ExecutionEngine.fetch(engine) do
      {:ok, module} -> module.available?()
      :error -> false
    end
  end

  defp sort_steps(steps), do: Enum.sort_by(steps, &{&1.position, &1.key})

  defp normalize_status(status)
       when status in ~w(pending ready running paused waiting_approval blocked completed failed cancelled skipped interrupted),
       do: status

  defp normalize_status(status) when is_atom(status), do: normalize_status(Atom.to_string(status))
  defp normalize_status(_status), do: nil

  defp normalize_attempt_status(status)
       when status in ~w(running paused completed failed cancelled interrupted),
       do: status

  defp normalize_attempt_status(status) when is_atom(status),
    do: normalize_attempt_status(Atom.to_string(status))

  defp normalize_attempt_status(_status), do: nil

  defp normalize_readiness("running"), do: "leased"
  defp normalize_readiness("interrupted"), do: "interrupted"
  defp normalize_readiness("failed"), do: "terminal"
  defp normalize_readiness(_status), do: "waiting_dependencies"

  defp valid_dependencies?(dependencies) when is_list(dependencies) do
    length(dependencies) <= 32 and
      Enum.all?(dependencies, &bounded_string?(&1, 1, 160)) and
      length(dependencies) == MapSet.size(MapSet.new(dependencies))
  end

  defp valid_dependencies?(_dependencies), do: false

  defp value(map, key, fallback \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), fallback))

  defp bounded_string?(value, minimum, maximum) when is_binary(value),
    do: byte_size(value) in minimum..maximum

  defp bounded_string?(_value, _minimum, _maximum), do: false

  defp bounded_percent(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp bounded_percent(value) when is_float(value), do: value |> round() |> bounded_percent()
  defp bounded_percent(_value), do: 0

  defp nonnegative_integer(value) when is_integer(value), do: max(value, 0)
  defp nonnegative_integer(_value), do: 0

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp safe_id(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp safe_id(_value), do: nil

  defp safe_timestamp(%DateTime{} = value), do: value

  defp safe_timestamp(%NaiveDateTime{} = value),
    do: DateTime.from_naive!(value, "Etc/UTC")

  defp safe_timestamp(_value), do: nil

  defp safe_attempt_error_code(details) when is_map(details) do
    code = Map.get(details, "code") || Map.get(details, :code)

    cond do
      is_nil(code) -> nil
      is_atom(code) -> code |> Atom.to_string() |> safe_error_code()
      is_binary(code) -> safe_error_code(code)
      true -> nil
    end
  end

  defp safe_attempt_error_code(_details), do: nil

  defp safe_error_code(code) when is_binary(code) do
    if Regex.match?(@safe_error_code, code), do: code
  end

  defp timestamp_past?(%DateTime{} = value, %DateTime{} = now),
    do: DateTime.compare(value, now) == :lt

  defp timestamp_past?(_value, _now), do: false

  defp timestamp_future?(%DateTime{} = value, %DateTime{} = now),
    do: DateTime.compare(value, now) == :gt

  defp timestamp_future?(_value, _now), do: false

  defp stale_heartbeat?(%DateTime{} = heartbeat, %DateTime{} = now, stale_after_ms),
    do: DateTime.diff(now, heartbeat, :millisecond) > stale_after_ms

  defp stale_heartbeat?(_heartbeat, _now, _stale_after_ms), do: true
end
