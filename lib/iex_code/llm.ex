defmodule IexCode.LLM do
  @moduledoc """
  Unified LLM gateway coordinating OpenAI, Anthropic, custom endpoints,
  and provider-specific exponential backoff resilience.

  There is no mock/local mode: a missing API key returns `{:error, :no_api_key}`
  and a provider failure returns an error — content is never fabricated.
  """
  alias IexCode.Execution.{Limits, ResourceGovernor}
  alias IexCode.Settings
  alias IexCode.LLM.{Anthropic, OpenAI, Resilience}

  @doc """
  Dispatches chat requests through the explicitly selected OpenAI or Anthropic
  protocol with retry resilience.

  ## Options
  - `:cancelled?` - zero-arg fun polled by the stream client between chunks; when
    truthy the stream aborts cleanly (forwarded to providers / `StreamClient`)
  - `:max_tokens` - overrides the provider default max token count
  - `:temperature` - overrides the session/settings temperature
  - `:on_retry` - fn (attempt, reason, sleep_ms) invoked by the resilience engine
    on every retry
  - `:receive_timeout` - HTTP receive timeout in ms forwarded to providers
  - `:resolved_route` - trusted execution-only provider/model/credential/endpoint
    route. When present, the gateway does not reread global settings.
  """
  def chat(messages, system_prompt, session, on_chunk \\ fn _c -> :ok end, opts \\ []) do
    permit_opts =
      ResourceGovernor.admission_opts(opts,
        priority: :interactive,
        run_key: session_run_key(session)
      )

    ResourceGovernor.with_permit(:llm_provider, permit_opts, fn ->
      dispatch_chat(messages, system_prompt, session, on_chunk, opts)
    end)
  end

  defp dispatch_chat(messages, system_prompt, session, on_chunk, opts) do
    case Keyword.pop(opts, :resolved_route) do
      {nil, opts} ->
        settings = Settings.get_settings()

        raw_provider =
          (session && session.model_provider) || settings.default_model_provider || "openai"

        raw_model =
          (session && session.model_name) || settings.default_model || "deepseek-v4-pro"

        if Limits.valid_model_name?(raw_model) do
          do_chat(
            messages,
            system_prompt,
            session,
            on_chunk,
            opts,
            settings,
            raw_provider,
            raw_model
          )
        else
          {:error, :invalid_model_name}
        end

      {route, opts} ->
        do_resolved_chat(messages, system_prompt, on_chunk, opts, route)
    end
  end

  defp session_run_key(%{id: id}) when is_binary(id), do: id
  defp session_run_key(_session), do: self()

  @doc "Returns the explicitly selected transport provider, with model-family inference only as a legacy fallback."
  def effective_provider(provider, model) do
    normalize_provider(provider) || provider_for_model(model)
  end

  defp do_chat(
         messages,
         system_prompt,
         session,
         on_chunk,
         opts,
         settings,
         raw_provider,
         raw_model
       ) do
    temperature =
      Keyword.get(opts, :temperature) || (session && session.temperature) || settings.temperature ||
        0.2

    tools = IexCode.Tools.tool_definitions(Keyword.get(opts, :allowed_tools, :all))
    max_tokens = Keyword.get(opts, :max_tokens) || settings.max_tokens

    # Provider selection is authoritative. Model identifiers are opaque to the
    # gateway because OpenAI-compatible endpoints can legitimately host models
    # whose names resemble another vendor's catalog.
    primary_provider = effective_provider(raw_provider, raw_model)

    passthrough_opts =
      opts
      |> Keyword.take([:cancelled?, :receive_timeout])
      |> Keyword.put(:max_tokens, max_tokens)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    openai_fn = fn ->
      OpenAI.chat(
        messages,
        system_prompt,
        [
          api_key: settings.openai_api_key,
          base_url: settings.openai_base_url || "https://cli.llmotions.com/v1",
          model: raw_model,
          temperature: temperature,
          tools: tools
        ] ++ passthrough_opts,
        on_chunk
      )
    end

    anthropic_fn = fn ->
      Anthropic.chat(
        messages,
        system_prompt,
        [
          api_key: settings.anthropic_api_key,
          base_url: settings.anthropic_base_url || "https://api.anthropic.com",
          model: raw_model,
          temperature: temperature,
          tools: tools
        ] ++ passthrough_opts,
        on_chunk
      )
    end

    providers =
      [
        {"openai", openai_fn, settings.openai_api_key},
        {"anthropic", anthropic_fn, settings.anthropic_api_key}
      ]
      |> Enum.filter(fn {name, _fn, key} ->
        present?(key) and provider_compatible?(name, primary_provider)
      end)
      |> Enum.sort_by(fn
        {^primary_provider, _fn, _key} -> 0
        {_other, _fn, _key} -> 1
      end)
      |> Enum.map(fn {name, fn_, _key} -> {name, fn_} end)

    cond do
      providers == [] ->
        {:error, :no_api_key}

      true ->
        case Resilience.with_fallback(providers,
               on_chunk: on_chunk,
               on_retry: Keyword.get(opts, :on_retry, fn _a, _r, _s -> :ok end)
             ) do
          {:ok, result, _meta} ->
            {:ok, result}

          {:ok, result} ->
            {:ok, result}

          {:error, {:all_providers_failed, errors}} ->
            first_err = List.first(errors) |> elem(1)
            {:error, first_err}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_resolved_chat(messages, system_prompt, on_chunk, opts, route) when is_map(route) do
    provider = route_value(route, :provider)
    model = route_value(route, :model)
    api_key = route_value(route, :api_key)
    base_url = route_value(route, :base_url)
    temperature = route_value(route, :temperature) || 0.2
    max_tokens = Keyword.get(opts, :max_tokens) || route_value(route, :max_tokens)

    with true <- provider in ["openai", "anthropic"] or {:error, :invalid_resolved_route},
         true <- Limits.valid_model_name?(model) or {:error, :invalid_resolved_route},
         true <- present?(api_key) or {:error, :no_api_key},
         true <- present?(base_url) or {:error, :invalid_resolved_route},
         true <- (is_integer(max_tokens) and max_tokens > 0) or {:error, :invalid_resolved_route} do
      tools = IexCode.Tools.tool_definitions(Keyword.get(opts, :allowed_tools, :all))

      passthrough_opts =
        opts
        |> Keyword.take([:cancelled?, :receive_timeout])
        |> Keyword.put(:max_tokens, max_tokens)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      callback = fn ->
        module = provider_module(provider)

        module.chat(
          messages,
          system_prompt,
          [
            api_key: api_key,
            base_url: base_url,
            model: model,
            temperature: temperature,
            tools: tools
          ] ++ passthrough_opts,
          on_chunk
        )
      end

      case Resilience.with_fallback([{provider, callback}],
             on_chunk: on_chunk,
             on_retry: Keyword.get(opts, :on_retry, fn _attempt, _reason, _sleep -> :ok end)
           ) do
        {:ok, result, _meta} -> {:ok, result}
        {:ok, result} -> {:ok, result}
        {:error, {:all_providers_failed, errors}} -> {:error, errors |> List.first() |> elem(1)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_resolved_route}
      {:error, _reason} = error -> error
    end
  end

  defp do_resolved_chat(_messages, _system_prompt, _on_chunk, _opts, _route),
    do: {:error, :invalid_resolved_route}

  defp blank?(key), do: is_nil(key) or key == ""
  defp present?(key), do: not blank?(key)

  defp provider_for_model(model) when is_binary(model) do
    normalized = String.downcase(model)

    cond do
      String.starts_with?(normalized, "claude") -> "anthropic"
      String.starts_with?(normalized, ["gpt", "gemini", "o1", "o3", "o4"]) -> "openai"
      true -> nil
    end
  end

  defp provider_for_model(_model), do: nil

  defp normalize_provider(provider) when provider in ["openai", "anthropic"], do: provider

  defp normalize_provider(provider) when provider in [:openai, :anthropic],
    do: Atom.to_string(provider)

  defp normalize_provider(_provider), do: nil

  defp provider_module("openai"), do: OpenAI
  defp provider_module("anthropic"), do: Anthropic

  defp route_value(route, key) do
    Map.get(route, key, Map.get(route, Atom.to_string(key)))
  end

  defp provider_compatible?(provider, selected_provider), do: provider == selected_provider
end
