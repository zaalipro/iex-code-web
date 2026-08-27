defmodule IexCode.Observability.RuntimeStatus do
  @moduledoc """
  Failure-tolerant, aggregate runtime status for local operational surfaces.

  The snapshot deliberately contains counts only. It never exposes run, agent,
  session, project, worker, or lease identifiers.
  """

  alias IexCode.Engine.{AgentSupervisor, FleetSupervisor, SessionSupervisor}
  alias IexCode.Observability.MetricsStore
  alias IexCode.Runs.RunDispatcher
  alias IexCode.Tools.TerminalSupervisor

  @default_cgroup_root "/sys/fs/cgroup"
  @default_snapshot_timeout_ms 1_000
  @max_snapshot_timeout_ms 5_000

  @typedoc "A non-secret, aggregate view of the local application runtime."
  @type snapshot :: %{
          state: :idle | :active | :unavailable,
          container: %{
            memory_current_bytes: non_neg_integer() | nil,
            memory_limit_bytes: non_neg_integer() | :unlimited | nil
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
          }
        }

  @doc """
  Returns a bounded aggregate snapshot of the local runtime.

  Runtime dependencies are independently protected so a missing cgroup file or
  a restarting OTP process produces an unavailable measurement instead of
  crashing a status command or LiveView. Tests may inject zero-arity
  `:dispatcher_stats`, `:metrics_snapshot`, `:beam_memory`, and one-arity
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
      activity: activity
    }
  end

  defp unavailable_snapshot do
    %{
      state: :unavailable,
      container: %{memory_current_bytes: nil, memory_limit_bytes: nil},
      beam: %{memory_total_bytes: nil, port_count: nil, port_limit: nil},
      dispatcher: %{active: nil, queued: nil, capacity: nil},
      activity: %{
        agents: nil,
        fleets: nil,
        sessions: nil,
        terminals: nil,
        dag_attempts: nil
      }
    }
  end

  @doc "Returns stable, human-readable lines for the CLI status command."
  @spec format_cli(snapshot()) :: [String.t()]
  def format_cli(snapshot) when is_map(snapshot) do
    state = snapshot |> nested([:state]) |> format_state()
    memory_current = snapshot |> nested([:container, :memory_current_bytes]) |> format_bytes()
    memory_limit = snapshot |> nested([:container, :memory_limit_bytes]) |> format_bytes()
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

    [
      "IexCode runtime: #{state}",
      "Container memory: #{memory_current} / #{memory_limit}",
      "BEAM memory: #{beam_memory}",
      "BEAM ports: #{port_count} / #{port_limit}",
      "Runs: #{active} active, #{queued} queued, #{capacity} capacity",
      "Agents: #{agents} active",
      "Fleets: #{fleets} active",
      "DAG attempts: #{attempts} active",
      "Sessions: #{sessions}",
      "Terminals: #{terminals}"
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
      memory_limit_bytes: read_cgroup_number(root, "memory.max", read_file, true)
    }
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

  defp format_count(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp format_count(_value), do: "unavailable"

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
