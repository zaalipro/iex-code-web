defmodule IexCode.Settings.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Research.Registry, as: SearchRegistry

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "app_settings" do
    field :anthropic_api_key, :string, redact: true
    field :anthropic_base_url, :string, default: "https://api.anthropic.com"
    field :openai_api_key, :string, redact: true
    field :openai_base_url, :string, default: "https://cli.llmotions.com/v1"
    field :default_model_provider, :string, default: "openai"
    field :default_model, :string, default: "deepseek-v4-pro"
    field :swarm_agent_count, :integer, default: 4
    field :auto_save, :boolean, default: true
    field :temperature, :float, default: 0.2
    field :max_tokens, :integer, default: 4096
    field :default_dispatch_mode, :string, default: "background"
    field :default_run_mode, :string, default: "swarm"
    field :default_run_priority, :string, default: "normal"
    field :default_run_max_attempts, :integer, default: 3
    field :default_run_token_budget, :integer
    field :default_run_cost_budget_cents, :integer
    field :default_run_time_budget_minutes, :integer
    field :goal_auto_start, :boolean, default: true
    field :agent_max_turns, :integer, default: 8
    field :swarm_max_retries, :integer, default: 3
    field :lock_version, :integer, default: 1

    field :default_tools, :map, default: %{"ast_search" => true, "web_search" => false}

    field :search_providers, :map,
      redact: true,
      default: %{
        "tavily" => %{"enabled" => false},
        "brave" => %{"enabled" => false},
        "exa" => %{"enabled" => false},
        "perplexity" => %{"enabled" => false},
        "firecrawl" => %{"enabled" => false},
        "linkup" => %{"enabled" => false},
        "serper" => %{"enabled" => false},
        "serpapi" => %{"enabled" => false},
        "google" => %{"enabled" => false},
        "bing" => %{"enabled" => false},
        "searxng" => %{"enabled" => false},
        "duckduckgo" => %{"enabled" => true}
      }

    field :search_provider_order, {:array, :string},
      default:
        ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)

    field :research_depth, :string, default: "standard"
    field :research_level, :string, default: "medium"
    field :research_max_sources, :integer, default: 12
    field :research_parallelism, :integer, default: 4
    field :research_require_conflict_audit, :boolean, default: true
    field :research_max_cost_cents, :integer
    field :research_max_tokens, :integer
    field :research_time_budget_minutes, :integer

    timestamps(type: :utc_datetime)
  end

  @model_providers ~w(openai anthropic)
  @search_provider_ids ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)
  @required_fields [
    :anthropic_base_url,
    :openai_base_url,
    :default_model_provider,
    :default_model,
    :swarm_agent_count,
    :auto_save,
    :temperature,
    :max_tokens,
    :default_dispatch_mode,
    :default_run_mode,
    :default_run_priority,
    :default_run_max_attempts,
    :goal_auto_start,
    :agent_max_turns,
    :swarm_max_retries,
    :default_tools,
    :search_providers,
    :search_provider_order,
    :research_depth,
    :research_level,
    :research_max_sources,
    :research_parallelism,
    :research_require_conflict_audit
  ]

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :anthropic_api_key,
      :anthropic_base_url,
      :openai_api_key,
      :openai_base_url,
      :default_model_provider,
      :default_model,
      :swarm_agent_count,
      :auto_save,
      :temperature,
      :max_tokens,
      :default_dispatch_mode,
      :default_run_mode,
      :default_run_priority,
      :default_run_max_attempts,
      :default_run_token_budget,
      :default_run_cost_budget_cents,
      :default_run_time_budget_minutes,
      :goal_auto_start,
      :agent_max_turns,
      :swarm_max_retries,
      :default_tools,
      :search_providers,
      :search_provider_order,
      :research_depth,
      :research_level,
      :research_max_sources,
      :research_parallelism,
      :research_require_conflict_audit,
      :research_max_cost_cents,
      :research_max_tokens,
      :research_time_budget_minutes
    ])
    |> validate_required(@required_fields)
    |> validate_length(:anthropic_api_key, max: 4_096)
    |> validate_length(:openai_api_key, max: 4_096)
    |> validate_length(:anthropic_base_url, max: 2_048)
    |> validate_length(:openai_base_url, max: 2_048)
    |> validate_length(:default_model, min: 1, max: 240, count: :bytes)
    |> validate_url(:anthropic_base_url)
    |> validate_url(:openai_base_url)
    |> validate_inclusion(:default_model_provider, @model_providers)
    |> validate_number(:swarm_agent_count,
      greater_than_or_equal_to: 4,
      less_than_or_equal_to: 32
    )
    |> validate_number(:temperature,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:max_tokens,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 128_000
    )
    |> validate_inclusion(:default_dispatch_mode, ~w(background interactive))
    |> validate_inclusion(:default_run_mode, ~w(single swarm dag research))
    |> validate_inclusion(:default_run_priority, ~w(low normal high critical))
    |> validate_number(:default_run_max_attempts,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10
    )
    |> validate_optional_execution_budget(:default_run_token_budget, 10_000_000)
    |> validate_optional_execution_budget(:default_run_cost_budget_cents, 10_000_000)
    |> validate_optional_execution_budget(:default_run_time_budget_minutes, 10_080)
    |> validate_number(:agent_max_turns,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> validate_number(:swarm_max_retries,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10
    )
    |> validate_default_tools()
    |> validate_inclusion(:research_depth, ~w(quick standard deep))
    |> validate_inclusion(:research_level, ~w(low medium high ultra))
    |> validate_number(:research_max_sources,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 40
    )
    |> validate_number(:research_parallelism,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 16
    )
    |> validate_number(:research_max_cost_cents,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10_000_000
    )
    |> validate_number(:research_max_tokens,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10_000_000
    )
    |> validate_number(:research_time_budget_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1_440
    )
    |> check_constraint(:research_level, name: :app_settings_research_level_check)
    |> validate_search_providers()
    |> validate_search_provider_order()
    |> optimistic_lock(:lock_version)
  end

  defp validate_search_providers(changeset) do
    case get_field(changeset, :search_providers) do
      providers when is_map(providers) and map_size(providers) <= 32 ->
        encoded_size =
          case Jason.encode(providers) do
            {:ok, encoded} -> byte_size(encoded)
            {:error, _reason} -> :invalid
          end

        if is_integer(encoded_size) and encoded_size <= 64_000 and
             Enum.all?(providers, &valid_provider_config?/1) do
          changeset
        else
          add_error(changeset, :search_providers, "contains an invalid provider configuration")
        end

      _ ->
        add_error(changeset, :search_providers, "must be a map with at most 32 providers")
    end
  end

  defp valid_provider_config?({id, config}) when is_binary(id) and is_map(config) do
    id in @search_provider_ids and valid_provider_fields?(id, Map.keys(config)) and
      valid_enabled?(Map.get(config, "enabled", Map.get(config, :enabled))) and
      valid_bounded_string?(Map.get(config, "api_key", Map.get(config, :api_key)), 4_096) and
      valid_bounded_string?(Map.get(config, "engine_id", Map.get(config, :engine_id)), 500) and
      valid_engine?(id, Map.get(config, "engine", Map.get(config, :engine))) and
      valid_provider_url?(id, Map.get(config, "base_url", Map.get(config, :base_url)))
  end

  defp valid_provider_config?(_), do: false

  defp valid_provider_fields?(id, fields) do
    case SearchRegistry.descriptor(id) do
      {:ok, descriptor} ->
        allowed = Enum.map(descriptor.config_fields, &Atom.to_string/1)

        normalized =
          Enum.map(fields, fn
            field when is_binary(field) -> field
            field when is_atom(field) -> Atom.to_string(field)
            _field -> :invalid
          end)

        length(normalized) == length(Enum.uniq(normalized)) and
          Enum.all?(normalized, &(&1 in allowed))

      :error ->
        false
    end
  end

  defp valid_enabled?(value), do: is_nil(value) or is_boolean(value)

  defp valid_bounded_string?(value, max),
    do: is_nil(value) or (is_binary(value) and byte_size(value) <= max)

  defp valid_engine?("serpapi", value),
    do: is_nil(value) or value in ~w(google bing duckduckgo baidu yahoo yandex)

  defp valid_engine?(_id, value), do: is_nil(value)

  defp valid_provider_url?(_id, value) when value in [nil, ""], do: true

  defp valid_provider_url?(id, value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if id == "searxng" do
          true
        else
          scheme == "https" and SearchRegistry.official_host(id) == String.downcase(host)
        end

      _ ->
        false
    end
  end

  defp valid_provider_url?(_id, _value), do: false

  defp validate_search_provider_order(changeset) do
    order = get_field(changeset, :search_provider_order)
    providers = get_field(changeset, :search_providers) || %{}

    if is_list(order) and order != [] and length(order) <= 32 and
         Enum.all?(order, &(is_binary(&1) and Map.has_key?(providers, &1))) and
         length(Enum.uniq(order)) == length(order) do
      changeset
    else
      add_error(
        changeset,
        :search_provider_order,
        "must contain unique configured provider identifiers"
      )
    end
  end

  defp validate_optional_execution_budget(changeset, field, maximum) do
    validate_number(changeset, field,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: maximum
    )
  end

  defp validate_default_tools(changeset) do
    case get_field(changeset, :default_tools) do
      tools when is_map(tools) and map_size(tools) <= 2 ->
        normalized_keys =
          Enum.map(Map.keys(tools), fn
            key when is_binary(key) -> key
            key when is_atom(key) -> Atom.to_string(key)
            _key -> :invalid
          end)

        valid? =
          length(normalized_keys) == length(Enum.uniq(normalized_keys)) and
            Enum.all?(normalized_keys, &(&1 in ["ast_search", "web_search"])) and
            Enum.all?(Map.values(tools), &is_boolean/1)

        if valid?, do: changeset, else: add_error(changeset, :default_tools, "is invalid")

      _tools ->
        add_error(changeset, :default_tools, "must contain only supported boolean tools")
    end
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _uri ->
          [{field, "must be an http(s) URL without embedded credentials"}]
      end
    end)
  end
end
