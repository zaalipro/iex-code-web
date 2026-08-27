defmodule IexCode.Engine.OperationManager do
  @moduledoc """
  Manages asynchronous execution of operations (tools, file IO, commands, subagent tasks).
  Each operation is spawned in a dedicated Elixir process, monitored via OTP Process.monitor/1,
  and emits real-time progress and telemetry events.
  """
  require Logger
  alias IexCode.Sessions
  alias IexCode.Sessions.Operation
  alias IexCode.Engine.OperationMonitor
  alias IexCode.Engine.OperationProjection
  alias Phoenix.PubSub

  @update_max_attempts 10
  @update_retry_base_ms 100

  @doc """
  Runs an operation in a dedicated asynchronous Elixir task process with crash monitoring.
  Returns `{:ok, task_pid, op_record}` or `{:error, reason}` if the task could not be started.
  """
  def run_async_operation(session_id, parent_op_id, agent_name, op_type, title, params, fun) do
    fleet_owner = Process.get(:iex_code_fleet_owner)
    fleet_control_token = Process.get(:iex_code_fleet_control_token)
    task_supervisor = fleet_task_supervisor(fleet_owner)

    op =
      create_or_fallback_operation(session_id, parent_op_id, agent_name, op_type, title, params)

    op_id = op.id
    parent_caller = self()
    start_time = System.monotonic_time(:millisecond)

    emit_telemetry(:start, session_id, op_id, 0, nil, nil, op)

    case Task.Supervisor.start_child(task_supervisor, fn ->
           await_monitor_registration(op_id)

           if fleet_owner, do: Process.put(:iex_code_fleet_owner, fleet_owner)

           if fleet_control_token,
             do: Process.put(:iex_code_fleet_control_token, fleet_control_token)

           assert_fleet_control!(fleet_control_token)
           pid_str = inspect(self())

           started_op =
             safe_update_operation(op_id, %{pid_str: pid_str}, %{op | pid_str: pid_str})

           broadcast(session_id, {:operation_started, started_op})

           progress_fn = fn percent, message ->
             assert_fleet_control!(fleet_control_token)
             projected_message = OperationProjection.text(message)
             safe_update_operation(op_id, %{progress: percent, result: projected_message}, op)

             case IexCode.Engine.FleetRuntime.progress(fleet_owner, percent, projected_message) do
               :ok -> :ok
               {:error, reason} -> exit({:fleet_lease_lost, reason})
             end

             broadcast(session_id, {:operation_progress, op_id, percent, projected_message})
             emit_telemetry(:progress, session_id, op_id, percent, nil, projected_message, op)
           end

           result =
             try do
               case fun.(progress_fn) do
                 {:ok, res} ->
                   duration = System.monotonic_time(:millisecond) - start_time
                   res_str = OperationProjection.text(res)

                   final_op =
                     persist_terminal_operation(
                       op_id,
                       %{
                         status: "completed",
                         progress: 100,
                         result: res_str,
                         completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                         duration_ms: duration
                       },
                       %{
                         op
                         | status: "completed",
                           progress: 100,
                           result: res_str,
                           duration_ms: duration
                       }
                     )

                   broadcast(session_id, {:operation_completed, final_op})
                   emit_telemetry(:stop, session_id, op_id, duration, nil, nil, final_op)
                   {:ok, res}

                 {:error, reason} ->
                   duration = System.monotonic_time(:millisecond) - start_time
                   err_str = reason |> format_crash_reason() |> OperationProjection.text()

                   final_op =
                     persist_terminal_operation(
                       op_id,
                       %{
                         status: "failed",
                         error_message: err_str,
                         completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                         duration_ms: duration
                       },
                       %{op | status: "failed", error_message: err_str, duration_ms: duration}
                     )

                   broadcast(session_id, {:operation_failed, final_op})
                   emit_telemetry(:crash, session_id, op_id, duration, reason, err_str, final_op)
                   {:error, reason}
               end
             catch
               kind, err ->
                 duration = System.monotonic_time(:millisecond) - start_time
                 err_str = OperationProjection.text("#{kind}: #{format_crash_reason(err)}")

                 final_op =
                   persist_terminal_operation(
                     op_id,
                     %{
                       status: "failed",
                       error_message: err_str,
                       completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                       duration_ms: duration
                     },
                     %{op | status: "failed", error_message: err_str, duration_ms: duration}
                   )

                 broadcast(session_id, {:operation_failed, final_op})

                 emit_telemetry(
                   :crash,
                   session_id,
                   op_id,
                   duration,
                   {kind, err},
                   err_str,
                   final_op
                 )

                 {:error, err_str}
             end

           send(parent_caller, {:operation_task_done, op_id, result})
           OperationMonitor.unregister(self())
           result
         end) do
      {:ok, task_pid} ->
        if fleet_owner, do: safely_link_fleet_task(task_pid)

        monitor_metadata = %{
          session_id: session_id,
          operation_id: op_id,
          started_monotonic_ms: start_time,
          parent_caller: parent_caller,
          agent_name: op.agent_name,
          op_type: op.op_type,
          parent_op_id: op.parent_op_id
        }

        case OperationMonitor.register(task_pid, monitor_metadata) do
          :ok ->
            send(task_pid, {:operation_monitor_ready, op_id})

          {:error, monitor_reason} ->
            Logger.warning(
              "OperationManager: failed to register centralized crash monitor for " <>
                "#{inspect(op_id)}: #{inspect(monitor_reason)}"
            )

            Process.exit(task_pid, :kill)

            finalize_abnormal_exit(
              monitor_metadata,
              {:monitor_registration_failed, monitor_reason}
            )
        end

        {:ok, task_pid, op}

      {:error, reason} ->
        Logger.warning(
          "OperationManager: failed to start operation task for #{inspect(op_id)}: #{inspect(reason)}"
        )

        err_str = reason |> format_crash_reason() |> OperationProjection.text()
        duration = System.monotonic_time(:millisecond) - start_time

        final_op =
          safe_update_operation(
            op_id,
            %{
              status: "failed",
              error_message: err_str,
              completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
              duration_ms: duration
            },
            %{op | status: "failed", error_message: err_str, duration_ms: duration}
          )

        broadcast(session_id, {:operation_failed, final_op})
        emit_telemetry(:crash, session_id, op_id, duration, reason, err_str, final_op)
        {:error, err_str}
    end
  end

  @doc false
  def await_monitor_registration(op_id, timeout_ms \\ 5_000) do
    receive do
      {:operation_monitor_ready, ^op_id} -> :ok
    after
      timeout_ms -> exit(:operation_monitor_registration_timeout)
    end
  end

  defp safely_link_fleet_task(pid) do
    Process.link(pid)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp assert_fleet_control!(nil), do: :ok

  defp assert_fleet_control!(token) do
    case IexCode.Engine.FleetControlToken.checkpoint(token) do
      :ok -> :ok
      :cancelled -> exit(:fleet_agent_cancelled)
    end
  end

  defp fleet_task_supervisor(%{run_id: run_id}) when is_binary(run_id) do
    case IexCode.Engine.AgentRegistry.whereis_fleet(run_id, :task_supervisor) do
      nil -> IexCode.TaskSupervisor
      _pid -> IexCode.Engine.AgentRegistry.via_fleet(run_id, :task_supervisor)
    end
  end

  defp fleet_task_supervisor(_owner), do: IexCode.TaskSupervisor

  @doc """
  Synchronous wrapper that monitors the task process with Process.monitor/1 and awaits completion.
  Returns immediately upon completion or process crash without blocking on timeouts.
  """
  def run_sync_operation(
        session_id,
        parent_op_id,
        agent_name,
        op_type,
        title,
        params,
        fun,
        timeout \\ 60_000
      ) do
    case run_async_operation(session_id, parent_op_id, agent_name, op_type, title, params, fun) do
      {:ok, task_pid, op} ->
        await_operation_task(task_pid, op.id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Final safety net for abnormal task exits: make sure the operation record
  # does not stay stuck in "running".
  @doc false
  def finalize_abnormal_exit(metadata, crash_reason) when is_map(metadata) do
    op_id = metadata.operation_id

    op =
      Sessions.get_operation(op_id) ||
        %Operation{
          id: op_id,
          session_id: metadata.session_id,
          agent_name: metadata[:agent_name],
          op_type: metadata[:op_type],
          parent_op_id: metadata[:parent_op_id],
          status: "running"
        }

    ensure_finalized(
      metadata.session_id,
      op_id,
      op,
      metadata.started_monotonic_ms,
      metadata.parent_caller,
      crash_reason
    )
  rescue
    error ->
      Logger.warning(
        "OperationManager: abnormal exit finalization raised for " <>
          "#{inspect(metadata[:operation_id])}: #{Exception.message(error)}"
      )

      :error
  catch
    kind, reason ->
      Logger.warning(
        "OperationManager: abnormal exit finalization #{kind} for " <>
          "#{inspect(metadata[:operation_id])}: #{inspect(reason)}"
      )

      :error
  end

  @doc false
  def finalize_orphaned_operation(%Operation{status: "running"} = op) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    duration = operation_wall_duration(op, now)
    err_str = "Operation monitor restarted before task completion"

    attrs = %{
      status: "failed",
      error_message: err_str,
      completed_at: now,
      duration_ms: duration
    }

    case finalize_operation(op.id, attrs, @update_max_attempts) do
      {:ok, final_op} ->
        broadcast(op.session_id, {:operation_failed, final_op})

        emit_telemetry(
          :crash,
          op.session_id,
          op.id,
          duration,
          :monitor_restarted,
          err_str,
          final_op
        )

        :ok

      :error ->
        :error
    end
  end

  def finalize_orphaned_operation(_operation), do: :ok

  defp operation_wall_duration(%Operation{started_at: %DateTime{} = started_at}, now),
    do: max(DateTime.diff(now, started_at, :millisecond), 0)

  defp operation_wall_duration(_operation, _now), do: 0

  defp ensure_finalized(session_id, op_id, _op, start_time, parent_caller, crash_reason) do
    should_finalize =
      try do
        case Sessions.get_operation(op_id) do
          %Sessions.Operation{status: status} when status in ["completed", "failed"] ->
            false

          _ ->
            true
        end
      rescue
        # If the status read itself fails, attempt the finalize write anyway —
        # finalize_operation/3 retries transient DB errors on its own.
        _ -> true
      catch
        _, _ -> true
      end

    if should_finalize do
      duration = System.monotonic_time(:millisecond) - start_time

      err_str = crash_reason |> format_crash_reason() |> OperationProjection.text()

      attrs = %{
        status: "failed",
        error_message: err_str,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        duration_ms: duration
      }

      case finalize_operation(op_id, attrs, @update_max_attempts) do
        {:ok, final_op} ->
          broadcast(session_id, {:operation_failed, final_op})
          emit_telemetry(:crash, session_id, op_id, duration, crash_reason, err_str, final_op)
          send(parent_caller, {:operation_task_done, op_id, {:error, err_str}})
          :ok

        :error ->
          :error
      end
    else
      Logger.warning(
        "OperationManager: operation #{inspect(op_id)} crashed with " <>
          "#{format_crash_reason(crash_reason)} but was already finalized; not overwriting status"
      )

      :ok
    end
  end

  defp await_operation_task(task_pid, op_id, timeout) do
    ref = Process.monitor(task_pid)

    result =
      receive do
        {:operation_task_done, ^op_id, result} ->
          Process.demonitor(ref, [:flush])
          normalize_task_result(result)

        {:DOWN, ^ref, :process, ^task_pid, :normal} ->
          # Process completed normally; flush and wait briefly for task_done message
          receive do
            {:operation_task_done, ^op_id, result} ->
              Process.demonitor(ref, [:flush])
              normalize_task_result(result)
          after
            100 ->
              Process.demonitor(ref, [:flush])
              drain_task_done_messages(op_id)
              {:ok, :completed}
          end

        {:DOWN, ^ref, :process, ^task_pid, reason} ->
          Process.demonitor(ref, [:flush])
          drain_task_done_messages(op_id)
          err_msg = format_crash_reason(reason)
          {:error, err_msg}
      after
        timeout ->
          # The task already overran its deadline; kill it instead of leaking it.
          _ = Process.exit(task_pid, :kill)
          Process.demonitor(ref, [:flush])
          drain_task_done_messages(op_id)
          {:error, "Operation timed out after #{timeout}ms"}
      end

    # Drain any straggler task_done messages left in our mailbox.
    drain_task_done_messages(op_id)
    result
  end

  defp normalize_task_result({:exit, reason}), do: {:error, format_crash_reason(reason)}
  defp normalize_task_result(result), do: result

  defp drain_task_done_messages(op_id) do
    receive do
      {:operation_task_done, ^op_id, _result} -> drain_task_done_messages(op_id)
    after
      0 -> :ok
    end
  end

  # ============================================================================
  # Operation Tree Hierarchy Helpers
  # ============================================================================

  @doc """
  Builds a nested operation tree from a flat list of operations.
  Each operation has a `:children` list containing its direct descendants.
  """
  def build_tree(operations) when is_list(operations) do
    by_parent = Enum.group_by(operations, & &1.parent_op_id)
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    root_ops =
      Enum.filter(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    root_ops =
      if root_ops == [] and operations != [] do
        [hd(operations)]
      else
        root_ops
      end

    Enum.map(root_ops, &nest_children(&1, by_parent, MapSet.new([&1.id])))
  end

  defp nest_children(op, by_parent, visited) do
    children =
      Map.get(by_parent, op.id, [])
      |> Enum.reject(&MapSet.member?(visited, &1.id))

    nested_children =
      Enum.map(children, fn child ->
        nest_children(child, by_parent, MapSet.put(visited, child.id))
      end)

    Map.put(op, :children, nested_children)
  end

  @doc """
  Returns all direct child operations for a given parent_op_id.
  """
  def get_children(parent_op_id, operations) when is_list(operations) do
    Enum.filter(operations, &(&1.parent_op_id == parent_op_id))
  end

  @doc """
  Returns all root operations (parent_op_id is nil or empty or not found).
  """
  def get_root_operations(operations) when is_list(operations) do
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    roots =
      Enum.filter(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    if roots == [] and operations != [] do
      [hd(operations)]
    else
      roots
    end
  end

  @doc """
  Returns summary statistics for the operation tree.
  """
  def tree_stats(operations) when is_list(operations) do
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    roots_count =
      Enum.count(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    roots_count = if roots_count == 0 and operations != [], do: 1, else: roots_count

    %{
      total: length(operations),
      roots: roots_count,
      running: Enum.count(operations, &(&1.status == "running")),
      completed: Enum.count(operations, &(&1.status == "completed")),
      failed: Enum.count(operations, &(&1.status == "failed")),
      total_duration_ms: Enum.sum(Enum.map(operations, &(&1.duration_ms || 0)))
    }
  end

  # ============================================================================
  # Crash Formatting & Telemetry Helpers
  # ============================================================================

  @doc """
  Formats any Erlang/Elixir crash or exit reason into a sanitized UTF-8 string.
  """
  def format_crash_reason(:normal), do: "Process exited normally"
  def format_crash_reason(:noproc), do: "Process does not exist or died before monitor"
  def format_crash_reason(:killed), do: "Process was killed (:killed)"

  def format_crash_reason({:shutdown, reason}),
    do: "Process shut down: #{format_crash_reason(reason)}"

  def format_crash_reason(:shutdown), do: "Process shut down"
  def format_crash_reason(%{__struct__: _, message: msg}) when is_binary(msg), do: msg
  def format_crash_reason({%{__struct__: _, message: msg}, _stack}) when is_binary(msg), do: msg

  def format_crash_reason({exception, _stack}) when is_exception(exception),
    do: Exception.message(exception)

  def format_crash_reason(exception) when is_exception(exception),
    do: Exception.message(exception)

  def format_crash_reason(term) when is_binary(term), do: Sessions.sanitize_utf8(term)
  def format_crash_reason(term) when is_atom(term), do: Atom.to_string(term)

  def format_crash_reason({kind, term}) when is_atom(kind),
    do: "#{kind}: #{OperationProjection.text(term)}"

  def format_crash_reason(term), do: OperationProjection.text(term)

  defp create_or_fallback_operation(session_id, parent_op_id, agent_name, op_type, title, params) do
    try do
      case Sessions.create_operation(%{
             session_id: session_id,
             parent_op_id: parent_op_id,
             agent_name: agent_name,
             op_type: to_string(op_type),
             title: title,
             status: "running",
             progress: 0,
             params: OperationProjection.params(params),
             started_at: DateTime.utc_now() |> DateTime.truncate(:second)
           }) do
        {:ok, created} ->
          created

        other ->
          Logger.warning(
            "OperationManager: create_operation failed (#{inspect(other)}); " <>
              "degrading to in-memory operation for session #{inspect(session_id)}"
          )

          fallback_op(session_id, parent_op_id, agent_name, op_type, title, params)
      end
    rescue
      e ->
        Logger.warning(
          "OperationManager: create_operation raised #{Exception.format(:error, e)}; " <>
            "degrading to in-memory operation for session #{inspect(session_id)}"
        )

        fallback_op(session_id, parent_op_id, agent_name, op_type, title, params)
    end
  end

  defp fallback_op(session_id, parent_op_id, agent_name, op_type, title, params) do
    %Operation{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      parent_op_id: parent_op_id,
      agent_name: agent_name,
      op_type: to_string(op_type),
      title: title,
      status: "running",
      progress: 0,
      params: OperationProjection.params(params),
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    e ->
      Logger.warning(
        "OperationManager: broadcast of #{inspect(event)} failed for session " <>
          "#{inspect(session_id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp emit_telemetry(event, session_id, op_id, value, reason, message, op) do
    measurements =
      case event do
        :start -> %{system_time: System.system_time()}
        :progress -> %{progress: value, system_time: System.system_time()}
        :stop -> %{duration_ms: value, system_time: System.system_time()}
        :crash -> %{duration_ms: value, system_time: System.system_time()}
      end

    metadata = %{
      session_id: session_id,
      operation_id: op_id,
      agent_name: op.agent_name,
      op_type: op.op_type,
      parent_op_id: op.parent_op_id,
      reason: reason,
      message: message
    }

    :telemetry.execute([:iex_code, :operation, event], measurements, metadata)
  rescue
    e ->
      Logger.warning(
        "OperationManager: telemetry event #{inspect(event)} failed: #{Exception.message(e)}"
      )

      :ok
  end

  # Persists a terminal (completed/failed) status from the operation task's own
  # path. The single inline attempt keeps the sync caller's unblock latency
  # minimal; if the write is dropped (e.g. DB checkout queue overflow under
  # load), a detached retrier finishes the terminal write so the record never
  # stays stuck in "running".
  defp persist_terminal_operation(op_id, attrs, fallback_struct) do
    case update_operation_once(op_id, attrs) do
      {:ok, updated} ->
        updated

      _ ->
        spawn(fn -> finalize_operation(op_id, attrs, @update_max_attempts) end)
        fallback_struct
    end
  end

  # Best-effort persist used on the operation task's own path (progress,
  # completion, crash). Single attempt: the sync caller must unblock quickly,
  # so retries never block the task — the crash watcher guarantees the final
  # write with retries instead.
  defp safe_update_operation(op_id, attrs, fallback_struct) do
    case update_operation_once(op_id, attrs) do
      {:ok, updated} ->
        updated

      _ ->
        fallback_struct
    end
  end

  # Retrying persist used by the crash watcher: transient DB failures
  # (connection checkout drops when many concurrent operations flood the
  # queue) are retried with backoff so an operation never silently stays in a
  # non-terminal status.
  defp finalize_operation(_op_id, _attrs, 0), do: :error

  defp finalize_operation(op_id, attrs, attempts_left) do
    case update_operation_once(op_id, attrs) do
      {:ok, updated} ->
        {:ok, updated}

      :give_up ->
        :error

      :retry ->
        Process.sleep(
          @update_retry_base_ms * (@update_max_attempts - attempts_left + 1) +
            :rand.uniform(100)
        )

        finalize_operation(op_id, attrs, attempts_left - 1)
    end
  end

  defp update_operation_once(op_id, attrs) do
    try do
      case Sessions.update_operation(op_id, attrs) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, :not_found} ->
          Logger.warning(
            "OperationManager: update_operation(#{inspect(op_id)}, #{inspect(attrs)}) failed: :not_found"
          )

          :give_up

        other ->
          Logger.warning(
            "OperationManager: update_operation(#{inspect(op_id)}, #{inspect(attrs)}) failed: #{inspect(other)}"
          )

          :retry
      end
    rescue
      e ->
        Logger.warning(
          "OperationManager: update_operation(#{inspect(op_id)}, #{inspect(attrs)}) raised: #{Exception.message(e)}"
        )

        :retry
    catch
      kind, err ->
        Logger.warning(
          "OperationManager: update_operation(#{inspect(op_id)}, #{inspect(attrs)}) threw #{kind}: #{inspect(err)}"
        )

        :retry
    end
  end
end
