defmodule IexCode.Workflows.Engine do
  @moduledoc """
  GenServer execution engine managing active workflow run execution,
  topological step advancement, variable piping, and PubSub broadcasts.
  """

  use GenServer, restart: :transient
  require Logger

  alias IexCode.Repo
  alias IexCode.Workflows.{WorkflowDag, WorkflowRun, VariableInterpolator}
  alias IexCode.Workflows.Steps.Dispatcher

  @registry IexCode.Workflows.EngineRegistry
  @supervisor IexCode.Workflows.EngineSupervisor
  @pubsub IexCode.PubSub

  defstruct [
    :run_id,
    :project_id,
    :workflow,
    :steps,
    :inputs,
    :project,
    status: :pending,
    step_states: %{},
    step_outputs: %{},
    active_tasks: %{},
    task_refs: %{},
    paused?: false,
    cancelled?: false,
    pressure_backoff_count: 0,
    max_pressure_backoffs: 120,
    pressure_backoff_interval_ms: 1_000,
    memory_checker: &IexCode.Observability.MemoryGuardrail.critical?/0
  ]

  # Client API

  @doc "Starts a workflow execution engine under DynamicSupervisor or standalone."
  def start_link(opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  @doc "Starts a workflow run asynchronously under the supervisor."
  def start_run(run_id, opts \\ []) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, [run_id: run_id] ++ opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ ->
      # If supervisor is not running (e.g. isolated test environment), start standalone
      start_link([run_id: run_id] ++ opts)
  end

  @doc "Returns the PID of a running engine for run_id, if active."
  def whereis_run(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Pauses an active workflow run."
  def pause_run(run_id) do
    call_engine(run_id, :pause)
  end

  @doc "Resumes a paused workflow run."
  def resume_run(run_id) do
    call_engine(run_id, :resume)
  end

  @doc "Cancels an active workflow run."
  def cancel_run(run_id) do
    call_engine(run_id, :cancel)
  end

  @doc "Retries a specific failed step in the run."
  def retry_step(run_id, step_key) do
    case whereis_run(run_id) do
      nil ->
        case load_run(run_id) do
          nil ->
            {:error, :run_not_found}

          run when run.status in ["failed", "paused", :failed, :paused] ->
            case start_run(run_id) do
              {:ok, _pid} ->
                call_engine(run_id, {:retry_step, step_key})

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:error, :run_not_active}
        end

      _pid ->
        call_engine(run_id, {:retry_step, step_key})
    end
  end

  @doc "Gets current engine status."
  def get_status(run_id) do
    call_engine(run_id, :get_status)
  end

  def via_tuple(run_id), do: {:via, Registry, {@registry, run_id}}

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    run_id = Keyword.fetch!(opts, :run_id)
    max_pressure_backoffs = Keyword.get(opts, :max_pressure_backoffs, 120)
    pressure_backoff_interval_ms = Keyword.get(opts, :pressure_backoff_interval_ms, 1_000)

    memory_checker =
      Keyword.get(opts, :memory_checker, &IexCode.Observability.MemoryGuardrail.critical?/0)

    send(self(), :initialize_run)

    {:ok,
     %__MODULE__{
       run_id: run_id,
       max_pressure_backoffs: max_pressure_backoffs,
       pressure_backoff_interval_ms: pressure_backoff_interval_ms,
       memory_checker: memory_checker
     }}
  end

  @impl true
  def handle_info(:initialize_run, state) do
    case load_run(state.run_id) do
      nil ->
        Logger.error("Workflow run #{state.run_id} not found")
        {:stop, :normal, state}

      run ->
        initial_step_states =
          Enum.reduce(run.resolved_steps, run.step_states || %{}, fn step, acc ->
            k = WorkflowDag.step_key(step)
            Map.put_new(acc, k, %{"status" => "pending"})
          end)

        step_outputs =
          Enum.reduce(initial_step_states, %{}, fn {k, v}, acc ->
            case v do
              %{"status" => "completed", "output" => out} -> Map.put(acc, k, out)
              _ -> acc
            end
          end)

        has_failed_steps? =
          Enum.any?(initial_step_states, fn {_, s} -> Map.get(s, "status") == "failed" end)

        current_status =
          if run.status in ["failed", :failed] or has_failed_steps?, do: :failed, else: :running

        new_state = %{
          state
          | project_id: run.project_id,
            workflow: run.workflow,
            steps: run.resolved_steps,
            inputs: run.inputs || %{},
            project: run.project,
            status: current_status,
            step_states: initial_step_states,
            step_outputs: step_outputs
        }

        in_flight_keys =
          initial_step_states
          |> Enum.filter(fn {_key, step_state} -> Map.get(step_state, "status") == "running" end)
          |> Enum.map(&elem(&1, 0))

        cond do
          in_flight_keys != [] ->
            finalize_run_failure(
              new_state,
              "Workflow engine interrupted while step(s) were in flight: #{Enum.join(in_flight_keys, ", ")}; retry is required"
            )

          current_status == :running ->
            updated_run =
              update_run_record(run, %{
                status: "running",
                started_at: run.started_at || DateTime.utc_now(),
                step_states: initial_step_states
              })

            broadcast_run_event(updated_run, {:workflow_run_started, updated_run})
            broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})

            send(self(), :execute_next_layer)
            {:noreply, new_state}

          true ->
            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info(:execute_next_layer, %{paused?: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:execute_next_layer, %{cancelled?: true} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:execute_next_layer, state) do
    critical? =
      try do
        state.memory_checker.()
      rescue
        e ->
          Logger.warning("[Workflows.Engine] Memory checker failed with exception: #{inspect(e)}")
          false
      catch
        :exit, e ->
          Logger.warning("[Workflows.Engine] Memory checker caught exit: #{inspect(e)}")
          false
      end

    if critical? do
      new_count = state.pressure_backoff_count + 1

      if new_count >= state.max_pressure_backoffs do
        Logger.error(
          "[Workflows.Engine] Critical memory pressure persisted for >=#{state.max_pressure_backoffs} attempts; aborting run #{state.run_id}"
        )

        finalize_run_failure(
          state,
          "Workflow run aborted: critical memory pressure persisted for >120s"
        )
      else
        Logger.warning(
          "[Workflows.Engine] Critical memory pressure detected (#{new_count}/#{state.max_pressure_backoffs}); deferring step launch for run #{state.run_id}"
        )

        Process.send_after(self(), :execute_next_layer, state.pressure_backoff_interval_ms)
        {:noreply, %{state | pressure_backoff_count: new_count}}
      end
    else
      # Reset pressure backoff counter if pressure has cleared
      state = %{state | pressure_backoff_count: 0}

      completed_keys =
        state.step_states
        |> Enum.filter(fn {_, s} -> Map.get(s, "status") == "completed" end)
        |> Enum.map(&elem(&1, 0))

      failed_keys =
        state.step_states
        |> Enum.filter(fn {_, s} -> Map.get(s, "status") == "failed" end)
        |> Enum.map(&elem(&1, 0))

      running_keys =
        state.step_states
        |> Enum.filter(fn {_, s} -> Map.get(s, "status") == "running" end)
        |> Enum.map(&elem(&1, 0))

      cond do
        failed_keys != [] and running_keys == [] ->
          # Run has failed steps and no more running steps
          finalize_run_failure(state, "Step(s) failed: #{Enum.join(failed_keys, ", ")}")

        length(completed_keys) == length(state.steps) ->
          # All steps completed!
          finalize_run_completion(state)

        true ->
          ready = WorkflowDag.ready_steps(state.steps, completed_keys, failed_keys)
          ready_not_running = Enum.reject(ready, &(WorkflowDag.step_key(&1) in running_keys))

          if ready_not_running == [] and running_keys == [] and
               length(completed_keys) < length(state.steps) do
            # Deadlock or unmet dependencies without failure
            finalize_run_failure(state, "Unresolvable dependency block in workflow steps")
          else
            new_state =
              Enum.reduce(ready_not_running, state, fn step, acc ->
                launch_step(step, acc)
              end)

            {:noreply, new_state}
          end
      end
    end
  end

  # Step completion from async Task
  @impl true
  def handle_info({:step_completed, step_key, output, duration_ms}, state) do
    state = drop_active_task(state, step_key)

    updated_step_state = %{
      "status" => "completed",
      "output" => output,
      "duration_ms" => duration_ms,
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_step_states = Map.put(state.step_states, step_key, updated_step_state)
    new_outputs = Map.put(state.step_outputs, step_key, output)
    total_count = max(1, length(state.steps))

    completed_count =
      Enum.count(new_step_states, fn {_, s} -> Map.get(s, "status") == "completed" end)

    progress = trunc(completed_count / total_count * 100)

    run = load_run(state.run_id)

    updated_run =
      if run do
        update_run_record(run, %{
          step_states: new_step_states,
          progress: progress
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:step_state_updated, state.run_id, step_key, "completed"})
      broadcast_run_event(updated_run, {:workflow_step_completed, step_key, output})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    new_state = %{
      state
      | step_states: new_step_states,
        step_outputs: new_outputs,
        pressure_backoff_count: 0
    }

    send(self(), :execute_next_layer)
    {:noreply, new_state}
  end

  # Step failure from async Task
  @impl true
  def handle_info({:step_failed, step_key, error_reason, duration_ms}, state) do
    state = drop_active_task(state, step_key)
    error_str = format_error_reason(error_reason)

    updated_step_state = %{
      "status" => "failed",
      "error" => error_str,
      "duration_ms" => duration_ms,
      "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_step_states = Map.put(state.step_states, step_key, updated_step_state)
    run = load_run(state.run_id)

    updated_run =
      if run do
        update_run_record(run, %{
          status: "failed",
          error_message: "Step #{step_key} failed: #{error_str}",
          step_states: new_step_states
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:step_state_updated, state.run_id, step_key, "failed"})
      broadcast_run_event(updated_run, {:workflow_step_failed, step_key, error_str})
      broadcast_run_event(updated_run, {:workflow_run_failed, updated_run, error_str})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    new_state = %{
      state
      | status: :failed,
        step_states: new_step_states
    }

    # If there are no other active tasks, finalize failure cleanly
    if map_size(new_state.active_tasks) == 0 do
      finalize_run_failure(new_state, "Step #{step_key} failed: #{error_str}")
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({ref, {:step_result, result, duration_ms}}, state) when is_reference(ref) do
    case Map.get(state.task_refs, ref) do
      nil ->
        {:noreply, state}

      step_key ->
        case result do
          {:ok, output} ->
            handle_info({:step_completed, step_key, output, duration_ms}, state)

          {:error, reason} ->
            handle_info({:step_failed, step_key, reason, duration_ms}, state)

          unexpected ->
            handle_info(
              {:step_failed, step_key, {:unexpected_step_result, unexpected}, duration_ms},
              state
            )
        end
    end
  end

  @impl true
  def handle_info({ref, _msg}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {step_key, task_refs} ->
        state = %{
          state
          | task_refs: task_refs,
            active_tasks: Map.delete(state.active_tasks, step_key)
        }

        handle_info({:step_failed, step_key, {:step_task_exit, reason}, 0}, state)
    end
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply,
     {:ok,
      %{
        status: state.status,
        step_states: state.step_states,
        pressure_backoff_count: state.pressure_backoff_count
      }}, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    run = load_run(state.run_id)

    updated_run =
      if run do
        update_run_record(run, %{
          status: "paused",
          paused_at: DateTime.utc_now()
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:workflow_run_paused, updated_run})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    {:reply, :ok, %{state | paused?: true, status: :paused}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    run = load_run(state.run_id)

    updated_run =
      if run do
        update_run_record(run, %{
          status: "running",
          paused_at: nil
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:workflow_run_resumed, updated_run})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    new_state = %{state | paused?: false, status: :running, pressure_backoff_count: 0}
    send(self(), :execute_next_layer)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    # Abort active tasks
    Enum.each(state.active_tasks, fn {_k, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    run = load_run(state.run_id)

    updated_run =
      if run do
        curr_step_states = run.step_states || %{}

        {updated_step_states, cancelled_keys} =
          Enum.reduce(curr_step_states, {%{}, []}, fn {step_k, sinfo}, {acc_map, acc_keys} ->
            sinfo_map = if is_map(sinfo), do: sinfo, else: %{}
            status = Map.get(sinfo_map, "status")

            if status in ["running", "pending"] do
              new_sinfo = Map.put(sinfo_map, "status", "cancelled")
              {Map.put(acc_map, step_k, new_sinfo), [step_k | acc_keys]}
            else
              {Map.put(acc_map, step_k, sinfo), acc_keys}
            end
          end)

        updated =
          update_run_record(run, %{
            status: "cancelled",
            completed_at: DateTime.utc_now(),
            step_states: updated_step_states
          })

        if updated do
          Enum.each(cancelled_keys, fn step_k ->
            broadcast_run_event(updated, {:step_state_updated, run.id, step_k, "cancelled"})
          end)
        end

        updated
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    {:stop, :normal, :ok, %{state | cancelled?: true, status: :cancelled, active_tasks: %{}}}
  end

  @impl true
  def handle_call({:retry_step, step_key}, _from, state) do
    current = Map.get(state.step_states, step_key, %{})

    if Map.get(current, "status") in ["failed", "cancelled"] do
      new_step_states = Map.put(state.step_states, step_key, %{"status" => "pending"})
      run = load_run(state.run_id)

      updated_run =
        if run do
          update_run_record(run, %{
            status: "running",
            error_message: nil,
            step_states: new_step_states
          })
        else
          nil
        end

      if updated_run do
        broadcast_run_event(updated_run, {:step_state_updated, state.run_id, step_key, "pending"})
        broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
      end

      new_state = %{
        state
        | status: :running,
          step_states: new_step_states,
          paused?: false,
          pressure_backoff_count: 0
      }

      send(self(), :execute_next_layer)
      {:reply, {:ok, updated_run || run}, new_state}
    else
      {:reply, {:error, :step_not_failed}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(state.active_tasks, fn {_k, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    if reason not in [:normal, :shutdown] and
         state.status not in [:completed, :cancelled, :failed] do
      run = load_run(state.run_id)

      if run && run.status not in ["completed", "cancelled", "failed"] do
        update_run_record(run, %{
          status: "failed",
          error_message: "Engine terminated unexpectedly: #{inspect(reason)}",
          completed_at: DateTime.utc_now()
        })
      end
    end

    :ok
  end

  # Helpers

  defp launch_step(step, state) do
    step_key = WorkflowDag.step_key(step)

    # Mark step as running
    updated_step_state = %{
      "status" => "running",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_step_states = Map.put(state.step_states, step_key, updated_step_state)

    run = load_run(state.run_id)

    updated_run =
      if run do
        update_run_record(run, %{
          current_step_key: step_key,
          step_states: new_step_states
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:workflow_step_started, step_key, step})
      broadcast_run_event(updated_run, {:step_state_updated, state.run_id, step_key, "running"})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    # Build step execution context with outputs of completed steps
    context = build_step_context(state)

    # Interpolate step parameters with resolved context
    interpolated_step =
      case VariableInterpolator.interpolate(step, context) do
        {:ok, s} -> s
        _ -> step
      end

    # Supervise and monitor every step so an exit without a result cannot leave
    # durable state stuck in "running".
    task =
      Task.Supervisor.async(IexCode.TaskSupervisor, fn ->
        start_mono = System.monotonic_time(:millisecond)
        result = Dispatcher.dispatch(interpolated_step, context)
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        {:step_result, result, duration_ms}
      end)

    active_tasks = Map.put(state.active_tasks, step_key, task.pid)
    task_refs = Map.put(state.task_refs, task.ref, step_key)

    %{
      state
      | step_states: new_step_states,
        active_tasks: active_tasks,
        task_refs: task_refs
    }
  end

  defp drop_active_task(state, step_key) do
    case Enum.find(state.task_refs, fn {_ref, key} -> key == step_key end) do
      {ref, ^step_key} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | active_tasks: Map.delete(state.active_tasks, step_key),
            task_refs: Map.delete(state.task_refs, ref)
        }

      nil ->
        %{state | active_tasks: Map.delete(state.active_tasks, step_key)}
    end
  end

  defp build_step_context(state) do
    # Structure context so {{steps.step_key.output.field}} and {{inputs.field}} work
    step_map =
      Enum.reduce(state.step_outputs, %{}, fn {k, out}, acc ->
        Map.put(acc, k, %{"output" => out})
      end)

    project_map =
      case state.project do
        %{id: id, name: name, root_path: root} ->
          %{"id" => id, "name" => name, "root_path" => root}

        _ ->
          %{}
      end

    %{
      "inputs" => state.inputs,
      "project" => project_map,
      "steps" => step_map,
      :repo_dir => Map.get(project_map, "root_path") || File.cwd!()
    }
  end

  defp finalize_run_completion(state) do
    run = load_run(state.run_id)
    now = DateTime.utc_now()

    duration =
      if run && run.started_at do
        DateTime.diff(now, run.started_at, :millisecond)
      else
        0
      end

    updated_run =
      if run do
        update_run_record(run, %{
          status: "completed",
          progress: 100,
          completed_at: now,
          duration_ms: duration,
          current_step_key: nil
        })
      else
        nil
      end

    if updated_run do
      broadcast_run_event(updated_run, {:workflow_run_completed, updated_run})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    {:stop, :normal, %{state | status: :completed}}
  end

  defp finalize_run_failure(state, reason) do
    # Kill any active tasks to prevent resource leaks
    Enum.each(state.active_tasks, fn {_k, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    run = load_run(state.run_id)
    curr_step_states = (run && run.step_states) || state.step_states || %{}

    {updated_step_states, aborted_keys} =
      Enum.reduce(curr_step_states, {%{}, []}, fn {step_k, sinfo}, {acc_map, acc_keys} ->
        sinfo_map = if is_map(sinfo), do: sinfo, else: %{}
        status = Map.get(sinfo_map, "status")

        if status == "running" do
          new_sinfo =
            sinfo_map
            |> Map.put("status", "failed")
            |> Map.put_new("error", reason)

          {Map.put(acc_map, step_k, new_sinfo), [step_k | acc_keys]}
        else
          {Map.put(acc_map, step_k, sinfo), acc_keys}
        end
      end)

    now = DateTime.utc_now()

    updated_run =
      if run do
        update_run_record(run, %{
          status: "failed",
          error_message: reason,
          step_states: updated_step_states,
          completed_at: now,
          current_step_key: nil
        })
      else
        nil
      end

    if updated_run do
      Enum.each(aborted_keys, fn step_k ->
        broadcast_run_event(updated_run, {:step_state_updated, run.id, step_k, "failed"})
      end)

      broadcast_run_event(updated_run, {:workflow_run_failed, updated_run, reason})
      broadcast_run_event(updated_run, {:workflow_run_updated, updated_run})
    end

    {:stop, :normal,
     %{state | status: :failed, step_states: updated_step_states, active_tasks: %{}}}
  end

  defp load_run(run_id) do
    Repo.retry_on_busy(fn ->
      Repo.get(WorkflowRun, run_id)
      |> Repo.preload([:workflow, :project, :session])
    end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp update_run_record(run, attrs) do
    Repo.retry_on_busy(fn ->
      run
      |> WorkflowRun.changeset(attrs)
      |> Repo.update()
    end)
    |> case do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("Failed to update workflow run: #{inspect(changeset.errors)}")
        run
    end
  rescue
    e ->
      Logger.error("Exception updating workflow run: #{inspect(e)}")
      run
  catch
    :exit, e ->
      Logger.error("Exit updating workflow run: #{inspect(e)}")
      run
  end

  defp broadcast_run_event(run, event) do
    try do
      Phoenix.PubSub.broadcast(@pubsub, "workflow_run:#{run.id}", event)

      if run.project_id do
        Phoenix.PubSub.broadcast(@pubsub, "workflow_runs:project:#{run.project_id}", event)
      end
    rescue
      _ -> :ok
    end
  end

  defp call_engine(run_id, message) do
    case whereis_run(run_id) do
      nil ->
        {:error, :run_not_active}

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, message, 10_000)
        catch
          :exit, {:noproc, _} -> {:error, :run_not_active}
          :exit, {:normal, _} -> {:error, :run_not_active}
        end
    end
  end

  defp format_error_reason(reason) when is_binary(reason), do: reason

  defp format_error_reason({:verification_failed, map}) when is_map(map),
    do: "Verification failed: #{map["verdict"]}"

  defp format_error_reason({:step_exception, msg, _}), do: "Exception: #{msg}"
  defp format_error_reason({:step_task_exit, reason}), do: "Step task exited: #{inspect(reason)}"
  defp format_error_reason(other), do: inspect(other)
end
