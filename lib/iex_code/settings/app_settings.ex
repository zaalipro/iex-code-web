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

    field :default_reasoning_effort, :string, default: "medium"
    field :default_thinking_budget, :integer, default: 4096
    field :model_overrides, :map, default: %{}

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

    # Codex CLI Parity & Safety Settings
    field :tool_approval_mode, :string, default: "prompt_dangerous"

    field :tool_category_overrides, :map,
      default: %{
        "shell_execution" => "prompt",
        "file_mutations" => "prompt",
        "git_push" => "prompt",
        "web_search" => "auto"
      }

    field :context_window_tokens, :integer, default: 128_000
    field :context_prune_threshold_percent, :integer, default: 75
    field :context_compaction_strategy, :string, default: "token_compaction"
    field :keep_recent_turns, :integer, default: 6
    field :custom_system_prompt, :string
    field :workspace_persona, :string, default: "pragmatic_engineer"
    field :coding_style_rules, :string
    field :custom_env_vars, :map, default: %{}
    field :sandbox_mode, :string, default: "inherit_filtered"
    field :sound_enabled, :boolean, default: true
    field :sound_volume, :integer, default: 80
    field :completion_chime, :string, default: "hero"
    field :error_alert_chime, :string, default: "basso"
    field :approval_prompt_chime, :string, default: "ping"
    field :theme_accent, :string, default: "cyan"
    field :layout_density, :string, default: "comfortable"

    # VPS Resource Policy Settings
    field :resource_pressure_percent, :integer, default: 70
    field :resource_critical_percent, :integer, default: 85
    field :terminal_idle_timeout_minutes, :integer, default: 30
    field :session_idle_timeout_minutes, :integer, default: 30
    field :output_artifact_limit_mib, :integer, default: 256
    field :output_spool_quota_mib, :integer, default: 2048
    field :output_retention_days, :integer, default: 7

    timestamps(type: :utc_datetime)
  end

  @model_providers ~w(openai anthropic)
  @search_provider_ids ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)
  @tool_approval_modes ~w(full_auto prompt_dangerous read_only)
  @compaction_strategies ~w(token_compaction rolling_summary sliding_window)
  @workspace_personas ~w(pragmatic_engineer architect security_auditor minimalist custom)
  @sandbox_modes ~w(isolated inherit_filtered passthrough)
  @chimes ~w(hero sosumi basso ping glass bottle funk)
  @theme_accents ~w(cyan emerald violet amber rose carbon)
  @layout_densities ~w(comfortable compact)

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
    :research_require_conflict_audit,
    :resource_pressure_percent,
    :resource_critical_percent,
    :terminal_idle_timeout_minutes,
    :session_idle_timeout_minutes,
    :output_artifact_limit_mib,
    :output_spool_quota_mib,
    :output_retention_days
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
      :default_reasoning_effort,
      :default_thinking_budget,
      :model_overrides,
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
      :research_time_budget_minutes,
      :tool_approval_mode,
      :tool_category_overrides,
      :context_window_tokens,
      :context_prune_threshold_percent,
      :context_compaction_strategy,
      :keep_recent_turns,
      :custom_system_prompt,
      :workspace_persona,
      :coding_style_rules,
      :custom_env_vars,
      :sandbox_mode,
      :sound_enabled,
      :sound_volume,
      :completion_chime,
      :error_alert_chime,
      :approval_prompt_chime,
      :theme_accent,
      :layout_density,
      :resource_pressure_percent,
      :resource_critical_percent,
      :terminal_idle_timeout_minutes,
      :session_idle_timeout_minutes,
      :output_artifact_limit_mib,
      :output_spool_quota_mib,
      :output_retention_days
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
    |> validate_inclusion(:default_reasoning_effort, ~w(none low medium high max))
    |> validate_number(:default_thinking_budget,
      greater_than_or_equal_to: 1024,
      less_than_or_equal_to: 128_000
    )
    |> validate_model_overrides()
    |> validate_search_providers()
    |> validate_search_provider_order()
    |> validate_inclusion(:tool_approval_mode, @tool_approval_modes)
    |> validate_tool_category_overrides()
    |> validate_number(:context_window_tokens,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 10_000_000
    )
    |> validate_number(:context_prune_threshold_percent,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 95
    )
    |> validate_inclusion(:context_compaction_strategy, @compaction_strategies)
    |> validate_number(:keep_recent_turns,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 50
    )
    |> validate_length(:custom_system_prompt, max: 20_000)
    |> validate_inclusion(:workspace_persona, @workspace_personas)
    |> validate_length(:coding_style_rules, max: 20_000)
    |> validate_custom_env_vars()
    |> validate_inclusion(:sandbox_mode, @sandbox_modes)
    |> validate_number(:sound_volume,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_inclusion(:completion_chime, @chimes)
    |> validate_inclusion(:error_alert_chime, @chimes)
    |> validate_inclusion(:approval_prompt_chime, @chimes)
    |> validate_inclusion(:theme_accent, @theme_accents)
    |> validate_inclusion(:layout_density, @layout_densities)
    |> validate_number(:resource_pressure_percent,
      greater_than_or_equal_to: 40,
      less_than_or_equal_to: 95
    )
    |> validate_number(:resource_critical_percent,
      greater_than_or_equal_to: 50,
      less_than_or_equal_to: 99
    )
    |> validate_number(:terminal_idle_timeout_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1_440
    )
    |> validate_number(:session_idle_timeout_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1_440
    )
    |> validate_number(:output_artifact_limit_mib,
      greater_than_or_equal_to: 16,
      less_than_or_equal_to: 1_024
    )
    |> validate_number(:output_spool_quota_mib,
      greater_than_or_equal_to: 256,
      less_than_or_equal_to: 10_240
    )
    |> validate_number(:output_retention_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 90
    )
    |> validate_resource_policy()
    |> optimistic_lock(:lock_version)
  end

  defp validate_resource_policy(changeset) do
    pressure = get_field(changeset, :resource_pressure_percent)
    critical = get_field(changeset, :resource_critical_percent)
    artifact_limit = get_field(changeset, :output_artifact_limit_mib)
    spool_quota = get_field(changeset, :output_spool_quota_mib)

    changeset =
      if is_integer(pressure) and is_integer(critical) and pressure >= critical,
        do: add_error(changeset, :resource_critical_percent, "must exceed pressure threshold"),
        else: changeset

    if is_integer(artifact_limit) and is_integer(spool_quota) and
         artifact_limit > spool_quota,
       do: add_error(changeset, :output_spool_quota_mib, "must cover one output artifact"),
       else: changeset
  end

  defp validate_model_overrides(changeset) do
    case get_field(changeset, :model_overrides) do
      nil ->
        put_change(changeset, :model_overrides, %{})

      overrides when is_map(overrides) and map_size(overrides) <= 128 ->
        if Enum.all?(overrides, &valid_model_override?/1) do
          changeset
        else
          add_error(
            changeset,
            :model_overrides,
            "contains an invalid model override configuration"
          )
        end

      _ ->
        add_error(changeset, :model_overrides, "must be a map with at most 128 model overrides")
    end
  end

  defp valid_model_override?({model_name, config})
       when is_binary(model_name) and byte_size(model_name) <= 240 and is_map(config) do
    budget =
      Map.get(
        config,
        "budget_tokens",
        Map.get(
          config,
          :budget_tokens,
          Map.get(config, "thinking_budget", Map.get(config, :thinking_budget))
        )
      )

    valid_override_keys?(config) and
      valid_override_effort?(
        Map.get(config, "reasoning_effort", Map.get(config, :reasoning_effort))
      ) and
      valid_override_budget?(budget) and
      valid_override_tokens?(Map.get(config, "max_tokens", Map.get(config, :max_tokens))) and
      valid_override_temp?(Map.get(config, "temperature", Map.get(config, :temperature)))
  end

  defp valid_model_override?(_), do: false

  defp valid_override_keys?(config) do
    allowed = ~w(reasoning_effort budget_tokens thinking_budget max_tokens temperature)

    keys =
      Enum.map(Map.keys(config), fn
        k when is_binary(k) -> k
        k when is_atom(k) -> Atom.to_string(k)
        _ -> :invalid
      end)

    Enum.all?(keys, &(&1 in allowed))
  end

  defp valid_override_effort?(nil), do: true

  defp valid_override_effort?(effort) when is_binary(effort),
    do: effort in ~w(none low medium high max)

  defp valid_override_effort?(effort) when is_atom(effort),
    do: Atom.to_string(effort) in ~w(none low medium high max)

  defp valid_override_effort?(_), do: false

  defp valid_override_budget?(nil), do: true
  defp valid_override_budget?(b) when is_integer(b), do: b >= 1024 and b <= 128_000
  defp valid_override_budget?(_), do: false

  defp valid_override_tokens?(nil), do: true
  defp valid_override_tokens?(t) when is_integer(t), do: t >= 1 and t <= 128_000
  defp valid_override_tokens?(_), do: false

  defp valid_override_temp?(nil), do: true
  defp valid_override_temp?(temp) when is_float(temp), do: temp >= 0.0 and temp <= 2.0
  defp valid_override_temp?(temp) when is_integer(temp), do: temp >= 0 and temp <= 2
  defp valid_override_temp?(_), do: false

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

  defp validate_tool_category_overrides(changeset) do
    case get_field(changeset, :tool_category_overrides) do
      nil ->
        put_change(changeset, :tool_category_overrides, %{
          "shell_execution" => "prompt",
          "file_mutations" => "prompt",
          "git_push" => "prompt",
          "web_search" => "auto"
        })

      overrides when is_map(overrides) and map_size(overrides) <= 32 ->
        allowed_cats = ~w(shell_execution file_mutations git_push web_search read_only other)
        allowed_vals = ~w(auto prompt deny)

        valid? =
          Enum.all?(overrides, fn {k, v} ->
            k_str = to_string(k)
            v_str = to_string(v)
            k_str in allowed_cats and v_str in allowed_vals
          end)

        if valid?,
          do: changeset,
          else:
            add_error(changeset, :tool_category_overrides, "contains invalid category overrides")

      _ ->
        add_error(changeset, :tool_category_overrides, "must be a map of category overrides")
    end
  end

  defp validate_custom_env_vars(changeset) do
    case get_field(changeset, :custom_env_vars) do
      nil ->
        put_change(changeset, :custom_env_vars, %{})

      vars when is_map(vars) and map_size(vars) <= 128 ->
        valid? =
          Enum.all?(vars, fn {k, v} ->
            k_str = to_string(k)
            v_str = to_string(v)

            byte_size(k_str) > 0 and byte_size(k_str) <= 256 and
              not String.contains?(k_str, "=") and
              byte_size(v_str) <= 4096
          end)

        if valid?,
          do: changeset,
          else: add_error(changeset, :custom_env_vars, "contains invalid environment variables")

      _ ->
        add_error(
          changeset,
          :custom_env_vars,
          "must be a map with at most 128 environment variables"
        )
    end
  end
end
