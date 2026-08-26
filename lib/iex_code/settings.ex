defmodule IexCode.Settings do
  @moduledoc """
  Context for managing application settings and LLM API credentials.
  Guarantees crash-free singleton retrieval and idempotent updates.

  A blank stored API key means "no key configured" — no key is ever injected
  here. Concurrency is delegated to SQLite's `busy_timeout`; there are no
  sleep-based retry loops.
  """
  import Ecto.Query, warn: false
  require Logger
  alias IexCode.Execution.Policy
  alias IexCode.Repo
  alias IexCode.Research.Registry, as: SearchRegistry
  alias IexCode.Settings.AppSettings

  @default_openai_base "https://cli.llmotions.com/v1"
  @default_provider "openai"
  @default_model "gemini-3.7-flash-high"
  @settings_topic "settings"
  @stale_update_attempts 64
  @tool_atoms %{"ast_search" => :ast_search, "web_search" => :web_search}
  @previous_search_provider_order ~w(tavily brave exa serper google bing searxng duckduckgo)
  @search_provider_order ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)
  @doc """
  Returns the active application settings.
  Safely fetches the most recently updated or created settings record.
  If no settings exist, creates default settings. If the database is
  unavailable, logs the error and falls back to volatile in-memory defaults
  (an unpersisted struct).
  """
  def get_settings do
    case fetch_latest_settings() do
      {:ok, %AppSettings{} = settings} ->
        ensure_default_endpoints(settings)

      {:ok, nil} ->
        create_default_settings()

      {:error, reason} ->
        Logger.error(
          "Settings.get_settings falling back to volatile defaults: #{inspect(reason)}"
        )

        ensure_default_endpoints(volatile_defaults())
    end
  end

  @doc """
  Updates the active application settings.
  Persists updates to the database; relies on `busy_timeout` for lock contention.
  """
  def update_settings(attrs), do: update_latest_settings(attrs, @stale_update_attempts)

  defp update_latest_settings(attrs, stale_attempts) do
    case settings_for_update() do
      {:ok, settings} -> persist_settings(settings, attrs)
      {:error, _reason} = error -> error
    end
  rescue
    _error in Ecto.StaleEntryError ->
      if stale_attempts > 1,
        do: update_latest_settings(attrs, stale_attempts - 1),
        else: {:error, :stale_settings}

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.update_settings failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  @doc "Subscribes the caller to successful global settings updates."
  def subscribe, do: Phoenix.PubSub.subscribe(IexCode.PubSub, @settings_topic)

  @doc "Normalizes browser form parameters without accepting partial numeric parses."
  def normalize_form_params(params, %AppSettings{} = current) when is_map(params) do
    params
    |> preserve_blank_secret("openai_api_key")
    |> preserve_blank_secret("anthropic_api_key")
    |> normalize_required_integers()
    |> normalize_optional_integers()
    |> normalize_float("temperature")
    |> normalize_booleans()
    |> normalize_default_tools()
    |> normalize_provider_order()
    |> merge_search_provider_settings(current)
  end

  def normalize_form_params(params, _current) when is_map(params), do: params
  def normalize_form_params(_params, _current), do: %{}

  @doc "Normalizes and persists settings submitted by a form."
  def update_settings_from_form(%AppSettings{} = current, params) when is_map(params) do
    persist_settings(current, normalize_form_params(params, current))
  rescue
    _error in Ecto.StaleEntryError ->
      {:error, :stale_settings}

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.update_settings_from_form failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def update_settings_from_form(_current, _params), do: {:error, :invalid_settings_form}

  defp persist_settings(%AppSettings{} = settings, attrs) when is_map(attrs) do
    Repo.retry_on_busy(fn ->
      changeset = AppSettings.changeset(settings, attrs)

      if changeset.valid? do
        result =
          if settings.__meta__.state == :built do
            Repo.insert(changeset, log: false)
          else
            Repo.update(changeset, log: false)
          end

        case result do
          {:ok, struct} ->
            updated = ensure_default_endpoints(struct)
            broadcast_update(updated)
            {:ok, updated}

          {:error, %Ecto.Changeset{} = error_changeset} ->
            {:error, error_changeset}
        end
      else
        {:error, changeset}
      end
    end)
  end

  @doc "Explicitly clears one model or ranked-search provider credential."
  def clear_credential(settings \\ nil, credential)

  def clear_credential(settings, credential)
      when credential in [:openai, :openai_api_key, "openai", "openai_api_key"] do
    with {:ok, settings} <- settings_for_credential_update(settings) do
      persist_settings(settings, %{openai_api_key: nil})
    end
  rescue
    _error in Ecto.StaleEntryError ->
      {:error, :stale_settings}

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.clear_credential failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def clear_credential(settings, credential)
      when credential in [:anthropic, :anthropic_api_key, "anthropic", "anthropic_api_key"] do
    with {:ok, settings} <- settings_for_credential_update(settings) do
      persist_settings(settings, %{anthropic_api_key: nil})
    end
  rescue
    _error in Ecto.StaleEntryError ->
      {:error, :stale_settings}

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.clear_credential failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def clear_credential(settings, {:search, provider}),
    do: clear_search_credential(settings, provider)

  def clear_credential(settings, provider) when is_binary(provider),
    do: clear_search_credential(settings, provider)

  def clear_credential(_settings, _credential), do: {:error, :unsupported_credential}

  @doc """
  Returns a validated, string-keyed, secret-free policy snapshot.

  The default call always returns a map. Invalid explicit overrides return the
  structured validation error produced by `IexCode.Execution.Policy`.
  """
  def execution_policy(settings, session \\ nil, overrides \\ %{})

  def execution_policy(%AppSettings{} = settings, session, overrides) when is_map(overrides) do
    case Policy.from_settings(settings, session, overrides) do
      {:ok, policy} -> policy
      {:error, reason} when map_size(overrides) > 0 -> {:error, reason}
      {:error, _reason} -> Policy.from_settings!(volatile_defaults(), nil, %{})
    end
  end

  def execution_policy(_settings, _session, overrides) when is_map(overrides) do
    execution_policy(volatile_defaults(), nil, overrides)
  end

  def execution_policy(_settings, _session, _overrides),
    do: {:error, :invalid_execution_policy_overrides}

  @doc """
  Returns a changeset for tracking settings changes.
  """
  def change_settings(%AppSettings{} = settings, attrs \\ %{}) do
    AppSettings.changeset(settings, attrs)
  end

  @doc "Returns the normalized, ordered configuration consumed by the research gateway."
  def search_config(%AppSettings{} = settings \\ get_settings()) do
    providers = settings.search_providers || default_search_providers()
    configured_order = settings.search_provider_order || @search_provider_order

    order =
      Enum.filter(configured_order, fn provider ->
        config = Map.get(providers, provider, %{})

        Map.get(config, "enabled", Map.get(config, :enabled, false)) == true and
          SearchRegistry.automatically_selectable?(provider)
      end)

    %{
      providers: providers,
      order: Enum.filter(order, &Map.has_key?(providers, &1)),
      depth: settings.research_depth || "standard",
      level: settings.research_level || "medium",
      max_sources: settings.research_max_sources || 12,
      parallelism: settings.research_parallelism || 4,
      require_conflict_audit: settings.research_require_conflict_audit != false,
      max_cost_cents: settings.research_max_cost_cents,
      max_tokens: settings.research_max_tokens,
      time_budget_minutes: settings.research_time_budget_minutes
    }
  end

  defp default_settings_attrs do
    %{
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || "",
      anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com",
      openai_api_key: System.get_env("OPENAI_API_KEY") || "",
      openai_base_url: System.get_env("OPENAI_BASE_URL") || @default_openai_base,
      default_model_provider:
        System.get_env("IEX_CODE_DEFAULT_MODEL_PROVIDER") || @default_provider,
      default_model: System.get_env("IEX_CODE_DEFAULT_MODEL") || @default_model,
      swarm_agent_count: 4,
      auto_save: true,
      temperature: 0.2,
      max_tokens: 4096,
      default_dispatch_mode: "background",
      default_run_mode: "swarm",
      default_run_priority: "normal",
      default_run_max_attempts: 3,
      default_run_token_budget: nil,
      default_run_cost_budget_cents: nil,
      default_run_time_budget_minutes: nil,
      goal_auto_start: true,
      agent_max_turns: 8,
      swarm_max_retries: 3,
      default_tools: %{"ast_search" => true, "web_search" => false},
      search_providers: default_search_providers(),
      search_provider_order: @search_provider_order,
      research_depth: "standard",
      research_level: "medium",
      research_max_sources: 12,
      research_parallelism: 4,
      research_require_conflict_audit: true,
      research_max_cost_cents: nil,
      research_max_tokens: nil,
      research_time_budget_minutes: nil
    }
  end

  defp default_search_providers do
    %{
      "tavily" => provider_config("TAVILY_API_KEY", "https://api.tavily.com"),
      "brave" => provider_config("BRAVE_SEARCH_API_KEY", "https://api.search.brave.com/res/v1"),
      "exa" => provider_config("EXA_API_KEY", "https://api.exa.ai"),
      "perplexity" => provider_config("PERPLEXITY_API_KEY", "https://api.perplexity.ai"),
      "firecrawl" => provider_config("FIRECRAWL_API_KEY", "https://api.firecrawl.dev"),
      "linkup" => provider_config("LINKUP_API_KEY", "https://api.linkup.so"),
      "serper" => provider_config("SERPER_API_KEY", "https://google.serper.dev"),
      "serpapi" =>
        provider_config("SERPAPI_API_KEY", "https://serpapi.com")
        |> Map.put("engine", "google"),
      "google" =>
        provider_config("GOOGLE_SEARCH_API_KEY", "https://customsearch.googleapis.com")
        |> Map.put("engine_id", System.get_env("GOOGLE_SEARCH_ENGINE_ID") || ""),
      "bing" => provider_config("BING_SEARCH_API_KEY", "https://api.bing.microsoft.com/v7.0"),
      "searxng" => %{
        "enabled" => present_env?("SEARXNG_BASE_URL"),
        "base_url" => System.get_env("SEARXNG_BASE_URL") || ""
      },
      "duckduckgo" => %{
        "enabled" => true,
        "base_url" => "https://html.duckduckgo.com"
      }
    }
  end

  defp provider_config(key_env, base_url) do
    %{
      "enabled" => present_env?(key_env),
      "api_key" => System.get_env(key_env) || "",
      "base_url" => base_url
    }
  end

  defp present_env?(name), do: System.get_env(name) not in [nil, ""]

  # Unpersisted defaults used only when the database cannot be reached.
  defp volatile_defaults do
    struct(AppSettings, default_settings_attrs())
  end

  defp create_default_settings do
    Repo.retry_on_busy(fn ->
      case %AppSettings{}
           |> AppSettings.changeset(default_settings_attrs())
           |> Repo.insert(log: false) do
        {:ok, settings} ->
          ensure_default_endpoints(settings)

        {:error, _changeset} ->
          case fetch_latest_settings() do
            {:ok, %AppSettings{} = settings} ->
              ensure_default_endpoints(settings)

            _ ->
              Logger.error("Settings.create_default_settings could not persist or fetch settings")
              ensure_default_endpoints(volatile_defaults())
          end
      end
    end)
  rescue
    # Concurrent creation raced past the singleton unique index — refetch.
    _ in Ecto.ConstraintError ->
      case fetch_latest_settings() do
        {:ok, %AppSettings{} = settings} ->
          ensure_default_endpoints(settings)

        _ ->
          Logger.error("Settings.create_default_settings lost insert race and refetch failed")
          ensure_default_endpoints(volatile_defaults())
      end

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.create_default_settings failed: #{Exception.message(e)}")

      case fetch_latest_settings() do
        {:ok, %AppSettings{} = settings} -> ensure_default_endpoints(settings)
        _ -> ensure_default_endpoints(volatile_defaults())
      end
  end

  defp fetch_latest_settings do
    result =
      Repo.retry_on_busy(fn ->
        Repo.one(
          from(s in AppSettings,
            order_by: [desc: s.updated_at, desc: s.inserted_at, desc: s.id],
            limit: 1
          )
        )
      end)

    {:ok, result}
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.fetch_latest_settings failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # Write paths never proceed from volatile defaults. If the singleton cannot
  # be read after the bounded canonical SQLite retry, returning a DB error is
  # safer than attempting an insert/update from stale or fabricated state.
  defp settings_for_update do
    case fetch_latest_settings() do
      {:ok, %AppSettings{} = settings} ->
        {:ok, settings}

      {:ok, nil} ->
        _ = create_default_settings()

        case fetch_latest_settings() do
          {:ok, %AppSettings{} = settings} -> {:ok, settings}
          {:ok, nil} -> {:error, {:db_error, "settings singleton was not persisted"}}
          {:error, reason} -> {:error, {:db_error, reason}}
        end

      {:error, reason} ->
        {:error, {:db_error, reason}}
    end
  end

  defp ensure_default_endpoints(%AppSettings{} = settings) do
    hydrated_search_providers =
      if is_map(settings.search_providers) and map_size(settings.search_providers) > 0 do
        hydrate_search_providers(settings.search_providers)
      else
        default_search_providers()
      end

    %{
      settings
      | anthropic_base_url:
          if(is_nil(settings.anthropic_base_url) or settings.anthropic_base_url == "",
            do: "https://api.anthropic.com",
            else: settings.anthropic_base_url
          ),
        openai_base_url:
          if(is_nil(settings.openai_base_url) or settings.openai_base_url == "",
            do: @default_openai_base,
            else: settings.openai_base_url
          ),
        default_model_provider:
          if(is_nil(settings.default_model_provider) or settings.default_model_provider == "",
            do: @default_provider,
            else: settings.default_model_provider
          ),
        default_model:
          if(is_nil(settings.default_model) or settings.default_model == "",
            do: @default_model,
            else: settings.default_model
          ),
        search_providers: hydrated_search_providers,
        search_provider_order:
          normalize_search_provider_order(
            settings.search_provider_order,
            hydrated_search_providers
          ),
        research_depth: settings.research_depth || "standard",
        research_level: settings.research_level || "medium",
        research_max_sources: settings.research_max_sources || 12,
        research_parallelism: settings.research_parallelism || 4,
        research_require_conflict_audit:
          if(is_boolean(settings.research_require_conflict_audit),
            do: settings.research_require_conflict_audit,
            else: true
          ),
        default_dispatch_mode: settings.default_dispatch_mode || "background",
        default_run_mode: settings.default_run_mode || "swarm",
        default_run_priority: settings.default_run_priority || "normal",
        default_run_max_attempts: settings.default_run_max_attempts || 3,
        goal_auto_start:
          if(is_boolean(settings.goal_auto_start), do: settings.goal_auto_start, else: true),
        agent_max_turns: settings.agent_max_turns || 8,
        swarm_max_retries: settings.swarm_max_retries || 3,
        default_tools:
          if(is_map(settings.default_tools),
            do: normalize_policy_tools(settings.default_tools, %{}),
            else: %{"ast_search" => true, "web_search" => false}
          )
    }
  end

  defp normalize_search_provider_order(order, providers) do
    known = Enum.filter(@search_provider_order, &Map.has_key?(providers, &1))
    known_set = MapSet.new(known)

    existing =
      order
      |> then(fn value -> if is_list(value), do: value, else: [] end)
      |> Enum.filter(&(is_binary(&1) and MapSet.member?(known_set, &1)))
      |> Enum.uniq()

    if existing == @previous_search_provider_order do
      known
    else
      existing ++ Enum.reject(known, &(&1 in existing))
    end
  end

  defp hydrate_search_providers(stored) do
    Map.merge(default_search_providers(), stored, fn _provider, defaults, current ->
      # Stored values are authoritative. Defaults only fill fields added by a
      # newer release; in particular, an explicit `enabled: false` must never
      # be replaced by an environment-derived/default `true` value.
      Map.merge(defaults, current)
    end)
  end

  defp broadcast_update(settings) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, @settings_topic, {:settings_updated, settings})
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp preserve_blank_secret(params, field) do
    case Map.get(params, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: Map.delete(params, field),
          else: Map.put(params, field, String.trim(value))

      _value ->
        params
    end
  end

  defp normalize_required_integers(params) do
    Enum.reduce(
      ~w(swarm_agent_count max_tokens research_max_sources research_parallelism default_run_max_attempts agent_max_turns swarm_max_retries),
      params,
      &normalize_integer(&2, &1, false)
    )
  end

  defp normalize_optional_integers(params) do
    Enum.reduce(
      ~w(research_max_cost_cents research_max_tokens research_time_budget_minutes default_run_token_budget default_run_cost_budget_cents default_run_time_budget_minutes),
      params,
      &normalize_integer(&2, &1, true)
    )
  end

  defp normalize_integer(params, field, optional?) do
    case Map.fetch(params, field) do
      {:ok, value} when is_integer(value) ->
        params

      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          optional? and trimmed == "" -> Map.put(params, field, nil)
          true -> strict_integer(params, field, trimmed)
        end

      _other ->
        params
    end
  end

  defp strict_integer(params, field, value) do
    case Integer.parse(value) do
      {integer, ""} -> Map.put(params, field, integer)
      _invalid -> params
    end
  end

  defp normalize_float(params, field) do
    case Map.fetch(params, field) do
      {:ok, value} when is_float(value) or is_integer(value) -> params
      {:ok, value} when is_binary(value) -> strict_float(params, field, String.trim(value))
      _other -> params
    end
  end

  defp strict_float(params, field, value) do
    case Float.parse(value) do
      {float, ""} -> Map.put(params, field, float)
      _invalid -> params
    end
  end

  defp normalize_booleans(params) do
    Enum.reduce(
      ~w(auto_save research_require_conflict_audit goal_auto_start),
      params,
      fn field, current ->
        case parse_boolean(Map.get(current, field)) do
          {:ok, value} -> Map.put(current, field, value)
          :error -> current
        end
      end
    )
  end

  defp normalize_default_tools(params) do
    case Map.get(params, "default_tools") do
      tools when is_map(tools) ->
        normalized =
          Enum.reduce(~w(ast_search web_search), %{}, fn tool, acc ->
            case parse_boolean(tool_value(tools, tool)) do
              {:ok, value} -> Map.put(acc, tool, value)
              :error -> acc
            end
          end)

        Map.put(params, "default_tools", normalized)

      _other ->
        params
    end
  end

  defp normalize_provider_order(params) do
    case Map.get(params, "search_provider_order") do
      value when is_binary(value) ->
        order = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        Map.put(params, "search_provider_order", order)

      value when is_list(value) ->
        order = Enum.map(value, &to_string/1)
        Map.put(params, "search_provider_order", order)

      _value ->
        params
    end
  rescue
    _error -> params
  end

  defp merge_search_provider_settings(params, current) do
    case Map.get(params, "search_providers") do
      submitted when is_map(submitted) ->
        existing = current.search_providers || %{}

        merged =
          Enum.reduce(submitted, existing, fn
            {provider, raw_config}, acc when is_binary(provider) and is_map(raw_config) ->
              previous = Map.get(existing, provider, %{})

              config =
                Enum.reduce(raw_config, previous, fn
                  {"api_key", value}, config when is_binary(value) ->
                    if String.trim(value) == "",
                      do: config,
                      else: Map.put(config, "api_key", String.trim(value))

                  {"enabled", value}, config ->
                    case parse_boolean(value) do
                      {:ok, enabled} -> Map.put(config, "enabled", enabled)
                      :error -> Map.put(config, "enabled", false)
                    end

                  {"base_url", value}, config
                  when provider != "searxng" and is_binary(value) ->
                    # Fixed-provider endpoints are security boundaries because
                    # their API keys are sent to them. A crafted form may not
                    # clear or replace the pinned endpoint.
                    if String.trim(value) == "",
                      do: config,
                      else: Map.put(config, "base_url", value)

                  {"engine", value}, config when is_binary(value) ->
                    case String.trim(value) do
                      "" -> Map.delete(config, "engine")
                      engine -> Map.put(config, "engine", engine)
                    end

                  {key, value}, config when is_binary(key) and is_binary(value) ->
                    Map.put(config, key, String.trim(value))

                  {key, value}, config when is_binary(key) ->
                    Map.put(config, key, value)

                  _entry, config ->
                    config
                end)

              Map.put(acc, provider, config)

            _entry, acc ->
              acc
          end)

        Map.put(params, "search_providers", merged)

      _other ->
        params
    end
  end

  defp parse_boolean(value) when value in [true, "true", "1", "on", 1], do: {:ok, true}
  defp parse_boolean(value) when value in [false, "false", "0", "off", 0], do: {:ok, false}
  defp parse_boolean(_value), do: :error

  defp settings_for_credential_update(%AppSettings{} = settings), do: {:ok, settings}
  defp settings_for_credential_update(nil), do: {:ok, get_settings()}
  defp settings_for_credential_update(_settings), do: {:error, :invalid_settings}

  defp clear_search_credential(settings, provider) when is_atom(provider),
    do: clear_search_credential(settings, Atom.to_string(provider))

  defp clear_search_credential(settings, provider) when is_binary(provider) do
    with {:ok, settings} <- settings_for_credential_update(settings),
         {:ok, descriptor} <- search_descriptor(provider),
         true <- :api_key in descriptor.config_fields do
      providers = settings.search_providers || %{}
      config = providers |> Map.get(provider, %{}) |> Map.put("api_key", "")
      persist_settings(settings, %{search_providers: Map.put(providers, provider, config)})
    else
      false -> {:error, :unsupported_credential}
      {:error, _reason} -> {:error, :unsupported_credential}
      :error -> {:error, :unsupported_credential}
    end
  rescue
    _error in Ecto.StaleEntryError ->
      {:error, :stale_settings}

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.clear_search_credential failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  defp clear_search_credential(_settings, _provider), do: {:error, :unsupported_credential}

  defp search_descriptor(provider) do
    case SearchRegistry.descriptor(provider) do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> :error
    end
  end

  defp normalize_policy_tools(tools, fallback) when is_map(tools) do
    Enum.reduce(~w(ast_search web_search), %{}, fn tool, acc ->
      value = tool_value(tools, tool)
      fallback_value = tool_value(fallback, tool, false)

      enabled =
        case parse_boolean(value) do
          {:ok, boolean} -> boolean
          :error -> fallback_value == true
        end

      Map.put(acc, tool, enabled)
    end)
  end

  defp normalize_policy_tools(_tools, fallback), do: normalize_policy_tools(fallback, %{})

  defp tool_value(map, tool, default \\ nil) when is_map(map) do
    case Map.fetch(map, tool) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@tool_atoms, tool), default)
    end
  end
end
