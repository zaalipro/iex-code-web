defmodule IexCode.Engine.FleetSupervisor do
  @moduledoc "Dynamic supervisor owning one isolated supervision tree per durable run."
  use DynamicSupervisor

  alias IexCode.Engine.{AgentRegistry, FleetManager, FleetTopology, RunFleetSupervisor}
  alias IexCode.Execution.Limits

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_started(run, opts \\ []) do
    persisted = IexCode.Runs.get_run(run.id)

    with %IexCode.Runs.Run{} = persisted <- persisted,
         true <-
           persisted.session_id == run.session_id and persisted.project_id == run.project_id,
         :ok <- validate_execution_engine(persisted),
         :ok <- validate_run_lineage(persisted, run) do
      do_ensure_started(persisted, opts)
    else
      nil -> {:error, :run_not_found}
      false -> {:error, :run_scope_mismatch}
      {:error, {:execution_engine_unavailable, _engine}} = error -> error
    end
  end

  defp do_ensure_started(run, opts) do
    case AgentRegistry.whereis_fleet(run.id, :supervisor) do
      nil ->
        case DynamicSupervisor.start_child(__MODULE__, {RunFleetSupervisor, [run: run] ++ opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        if FleetManager.matches_parent_lineage?(run.id, run) do
          {:ok, pid}
        else
          with :ok <- DynamicSupervisor.terminate_child(__MODULE__, pid) do
            do_ensure_started(run, opts)
          end
        end
    end
  end

  def stop(run_id) when is_binary(run_id) do
    case AgentRegistry.whereis_fleet(run_id, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  def attach(run, opts \\ []) do
    persisted = IexCode.Runs.get_run(run.id)

    with %IexCode.Runs.Run{} = persisted <- persisted,
         true <-
           persisted.session_id == run.session_id and persisted.project_id == run.project_id,
         :ok <- validate_execution_engine(persisted),
         :ok <- validate_run_lineage(persisted, run),
         :ok <- validate_delegation(persisted, opts[:workspace_lock_delegation]),
         %IexCode.Sessions.Session{} = stored_session <-
           IexCode.Sessions.get_session(persisted.session_id),
         project <- IexCode.Projects.get_project!(persisted.project_id),
         {:ok, count} <- effective_agent_count(persisted, opts),
         {:ok, session} <- effective_session(persisted, stored_session) do
      manifest = FleetTopology.manifest(count)

      trusted_opts =
        opts
        |> Keyword.put(:session, session)
        |> Keyword.put(:project_root, project.root_path)

      with {:ok, _pid} <- ensure_started(persisted, trusted_opts),
           {:ok, rows} <- IexCode.Runs.ensure_run_agents(persisted, manifest, max_agents: 32),
           {:ok, agents} <- FleetManager.activate(persisted.id, rows, trusted_opts) do
        {:ok, agents}
      end
    else
      nil -> {:error, :run_not_found}
      false -> {:error, :run_scope_mismatch}
      {:error, {:execution_engine_unavailable, _engine}} = error -> error
      _ -> {:error, :run_scope_mismatch}
    end
  end

  defp validate_execution_engine(%IexCode.Runs.Run{execution_engine: "legacy_v1"}), do: :ok

  defp validate_execution_engine(%IexCode.Runs.Run{execution_engine: engine}),
    do: {:error, {:execution_engine_unavailable, engine}}

  defp validate_run_lineage(persisted, requested) do
    live_lease? =
      is_binary(persisted.lease_owner) and persisted.lease_owner != "" and
        is_struct(persisted.lease_expires_at, DateTime) and
        DateTime.compare(persisted.lease_expires_at, DateTime.utc_now()) == :gt

    if persisted.status in ["running", "paused"] and live_lease? and
         persisted.attempt == requested.attempt and
         persisted.lease_generation == requested.lease_generation and
         persisted.lease_owner == requested.lease_owner do
      :ok
    else
      {:error, :parent_lease_lost}
    end
  end

  defp validate_delegation(_run, nil), do: :ok

  defp validate_delegation(run, %IexCode.WorkspaceLocks{} = delegation) do
    if delegation.run_id == run.id and delegation.session_id == run.session_id and
         delegation.project_id == run.project_id do
      IexCode.WorkspaceLocks.assert(delegation)
    else
      {:error, :workspace_delegation_scope_mismatch}
    end
  end

  defp validate_delegation(_run, _delegation), do: {:error, :invalid_workspace_delegation}

  defp effective_agent_count(run, opts) do
    case snapshotted_agent_count(run.metadata) do
      {:ok, count} ->
        {:ok, count}

      :missing ->
        legacy_count =
          Keyword.get_lazy(opts, :agent_count, fn ->
            IexCode.Settings.get_settings().swarm_agent_count
          end)

        {:ok, normalize_legacy_count(legacy_count)}

      {:error, _reason} = error ->
        error
    end
  end

  defp snapshotted_agent_count(metadata) when is_map(metadata) do
    policy = Map.get(metadata, "execution_policy") || Map.get(metadata, :execution_policy)

    case policy do
      nil ->
        :missing

      policy when is_map(policy) ->
        case Map.get(policy, "swarm_agent_count") || Map.get(policy, :swarm_agent_count) do
          nil -> :missing
          count when is_integer(count) and count in 4..32 -> {:ok, count}
          _invalid -> {:error, :invalid_snapshotted_swarm_agent_count}
        end

      _invalid ->
        {:error, :invalid_execution_policy}
    end
  end

  defp snapshotted_agent_count(_metadata), do: :missing

  defp normalize_legacy_count(value) when is_integer(value), do: value |> max(4) |> min(32)
  defp normalize_legacy_count(_value), do: 4

  defp effective_session(run, session) do
    policy =
      case run.metadata do
        metadata when is_map(metadata) ->
          Map.get(metadata, "execution_policy") || Map.get(metadata, :execution_policy) || %{}

        _metadata ->
          %{}
      end

    provider =
      Map.get(policy, "model_provider") || Map.get(policy, :model_provider) ||
        session.model_provider

    model = Map.get(policy, "model_name") || Map.get(policy, :model_name) || session.model_name

    temperature =
      Map.get(policy, "temperature") || Map.get(policy, :temperature) || session.temperature

    temperature = if is_number(temperature), do: temperature * 1.0, else: temperature

    cond do
      provider not in ["openai", "anthropic"] ->
        {:error, :invalid_snapshotted_model_provider}

      not Limits.valid_model_name?(model) ->
        {:error, :invalid_snapshotted_model}

      not is_float(temperature) or temperature < 0.0 or temperature > 2.0 ->
        {:error, :invalid_snapshotted_temperature}

      true ->
        {:ok, %{session | model_provider: provider, model_name: model, temperature: temperature}}
    end
  end
end
