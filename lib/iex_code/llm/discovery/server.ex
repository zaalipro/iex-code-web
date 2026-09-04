defmodule IexCode.LLM.Discovery.Server do
  @moduledoc """
  GenServer that coordinates periodic and on-demand discovery of local LLM inference engines.
  Maintains cached server status and discovered models, broadcasting updates over PubSub.
  """
  use GenServer
  require Logger

  alias IexCode.LLM.Discovery

  @pubsub_topic "llm:discovery"
  @default_interval_ms 30_000

  # --- Client API ---

  @doc """
  Starts the discovery server.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the list of currently discovered models.
  """
  def get_discovered_models(server \\ __MODULE__) do
    GenServer.call(server, :get_discovered_models)
  catch
    :exit, _ -> []
  end

  @doc """
  Returns the list of local server probe statuses.
  """
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  catch
    :exit, _ -> []
  end

  @doc """
  Triggers an immediate rescan of local servers, updates cache, broadcasts to PubSub,
  and returns `{:ok, models}`.
  """
  def rescan(server \\ __MODULE__) do
    GenServer.call(server, :rescan, 10_000)
  catch
    :exit, _ -> {:error, :discovery_server_unavailable}
  end

  @doc """
  Subscribes the calling process to discovery broadcasts on `"llm:discovery"`.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(IexCode.PubSub, @pubsub_topic)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:iex_code, :discovery, [])
    enabled? = Keyword.get(opts, :enabled, Keyword.get(config, :enabled, true))

    interval_ms =
      Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, @default_interval_ms))

    probe_opts = Keyword.get(opts, :probe_opts, [])

    # Initial offline state for all known targets
    initial_servers =
      Enum.map(Discovery.targets(), fn t ->
        %{
          provider: t.id,
          name: t.name,
          port: t.port,
          base_url: t.base_url,
          online: false,
          models: [],
          version: nil,
          latency_ms: nil,
          error: nil
        }
      end)

    state = %{
      servers: initial_servers,
      models: [],
      probing?: false,
      enabled?: enabled?,
      interval_ms: interval_ms,
      probe_opts: probe_opts,
      timer_ref: nil,
      last_scanned_at: nil
    }

    if enabled? do
      send(self(), :poll_tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_discovered_models, _from, state) do
    {:reply, state.models, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.servers, state}
  end

  @impl true
  def handle_call(:rescan, _from, state) do
    new_state = execute_scan(state)
    {:reply, {:ok, new_state.models}, new_state}
  end

  @impl true
  def handle_info(:poll_tick, state) do
    new_state = execute_scan(state)
    timer_ref = schedule_poll(new_state.enabled?, new_state.interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp execute_scan(state) do
    {:ok, servers} = Discovery.probe_all(state.probe_opts)
    models = Discovery.discovered_models(servers)

    # Broadcast to PubSub
    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      @pubsub_topic,
      {:local_models_discovered, models}
    )

    %{
      state
      | servers: servers,
        models: models,
        probing?: false,
        last_scanned_at: DateTime.utc_now()
    }
  end

  defp schedule_poll(false, _interval), do: nil

  defp schedule_poll(true, interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :poll_tick, interval)
  end

  defp schedule_poll(_, _), do: nil
end
