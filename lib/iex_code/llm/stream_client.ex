defmodule IexCode.LLM.StreamClient do
  @moduledoc """
  Multi-provider SSE streaming HTTP client.
  Integrates Req response streaming with UTF8Buffer and SSEParser, triggers incremental
  callbacks, and accumulates the complete response struct with merged tool call arguments.

  All parsing and `on_chunk` callbacks run in the calling process while Req streams the
  response (no helper process is spawned), so a raising callback aborts the stream with
  an error instead of deadlocking.
  """
  require Logger
  alias IexCode.LLM.{UTF8Buffer, SSEParser}

  defstruct [
    :provider,
    :url,
    :headers,
    :body,
    :on_chunk,
    :receive_timeout
  ]

  @stream_state_key :iex_code_llm_stream_state
  @max_success_stream_bytes 2_000_000
  @max_error_body_bytes 64_000
  @max_error_collection_items 50
  @max_error_depth 8
  @auth_header_names ~w(authorization proxy-authorization x-api-key api-key x-goog-api-key ocp-apim-subscription-key)

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  @type stream_response :: %{
          text: String.t(),
          tool_calls: [tool_call()],
          reasoning: String.t(),
          stop_reason: String.t() | atom() | nil,
          raw: map()
        }

  @doc """
  Streams a request to the configured LLM endpoint and accumulates the final response.

  ## Options
  - `:provider` - "openai" (default) or "anthropic"
  - `:url` - full endpoint URL
  - `:headers` - HTTP headers list
  - `:body` - map to be encoded as JSON (with `stream: true`)
  - `:receive_timeout` - HTTP receive timeout in ms (default: 60_000)
  - `:cancelled?` - optional zero-arity fun polled between chunks; when it returns
    truthy the stream is aborted cleanly and the partial response is returned

  On HTTP failures a structured error map is returned:
  `{:error, %{status: integer, body: binary, kind: atom, message: binary}}` where `kind`
  is one of `:rate_limit | :auth | :server | :network | :bad_request`.
  """
  @spec stream(map() | keyword(), (String.t() | map() -> any())) ::
          {:ok, stream_response()} | {:error, term()}
  def stream(request_opts, on_chunk \\ fn _c -> :ok end) do
    opts_map = if is_list(request_opts), do: Map.new(request_opts), else: request_opts

    provider = Map.get(opts_map, :provider, "openai")
    url = Map.fetch!(opts_map, :url)
    headers = opts_map |> Map.get(:headers, []) |> normalize_headers()
    auth_secrets = auth_secrets(headers)

    body =
      opts_map
      |> Map.fetch!(:body)
      |> Map.put("stream", true)
      |> maybe_request_openai_usage(provider)

    receive_timeout = Map.get(opts_map, :receive_timeout, 60_000)
    # A nil value (key present, no fun provided) must behave like an absent key.
    cancelled? = Map.get(opts_map, :cancelled?) || fn -> false end

    initial_state = new_state(provider)

    into_fun = fn
      {:data, raw_chunk}, {req, resp} ->
        state = get_stream_state(resp, initial_state)

        cond do
          cancelled?.() ->
            # abort cleanly between chunks; the partial result is still returned
            {:halt, {req, put_stream_state(resp, %{state | cancelled?: true})}}

          resp.status != 200 ->
            {next_state, directive} = append_error_chunk(state, raw_chunk)
            {directive, {req, put_stream_state(resp, next_state)}}

          true ->
            case account_success_chunk(state, raw_chunk) do
              {:ok, bounded_state} ->
                case consume_chunk(bounded_state, raw_chunk, on_chunk) do
                  {:ok, next_state} ->
                    {:cont, {req, put_stream_state(resp, next_state)}}

                  {:error, error_state} ->
                    # a raising on_chunk kills the stream instead of deadlocking it
                    {:halt, {req, put_stream_state(resp, error_state)}}
                end

              {:error, error_state} ->
                {:halt, {req, put_stream_state(resp, error_state)}}
            end
        end
    end

    http_result =
      try do
        Req.post(
          url,
          json: body,
          headers: headers,
          into: into_fun,
          receive_timeout: receive_timeout,
          retry: false
        )
      rescue
        exception -> {:request_exception, exception}
      catch
        kind, reason -> {:request_failure, kind, reason}
      end

    case http_result do
      {:ok, %{status: 200} = resp} ->
        state = get_stream_state(resp, initial_state)

        state =
          if state.error do
            state
          else
            try do
              flush_tail(state, on_chunk)
            rescue
              e -> %{state | error: e}
            end
          end

        if state.error do
          {:error, sanitize_error(state.error, auth_secrets)}
        else
          {:ok, assemble_final_response(state)}
        end

      {:ok, %{status: status} = resp} ->
        state = get_stream_state(resp, initial_state)

        error_body =
          if state.error_truncated? do
            "Upstream error body exceeded #{@max_error_body_bytes} bytes"
          else
            captured = state.error_io |> Enum.reverse() |> IO.iodata_to_binary()

            if captured == "" and is_binary(resp.body) do
              bounded_binary(resp.body, @max_error_body_bytes)
            else
              captured
            end
          end

        error_body = sanitize_error(error_body, auth_secrets)

        {:error,
         %{
           status: status,
           body: error_body,
           kind: error_kind(status),
           message: "HTTP #{status}"
         }}

      {:error, exception} ->
        message = exception |> request_error_message() |> sanitize_error(auth_secrets)
        {:error, %{status: 0, body: message, kind: :network, message: message}}

      {:request_exception, exception} ->
        message = exception |> request_error_message() |> sanitize_error(auth_secrets)
        {:error, %{status: 0, body: message, kind: :network, message: message}}

      {:request_failure, kind, reason} ->
        safe_reason = sanitize_error(reason, auth_secrets)
        message = "HTTP request #{kind}"
        {:error, %{status: 0, body: safe_reason, kind: :network, message: message}}
    end
  end

  # --- Internal Chunk Handling ---

  defp new_state(provider) do
    %{
      provider: provider,
      utf8_state: UTF8Buffer.new(),
      sse_state: SSEParser.new(),
      text_io: [],
      reasoning_io: [],
      tool_calls_acc: %{},
      usage: nil,
      stop_reason: nil,
      error: nil,
      error_io: [],
      error_bytes: 0,
      error_truncated?: false,
      success_bytes: 0,
      cancelled?: false
    }
  end

  defp consume_chunk(state, raw_chunk, on_chunk) do
    {valid_text, next_utf8} = UTF8Buffer.process_bytes(state.utf8_state, raw_chunk)
    {events, next_sse} = SSEParser.parse(state.sse_state, valid_text)

    try do
      next_state =
        Enum.reduce(events, %{state | utf8_state: next_utf8, sse_state: next_sse}, fn ev, st ->
          apply_event(ev, st, on_chunk)
        end)

      {:ok, next_state}
    rescue
      e -> {:error, %{state | error: e}}
    end
  end

  # Emits anything still buffered at end-of-stream so the last event or a
  # truncated multibyte tail is not lost.
  defp flush_tail(state, on_chunk) do
    {tail_text, <<>>} = UTF8Buffer.flush(state.utf8_state)
    {events, next_sse} = SSEParser.parse(state.sse_state, tail_text <> "\n")

    Enum.reduce(events, %{state | utf8_state: <<>>, sse_state: next_sse}, fn ev, st ->
      apply_event(ev, st, on_chunk)
    end)
  end

  defp apply_event(ev, st, on_chunk) do
    case SSEParser.parse_event(ev, st.provider) do
      {:delta, delta} ->
        text = delta[:text] || ""
        if text != "", do: on_chunk.(text)

        %{
          st
          | text_io: [text | st.text_io],
            reasoning_io: [delta[:reasoning] || "" | st.reasoning_io],
            tool_calls_acc: accumulate_tool_calls(st.tool_calls_acc, delta[:tool_calls] || []),
            usage: merge_usage(st.usage, delta[:usage])
        }

      {:done, reason, final_delta} ->
        text = final_delta[:text] || ""
        if text != "", do: on_chunk.(text)

        %{
          st
          | text_io: [text | st.text_io],
            reasoning_io: [final_delta[:reasoning] || "" | st.reasoning_io],
            tool_calls_acc:
              accumulate_tool_calls(st.tool_calls_acc, final_delta[:tool_calls] || []),
            stop_reason: st.stop_reason || reason,
            usage: merge_usage(st.usage, final_delta[:usage])
        }

      {:done, reason} ->
        # keep an already-captured stop_reason (finish_reason / message_delta);
        # [DONE] and message_stop must not overwrite it
        %{st | stop_reason: st.stop_reason || reason}

      {:error, err} ->
        %{st | error: err}

      :ignore ->
        st
    end
  end

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, [tc | rest]) do
    idx = tool_call_index(tc, acc)
    existing = Map.get(acc, idx, %{id: nil, name: nil, args_io: []})

    id = tc["id"] || existing.id
    name = get_in(tc, ["function", "name"]) || tc["name"] || existing.name
    args_delta = get_in(tc, ["function", "arguments"]) || tc["partial_json"] || ""

    updated = %{
      id: id,
      name: name,
      args_io: [args_delta | existing.args_io]
    }

    accumulate_tool_calls(Map.put(acc, idx, updated), rest)
  end

  # Keys parallel tool calls by their stream index. When a provider omits the
  # index, fall back to matching the tool call id, then to the newest entry for
  # continuation deltas, so a single call is neither split across entries nor
  # merged with a sibling call.
  defp tool_call_index(%{"index" => idx}, _acc) when is_integer(idx), do: idx

  defp tool_call_index(tc, acc) do
    id = tc["id"]

    case id && Enum.find_value(acc, fn {idx, entry} -> if entry.id == id, do: idx end) do
      idx when is_integer(idx) ->
        idx

      _ ->
        if id == nil and map_size(acc) > 0 do
          acc |> Map.keys() |> Enum.max()
        else
          map_size(acc)
        end
    end
  end

  defp assemble_final_response(state) do
    final_tool_calls =
      state.tool_calls_acc
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        args_raw = tc.args_io |> Enum.reverse() |> IO.iodata_to_binary()

        args =
          if args_raw != "" do
            case Jason.decode(args_raw) do
              {:ok, map} when is_map(map) -> map
              _ -> %{"raw" => args_raw}
            end
          else
            %{}
          end

        %{
          id: tc.id || "call_#{:erlang.unique_integer([:positive])}",
          name: tc.name || "unknown",
          args: args
        }
      end)

    response = %{
      text: state.text_io |> Enum.reverse() |> IO.iodata_to_binary(),
      tool_calls: final_tool_calls,
      reasoning: state.reasoning_io |> Enum.reverse() |> IO.iodata_to_binary(),
      stop_reason: state.stop_reason || if(state.cancelled?, do: :cancelled),
      raw: raw_map(state.usage)
    }

    if is_map(state.usage),
      do: Map.put(response, :usage, normalize_usage(state.usage)),
      else: response
  end

  defp maybe_request_openai_usage(body, "openai"),
    do: Map.put_new(body, "stream_options", %{"include_usage" => true})

  defp maybe_request_openai_usage(body, _provider), do: body

  defp normalize_usage(usage) do
    prompt = usage["prompt_tokens"] || usage["input_tokens"] || usage[:prompt_tokens] || 0

    completion =
      usage["completion_tokens"] || usage["output_tokens"] || usage[:completion_tokens] || 0

    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: usage["total_tokens"] || usage[:total_tokens] || prompt + completion
    }
  end

  defp raw_map(nil), do: %{}
  defp raw_map(usage), do: %{"usage" => usage}

  defp merge_usage(nil, nil), do: nil
  defp merge_usage(existing, nil), do: existing
  defp merge_usage(nil, new_usage), do: new_usage
  defp merge_usage(existing, new_usage), do: Map.merge(existing, new_usage)

  defp error_kind(401), do: :auth
  defp error_kind(403), do: :auth
  defp error_kind(429), do: :rate_limit
  defp error_kind(status) when status >= 400 and status < 500, do: :bad_request
  defp error_kind(status) when status >= 500, do: :server
  defp error_kind(_), do: :bad_request

  defp account_success_chunk(state, chunk) when is_binary(chunk) do
    received = state.success_bytes + byte_size(chunk)

    if received <= @max_success_stream_bytes do
      {:ok, %{state | success_bytes: received}}
    else
      {:error, %{state | error: :response_too_large, success_bytes: received}}
    end
  end

  defp append_error_chunk(state, chunk) when is_binary(chunk) do
    remaining = max(@max_error_body_bytes - state.error_bytes, 0)

    cond do
      byte_size(chunk) <= remaining ->
        {%{
           state
           | error_io: [chunk | state.error_io],
             error_bytes: state.error_bytes + byte_size(chunk)
         }, :cont}

      remaining > 0 ->
        prefix = binary_part(chunk, 0, remaining)

        {%{
           state
           | error_io: [prefix | state.error_io],
             error_bytes: @max_error_body_bytes,
             error_truncated?: true
         }, :halt}

      true ->
        {%{state | error_truncated?: true}, :halt}
    end
  end

  defp bounded_binary(value, limit) when byte_size(value) <= limit, do: value
  defp bounded_binary(value, limit), do: binary_part(value, 0, limit)

  defp request_error_message(error) when is_exception(error), do: Exception.message(error)

  defp request_error_message(error),
    do: inspect(error, limit: 20, printable_limit: @max_error_body_bytes)

  defp auth_secrets(headers) when is_map(headers), do: auth_secrets(Map.to_list(headers))

  defp auth_secrets(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {name, value} ->
        if auth_header?(name), do: credential_values(value), else: []

      _other ->
        []
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp auth_secrets(_headers), do: []

  defp normalize_headers(headers) when is_map(headers),
    do: headers |> Map.to_list() |> normalize_headers()

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {name, value} -> {normalize_header_string(name), normalize_header_string(value)}
      other -> other
    end)
  end

  defp normalize_headers(headers), do: headers

  defp normalize_header_string(value) when is_list(value) do
    if Enum.all?(value, &is_integer/1) and List.ascii_printable?(value),
      do: List.to_string(value),
      else: value
  end

  defp normalize_header_string(value), do: value

  defp auth_header?(name) do
    name = name |> normalize_header_string() |> to_string() |> String.downcase()
    name in @auth_header_names or String.ends_with?(name, "-api-key")
  end

  defp credential_values(value) when is_list(value) do
    if Enum.all?(value, &is_integer/1) and List.ascii_printable?(value) do
      credential_values(List.to_string(value))
    else
      Enum.flat_map(value, &credential_values/1)
    end
  end

  defp credential_values(value) when is_binary(value) do
    case String.split(value, ~r/\s+/, parts: 2, trim: true) do
      [_scheme, credential] -> [value, credential]
      _ -> [value]
    end
  end

  defp credential_values(_value), do: []

  defp sanitize_error(value, secrets),
    do: sanitize_error(value, secrets, @max_error_depth)

  defp sanitize_error(_value, _secrets, 0), do: :truncated

  defp sanitize_error(value, secrets, _depth) when is_binary(value) do
    secrets
    |> Enum.reduce(value, fn secret, redacted ->
      :binary.replace(redacted, secret, "[REDACTED]", [:global])
    end)
    |> bounded_binary(@max_error_body_bytes)
  end

  defp sanitize_error(value, secrets, depth) when is_exception(value) do
    module = value.__struct__

    sanitized_fields =
      value
      |> Map.from_struct()
      |> sanitize_error(secrets, depth - 1)

    try do
      struct(module, sanitized_fields)
    rescue
      _exception ->
        %{
          kind: :exception,
          module: module,
          message: sanitize_error(Exception.message(value), secrets, depth - 1)
        }
    end
  end

  defp sanitize_error(value, secrets, depth) when is_map(value) do
    value
    |> Enum.take(@max_error_collection_items)
    |> Map.new(fn {key, nested} ->
      {sanitize_error(key, secrets, depth - 1), sanitize_error(nested, secrets, depth - 1)}
    end)
  end

  defp sanitize_error(value, secrets, depth) when is_list(value) do
    if Enum.all?(value, &is_integer/1) and List.ascii_printable?(value) do
      value
      |> List.to_string()
      |> sanitize_error(secrets, depth - 1)
    else
      value
      |> Enum.take(@max_error_collection_items)
      |> Enum.map(&sanitize_error(&1, secrets, depth - 1))
    end
  end

  defp sanitize_error(value, secrets, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.take(@max_error_collection_items)
    |> Enum.map(&sanitize_error(&1, secrets, depth - 1))
    |> List.to_tuple()
  end

  defp sanitize_error(value, _secrets, _depth)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_error(value, secrets, _depth) do
    value
    |> inspect(limit: 20, printable_limit: @max_error_body_bytes)
    |> sanitize_error(secrets)
  end

  # --- Stream State (threaded through Req's response accumulator) ---

  defp get_stream_state(resp, default) do
    Map.get(resp.private, @stream_state_key, default)
  end

  defp put_stream_state(resp, state) do
    put_in(resp.private[@stream_state_key], state)
  end
end
