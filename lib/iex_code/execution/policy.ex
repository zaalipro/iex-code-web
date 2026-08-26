defmodule IexCode.Execution.Policy do
  @moduledoc """
  Builds a validated, secret-free execution-policy snapshot.

  Stored settings and an optional session supply defaults. Explicit overrides
  are validated rather than silently coerced or ignored. The resulting v1 map
  contains string keys only and intentionally excludes credentials, endpoints,
  and ranked-search provider configuration.
  """

  alias IexCode.Execution.{Limits, ModelRoute, PolicyError}

  @version 1
  @max_model_name_bytes Limits.max_model_name_bytes()
  @dispatch_modes ~w(background interactive)
  @run_modes ~w(single swarm dag research)
  @priorities ~w(low normal high critical)
  @model_providers ~w(openai anthropic)
  @optional_tools %{
    "ast_search" => ["ast_search"],
    "web_search" => ["web_search", "fetch_url"]
  }
  @core_tools ~w(
    read_file
    write_file
    patch_file
    multi_patch
    list_dir
    grep_search
    run_tests
    run_command
    git_status
    git_diff
    git_stage
    git_commit
    git_generate_commit
  )
  @all_tools @core_tools ++ ~w(ast_search web_search fetch_url)
  @secret_field_fragments ~w(api_key authorization base_url cookie credential endpoint password secret)

  @override_aliases %{
    "dispatch_mode" => "dispatch_mode",
    "default_dispatch_mode" => "dispatch_mode",
    "run_mode" => "run_mode",
    "default_run_mode" => "run_mode",
    "priority" => "run_priority",
    "run_priority" => "run_priority",
    "default_run_priority" => "run_priority",
    "max_attempts" => "run_max_attempts",
    "run_max_attempts" => "run_max_attempts",
    "default_run_max_attempts" => "run_max_attempts",
    "token_budget" => "run_token_budget",
    "run_token_budget" => "run_token_budget",
    "default_run_token_budget" => "run_token_budget",
    "cost_budget_cents" => "run_cost_budget_cents",
    "run_cost_budget_cents" => "run_cost_budget_cents",
    "default_run_cost_budget_cents" => "run_cost_budget_cents",
    "time_budget_minutes" => "run_time_budget_minutes",
    "run_time_budget_minutes" => "run_time_budget_minutes",
    "default_run_time_budget_minutes" => "run_time_budget_minutes",
    "goal_auto_start" => "goal_auto_start",
    "agent_max_turns" => "agent_max_turns",
    "swarm_agent_count" => "swarm_agent_count",
    "swarm_max_retries" => "swarm_max_retries",
    "default_tools" => "default_tools",
    "allowed_tools" => "allowed_tools",
    "model_provider" => "model_provider",
    "default_model_provider" => "model_provider",
    "model_name" => "model_name",
    "default_model" => "model_name",
    "temperature" => "temperature",
    "max_tokens" => "max_tokens"
  }

  @defaults %{
    "dispatch_mode" => "background",
    "run_mode" => "swarm",
    "run_priority" => "normal",
    "run_max_attempts" => 3,
    "run_token_budget" => nil,
    "run_cost_budget_cents" => nil,
    "run_time_budget_minutes" => nil,
    "goal_auto_start" => true,
    "agent_max_turns" => 8,
    "swarm_agent_count" => 4,
    "swarm_max_retries" => 3,
    "default_tools" => %{"ast_search" => true, "web_search" => false},
    "model_provider" => "openai",
    "model_name" => "deepseek-v4-pro",
    "temperature" => 0.2,
    "max_tokens" => 4_096
  }

  @type policy :: %{required(String.t()) => term()}
  @type result :: {:ok, policy()} | {:error, PolicyError.t()}

  @spec from_settings(map() | struct(), map() | struct() | nil, map()) :: result()
  def from_settings(settings, session \\ nil, overrides \\ %{})

  def from_settings(settings, session, overrides)
      when is_map(settings) and (is_map(session) or is_nil(session)) and is_map(overrides) do
    base = settings_policy(settings, session)

    with {:ok, normalized_overrides} <- normalize_overrides(overrides),
         {:ok, policy} <- apply_overrides(base, normalized_overrides),
         {:ok, policy} <- policy |> finalize() |> ModelRoute.put_digest(settings) do
      {:ok, policy}
    end
  end

  def from_settings(_settings, _session, _overrides) do
    {:error,
     %PolicyError{
       code: :invalid_override,
       field: "policy",
       value: nil,
       message: "Settings, session, and overrides must be maps or structs"
     }}
  end

  @spec from_settings!(map() | struct(), map() | struct() | nil, map()) :: policy()
  def from_settings!(settings, session \\ nil, overrides \\ %{}) do
    case from_settings(settings, session, overrides) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec supported_tools() :: [String.t()]
  def supported_tools, do: @all_tools

  defp settings_policy(settings, session) do
    @defaults
    |> Map.put(
      "dispatch_mode",
      stored_enum(settings, "default_dispatch_mode", @dispatch_modes, @defaults["dispatch_mode"])
    )
    |> Map.put(
      "run_mode",
      stored_enum(settings, "default_run_mode", @run_modes, @defaults["run_mode"])
    )
    |> Map.put(
      "run_priority",
      stored_enum(
        settings,
        "default_run_priority",
        @priorities,
        @defaults["run_priority"]
      )
    )
    |> Map.put(
      "run_max_attempts",
      stored_integer(settings, "default_run_max_attempts", 1, 10, @defaults["run_max_attempts"])
    )
    |> Map.put(
      "run_token_budget",
      stored_optional_integer(settings, "default_run_token_budget", 1, 10_000_000)
    )
    |> Map.put(
      "run_cost_budget_cents",
      stored_optional_integer(settings, "default_run_cost_budget_cents", 1, 10_000_000)
    )
    |> Map.put(
      "run_time_budget_minutes",
      stored_optional_integer(settings, "default_run_time_budget_minutes", 1, 10_080)
    )
    |> Map.put(
      "goal_auto_start",
      stored_boolean(settings, "goal_auto_start", @defaults["goal_auto_start"])
    )
    |> Map.put(
      "agent_max_turns",
      stored_integer(settings, "agent_max_turns", 1, 20, @defaults["agent_max_turns"])
    )
    |> Map.put(
      "swarm_agent_count",
      stored_integer(settings, "swarm_agent_count", 4, 32, @defaults["swarm_agent_count"])
    )
    |> Map.put(
      "swarm_max_retries",
      stored_integer(settings, "swarm_max_retries", 0, 10, @defaults["swarm_max_retries"])
    )
    |> Map.put(
      "default_tools",
      stored_tool_map(value(settings, "default_tools"), @defaults["default_tools"])
    )
    |> Map.put(
      "model_provider",
      session_or_setting_enum(
        session,
        "model_provider",
        settings,
        "default_model_provider",
        @model_providers,
        @defaults["model_provider"]
      )
    )
    |> Map.put(
      "model_name",
      session_or_setting_string(
        session,
        "model_name",
        settings,
        "default_model",
        @max_model_name_bytes,
        @defaults["model_name"]
      )
    )
    |> Map.put(
      "temperature",
      session_or_setting_float(
        session,
        "temperature",
        settings,
        "temperature",
        0.0,
        2.0,
        @defaults["temperature"]
      )
    )
    |> Map.put(
      "max_tokens",
      stored_integer(settings, "max_tokens", 1, 128_000, @defaults["max_tokens"])
    )
  end

  defp normalize_overrides(overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn {raw_key, value}, {:ok, acc} ->
      key = key_string(raw_key)

      case Map.get(@override_aliases, key) do
        nil ->
          {:halt,
           policy_error(
             :unsupported_override,
             key,
             value,
             "Unsupported execution policy override #{inspect(key)}"
           )}

        canonical ->
          if Map.has_key?(acc, canonical) do
            {:halt,
             policy_error(
               :invalid_override,
               canonical,
               value,
               "Execution policy override #{inspect(canonical)} was provided more than once"
             )}
          else
            {:cont, {:ok, Map.put(acc, canonical, value)}}
          end
      end
    end)
  end

  defp apply_overrides(policy, overrides) do
    validators = [
      {"dispatch_mode", &enum_override(&1, @dispatch_modes)},
      {"run_mode", &enum_override(&1, @run_modes)},
      {"run_priority", &enum_override(&1, @priorities)},
      {"run_max_attempts", &integer_override(&1, 1, 10)},
      {"run_token_budget", &optional_integer_override(&1, 1, 10_000_000)},
      {"run_cost_budget_cents", &optional_integer_override(&1, 1, 10_000_000)},
      {"run_time_budget_minutes", &optional_integer_override(&1, 1, 10_080)},
      {"goal_auto_start", &boolean_override/1},
      {"agent_max_turns", &integer_override(&1, 1, 20)},
      {"swarm_agent_count", &integer_override(&1, 4, 32)},
      {"swarm_max_retries", &integer_override(&1, 0, 10)},
      {"model_provider", &enum_override(&1, @model_providers)},
      {"model_name", &string_override(&1, @max_model_name_bytes)},
      {"temperature", &float_override(&1, 0.0, 2.0)},
      {"max_tokens", &integer_override(&1, 1, 128_000)},
      {"default_tools", &tool_map_override/1},
      {"allowed_tools", &allowed_tools_override/1}
    ]

    Enum.reduce_while(validators, {:ok, policy}, fn {key, validator}, {:ok, acc} ->
      case Map.fetch(overrides, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case validator.(value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
            :error -> {:halt, invalid_override(key, value)}
          end
      end
    end)
  end

  defp finalize(policy) do
    allowed_tools =
      case Map.fetch(policy, "allowed_tools") do
        {:ok, tools} -> tools
        :error -> expand_default_tools(policy["default_tools"])
      end

    policy
    |> Map.drop(["default_tools"])
    |> Map.put("allowed_tools", allowed_tools)
    |> Map.put("version", @version)
  end

  defp stored_enum(map, key, allowed, fallback) do
    candidate = value(map, key)
    if candidate in allowed, do: candidate, else: fallback
  end

  defp stored_integer(map, key, minimum, maximum, fallback) do
    case integer_value(value(map, key), minimum, maximum) do
      {:ok, integer} -> integer
      :error -> fallback
    end
  end

  defp stored_optional_integer(map, key, minimum, maximum) do
    case value(map, key) do
      nil ->
        nil

      "" ->
        nil

      candidate ->
        case integer_value(candidate, minimum, maximum) do
          {:ok, integer} -> integer
          :error -> nil
        end
    end
  end

  defp stored_boolean(map, key, fallback) do
    case boolean_value(value(map, key)) do
      {:ok, boolean} -> boolean
      :error -> fallback
    end
  end

  defp stored_tool_map(candidate, fallback) when is_map(candidate) do
    Enum.reduce(@optional_tools, %{}, fn {tool, _expanded}, acc ->
      default = Map.get(fallback, tool, false)

      enabled =
        case boolean_value(value(candidate, tool)) do
          {:ok, boolean} -> boolean
          :error -> default
        end

      Map.put(acc, tool, enabled)
    end)
  end

  defp stored_tool_map(_candidate, fallback), do: fallback

  defp session_or_setting_enum(session, session_key, settings, setting_key, allowed, fallback) do
    candidate = value(session, session_key)

    if candidate in allowed,
      do: candidate,
      else: stored_enum(settings, setting_key, allowed, fallback)
  end

  defp session_or_setting_string(
         session,
         session_key,
         settings,
         setting_key,
         maximum,
         fallback
       ) do
    case bounded_string(value(session, session_key), maximum) do
      {:ok, string} ->
        string

      :error ->
        case bounded_string(value(settings, setting_key), maximum) do
          {:ok, string} -> string
          :error -> fallback
        end
    end
  end

  defp session_or_setting_float(
         session,
         session_key,
         settings,
         setting_key,
         minimum,
         maximum,
         fallback
       ) do
    case float_value(value(session, session_key), minimum, maximum) do
      {:ok, float} ->
        float

      :error ->
        case float_value(value(settings, setting_key), minimum, maximum) do
          {:ok, float} -> float
          :error -> fallback
        end
    end
  end

  defp enum_override(value, allowed), do: if(value in allowed, do: {:ok, value}, else: :error)
  defp integer_override(value, minimum, maximum), do: integer_value(value, minimum, maximum)

  defp optional_integer_override(value, _minimum, _maximum) when value in [nil, ""],
    do: {:ok, nil}

  defp optional_integer_override(value, minimum, maximum),
    do: integer_value(value, minimum, maximum)

  defp boolean_override(value), do: boolean_value(value)
  defp string_override(value, maximum), do: bounded_string(value, maximum)
  defp float_override(value, minimum, maximum), do: float_value(value, minimum, maximum)

  defp tool_map_override(value) when is_map(value) do
    allowed_keys = Map.keys(@optional_tools) |> MapSet.new()
    submitted_keys = value |> Map.keys() |> Enum.map(&key_string/1)

    if Enum.all?(submitted_keys, &MapSet.member?(allowed_keys, &1)) do
      Enum.reduce_while(@optional_tools, {:ok, %{}}, fn {tool, _expanded}, {:ok, acc} ->
        case fetch_value(value, tool) do
          :absent ->
            {:cont, {:ok, Map.put(acc, tool, false)}}

          {:present, raw} ->
            case boolean_value(raw) do
              {:ok, boolean} -> {:cont, {:ok, Map.put(acc, tool, boolean)}}
              :error -> {:halt, :error}
            end
        end
      end)
    else
      :error
    end
  end

  defp tool_map_override(_value), do: :error

  defp allowed_tools_override(value) when is_list(value) do
    normalized = Enum.map(value, &key_string/1)

    if length(normalized) == length(Enum.uniq(normalized)) and
         Enum.all?(normalized, &(&1 in @all_tools)) do
      {:ok, Enum.filter(@all_tools, &(&1 in normalized))}
    else
      :error
    end
  end

  defp allowed_tools_override(_value), do: :error

  defp expand_default_tools(tools) do
    optional =
      Enum.flat_map(@optional_tools, fn {tool, expanded} ->
        if Map.get(tools, tool, false), do: expanded, else: []
      end)

    Enum.uniq(@core_tools ++ optional)
  end

  defp integer_value(value, minimum, maximum) when is_integer(value) do
    if value >= minimum and value <= maximum, do: {:ok, value}, else: :error
  end

  defp integer_value(value, minimum, maximum) when is_binary(value) do
    if String.valid?(value) do
      case Integer.parse(String.trim(value)) do
        {integer, ""} when integer >= minimum and integer <= maximum -> {:ok, integer}
        _ -> :error
      end
    else
      :error
    end
  end

  defp integer_value(_value, _minimum, _maximum), do: :error

  defp float_value(value, minimum, maximum) when is_integer(value),
    do: float_value(value / 1, minimum, maximum)

  defp float_value(value, minimum, maximum) when is_float(value) do
    if value >= minimum and value <= maximum, do: {:ok, value}, else: :error
  end

  defp float_value(value, minimum, maximum) when is_binary(value) do
    if String.valid?(value) do
      case Float.parse(String.trim(value)) do
        {float, ""} -> float_value(float, minimum, maximum)
        _ -> :error
      end
    else
      :error
    end
  end

  defp float_value(_value, _minimum, _maximum), do: :error

  defp boolean_value(value) when value in [true, "true", "1", "on"], do: {:ok, true}
  defp boolean_value(value) when value in [false, "false", "0", "off"], do: {:ok, false}
  defp boolean_value(_value), do: :error

  defp bounded_string(value, maximum) when is_binary(value) do
    if String.valid?(value) do
      trimmed = String.trim(value)

      if trimmed != "" and byte_size(trimmed) <= maximum,
        do: {:ok, trimmed},
        else: :error
    else
      :error
    end
  end

  defp bounded_string(_value, _maximum), do: :error

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, known_atom(key)))
  end

  defp fetch_value(map, key) when is_map(map) do
    atom = known_atom(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, atom) -> {:present, Map.get(map, atom)}
      true -> :absent
    end
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
  defp key_string(key), do: inspect(key)

  # Closed conversion table: never create atoms from user-controlled input.
  defp known_atom("default_dispatch_mode"), do: :default_dispatch_mode
  defp known_atom("default_run_mode"), do: :default_run_mode
  defp known_atom("default_run_priority"), do: :default_run_priority
  defp known_atom("default_run_max_attempts"), do: :default_run_max_attempts
  defp known_atom("default_run_token_budget"), do: :default_run_token_budget
  defp known_atom("default_run_cost_budget_cents"), do: :default_run_cost_budget_cents
  defp known_atom("default_run_time_budget_minutes"), do: :default_run_time_budget_minutes
  defp known_atom("goal_auto_start"), do: :goal_auto_start
  defp known_atom("agent_max_turns"), do: :agent_max_turns
  defp known_atom("swarm_agent_count"), do: :swarm_agent_count
  defp known_atom("swarm_max_retries"), do: :swarm_max_retries
  defp known_atom("default_tools"), do: :default_tools
  defp known_atom("default_model_provider"), do: :default_model_provider
  defp known_atom("default_model"), do: :default_model
  defp known_atom("model_provider"), do: :model_provider
  defp known_atom("model_name"), do: :model_name
  defp known_atom("temperature"), do: :temperature
  defp known_atom("max_tokens"), do: :max_tokens
  defp known_atom("ast_search"), do: :ast_search
  defp known_atom("web_search"), do: :web_search
  defp known_atom(_key), do: :__unknown_execution_policy_key__

  defp invalid_override(field, value) do
    policy_error(
      :invalid_override,
      field,
      value,
      "Invalid value for execution policy override #{inspect(field)}"
    )
  end

  defp policy_error(code, field, value, message) do
    {:error,
     %PolicyError{
       code: code,
       field: field,
       value: redacted_error_value(field, value),
       message: message
     }}
  end

  defp redacted_error_value(field, value) do
    field = String.downcase(field)

    if Enum.any?(@secret_field_fragments, &String.contains?(field, &1)),
      do: :redacted,
      else: value
  end
end
