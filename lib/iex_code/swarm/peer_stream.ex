defmodule IexCode.Swarm.PeerStream do
  @moduledoc """
  Live Peer Message Stream and Dynamic Swarm Telemetry Hub.
  Facilitates real-time inter-agent messaging over Phoenix.PubSub,
  chronological message history accumulation, and filtering by role/agent.
  """

  use GenServer
  require Logger

  @pubsub IexCode.PubSub
  @table :iex_code_swarm_peer_stream_history
  @telemetry_topic "swarm:telemetry"

  # ============================================================================
  # CLIENT API
  # ============================================================================

  @doc """
  Starts the PeerStream history server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the caller process to the swarm's peer message topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(swarm_id) when is_binary(swarm_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(swarm_id))
  end

  def subscribe(swarm_id), do: subscribe(to_string(swarm_id))

  @doc """
  Subscribes the caller process to the global swarm telemetry topic.
  """
  @spec subscribe_telemetry() :: :ok | {:error, term()}
  def subscribe_telemetry do
    Phoenix.PubSub.subscribe(@pubsub, @telemetry_topic)
  end

  @doc """
  Unsubscribes the caller process from the swarm's peer message topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(swarm_id) when is_binary(swarm_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(swarm_id))
  end

  def unsubscribe(swarm_id), do: unsubscribe(to_string(swarm_id))

  @doc """
  Unsubscribes the caller process from the global swarm telemetry topic.
  """
  @spec unsubscribe_telemetry() :: :ok
  def unsubscribe_telemetry do
    Phoenix.PubSub.unsubscribe(@pubsub, @telemetry_topic)
  end

  @doc """
  Topic name helper.
  """
  @spec topic(String.t()) :: String.t()
  def topic(swarm_id), do: "swarm:#{swarm_id}"

  @doc """
  Broadcasts a structured peer message across Phoenix.PubSub and records it to history.
  """
  @spec broadcast_peer_message(
          String.t(),
          String.t(),
          String.t(),
          atom() | String.t(),
          atom() | String.t(),
          map()
        ) :: {:ok, map()}
  def broadcast_peer_message(swarm_id, from_agent, to_agent, role, type, payload) do
    msg = %{
      id: generate_uuid(),
      swarm_id: to_string(swarm_id),
      from_agent: to_string(from_agent),
      to_agent: to_string(to_agent),
      role: normalize_atom(role),
      type: normalize_atom(type),
      payload: payload || %{},
      timestamp: DateTime.utc_now()
    }

    # Record message to history table
    record_message(msg)

    # Broadcast to swarm-specific channel
    Phoenix.PubSub.broadcast(@pubsub, topic(swarm_id), {:swarm_peer_message, msg})

    # Broadcast to global telemetry channel
    Phoenix.PubSub.broadcast(@pubsub, @telemetry_topic, {:swarm_peer_message, msg})

    {:ok, msg}
  end

  @doc """
  Broadcasts real-time swarm telemetry data.
  """
  @spec broadcast_telemetry(String.t(), map()) :: {:ok, map()}
  def broadcast_telemetry(swarm_id, telemetry_data) when is_map(telemetry_data) do
    s_id = to_string(swarm_id)

    payload = %{
      swarm_id: s_id,
      active_roles:
        Map.get(telemetry_data, :active_roles) || Map.get(telemetry_data, "active_roles") || [],
      consensus_score:
        Map.get(telemetry_data, :consensus_score) || Map.get(telemetry_data, "consensus_score") ||
          0.0,
      concordance:
        Map.get(telemetry_data, :concordance) || Map.get(telemetry_data, "concordance") || 1.0,
      message_count:
        Map.get(telemetry_data, :message_count) || Map.get(telemetry_data, "message_count") || 0,
      active_turn:
        Map.get(telemetry_data, :active_turn) || Map.get(telemetry_data, "active_turn") || 1,
      token_usage:
        Map.get(telemetry_data, :token_usage) ||
          Map.get(telemetry_data, "token_usage") ||
          %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      stage:
        normalize_atom(
          Map.get(telemetry_data, :stage) || Map.get(telemetry_data, "stage") || :coding
        ),
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(@pubsub, topic(s_id), {:swarm_telemetry, payload})
    Phoenix.PubSub.broadcast(@pubsub, @telemetry_topic, {:swarm_telemetry, payload})

    {:ok, payload}
  end

  @doc """
  Records a peer message in the history storage.
  """
  @spec record_message(map()) :: :ok
  def record_message(message) when is_map(message) do
    ensure_table_exists()
    s_id = to_string(message[:swarm_id] || message["swarm_id"] || "default")
    order_key = System.monotonic_time(:microsecond)
    :ets.insert(@table, {s_id, order_key, message})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Retrieves chronological peer message history for a swarm (earliest first).
  """
  @spec get_history(String.t()) :: [map()]
  def get_history(swarm_id) do
    ensure_table_exists()
    s_id = to_string(swarm_id)

    case :ets.lookup(@table, s_id) do
      records when is_list(records) ->
        records
        |> Enum.sort_by(fn {_swarm_id, order_key, _msg} -> order_key end)
        |> Enum.map(fn {_swarm_id, _order_key, msg} -> msg end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Clears message history for a given swarm.
  """
  @spec clear_history(String.t()) :: :ok
  def clear_history(swarm_id) do
    ensure_table_exists()
    s_id = to_string(swarm_id)
    :ets.delete(@table, s_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Filters a list of peer messages by role.
  """
  @spec filter_by_role([map()], atom() | String.t()) :: [map()]
  def filter_by_role(messages, role) when is_list(messages) do
    target_role = normalize_atom(role)

    Enum.filter(messages, fn msg ->
      r = normalize_atom(msg[:role] || msg["role"])
      r == target_role
    end)
  end

  @doc """
  Filters a list of peer messages by agent identifier (matches from_agent or to_agent).
  """
  @spec filter_by_agent([map()], String.t()) :: [map()]
  def filter_by_agent(messages, agent_id) when is_list(messages) do
    target_agent = to_string(agent_id)

    Enum.filter(messages, fn msg ->
      from_a = to_string(msg[:from_agent] || msg["from_agent"])
      to_a = to_string(msg[:to_agent] || msg["to_agent"])
      from_a == target_agent or to_a == target_agent
    end)
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_table_exists()
    {:ok, %{}}
  end

  defp ensure_table_exists do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :duplicate_bag,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp generate_uuid do
    "peer-" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> :general
    end
  end

  defp normalize_atom(_), do: :general
end
