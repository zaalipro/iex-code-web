defmodule IexCode.Execution.ModelRoute do
  @moduledoc """
  Secret-free identity and execution-time resolution for durable model routes.

  Durable policies persist only a SHA-256 digest of the effective provider,
  model, and base URL. Credentials remain live so they can be rotated, but the
  non-secret transport route must still match immediately before every model
  effect.
  """

  alias IexCode.Execution.Limits
  alias IexCode.LLM

  @openai_default "https://cli.llmotions.com/v1"
  @anthropic_default "https://api.anthropic.com"
  @digest_key "model_route_sha256"

  @spec put_digest(map(), map() | struct()) :: {:ok, map()} | {:error, term()}
  def put_digest(policy, settings) when is_map(policy) and is_map(settings) do
    with {:ok, projection} <- projection(policy, settings),
         {:ok, digest} <- digest(projection) do
      {:ok, Map.put(policy, @digest_key, digest)}
    end
  end

  def put_digest(_policy, _settings), do: {:error, :invalid_model_route}

  @doc """
  Resolves current credentials only after the non-secret durable route matches.

  Policies created before route digests were introduced remain executable for
  backwards compatibility; every newly normalized policy includes a digest.
  """
  @spec resolve(map(), map() | struct()) :: {:ok, map()} | {:error, term()}
  def resolve(_policy, %IexCode.Settings.AppSettings{__meta__: %{state: state}})
      when state in [:built, :deleted],
      do: {:error, :settings_unavailable}

  def resolve(policy, settings) when is_map(policy) and is_map(settings) do
    with {:ok, projection} <- projection(policy, settings),
         {:ok, current_digest} <- digest(projection),
         :ok <- validate_expected_digest(value(policy, @digest_key), current_digest) do
      provider = projection["provider"]

      {:ok,
       %{
         "provider" => provider,
         "model" => projection["model"],
         "base_url" => projection["base_url"],
         "api_key" => credential(settings, provider),
         "temperature" => numeric(value(policy, "temperature"), 0.2),
         "max_tokens" => integer(value(policy, "max_tokens"), 4_096)
       }}
    end
  end

  def resolve(_policy, _settings), do: {:error, :invalid_model_route}

  def digest_key, do: @digest_key

  defp projection(policy, settings) do
    selected_provider = value(policy, "model_provider")
    model = value(policy, "model_name")
    provider = LLM.effective_provider(selected_provider, model)
    base_url = base_url(settings, provider)

    cond do
      provider not in ["openai", "anthropic"] ->
        {:error, :invalid_model_route}

      not Limits.valid_model_name?(model) ->
        {:error, :invalid_model_route}

      not valid_base_url?(base_url) ->
        {:error, :invalid_model_route}

      true ->
        {:ok, %{"version" => 1, "provider" => provider, "model" => model, "base_url" => base_url}}
    end
  end

  defp digest(projection) do
    with {:ok, canonical} <- IexCode.Runs.DagPayload.canonical_json(projection) do
      {:ok,
       :crypto.hash(:sha256, "iex-code/model-route/v1\0" <> canonical)
       |> Base.encode16(case: :lower)}
    else
      _error -> {:error, :invalid_model_route}
    end
  end

  defp validate_expected_digest(nil, _current), do: :ok

  defp validate_expected_digest(expected, current)
       when is_binary(expected) and byte_size(expected) == 64 do
    if Plug.Crypto.secure_compare(expected, current),
      do: :ok,
      else: {:error, :model_route_configuration_changed}
  end

  defp validate_expected_digest(_expected, _current), do: {:error, :invalid_model_route_digest}

  defp base_url(settings, "openai"),
    do: normalize_url(value(settings, "openai_base_url") || @openai_default)

  defp base_url(settings, "anthropic"),
    do: normalize_url(value(settings, "anthropic_base_url") || @anthropic_default)

  defp credential(settings, "openai"), do: value(settings, "openai_api_key")
  defp credential(settings, "anthropic"), do: value(settings, "anthropic_api_key")

  defp normalize_url(url) when is_binary(url), do: String.trim_trailing(String.trim(url), "/")
  defp normalize_url(_url), do: nil

  defp valid_base_url?(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  defp numeric(value, _fallback) when is_number(value), do: value * 1.0
  defp numeric(_value, fallback), do: fallback
  defp integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp integer(_value, fallback), do: fallback

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom(key))
  end

  defp known_atom("model_provider"), do: :model_provider
  defp known_atom("model_name"), do: :model_name
  defp known_atom("temperature"), do: :temperature
  defp known_atom("max_tokens"), do: :max_tokens
  defp known_atom("model_route_sha256"), do: :model_route_sha256
  defp known_atom("openai_base_url"), do: :openai_base_url
  defp known_atom("anthropic_base_url"), do: :anthropic_base_url
  defp known_atom("openai_api_key"), do: :openai_api_key
  defp known_atom("anthropic_api_key"), do: :anthropic_api_key
  defp known_atom(_key), do: :__unknown_model_route_key__
end
