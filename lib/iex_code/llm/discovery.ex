defmodule IexCode.LLM.Discovery do
  @moduledoc """
  Zero-config auto-discovery for local LLM inference engines (Ollama, LM Studio, llama.cpp).
  Provides concurrent, non-blocking probes and model normalization.
  """
  require Logger

  @default_connect_timeout 400
  @default_receive_timeout 800

  @targets [
    %{
      id: "ollama",
      name: "Ollama",
      port: 11434,
      base_url: "http://localhost:11434/v1",
      probe_url: "http://localhost:11434/api/tags",
      version_url: "http://localhost:11434/api/version"
    },
    %{
      id: "lm_studio",
      name: "LM Studio",
      port: 1234,
      base_url: "http://localhost:1234/v1",
      probe_url: "http://localhost:1234/v1/models",
      version_url: nil
    },
    %{
      id: "llama_cpp",
      name: "llama.cpp",
      port: 8080,
      base_url: "http://localhost:8080/v1",
      probe_url: "http://localhost:8080/v1/models",
      health_url: "http://localhost:8080/health",
      version_url: nil
    }
  ]

  @doc "Returns the default probe targets."
  def targets, do: @targets

  @doc """
  Checks if a URL points to a local loopback endpoint (localhost, 127.0.0.1, ::1, 0.0.0.0).
  """
  def is_local_endpoint?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) ->
        normalized = String.downcase(host)
        normalized in ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

      _ ->
        false
    end
  end

  def is_local_endpoint?(_), do: false

  @doc """
  Checks if a provider identifier represents a local inference engine.
  """
  def is_local_provider?(provider) when provider in ["ollama", "lm_studio", "llama_cpp"], do: true
  def is_local_provider?(provider) when provider in [:ollama, :lm_studio, :llama_cpp], do: true
  def is_local_provider?(_), do: false

  @doc """
  Returns the default base URL for a local provider.
  """
  def default_base_url("ollama"), do: "http://localhost:11434/v1"
  def default_base_url("lm_studio"), do: "http://localhost:1234/v1"
  def default_base_url("llama_cpp"), do: "http://localhost:8080/v1"
  def default_base_url(:ollama), do: "http://localhost:11434/v1"
  def default_base_url(:lm_studio), do: "http://localhost:1234/v1"
  def default_base_url(:llama_cpp), do: "http://localhost:8080/v1"
  def default_base_url(_), do: nil

  @doc """
  Probes all target inference engines concurrently without blocking.
  Returns `{:ok, [server_result]}`.
  """
  @spec probe_all(keyword()) :: {:ok, [map()]}
  def probe_all(opts \\ []) do
    target_list = Keyword.get(opts, :targets, @targets)
    timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    tasks =
      Enum.map(target_list, fn target ->
        Task.async(fn ->
          probe_target(target, opts)
        end)
      end)

    results = Task.await_many(tasks, timeout + 500)
    {:ok, results}
  rescue
    e ->
      Logger.debug("LLM probe_all exception: #{inspect(e)}")
      fallback = Enum.map(@targets, &offline_result(&1, :timeout, nil))
      {:ok, fallback}
  end

  @doc """
  Scans all local inference engines and returns a map keyed by atom provider.
  Conforms to the specification in PROJECT.md:
  `%{ollama: %{online?: boolean(), models: list()}, lm_studio: %{...}, llama_cpp: %{...}}`.
  """
  @spec scan(keyword()) :: %{
          optional(:ollama) => map(),
          optional(:lm_studio) => map(),
          optional(:llama_cpp) => map()
        }
  def scan(opts \\ []) do
    {:ok, results} = probe_all(opts)

    Map.new(results, fn server ->
      provider_atom =
        case server.provider do
          "ollama" -> :ollama
          "lm_studio" -> :lm_studio
          "llama_cpp" -> :llama_cpp
          other -> String.to_atom(other)
        end

      {provider_atom,
       %{
         online?: server.online,
         online: server.online,
         models: server.models,
         version: server.version,
         latency_ms: server.latency_ms,
         port: server.port,
         base_url: server.base_url,
         error: server.error
       }}
    end)
  end

  @doc """
  Pings a provider endpoint (cloud or local) and returns latency, model count, and status.
  Returns `{:ok, %{latency_ms: integer(), model_count: integer(), status: :online}}` or `{:error, reason}`.
  """
  @spec ping(String.t() | atom(), map() | struct() | nil, keyword()) ::
          {:ok, %{latency_ms: integer(), model_count: integer(), status: :online}}
          | {:error, any()}
  def ping(provider, settings \\ nil, opts \\ []) do
    provider_str = to_string(provider)

    cond do
      is_local_provider?(provider_str) ->
        target =
          Enum.find(@targets, &(&1.id == provider_str)) ||
            %{
              id: provider_str,
              name: provider_str,
              port: 0,
              base_url: Keyword.get(opts, :base_url, default_base_url(provider_str)),
              probe_url:
                Keyword.get(
                  opts,
                  :probe_url,
                  Keyword.get(opts, :base_url, default_base_url(provider_str)) <> "/models"
                ),
              version_url: nil
            }

        target =
          if base = Keyword.get(opts, :base_url) do
            %{target | base_url: base, probe_url: String.trim_trailing(base, "/") <> "/models"}
          else
            target
          end

        server = probe_target(target, opts)

        if server.online do
          {:ok,
           %{
             latency_ms: server.latency_ms,
             model_count: length(server.models),
             status: :online
           }}
        else
          {:error, server.error || :offline}
        end

      provider_str == "openai" ->
        base_url =
          Keyword.get(opts, :base_url) ||
            settings_value(settings, :openai_base_url, "https://cli.llmotions.com/v1")

        api_key =
          Keyword.get(opts, :api_key) ||
            settings_value(settings, :openai_api_key, nil)

        url = String.trim_trailing(base_url, "/") <> "/models"
        headers = [{"accept", "application/json"}]

        headers =
          if is_binary(api_key) and api_key != "" do
            [{"authorization", "Bearer " <> api_key} | headers]
          else
            headers
          end

        ping_http_endpoint(url, headers, opts)

      provider_str == "anthropic" ->
        base_url =
          Keyword.get(opts, :base_url) ||
            settings_value(settings, :anthropic_base_url, "https://api.anthropic.com")

        api_key =
          Keyword.get(opts, :api_key) ||
            settings_value(settings, :anthropic_api_key, nil)

        url = String.trim_trailing(base_url, "/") <> "/v1/models"

        headers = [
          {"accept", "application/json"},
          {"anthropic-version", "2023-06-01"}
        ]

        headers =
          if is_binary(api_key) and api_key != "" do
            [{"x-api-key", api_key} | headers]
          else
            headers
          end

        ping_http_endpoint(url, headers, opts)

      provider_str in ["gemini", "google"] ->
        base_url = Keyword.get(opts, :base_url, "https://generativelanguage.googleapis.com")
        url = String.trim_trailing(base_url, "/") <> "/v1beta/models"
        headers = [{"accept", "application/json"}]
        ping_http_endpoint(url, headers, opts)

      true ->
        {:error, :unsupported_provider}
    end
  end

  @doc """
  Pings a provider by provider name, base URL, and API key.
  Returns `{:ok, latency_ms, models}` or `{:error, reason, latency_ms}`.
  """
  def ping_provider(provider, base_url, api_key) do
    opts = [base_url: base_url, api_key: api_key]

    case ping(provider, nil, opts) do
      {:ok, %{latency_ms: ms}} ->
        {:ok, ms, []}

      {:error, reason} ->
        {:error, reason, 0}
    end
  end

  @doc """
  Probes a single target inference engine.
  """
  @spec probe_target(map(), keyword()) :: map()
  def probe_target(target, opts \\ []) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    req_opts =
      [
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false,
        headers: [{"accept", "application/json"}]
      ]
      |> maybe_put_plug(opts)

    {time_us, result} =
      :timer.tc(fn ->
        try do
          do_probe(target, req_opts)
        rescue
          err -> {:error, err}
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    latency_ms = max(div(time_us, 1000), 1)

    case result do
      {:ok, models, version} ->
        %{
          provider: target.id,
          name: target.name,
          port: target.port,
          base_url: target.base_url,
          online: true,
          models: models,
          version: version,
          latency_ms: latency_ms,
          error: nil
        }

      {:error, reason} ->
        offline_result(target, format_error(reason), latency_ms)
    end
  end

  @doc """
  Flattens and deduplicates models discovered across online servers.
  """
  def discovered_models(servers) when is_list(servers) do
    servers
    |> Enum.filter(& &1.online)
    |> Enum.flat_map(& &1.models)
    |> Enum.uniq_by(&{&1.provider, &1.id})
  end

  def discovered_models(_), do: []

  # --- Target-Specific Probe Handlers ---

  defp do_probe(%{id: "ollama"} = target, req_opts) do
    case Req.get(target.probe_url, req_opts) do
      {:ok, %{status: 200, body: %{"models" => raw_models}}} when is_list(raw_models) ->
        models = Enum.map(raw_models, &parse_ollama_model(&1, target))
        version = fetch_version(target.version_url, req_opts)
        {:ok, models, version}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        raw_models = Map.get(body, "models", [])
        models = Enum.map(raw_models, &parse_ollama_model(&1, target))
        version = fetch_version(target.version_url, req_opts)
        {:ok, models, version}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_probe(%{id: "lm_studio"} = target, req_opts) do
    case Req.get(target.probe_url, req_opts) do
      {:ok, %{status: 200, body: %{"data" => raw_models}}} when is_list(raw_models) ->
        models = Enum.map(raw_models, &parse_lm_studio_model(&1, target))
        {:ok, models, nil}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        raw_models = Map.get(body, "data", [])
        models = Enum.map(raw_models, &parse_lm_studio_model(&1, target))
        {:ok, models, nil}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_probe(%{id: "llama_cpp"} = target, req_opts) do
    case Req.get(target.probe_url, req_opts) do
      {:ok, %{status: 200, body: %{"data" => raw_models}}}
      when is_list(raw_models) and raw_models != [] ->
        models = Enum.map(raw_models, &parse_llama_cpp_model(&1, target))
        {:ok, models, nil}

      _fallback ->
        # If /v1/models returned empty or not found, try /health
        health_url = Map.get(target, :health_url, "http://localhost:8080/health")

        case Req.get(health_url, req_opts) do
          {:ok, %{status: 200}} ->
            default_model = %{
              id: "default",
              name: "default",
              provider: "llama_cpp",
              server_name: target.name,
              port: target.port,
              base_url: target.base_url,
              parameter_size: nil,
              quantization: nil,
              size_bytes: nil,
              format: "gguf"
            }

            {:ok, [default_model], nil}

          {:ok, %{status: status}} ->
            {:error, {:unexpected_status, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Model Parsers ---

  defp parse_ollama_model(raw, target) do
    id = raw["name"] || raw["model"] || ""
    details = raw["details"] || %{}

    %{
      id: id,
      name: id,
      provider: "ollama",
      server_name: target.name,
      port: target.port,
      base_url: target.base_url,
      parameter_size: details["parameter_size"],
      quantization: details["quantization_level"],
      size_bytes: raw["size"],
      format: details["format"] || "gguf"
    }
  end

  defp parse_lm_studio_model(raw, target) do
    id = raw["id"] || ""

    %{
      id: id,
      name: id,
      provider: "lm_studio",
      server_name: target.name,
      port: target.port,
      base_url: target.base_url,
      parameter_size: raw["arch"],
      quantization: raw["quantization"],
      size_bytes: nil,
      format: raw["compatibility_type"] || "gguf"
    }
  end

  defp parse_llama_cpp_model(raw, target) do
    id = raw["id"] || "default"

    %{
      id: id,
      name: id,
      provider: "llama_cpp",
      server_name: target.name,
      port: target.port,
      base_url: target.base_url,
      parameter_size: nil,
      quantization: nil,
      size_bytes: nil,
      format: "gguf"
    }
  end

  defp fetch_version(nil, _req_opts), do: nil

  defp fetch_version(url, req_opts) do
    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: %{"version" => v}}} when is_binary(v) -> v
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_put_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) || Application.get_env(:iex_code, :discovery_req_plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp format_error(%Req.TransportError{reason: reason}), do: reason
  defp format_error(%{reason: reason}), do: reason
  defp format_error(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp format_error({:unexpected_status, status}), do: {:unexpected_status, status}
  defp format_error(_), do: :error

  defp ping_http_endpoint(url, headers, opts) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    req_opts =
      [
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false,
        headers: headers
      ]
      |> maybe_put_plug(opts)

    {time_us, result} =
      :timer.tc(fn ->
        try do
          Req.get(url, req_opts)
        rescue
          err -> {:error, err}
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    latency_ms = max(div(time_us, 1000), 1)

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        model_count =
          cond do
            is_map(body) and is_list(body["data"]) -> length(body["data"])
            is_map(body) and is_list(body["models"]) -> length(body["models"])
            is_list(body) -> length(body)
            true -> 1
          end

        {:ok, %{latency_ms: latency_ms, model_count: model_count, status: :online}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp settings_value(settings, key, default) when is_struct(settings) or is_map(settings) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key)) || default
  end

  defp settings_value(_settings, _key, default), do: default

  defp offline_result(target, reason, latency_ms) do
    %{
      provider: target.id,
      name: target.name,
      port: target.port,
      base_url: target.base_url,
      online: false,
      models: [],
      version: nil,
      latency_ms: latency_ms,
      error: reason
    }
  end
end
