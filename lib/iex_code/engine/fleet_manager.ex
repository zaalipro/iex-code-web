defmodule IexCode.Engine.FleetManager do
  @moduledoc "Run-scoped owner and control router for a bounded durable agent fleet."
  use GenServer
  require Logger

  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, FleetControlToken}
  alias IexCode.Runs
  alias IexCode.Runs.RunAgent

  @roles ~w(planner explorer coder verifier)a
  @lease_ms 30_000
  @heartbeat_ms 10_000
  # Durable controls can each perform several SQLite transactions. Keep replay
  # chunks deliberately small so a large backlog yields to GenServer calls,
  # heartbeats, and controls for other agents between chunks.
  @control_replay_batch_size 16
  @control_receipt_poll_ms 10
  @control_receipt_max_poll_ms 100
  @terminal_control_statuses ~w(applied rejected superseded)
  # A replacement fleet supervisor receives a new secret and cannot take over
  # rows until the prior 30-second lease expires. Keep the bounded retry window
  # beyond that lease horizon so recovery cannot stop just before takeover is
  # legal.
  @rehydrate_retry_limit 6

  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_fleet(run.id, :manager))
  end

  def activate(run_id, rows, opts \\ []) when is_list(rows) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:activate, rows, opts}, 30_000)
  end

  def list_agents(run_id), do: GenServer.call(AgentRegistry.via_fleet(run_id, :manager), :list)

  @doc false
  def matches_parent_lineage?(run_id, run) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:matches_parent_lineage, run.attempt, run.lease_generation, run.lease_owner}
    )
  catch
    :exit, _reason -> false
  end

  @doc false
  def rehydration_errors(run_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), :rehydration_errors)
  end

  def agent_pid(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:agent_pid, agent_id})
  end

  @doc "Returns the current live incarnation of one durable agent identity."
  def current_agent(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:current_agent, agent_id})
  end

  def role_pids(run_id, role) when role in @roles do
    run_id
    |> list_agents()
    |> Enum.filter(&(&1.role == role and is_pid(&1.pid) and Process.alive?(&1.pid)))
    |> Enum.map(& &1.pid)
  end

  def drain_steering(run_id, agent_id) do
    GenServer.call(AgentRegistry.via_fleet(run_id, :manager), {:drain_steering, agent_id})
  end

  def control_all(run_id, action, payload \\ %{}) when action in [:pause, :resume] do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:control_all, action, payload},
      30_000
    )
  end

  def apply_durable_control(run_id, control_id) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:apply_durable_control, control_id},
      30_000
    )
  end

  @doc """
  Waits for a durable agent control to reach a terminal status.

  The receipt is bounded by `timeout` and is based on persisted control state,
  rather than GenServer mailbox ordering. If the caller is already subscribed
  to the run, matching PubSub updates provide a fast path; bounded persistence
  polling makes the barrier reliable across processes and BEAM instances too.
  """
  def await_control(run_id, control_id, timeout \\ 30_000)

  def await_control(run_id, control_id, timeout)
      when is_binary(run_id) and is_binary(control_id) and is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_control_receipt(run_id, control_id, deadline, @control_receipt_poll_ms)
  end

  def await_control(_run_id, _control_id, _timeout),
    do: {:error, :invalid_control_receipt}

  def runtime_begin(run_id, agent_id, generation, task) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_begin, agent_id, generation, task},
      30_000
    )
  end

  def runtime_progress(run_id, agent_id, generation, percent, message) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_progress, agent_id, generation, percent, message},
      30_000
    )
  end

  def runtime_finish(run_id, agent_id, generation, result) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_finish, agent_id, generation, result},
      30_000
    )
  end

  def runtime_usage(run_id, agent_id, generation, usage, source) do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:runtime_usage, agent_id, generation, usage, source},
      30_000
    )
  end

  @doc false
  def control(run_id, agent_id, action, payload \\ %{})
      when action in [:pause, :resume, :cancel, :steer, :restart] do
    GenServer.call(
      AgentRegistry.via_fleet(run_id, :manager),
      {:control, agent_id, action, payload},
      30_000
    )
  end

  def stop(run_id, status, opts) when is_binary(run_id) and is_list(opts) do
    case GenServer.call(
           AgentRegistry.via_fleet(run_id, :manager),
           {:stop, status, requested_parent_authority(opts)},
           30_000
         ) do
      :ok ->
        teardown_fleet(run_id)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def stop(_run_id, _status, _opts), do: {:error, :invalid_parent_authority}

  def stop(_run_id, _status \\ "interrupted"), do: {:error, :parent_authority_required}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    run = Keyword.fetch!(opts, :run)
    lease_owner = Keyword.fetch!(opts, :fleet_lease_secret)
    Process.put(:fleet_lease_owner, lease_owner)

    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    state = %{
      run: run,
      parent_authority: %{
        lease_owner: run.lease_owner,
        run_attempt: run.attempt,
        lease_generation: run.lease_generation
      },
      session: opts[:session],
      project_root: opts[:project_root],
      allowed_tools: Keyword.get(opts, :allowed_tools, :all),
      workspace_lock_delegation: opts[:workspace_lock_delegation],
      supervisor: AgentRegistry.via_fleet(run.id, :agent_supervisor),
      agents: %{},
      budget_callers: %{},
      control_replay_scheduled?: false,
      control_replay_cursor: nil,
      rehydrate_errors: [],
      rehydrate_attempt: 0,
      activation_opts: opts
    }

    {:ok, state, {:continue, :rehydrate}}
  end

  @impl true
  def handle_continue(:rehydrate, state) do
    case require_parent_run_status(state, ["running", "paused"]) do
      {:ok, state} -> rehydrate(state)
      {:error, _reason} -> {:noreply, deactivate_stale_fleet(state)}
    end
  end

  defp rehydrate(state) do
    _ = Runs.reconcile_terminal_run_agent_controls(run_id: state.run.id)

    rows =
      state.run.id
      |> Runs.list_run_agents()
      |> Enum.filter(&rehydratable?/1)

    {agents, errors} =
      Enum.reduce(rows, {state.agents, []}, fn row, {agents, errors} ->
        case ensure_agent(state, agents, row, state.activation_opts) do
          {:ok, _entry, updated} ->
            {updated, errors}

          {:error, reason} ->
            report_rehydrate_error(state.run.id, row, reason)
            {agents, [{row.id, reason} | errors]}
        end
      end)

    state =
      state
      |> Map.put(:agents, agents)
      |> Map.put(:rehydrate_errors, Enum.reverse(errors))
      |> schedule_control_replay()

    if errors != [], do: Process.send_after(self(), :retry_rehydrate, 1_000)

    {:noreply, state}
  end

  @impl true
  def handle_call({:activate, rows, opts}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         :ok <- validate_rows(state.run.id, rows) do
      {agents, result} =
        Enum.reduce_while(rows, {state.agents, []}, fn row, {agents, result} ->
          case ensure_agent(state, agents, row, opts) do
            {:ok, entry, updated} -> {:cont, {updated, [public_entry(entry) | result]}}
            {:error, reason} -> {:halt, {agents, {:error, reason}}}
          end
        end)

      case result do
        {:error, _} = error -> {:reply, error, %{state | agents: agents}}
        entries -> {:reply, {:ok, Enum.reverse(entries)}, %{state | agents: agents}}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:matches_parent_lineage, attempt, generation, owner}, _from, state) do
    authority = state.parent_authority

    {:reply,
     authority.run_attempt == attempt and authority.lease_generation == generation and
       authority.lease_owner == owner, state}
  end

  def handle_call(:list, _from, state) do
    entries =
      state.agents
      |> Map.values()
      |> Enum.sort_by(&{&1.position, &1.key})
      |> Enum.map(&public_entry/1)

    {:reply, entries, state}
  end

  def handle_call(:rehydration_errors, _from, state) do
    {:reply, state.rehydrate_errors, state}
  end

  def handle_call({:agent_pid, agent_id}, _from, state) do
    reply =
      case Map.get(state.agents, agent_id) do
        nil -> nil
        entry -> entry.pid
      end

    {:reply, reply, state}
  end

  def handle_call({:current_agent, agent_id}, _from, state) do
    {reply, state} =
      with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]) do
        case Map.get(state.agents, agent_id) do
          %{pid: pid} = entry when is_pid(pid) ->
            with true <- Process.alive?(pid),
                 %RunAgent{lease_generation: generation, status: status} = row <-
                   Runs.get_run_agent(state.run.id, agent_id),
                 true <- generation == entry.generation,
                 true <- status in RunAgent.leased_statuses(),
                 {:ok, row} <- Runs.assert_run_agent_lease(row, lease_owner(), generation) do
              refreshed = %{entry | row: row, status: String.to_existing_atom(status)}
              {{:ok, public_entry(refreshed)}, put_in(state.agents[agent_id], refreshed)}
            else
              _ -> {{:error, :agent_not_active}, state}
            end

          nil ->
            {{:error, :agent_not_found}, state}

          _entry ->
            {{:error, :agent_not_active}, state}
        end
      else
        {:error, reason} -> {{:error, reason}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:drain_steering, agent_id}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]) do
      case Map.get(state.agents, agent_id) do
        nil ->
          {:reply, [], state}

        entry ->
          case Runs.consume_run_agent_steering_controls(
                 entry.row,
                 lease_owner(),
                 entry.generation
               ) do
            {:ok, directives} -> {:reply, Enum.map(directives, & &1["guidance"]), state}
            {:error, _reason} -> {:reply, [], state}
          end
      end
    else
      {:error, _reason} -> {:reply, [], state}
    end
  end

  def handle_call({:control, agent_id, action, payload}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]) do
      case Map.fetch(state.agents, agent_id) do
        :error ->
          {:reply, {:error, :agent_not_found}, state}

        {:ok, entry} ->
          case Runs.get_run_agent(entry.agent_id) do
            %RunAgent{lease_generation: generation} = row when generation == entry.generation ->
              fresh = %{entry | row: row, status: String.to_existing_atom(row.status)}
              apply_control(put_in(state.agents[agent_id], fresh), fresh, action, payload)

            _ ->
              {:reply, {:error, :lease_lost}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:control_all, action, payload}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]) do
      {results, updated_state} =
        Enum.reduce(state.agents, {[], state}, fn {agent_id, entry}, {results, acc} ->
          fresh = Map.get(acc.agents, agent_id, entry)

          case apply_control_result(acc, fresh, action, payload) do
            {:ok, result, updated} -> {[{agent_id, result} | results], updated}
            {:error, reason, updated} -> {[{agent_id, {:error, reason}} | results], updated}
          end
        end)

      {:reply, {:ok, Enum.reverse(results)}, updated_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_durable_control, control_id}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]) do
      case Runs.get_run_agent_control(control_id) do
        %{run_id: run_id, run_agent_id: agent_id} = control when run_id == state.run.id ->
          case Map.get(state.agents, agent_id) do
            nil ->
              {:reply, {:error, :agent_not_active}, state}

            entry ->
              case Runs.get_run_agent(state.run.id, agent_id) do
                %RunAgent{} = row ->
                  fresh = %{
                    entry
                    | row: row,
                      generation: row.lease_generation,
                      status: String.to_existing_atom(row.status)
                  }

                  apply_control_queue(put_in(state.agents[agent_id], fresh), fresh, control)

                nil ->
                  {:reply, {:error, :agent_not_found}, state}
              end
          end

        nil ->
          {:reply, {:error, :control_not_found}, state}

        _foreign ->
          {:reply, {:error, :agent_scope_mismatch}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runtime_begin, agent_id, generation, task}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         true <- entry.row.status == "idle" || {:error, :agent_not_available},
         {:ok, row} <-
           Runs.transition_run_agent(entry.row, "running", %{current_task: task, progress: 0},
             lease_owner: lease_owner(),
             lease_generation: generation
           ) do
      updated = %{entry | row: row, status: :running}
      {:reply, :ok, put_in(state.agents[agent_id], updated)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runtime_progress, agent_id, generation, percent, message}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         {:ok, row} <-
           Runs.heartbeat_run_agent(entry.row, lease_owner(), generation, @lease_ms, %{
             progress: min(max(percent, 0), 100),
             current_task: String.slice(message, 0, 20_000)
           }) do
      {:reply, :ok, put_in(state.agents[agent_id], %{entry | row: row})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runtime_finish, agent_id, generation, result}, _from, state) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation) do
      if entry.row.status == "running" do
        status = if entry.row.desired_state == "paused", do: "paused", else: "idle"

        attrs = %{
          current_task: nil,
          progress: if(match?({:ok, _}, result), do: 100, else: entry.row.progress),
          error_message: runtime_error(result)
        }

        case Runs.transition_run_agent(entry.row, status, attrs,
               lease_owner: lease_owner(),
               lease_generation: generation
             ) do
          {:ok, row} ->
            updated = %{entry | row: row, status: String.to_existing_atom(status)}
            {:reply, :ok, put_in(state.agents[agent_id], updated)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:runtime_usage, agent_id, generation, usage, source},
        {caller_pid, _tag},
        state
      ) do
    with {:ok, state} <- require_parent_run_status(state, ["running", "paused"]),
         {:ok, entry} <- runtime_entry(state, agent_id, generation),
         {:ok, row} <-
           Runs.record_run_agent_usage(entry.row, usage, source,
             lease_owner: lease_owner(),
             lease_generation: generation,
             terminal_lease_ms: @lease_ms
           ) do
      {:reply, :ok, put_in(state.agents[agent_id], %{entry | row: row})}
    else
      {:error, {:token_budget_exhausted, failed_run}} ->
        terminalize_budget_exhausted_fleet(
          state,
          failed_run,
          :token_budget_exhausted,
          caller_pid
        )

      {:error, {:cost_budget_exhausted, failed_run}} ->
        terminalize_budget_exhausted_fleet(
          state,
          failed_run,
          :cost_budget_exhausted,
          caller_pid
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, status, requested_authority}, _from, state)
      when status in ["completed", "failed", "cancelled", "interrupted"] do
    if requested_authority != state.parent_authority do
      {:reply, {:error, :parent_lease_lost}, state}
    else
      entries = Map.values(state.agents)

      result =
        Runs.terminalize_run_agents(
          state.run,
          status,
          %{error_message: terminal_error(status)},
          terminalization_authority_opts(state)
        )

      case result do
        {:ok, _rows} ->
          Enum.each(entries, &FleetControlToken.cancel(&1.token))
          Enum.each(entries, &demonitor_entry/1)
          launch_agent_shutdown(state.run.id, entries)

          {:reply, :ok,
           %{
             state
             | agents: %{},
               control_replay_cursor: nil,
               control_replay_scheduled?: false
           }}

        {:error, reason} ->
          Logger.error(
            "Run #{state.run.id} fleet shutdown could not terminalize agents: #{inspect(reason)}"
          )

          {:reply, {:error, {:fleet_terminalization_failed, reason}}, state}
      end
    end
  end

  defp terminal_error("completed"), do: nil
  defp terminal_error(status), do: "Run fleet #{status}"

  @impl true
  def handle_info(:heartbeat, state) do
    case require_parent_run_status(state, ["running", "paused"]) do
      {:ok, state} -> heartbeat_agents(state)
      {:error, _reason} -> {:noreply, deactivate_stale_fleet(state)}
    end
  end

  def handle_info(:replay_controls, state) do
    state = %{state | control_replay_scheduled?: false}

    case require_parent_run_status(state, ["running", "paused"]) do
      {:ok, state} ->
        case replay_controls(state, @control_replay_batch_size) do
          {updated, :more} -> {:noreply, schedule_control_replay(updated)}
          {updated, _status} -> {:noreply, updated}
        end

      {:error, _reason} ->
        {:noreply, deactivate_stale_fleet(state)}
    end
  end

  def handle_info(:retry_rehydrate, %{rehydrate_errors: []} = state), do: {:noreply, state}

  def handle_info(:retry_rehydrate, state) do
    case require_parent_run_status(state, ["running", "paused"]) do
      {:ok, state} -> retry_rehydrate(state)
      {:error, _reason} -> {:noreply, deactivate_stale_fleet(state)}
    end
  end

  def handle_info({:terminate_budget_children, entries}, state) when is_list(entries) do
    Enum.each(entries, fn entry ->
      _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
    end)

    {:noreply, state}
  end

  def handle_info({:terminate_budget_owner, ref}, state) when is_reference(ref) do
    case Map.pop(state.budget_callers, ref) do
      {nil, _callers} ->
        {:noreply, state}

      {entry, callers} ->
        Process.demonitor(ref, [:flush])
        _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
        {:noreply, %{state | budget_callers: callers}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.budget_callers, ref) do
      {entry, callers} when not is_nil(entry) ->
        # The usage caller has now received the structured budget result and
        # completed its own unwind. Keep a bounded grace period so the owning
        # GenServer can relay the operation result to its caller before it is
        # terminated as well; the separate five-second timer remains the hard
        # fallback when a linked caller never exits.
        Process.send_after(self(), {:terminate_budget_children, [entry]}, 100)
        {:noreply, %{state | budget_callers: callers}}

      {nil, _callers} ->
        case Enum.find(state.agents, fn {_id, entry} -> entry.ref == ref end) do
          nil ->
            {:noreply, state}

          {agent_id, entry} ->
            FleetControlToken.cancel(entry.token)
            _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
            _ = release(entry, state, "interrupted", %{error_message: inspect(reason)})
            updated = %{entry | pid: nil, ref: nil, status: :interrupted, error: inspect(reason)}
            {:noreply, put_in(state.agents[agent_id], updated)}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp heartbeat_agents(state) do
    agents =
      Map.new(state.agents, fn {id, entry} ->
        updated =
          if heartbeat_eligible?(entry) do
            case Runs.heartbeat_run_agent(
                   entry.row,
                   lease_owner(),
                   entry.generation,
                   @lease_ms,
                   %{}
                 ) do
              {:ok, row} ->
                %{entry | row: row}

              {:error, reason} ->
                FleetControlToken.cancel(entry.token)
                demonitor_entry(entry)
                _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
                %{entry | pid: nil, ref: nil, status: :interrupted, error: inspect(reason)}
            end
          else
            entry
          end

        {id, updated}
      end)

    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state |> Map.put(:agents, agents) |> schedule_control_replay()}
  end

  defp retry_rehydrate(state) do
    _ = Runs.reconcile_orphaned_run_agents(run_id: state.run.id)
    failed_ids = MapSet.new(Enum.map(state.rehydrate_errors, &elem(&1, 0)))

    rows =
      state.run.id
      |> Runs.list_run_agents()
      |> Enum.filter(&(MapSet.member?(failed_ids, &1.id) and rehydratable?(&1)))

    {agents, errors} =
      Enum.reduce(rows, {state.agents, []}, fn row, {agents, errors} ->
        case ensure_agent(state, agents, row, state.activation_opts) do
          {:ok, _entry, updated} ->
            {updated, errors}

          {:error, reason} ->
            report_rehydrate_error(state.run.id, row, reason)
            {agents, [{row.id, reason} | errors]}
        end
      end)

    attempt = state.rehydrate_attempt + 1

    if errors != [] and attempt < @rehydrate_retry_limit do
      Process.send_after(self(), :retry_rehydrate, min(1_000 * Integer.pow(2, attempt), 10_000))
    end

    updated = %{
      state
      | agents: agents,
        rehydrate_errors: Enum.reverse(errors),
        rehydrate_attempt: attempt
    }

    {:noreply, schedule_control_replay(updated)}
  end

  defp replay_controls(state, limit) do
    candidates = replay_control_candidates(state, limit)

    {updated, result} =
      Enum.reduce_while(candidates, {state, :done}, fn {entry, control}, {current, _status} ->
        fresh_entry = Map.get(current.agents, entry.agent_id, entry)

        case apply_control_queue(current, fresh_entry, control) do
          {:reply, {:ok, _result}, next} ->
            next = %{next | control_replay_cursor: entry.agent_id}
            {:cont, {next, :done}}

          {:reply, {:error, reason}, next} ->
            case Runs.get_run_agent_control(control.id) do
              %{status: status} when status in ["applied", "rejected", "superseded"] ->
                # The effect can fail while its durable control is successfully
                # rejected. That is forward progress, so do not starve later
                # agents until the next heartbeat.
                next = %{next | control_replay_cursor: entry.agent_id}
                {:cont, {next, :done}}

              _open_or_missing ->
                Logger.warning(
                  "Run #{state.run.id} control replay paused at agent #{entry.agent_id}: #{inspect(reason)}"
                )

                {:halt, {next, :blocked}}
            end
        end
      end)

    cond do
      result == :blocked -> {updated, :blocked}
      length(candidates) == limit -> {updated, :more}
      true -> {updated, :done}
    end
  end

  defp replay_control_candidates(state, limit) do
    queues =
      Enum.map(replay_agent_order(state), fn {_id, entry} ->
        controls =
          ["pending", "claimed"]
          |> Enum.flat_map(&Runs.list_run_agent_controls(entry.agent_id, status: &1, limit: 200))
          |> Enum.reject(&(&1.kind == "restart" and &1.status == "claimed"))
          |> Enum.sort_by(&{&1.sequence, &1.id})

        {entry, controls}
      end)

    max_depth =
      queues |> Enum.map(fn {_entry, controls} -> length(controls) end) |> Enum.max(fn -> 0 end)

    if max_depth == 0 do
      []
    else
      0..(max_depth - 1)
      |> Enum.flat_map(fn index ->
        Enum.flat_map(queues, fn {entry, controls} ->
          case Enum.at(controls, index) do
            nil -> []
            control -> [{entry, control}]
          end
        end)
      end)
      |> Enum.take(limit)
    end
  end

  defp replay_agent_order(state) do
    entries = Enum.sort_by(state.agents, fn {_id, entry} -> {entry.position, entry.key} end)

    case Enum.split_while(entries, fn {_id, entry} ->
           entry.agent_id != state.control_replay_cursor
         end) do
      {before, [cursor | after_cursor]} -> after_cursor ++ before ++ [cursor]
      {_before, []} -> entries
    end
  end

  defp schedule_control_replay(%{control_replay_scheduled?: true} = state), do: state

  defp schedule_control_replay(state) do
    send(self(), :replay_controls)
    %{state | control_replay_scheduled?: true}
  end

  defp await_control_receipt(run_id, control_id, deadline, poll_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :control_receipt_timeout}
    else
      case fetch_control_receipt(control_id, min(remaining, @control_receipt_max_poll_ms)) do
        {:ok, %{run_id: ^run_id, status: status} = control}
        when status in @terminal_control_statuses ->
          {:ok, control}

        {:ok, %{run_id: ^run_id}} ->
          await_open_control_receipt(run_id, control_id, deadline, poll_ms)

        {:ok, _missing_or_different_run} ->
          {:error, :control_not_found}

        :retry ->
          # The fleet may briefly own SQLite's only available writer/connection.
          # Treat checkout pressure as a transient observation failure, not as a
          # failed receipt, while preserving the caller's original deadline.
          await_open_control_receipt(run_id, control_id, deadline, poll_ms)
      end
    end
  end

  defp fetch_control_receipt(control_id, timeout) do
    {:ok, Runs.get_run_agent_control(control_id, timeout: timeout)}
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      if transient_control_receipt_database_error?(error) do
        :retry
      else
        reraise error, __STACKTRACE__
      end
  end

  defp transient_control_receipt_database_error?(%DBConnection.OwnershipError{}), do: true

  defp transient_control_receipt_database_error?(%DBConnection.ConnectionError{} = error) do
    message = error |> Exception.message() |> String.downcase()

    String.contains?(message, "could not checkout the connection") or
      String.contains?(message, "connection not available") or
      String.contains?(message, "request was dropped from queue")
  end

  defp await_open_control_receipt(run_id, control_id, deadline, poll_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :control_receipt_timeout}
    else
      receive do
        {:run_agent_control_updated,
         %{id: ^control_id, run_id: ^run_id, status: status} = control}
        when status in @terminal_control_statuses ->
          {:ok, control}

        {:run_agent_control_updated, %{id: ^control_id, run_id: ^run_id}} ->
          await_control_receipt(run_id, control_id, deadline, poll_ms)
      after
        min(remaining, poll_ms) ->
          await_control_receipt(
            run_id,
            control_id,
            deadline,
            min(poll_ms * 2, @control_receipt_max_poll_ms)
          )
      end
    end
  end

  defp heartbeat_eligible?(%{pid: pid, row: %RunAgent{status: status}})
       when is_pid(pid) and status in ["starting", "idle", "running", "paused", "stopping"] do
    Process.alive?(pid)
  end

  defp heartbeat_eligible?(_entry), do: false

  defp rehydratable?(%RunAgent{status: status, desired_state: desired_state}) do
    desired_state != "stopped" and
      status in ["pending", "interrupted" | RunAgent.leased_statuses()]
  end

  defp report_rehydrate_error(run_id, row, reason) do
    Logger.error(
      "Run #{run_id} could not rehydrate fleet agent #{row.id} (#{row.key}): #{inspect(reason)}"
    )

    :telemetry.execute(
      [:iex_code, :fleet, :rehydrate_error],
      %{count: 1},
      %{run_id: run_id, agent_id: row.id, agent_key: row.key, reason: reason}
    )
  end

  defp launch_agent_shutdown(run_id, entries) do
    pids = entries |> Enum.map(& &1.pid) |> Enum.filter(&is_pid/1)

    result =
      try do
        Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
          AgentSupervisor.stop_run_pids(pids)
        end)
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Run #{run_id} could not start supervised fleet cleanup: #{inspect(reason)}"
        )

        Enum.each(pids, fn pid ->
          if Process.alive?(pid), do: Process.exit(pid, :shutdown)
        end)
    end
  end

  defp teardown_fleet(run_id) do
    IexCode.Engine.FleetSupervisor.stop(run_id)
  rescue
    error ->
      Logger.warning(
        "Run #{run_id} fleet supervisor teardown failed: #{Exception.message(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("Run #{run_id} fleet supervisor teardown failed: #{inspect({kind, reason})}")
      :ok
  end

  defp ensure_agent(state, agents, %RunAgent{} = row, opts) do
    case Map.get(agents, row.id) do
      %{pid: pid} = entry when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, entry, agents},
          else: start_agent(state, agents, row, opts)

      _ ->
        start_agent(state, agents, row, opts)
    end
  end

  defp start_agent(state, agents, %RunAgent{status: "interrupted"} = row, opts) do
    case pending_restart_control(row) do
      nil -> claim_and_start_agent(state, agents, row, opts)
      control -> recover_restart_control(state, agents, row, control, opts)
    end
  end

  defp start_agent(state, agents, %RunAgent{} = row, opts) do
    claim_and_start_agent(state, agents, row, opts)
  end

  defp claim_and_start_agent(state, agents, row, opts) do
    with {:ok, claimed} <- claim_if_needed(row, lease_owner()) do
      start_claimed_agent(state, agents, claimed, opts)
    end
  end

  defp recover_restart_control(state, agents, row, _control, opts) do
    with {:ok, {claimed_agent, claimed_control}} <-
           Runs.claim_restart_run_agent_control(row, lease_owner(), @lease_ms),
         {:ok, restarted, agents} <-
           start_claimed_agent(state, Map.delete(agents, row.id), claimed_agent, opts) do
      resolve_started_restart(state, restarted, agents, claimed_control)
    end
  end

  defp pending_restart_control(row) do
    active =
      row.id
      |> Runs.list_run_agent_controls()
      |> Enum.find(&(&1.status in ["pending", "claimed"]))

    case active do
      %{status: "pending", kind: "restart", target_generation: generation} = control
      when generation == row.lease_generation ->
        control

      _other ->
        nil
    end
  end

  defp start_claimed_agent(state, agents, %RunAgent{} = claimed, opts) do
    with role when role in @roles <- normalize_role(claimed.role) do
      token = FleetControlToken.new()

      agent_opts =
        [
          session_id: state.run.session_id,
          session: state.session,
          project_root: state.project_root,
          generation: claimed.lease_generation,
          run_agent_id: claimed.id,
          control_token: token,
          allowed_tools: state.allowed_tools,
          workspace_lock_delegation: state.workspace_lock_delegation
        ] ++ opts

      case AgentSupervisor.start_run_agent(
             state.supervisor,
             state.run.id,
             claimed.id,
             role,
             agent_opts
           ) do
        {:ok, pid} ->
          with :ok <- validate_registration(state.run.id, claimed, role, pid),
               {:ok, ready} <- ready_agent_row(claimed, token) do
            entry = %{
              agent_id: claimed.id,
              key: claimed.key,
              role: role,
              position: claimed.position,
              generation: claimed.lease_generation,
              pid: pid,
              ref: Process.monitor(pid),
              token: token,
              row: ready,
              status: String.to_existing_atom(ready.status),
              error: nil
            }

            {:ok, entry, Map.put(agents, claimed.id, entry)}
          else
            {:error, reason} ->
              _ =
                AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, claimed.id)

              _ =
                release_row(claimed, state, "interrupted", %{error_message: inspect(reason)})

              {:error, {claimed.key, reason}}
          end

        {:error, reason} ->
          _ = release_row(claimed, state, "interrupted", %{error_message: inspect(reason)})
          {:error, {claimed.key, reason}}
      end
    else
      nil -> {:error, {claimed.key, :invalid_role}}
    end
  end

  defp ready_agent_row(%RunAgent{status: "paused"} = claimed, token) do
    FleetControlToken.pause(token)
    {:ok, claimed}
  end

  defp ready_agent_row(%RunAgent{} = claimed, _token) do
    Runs.transition_run_agent(claimed, "idle", %{},
      lease_owner: lease_owner(),
      lease_generation: claimed.lease_generation
    )
  end

  defp claim_if_needed(%RunAgent{status: status} = row, owner)
       when status in ["pending", "interrupted"] do
    Runs.claim_run_agent(row, owner, @lease_ms)
  end

  defp claim_if_needed(%RunAgent{} = row, owner) do
    with {:ok, _asserted} <- Runs.assert_run_agent_lease(row, owner, row.lease_generation),
         {:ok, interrupted} <-
           Runs.release_run_agent_lease(
             row,
             owner,
             row.lease_generation,
             "interrupted",
             %{error_message: "fleet_manager_restarted"}
           ) do
      Runs.claim_run_agent(interrupted, owner, @lease_ms)
    end
  end

  defp apply_control(state, entry, :pause, _payload) do
    case transition_control_result(state, entry, "paused", %{desired_state: "paused"}) do
      {:ok, updated_state} ->
        FleetControlToken.pause(entry.token)
        {:reply, {:ok, :paused}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, entry, :resume, _payload) do
    target = if entry.row.current_task, do: "running", else: "idle"

    case transition_control_result(state, entry, target, %{desired_state: "active"}) do
      {:ok, updated_state} ->
        FleetControlToken.resume(entry.token)
        {:reply, {:ok, :resumed}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, _entry, :steer, payload) do
    guidance = value(payload, :guidance)

    if is_binary(guidance) and String.trim(guidance) != "" do
      {:reply, {:ok, :queued}, state}
    else
      {:reply, {:error, :invalid_guidance}, state}
    end
  end

  defp apply_control(state, entry, :cancel, _payload) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    case release(entry, state, "cancelled", %{desired_state: "stopped"}) do
      {:ok, row} ->
        updated = %{entry | pid: nil, ref: nil, status: :cancelled, row: row}
        {:reply, {:ok, :cancelled}, put_in(state.agents[entry.agent_id], updated)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_control(state, entry, :restart, _payload) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    with {:ok, interrupted} <- release(entry, state, "interrupted", %{desired_state: "active"}),
         {:ok, restarted, agents} <-
           start_agent(state, Map.delete(state.agents, entry.agent_id), interrupted, []) do
      {:reply, {:ok, public_entry(restarted)}, %{state | agents: agents}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp apply_control_result(state, entry, action, payload) do
    case apply_control(state, entry, action, payload) do
      {:reply, {:ok, result}, updated} -> {:ok, result, updated}
      {:reply, {:error, reason}, updated} -> {:error, reason, updated}
    end
  end

  defp apply_control_queue(state, _entry, %{status: "applied"}),
    do: {:reply, {:ok, :already_applied}, state}

  defp apply_control_queue(state, entry, target) do
    if target.kind == "restart" and restart_control_at_head?(entry, target) do
      apply_restart_control(state, entry, target)
    else
      apply_regular_control_queue(state, entry, target)
    end
  end

  defp apply_regular_control_queue(state, entry, target) do
    case Runs.claim_next_run_agent_control(
           entry.row,
           lease_owner(),
           entry.generation
         ) do
      {:ok, claimed} ->
        action = String.to_existing_atom(claimed.kind)

        case apply_control_result(state, entry, action, claimed.payload) do
          {:ok, effect, updated_state} ->
            result = control_result(action, effect)

            case Runs.resolve_run_agent_control(
                   claimed,
                   "applied",
                   result,
                   lease_owner(),
                   claimed.claim_generation
                 ) do
              {:ok, _resolved} ->
                outward_effect = if action == :steer, do: :steered, else: effect

                if claimed.id == target.id do
                  {:reply, {:ok, outward_effect}, updated_state}
                else
                  next_entry = Map.get(updated_state.agents, entry.agent_id, entry)
                  apply_control_queue(updated_state, next_entry, target)
                end

              {:error, reason} ->
                {:reply, {:error, reason}, updated_state}
            end

          {:error, reason, updated_state} ->
            _ =
              Runs.resolve_run_agent_control(
                claimed,
                "rejected",
                %{"action" => Atom.to_string(action), "error" => error_code(reason)},
                lease_owner(),
                claimed.claim_generation
              )

            if claimed.id == target.id do
              {:reply, {:error, reason}, updated_state}
            else
              next_entry = Map.get(updated_state.agents, entry.agent_id, entry)
              apply_control_queue(updated_state, next_entry, target)
            end
        end

      :none ->
        {:reply, {:error, :control_not_claimable}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp restart_control_at_head?(entry, target) do
    active =
      entry.agent_id
      |> Runs.list_run_agent_controls()
      |> Enum.find(&(&1.status in ["pending", "claimed"]))

    case active do
      %{id: id} when id == target.id ->
        true

      _ ->
        false
    end
  end

  defp apply_restart_control(state, entry, _target) do
    FleetControlToken.cancel(entry.token)
    demonitor_entry(entry)
    _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)

    with {:ok, interrupted} <- prepare_restart_claim(entry, state),
         {:ok, {claimed_agent, claimed_control}} <-
           Runs.claim_restart_run_agent_control(interrupted, lease_owner(), @lease_ms),
         {:ok, restarted, agents} <-
           start_claimed_agent(
             state,
             Map.delete(state.agents, entry.agent_id),
             claimed_agent,
             []
           ) do
      case resolve_started_restart(state, restarted, agents, claimed_control) do
        {:ok, restarted, agents} ->
          {:reply, {:ok, public_entry(restarted)}, %{state | agents: agents}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp resolve_started_restart(state, restarted, agents, claimed_control) do
    case Runs.resolve_run_agent_control(
           claimed_control,
           "applied",
           control_result(:restart, public_entry(restarted)),
           lease_owner(),
           claimed_control.claim_generation
         ) do
      {:ok, _resolved} ->
        {:ok, restarted, agents}

      {:error, reason} ->
        # Starting the replacement and resolving its durable receipt cannot be
        # one DB/process transaction. If receipt fencing wins the race, stop
        # and release the replacement before returning so it is never lost
        # outside `state.agents`.
        FleetControlToken.cancel(restarted.token)
        demonitor_entry(restarted)
        _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, restarted.agent_id)

        _ =
          release_row(restarted.row, state, "interrupted", %{
            error_message: "restart_control_resolution_failed"
          })

        {:error, reason}
    end
  end

  # An interrupted row has already surrendered its lease. Releasing it again is both
  # unnecessary and an invalid interrupted -> interrupted lifecycle transition. Live
  # incarnations must still be stopped and fenced into interrupted before the atomic
  # restart-control claim advances their generation.
  defp prepare_restart_claim(%{row: %RunAgent{status: "interrupted"}} = entry, _state) do
    {:ok, entry.row}
  end

  defp prepare_restart_claim(entry, state) do
    release(entry, state, "interrupted", %{desired_state: "active"})
  end

  defp control_result(:restart, %{generation: generation}) when is_integer(generation) do
    %{"action" => "restart", "status" => "restarted", "generation" => generation}
  end

  defp control_result(:steer, :queued),
    do: %{"action" => "steer", "status" => "queued"}

  defp control_result(action, status) when is_atom(status),
    do: %{"action" => Atom.to_string(action), "status" => Atom.to_string(status)}

  defp control_result(action, _effect),
    do: %{"action" => Atom.to_string(action), "status" => "applied"}

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "control_failed"

  defp transition_control_result(state, entry, status, attrs) do
    case Runs.transition_run_agent(entry.row, status, attrs,
           lease_owner: lease_owner(),
           lease_generation: entry.generation
         ) do
      {:ok, row} ->
        updated = %{entry | status: String.to_existing_atom(status), row: row}
        {:ok, put_in(state.agents[entry.agent_id], updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release(entry, state, status, attrs) do
    release_row(entry.row, state, status, attrs)
  end

  defp release_row(row, _state, status, attrs) do
    Runs.release_run_agent_lease(
      row,
      lease_owner(),
      row.lease_generation,
      status,
      attrs
    )
  end

  defp validate_rows(_run_id, rows) when length(rows) > 32,
    do: {:error, :fleet_limit_exceeded}

  defp validate_rows(run_id, rows) do
    cond do
      rows == [] -> {:error, :empty_fleet}
      Enum.any?(rows, &(&1.run_id != run_id)) -> {:error, :agent_scope_mismatch}
      Enum.any?(rows, &(normalize_role(&1.role) not in @roles)) -> {:error, :invalid_role}
      true -> :ok
    end
  end

  defp validate_registration(run_id, row, role, pid) do
    case AgentRegistry.agent_registration(run_id, row.id) do
      {:ok, ^pid, %{role: ^role, generation: generation}}
      when generation == row.lease_generation ->
        :ok

      _ ->
        {:error, :agent_registration_mismatch}
    end
  end

  defp runtime_entry(state, agent_id, generation) do
    case Map.get(state.agents, agent_id) do
      %{generation: ^generation} = entry -> {:ok, entry}
      nil -> {:error, :agent_not_active}
      _stale -> {:error, :lease_lost}
    end
  end

  defp require_parent_run_status(state, allowed_statuses) do
    case Runs.get_run(state.run.id) do
      %IexCode.Runs.Run{} = run ->
        authority = state.parent_authority

        cond do
          run.attempt != authority.run_attempt or
            run.lease_generation != authority.lease_generation or
            run.lease_owner != authority.lease_owner or not live_parent_lease?(run) ->
            {:error, :parent_lease_lost}

          run.status not in allowed_statuses ->
            {:error, {:run_not_active, run.status}}

          true ->
            {:ok, %{state | run: run}}
        end

      nil ->
        {:error, :run_not_found}
    end
  end

  defp live_parent_lease?(%{lease_expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp live_parent_lease?(_run), do: false

  defp parent_authority_opts(state) do
    authority = state.parent_authority

    [
      lease_owner: authority.lease_owner,
      run_attempt: authority.run_attempt,
      lease_generation: authority.lease_generation
    ]
  end

  defp requested_parent_authority(opts) do
    %{
      lease_owner: opts[:lease_owner],
      run_attempt: opts[:run_attempt],
      lease_generation: opts[:lease_generation]
    }
  end

  defp terminalization_authority_opts(state) do
    authority = state.parent_authority

    case Runs.get_run(state.run.id) do
      %{
        attempt: attempt,
        lease_generation: generation,
        status: status
      }
      when attempt == authority.run_attempt and generation == authority.lease_generation and
             status in ["completed", "failed", "cancelled", "interrupted"] ->
        run = Runs.get_run!(state.run.id)

        if run.lease_owner == authority.lease_owner and live_parent_lease?(run) do
          parent_authority_opts(state)
        else
          [
            run_attempt: authority.run_attempt,
            lease_generation: authority.lease_generation,
            reconcile_terminal: true
          ]
        end

      _active_or_stale ->
        parent_authority_opts(state)
    end
  end

  defp deactivate_stale_fleet(state) do
    entries = Map.values(state.agents)

    Enum.each(entries, fn entry ->
      FleetControlToken.cancel(entry.token)
      demonitor_entry(entry)
      _ = AgentSupervisor.stop_run_agent(state.supervisor, state.run.id, entry.agent_id)
    end)

    %{
      state
      | agents: %{},
        control_replay_cursor: nil,
        control_replay_scheduled?: false,
        rehydrate_errors: []
    }
  end

  defp terminalize_budget_exhausted_fleet(state, failed_run, budget_error, caller_pid) do
    entries = Map.values(state.agents)

    Enum.each(entries, fn entry ->
      FleetControlToken.cancel(entry.token)
    end)

    attrs = %{
      error_message: failed_run.error_message,
      error_details: failed_run.error_details
    }

    case Runs.terminalize_run_agents(failed_run, "failed", attrs, parent_authority_opts(state)) do
      {:ok, _terminalized} ->
        Enum.each(entries, &demonitor_entry/1)

        {deferred_owner, immediate_entries} =
          Enum.split_with(entries, &usage_caller_linked_to_agent?(&1, caller_pid))

        # GenServer sends the reply from this callback before processing this
        # self-message. Siblings terminate immediately after the reply. An
        # owning child stays alive until its linked usage task exits after
        # observing the structured result.
        send(self(), {:terminate_budget_children, immediate_entries})

        {budget_callers, _refs} =
          Enum.reduce(deferred_owner, {state.budget_callers, []}, fn entry, {callers, refs} ->
            ref = Process.monitor(caller_pid)
            Process.send_after(self(), {:terminate_budget_owner, ref}, 5_000)
            {Map.put(callers, ref, entry), [ref | refs]}
          end)

        {:reply, {:error, budget_error},
         %{state | run: failed_run, agents: %{}, budget_callers: budget_callers}}

      {:error, reason} ->
        Logger.error(
          "Run #{failed_run.id} exhausted its budget but fleet terminalization failed: #{inspect(reason)}"
        )

        {:reply, {:error, {budget_error, {:fleet_terminalization_failed, reason}}},
         %{state | run: failed_run}}
    end
  end

  defp usage_caller_linked_to_agent?(%{pid: agent_pid}, caller_pid)
       when is_pid(agent_pid) and is_pid(caller_pid) do
    caller_pid == agent_pid or
      case Process.info(agent_pid, :links) do
        {:links, links} -> caller_pid in links
        nil -> false
      end
  end

  defp usage_caller_linked_to_agent?(_entry, _caller_pid), do: false

  defp runtime_error({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp runtime_error({:error, _reason}), do: "agent_work_failed"
  defp runtime_error(_result), do: nil

  defp demonitor_entry(%{ref: ref}) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_entry(_entry), do: :ok

  defp normalize_role(role) when role in @roles, do: role

  defp normalize_role(role) when is_binary(role),
    do: Enum.find(@roles, &(Atom.to_string(&1) == role))

  defp normalize_role(_role), do: nil

  defp public_entry(entry) do
    Map.take(entry, [:agent_id, :key, :role, :position, :generation, :pid, :status, :error])
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp lease_owner, do: Process.get(:fleet_lease_owner)
end
