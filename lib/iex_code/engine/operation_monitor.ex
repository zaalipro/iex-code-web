defmodule IexCode.Engine.OperationMonitor do
  @moduledoc """
  Central crash monitor for asynchronous operations.

  A central process monitors and links every operation task. One linked,
  fixed-process finalizer serializes durable crash writes without blocking
  registrations or task DOWN handling. Links make monitor/finalizer failure
  fail closed: supervised restart terminates registered tasks, and the
  restarted monitor reconciles their durable `running` rows.
  """

  use GenServer

  require Logger

  alias IexCode.Engine.OperationManager
  alias IexCode.Repo
  alias IexCode.Sessions.Operation

  import Ecto.Query, only: [from: 2]

  @reconciliation_batch_size 100
  @reconciliation_fields [
    :id,
    :session_id,
    :parent_op_id,
    :agent_name,
    :op_type,
    :status,
    :started_at
  ]

  defstruct by_ref: %{},
            by_pid: %{},
            reconciliation_attempt: 0,
            reconciliation_in_progress?: false,
            reconciliation_delay_ms: 1_100,
            reconciliation_grace_seconds: 1,
            pending_finalizations: 0,
            finalizer_pid: nil

  @type registration :: %{
          required(:session_id) => String.t(),
          required(:operation_id) => String.t(),
          required(:started_monotonic_ms) => integer(),
          required(:parent_caller) => pid()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Registers one task with fixed-size crash-finalization metadata."
  @spec register(pid(), registration(), GenServer.server()) :: :ok | {:error, term()}
  def register(task_pid, metadata, server \\ __MODULE__)
      when is_pid(task_pid) and is_map(metadata) do
    GenServer.call(server, {:register, task_pid, bounded_metadata(metadata)})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Removes the current task after its terminal state has been persisted."
  @spec unregister(pid(), GenServer.server()) :: :ok
  def unregister(task_pid \\ self(), server \\ __MODULE__) when is_pid(task_pid) do
    GenServer.call(server, {:unregister, task_pid})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Waits until every registered operation has reached crash finalization.

  This is primarily a lifecycle barrier for orderly shutdown and test sandbox
  teardown. A zero `active` snapshot is stronger than merely observing the
  operation tasks exit: the reply is sent only after this monitor has consumed
  all earlier `:DOWN` messages and its linked finalizer has acknowledged every
  durable crash write.
  """
  @spec await_idle(non_neg_integer(), GenServer.server()) :: :ok | {:error, :timeout}
  def await_idle(timeout_ms \\ 30_000, server \\ __MODULE__)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_idle(server, deadline)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    parent = self()
    finalize_fun = Keyword.get(opts, :finalizer, &OperationManager.finalize_abnormal_exit/2)
    page_hook = Keyword.get(opts, :reconciliation_page_hook, fn _page -> :ok end)

    reconcile_fun =
      Keyword.get(opts, :reconciler, fn cutoff, monitor_pid ->
        reconcile_running_operations(cutoff, monitor_pid, page_hook)
      end)

    finalizer_pid = spawn_link(fn -> finalizer_loop(parent, finalize_fun, reconcile_fun) end)

    reconciliation_delay_ms =
      normalize_nonnegative(Keyword.get(opts, :reconciliation_delay_ms, 1_100), 1_100)

    reconciliation_grace_seconds =
      normalize_nonnegative(Keyword.get(opts, :reconciliation_grace_seconds, 1), 1)

    reconcile_on_start? =
      Keyword.get_lazy(opts, :reconcile_on_start, fn ->
        Application.get_env(:iex_code, :operation_monitor_reconcile_on_start, true)
      end)

    if reconcile_on_start? do
      Process.send_after(self(), :reconcile_running, reconciliation_delay_ms)
    end

    {:ok,
     %__MODULE__{
       finalizer_pid: finalizer_pid,
       reconciliation_delay_ms: reconciliation_delay_ms,
       reconciliation_grace_seconds: reconciliation_grace_seconds
     }}
  end

  @impl true
  def handle_call({:register, task_pid, metadata}, _from, state) do
    if Process.alive?(task_pid) do
      Process.link(task_pid)
      ref = Process.monitor(task_pid)
      entry = %{task_pid: task_pid, metadata: metadata}

      state = %{
        state
        | by_ref: Map.put(state.by_ref, ref, entry),
          by_pid: Map.put(state.by_pid, task_pid, ref)
      }

      {:reply, :ok, state}
    else
      {:reply, {:error, :task_not_alive}, state}
    end
  end

  def handle_call({:unregister, task_pid}, _from, state) do
    {:reply, :ok, remove_task(state, task_pid)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       active: map_size(state.by_pid),
       pending_finalizations: state.pending_finalizations,
       reconciliation_in_progress?: state.reconciliation_in_progress?
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, task_pid, reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _by_ref} ->
        {:noreply, state}

      {%{metadata: metadata}, by_ref} ->
        state = %{state | by_ref: by_ref, by_pid: Map.delete(state.by_pid, task_pid)}

        state = enqueue_finalization(state, metadata, reason)

        {:noreply, state}
    end
  end

  # Keep registration and task DOWN processing responsive even when a durable
  # write is slow. The linked, fixed-process finalizer owns all database work;
  # if it exits, fail closed by restarting this monitor and its linked tasks.
  def handle_info({:EXIT, finalizer_pid, reason}, %{finalizer_pid: finalizer_pid} = state),
    do: {:stop, {:operation_finalizer_exited, reason}, state}

  # The monitor reference is authoritative; linked task EXIT messages are
  # retained solely to make monitor failure propagate to registered tasks.
  def handle_info({:EXIT, task_pid, _reason}, state) when is_pid(task_pid),
    do: {:noreply, state}

  def handle_info(:reconcile_running, state) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-state.reconciliation_grace_seconds, :second)

    send(state.finalizer_pid, {:reconcile_running, cutoff})
    {:noreply, %{state | reconciliation_in_progress?: true}}
  end

  def handle_info(
        {:reconciliation_candidates, finalizer_pid, ref, page},
        %{finalizer_pid: finalizer_pid} = state
      ) do
    active_ids =
      Map.new(state.by_ref, fn {_monitor_ref, entry} ->
        {entry.metadata.operation_id, true}
      end)

    eligible = Enum.reject(page, &Map.has_key?(active_ids, &1.id))
    send(finalizer_pid, {:reconciliation_eligible, ref, eligible})
    {:noreply, state}
  end

  def handle_info(
        {:reconciliation_finished, finalizer_pid},
        %{finalizer_pid: finalizer_pid} = state
      ) do
    {:noreply, %{state | reconciliation_attempt: 0, reconciliation_in_progress?: false}}
  end

  def handle_info(
        {:reconciliation_failed, finalizer_pid},
        %{finalizer_pid: finalizer_pid} = state
      ) do
    attempt = state.reconciliation_attempt + 1
    Process.send_after(self(), :reconcile_running, min(attempt * 1_000, 30_000))

    {:noreply, %{state | reconciliation_attempt: attempt, reconciliation_in_progress?: false}}
  end

  def handle_info(
        {:finalization_finished, finalizer_pid},
        %{finalizer_pid: finalizer_pid} = state
      ) do
    {:noreply, %{state | pending_finalizations: max(state.pending_finalizations - 1, 0)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remove_task(state, task_pid) do
    case Map.pop(state.by_pid, task_pid) do
      {nil, _by_pid} ->
        state

      {ref, by_pid} ->
        Process.unlink(task_pid)
        Process.demonitor(ref, [:flush])
        %{state | by_pid: by_pid, by_ref: Map.delete(state.by_ref, ref)}
    end
  end

  defp reconcile_running_operations(cutoff, monitor_pid, page_hook) do
    reconcile_running_page(nil, cutoff, monitor_pid, page_hook)
  rescue
    error ->
      Logger.warning("OperationMonitor reconciliation failed: #{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.warning("OperationMonitor reconciliation #{kind}: #{inspect(reason)}")
      :error
  end

  defp reconcile_running_page(after_id, cutoff, monitor_pid, page_hook) do
    base_query = where_running_after(Operation, after_id, cutoff)

    page =
      Repo.all(
        from(operation in base_query,
          order_by: [asc: operation.id],
          limit: ^@reconciliation_batch_size,
          select: struct(operation, ^@reconciliation_fields)
        )
      )

    _ = page_hook.(page)
    eligible = reconciliation_eligible(monitor_pid, page)

    result =
      Enum.reduce_while(eligible, :ok, fn operation, :ok ->
        case OperationManager.finalize_orphaned_operation(operation) do
          :ok -> {:cont, :ok}
          :error -> {:halt, :error}
        end
      end)

    case {result, List.last(page)} do
      {:error, _last} ->
        :error

      {:ok, %Operation{id: id}} when length(page) == @reconciliation_batch_size ->
        reconcile_running_page(id, cutoff, monitor_pid, page_hook)

      {:ok, _last} ->
        :ok
    end
  end

  defp where_running_after(query, nil, cutoff),
    do:
      from(operation in query,
        where: operation.status == "running" and operation.inserted_at <= ^cutoff
      )

  defp where_running_after(query, after_id, cutoff),
    do:
      from(operation in query,
        where:
          operation.status == "running" and operation.inserted_at <= ^cutoff and
            operation.id > ^after_id
      )

  defp reconciliation_eligible(monitor_pid, page) do
    ref = make_ref()
    send(monitor_pid, {:reconciliation_candidates, self(), ref, page})

    receive do
      {:reconciliation_eligible, ^ref, eligible} -> eligible
    end
  end

  defp enqueue_finalization(state, _metadata, :normal), do: state

  defp enqueue_finalization(state, metadata, reason) do
    send(state.finalizer_pid, {:finalize, metadata, reason, 1})
    %{state | pending_finalizations: state.pending_finalizations + 1}
  end

  defp finalizer_loop(parent, finalize_fun, reconcile_fun) do
    receive do
      {:reconcile_running, cutoff} ->
        event =
          case invoke_reconciler(reconcile_fun, cutoff, parent) do
            :ok -> :reconciliation_finished
            :error -> :reconciliation_failed
          end

        send(parent, {event, self()})
        finalizer_loop(parent, finalize_fun, reconcile_fun)

      {:finalize, metadata, reason, attempt} ->
        case safe_finalize(fn -> finalize_fun.(metadata, reason) end) do
          :ok ->
            send(parent, {:finalization_finished, self()})

          :error when attempt < 5 ->
            Process.send_after(
              self(),
              {:finalize, metadata, reason, attempt + 1},
              attempt * 250
            )

          :error ->
            Logger.error(
              "OperationMonitor could not finalize #{inspect(metadata.operation_id)} after #{attempt} attempts"
            )

            send(parent, {:finalization_finished, self()})
        end

        finalizer_loop(parent, finalize_fun, reconcile_fun)
    end
  end

  defp invoke_reconciler(reconcile_fun, cutoff, parent) do
    case Function.info(reconcile_fun, :arity) do
      {:arity, 0} -> reconcile_fun.()
      {:arity, 2} -> reconcile_fun.(cutoff, parent)
    end
  end

  defp normalize_nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_nonnegative(_value, default), do: default

  @doc false
  def safe_finalize(fun) when is_function(fun, 0) do
    case fun.() do
      :error -> :error
      _result -> :ok
    end
  rescue
    error ->
      Logger.warning("OperationMonitor finalizer raised: #{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.warning("OperationMonitor finalizer #{kind}: #{inspect(reason)}")
      :error
  end

  # Never retain arbitrary operation params, results, closures, or exception
  # terms in the monitor. IDs are capped defensively even though durable IDs
  # are UUIDs in normal operation.
  defp bounded_metadata(metadata) do
    %{
      session_id: bounded_string(Map.fetch!(metadata, :session_id)),
      operation_id: bounded_string(Map.fetch!(metadata, :operation_id)),
      started_monotonic_ms: Map.fetch!(metadata, :started_monotonic_ms),
      parent_caller: Map.fetch!(metadata, :parent_caller),
      agent_name: bounded_string(metadata[:agent_name]),
      op_type: bounded_string(metadata[:op_type]),
      parent_op_id: bounded_string(metadata[:parent_op_id])
    }
  end

  defp bounded_string(nil), do: nil

  defp bounded_string(value) do
    value = to_string(value)
    binary_part(value, 0, min(byte_size(value), 128))
  end

  defp do_await_idle(server, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    snapshot =
      try do
        GenServer.call(server, :snapshot, max(remaining, 1))
      catch
        :exit, _reason -> :unavailable
      end

    case snapshot do
      %{active: 0, pending_finalizations: 0, reconciliation_in_progress?: false} ->
        :ok

      _other when remaining == 0 ->
        {:error, :timeout}

      _other ->
        receive do
        after
          min(remaining, 10) -> do_await_idle(server, deadline)
        end
    end
  end
end
