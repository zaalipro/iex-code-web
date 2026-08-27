defmodule IexCode.Research.HTTP do
  @moduledoc false

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Research.URLGuard

  @max_body_bytes 2_000_000
  @timeout 15_000
  @max_error_string_bytes 4_000
  @max_error_collection_items 50
  @max_error_depth 8

  def request(method, url, opts) do
    permit_opts = ResourceGovernor.admission_opts(opts, priority: :background)

    ResourceGovernor.with_permit(:research_fetch, permit_opts, fn ->
      do_request(method, url, opts)
    end)
  end

  defp do_request(method, url, opts) do
    secret = Keyword.get(opts, :api_key)

    result =
      try do
        request = Keyword.get(opts, :request, &default_request/1)

        request_opts =
          opts
          |> Keyword.drop([
            :request,
            :base_url,
            :limit,
            :api_key,
            :enabled,
            :cx,
            :engine_id,
            :engine,
            :country,
            :language,
            :search_depth,
            :location,
            :safe,
            :include_domains,
            :exclude_domains,
            :start_date,
            :end_date,
            :search_after_date,
            :search_before_date,
            :recency,
            :resource_governor,
            :resource_priority,
            :resource_run_key,
            :resource_timeout
          ])
          |> Keyword.put(:method, method)
          |> Keyword.put(:url, url)
          |> Keyword.put(:redirect, false)
          |> Keyword.put(:retry, false)
          |> Keyword.put(:decode_body, false)
          |> Keyword.put(:compressed, false)
          |> Keyword.put_new(:receive_timeout, @timeout)
          |> Keyword.put_new(:connect_options, timeout: @timeout)
          |> Keyword.put(:into, body_collector(@max_body_bytes))

        response =
          cond do
            is_function(request, 1) ->
              request.(request_opts)

            is_function(request, 3) ->
              request.(method, url, Keyword.drop(request_opts, [:method, :url]))

            true ->
              {:error, :invalid_request_function}
          end

        normalize_response(response)
      rescue
        exception -> {:error, {:request_exception, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {:request_failure, kind, reason}}
      end

    sanitize_error(result, secret)
  end

  def endpoint(opts, default, path) do
    case Keyword.get(opts, :base_url) do
      nil ->
        default

      base ->
        validate_endpoint!(base, default, Keyword.get(opts, :allow_custom_endpoint, false))
        base = String.trim_trailing(base, "/")
        path = "/" <> String.trim(path, "/")
        if String.ends_with?(base, path), do: base, else: base <> path
    end
  end

  def limit(opts), do: opts |> Keyword.get(:limit, 10) |> min(50) |> max(1)

  defp default_request(opts) do
    url = Keyword.fetch!(opts, :url)

    with {:ok, target} <- URLGuard.validate_and_resolve(url) do
      pinned_uri = %{target.uri | host: target.address |> :inet.ntoa() |> to_string()}

      connect_options =
        opts
        |> Keyword.get(:connect_options, [])
        |> Keyword.put(:hostname, target.uri.host)

      opts
      |> Keyword.put(:url, URI.to_string(pinned_uri))
      |> Keyword.put(:connect_options, connect_options)
      |> IexCode.HTTP.pinned_request()
    end
  end

  defp body_collector(limit) do
    fn {:data, chunk}, {request, response} ->
      body = Req.Response.get_private(response, :iex_code_provider_body, "")
      remaining = limit - byte_size(body)

      if byte_size(chunk) > remaining do
        response =
          response
          |> Req.Response.put_private(
            :iex_code_provider_body,
            body <> binary_part(chunk, 0, max(remaining, 0))
          )
          |> Req.Response.put_private(:iex_code_provider_body_exceeded, true)

        {:halt, {request, response}}
      else
        response = Req.Response.put_private(response, :iex_code_provider_body, body <> chunk)
        {:cont, {request, response}}
      end
    end
  end

  defp normalize_response({:ok, %Req.Response{} = response}), do: normalize_response(response)

  defp normalize_response(%Req.Response{} = response) do
    if Req.Response.get_private(response, :iex_code_provider_body_exceeded, false) do
      {:error, :response_too_large}
    else
      body = Req.Response.get_private(response, :iex_code_provider_body, response.body)

      with :ok <- ensure_body_size(body),
           true <- is_binary(body) || {:error, :invalid_response_body},
           {:ok, decoded} <- decode_body(body, response.headers) do
        normalize_response(%{status: response.status, body: decoded})
      end
    end
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    with :ok <- ensure_body_size(body), do: {:ok, body}
  end

  defp normalize_response({:ok, %{status: status, body: body}}) do
    case ensure_body_size(body) do
      :ok -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, {:http_error, status, reason}}
    end
  end

  defp normalize_response({:error, reason}), do: {:error, reason}

  defp normalize_response(%{status: status, body: body}),
    do: normalize_response({:ok, %{status: status, body: body}})

  defp normalize_response(other), do: {:error, {:invalid_response, other}}

  defp decode_body(body, headers) do
    content_type =
      headers
      |> Enum.find_value("", fn {key, values} ->
        if String.downcase(to_string(key)) == "content-type", do: List.first(List.wrap(values))
      end)
      |> to_string()
      |> String.downcase()

    if String.contains?(content_type, "json") or
         String.starts_with?(String.trim(body), ["{", "["]) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    else
      {:ok, String.replace_invalid(body)}
    end
  end

  defp ensure_body_size(body) when is_binary(body) do
    if byte_size(body) <= @max_body_bytes, do: :ok, else: {:error, :response_too_large}
  end

  defp ensure_body_size(body) do
    if :erlang.external_size(body) <= @max_body_bytes,
      do: :ok,
      else: {:error, :response_too_large}
  rescue
    _exception -> {:error, :invalid_response_body}
  end

  defp validate_endpoint!(base, _default, true) do
    validate_uri!(base)
    :ok
  end

  defp validate_endpoint!(base, default, false) do
    base_uri = validate_uri!(base)
    default_uri = validate_uri!(default)

    unless base_uri.scheme == "https" and base_uri.host == default_uri.host and
             effective_port(base_uri) == effective_port(default_uri) do
      raise ArgumentError, "provider base URL must use its official HTTPS origin"
    end
  end

  defp validate_uri!(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri

      _ ->
        raise ArgumentError, "invalid provider base URL"
    end
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80

  defp sanitize_error({:error, reason}, secret),
    do: {:error, sanitize_error_value(reason, secret, @max_error_depth)}

  defp sanitize_error(result, _secret), do: result

  defp sanitize_error_value(_value, _secret, 0), do: :truncated

  defp sanitize_error_value(value, secret, _depth) when is_binary(value) do
    value
    |> redact_secret(secret)
    |> truncate_binary(@max_error_string_bytes)
  end

  defp sanitize_error_value(value, secret, depth) when is_map(value) do
    value
    |> Enum.take(@max_error_collection_items)
    |> Map.new(fn {key, nested} ->
      {sanitize_error_value(key, secret, depth - 1),
       sanitize_error_value(nested, secret, depth - 1)}
    end)
  end

  defp sanitize_error_value(value, secret, depth) when is_list(value) do
    value
    |> Enum.take(@max_error_collection_items)
    |> Enum.map(&sanitize_error_value(&1, secret, depth - 1))
  end

  defp sanitize_error_value(value, secret, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.take(@max_error_collection_items)
    |> Enum.map(&sanitize_error_value(&1, secret, depth - 1))
    |> List.to_tuple()
  end

  defp sanitize_error_value(value, _secret, _depth)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_error_value(_value, _secret, _depth), do: :redacted

  defp redact_secret(value, secret) when is_binary(secret) and secret != "",
    do: String.replace(value, secret, "[REDACTED]")

  defp redact_secret(value, _secret), do: value

  defp truncate_binary(value, limit) when byte_size(value) <= limit, do: value

  defp truncate_binary(value, limit) do
    value
    |> binary_part(0, limit)
    |> String.replace_invalid("")
  end

  def header(_key, nil), do: []
  def header(key, value), do: [{key, value}]
end
