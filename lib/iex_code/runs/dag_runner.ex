defmodule IexCode.Runs.DagRunner do
  @moduledoc false

  alias IexCode.Engine.FleetControlToken
  alias IexCode.Projects
  alias IexCode.Research.{DagFinalizer, ProviderEffect}
  alias IexCode.Runs
  alias IexCode.Runs.{DagPayload, DagScheduler, DagStepRegistry, Run}

  @default_max_concurrency 4
  @max_concurrency 32
  @default_lease_ms 30_000
  @default_heartbeat_ms 10_000
  @default_poll_ms 50

  @type result :: {:ok, Run.t()} | {:error, term()}

  @doc false
  @spec run(Run.t(), keyword()) :: result()
  def run(%Run{} = run, opts) when is_list(opts) do
    with {:ok, config} <- config(run, opts),
         {:ok, persisted_run} <- refresh_parent(config) do
      config = %{config | run: persisted_run}

      case Task.Supervisor.start_link() do
        {:ok, supervisor} ->
          try do
            state = %{
              config: config,
              supervisor: supervisor,
              active: %{},
              shutting_down?: false
            }

            schedule(:poll, 0)
            schedule(:heartbeat, config.heartbeat_ms)
            loop(state)
          catch
            {:dag_runner_failed, reason, failed_state} ->
              terminate_active(failed_state)
              {:error, reason}
          after
            if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 5_000)
          end

        {:error, reason} ->
          {:error, {:dag_task_supervisor_start_failed, reason}}
      end
    end
  end

  def run(_run, _opts), do: {:error, :invalid_dag_runner}

  defp loop(state) do
    receive do
      :poll ->
        case refresh_parent(state.config) do
          {:ok, %Run{cancellation_requested_at: %DateTime{}} = run} ->
            _ =
              DagScheduler.terminalize_active(
                run,
                state.config.owner,
                state.config.generation,
                "cancelled"
              )

            terminate_active(state)
            {:error, {:run_cancellation_requested, run}}

          {:ok, %Run{status: "running", cancellation_requested_at: nil} = run} ->
            case DagScheduler.set_paused(
                   run,
                   state.config.owner,
                   state.config.generation,
                   false
                 ) do
              {:ok, _summary} ->
                state =
                  state
                  |> put_in([:config, :run], run)
                  |> resume_active()
                  |> fill_capacity()

                schedule(:poll, state.config.poll_ms)
                loop(state)

              {:error, reason} ->
                terminate_active(state)
                {:error, {:dag_resume_failed, reason}}
            end

          {:ok, %Run{status: "paused"} = run} ->
            case DagScheduler.set_paused(
                   run,
                   state.config.owner,
                   state.config.generation,
                   true
                 ) do
              {:ok, _summary} ->
                state = state |> put_in([:config, :run], run) |> pause_active()
                schedule(:poll, state.config.poll_ms)
                loop(state)

              {:error, reason} ->
                terminate_active(state)
                {:error, {:dag_pause_failed, reason}}
            end

          {:ok, %Run{status: status} = run}
          when status in ["completed", "failed", "cancelled", "interrupted"] ->
            result = terminalize_observed_parent(state, run)
            terminate_active(state)

            case result do
              {:ok, _summary} -> terminal_result(run)
              {:error, reason} -> {:error, {:dag_terminalization_failed, reason}}
            end

          {:ok, %Run{status: status}} ->
            terminate_active(state)
            {:error, {:run_not_active, status}}

          {:error, reason} ->
            terminate_active(state)
            {:error, reason}
        end

      :heartbeat ->
        case heartbeat_active(state) do
          {:ok, state} ->
            notify(state.config, {:heartbeat, map_size(state.active)})
            schedule(:heartbeat, state.config.heartbeat_ms)
            loop(state)

          {:error, reason, failed_state} ->
            case refresh_parent(failed_state.config) do
              {:ok, %Run{status: status} = run}
              when status in ["completed", "failed", "cancelled", "interrupted"] ->
                result = terminalize_observed_parent(failed_state, run)
                terminate_active(failed_state)

                case result do
                  {:ok, _summary} ->
                    terminal_result(run)

                  {:error, terminal_reason} ->
                    {:error, {:dag_terminalization_failed, terminal_reason}}
                end

              _parent ->
                terminate_active(failed_state)
                {:error, {:dag_step_heartbeat_failed, reason}}
            end
        end

      {ref, result} when is_reference(ref) ->
        case Map.get(state.active, ref) do
          nil ->
            loop(state)

          entry ->
            Process.demonitor(ref, [:flush])
            state = remove_active(state, ref, entry)

            case settle(entry, result, state.config) do
              {:ok, _attempt} ->
                schedule(:poll, 0)
                loop(state)

              {:error, reason} ->
                terminate_active(state)
                {:error, {:dag_step_settlement_failed, reason}}
            end
        end

      {:DOWN, ref, :process, _pid, reason} ->
        case Map.get(state.active, ref) do
          nil ->
            loop(state)

          entry ->
            state = remove_active(state, ref, entry)

            case DagScheduler.fail(
                   entry.attempt,
                   state.config.owner,
                   state.config.generation,
                   entry.generation,
                   reason
                 ) do
              {:ok, _attempt} ->
                schedule(:poll, 0)
                loop(state)

              {:error, settlement_reason} ->
                terminate_active(state)
                {:error, {:dag_step_settlement_failed, settlement_reason}}
            end
        end

      {:step_timeout, ref} ->
        case Map.get(state.active, ref) do
          nil ->
            loop(state)

          entry ->
            FleetControlToken.cancel(entry.token)
            _ = Task.Supervisor.terminate_child(state.supervisor, entry.pid)
            state = remove_active(state, ref, entry)

            case DagScheduler.fail(
                   entry.attempt,
                   state.config.owner,
                   state.config.generation,
                   entry.generation,
                   :timeout
                 ) do
              {:ok, _attempt} ->
                schedule(:poll, 0)
                loop(state)

              {:error, reason} ->
                terminate_active(state)
                {:error, {:dag_step_settlement_failed, reason}}
            end
        end
    end
  end

  defp fill_capacity(state) when map_size(state.active) >= state.config.max_concurrency, do: state

  defp fill_capacity(state) do
    case DagScheduler.claim_ready(
           state.config.run,
           state.config.owner,
           state.config.generation,
           lease_ms: state.config.lease_ms
         ) do
      {:ok, claim} ->
        state |> start_claim(claim) |> fill_capacity()

      :none ->
        state

      {:error, {:run_not_running, "paused"}} ->
        state

      {:error, reason} ->
        throw({:dag_runner_failed, {:dag_claim_failed, reason}, state})
    end
  end

  defp start_claim(state, claim) do
    token = FleetControlToken.new()
    runner = self()
    context = execution_context(state.config, claim, token)

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        execute_step(state.config, claim, context)
      end)

    timeout_ms = state.config.internal_timeout_ms || step_timeout(claim.step)
    timer = Process.send_after(runner, {:step_timeout, task.ref}, timeout_ms)

    entry = %{
      pid: task.pid,
      attempt: claim.attempt,
      step: claim.step,
      generation: claim.attempt.lease_generation,
      token: token,
      timer: timer
    }

    put_in(state.active[task.ref], entry)
  end

  defp execution_context(config, claim, token) do
    checkpoint_callback = fn checkpoint, progress ->
      case FleetControlToken.checkpoint(token) do
        :ok ->
          DagScheduler.checkpoint(
            claim.attempt,
            config.owner,
            config.generation,
            claim.attempt.lease_generation,
            checkpoint,
            progress
          )

        :cancelled ->
          {:error, :cancelled}
      end
    end

    cancelled? = fn -> FleetControlToken.cancelled?(token) end

    provider_effect = fn operation, request, estimate, callback, effect_opts ->
      effect_opts =
        effect_opts
        |> Keyword.delete(:cancelled?)
        |> Keyword.delete(:checkpoint)
        |> Keyword.put(:cancelled?, cancelled?)
        |> Keyword.put(:checkpoint, checkpoint_callback)

      ProviderEffect.invoke(
        claim.attempt,
        config.owner,
        config.generation,
        claim.attempt.lease_generation,
        operation,
        request,
        estimate,
        callback,
        effect_opts
      )
    end

    %{
      run: config.run,
      step: claim.step,
      attempt: claim.attempt,
      project_root: config.project_root,
      dependency_results: claim.dependency_results,
      checkpoint: claim.attempt.checkpoint,
      cancelled?: cancelled?,
      checkpoint_callback: checkpoint_callback,
      provider_effect: provider_effect
    }
  end

  defp execute_step(%{step_executor: fun}, claim, context) when is_function(fun, 2),
    do: fun.(claim, context)

  defp execute_step(_config, claim, context) do
    case DagStepRegistry.fetch(claim.step.kind) do
      {:ok, module} -> module.execute(claim.step.params, context)
      :error -> {:error, {:unsupported_kind, claim.step.kind}}
    end
  end

  defp settle(entry, {:ok, result}, config) when is_map(result) do
    descriptor = DagStepRegistry.descriptor!(entry.attempt.handler_kind)

    case DagPayload.validate(result, max_bytes: descriptor.max_output_bytes) do
      {:ok, validated} ->
        with {:ok, completed} <-
               DagScheduler.complete(
                 entry.attempt,
                 config.owner,
                 config.generation,
                 entry.generation,
                 validated
               ),
             :ok <- finalize_public_research_result(entry, config) do
          {:ok, completed}
        end

      {:error, _reason} ->
        DagScheduler.fail(
          entry.attempt,
          config.owner,
          config.generation,
          entry.generation,
          :invalid_step_output
        )
    end
  end

  defp settle(entry, {:error, reason}, config) do
    DagScheduler.fail(entry.attempt, config.owner, config.generation, entry.generation, reason)
  end

  defp settle(entry, other, config) do
    DagScheduler.fail(
      entry.attempt,
      config.owner,
      config.generation,
      entry.generation,
      {:invalid_result, other}
    )
  end

  defp finalize_public_research_result(
         %{step: %{kind: "research_report_verify"}},
         %{run: %{kind: "deep_research", execution_engine: "dag_v1", id: run_id}}
       ) do
    case Runs.get_run(run_id) do
      %{status: "completed"} = run ->
        case DagFinalizer.finalize(run) do
          {:ok, _ready} -> :ok
          {:error, reason} -> {:error, {:research_result_finalization_failed, reason}}
        end

      _run ->
        {:error, :research_dag_not_completed}
    end
  end

  defp finalize_public_research_result(_entry, _config), do: :ok

  defp heartbeat_active(state) do
    Enum.reduce_while(Map.to_list(state.active), {:ok, state}, fn {_ref, entry}, {:ok, current} ->
      case DagScheduler.heartbeat(
             entry.attempt,
             current.config.owner,
             current.config.generation,
             entry.generation,
             current.config.lease_ms
           ) do
        {:ok, _attempt} ->
          {:cont, {:ok, current}}

        {:error, reason} ->
          # Preserve the active entry until the parent is refreshed. If the
          # parent became terminal, its attempt must be durably terminalized
          # before this task is killed. A genuine lease loss is stopped by the
          # outer heartbeat branch immediately afterward.
          {:halt, {:error, reason, current}}
      end
    end)
  end

  defp terminate_active(state) do
    Enum.each(state.active, fn {_ref, entry} ->
      FleetControlToken.cancel(entry.token)
      if entry.timer, do: Process.cancel_timer(entry.timer)
      _ = Task.Supervisor.terminate_child(state.supervisor, entry.pid)
    end)

    :ok
  end

  defp pause_active(state) do
    Enum.each(state.active, fn {_ref, entry} -> FleetControlToken.pause(entry.token) end)
    notify(state.config, {:control, :paused, map_size(state.active)})
    state
  end

  defp resume_active(state) do
    Enum.each(state.active, fn {_ref, entry} -> FleetControlToken.resume(entry.token) end)
    notify(state.config, {:control, :running, map_size(state.active)})
    state
  end

  defp terminalize_observed_parent(_state, run) do
    # Parent terminal transitions now atomically settle the DAG graph. The
    # runner may observe that committed state before its local task monitors
    # drain, so use the idempotent system reconciler rather than requiring the
    # no-longer-active parent lease a second time.
    DagScheduler.reconcile_terminal_run(run)
  end

  defp remove_active(state, ref, entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    %{state | active: Map.delete(state.active, ref)}
  end

  defp refresh_parent(config) do
    case Runs.get_run(config.run.id) do
      %Run{status: status} = run
      when status in ["completed", "failed", "cancelled", "interrupted"] ->
        {:ok, run}

      %Run{} = run ->
        validate_parent(%{config | run: run}) |> parent_result(run)

      nil ->
        {:error, :run_not_found}
    end
  end

  defp parent_result(:ok, run), do: {:ok, run}
  defp parent_result({:error, reason}, _run), do: {:error, reason}

  defp validate_parent(config) do
    run = config.run
    timestamp = DateTime.utc_now()

    cond do
      run.execution_engine != "dag_v1" -> {:error, :not_a_dag_run}
      run.attempt < 1 -> {:error, :run_not_claimed}
      run.lease_generation != config.generation -> {:error, :run_lease_lost}
      run.lease_owner != config.owner -> {:error, :run_lease_lost}
      not is_struct(run.lease_expires_at, DateTime) -> {:error, :run_lease_lost}
      DateTime.compare(run.lease_expires_at, timestamp) != :gt -> {:error, :run_lease_expired}
      true -> :ok
    end
  end

  defp terminal_result(%Run{status: "completed"} = run), do: {:ok, run}
  defp terminal_result(%Run{} = run), do: {:error, {:dag_run_terminal, run}}

  defp config(run, opts) do
    owner = Keyword.get(opts, :lease_owner)
    generation = Keyword.get(opts, :lease_generation, run.lease_generation)
    step_executor = Keyword.get(opts, :internal_step_executor)

    cond do
      not (is_binary(owner) and owner != "") ->
        {:error, :invalid_run_lease_owner}

      not (is_integer(generation) and generation > 0) ->
        {:error, :invalid_run_lease_generation}

      not (is_nil(step_executor) or is_function(step_executor, 2)) ->
        {:error, :invalid_internal_step_executor}

      true ->
        project_root =
          Keyword.get_lazy(opts, :project_root, fn ->
            Projects.get_project!(run.project_id).root_path
          end)

        {:ok,
         %{
           run: run,
           owner: owner,
           generation: generation,
           project_root: project_root,
           step_executor: step_executor,
           internal_timeout_ms:
             internal_timeout(Keyword.get(opts, :internal_step_timeout_ms), step_executor),
           internal_observer:
             internal_observer(Keyword.get(opts, :internal_observer), step_executor),
           max_concurrency:
             bounded(
               Keyword.get(opts, :max_concurrency),
               @default_max_concurrency,
               @max_concurrency
             ),
           lease_ms: positive(Keyword.get(opts, :lease_ms), @default_lease_ms),
           heartbeat_ms: positive(Keyword.get(opts, :heartbeat_ms), @default_heartbeat_ms),
           poll_ms: positive(Keyword.get(opts, :poll_ms), @default_poll_ms)
         }}
    end
  rescue
    Ecto.NoResultsError -> {:error, :project_not_found}
  end

  defp step_timeout(step) do
    descriptor = DagStepRegistry.descriptor!(step.kind)
    step.timeout_ms || descriptor.default_timeout_ms
  rescue
    MatchError -> 1
  end

  defp bounded(value, _default, maximum) when is_integer(value),
    do: value |> max(1) |> min(maximum)

  defp bounded(_value, default, _maximum), do: default
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp internal_timeout(value, executor)
       when is_integer(value) and value > 0 and is_function(executor, 2),
       do: value

  defp internal_timeout(_value, _executor), do: nil
  defp internal_observer(pid, executor) when is_pid(pid) and is_function(executor, 2), do: pid
  defp internal_observer(_pid, _executor), do: nil

  defp notify(%{internal_observer: pid}, event) when is_pid(pid),
    do: send(pid, {:dag_runner, event})

  defp notify(_config, _event), do: :ok
  defp schedule(message, delay), do: Process.send_after(self(), message, delay)
end
