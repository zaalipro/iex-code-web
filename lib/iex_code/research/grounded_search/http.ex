defmodule IexCode.Research.GroundedSearch.HTTP do
  @moduledoc false

  @max_body_bytes 2_000_000
  @official_origins %{
    openai_responses: {"api.openai.com", 443},
    anthropic_messages: {"api.anthropic.com", 443},
    gemini_interactions: {"generativelanguage.googleapis.com", 443}
  }

  def post(provider, url, api_key, request_opts, opts) do
    with :ok <- official_origin(provider, url),
         :ok <- cancellation_status(opts) do
      request = opts[:request] || (&Req.request/1)

      req_opts =
        request_opts
        |> Keyword.put(:method, :post)
        |> Keyword.put(:url, url)
        |> Keyword.put(:redirect, false)
        |> Keyword.put(:retry, false)
        |> Keyword.put(:decode_body, false)
        |> Keyword.put(:compressed, false)
        |> Keyword.put(:into, body_collector(@max_body_bytes))
        |> Keyword.put_new(:receive_timeout, 60_000)
        |> Keyword.put_new(:connect_options, timeout: 15_000)

      result =
        try do
          if is_function(request, 1),
            do: request.(req_opts),
            else: {:error, :invalid_request_function}
        rescue
          exception -> {:error, {:request_exception, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {:request_failure, kind, reason}}
        end

      result |> normalize() |> redact(api_key)
    end
  end

  @doc false
  def sanitize_result({:error, reason}, api_key), do: {:error, redact_value(reason, api_key, 6)}
  def sanitize_result(result, _api_key), do: result

  defp official_origin(provider, url) do
    with {host, port} <- Map.get(@official_origins, provider),
         %URI{scheme: "https", host: ^host, userinfo: nil} = uri <- URI.parse(url),
         true <- effective_port(uri) == port do
      :ok
    else
      _ -> {:error, {:configuration, :unofficial_endpoint}}
    end
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(_uri), do: 443

  defp cancelled?(opts), do: IexCode.Research.GroundedSearch.Normalizer.cancelled?(opts)

  defp cancellation_status(opts) do
    if cancelled?(opts), do: {:error, :cancelled}, else: :ok
  end

  defp normalize({:ok, %Req.Response{} = response}), do: normalize(response)

  defp normalize(%Req.Response{} = response) do
    if Req.Response.get_private(response, :iex_code_grounded_body_exceeded, false) do
      {:error, :response_too_large}
    else
      body = Req.Response.get_private(response, :iex_code_grounded_body, response.body)
      status_body(response.status, body)
    end
  end

  defp normalize({:ok, %{status: status, body: body}}), do: status_body(status, body)
  defp normalize(%{status: status, body: body}), do: status_body(status, body)
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:invalid_response, safe(other)}}

  defp status_body(status, body) when is_integer(status) and status in 200..299 do
    with :ok <- bounded(body), {:ok, decoded} <- decode(body), do: {:ok, decoded}
  end

  defp status_body(status, body) when is_integer(status) do
    case bounded(body) do
      :ok -> {:error, {:http_error, status, provider_error(body)}}
      {:error, reason} -> {:error, {:http_error, status, reason}}
    end
  end

  defp status_body(_status, _body), do: {:error, {:invalid_response, :invalid_status}}

  defp bounded(body) when is_binary(body),
    do: if(byte_size(body) <= @max_body_bytes, do: :ok, else: {:error, :response_too_large})

  defp bounded(body) do
    if :erlang.external_size(body) <= @max_body_bytes,
      do: :ok,
      else: {:error, :response_too_large}
  rescue
    _ -> {:error, :invalid_response_body}
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_response, :non_object_json}}
      {:error, _reason} -> {:error, {:invalid_response, :invalid_json}}
    end
  end

  defp decode(_body), do: {:error, {:invalid_response, :invalid_body}}

  defp provider_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> provider_error(decoded)
      _ -> :request_failed
    end
  end

  defp provider_error(%{"error" => error}), do: safe(error)
  defp provider_error(%{error: error}), do: safe(error)
  defp provider_error(_body), do: :request_failed

  defp body_collector(limit) do
    fn {:data, chunk}, {request, response} ->
      body = Req.Response.get_private(response, :iex_code_grounded_body, "")
      remaining = max(limit - byte_size(body), 0)

      if byte_size(chunk) > remaining do
        response =
          response
          |> Req.Response.put_private(
            :iex_code_grounded_body,
            body <> binary_part(chunk, 0, remaining)
          )
          |> Req.Response.put_private(:iex_code_grounded_body_exceeded, true)

        {:halt, {request, response}}
      else
        response = Req.Response.put_private(response, :iex_code_grounded_body, body <> chunk)
        {:cont, {request, response}}
      end
    end
  end

  defp redact({:error, reason}, key), do: {:error, redact_value(reason, key, 6)}
  defp redact(result, _key), do: result

  defp redact_value(_value, _key, 0), do: :truncated

  defp redact_value(value, key, _depth) when is_binary(value) do
    value =
      if is_binary(key) and key != "", do: String.replace(value, key, "[REDACTED]"), else: value

    if byte_size(value) <= 4_000, do: value, else: binary_part(value, 0, 4_000)
  end

  defp redact_value(value, key, depth) when is_map(value),
    do:
      value
      |> Enum.take(50)
      |> Map.new(fn {k, v} ->
        {redact_value(k, key, depth - 1), redact_value(v, key, depth - 1)}
      end)

  defp redact_value(value, key, depth) when is_list(value),
    do: value |> Enum.take(50) |> Enum.map(&redact_value(&1, key, depth - 1))

  defp redact_value(value, key, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&redact_value(&1, key, depth - 1)) |> List.to_tuple()

  defp redact_value(value, _key, _depth)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp redact_value(_value, _key, _depth), do: :redacted

  defp safe(value), do: redact_value(value, nil, 5)
end
