defmodule IexCode.Observability.MemoryPoller do
  @moduledoc """
  Lightweight background GenServer that periodically samples physical OS memory (RSS),
  BEAM VM memory allocators, concurrent process counts, and micro-garbage collection stats.

  Broadcasts updates across Phoenix PubSub to `"telemetry:memory"` for live consumption
  by LiveView workspace footers and status widgets.
  """

  use GenServer
  alias IexCode.Observability.MemorySnapshot
  alias Phoenix.PubSub

  @topic "telemetry:memory"
  @default_interval_ms 2_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the MemoryPoller GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the latest memory snapshot from the poller state, or samples immediately
  if the poller server is not started.
  """
  def current_metrics(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :current_metrics, 1_000)
        catch
          :exit, _ -> sample_metrics(nil)
        end

      nil ->
        sample_metrics(nil)
    end
  end

  @doc """
  Triggers an immediate sample.

  When called with a running server (PID or registered atom name), causes the server
  to sample, record, broadcast to PubSub, and return the snapshot.
  When called with a `%MemorySnapshot{}` or `nil`, performs a direct synchronous sample.
  """
  def sample_now(target \\ __MODULE__)

  def sample_now(%MemorySnapshot{} = prev) do
    sample_metrics(prev)
  end

  def sample_now(nil) do
    sample_metrics(nil)
  end

  def sample_now(server) when is_pid(server) or is_atom(server) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :sample_now, 2_000)
        catch
          :exit, _ -> sample_metrics(nil)
        end

      nil ->
        sample_metrics(nil)
    end
  end

  @doc """
  Forces global garbage collection on the BEAM node via `:erlang.garbage_collect()`,
  takes an immediate sample, broadcasts to `"telemetry:memory"`, and returns the snapshot.
  """
  def force_gc(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :force_gc, 5_000)
        catch
          :exit, _ ->
            :erlang.garbage_collect()
            snapshot = sample_metrics(nil)
            broadcast_snapshot(IexCode.PubSub, snapshot)
            snapshot
        end

      nil ->
        :erlang.garbage_collect()
        snapshot = sample_metrics(nil)
        broadcast_snapshot(IexCode.PubSub, snapshot)
        snapshot
    end
  end

  @doc """
  Directly samples OS RSS and BEAM VM metrics against a previous snapshot
  to calculate micro-GC deltas without requiring a GenServer.
  """
  def sample_metrics(prev_snapshot \\ nil) do
    rss_bytes = sample_os_rss()
    memory = :erlang.memory()

    beam_total_bytes = Keyword.get(memory, :total, 0)
    beam_processes_bytes = Keyword.get(memory, :processes, 0)
    beam_system_bytes = Keyword.get(memory, :system, 0)
    beam_atom_bytes = Keyword.get(memory, :atom, 0)
    beam_binary_bytes = Keyword.get(memory, :binary, 0)
    beam_ets_bytes = Keyword.get(memory, :ets, 0)

    process_count = :erlang.system_info(:process_count)

    {gc_runs, gc_words_reclaimed, 0} = :erlang.statistics(:garbage_collection)
    wordsize = :erlang.system_info(:wordsize)

    {delta_gc_runs, delta_reclaimed_bytes} =
      case prev_snapshot do
        %MemorySnapshot{gc_runs: prev_runs, gc_words_reclaimed: prev_words} ->
          delta_runs = max(0, gc_runs - prev_runs)
          delta_bytes = max(0, (gc_words_reclaimed - prev_words) * wordsize)
          {delta_runs, delta_bytes}

        _ ->
          {0, 0}
      end

    %MemorySnapshot{
      rss_bytes: rss_bytes,
      beam_total_bytes: beam_total_bytes,
      beam_processes_bytes: beam_processes_bytes,
      beam_system_bytes: beam_system_bytes,
      beam_atom_bytes: beam_atom_bytes,
      beam_binary_bytes: beam_binary_bytes,
      beam_ets_bytes: beam_ets_bytes,
      process_count: process_count,
      gc_runs: gc_runs,
      gc_words_reclaimed: gc_words_reclaimed,
      delta_gc_runs: delta_gc_runs,
      delta_reclaimed_bytes: delta_reclaimed_bytes,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Samples OS Resident Set Size (RSS) in bytes via `ps -o rss=` for the current BEAM OS PID.
  Falls back safely to 0 if command execution fails or is unsupported.
  """
  def sample_os_rss do
    case :os.type() do
      {:unix, _} ->
        case System.cmd("ps", ["-o", "rss=", "-p", to_string(System.pid())],
               stderr_to_stdout: false
             ) do
          {output, 0} ->
            case Integer.parse(String.trim(output)) do
              {kb, _} when kb >= 0 -> kb * 1024
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    app_opts = Application.get_env(:iex_code, :memory_telemetry, [])
    merged_opts = Keyword.merge(app_opts, opts)

    enabled? = Keyword.get(merged_opts, :enabled, true)
    interval_ms = Keyword.get(merged_opts, :interval_ms, @default_interval_ms)
    pubsub_server = Keyword.get(merged_opts, :pubsub_server, IexCode.PubSub)

    initial_snapshot = sample_metrics(nil)

    timer_ref =
      if enabled? and is_integer(interval_ms) and interval_ms > 0 do
        schedule_tick(interval_ms)
      else
        nil
      end

    state = %{
      enabled?: enabled?,
      interval_ms: interval_ms,
      pubsub_server: pubsub_server,
      last_snapshot: initial_snapshot,
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:current_metrics, _from, state) do
    {:reply, state.last_snapshot, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state.last_snapshot, state}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    snapshot = sample_metrics(state.last_snapshot)
    broadcast_snapshot(state.pubsub_server, snapshot)
    {:reply, snapshot, %{state | last_snapshot: snapshot}}
  end

  @impl true
  def handle_call(:force_gc, _from, state) do
    :erlang.garbage_collect()
    snapshot = sample_metrics(state.last_snapshot)
    broadcast_snapshot(state.pubsub_server, snapshot)
    {:reply, snapshot, %{state | last_snapshot: snapshot}}
  end

  @impl true
  def handle_info(:tick, state) do
    snapshot = sample_metrics(state.last_snapshot)
    broadcast_snapshot(state.pubsub_server, snapshot)
    timer_ref = if state.enabled?, do: schedule_tick(state.interval_ms), else: nil
    {:noreply, %{state | last_snapshot: snapshot, timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:poll, state), do: handle_info(:tick, state)
  @impl true
  def handle_info(:sample, state), do: handle_info(:tick, state)

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp schedule_tick(_), do: nil

  defp broadcast_snapshot(pubsub_server, snapshot) do
    if pubsub_server && Process.whereis(pubsub_server) do
      PubSub.broadcast(pubsub_server, @topic, {:memory_telemetry, snapshot})
    end
  rescue
    _ -> :ok
  end

  defp resolve_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp resolve_pid(name) when is_atom(name) do
    Process.whereis(name)
  end

  defp resolve_pid(_), do: nil
end
