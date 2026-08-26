defmodule IexCode.Observability.MetricsStore do
  @moduledoc """
  Bounded in-process operational view of the execution control plane.

  Durable records remain authoritative. This store consumes low-cardinality
  telemetry so local health surfaces can inspect the latest aggregate snapshot
  and lifecycle counters without rescanning SQLite on every request.
  """

  use GenServer

  @events [
    [:iex_code, :control_plane, :snapshot],
    [:iex_code, :control_plane, :snapshot_error],
    [:iex_code, :operation, :start],
    [:iex_code, :operation, :stop],
    [:iex_code, :operation, :crash],
    [:iex_code, :fleet, :rehydrate_error],
    [:iex_code, :terminal, :command_dispatched],
    [:iex_code, :terminal, :command_completed]
  ]

  @control_plane_keys ~w(
    runs_queued
    runs_active
    runs_attention
    runs_expired_leases
    agents_active
    agents_paused
    agents_attention
    agents_expired_leases
    dag_attempts_active
    dag_attempts_expired_leases
    run_controls_open
    agent_controls_open
    approvals_pending
    approvals_overdue
    workspace_locks_held
    workspace_locks_waiting
    workspace_locks_expired
  )a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    # Telemetry handlers outlive an abruptly killed subscriber. A stable ID per
    # registered store lets a supervised restart remove that stale callback
    # before attaching its replacement instead of leaking one handler per crash.
    handler_id = {__MODULE__, Keyword.get(opts, :name, __MODULE__)}
    :telemetry.detach(handler_id)

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        self()
      )

    {:ok,
     %{
       control_plane: %{},
       counters: %{},
       last_snapshot_at: nil,
       snapshot_errors: 0,
       handler_id: handler_id
     }}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, _metadata, owner) do
    send(owner, {:telemetry_metric, event, measurements})
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(
        {:telemetry_metric, [:iex_code, :control_plane, :snapshot], measurements},
        state
      ) do
    bounded =
      @control_plane_keys
      |> Map.new(fn key ->
        value = Map.get(measurements, key, 0)
        {key, if(is_integer(value) and value >= 0, do: value, else: 0)}
      end)

    {:noreply, %{state | control_plane: bounded, last_snapshot_at: DateTime.utc_now()}}
  end

  def handle_info(
        {:telemetry_metric, [:iex_code, :control_plane, :snapshot_error], _measurements},
        state
      ) do
    {:noreply, %{state | snapshot_errors: state.snapshot_errors + 1}}
  end

  def handle_info({:telemetry_metric, event, _measurements}, state) do
    key = event |> Enum.drop(1) |> Enum.join(".")
    {:noreply, update_in(state.counters[key], &((&1 || 0) + 1))}
  end
end
