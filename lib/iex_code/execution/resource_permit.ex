defmodule IexCode.Execution.ResourcePermit do
  @moduledoc false

  use GenServer

  defstruct [:owner, :owner_monitor, :ticket_ref, :metadata, status: :pending]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :ticket_ref),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def activate(pid, ticket_ref, metadata) when is_pid(pid) and is_reference(ticket_ref) do
    GenServer.call(pid, {:activate, ticket_ref, metadata})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def entry(pid) when is_pid(pid) do
    GenServer.call(pid, :entry)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def release(pid, ticket_ref, owner, timeout \\ 5_000)
      when is_pid(pid) and is_reference(ticket_ref) and is_pid(owner) do
    GenServer.call(pid, {:release, ticket_ref, owner}, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    ticket_ref = Keyword.fetch!(opts, :ticket_ref)

    # A permit worker is deliberately independent from the governor but linked
    # to the admitted owner. Governor restarts therefore preserve the lease. If
    # the lease layer itself fails, the owner cannot continue expensive work
    # without a tracked reservation.
    Process.link(owner)
    owner_monitor = Process.monitor(owner)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_monitor: owner_monitor,
       ticket_ref: ticket_ref
     }}
  end

  @impl true
  def handle_call({:activate, ticket_ref, metadata}, _from, state)
      when ticket_ref == state.ticket_ref and state.status == :pending and is_map(metadata) do
    {:reply, :ok, %{state | status: :active, metadata: metadata}}
  end

  def handle_call({:activate, ticket_ref, _metadata}, _from, state)
      when ticket_ref == state.ticket_ref do
    {:reply, {:error, :invalid_state}, state}
  end

  def handle_call({:activate, _ticket_ref, _metadata}, _from, state) do
    {:reply, {:error, :invalid_ticket}, state}
  end

  def handle_call(:entry, _from, state) do
    entry = %{
      owner: state.owner,
      ticket_ref: state.ticket_ref,
      permit_pid: self(),
      status: state.status,
      metadata: state.metadata
    }

    {:reply, {:ok, entry}, state}
  end

  def handle_call({:release, ticket_ref, owner}, _from, state)
      when ticket_ref == state.ticket_ref and owner == state.owner do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:release, _ticket_ref, _owner}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state)
      when monitor_ref == state.owner_monitor and owner == state.owner do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
