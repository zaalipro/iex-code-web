defmodule IexCode.Observability.RuntimeStatus do
  @moduledoc """
  Failure-tolerant, aggregate runtime status for local operational surfaces.

  The snapshot deliberately contains counts only. It never exposes run, agent,
  session, project, worker, or lease identifiers.
  """

  alias IexCode.Engine.{AgentSupervisor, FleetSupervisor, SessionSupervisor}
  alias IexCode.Observability.MetricsStore
  alias IexCode.Runs.RunDispatcher
  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Tools.TerminalSupervisor

  @default_cgroup_root "/sys/fs/cgroup"
  @default_snapshot_timeout_ms 1_000
  @max_snapshot_timeout_ms 5_000

  @typedoc "A non-secret, aggregate view of the local application runtime."
  @type snapshot :: %{
          state: :idle | :active | :unavailable,
          container: %{
            memory_current_bytes: non_neg_integer() | nil,
            memory_peak_bytes: non_neg_integer() | nil,
            memory_limit_bytes: non_neg_integer() | :unlimited | nil,
            oom_events: non_neg_integer() | nil,
            oom_kill_events: non_neg_integer() | nil,
            pids_current: non_neg_integer() | nil,
            pids_limit: non_neg_integer() | :unlimited | nil
          },
          beam: %{
            memory_total_bytes: non_neg_integer() | nil,
            port_count: non_neg_integer() | nil,
            port_limit: non_neg_integer() | nil
          },
          dispatcher: %{
            active: non_neg_integer() | nil,
            queued: non_neg_integer() | nil,
            capacity: non_neg_integer() | nil
          },
          activity: %{
            agents: non_neg_integer() | nil,
            fleets: non_neg_integer() | nil,
            sessions: non_neg_integer() | nil,
            terminals: non_neg_integer() | nil,
            dag_attempts: non_neg_integer() | nil
          },
          governor: %{
            state: :normal | :pressure | :critical | :unavailable,
            reserved_bytes: non_neg_integer() | nil,
            active_tickets: non_neg_integer() | nil,
            queued_interactive: non_neg_integer() | nil,
            queued_background: non_neg_integer() | nil
          },
          deployment: %{
            profile: String.t(),
            memory_limit_mib: non_neg_integer() | nil,
            memory_reservation_mib: non_neg_integer() | nil,
            pids_limit: non_neg_integer() | nil,
            nofile_limit: non_neg_integer() | nil
          }
        }

  @doc """
  Returns a bounded aggregate snapshot of the local runtime.

  Runtime dependencies are independently protected so a missing cgroup file or
  a restarting OTP process produces an unavailable measurement instead of
  crashing a status command or LiveView. Tests may inject zero-arity
  `:dispatcher_stats`, `:metrics_snapshot`, `:beam_memory`, `:governor_snapshot`, and one-arity
  `:supervisor_count` and `:beam_system_info` functions. `:cgroup_root`,
  `:read_file`, and the bounded `:snapshot_timeout_ms` may also be overridden
  for deterministic fixtures.
  """
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) when is_list(opts) do
    timeout = snapshot_timeout(opts)

    case bounded_measure(fn -> build_snapshot(opts) end, timeout) do
      %{} = snapshot -> snapshot
      _unavailable -> unavailable_snapshot()
    end
  end

  defp build_snapshot(opts) do
    dispatcher = dispatcher_snapshot(opts)
    metrics = metrics_snapshot(opts)
    supervisors = supervisor_snapshot(opts)

    activity = %{
      agents: sum_if_available([metrics.agents, supervisors.legacy_agents]),
      fleets: supervisors.fleets,
      sessions: supervisors.sessions,
      terminals: supervisors.terminals,
      dag_attempts: metrics.dag_attempts
    }

    %{
      state: runtime_state(dispatcher, metrics, supervisors),
      container: container_snapshot(opts),
      beam: beam_snapshot(opts),
      dispatcher: dispatcher,
      activity: activity,
      governor: governor_snapshot(opts),
      deployment: deployment_snapshot()
    }
  end

  defp unavailable_snapshot do
    %{
      state: :unavailable,
      container: %{
        memory_current_bytes: nil,
        memory_peak_bytes: nil,
        memory_limit_bytes: nil,
        oom_events: nil,
        oom_kill_events: nil,
        pids_current: nil,
        pids_limit: nil
      },
      beam: %{memory_total_bytes: nil, port_count: nil, port_limit: nil},
      dispatcher: %{active: nil, queued: nil, capacity: nil},
      activity: %{
        agents: nil,
        fleets: nil,
        sessions: nil,
        terminals: nil,
        dag_attempts: nil
      },
      governor: unavailable_governor(),
      deployment: deployment_snapshot()
    }
  end

  @doc "Returns stable, human-readable lines for the CLI status command."
  @spec format_cli(snapshot()) :: [String.t()]
  def format_cli(snapshot) when is_map(snapshot) do
    state = snapshot |> nested([:state]) |> format_state()
    memory_current = snapshot |> nested([:container, :memory_current_bytes]) |> format_bytes()
    memory_peak = snapshot |> nested([:container, :memory_peak_bytes]) |> format_bytes()
    memory_limit = snapshot |> nested([:container, :memory_limit_bytes]) |> format_bytes()
    oom_events = snapshot |> nested([:container, :oom_events]) |> format_count()
    oom_kills = snapshot |> nested([:container, :oom_kill_events]) |> format_count()
    pids_current = snapshot |> nested([:container, :pids_current]) |> format_count()
    pids_limit = snapshot |> nested([:container, :pids_limit]) |> format_limit_count()
    beam_memory = snapshot |> nested([:beam, :memory_total_bytes]) |> format_bytes()
    port_count = snapshot |> nested([:beam, :port_count]) |> format_count()
    port_limit = snapshot |> nested([:beam, :port_limit]) |> format_count()
    active = snapshot |> nested([:dispatcher, :active]) |> format_count()
    queued = snapshot |> nested([:dispatcher, :queued]) |> format_count()
    capacity = snapshot |> nested([:dispatcher, :capacity]) |> format_count()
    agents = snapshot |> nested([:activity, :agents]) |> format_count()
    fleets = snapshot |> nested([:activity, :fleets]) |> format_count()
    sessions = snapshot |> nested([:activity, :sessions]) |> format_count()
    terminals = snapshot |> nested([:activity, :terminals]) |> format_count()
    attempts = snapshot |> nested([:activity, :dag_attempts]) |> format_count()
    pressure = snapshot |> nested([:governor, :state]) |> format_pressure()
    tickets = snapshot |> nested([:governor, :active_tickets]) |> format_count()
    queued_interactive = snapshot |> nested([:governor, :queued_interactive]) |> format_count()
    queued_background = snapshot |> nested([:governor, :queued_background]) |> format_count()

    [
      "IexCode runtime: #{state}",
      "Container memory: #{memory_current} / #{memory_limit}",
      "Container peak memory: #{memory_peak}",
      "Container OOM events: #{oom_events}, kills: #{oom_kills}",
      "Container PIDs: #{pids_current} / #{pids_limit}",
      "BEAM memory: #{beam_memory}",
      "BEAM ports: #{port_count} / #{port_limit}",
      "Runs: #{active} active, #{queued} queued, #{capacity} capacity",
      "Agents: #{agents} active",
      "Fleets: #{fleets} active",
      "DAG attempts: #{attempts} active",
      "Sessions: #{sessions}",
      "Terminals: #{terminals}",
      "Governor: #{pressure}, #{tickets} active tickets, #{queued_interactive} interactive queued, #{queued_background} background queued"
    ]
  end

  @doc "Prints the current runtime snapshot in CLI form."
  @spec print_cli() :: :ok
  def print_cli do
    snapshot()
    |> format_cli()
    |> Enum.each(&IO.puts/1)
  end

  defp dispatcher_snapshot(opts) do
    result =
      safe_measure(fn ->
        case Keyword.get(opts, :dispatcher_stats) do
          fun when is_function(fun, 0) -> fun.()
          _other -> RunDispatcher.get_stats(Keyword.get(opts, :dispatcher, RunDispatcher))
        end
      end)

    %{
      active: nonnegative_map_value(result, :active),
      queued: nonnegative_map_value(result, :queued),
      capacity: nonnegative_map_value(result, :capacity)
    }
  end

  defp metrics_snapshot(opts) do
    result =
      safe_measure(fn ->
        case Keyword.get(opts, :metrics_snapshot) do
          fun when is_function(fun, 0) -> fun.()
          _other -> MetricsStore.snapshot(Keyword.get(opts, :metrics_store, MetricsStore))
        end
      end)

    control_plane = if is_map(result), do: Map.get(result, :control_plane), else: nil

    agents_active = nonnegative_map_value(control_plane, :agents_active)
    agents_paused = nonnegative_map_value(control_plane, :agents_paused)

    %{
      runs_active: nonnegative_map_value(control_plane, :runs_active),
      runs_queued: nonnegative_map_value(control_plane, :runs_queued),
      agents: sum_if_available([agents_active, agents_paused]),
      agent_counts: [agents_active, agents_paused],
      dag_attempts: nonnegative_map_value(control_plane, :dag_attempts_active)
    }
  end

  defp supervisor_snapshot(opts) do
    counter =
      case Keyword.get(opts, :supervisor_count) do
        fun when is_function(fun, 1) -> fun
        _other -> &DynamicSupervisor.count_children/1
      end

    %{
      legacy_agents: count_active_children(counter, AgentSupervisor),
      fleets: count_active_children(counter, FleetSupervisor),
      sessions: count_active_children(counter, SessionSupervisor),
      terminals: count_active_children(counter, TerminalSupervisor)
    }
  end

  defp count_active_children(counter, supervisor) do
    safe_measure(fn -> counter.(supervisor) end)
    |> nonnegative_map_value(:active)
  end

  defp container_snapshot(opts) do
    root = Keyword.get(opts, :cgroup_root, @default_cgroup_root)

    read_file =
      case Keyword.get(opts, :read_file) do
        fun when is_function(fun, 1) -> fun
        _other -> &File.read/1
      end

    %{
      memory_current_bytes: read_cgroup_number(root, "memory.current", read_file, false),
      memory_peak_bytes: read_cgroup_number(root, "memory.peak", read_file, false),
      memory_limit_bytes: read_cgroup_number(root, "memory.max", read_file, true),
      oom_events: read_cgroup_event(root, "oom", read_file),
      oom_kill_events: read_cgroup_event(root, "oom_kill", read_file),
      pids_current: read_cgroup_number(root, "pids.current", read_file, false),
      pids_limit: read_cgroup_number(root, "pids.max", read_file, true)
    }
  end

  defp read_cgroup_event(root, key, read_file) do
    result = safe_measure(fn -> read_file.(Path.join(root, "memory.events")) end)

    with {:ok, contents} when is_binary(contents) <- result,
         line when is_binary(line) <-
           Enum.find(String.split(contents, "\n"), &String.starts_with?(&1, key <> " ")),
         [_, value] <- String.split(line, ~r/\s+/, parts: 2),
         {number, ""} when number >= 0 <- Integer.parse(value) do
      number
    else
      _ -> nil
    end
  end

  defp governor_snapshot(opts) do
    result =
      safe_measure(fn ->
        case Keyword.get(opts, :governor_snapshot) do
          fun when is_function(fun, 0) -> fun.()
          _ -> ResourceGovernor.snapshot(Keyword.get(opts, :resource_governor, ResourceGovernor))
        end
      end)

    if is_map(result) do
      %{
        state: Map.get(result, :state, :unavailable),
        reserved_bytes: normalize_nonnegative(Map.get(result, :reserved_bytes)),
        active_tickets:
          result |> Map.get(:active_by_class, %{}) |> Map.values() |> sum_if_available(),
        queued_interactive: normalize_nonnegative(Map.get(result, :queued_interactive)),
        queued_background: normalize_nonnegative(Map.get(result, :queued_background))
      }
    else
      unavailable_governor()
    end
  end

  defp unavailable_governor do
    %{
      state: :unavailable,
      reserved_bytes: nil,
      active_tickets: nil,
      queued_interactive: nil,
      queued_background: nil
    }
  end

  defp deployment_snapshot do
    %{
      profile: resource_profile(),
      memory_limit_mib: env_integer("IEX_CODE_MEMORY_LIMIT_MIB"),
      memory_reservation_mib: env_integer("IEX_CODE_MEMORY_RESERVATION_MIB"),
      pids_limit: env_integer("IEX_CODE_PIDS_LIMIT"),
      nofile_limit: env_integer("IEX_CODE_NOFILE_LIMIT")
    }
  end

  defp resource_profile do
    case System.get_env("IEX_CODE_RESOURCE_PROFILE") do
      value when value in ["compact", "balanced", "throughput", "custom"] -> value
      _ -> "balanced"
    end
  end

  defp env_integer(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_cgroup_number(root, filename, read_file, allow_unlimited?)
       when is_binary(root) and is_binary(filename) do
    result = safe_measure(fn -> read_file.(Path.join(root, filename)) end)

    case result do
      {:ok, contents} when is_binary(contents) ->
        contents
        |> String.trim()
        |> parse_cgroup_number(allow_unlimited?)

      _other ->
        nil
    end
  end

  defp read_cgroup_number(_root, _filename, _read_file, _allow_unlimited?), do: nil

  defp parse_cgroup_number("max", true), do: :unlimited

  defp parse_cgroup_number(value, _allow_unlimited?) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _other -> nil
    end
  end

  defp beam_snapshot(opts) do
    memory =
      safe_measure(fn ->
        case Keyword.get(opts, :beam_memory) do
          fun when is_function(fun, 0) -> fun.()
          _other -> :erlang.memory(:total)
        end
      end)
      |> normalize_nonnegative()

    system_info =
      case Keyword.get(opts, :beam_system_info) do
        fun when is_function(fun, 1) -> fun
        _other -> &:erlang.system_info/1
      end

    %{
      memory_total_bytes: memory,
      port_count: system_info_value(system_info, :port_count),
      port_limit: system_info_value(system_info, :port_limit)
    }
  end

  defp system_info_value(fun, key) do
    safe_measure(fn -> fun.(key) end)
    |> normalize_nonnegative()
  end

  defp runtime_state(dispatcher, metrics, supervisors) do
    work_counts = [
      dispatcher.active,
      dispatcher.queued,
      metrics.runs_active,
      metrics.runs_queued,
      supervisors.legacy_agents,
      supervisors.fleets,
      metrics.dag_attempts
      | metrics.agent_counts
    ]

    cond do
      Enum.any?(work_counts, &(is_integer(&1) and &1 > 0)) -> :active
      Enum.any?(work_counts, &is_nil/1) -> :unavailable
      true -> :idle
    end
  end

  defp sum_if_available(values) do
    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)) do
      Enum.sum(values)
    end
  end

  defp nonnegative_map_value(map, key) when is_map(map) do
    map
    |> Map.get(key)
    |> normalize_nonnegative()
  end

  defp nonnegative_map_value(_map, _key), do: nil

  defp normalize_nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp normalize_nonnegative(_value), do: nil

  defp safe_measure(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp bounded_measure(fun, timeout) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(caller, {token, safe_measure(fun)})
      end)

    receive do
      {^token, value} ->
        Process.demonitor(monitor, [:flush])
        value

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        nil
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^token, _late_value} -> :ok
        after
          0 -> :ok
        end

        nil
    end
  end

  defp snapshot_timeout(opts) do
    case Keyword.get(opts, :snapshot_timeout_ms, @default_snapshot_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @max_snapshot_timeout_ms)
      _invalid -> @default_snapshot_timeout_ms
    end
  end

  defp nested(value, []), do: value

  defp nested(map, [key | rest]) when is_map(map) do
    nested(Map.get(map, key), rest)
  end

  defp nested(_value, _path), do: nil

  defp format_state(state) when state in [:idle, :active, :unavailable], do: Atom.to_string(state)
  defp format_state(_state), do: "unavailable"

  defp format_pressure(state) when state in [:normal, :pressure, :critical, :unavailable],
    do: Atom.to_string(state)

  defp format_pressure(_state), do: "unavailable"

  defp format_count(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp format_count(_value), do: "unavailable"

  defp format_limit_count(:unlimited), do: "unlimited"
  defp format_limit_count(value), do: format_count(value)

  defp format_bytes(:unlimited), do: "unlimited"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> format_unit(bytes, 1_073_741_824, "GiB")
      bytes >= 1_048_576 -> format_unit(bytes, 1_048_576, "MiB")
      bytes >= 1_024 -> format_unit(bytes, 1_024, "KiB")
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_value), do: "unavailable"

  defp format_unit(bytes, divisor, unit) do
    :erlang.float_to_binary(bytes / divisor, decimals: 1) <> " " <> unit
  end
end
