defmodule IexCode.Engine.RunFleetSupervisor do
  @moduledoc false
  use Supervisor

  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, FleetManager}

  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    Supervisor.start_link(__MODULE__, opts, name: AgentRegistry.via_fleet(run.id, :supervisor))
  end

  @doc "Durably applies one fenced control to one agent belonging to the selected run."
  def control_agent(run_or_id, agent_id, kind, payload \\ %{}) do
    run_id = if is_binary(run_or_id), do: run_or_id, else: run_or_id.id

    with %IexCode.Runs.RunAgent{} = agent <- IexCode.Runs.get_run_agent(run_id, agent_id),
         true <- kind in [:pause, :resume, :cancel, :steer, :restart],
         key <- control_key(kind, payload),
         {:ok, control} <-
           IexCode.Runs.enqueue_run_agent_control(agent, key, %{
             kind: to_string(kind),
             payload: Map.drop(payload, [:idempotency_key, "idempotency_key"]),
             target_generation: agent.lease_generation,
             requested_by: "local-user"
           }),
         {:ok, effect} <- FleetManager.apply_durable_control(run_id, control.id) do
      {:ok, effect}
    else
      nil ->
        {:error, :agent_not_found}

      false ->
        {:error, :invalid_agent_control}

      {:error, reason} = error ->
        _ = reason
        error
    end
  end

  defp control_key(kind, payload) do
    case Map.get(payload, :idempotency_key) || Map.get(payload, "idempotency_key") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        digest =
          :crypto.hash(:sha256, :erlang.term_to_binary({kind, payload, System.unique_integer()}))

        "fleet:" <> Base.url_encode64(digest, padding: false)
    end
  end

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)

    fleet_opts =
      Keyword.put_new_lazy(opts, :fleet_lease_secret, fn ->
        Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      end)

    children = [
      {Task.Supervisor, name: AgentRegistry.via_fleet(run.id, :task_supervisor)},
      {AgentSupervisor, name: AgentRegistry.via_fleet(run.id, :agent_supervisor)},
      {FleetManager, fleet_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
