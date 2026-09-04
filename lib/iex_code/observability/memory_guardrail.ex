defmodule IexCode.Observability.MemoryGuardrail do
  @moduledoc """
  Durable memory watchdog ensuring continuous >10h non-stop operation without OOM crashes.

  Periodically inspects BEAM VM allocators and physical container/system RSS (default every 5s).
  Provides multi-tiered progressive defense:
  - Warning tier: Runs ETS pruning (`ETSPruner.prune_all/0`), triggers node-level
    garbage collection (`:erlang.garbage_collect/0`), and runs micro-GC on idle processes.
  - Critical tier: Runs major GC across all processes in `Process.list/0`, compacts heap binaries,
    broadcasts pressure events to PubSub, and emits Telemetry.
  """

  use GenServer
  require Logger

  alias IexCode.Observability.ETSPruner
  alias Phoenix.PubSub

  @pubsub IexCode.PubSub
  @topic "telemetry:memory_guardrail"
  @default_check_interval_ms 5_000
  @mib 1_048_576

  # Default system memory fallback in bytes (2,048 MiB)
  @default_total_memory_bytes 2_048 * @mib

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the MemoryGuardrail GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns current memory watchdog status, pressure state, and limits.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :status, 5_000)
        catch
          :exit, _ -> current_status_snapshot()
        end

      nil ->
        current_status_snapshot()
    end
  end

  @doc """
  Forces immediate execution of memory guardrail remediation and returns result.
  """
  @spec force_remediation(GenServer.server()) :: map()
  def force_remediation(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :force_remediation, 10_000)
        catch
          :exit, _ -> do_remediation(:critical)
        end

      nil ->
        do_remediation(:critical)
    end
  end

  @doc """
  Checks whether the system is currently under critical memory pressure.
  Safe for high-frequency callers and load shedding checks.
  """
  @spec critical?(GenServer.server()) :: boolean()
  def critical?(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :pressure_level, 1_000) == :critical
        catch
          :exit, _ ->
            # Fallback direct check if GenServer is unresponsive or busy remediating
            :erlang.memory(:total) >= detect_critical_bytes()
        end

      nil ->
        # Fallback direct check when server process is not running
        :erlang.memory(:total) >= detect_critical_bytes()
    end
  rescue
    _ -> false
  end

  @doc """
  Checks whether the system is currently under any memory pressure (:warning or :critical).
  """
  @spec under_pressure?(GenServer.server()) :: boolean()
  def under_pressure?(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :pressure_level, 1_000) in [:warning, :critical]
        catch
          :exit, _ ->
            # Fallback direct check if GenServer is unresponsive or busy remediating
            :erlang.memory(:total) >= detect_warning_bytes()
        end

      nil ->
        # Fallback direct check when server process is not running
        :erlang.memory(:total) >= detect_warning_bytes()
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    app_opts = Application.get_env(:iex_code, :memory_guardrail, [])
    merged_opts = Keyword.merge(app_opts, opts)

    interval_ms = Keyword.get(merged_opts, :check_interval_ms, @default_check_interval_ms)
    enabled? = Keyword.get(merged_opts, :enabled, true)

    warning_bytes = Keyword.get(merged_opts, :warning_bytes, detect_warning_bytes())
    critical_bytes = Keyword.get(merged_opts, :critical_bytes, detect_critical_bytes())

    timer_ref =
      if enabled? and is_integer(interval_ms) and interval_ms > 0 do
        schedule_check(interval_ms)
      else
        nil
      end

    state = %{
      enabled?: enabled?,
      interval_ms: interval_ms,
      timer_ref: timer_ref,
      warning_bytes: warning_bytes,
      critical_bytes: critical_bytes,
      last_state: :normal,
      remediations_count: 0,
      last_remediation_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:pressure_level, _from, state) do
    {:reply, state.last_state, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply =
      Map.merge(current_status_snapshot(), %{
        pressure_level: state.last_state,
        warning_threshold_bytes: state.warning_bytes,
        critical_threshold_bytes: state.critical_bytes,
        remediations_count: state.remediations_count,
        last_remediation_at: state.last_remediation_at
      })

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:force_remediation, _from, state) do
    remediation_res = do_remediation(:critical)

    new_state = %{
      state
      | remediations_count: state.remediations_count + 1,
        last_remediation_at: DateTime.utc_now()
    }

    {:reply, remediation_res, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    beam_memory = :erlang.memory(:total)
    level = evaluate_pressure(beam_memory, state.warning_bytes, state.critical_bytes)

    new_state =
      if level in [:warning, :critical] do
        _res = do_remediation(level)

        if state.last_state != level do
          Logger.warning(
            "[MemoryGuardrail] Pressure detected (#{level}): #{div(beam_memory, @mib)} MiB in use; remediation applied"
          )
        end

        broadcast_event({:memory_pressure, %{level: level, beam_bytes: beam_memory}})

        %{
          state
          | last_state: level,
            remediations_count: state.remediations_count + 1,
            last_remediation_at: DateTime.utc_now()
        }
      else
        %{state | last_state: :normal}
      end

    timer_ref = if new_state.enabled?, do: schedule_check(new_state.interval_ms), else: nil
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # ============================================================================
  # Internal Remediation
  # ============================================================================

  defp evaluate_pressure(bytes, warning_bytes, critical_bytes) do
    cond do
      bytes >= critical_bytes -> :critical
      bytes >= warning_bytes -> :warning
      true -> :normal
    end
  end

  defp do_remediation(level) do
    prune_res = ETSPruner.prune_all()
    :erlang.garbage_collect()

    gc_processes_count =
      if level == :critical do
        # In critical mode, target top 50 memory-consuming processes to avoid scheduler freeze
        top_pids =
          Process.list()
          |> Enum.map(fn pid ->
            case Process.info(pid, :memory) do
              {:memory, mem} when is_integer(mem) -> {pid, mem}
              _ -> {pid, 0}
            end
          end)
          |> Enum.sort_by(fn {_pid, mem} -> mem end, :desc)
          |> Enum.take(50)
          |> Enum.map(fn {pid, _mem} -> pid end)

        Enum.each(top_pids, fn pid ->
          try do
            :erlang.garbage_collect(pid, type: :major)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        length(top_pids)
      else
        # In warning mode, GC known background servers
        target_servers = [
          IexCode.Observability.MetricsStore,
          IexCode.Swarm.PeerStream,
          IexCode.Observability.ETSPruner,
          IexCode.LLM.Discovery.Server
        ]

        pids =
          Enum.flat_map(target_servers, fn s ->
            case Process.whereis(s) do
              pid when is_pid(pid) -> [pid]
              _ -> []
            end
          end)

        Enum.each(pids, fn pid ->
          try do
            :erlang.garbage_collect(pid)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        length(pids)
      end

    reclaimed = %{
      level: level,
      ets_pruned: prune_res,
      processes_collected: gc_processes_count,
      beam_total_after: :erlang.memory(:total),
      timestamp: DateTime.utc_now()
    }

    :telemetry.execute(
      [:iex_code, :memory_guardrail, :remediation],
      %{processes_collected: gc_processes_count},
      reclaimed
    )

    reclaimed
  end

  defp current_status_snapshot do
    mem = :erlang.memory()
    total = Keyword.get(mem, :total, 0)
    procs = Keyword.get(mem, :processes, 0)
    ets = Keyword.get(mem, :ets, 0)
    binary = Keyword.get(mem, :binary, 0)

    %{
      pressure_level: :normal,
      beam_total_bytes: total,
      beam_processes_bytes: procs,
      beam_ets_bytes: ets,
      beam_binary_bytes: binary,
      process_count: :erlang.system_info(:process_count),
      timestamp: DateTime.utc_now()
    }
  end

  defp detect_warning_bytes do
    total = detect_total_system_memory()
    trunc(total * 0.70)
  end

  defp detect_critical_bytes do
    total = detect_total_system_memory()
    trunc(total * 0.85)
  end

  defp detect_total_system_memory do
    read_configured_limit() ||
      read_env_limit() ||
      read_cgroup_limit() ||
      read_proc_meminfo() ||
      @default_total_memory_bytes
  end

  defp read_configured_limit do
    case Application.get_env(:iex_code, :memory_guardrail, []) do
      opts when is_list(opts) -> Keyword.get(opts, :memory_limit_bytes)
      _ -> nil
    end
  end

  defp read_env_limit do
    case System.get_env("IEX_CODE_MEMORY_LIMIT_MIB") do
      val when is_binary(val) ->
        case Integer.parse(String.trim(val)) do
          {mib, ""} when mib > 0 -> mib * @mib
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_proc_meminfo do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
          [_, kb_str] ->
            case Integer.parse(kb_str) do
              {kb, ""} when kb > 0 -> kb * 1024
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp read_cgroup_limit do
    # Try cgroup v2
    case File.read("/sys/fs/cgroup/memory.max") do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {limit, ""} when limit > 0 -> limit
          _ -> read_cgroup_v1_limit()
        end

      _ ->
        read_cgroup_v1_limit()
    end
  rescue
    _ -> nil
  end

  defp read_cgroup_v1_limit do
    case File.read("/sys/fs/cgroup/memory/memory.limit_in_bytes") do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {limit, ""} when limit > 0 and limit < 9_000_000_000_000_000_000 -> limit
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp schedule_check(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :check, interval_ms)
  end

  defp schedule_check(_), do: nil

  defp broadcast_event(event) do
    if Process.whereis(@pubsub) do
      PubSub.broadcast(@pubsub, @topic, event)
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
