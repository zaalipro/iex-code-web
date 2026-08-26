defmodule IexCodeWeb.Telemetry do
  @moduledoc """
  Stable, low-cardinality telemetry definitions for the web and execution planes.

  Identifiers, prompts, commands and output deliberately remain outside metric tags.
  Run, fleet, DAG, control and workspace-lock health are sampled as aggregate gauges,
  which keeps the metric series bounded as durable history grows.
  """

  use Supervisor

  import Telemetry.Metrics

  alias IexCode.Observability.ControlPlaneSnapshot

  @control_plane_event [:iex_code, :control_plane, :snapshot]
  @control_plane_error_event [:iex_code, :control_plane, :snapshot_error]
  @snapshot_measurements [
    :runs_queued,
    :runs_active,
    :runs_attention,
    :runs_expired_leases,
    :agents_active,
    :agents_paused,
    :agents_attention,
    :agents_expired_leases,
    :dag_attempts_active,
    :dag_attempts_expired_leases,
    :run_controls_open,
    :agent_controls_open,
    :approvals_pending,
    :approvals_overdue,
    :workspace_locks_held,
    :workspace_locks_waiting,
    :workspace_locks_expired
  ]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      case poller_child_spec() do
        nil -> []
        child_spec -> [child_spec]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def poller_child_spec(opts \\ Application.get_env(:iex_code, :control_plane_telemetry, []))

  def poller_child_spec(opts) when is_list(opts) do
    if Keyword.get(opts, :enabled, true) do
      period = positive_integer(Keyword.get(opts, :period), 30_000)
      init_delay = nonnegative_integer(Keyword.get(opts, :init_delay), period)

      {:telemetry_poller,
       measurements: periodic_measurements(), period: period, init_delay: init_delay}
    end
  end

  def poller_child_spec(_invalid_config), do: nil

  def metrics do
    web_metrics() ++
      database_metrics() ++
      vm_metrics() ++
      operation_metrics() ++
      fleet_metrics() ++
      terminal_metrics() ++
      control_plane_metrics()
  end

  @doc false
  def measure_control_plane do
    :telemetry.execute(@control_plane_event, ControlPlaneSnapshot.build(), %{})
  rescue
    _error -> emit_control_plane_error()
  catch
    _kind, _reason -> emit_control_plane_error()
  end

  defp web_metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      # Client-supplied channel event names are not a bounded metric dimension.
      summary("phoenix.channel_handled_in.duration", unit: {:native, :millisecond})
    ]
  end

  defp database_metrics do
    [
      summary("iex_code.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("iex_code.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("iex_code.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("iex_code.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("iex_code.repo.query.idle_time",
        unit: {:native, :millisecond},
        description: "The time the connection waited before being checked out"
      )
    ]
  end

  defp vm_metrics do
    [
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp operation_metrics do
    operation_tags = [:operation_class]
    tag_values = &operation_tag_values/1

    [
      counter("iex_code.operation.started.total",
        event_name: [:iex_code, :operation, :start],
        measurement: fn _measurements -> 1 end,
        tags: operation_tags,
        tag_values: tag_values,
        description: "Operations started"
      ),
      last_value("iex_code.operation.progress.percent",
        event_name: [:iex_code, :operation, :progress],
        measurement: :progress,
        tags: operation_tags,
        tag_values: tag_values,
        description: "Most recently reported bounded operation progress"
      ),
      counter("iex_code.operation.completed.total",
        event_name: [:iex_code, :operation, :stop],
        measurement: fn _measurements -> 1 end,
        tags: operation_tags,
        tag_values: tag_values,
        description: "Operations completed successfully"
      ),
      summary("iex_code.operation.completed.duration",
        event_name: [:iex_code, :operation, :stop],
        measurement: :duration_ms,
        tags: operation_tags,
        tag_values: tag_values,
        unit: :millisecond,
        description: "Successful operation duration"
      ),
      counter("iex_code.operation.failed.total",
        event_name: [:iex_code, :operation, :crash],
        measurement: fn _measurements -> 1 end,
        tags: operation_tags,
        tag_values: tag_values,
        description: "Operations that returned an error or crashed"
      ),
      summary("iex_code.operation.failed.duration",
        event_name: [:iex_code, :operation, :crash],
        measurement: :duration_ms,
        tags: operation_tags,
        tag_values: tag_values,
        unit: :millisecond,
        description: "Failed operation duration"
      )
    ]
  end

  defp fleet_metrics do
    [
      counter("iex_code.fleet.rehydrate_error.total",
        event_name: [:iex_code, :fleet, :rehydrate_error],
        measurement: fn _measurements -> 1 end,
        description: "Durable fleet agents that failed a rehydration attempt"
      )
    ]
  end

  defp terminal_metrics do
    [
      counter("iex_code.terminal.session_started.total",
        event_name: [:iex_code, :terminal, :session_started],
        measurement: fn _measurements -> 1 end,
        tags: [:shell_family],
        tag_values: &terminal_start_tag_values/1,
        description: "Terminal PTY sessions started"
      ),
      counter("iex_code.terminal.command_dispatched.total",
        event_name: [:iex_code, :terminal, :command_dispatched],
        measurement: fn _measurements -> 1 end,
        tags: [:agent_class],
        tag_values: &terminal_command_tag_values/1,
        description: "Terminal commands dispatched"
      ),
      summary("iex_code.terminal.output_chunk.size",
        event_name: [:iex_code, :terminal, :output_chunk],
        measurement: :byte_size,
        unit: :byte,
        description: "Size of terminal output chunks streamed"
      ),
      sum("iex_code.terminal.output_chunk.bytes",
        event_name: [:iex_code, :terminal, :output_chunk],
        measurement: :byte_size,
        unit: :byte,
        description: "Total terminal output bytes streamed"
      ),
      counter("iex_code.terminal.command_completed.total",
        event_name: [:iex_code, :terminal, :command_completed],
        measurement: fn _measurements -> 1 end,
        tags: [:status, :agent_class],
        tag_values: &terminal_completion_tag_values/1,
        description: "Terminal commands completed"
      ),
      summary("iex_code.terminal.command_completed.duration",
        event_name: [:iex_code, :terminal, :command_completed],
        measurement: :duration_ms,
        tags: [:status, :agent_class],
        tag_values: &terminal_completion_tag_values/1,
        unit: :millisecond,
        description: "Terminal command duration"
      ),
      summary("iex_code.terminal.command_completed.exit_code",
        event_name: [:iex_code, :terminal, :command_completed],
        measurement: :exit_code,
        tags: [:status],
        tag_values: &terminal_completion_tag_values/1,
        description: "Terminal command exit code"
      ),
      counter("iex_code.terminal.session_stopped.total",
        event_name: [:iex_code, :terminal, :session_stopped],
        measurement: fn _measurements -> 1 end,
        tags: [:reason_class],
        tag_values: &terminal_stop_tag_values/1,
        description: "Terminal PTY sessions stopped"
      ),
      summary("iex_code.terminal.session_stopped.duration",
        event_name: [:iex_code, :terminal, :session_stopped],
        measurement: :duration_ms,
        tags: [:reason_class],
        tag_values: &terminal_stop_tag_values/1,
        unit: :millisecond,
        description: "Terminal session lifecycle duration"
      )
    ]
  end

  defp control_plane_metrics do
    snapshot_metrics =
      Enum.map(@snapshot_measurements, fn measurement ->
        last_value([:iex_code, :control_plane, :snapshot, measurement],
          event_name: @control_plane_event,
          measurement: measurement,
          description: snapshot_description(measurement)
        )
      end)

    snapshot_metrics ++
      [
        counter("iex_code.control_plane.snapshot_error.total",
          event_name: @control_plane_error_event,
          measurement: fn _measurements -> 1 end,
          description: "Control-plane aggregate collection failures"
        )
      ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_control_plane, []}
    ]
  end

  defp emit_control_plane_error do
    :telemetry.execute(@control_plane_error_event, %{count: 1}, %{})
    :ok
  rescue
    _error -> :ok
  end

  defp operation_tag_values(metadata) do
    %{operation_class: operation_class(metadata[:op_type])}
  end

  defp operation_class(value) do
    value = value |> safe_string() |> String.downcase()

    cond do
      value in ~w(llm llm_stream chat completion) ->
        "llm"

      value in ~w(run_command terminal shell) ->
        "terminal"

      value in ~w(read_file write_file patch_file multi_patch list_dir grep_search) ->
        "filesystem"

      String.starts_with?(value, "git_") ->
        "git"

      value in ~w(run_tests test autofix auto_fix) ->
        "test"

      value in ~w(web_search grounded_search deep_research research) ->
        "search"

      value in ~w(subagent_plan agent swarm planner explorer coder verifier) ->
        "agent"

      true ->
        "other"
    end
  end

  defp terminal_start_tag_values(metadata) do
    %{shell_family: shell_family(metadata[:shell])}
  end

  defp terminal_command_tag_values(metadata) do
    %{agent_class: agent_class(metadata[:agent_name])}
  end

  defp terminal_completion_tag_values(metadata) do
    %{
      status: completion_status(metadata[:status]),
      agent_class: agent_class(metadata[:agent_name])
    }
  end

  defp terminal_stop_tag_values(metadata) do
    %{reason_class: reason_class(metadata[:reason])}
  end

  defp shell_family(shell) do
    case shell |> safe_string() |> Path.basename() |> String.downcase() do
      shell when shell in ~w(zsh bash sh fish pwsh powershell cmd) -> shell
      _shell -> "other"
    end
  end

  defp agent_class(value) do
    value = value |> safe_string() |> String.downcase()

    cond do
      String.contains?(value, "planner") -> "planner"
      String.contains?(value, "explorer") -> "explorer"
      String.contains?(value, "coder") -> "coder"
      String.contains?(value, "verifier") -> "verifier"
      String.contains?(value, "assistant") -> "assistant"
      value == "" -> "interactive"
      true -> "other"
    end
  end

  defp completion_status(status) when status in [:ok, "ok", :success, "success"], do: "ok"

  defp completion_status(status)
       when status in [:error, "error", :failed, "failed", :timeout, "timeout"],
       do: "error"

  defp completion_status(_status), do: "other"

  defp reason_class(reason) when reason in [:normal, "normal"], do: "normal"

  defp reason_class(reason) when reason in [:shutdown, :killed, "shutdown", "killed"],
    do: "shutdown"

  defp reason_class({:shutdown, _reason}), do: "shutdown"

  defp reason_class({kind, _reason}) when kind in [:error, :exit, :throw],
    do: Atom.to_string(kind)

  defp reason_class(reason) when is_exception(reason), do: "exception"
  defp reason_class(nil), do: "unknown"
  defp reason_class(_reason), do: "other"

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(_value), do: ""

  defp snapshot_description(measurement) do
    measurement
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default
end
