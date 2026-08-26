defmodule IexCode.Runs.Executor do
  @moduledoc """
  Typed production executor for durable coding runs.

  The dispatcher persists and claims a run before this module is invoked.  No
  executable closures are stored in the database: the persisted `kind` and
  `mode` select a known implementation here.
  """

  @callback execute(IexCode.Runs.Run.t(), (non_neg_integer(), String.t() -> any())) ::
              {:ok, term()} | {:error, term()}

  alias IexCode.Engine.{AgentLoop, SwarmCoordinator}
  alias IexCode.Projects
  alias IexCode.Research.Runner, as: ResearchRunner
  alias IexCode.Runs.Run
  alias IexCode.Settings

  @doc false
  def execute(run, progress, opts \\ [])

  def execute(%Run{} = run, progress, opts) when is_function(progress, 2) and is_list(opts) do
    with :ok <- supported_run?(run),
         project <- Projects.get_project!(run.project_id) do
      progress.(5, "Preparing durable #{run_label(run)} run")

      result = execute_typed(run, project.root_path, progress, opts)

      progress.(100, "#{String.capitalize(run_label(run))} run finished")
      result
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp supported_run?(%Run{execution_engine: engine}) when engine != "legacy_v1",
    do: {:error, {:execution_engine_unavailable, engine}}

  defp supported_run?(%Run{kind: "coding_swarm", mode: mode})
       when mode in ["swarm", "workflow"],
       do: :ok

  defp supported_run?(%Run{kind: "coding_agent", mode: "single"}), do: :ok

  defp supported_run?(%Run{kind: "analysis"}), do: :ok

  defp supported_run?(%Run{kind: "deep_research", mode: mode})
       when mode in ["research", "workflow", "single"],
       do: :ok

  defp supported_run?(%Run{kind: kind, mode: mode}),
    do: {:error, {:unsupported_run, kind, mode}}

  defp execute_typed(%Run{kind: "coding_swarm"} = run, project_root, _progress, opts) do
    policy = execution_policy(run.metadata)

    allowed_tools =
      policy_value(policy, "allowed_tools") || metadata_value(run.metadata, "allowed_tools") ||
        :all

    max_retries = bounded_swarm_retries(policy_value(policy, "swarm_max_retries"))

    run.session_id
    |> SwarmCoordinator.run(run.objective,
      project_root: project_root,
      run_id: run.id,
      allowed_tools: allowed_tools,
      workspace_lock_delegation: opts[:workspace_lock_delegation],
      run_lease_owner: opts[:run_lease_owner],
      run_attempt: opts[:run_attempt],
      run_lease_generation: opts[:run_lease_generation],
      run_lease_ms: opts[:run_lease_ms],
      execution_policy: policy,
      max_retries: max_retries
    )
    |> normalize_swarm_result()
  end

  defp execute_typed(%Run{kind: "coding_agent"} = run, project_root, progress, opts) do
    AgentLoop.execute(run, project_root, progress, opts)
  end

  defp execute_typed(%Run{kind: "analysis"}, project_root, _progress, _opts) do
    with {:ok, entries} <- File.ls(project_root) do
      {:ok, %{project_root: project_root, entries: Enum.sort(entries)}}
    end
  end

  defp execute_typed(%Run{kind: "deep_research"} = run, _project_root, progress, opts) do
    search = Settings.search_config()
    research = research_metadata(run.metadata)

    ResearchRunner.execute(run, progress,
      provider_config: search.providers,
      max_concurrency: search.parallelism,
      providers: Map.get(research, "providers", search.order),
      depth: Map.get(research, "depth", search.depth),
      max_sources: Map.get(research, "max_sources", search.max_sources),
      fetch_sources: true,
      cancelled?: fn -> cancelled?(run.id) end,
      run_authority:
        Keyword.take(opts, [
          :run_lease_owner,
          :run_attempt,
          :run_lease_generation,
          :run_lease_ms,
          :run_terminal_lease_ms
        ])
    )
  end

  defp research_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, "research") || Map.get(metadata, :research) do
      research when is_map(research) ->
        Map.new(research, fn {key, value} -> {to_string(key), value} end)

      _ ->
        %{}
    end
  end

  defp research_metadata(_metadata), do: %{}

  defp execution_policy(metadata) when is_map(metadata) do
    case metadata_value(metadata, "execution_policy") do
      policy when is_map(policy) ->
        Map.new(policy, fn {key, value} -> {to_string(key), value} end)

      _missing ->
        # Rows created before execution-policy snapshots intentionally retain
        # the legacy live-session route. Passing `%{}` would look snapshotted to
        # Planner/Coder and fail ModelRoute validation before their model call.
        nil
    end
  end

  defp execution_policy(_metadata), do: nil

  defp metadata_value(map, "execution_policy") when is_map(map),
    do: Map.get(map, "execution_policy") || Map.get(map, :execution_policy)

  defp metadata_value(map, "allowed_tools") when is_map(map),
    do: Map.get(map, "allowed_tools") || Map.get(map, :allowed_tools)

  defp metadata_value(_map, _key), do: nil

  defp policy_value(policy, key) when is_map(policy), do: Map.get(policy, key)
  defp policy_value(_policy, _key), do: nil

  defp bounded_swarm_retries(value) when is_integer(value), do: value |> max(0) |> min(10)
  defp bounded_swarm_retries(_value), do: 3

  defp cancelled?(run_id) do
    case IexCode.Runs.get_run(run_id) do
      %Run{status: status} when status in ["cancelled", "interrupted", "failed"] -> true
      %Run{cancellation_requested_at: %DateTime{}} -> true
      _ -> false
    end
  end

  defp run_label(%Run{kind: "deep_research"}), do: "research"
  defp run_label(_run), do: "coding"

  @doc false
  def normalize_swarm_result({:ok, %{cancelled: true}}), do: {:error, :cancelled}

  def normalize_swarm_result({:ok, %{metadata: metadata} = message}) when is_map(metadata) do
    case Map.get(metadata, :status) || Map.get(metadata, "status") do
      status when status in [:failed, "failed"] -> {:error, {:swarm_failed, message}}
      status when status in [:cancelled, :stopped, "cancelled", "stopped"] -> {:error, :cancelled}
      _status -> {:ok, message}
    end
  end

  def normalize_swarm_result(result), do: result
end
