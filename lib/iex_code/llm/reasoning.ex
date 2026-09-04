defmodule IexCode.LLM.Reasoning do
  @moduledoc """
  Resolves effective reasoning configuration by combining global defaults,
  model override matrix, session settings, and turn-level options.
  Constructs native provider payloads honoring provider parameter invariants.
  """

  alias IexCode.LLM.Capabilities
  alias IexCode.Settings.AppSettings

  @doc """
  Resolves the effective reasoning profile for a provider and model.
  Returns a map with `:reasoning_effort`, `:thinking_budget`, `:budget_tokens`,
  `:temperature`, `:max_tokens`, and `:capabilities`.
  """
  def resolve_profile(provider, model, settings \\ nil, opts \\ []) do
    caps = Capabilities.detect(provider, model)
    overrides = get_model_override(settings, model)
    opts_map = normalize_opts(opts)

    raw_effort =
      opts_map[:reasoning_effort] ||
        opts_map["reasoning_effort"] ||
        Map.get(overrides, "reasoning_effort") ||
        Map.get(overrides, :reasoning_effort) ||
        settings_value(settings, :default_reasoning_effort, "medium")

    raw_budget =
      opts_map[:thinking_budget] ||
        opts_map["thinking_budget"] ||
        opts_map[:budget_tokens] ||
        opts_map["budget_tokens"] ||
        Map.get(overrides, "budget_tokens") ||
        Map.get(overrides, "thinking_budget") ||
        Map.get(overrides, :budget_tokens) ||
        settings_value(settings, :default_thinking_budget, 4096)

    budget_val = parse_integer(raw_budget, 4096)

    raw_max_tokens =
      opts_map[:max_tokens] ||
        opts_map["max_tokens"] ||
        Map.get(overrides, "max_tokens") ||
        Map.get(overrides, :max_tokens) ||
        settings_value(settings, :max_tokens, 4096)

    max_tokens_val = parse_integer(raw_max_tokens, 4096)

    raw_temp =
      opts_map[:temperature] ||
        opts_map["temperature"] ||
        Map.get(overrides, "temperature") ||
        Map.get(overrides, :temperature) ||
        settings_value(settings, :temperature, 0.2)

    temp_val = parse_float(raw_temp, 0.2)

    {effective_temp, effective_max_tokens, effective_budget, effective_effort} =
      case caps.type do
        :openai ->
          # OpenAI reasoning models (o1, o3, o4) reject temperature.
          effort = normalize_openai_effort(raw_effort)
          {nil, max_tokens_val, nil, effort}

        :anthropic ->
          # Anthropic extended thinking (Claude 3.7 Sonnet+)
          effort_str = to_string(raw_effort || "medium")

          if effort_str in ["none", ""] and
               is_nil(opts_map[:budget_tokens]) and is_nil(opts_map["budget_tokens"]) and
               is_nil(opts_map[:thinking_budget]) and is_nil(opts_map["thinking_budget"]) and
               is_nil(Map.get(overrides, "budget_tokens")) do
            {temp_val, max_tokens_val, nil, "none"}
          else
            # When thinking is enabled, temperature MUST be clamped to 1.0
            # and max_tokens must be strictly greater than budget_tokens (budget >= 1024).
            clamped_budget = max(budget_val, caps.min_budget || 1024)
            clamped_max = max(max_tokens_val, clamped_budget + 1024)
            {1.0, clamped_max, clamped_budget, effort_str}
          end

        :gemini ->
          effort_str = to_string(raw_effort || "medium")

          if effort_str in ["none", ""] do
            {temp_val, max_tokens_val, 0, "none"}
          else
            clamped_budget = max(budget_val, 1024)
            clamped_max = max(max_tokens_val, clamped_budget + 1024)
            {temp_val, clamped_max, clamped_budget, effort_str}
          end

        :local ->
          # Local / DeepSeek R1 models
          temp =
            if temp_val in [0.0, 0.2] and not has_explicit_temp?(opts_map, overrides),
              do: 0.6,
              else: temp_val

          clamped_budget = max(budget_val, 2048)
          {temp, max_tokens_val, clamped_budget, to_string(raw_effort || "medium")}

        :none ->
          {temp_val, max_tokens_val, nil, nil}
      end

    %{
      provider: provider,
      model: model,
      reasoning_effort: effective_effort,
      thinking_budget: effective_budget,
      budget_tokens: effective_budget,
      temperature: effective_temp,
      max_tokens: effective_max_tokens,
      capabilities: caps
    }
  end

  @doc """
  Constructs the exact native JSON payload for a given provider, model, messages,
  system prompt, and reasoning profile.
  """
  def serialize_payload(provider, model, messages, system_prompt, settings \\ nil, opts \\ []) do
    profile = resolve_profile(provider, model, settings, opts)
    tools = Keyword.get(opts, :tools, [])
    stream? = Keyword.get(opts, :stream, true)

    formatted_messages =
      format_messages_for_provider(profile.capabilities.type, messages, system_prompt)

    case profile.capabilities.type do
      :openai ->
        build_openai_payload(profile, formatted_messages, tools, stream?)

      :anthropic ->
        build_anthropic_payload(profile, formatted_messages, system_prompt, tools, stream?)

      :gemini when provider in ["gemini", "google"] ->
        build_gemini_native_payload(profile, formatted_messages, system_prompt, tools)

      :local ->
        build_local_payload(profile, formatted_messages, tools, stream?)

      _ ->
        if provider == "anthropic" do
          build_anthropic_payload(profile, formatted_messages, system_prompt, tools, stream?)
        else
          build_standard_openai_payload(profile, formatted_messages, tools, stream?)
        end
    end
  end

  @doc "Retrieves the override map for a specific model name from settings."
  def get_model_override(%AppSettings{model_overrides: overrides}, model)
      when is_map(overrides) and is_binary(model) do
    Map.get(overrides, model) || Map.get(overrides, List.last(String.split(model, "/"))) || %{}
  end

  def get_model_override(%{model_overrides: overrides}, model)
      when is_map(overrides) and is_binary(model) do
    Map.get(overrides, model) || Map.get(overrides, List.last(String.split(model, "/"))) || %{}
  end

  def get_model_override(%{"model_overrides" => overrides}, model)
      when is_map(overrides) and is_binary(model) do
    Map.get(overrides, model) || Map.get(overrides, List.last(String.split(model, "/"))) || %{}
  end

  def get_model_override(_settings, _model), do: %{}

  # --- Payload Builders ---

  defp build_openai_payload(profile, messages, tools, stream?) do
    base = %{
      "model" => profile.model,
      "messages" => messages,
      "max_completion_tokens" => profile.max_tokens
    }

    base
    |> put_optional("reasoning_effort", profile.reasoning_effort)
    |> put_tools_openai(tools)
    |> put_stream(stream?)
  end

  defp build_standard_openai_payload(profile, messages, tools, stream?) do
    base = %{
      "model" => profile.model,
      "messages" => messages,
      "temperature" => profile.temperature,
      "max_tokens" => profile.max_tokens
    }

    base
    |> put_tools_openai(tools)
    |> put_stream(stream?)
  end

  defp build_anthropic_payload(profile, messages, system_prompt, tools, stream?) do
    body = %{
      "model" => profile.model,
      "max_tokens" => profile.max_tokens,
      "messages" => messages
    }

    body =
      if profile.thinking_budget && profile.thinking_budget > 0 do
        body
        |> Map.put("temperature", 1.0)
        |> Map.put("thinking", %{
          "type" => "enabled",
          "budget_tokens" => profile.thinking_budget
        })
      else
        Map.put(body, "temperature", profile.temperature || 0.2)
      end

    body
    |> put_system_anthropic(system_prompt)
    |> put_tools_anthropic(tools)
    |> put_stream(stream?)
  end

  defp build_gemini_native_payload(profile, messages, system_prompt, _tools) do
    thinking_config =
      if profile.thinking_budget && profile.thinking_budget > 0 do
        %{"thinkingBudget" => profile.thinking_budget}
      else
        %{"thinkingBudget" => 0}
      end

    %{
      "contents" =>
        Enum.map(messages, fn m ->
          role = if m["role"] == "assistant", do: "model", else: "user"
          %{"role" => role, "parts" => [%{"text" => m["content"] || ""}]}
        end),
      "generationConfig" => %{
        "temperature" => profile.temperature || 0.7,
        "maxOutputTokens" => profile.max_tokens,
        "thinkingConfig" => thinking_config
      }
    }
    |> put_gemini_system(system_prompt)
  end

  defp build_local_payload(profile, messages, tools, stream?) do
    body = build_standard_openai_payload(profile, messages, tools, stream?)

    Map.put(body, "options", %{
      "num_ctx" => 16_384,
      "temperature" => profile.temperature || 0.6
    })
  end

  # --- Message Formatting Helpers ---

  defp format_messages_for_provider(:anthropic, messages, _system_prompt) do
    messages
    |> Enum.map(&format_anthropic_message/1)
    |> merge_consecutive_anthropic_roles()
  end

  defp format_messages_for_provider(_other, messages, system_prompt) do
    sys =
      if system_prompt in [nil, ""] do
        []
      else
        [%{"role" => "system", "content" => system_prompt}]
      end

    sys ++ Enum.map(messages, &format_openai_message/1)
  end

  defp format_openai_message(%{role: r, content: c}),
    do: %{"role" => to_string(r), "content" => c}

  defp format_openai_message(%{"role" => _r} = m), do: m
  defp format_openai_message(other), do: %{"role" => "user", "content" => to_string(other)}

  defp format_anthropic_message(%{role: "assistant"} = m) do
    %{"role" => "assistant", "content" => Map.get(m, :content) || Map.get(m, "content")}
  end

  defp format_anthropic_message(%{role: _r, content: c}) do
    %{"role" => "user", "content" => c}
  end

  defp format_anthropic_message(%{"role" => "assistant"} = m), do: m

  defp format_anthropic_message(%{"role" => _r} = m),
    do: %{"role" => "user", "content" => m["content"]}

  defp format_anthropic_message(other), do: %{"role" => "user", "content" => to_string(other)}

  defp merge_consecutive_anthropic_roles(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce([], fn
      msg, [%{"role" => role} = prev | rest] ->
        if role == msg["role"] do
          [
            %{
              "role" => role,
              "content" => to_string(prev["content"]) <> "\n\n" <> to_string(msg["content"])
            }
            | rest
          ]
        else
          [msg | [prev | rest]]
        end

      msg, acc ->
        [msg | acc]
    end)
  end

  # --- Payload Utility Helpers ---

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, val), do: Map.put(map, key, val)

  defp put_stream(map, true), do: Map.put(map, "stream", true)
  defp put_stream(map, _), do: map

  defp put_tools_openai(map, []), do: map

  defp put_tools_openai(map, tools) when is_list(tools) do
    openai_tools =
      Enum.map(tools, fn
        %{name: name, description: desc, parameters: params} ->
          %{
            "type" => "function",
            "function" => %{"name" => name, "description" => desc, "parameters" => params}
          }

        %{"name" => _} = t ->
          %{"type" => "function", "function" => t}

        t ->
          t
      end)

    Map.put(map, "tools", openai_tools)
  end

  defp put_tools_anthropic(map, []), do: map

  defp put_tools_anthropic(map, tools) when is_list(tools) do
    anthropic_tools =
      Enum.map(tools, fn
        %{name: name, description: desc, parameters: params} ->
          %{"name" => name, "description" => desc, "input_schema" => params}

        %{"name" => _name, "input_schema" => _} = t ->
          t

        %{"name" => name, "description" => desc, "parameters" => params} ->
          %{"name" => name, "description" => desc, "input_schema" => params}

        t ->
          t
      end)

    Map.put(map, "tools", anthropic_tools)
  end

  defp put_system_anthropic(map, prompt) when prompt in [nil, ""], do: map
  defp put_system_anthropic(map, prompt), do: Map.put(map, "system", prompt)

  defp put_gemini_system(map, prompt) when prompt in [nil, ""], do: map

  defp put_gemini_system(map, prompt) do
    Map.put(map, "systemInstruction", %{"parts" => [%{"text" => prompt}]})
  end

  defp normalize_openai_effort(effort) do
    case to_string(effort || "medium") do
      "low" -> "low"
      "medium" -> "medium"
      "high" -> "high"
      "max" -> "high"
      "none" -> nil
      _ -> "medium"
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp has_explicit_temp?(opts_map, overrides) do
    Map.has_key?(opts_map, :temperature) or
      Map.has_key?(opts_map, "temperature") or
      Map.has_key?(overrides, "temperature") or
      Map.has_key?(overrides, :temperature)
  end

  defp settings_value(nil, _key, default), do: default

  defp settings_value(settings, key, default) when is_struct(settings) or is_map(settings) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key)) || default
  end

  defp parse_integer(val, _default) when is_integer(val), do: val

  defp parse_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_integer(_val, default), do: default

  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val * 1.0

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {flt, ""} -> flt
      _ -> default
    end
  end

  defp parse_float(_val, default), do: default
end
