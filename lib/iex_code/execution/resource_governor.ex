defmodule IexCode.Execution.ResourceGovernor do
  @moduledoc """
  Memory-aware admission control for expensive execution work.

  Permits are deliberately advisory: lightweight application work does not use
  this process. Expensive callers request a weighted permit and always release
  it, while the governor queues new work when the cgroup is under pressure.
  Request owners are monitored so a crashed caller cannot leak capacity.
  """

  use GenServer

  alias IexCode.Execution.ResourcePermit
  alias IexCode.Execution.ResourcePermitSupervisor

  @mib 1_048_576
  @default_weights %{
    llm_provider: 32 * @mib,
    ast_scan: 32 * @mib,
    research_fetch: 48 * @mib,
    dag_step: 64 * @mib,
    native_command: 128 * @mib,
    build_test: 512 * @mib
  }
  @profile_headroom %{
    # Compact still needs to admit one heavyweight build/test at a realistic
    # BEAM idle footprint. The 85% critical ceiling remains the primary safety
    # boundary, while 128 MiB of hard-limit headroom prevents the 512 MiB class
    # from becoming permanently un-runnable on a 1 GiB deployment.
    compact: 128 * @mib,
    balanced: 320 * @mib,
    throughput: 384 * @mib
  }
  @profile_interactive_reserve %{
    compact: 32 * @mib,
    balanced: 64 * @mib,
    throughput: 128 * @mib
  }
  @default_poll_interval_ms 1_000

  defstruct [
    :name,
    :read_memory,
    :profile,
    :pressure_percent,
    :critical_percent,
    :headroom_bytes,
    :interactive_reserve_bytes,
    :class_weights,
    :permit_supervisor,
    :recovery_key,
    :poll_interval_ms,
    :memory,
    active: %{},
    pending: %{},
    monitor_index: %{},
    interactive_queue: :queue.new(),
    background_queues: %{},
    background_order: :queue.new()
  ]

  @type class ::
          :llm_provider
          | :ast_scan
          | :research_fetch
          | :dag_step
          | :native_command
          | :build_test

  @type priority :: :interactive | :background

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Requests a permit, waiting in the bounded admission queue when necessary."
  @spec request(class(), keyword()) :: {:ok, reference()} | {:error, atom()}
  def request(class, opts \\ [])

  def request(class, opts) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = request_timeout(Keyword.get(opts, :timeout, :infinity))
    priority = Keyword.get(opts, :priority, :background)
    run_key = Keyword.get(opts, :run_key, self())
    ticket_ref = make_ref()

    with {:ok, permit_supervisor} <- request_permit_supervisor(server),
         {:ok, permit_pid} <-
           ResourcePermitSupervisor.start_permit(permit_supervisor, self(), ticket_ref) do
      request_with_permit(
        server,
        permit_pid,
        ticket_ref,
        class,
        priority,
        run_key,
        timeout
      )
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def request(_class, _opts), do: {:error, :invalid_options}

  defp request_permit_supervisor(server) do
    GenServer.call(server, :permit_supervisor)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp request_with_permit(
         server,
         permit_pid,
         ticket_ref,
         class,
         priority,
         run_key,
         timeout
       ) do
    case GenServer.call(
           server,
           {:request, permit_pid, ticket_ref, class, priority, run_key, timeout},
           :infinity
         ) do
      {:ok, ^ticket_ref} = granted ->
        Process.put({__MODULE__, ticket_ref}, permit_pid)
        granted

      {:error, _reason} = error ->
        ResourcePermit.release(permit_pid, ticket_ref, self(), :infinity)
        error
    end
  catch
    :exit, _reason ->
      ResourcePermit.release(permit_pid, ticket_ref, self(), :infinity)
      {:error, :unavailable}
  end

  defp release_owned_permit(ticket_ref) do
    case Process.delete({__MODULE__, ticket_ref}) do
      permit_pid when is_pid(permit_pid) ->
        ResourcePermit.release(permit_pid, ticket_ref, self())

      _missing ->
        :ok
    end
  end

  @doc "Releases a permit. Releasing an unknown or already released reference is harmless."
  @spec release(reference(), GenServer.server()) :: :ok
  def release(ticket_ref, server \\ __MODULE__)

  def release(ticket_ref, server) when is_reference(ticket_ref) do
    result = GenServer.call(server, {:release, ticket_ref, self()})
    release_owned_permit(ticket_ref)
    result
  catch
    :exit, _reason ->
      release_owned_permit(ticket_ref)
      :ok
  end

  def release(_ticket_ref, _server), do: :ok

  @doc "Executes `fun` while holding a permit and releases it on every exit path."
  @spec with_permit(class(), keyword(), (-> result)) :: result | {:error, atom()}
        when result: term()
  def with_permit(class, opts \\ [], fun) when is_list(opts) and is_function(fun, 0) do
    case request(class, opts) do
      {:ok, ticket_ref} ->
        try do
          fun.()
        after
          release(ticket_ref, Keyword.get(opts, :server, __MODULE__))
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec admission_opts(keyword(), keyword()) :: keyword()
  def admission_opts(opts, defaults \\ []) when is_list(opts) and is_list(defaults) do
    process_context = Process.get(:iex_code_resource_context, %{})
    fleet_owner = Process.get(:iex_code_fleet_owner, %{})

    run_key =
      Keyword.get(opts, :resource_run_key) ||
        Keyword.get(opts, :run_id) ||
        context_value(process_context, :run_key) ||
        context_value(fleet_owner, :run_id) ||
        Keyword.get(defaults, :run_key) || self()

    priority =
      Keyword.get(opts, :resource_priority) ||
        context_value(process_context, :priority) ||
        (context_value(fleet_owner, :run_id) && :background) ||
        Keyword.get(defaults, :priority) ||
        if(run_key == self(), do: :interactive, else: :background)

    []
    |> Keyword.put(:server, Keyword.get(opts, :resource_governor, __MODULE__))
    |> Keyword.put(:timeout, Keyword.get(opts, :resource_timeout, :infinity))
    |> Keyword.put(:priority, priority)
    |> Keyword.put(:run_key, run_key)
  end

  @doc false
  def put_process_context(priority, run_key)
      when priority in [:interactive, :background] do
    Process.put(:iex_code_resource_context, %{priority: priority, run_key: run_key})
  end

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key, Map.get(context, to_string(key)))

  defp context_value(context, key) when is_list(context), do: Keyword.get(context, key)
  defp context_value(_context, _key), do: nil

  @doc "Returns aggregate admission and cgroup memory state without owner or run identifiers."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> unavailable_snapshot()
  end

  @doc "Applies validated admission thresholds without interrupting active permits."
  @spec update_policy(map(), GenServer.server()) :: :ok | {:error, atom()}
  def update_policy(policy, server \\ __MODULE__)

  def update_policy(%{pressure_percent: pressure, critical_percent: critical}, server)
      when is_integer(pressure) and is_integer(critical) and pressure >= 50 and
             pressure < critical and critical <= 95 do
    GenServer.call(server, {:update_policy, pressure, critical})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def update_policy(_policy, _server), do: {:error, :invalid_policy}

  @doc false
  def default_class_weights, do: @default_weights

  @doc false
  def read_cgroup_memory(root \\ "/sys/fs/cgroup") do
    %{
      memory_current_bytes: read_number(Path.join(root, "memory.current")),
      memory_limit_bytes: read_number(Path.join(root, "memory.max")),
      pressure: read_pressure(Path.join(root, "memory.pressure")),
      events: read_key_values(Path.join(root, "memory.events"))
    }
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:iex_code, :resource_governor, [])
    merged = Keyword.merge(config, opts)
    profile = normalize_profile(Keyword.get(merged, :profile, :balanced))
    weights = normalize_weights(Keyword.get(merged, :class_weights, %{}))

    pressure_percent = bounded_percent(Keyword.get(merged, :pressure_percent, 70), 70)
    critical_percent = bounded_percent(Keyword.get(merged, :critical_percent, 85), 85)

    {pressure_percent, critical_percent} =
      if pressure_percent < critical_percent,
        do: {pressure_percent, critical_percent},
        else: {70, 85}

    state = %__MODULE__{
      name: Keyword.get(merged, :name, __MODULE__),
      read_memory: Keyword.get(merged, :read_memory, &__MODULE__.read_cgroup_memory/0),
      profile: profile,
      pressure_percent: pressure_percent,
      critical_percent: critical_percent,
      headroom_bytes:
        nonnegative_integer(
          Keyword.get(merged, :headroom_bytes, Map.fetch!(@profile_headroom, profile)),
          Map.fetch!(@profile_headroom, profile)
        ),
      interactive_reserve_bytes:
        nonnegative_integer(
          Keyword.get(
            merged,
            :interactive_reserve_bytes,
            Map.fetch!(@profile_interactive_reserve, profile)
          ),
          Map.fetch!(@profile_interactive_reserve, profile)
        ),
      class_weights: weights,
      permit_supervisor: Keyword.get(merged, :permit_supervisor, ResourcePermitSupervisor),
      recovery_key:
        Keyword.get(merged, :recovery_key, Keyword.get(merged, :name, __MODULE__) || make_ref()),
      poll_interval_ms:
        normalize_poll_interval(Keyword.get(merged, :poll_interval_ms, @default_poll_interval_ms))
    }

    case recover_active_permits(state) do
      {:ok, state} ->
        state = refresh_memory(state)
        schedule_poll(state.poll_interval_ms)
        {:ok, state}

      {:error, :unavailable} ->
        {:stop, :permit_supervisor_unavailable}
    end
  end

  @impl true
  def handle_call(:permit_supervisor, _from, state) do
    {:reply, {:ok, state.permit_supervisor}, state}
  end

  def handle_call(
        {:request, permit_pid, ticket_ref, class, priority, run_key, timeout},
        from,
        state
      ) do
    cond do
      not Map.has_key?(state.class_weights, class) ->
        {:reply, {:error, :unknown_class}, state}

      priority not in [:interactive, :background] ->
        {:reply, {:error, :invalid_priority}, state}

      timeout == :invalid ->
        {:reply, {:error, :invalid_timeout}, state}

      true ->
        state = refresh_memory(state)
        owner = elem(from, 0)

        if valid_pending_permit?(permit_pid, ticket_ref, owner) do
          owner_monitor_ref = Process.monitor(owner)
          permit_monitor_ref = Process.monitor(permit_pid)

          entry = %{
            ticket_ref: ticket_ref,
            owner: owner,
            owner_monitor_ref: owner_monitor_ref,
            permit_monitor_ref: permit_monitor_ref,
            permit_pid: permit_pid,
            class: class,
            weight: Map.fetch!(state.class_weights, class),
            priority: priority,
            run_key: run_key,
            from: from,
            timer: nil
          }

          state =
            state
            |> put_in([Access.key(:monitor_index), owner_monitor_ref], ticket_ref)
            |> put_in([Access.key(:monitor_index), permit_monitor_ref], ticket_ref)

          if immediate_admission?(state, entry) do
            case activate(state, entry) do
              {:ok, state} -> {:reply, {:ok, ticket_ref}, state}
              {:error, state} -> {:reply, {:error, :unavailable}, state}
            end
          else
            entry = put_timeout(entry, timeout)
            state = enqueue(state, entry)
            {:noreply, state}
          end
        else
          {:reply, {:error, :unavailable}, state}
        end
    end
  end

  def handle_call({:release, ticket_ref, owner}, _from, state) do
    state = state |> release_active(ticket_ref, owner) |> refresh_memory() |> drain_queue()
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    state = state |> refresh_memory() |> drain_queue()
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:update_policy, pressure, critical}, _from, state) do
    state =
      state
      |> Map.put(:pressure_percent, pressure)
      |> Map.put(:critical_percent, critical)
      |> refresh_memory()
      |> drain_queue()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:capacity_timeout, ticket_ref}, state) do
    case Map.pop(state.pending, ticket_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        demonitor_entry(entry)
        GenServer.reply(entry.from, {:error, :capacity_timeout})

        state = %{
          state
          | pending: pending,
            monitor_index: drop_monitor_indexes(state.monitor_index, entry)
        }

        {:noreply, compact_queues(state)}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_index, monitor_ref) do
      {nil, _index} ->
        {:noreply, state}

      {ticket_ref, monitor_index} ->
        {active_entry, active} = Map.pop(state.active, ticket_ref)
        {pending_entry, pending} = Map.pop(state.pending, ticket_ref)
        cancel_timer(pending_entry)
        entry = active_entry || pending_entry
        demonitor_entry(entry)

        state = %{
          state
          | active: active,
            pending: pending,
            monitor_index: drop_monitor_indexes(monitor_index, entry)
        }

        state =
          if active_entry || pending_entry do
            state |> compact_queues() |> refresh_memory() |> drain_queue()
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info(:resource_governor_poll, state) do
    state = state |> refresh_memory() |> drain_queue()
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp recover_active_permits(state) do
    case ResourcePermitSupervisor.active_entries(state.permit_supervisor) do
      {:error, :unavailable} ->
        {:error, :unavailable}

      entries when is_list(entries) ->
        recovered =
          Enum.reduce(entries, state, fn
            %{ticket_ref: ticket_ref, permit_pid: permit_pid, owner: owner, metadata: metadata},
            state
            when is_reference(ticket_ref) and is_pid(permit_pid) and is_pid(owner) and
                   is_map(metadata) ->
              if Map.get(metadata, :recovery_key) == state.recovery_key do
                owner_monitor_ref = Process.monitor(owner)
                permit_monitor_ref = Process.monitor(permit_pid)

                entry =
                  metadata
                  |> Map.take([:class, :weight, :priority, :run_key])
                  |> Map.merge(%{
                    ticket_ref: ticket_ref,
                    permit_pid: permit_pid,
                    owner: owner,
                    owner_monitor_ref: owner_monitor_ref,
                    permit_monitor_ref: permit_monitor_ref
                  })

                state
                |> put_in([Access.key(:active), ticket_ref], entry)
                |> put_in([Access.key(:monitor_index), owner_monitor_ref], ticket_ref)
                |> put_in([Access.key(:monitor_index), permit_monitor_ref], ticket_ref)
              else
                state
              end

            _invalid, state ->
              state
          end)

        {:ok, recovered}
    end
  end

  defp valid_pending_permit?(permit_pid, ticket_ref, owner) do
    case ResourcePermit.entry(permit_pid) do
      {:ok,
       %{
         permit_pid: ^permit_pid,
         ticket_ref: ^ticket_ref,
         owner: ^owner,
         status: :pending
       }} ->
        true

      _other ->
        false
    end
  end

  defp drain_queue(state) do
    attempts =
      if :queue.is_empty(state.interactive_queue),
        do: map_size(state.background_queues),
        else: 1

    drain_queue(state, attempts)
  end

  # Scan each currently pending ticket at most once. A heavyweight request that
  # cannot fit must not head-of-line block a smaller request at the same
  # priority (or another background run) that can make safe forward progress.
  defp drain_queue(state, 0), do: state

  defp drain_queue(state, attempts_remaining) do
    case next_pending(state) do
      {:none, state} ->
        state

      {{:ok, entry}, state} ->
        if admissible?(state, entry) do
          cancel_timer(entry)

          case activate(state, %{entry | timer: nil}) do
            {:ok, state} ->
              GenServer.reply(entry.from, {:ok, entry.ticket_ref})
              drain_queue(state)

            {:error, state} ->
              GenServer.reply(entry.from, {:error, :unavailable})
              drain_queue(state)
          end
        else
          case entry.priority do
            # Interactive requests have equal weight, so if the FIFO head does
            # not fit none of its successors can fit either. Preserve strict
            # ordering and the interactive-first contract.
            :interactive ->
              requeue_interactive_front(state, entry)

            # Preserve FIFO within a run but move that run behind its peers, so
            # an oversized request cannot block safe work from another run.
            :background ->
              state
              |> requeue_background_after_run(entry)
              |> drain_queue(attempts_remaining - 1)
          end
        end
    end
  end

  defp next_pending(state) do
    case take_live_interactive(state.interactive_queue, state.pending) do
      {:ok, ticket_ref, queue} ->
        entry = Map.fetch!(state.pending, ticket_ref)

        {{:ok, entry},
         %{state | interactive_queue: queue, pending: Map.delete(state.pending, ticket_ref)}}

      :none ->
        take_live_background(state)
    end
  end

  defp take_live_interactive(queue, pending) do
    case :queue.out(queue) do
      {{:value, ticket_ref}, rest} ->
        if Map.has_key?(pending, ticket_ref),
          do: {:ok, ticket_ref, rest},
          else: take_live_interactive(rest, pending)

      {:empty, _queue} ->
        :none
    end
  end

  defp take_live_background(state) do
    case take_background_key(state.background_order, state.background_queues, state.pending) do
      :none ->
        {:none, %{state | background_order: :queue.new(), background_queues: %{}}}

      {:ok, _run_key, ticket_ref, order, queues} ->
        entry = Map.fetch!(state.pending, ticket_ref)

        {{:ok, entry},
         %{
           state
           | background_order: order,
             background_queues: queues,
             pending: Map.delete(state.pending, ticket_ref)
         }}
    end
  end

  defp take_background_key(order, queues, pending) do
    case :queue.out(order) do
      {{:value, run_key}, rest_order} ->
        queue = Map.get(queues, run_key, :queue.new())

        case take_live_ticket(queue, pending) do
          :none ->
            take_background_key(rest_order, Map.delete(queues, run_key), pending)

          {:ok, ticket_ref, remaining} ->
            if :queue.is_empty(remaining) do
              {:ok, run_key, ticket_ref, rest_order, Map.delete(queues, run_key)}
            else
              {:ok, run_key, ticket_ref, :queue.in(run_key, rest_order),
               Map.put(queues, run_key, remaining)}
            end
        end

      {:empty, _order} ->
        :none
    end
  end

  defp take_live_ticket(queue, pending) do
    case :queue.out(queue) do
      {{:value, ticket_ref}, rest} ->
        if Map.has_key?(pending, ticket_ref),
          do: {:ok, ticket_ref, rest},
          else: take_live_ticket(rest, pending)

      {:empty, _queue} ->
        :none
    end
  end

  defp enqueue(state, entry) do
    state = put_in(state.pending[entry.ticket_ref], entry)

    case entry.priority do
      :interactive ->
        %{state | interactive_queue: :queue.in(entry.ticket_ref, state.interactive_queue)}

      :background ->
        existing = Map.get(state.background_queues, entry.run_key)
        queue = :queue.in(entry.ticket_ref, existing || :queue.new())

        %{
          state
          | background_queues: Map.put(state.background_queues, entry.run_key, queue),
            background_order:
              if(existing,
                do: state.background_order,
                else: :queue.in(entry.run_key, state.background_order)
              )
        }
    end
  end

  defp requeue_interactive_front(state, entry) do
    %{
      state
      | pending: Map.put(state.pending, entry.ticket_ref, entry),
        interactive_queue: :queue.in_r(entry.ticket_ref, state.interactive_queue)
    }
  end

  defp requeue_background_after_run(state, entry) do
    queue =
      state.background_queues
      |> Map.get(entry.run_key, :queue.new())
      |> then(&:queue.in_r(entry.ticket_ref, &1))

    order =
      state.background_order
      |> :queue.to_list()
      |> Enum.reject(&(&1 == entry.run_key))
      |> :queue.from_list()
      |> then(&:queue.in(entry.run_key, &1))

    %{
      state
      | pending: Map.put(state.pending, entry.ticket_ref, entry),
        background_queues: Map.put(state.background_queues, entry.run_key, queue),
        background_order: order
    }
  end

  defp activate(state, entry) do
    metadata =
      entry
      |> Map.take([:class, :weight, :priority, :run_key])
      |> Map.put(:recovery_key, state.recovery_key)

    case ResourcePermit.activate(entry.permit_pid, entry.ticket_ref, metadata) do
      :ok ->
        active_entry = Map.drop(entry, [:from, :timer])
        {:ok, put_in(state.active[entry.ticket_ref], active_entry)}

      {:error, _reason} ->
        demonitor_entry(entry)

        {:error, %{state | monitor_index: drop_monitor_indexes(state.monitor_index, entry)}}
    end
  end

  defp release_active(state, ticket_ref, owner) do
    case Map.pop(state.active, ticket_ref) do
      {nil, _active} ->
        state

      {%{owner: ^owner} = entry, active} ->
        ResourcePermit.release(entry.permit_pid, ticket_ref, owner)
        demonitor_entry(entry)

        %{
          state
          | active: active,
            monitor_index: drop_monitor_indexes(state.monitor_index, entry)
        }

      {_other_owner, _active} ->
        state
    end
  end

  defp immediate_admission?(state, %{priority: :interactive} = entry) do
    :queue.is_empty(state.interactive_queue) and admissible?(state, entry)
  end

  defp immediate_admission?(state, entry),
    do: queue_empty?(state) and admissible?(state, entry)

  defp admissible?(state, entry) do
    case state.memory do
      %{current: current, limit: limit}
      when is_integer(current) and is_integer(limit) and limit > 0 ->
        projected = current + reserved_bytes(state) + entry.weight
        continuation? = continuation_of_active_dag?(state, entry)

        critical_ceiling =
          min(
            div(limit * state.critical_percent, 100),
            limit - state.headroom_bytes
          )

        admission_ceiling =
          cond do
            continuation? -> limit - state.headroom_bytes
            entry.priority == :background -> critical_ceiling - state.interactive_reserve_bytes
            true -> critical_ceiling
          end

        normal_or_continuation? =
          continuation? or
            memory_state(state.memory, state.pressure_percent, state.critical_percent) == :normal

        normal_or_continuation? and projected <= max(admission_ceiling, 0)

      # Hosts without cgroup v2 accounting (notably local macOS development)
      # must remain functional. The governor is advisory there and fails open;
      # production containers always expose current/max accounting.
      _memory ->
        true
    end
  end

  # A DAG permit covers the base handler. Provider/fetch permits are continuations
  # of already-admitted work and may use the safety-headroom ceiling, otherwise a
  # full set of admitted DAG handlers could deadlock while all wait for nested
  # effects. New DAG topology remains subject to the normal background ceiling.
  defp continuation_of_active_dag?(state, entry) do
    entry.class != :dag_step and
      Enum.any?(state.active, fn {_ref, active} ->
        active.class == :dag_step and active.run_key == entry.run_key
      end)
  end

  defp refresh_memory(state) do
    memory =
      try do
        state.read_memory.() |> normalize_memory()
      rescue
        _error -> unavailable_memory()
      catch
        _kind, _reason -> unavailable_memory()
      end

    %{state | memory: memory}
  end

  defp normalize_memory(memory) when is_map(memory) do
    current = memory[:memory_current_bytes] || memory[:current_bytes] || memory[:current]
    limit = memory[:memory_limit_bytes] || memory[:limit_bytes] || memory[:limit]

    if is_integer(current) and current >= 0 and is_integer(limit) and limit > 0 do
      %{
        current: current,
        limit: limit,
        pressure: Map.get(memory, :pressure, %{}),
        events: Map.get(memory, :events, %{})
      }
    else
      unavailable_memory()
    end
  end

  defp normalize_memory(_memory), do: unavailable_memory()
  defp unavailable_memory, do: %{current: nil, limit: nil, pressure: %{}, events: %{}}

  defp memory_state(%{current: current, limit: limit}, pressure, critical)
       when is_integer(current) and is_integer(limit) and limit > 0 do
    percent = current * 100 / limit

    cond do
      percent >= critical -> :critical
      percent >= pressure -> :pressure
      true -> :normal
    end
  end

  defp memory_state(_memory, _pressure, _critical), do: :unavailable

  defp build_snapshot(state) do
    %{
      state: memory_state(state.memory, state.pressure_percent, state.critical_percent),
      memory_current_bytes: state.memory.current,
      memory_limit_bytes: state.memory.limit,
      reserved_bytes: reserved_bytes(state),
      interactive_reserve_bytes: state.interactive_reserve_bytes,
      active_by_class:
        Map.new(state.class_weights, fn {class, _weight} ->
          {class, Enum.count(state.active, fn {_ref, entry} -> entry.class == class end)}
        end),
      queued_interactive:
        Enum.count(state.pending, fn {_ref, entry} -> entry.priority == :interactive end),
      queued_background:
        Enum.count(state.pending, fn {_ref, entry} -> entry.priority == :background end)
    }
  end

  defp unavailable_snapshot do
    %{
      state: :unavailable,
      memory_current_bytes: nil,
      memory_limit_bytes: nil,
      reserved_bytes: 0,
      interactive_reserve_bytes: 0,
      active_by_class: Map.new(@default_weights, fn {class, _weight} -> {class, 0} end),
      queued_interactive: 0,
      queued_background: 0
    }
  end

  defp reserved_bytes(state) do
    Enum.reduce(state.active, 0, fn {_ref, entry}, total -> total + entry.weight end)
  end

  defp queue_empty?(state), do: map_size(state.pending) == 0

  defp put_timeout(entry, :infinity), do: entry

  defp put_timeout(entry, timeout) do
    %{entry | timer: Process.send_after(self(), {:capacity_timeout, entry.ticket_ref}, timeout)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(%{timer: nil}), do: :ok

  defp cancel_timer(%{timer: timer}) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp demonitor_entry(nil), do: :ok

  defp demonitor_entry(entry) do
    Enum.each([entry[:owner_monitor_ref], entry[:permit_monitor_ref]], fn
      monitor_ref when is_reference(monitor_ref) -> Process.demonitor(monitor_ref, [:flush])
      _missing -> :ok
    end)
  end

  defp drop_monitor_indexes(index, nil), do: index

  defp drop_monitor_indexes(index, entry) do
    Enum.reduce([entry[:owner_monitor_ref], entry[:permit_monitor_ref]], index, fn
      monitor_ref, index when is_reference(monitor_ref) -> Map.delete(index, monitor_ref)
      _missing, index -> index
    end)
  end

  defp compact_queues(state) do
    interactive =
      state.interactive_queue
      |> :queue.to_list()
      |> Enum.filter(&Map.has_key?(state.pending, &1))
      |> :queue.from_list()

    {queues, keys} =
      state.background_order
      |> :queue.to_list()
      |> Enum.uniq()
      |> Enum.reduce({%{}, []}, fn key, {queues, keys} ->
        live =
          state.background_queues
          |> Map.get(key, :queue.new())
          |> :queue.to_list()
          |> Enum.filter(&Map.has_key?(state.pending, &1))

        if live == [],
          do: {queues, keys},
          else: {Map.put(queues, key, :queue.from_list(live)), keys ++ [key]}
      end)

    %{
      state
      | interactive_queue: interactive,
        background_queues: queues,
        background_order: :queue.from_list(keys)
    }
  end

  defp normalize_weights(overrides) when is_map(overrides) do
    Enum.reduce(overrides, @default_weights, fn
      {class, weight}, weights
      when is_atom(class) and is_integer(weight) and weight > 0 and
             is_map_key(@default_weights, class) ->
        Map.put(weights, class, weight)

      _invalid, weights ->
        weights
    end)
  end

  defp normalize_weights(_overrides), do: @default_weights

  defp normalize_profile(profile) when profile in [:compact, :balanced, :throughput], do: profile
  defp normalize_profile(_profile), do: :balanced

  defp bounded_percent(value, _default) when is_integer(value) and value in 1..100, do: value
  defp bounded_percent(_value, default), do: default

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default

  defp request_timeout(:infinity), do: :infinity
  defp request_timeout(value) when is_integer(value) and value >= 0, do: value
  defp request_timeout(_value), do: :invalid

  defp normalize_poll_interval(:infinity), do: :infinity
  defp normalize_poll_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_poll_interval(_value), do: @default_poll_interval_ms

  defp schedule_poll(:infinity), do: :ok
  defp schedule_poll(interval), do: Process.send_after(self(), :resource_governor_poll, interval)

  defp read_number(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {number, ""} when number >= 0 -> number
          _invalid -> nil
        end

      _error ->
        nil
    end
  end

  defp read_pressure(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [kind | values] = String.split(line)

          parsed =
            Map.new(values, fn field ->
              case String.split(field, "=", parts: 2) do
                [key, value] -> {key, parse_number(value)}
                [key] -> {key, nil}
              end
            end)

          {kind, parsed}
        end)

      _error ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp read_key_values(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          case String.split(line, ~r/\s+/, parts: 2) do
            [key, value] -> {key, parse_number(value)}
            [key] -> {key, nil}
          end
        end)

      _error ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {number, ""} ->
        number

      _invalid ->
        case Float.parse(value) do
          {number, ""} -> number
          _invalid -> nil
        end
    end
  end
end
