defmodule IexCode.Research.Fetcher do
  @moduledoc """
  A bounded, SSRF-resistant fetcher for public research sources.

  Redirects are followed manually and every hop is resolved and validated by
  `IexCode.Research.URLGuard`. Requests are pinned to the validated address so a
  second, attacker-controlled DNS answer cannot redirect the actual connection.
  """

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Research.URLGuard

  @default_timeout 10_000
  @default_body_limit 1_000_000
  @default_text_limit 200_000
  @default_redirects 5
  @absolute_timeout 60_000
  @absolute_body_limit 5_000_000
  @absolute_redirects 10
  @redirect_statuses [301, 302, 303, 307, 308]

  @type result :: %{
          url: String.t(),
          status: non_neg_integer(),
          content_type: String.t(),
          text: String.t(),
          bytes: non_neg_integer(),
          redirects: [String.t()]
        }

  @spec fetch(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    with {:ok, config} <- config(opts) do
      ResourceGovernor.with_permit(
        :research_fetch,
        ResourceGovernor.admission_opts(opts, priority: :background),
        fn -> do_fetch(url, config, []) end
      )
    end
  end

  defp do_fetch(url, config, redirects) do
    with {:ok, target} <- URLGuard.validate_and_resolve(url, resolver: config.resolver),
         {:ok, response} <- request(target, config) do
      if response.status in @redirect_statuses do
        follow_redirect(response, target.uri, config, redirects)
      else
        finish(response, target.uri, redirects, config)
      end
    end
  end

  defp request(target, %{request: request} = config) do
    pinned_uri = %{target.uri | host: target.address |> :inet.ntoa() |> to_string()}

    request_opts = [
      headers: [
        {"accept", "text/html, text/plain, application/json"},
        {"user-agent", config.user_agent}
      ],
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: true,
      receive_timeout: config.timeout,
      connect_options: [timeout: config.timeout, hostname: target.uri.host],
      into: body_collector(config.body_limit)
    ]

    call = fn -> request.(URI.to_string(pinned_uri), request_opts) end

    case request_with_deadline(call, config.timeout) do
      {:ok, response} -> normalize_response(response)
      {:error, reason} -> {:error, {:request_failed, reason}}
      other -> {:error, {:invalid_response, other}}
    end
  rescue
    exception -> {:error, {:request_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:request_failed, {kind, reason}}}
  end

  defp request_with_deadline(call, timeout) do
    task =
      Task.async(fn ->
        try do
          call.()
        rescue
          exception -> {:error, {:exception, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:request_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp body_collector(limit) do
    fn {:data, chunk}, {request, response} ->
      body = Req.Response.get_private(response, :iex_code_research_body, "")
      remaining = limit - byte_size(body)

      if byte_size(chunk) > remaining do
        response =
          response
          |> Req.Response.put_private(
            :iex_code_research_body,
            body <> binary_part(chunk, 0, max(remaining, 0))
          )
          |> Req.Response.put_private(:iex_code_research_body_exceeded, true)

        {:halt, {request, response}}
      else
        response = Req.Response.put_private(response, :iex_code_research_body, body <> chunk)
        {:cont, {request, response}}
      end
    end
  end

  defp normalize_response(%Req.Response{} = response) do
    body = Req.Response.get_private(response, :iex_code_research_body, response.body)
    exceeded? = Req.Response.get_private(response, :iex_code_research_body_exceeded, false)

    if exceeded? do
      {:error, :body_too_large}
    else
      {:ok, %{status: response.status, headers: response.headers, body: body}}
    end
  end

  defp normalize_response(%{status: status} = response) when is_integer(status) do
    body = Map.get(response, :body, "")

    if is_binary(body) do
      {:ok, %{status: status, headers: Map.get(response, :headers, %{}), body: body}}
    else
      {:error, :non_binary_body}
    end
  end

  defp normalize_response(other), do: {:error, {:invalid_response, other}}

  defp follow_redirect(response, uri, config, redirects) do
    with :ok <- redirect_available?(config.redirects, redirects),
         {:ok, location} <- header(response.headers, "location"),
         {:ok, next_url} <- redirect_url(uri, location) do
      do_fetch(next_url, config, redirects ++ [URI.to_string(uri)])
    end
  end

  defp redirect_available?(limit, redirects) do
    if length(redirects) < limit, do: :ok, else: {:error, :too_many_redirects}
  end

  defp redirect_url(uri, location) do
    case URI.merge(uri, location) do
      %URI{} = target -> {:ok, URI.to_string(target)}
      _ -> {:error, :invalid_redirect}
    end
  rescue
    _ -> {:error, :invalid_redirect}
  end

  defp finish(%{status: status}, _uri, _redirects, _config) when status < 200 or status >= 300,
    do: {:error, {:http_status, status}}

  defp finish(response, uri, redirects, config) do
    with {:ok, content_type} <- header(response.headers, "content-type"),
         {:ok, media_type} <- allowed_media_type(content_type),
         :ok <- within_limit(response.body, config.body_limit),
         {:ok, text} <- extract_text(response.body, media_type) do
      {:ok,
       %{
         url: URI.to_string(uri),
         status: response.status,
         content_type: media_type,
         text: String.slice(text, 0, config.text_limit),
         bytes: byte_size(response.body),
         redirects: redirects
       }}
    end
  end

  defp allowed_media_type(content_type) do
    media_type =
      content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    if media_type in ["text/html", "text/plain", "application/json"] do
      {:ok, media_type}
    else
      {:error, {:unsupported_content_type, media_type}}
    end
  end

  defp within_limit(body, limit) do
    if byte_size(body) <= limit, do: :ok, else: {:error, :body_too_large}
  end

  defp extract_text(body, "text/html") do
    case Floki.parse_document(body) do
      {:ok, document} ->
        nodes =
          case Floki.find(document, "body") do
            [] -> document
            body_nodes -> body_nodes
          end

        text =
          nodes
          |> Floki.filter_out("script, style, noscript, template, svg")
          |> Floki.text(sep: " ")
          |> normalize_text()

        {:ok, text}

      {:error, reason} ->
        {:error, {:invalid_html, reason}}
    end
  end

  defp extract_text(body, "text/plain"), do: {:ok, normalize_text(body)}

  defp extract_text(body, "application/json") do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, Jason.encode!(value, pretty: true)}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp normalize_text(text) do
    text |> String.replace_invalid() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp header(headers, name) do
    values =
      cond do
        is_map(headers) ->
          Enum.find_value(headers, fn {key, value} ->
            if String.downcase(to_string(key)) == name, do: value
          end)

        is_list(headers) ->
          Enum.find_value(headers, fn {key, value} ->
            if String.downcase(to_string(key)) == name, do: value
          end)

        true ->
          nil
      end

    case values do
      [value | _] when is_binary(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_header, name}}
    end
  end

  defp config(opts) do
    config = %{
      resolver: Keyword.get(opts, :resolver, &default_resolver/1),
      request: Keyword.get(opts, :request, &default_request/2),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      body_limit: Keyword.get(opts, :max_body_bytes, @default_body_limit),
      text_limit: Keyword.get(opts, :max_text_chars, @default_text_limit),
      redirects: Keyword.get(opts, :max_redirects, @default_redirects),
      user_agent: Keyword.get(opts, :user_agent, "IExCode Research/1.0")
    }

    cond do
      not is_function(config.resolver, 1) -> {:error, :invalid_resolver}
      not is_function(config.request, 2) -> {:error, :invalid_request}
      config.timeout not in 1..@absolute_timeout -> {:error, :invalid_timeout}
      config.body_limit not in 1..@absolute_body_limit -> {:error, :invalid_body_limit}
      not is_integer(config.text_limit) or config.text_limit < 1 -> {:error, :invalid_text_limit}
      config.redirects not in 0..@absolute_redirects -> {:error, :invalid_redirect_limit}
      true -> {:ok, config}
    end
  end

  defp default_resolver(host) do
    results =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, addresses} -> addresses
          {:error, _} -> []
        end
      end)

    if results == [], do: {:error, :nxdomain}, else: {:ok, Enum.uniq(results)}
  end

  defp default_request(url, opts) do
    opts
    |> Keyword.put(:method, :get)
    |> Keyword.put(:url, url)
    |> IexCode.HTTP.pinned_request()
  end
end
