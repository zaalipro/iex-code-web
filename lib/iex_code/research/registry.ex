defmodule IexCode.Research.Registry do
  @moduledoc """
  Canonical registry and configuration resolver for search providers.

  Provider descriptors expose operational lifecycle, capability, and
  authentication metadata without requiring callers to load provider modules.
  Retired providers remain addressable for an explicit compatibility request,
  but are excluded from configuration-driven automatic selection.
  """

  @descriptor_order ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)a

  @descriptors %{
    tavily: %{
      id: :tavily,
      module: IexCode.Research.Providers.Tavily,
      result_contract: :ranked_results,
      official_host: "api.tavily.com",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :content],
      auth_label: "API key"
    },
    brave: %{
      id: :brave,
      module: IexCode.Research.Providers.Brave,
      result_contract: :ranked_results,
      official_host: "api.search.brave.com",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search],
      auth_label: "Subscription token"
    },
    exa: %{
      id: :exa,
      module: IexCode.Research.Providers.Exa,
      result_contract: :ranked_results,
      official_host: "api.exa.ai",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :semantic_search, :content],
      auth_label: "API key"
    },
    perplexity: %{
      id: :perplexity,
      module: IexCode.Research.Providers.Perplexity,
      result_contract: :ranked_results,
      official_host: "api.perplexity.ai",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :content, :domain_filter, :date_filter, :recency_filter],
      auth_label: "API key"
    },
    firecrawl: %{
      id: :firecrawl,
      module: IexCode.Research.Providers.Firecrawl,
      result_contract: :ranked_results,
      official_host: "api.firecrawl.dev",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :content, :domain_filter],
      auth_label: "API key"
    },
    linkup: %{
      id: :linkup,
      module: IexCode.Research.Providers.Linkup,
      result_contract: :ranked_results,
      official_host: "api.linkup.so",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :content, :agentic_search, :domain_filter, :date_filter],
      auth_label: "API key"
    },
    serper: %{
      id: :serper,
      module: IexCode.Research.Providers.Serper,
      result_contract: :ranked_results,
      official_host: "google.serper.dev",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :active,
      capabilities: [:web_search],
      auth_label: "API key"
    },
    serpapi: %{
      id: :serpapi,
      module: IexCode.Research.Providers.SerpApi,
      result_contract: :ranked_results,
      official_host: "serpapi.com",
      config_fields: [:enabled, :api_key, :base_url, :engine],
      lifecycle: :active,
      capabilities: [:web_search, :multi_engine, :localization, :structured_serp],
      auth_label: "API key"
    },
    google: %{
      id: :google,
      module: IexCode.Research.Providers.GoogleCSE,
      result_contract: :ranked_results,
      official_host: "customsearch.googleapis.com",
      config_fields: [:enabled, :api_key, :base_url, :engine_id],
      lifecycle: :sunsetting,
      capabilities: [:web_search],
      auth_label: "API key + search engine ID",
      new_customers: false,
      retires_at: ~D[2027-01-01]
    },
    bing: %{
      id: :bing,
      module: IexCode.Research.Providers.Bing,
      result_contract: :ranked_results,
      official_host: "api.bing.microsoft.com",
      config_fields: [:enabled, :api_key, :base_url],
      lifecycle: :retired,
      capabilities: [:web_search],
      auth_label: "Subscription key"
    },
    searxng: %{
      id: :searxng,
      module: IexCode.Research.Providers.SearxNG,
      result_contract: :ranked_results,
      official_host: nil,
      config_fields: [:enabled, :base_url],
      lifecycle: :active,
      capabilities: [:web_search, :metasearch, :self_hosted],
      auth_label: "Instance URL"
    },
    duckduckgo: %{
      id: :duckduckgo,
      module: IexCode.Research.Providers.DuckDuckGo,
      result_contract: :ranked_results,
      official_host: "html.duckduckgo.com",
      config_fields: [:enabled, :base_url],
      lifecycle: :unofficial,
      capabilities: [:web_search, :credential_free],
      auth_label: "No credentials"
    }
  }

  @providers Map.new(@descriptors, fn {id, descriptor} -> {id, descriptor.module} end)

  @type lifecycle :: :active | :legacy | :sunsetting | :retired | :unofficial
  @type descriptor :: %{
          optional(:new_customers) => boolean(),
          optional(:retires_at) => Date.t(),
          id: atom(),
          module: module(),
          result_contract: :ranked_results,
          official_host: String.t() | nil,
          config_fields: [atom()],
          lifecycle: lifecycle(),
          capabilities: [atom()],
          auth_label: String.t()
        }

  @doc "Returns the provider module map retained for backwards compatibility."
  def all, do: @providers

  @doc "Returns provider identifiers in their stable presentation order."
  def names, do: @descriptor_order

  @doc "Returns provider descriptors in their stable presentation order."
  @spec descriptors() :: [descriptor()]
  def descriptors, do: Enum.map(@descriptor_order, &Map.fetch!(@descriptors, &1))

  @doc "Looks up lifecycle, capability, and authentication metadata for a provider."
  @spec descriptor(atom() | String.t()) :: {:ok, descriptor()} | :error
  def descriptor(name) do
    with {:ok, id} <- normalize_name(name) do
      Map.fetch(@descriptors, id)
    end
  end

  @doc "Returns the pinned official API host, or nil for a self-hosted provider."
  @spec official_host(atom() | String.t()) :: String.t() | nil
  def official_host(name) do
    case descriptor(name) do
      {:ok, descriptor} -> descriptor.official_host
      :error -> nil
    end
  end

  @doc "Returns whether configuration-driven selection may use the provider."
  @spec automatically_selectable?(atom() | String.t()) :: boolean()
  def automatically_selectable?(name) do
    case descriptor(name) do
      {:ok, %{lifecycle: :retired}} -> false
      {:ok, _descriptor} -> true
      :error -> match?({:ok, _module}, fetch_custom_module(name))
    end
  end

  def fetch(name) do
    with {:ok, id} <- normalize_name(name) do
      Map.fetch(@providers, id)
    else
      :error -> fetch_custom_module(name)
    end
  end

  def configured(config \\ %{}) when is_map(config) do
    order = configured_order(config)
    config = unwrap_config(config)

    if map_size(config) == 0 do
      [{:duckduckgo, @providers.duckduckgo, %{}}]
    else
      order
      |> Enum.flat_map(fn name ->
        with {:ok, module} <- fetch(name),
             true <- configured_selectable?(name),
             provider_config <- provider_config(config, name),
             true <- enabled?(provider_config) do
          [{provider_name(name), module, provider_config}]
        else
          _ -> []
        end
      end)
    end
  end

  def configured_providers(settings_or_config), do: configured(settings_or_config)

  def provider_config(config, name) do
    config = unwrap_config(config)

    case Map.get(config, name) || Map.get(config, provider_key(name)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  # DuckDuckGo is the useful, credential-free baseline only when no provider
  # configuration exists. A populated configuration is strictly opt-in.
  defp enabled?(config),
    do: Map.get(config, :enabled, Map.get(config, "enabled", false)) == true

  defp unwrap_config(%{search_providers: config}) when is_map(config), do: config
  defp unwrap_config(%{"search_providers" => config}) when is_map(config), do: config
  defp unwrap_config(%{providers: config}) when is_map(config), do: config
  defp unwrap_config(%{"providers" => config}) when is_map(config), do: config
  defp unwrap_config(config), do: config

  defp configured_order(%{search_provider_order: order}) when is_list(order), do: order
  defp configured_order(%{"search_provider_order" => order}) when is_list(order), do: order
  defp configured_order(%{order: order}) when is_list(order), do: order
  defp configured_order(%{"order" => order}) when is_list(order), do: order
  defp configured_order(config), do: config |> unwrap_config() |> Map.keys()

  defp provider_name(name) do
    case normalize_name(name) do
      {:ok, id} -> id
      :error -> name
    end
  end

  defp provider_key(name) when is_atom(name), do: Atom.to_string(name)
  defp provider_key(name) when is_binary(name), do: name
  defp provider_key(name), do: to_string(name)

  defp normalize_name(:google_cse), do: {:ok, :google}
  defp normalize_name("google_cse"), do: {:ok, :google}

  defp normalize_name(name) when is_atom(name) do
    if Map.has_key?(@descriptors, name), do: {:ok, name}, else: :error
  end

  defp normalize_name(name) when is_binary(name) do
    Enum.find_value(@descriptor_order, :error, fn id ->
      if Atom.to_string(id) == name, do: {:ok, id}
    end)
  end

  defp normalize_name(_name), do: :error

  defp fetch_custom_module(name) when is_atom(name) do
    if Code.ensure_loaded?(name) and function_exported?(name, :search, 2),
      do: {:ok, name},
      else: :error
  end

  defp fetch_custom_module(_name), do: :error

  defp configured_selectable?(name), do: automatically_selectable?(name)
end
