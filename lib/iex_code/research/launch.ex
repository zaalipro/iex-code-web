defmodule IexCode.Research.Launch do
  @moduledoc """
  Canonical validation and policy helpers for exact deep-research launches.

  The module contains no credentials. Its pure helpers normalize policy and
  readiness; `enqueue/2` delegates durable persistence to the run dispatcher.
  Callers may supply an application settings struct (or normalized search
  config) when they want launch-time provider-readiness validation.
  """

  alias IexCode.LLM
  alias IexCode.Research.{GroundedSearch, LevelPolicy, Registry}
  alias IexCode.Runs.DagPayload
  alias IexCode.Runs.DagStepRegistry
  alias IexCode.Sessions
  alias IexCode.Sessions.Session
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings

  @max_sources 40
  @default_fetch_parallelism 6

  @type normalized_request :: %{
          level: String.t(),
          ranked_providers: [String.t()],
          grounded_providers: [String.t()],
          max_sources: 1..40,
          fetch_parallelism: 1..16,
          require_conflict_audit: boolean(),
          provider_snapshot_ref: String.t()
        }

  @doc """
  Validates and enqueues one canonical research request.

  `context` carries trusted workspace identity and launch policy. `request`
  carries the user-visible exact research contract. Public attachment IDs are
  accepted as `request.attachments` or `context.attachment_ids`; their session
  scope and checksums are resolved by the dispatcher before persistence.
  """
  def enqueue(context, request) when is_map(context) and is_map(request) do
    request =
      request
      |> Map.delete(:provider_snapshot_ref)
      |> Map.delete("provider_snapshot_ref")

    with {:ok, settings} <- trusted_settings(value(context, :settings)),
         {:ok, session} <-
           trusted_session(
             value(context, :session) || resolve_session(value(context, :session_id)),
             value(context, :session_id)
           ),
         {:ok, objective} <- required_objective(value(request, :objective)),
         {:ok, normalized} <- normalize_request(request, settings: settings),
         normalized <-
           Map.put(
             normalized,
             :provider_snapshot_ref,
             settings_snapshot_ref(
               settings,
               session,
               normalized.ranked_providers,
               normalized.grounded_providers
             )
           ),
         {:ok, metadata} <- launch_metadata(context, request),
         {:ok, attrs} <- launch_attrs(context, objective, metadata) do
      if value(context, :wake_dispatcher) == false,
        do: IexCode.Runs.RunDispatcher.persist_research(attrs, normalized),
        else: IexCode.Runs.RunDispatcher.enqueue_research(attrs, normalized)
    end
  end

  def enqueue(_context, _request), do: {:error, :invalid_research_launch}

  @doc "The maximum source count preserved by evidence envelopes and the finalizer."
  def max_sources, do: @max_sources

  @doc "The exact supported named research levels."
  def levels, do: LevelPolicy.names()

  @doc "Research DAGs intentionally require manual review rather than whole-run paid replay."
  def retry_policy do
    %{
      "mode" => "manual_review",
      "replay_safe" => false,
      "max_run_attempts" => 1,
      "reason" => "paid_provider_effects_are_not_replayed_across_run_attempts"
    }
  end

  @doc "Returns the non-secret effective-routing reference persisted in a launch manifest."
  def settings_snapshot_ref(settings), do: settings_snapshot_ref(settings, nil)

  def settings_snapshot_ref(%AppSettings{} = settings, session) do
    settings
    |> normalized_runtime_settings()
    |> settings_snapshot_ref(session)
  end

  def settings_snapshot_ref(settings, session) when is_map(settings) do
    settings_snapshot_ref(settings, session, nil, nil)
  end

  def settings_snapshot_ref(_settings, _session), do: "settings://search-providers/current"

  def settings_snapshot_ref(%AppSettings{} = settings, session, ranked, grounded) do
    settings
    |> normalized_runtime_settings()
    |> settings_snapshot_ref(session, ranked, grounded)
  end

  def settings_snapshot_ref(settings, session, ranked, grounded) when is_map(settings) do
    strict_snapshot_ref(%{
      "ranked" => ranked_routing(settings, ranked),
      "grounded" => grounded_routing(settings, grounded),
      "synthesis" => synthesis_routing(settings, session)
    })
  end

  def settings_snapshot_ref(_settings, _session, _ranked, _grounded),
    do: "settings://search-providers/current"

  @doc "Validates an immutable routing reference without persisting or comparing credentials."
  def validate_snapshot_ref(reference, settings, session),
    do: validate_snapshot_ref(reference, settings, session, nil, nil)

  def validate_snapshot_ref(
        "settings://research-routing/v2/" <> digest = expected,
        settings,
        session,
        ranked,
        grounded
      ) do
    if valid_snapshot_digest?(digest) do
      if settings_snapshot_ref(settings, session, ranked, grounded) == expected,
        do: :ok,
        else: {:error, :provider_configuration_changed}
    else
      {:error, :invalid_provider_snapshot_ref}
    end
  end

  def validate_snapshot_ref(
        "settings://research-routing/v1/" <> digest,
        _settings,
        _session,
        _ranked,
        _grounded
      ) do
    if valid_snapshot_digest?(digest),
      do: :ok,
      else: {:error, :invalid_provider_snapshot_ref}
  end

  def validate_snapshot_ref(reference, _settings, _session, _ranked, _grounded)
      when reference in [nil, "settings://search-providers/current", "settings://current"],
      do: :ok

  def validate_snapshot_ref(_reference, _settings, _session, _ranked, _grounded),
    do: {:error, :invalid_provider_snapshot_ref}

  @doc "Accepts only the strict v2 reference shape allowed for newly enqueued research."
  def validate_new_snapshot_ref("settings://research-routing/v2/" <> digest) do
    if valid_snapshot_digest?(digest),
      do: :ok,
      else: {:error, :trusted_provider_snapshot_required}
  end

  def validate_new_snapshot_ref(_reference),
    do: {:error, :trusted_provider_snapshot_required}

  @doc "Normalizes one exact launch request and optionally checks live provider readiness."
  @spec normalize_request(map(), keyword()) :: {:ok, normalized_request()} | {:error, term()}
  def normalize_request(request, opts \\ [])

  def normalize_request(request, opts) when is_map(request) and is_list(opts) do
    with {:ok, policy} <- LevelPolicy.fetch(value(request, :level)),
         {:ok, ranked} <- normalize_ranked_providers(value(request, :ranked_providers) || []),
         {:ok, grounded} <-
           normalize_grounded_providers(value(request, :grounded_providers) || []),
         :ok <- require_evidence_plane(ranked, grounded),
         {:ok, max_sources} <- normalize_max_sources(value(request, :max_sources)),
         {:ok, fetch_parallelism} <-
           bounded_integer(
             value(request, :fetch_parallelism),
             1,
             16,
             @default_fetch_parallelism,
             :research_fetch_parallelism_out_of_range
           ),
         {:ok, require_conflict_audit} <-
           normalize_boolean(value(request, :require_conflict_audit), true),
         {:ok, provider_snapshot_ref} <-
           normalize_snapshot_ref(value(request, :provider_snapshot_ref)),
         :ok <- maybe_validate_readiness(opts[:settings], ranked, grounded) do
      {:ok,
       %{
         level: policy.level,
         ranked_providers: ranked,
         grounded_providers: grounded,
         max_sources: max_sources,
         fetch_parallelism: fetch_parallelism,
         require_conflict_audit: require_conflict_audit,
         provider_snapshot_ref: provider_snapshot_ref
       }}
    end
  end

  def normalize_request(_request, _opts), do: {:error, :invalid_research_launch}

  @doc "Normalizes the finalizer-compatible source bound, rejecting rather than truncating."
  def normalize_max_sources(nil), do: {:ok, @max_sources}

  def normalize_max_sources(value),
    do: bounded_integer(value, 1, @max_sources, nil, :research_max_sources_out_of_range)

  @doc "Describes readiness of selected ranked providers for a supplied settings/config value."
  def ranked_provider_readiness(settings, providers) when is_list(providers) do
    providers
    |> Enum.map(&provider_id/1)
    |> Enum.map(fn provider ->
      case ranked_provider_status(settings, provider) do
        :ready -> %{provider: provider, ready?: true, reason: nil}
        reason -> %{provider: provider, ready?: false, reason: reason}
      end
    end)
  end

  def ranked_provider_readiness(_settings, _providers), do: []

  @doc "Returns selected ranked providers only when every one is execution-ready."
  def validate_ranked_provider_readiness(settings, providers) when is_list(providers) do
    unavailable =
      settings
      |> ranked_provider_readiness(providers)
      |> Enum.reject(& &1.ready?)

    if unavailable == [],
      do: :ok,
      else: {:error, {:research_providers_unavailable, unavailable}}
  end

  def validate_ranked_provider_readiness(_settings, _providers),
    do: {:error, :invalid_ranked_providers}

  @doc "Describes readiness of selected model-native grounded providers."
  def grounded_provider_readiness(settings, providers) when is_list(providers) do
    providers
    |> Enum.map(&provider_id/1)
    |> Enum.map(fn provider ->
      case grounded_provider_status(settings, provider) do
        :ready -> %{provider: provider, ready?: true, reason: nil}
        reason -> %{provider: provider, ready?: false, reason: reason}
      end
    end)
  end

  def grounded_provider_readiness(_settings, _providers), do: []

  @doc "Returns selected grounded providers only when every one is execution-ready."
  def validate_grounded_provider_readiness(settings, providers) when is_list(providers) do
    unavailable =
      settings
      |> grounded_provider_readiness(providers)
      |> Enum.reject(& &1.ready?)

    if unavailable == [],
      do: :ok,
      else: {:error, {:research_grounded_providers_unavailable, unavailable}}
  end

  def validate_grounded_provider_readiness(_settings, _providers),
    do: {:error, :invalid_grounded_providers}

  @doc "Returns all configured ranked providers that are ready for a new launch."
  def ready_ranked_providers(settings) do
    settings
    |> provider_order()
    |> Enum.map(&provider_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(ranked_provider_status(settings, &1) == :ready))
  end

  @doc "Computes the exact pre-use reservations encoded by one research manifest."
  def manifest_budget_requirements(steps) when is_list(steps) do
    Enum.reduce(steps, %{tokens: 0, cost_cents: 0}, fn step, requirements ->
      kind = Map.get(step, :kind, Map.get(step, "kind"))
      params = Map.get(step, :params, Map.get(step, "params", %{})) || %{}

      case DagStepRegistry.fetch(kind) do
        {:ok, module} when is_atom(module) ->
          descriptor = module.descriptor()
          input = nonnegative(params["max_input_tokens"])
          output = nonnegative(params["max_output_tokens"])
          cost = nonnegative(params["max_cost_cents"])

          if descriptor.effect_class == :provider do
            %{
              tokens: requirements.tokens + input + output,
              cost_cents: requirements.cost_cents + cost
            }
          else
            requirements
          end

        :error ->
          requirements
      end
    end)
  end

  def manifest_budget_requirements(_steps), do: %{tokens: 0, cost_cents: 0}

  @doc "Rejects explicit budgets that cannot admit the manifest's known reservations."
  def validate_explicit_budgets(attrs, requirements)
      when is_map(attrs) and is_map(requirements) do
    with :ok <-
           validate_budget(attrs, :token_budget, :tokens, Map.get(requirements, :tokens, 0)),
         :ok <-
           validate_budget(
             attrs,
             :cost_budget_cents,
             :cost_cents,
             Map.get(requirements, :cost_cents, 0)
           ) do
      :ok
    end
  end

  def validate_explicit_budgets(_attrs, _requirements),
    do: {:error, :invalid_research_budget}

  defp launch_attrs(context, objective, metadata) do
    attrs = %{
      project_id: value(context, :project_id),
      session_id: value(context, :session_id),
      objective: objective,
      priority: value(context, :priority),
      token_budget: value(context, :token_budget),
      cost_budget_cents: value(context, :cost_budget_cents),
      time_budget_ms: value(context, :time_budget_ms),
      request_key: value(context, :request_key),
      metadata: metadata
    }

    if valid_id?(attrs.project_id) and valid_id?(attrs.session_id) do
      {:ok, Enum.reject(attrs, fn {_key, value} -> is_nil(value) end) |> Map.new()}
    else
      {:error, :invalid_research_context}
    end
  end

  defp launch_metadata(context, request) do
    metadata = value(context, :metadata) || %{}
    attachment_ids = value(request, :attachments) || value(context, :attachment_ids) || []

    cond do
      not is_map(metadata) ->
        {:error, :invalid_research_metadata}

      not is_list(attachment_ids) or length(attachment_ids) > 12 or
          not Enum.all?(attachment_ids, &(is_integer(&1) and &1 > 0)) ->
        {:error, :invalid_research_attachments}

      true ->
        {:ok,
         metadata
         |> Map.delete(:research_result_ids)
         |> Map.put("research_result_ids", Enum.uniq(attachment_ids))}
    end
  end

  defp required_objective(value) when is_binary(value) do
    objective = String.trim(value)

    if byte_size(objective) in 1..50_000,
      do: {:ok, objective},
      else: {:error, :invalid_research_objective}
  end

  defp required_objective(_value), do: {:error, :invalid_research_objective}

  defp valid_id?(value), do: is_binary(value) and value != ""

  defp strict_snapshot_ref(snapshot) do
    case DagPayload.digest(snapshot) do
      {:ok, digest} -> "settings://research-routing/v2/#{digest}"
      {:error, _reason} -> "settings://research-routing/unavailable"
    end
  end

  defp normalized_runtime_settings(settings) do
    {openai_model, anthropic_model} =
      case settings.default_model_provider do
        "openai" -> {settings.default_model, ""}
        "anthropic" -> {"", settings.default_model}
        _provider -> {"", ""}
      end

    %{
      "search" => Settings.search_config(settings),
      "synthesis_providers" => %{
        "openai" => %{"base_url" => settings.openai_base_url},
        "anthropic" => %{"base_url" => settings.anthropic_base_url}
      },
      "grounded_providers" => %{
        "openai_responses" => %{"model" => openai_model},
        "anthropic_messages" => %{"model" => anthropic_model},
        "gemini_interactions" => %{
          "model" => System.get_env("GEMINI_GROUNDED_MODEL") || "gemini-2.5-flash"
        }
      }
    }
  end

  defp ranked_routing(settings, selected) do
    search = value(settings, :search) || settings
    providers = value(search, :providers) || %{}

    order =
      case value(search, :order) do
        order when is_list(order) ->
          Enum.map(order, &provider_id/1) |> Enum.reject(&is_nil/1)

        _order ->
          providers
          |> Map.keys()
          |> Enum.map(&provider_id/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
      end

    selected = provider_selection(selected, Map.keys(providers))

    effective_order =
      Enum.filter(order, &(&1 in selected)) ++ Enum.reject(selected, &(&1 in order))

    %{
      "order" => effective_order,
      "providers" =>
        Map.new(effective_order, fn provider ->
          {provider, provider |> provider_value(providers) |> public_routing_config()}
        end)
    }
  end

  defp grounded_routing(settings, selected) do
    case value(settings, :grounded_providers) do
      providers when is_map(providers) ->
        selected = provider_selection(selected, Map.keys(providers))

        providers
        |> Enum.map(fn {provider, config} ->
          {provider_id(provider), public_routing_config(config)}
        end)
        |> Enum.filter(fn {provider, _config} -> provider in selected end)
        |> Map.new()

      _providers ->
        %{}
    end
  end

  defp synthesis_routing(settings, session) do
    model = session_model(session)
    providers = value(settings, :synthesis_providers) || %{}
    effective_provider = LLM.effective_provider(model["provider"], model["model"])
    config = effective_provider |> provider_value(providers) |> public_routing_config()

    model
    |> Map.put("provider", effective_provider)
    |> Map.put("config", config)
  end

  defp provider_selection(selected, _defaults) when is_list(selected) do
    selected |> Enum.map(&provider_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp provider_selection(_selected, defaults) do
    defaults |> Enum.map(&provider_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp public_routing_config(config) when is_map(config) do
    config
    |> Enum.reject(fn {key, _value} -> credential_key?(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), public_routing_value(value)} end)
  end

  defp public_routing_config(_config), do: %{}

  defp public_routing_value(value) when is_map(value), do: public_routing_config(value)

  defp public_routing_value(value) when is_list(value),
    do: Enum.map(value, &public_routing_value/1)

  defp public_routing_value(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: value

  defp public_routing_value(value), do: inspect(value)

  defp credential_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

    normalized in ~w(api_key access_token auth_token authorization credential credentials password private_key secret secrets token) or
      Enum.any?(
        ~w(_api_key _secret _token _credential _password _private_key),
        &String.ends_with?(normalized, &1)
      )
  end

  defp provider_value(provider, providers) when is_map(providers) do
    Map.get(providers, provider) ||
      Enum.find_value(providers, %{}, fn
        {key, config} when is_atom(key) -> if Atom.to_string(key) == provider, do: config
        _entry -> nil
      end)
  end

  defp provider_value(_provider, _providers), do: %{}

  defp session_model(session) when is_map(session) do
    %{
      "provider" => value(session, :model_provider),
      "model" => value(session, :model_name)
    }
  end

  defp session_model(_session), do: %{"provider" => nil, "model" => nil}

  defp resolve_session(session_id) when is_binary(session_id),
    do: Sessions.get_session(session_id)

  defp resolve_session(_session_id), do: nil

  defp validate_budget(attrs, field, dimension, required) do
    case value(attrs, field) do
      nil ->
        :ok

      provided when is_integer(provided) and provided >= required ->
        :ok

      provided when is_integer(provided) and provided >= 0 ->
        {:error,
         {:research_budget_below_manifest_requirement,
          %{dimension: dimension, provided: provided, required: required}}}

      _invalid ->
        {:error, {:invalid_research_budget, dimension}}
    end
  end

  defp normalize_ranked_providers(providers) when is_list(providers) do
    normalize_providers(providers, fn provider ->
      match?({:ok, _descriptor}, Registry.descriptor(provider)) and
        Registry.automatically_selectable?(provider)
    end)
  end

  defp normalize_ranked_providers(_providers), do: {:error, :invalid_ranked_providers}

  defp normalize_grounded_providers(providers) when is_list(providers) do
    normalize_providers(providers, fn provider ->
      match?({:ok, %{status: :supported}}, GroundedSearch.descriptor(provider))
    end)
  end

  defp normalize_grounded_providers(_providers), do: {:error, :invalid_grounded_providers}

  defp normalize_providers(providers, supported?) do
    normalized = Enum.map(providers, &provider_id/1)

    cond do
      Enum.any?(normalized, &is_nil/1) -> {:error, :invalid_research_provider}
      Enum.any?(normalized, &(not supported?.(&1))) -> {:error, :unsupported_research_provider}
      true -> {:ok, Enum.uniq(normalized)}
    end
  end

  defp require_evidence_plane([], []), do: {:error, :no_research_provider}
  defp require_evidence_plane(_ranked, _grounded), do: :ok

  defp maybe_validate_readiness(nil, _ranked, _grounded), do: :ok

  defp maybe_validate_readiness(settings, ranked, grounded) do
    with :ok <- validate_ranked_provider_readiness(settings, ranked) do
      validate_grounded_provider_readiness(settings, grounded)
    end
  end

  defp ranked_provider_status(_settings, nil), do: :invalid_provider

  defp ranked_provider_status(settings, provider) do
    config = provider_config(settings, provider)

    case Registry.descriptor(provider) do
      {:ok, %{lifecycle: :retired}} ->
        :retired

      {:ok, descriptor} ->
        cond do
          not enabled?(config) ->
            :disabled

          :api_key in descriptor.config_fields and not configured?(config, "api_key") ->
            :missing_api_key

          provider == "searxng" and not configured?(config, "base_url") ->
            :missing_base_url

          provider == "google" and not configured?(config, "engine_id") ->
            :missing_engine_id

          true ->
            :ready
        end

      :error ->
        :unsupported_provider
    end
  end

  defp grounded_provider_status(_settings, nil), do: :invalid_provider

  defp grounded_provider_status(settings, provider) do
    config = grounded_provider_config(settings, provider)

    case GroundedSearch.descriptor(provider) do
      {:ok, %{status: :supported}} ->
        cond do
          not configured?(config, "api_key") -> :missing_api_key
          not configured?(config, "model") -> :missing_model
          true -> :ready
        end

      {:ok, _descriptor} ->
        :unsupported_provider

      :error ->
        :unsupported_provider
    end
  end

  defp provider_config(%AppSettings{search_providers: providers}, provider),
    do: Map.get(providers || %{}, provider, %{})

  defp provider_config(settings, provider) when is_map(settings) do
    providers =
      value(settings, :search_providers) || value(settings, :providers) ||
        settings |> value(:search) |> then(&(&1 && value(&1, :providers))) || %{}

    Map.get(providers, provider) ||
      Enum.find_value(providers, %{}, fn
        {key, config} when is_atom(key) -> if Atom.to_string(key) == provider, do: config
        _entry -> nil
      end)
  end

  defp provider_config(_settings, _provider), do: %{}

  defp grounded_provider_config(%AppSettings{} = settings, "openai_responses") do
    if settings.default_model_provider == "openai" do
      %{"api_key" => settings.openai_api_key, "model" => settings.default_model}
    else
      %{}
    end
  end

  defp grounded_provider_config(%AppSettings{} = settings, "anthropic_messages") do
    if settings.default_model_provider == "anthropic" do
      %{"api_key" => settings.anthropic_api_key, "model" => settings.default_model}
    else
      %{}
    end
  end

  defp grounded_provider_config(%AppSettings{}, "gemini_interactions") do
    %{
      "api_key" => System.get_env("GEMINI_API_KEY"),
      "model" => System.get_env("GEMINI_GROUNDED_MODEL") || "gemini-2.5-flash"
    }
  end

  defp grounded_provider_config(settings, provider) when is_map(settings) do
    settings
    |> value(:grounded_providers)
    |> then(fn
      providers when is_map(providers) -> provider_value(provider, providers)
      _providers -> %{}
    end)
  end

  defp grounded_provider_config(_settings, _provider), do: %{}

  defp provider_order(%AppSettings{} = settings),
    do: settings.search_provider_order || Map.keys(settings.search_providers || %{})

  defp provider_order(settings) when is_map(settings) do
    value(settings, :search_provider_order) || value(settings, :order) ||
      settings |> value(:search) |> then(&(&1 && value(&1, :order))) ||
      Map.keys(value(settings, :search_providers) || value(settings, :providers) || %{})
  end

  defp provider_order(_settings), do: []

  defp enabled?(config) when is_map(config), do: value(config, :enabled) == true
  defp enabled?(_config), do: false

  defp configured?(config, field) do
    case Map.get(config, field) || existing_atom_value(config, field) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp existing_atom_value(map, "api_key"), do: Map.get(map, :api_key)
  defp existing_atom_value(map, "base_url"), do: Map.get(map, :base_url)
  defp existing_atom_value(map, "engine_id"), do: Map.get(map, :engine_id)
  defp existing_atom_value(_map, _field), do: nil

  defp normalize_boolean(nil, default), do: {:ok, default}
  defp normalize_boolean(value, _default) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value, _default), do: {:error, :invalid_research_conflict_audit}

  defp normalize_snapshot_ref(nil), do: {:ok, "settings://search-providers/current"}

  defp normalize_snapshot_ref(value) when is_binary(value) and byte_size(value) in 1..500,
    do: {:ok, value}

  defp normalize_snapshot_ref(_value), do: {:error, :invalid_provider_snapshot_ref}

  defp valid_snapshot_digest?(digest) when byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_snapshot_digest?(_digest), do: false

  defp trusted_settings(%AppSettings{id: id, __meta__: %{state: :loaded}} = settings)
       when is_binary(id) and id != "",
       do: {:ok, settings}

  defp trusted_settings(_settings), do: {:error, :settings_unavailable}

  defp trusted_session(
         %Session{id: resolved_id, __meta__: %{state: :loaded}} = session,
         session_id
       ) do
    if is_binary(resolved_id) and resolved_id != "" and resolved_id == session_id do
      {:ok, session}
    else
      {:error, :session_unavailable}
    end
  end

  defp trusted_session(_session, _session_id), do: {:error, :session_unavailable}

  defp bounded_integer(nil, _minimum, _maximum, default, _error) when is_integer(default),
    do: {:ok, default}

  defp bounded_integer(value, minimum, maximum, _default, _error)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: {:ok, value}

  defp bounded_integer(value, minimum, maximum, _default, error),
    do: {:error, {error, %{minimum: minimum, maximum: maximum, value: value}}}

  defp provider_id(value) when is_atom(value), do: Atom.to_string(value)

  defp provider_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      provider -> provider
    end
  end

  defp provider_id(_value), do: nil

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)
    Map.get(map, key, Map.get(map, string_key))
  end

  defp value(_map, _key), do: nil
end
