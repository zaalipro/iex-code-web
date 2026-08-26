defmodule IexCode.LLM.Anthropic do
  @moduledoc """
  Anthropic API client supporting streaming messages, tool use, and custom endpoints.
  """
  require Logger
  alias IexCode.LLM.StreamClient

  def chat(messages, system_prompt, opts, on_chunk \\ fn _c -> :ok end) do
    api_key = Keyword.get(opts, :api_key, "")
    base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")
    model = Keyword.get(opts, :model, "claude-3-7-sonnet")
    temperature = Keyword.get(opts, :temperature, 0.2)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    anthropic_version = Keyword.get(opts, :anthropic_version, "2023-06-01")
    tools = Keyword.get(opts, :tools, [])
    stream? = Keyword.get(opts, :stream, true)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", anthropic_version},
      {"content-type", "application/json"}
    ]

    formatted_messages =
      messages
      |> Enum.map(&format_message/1)
      |> merge_consecutive_roles()

    anthropic_tools =
      Enum.map(tools, fn t ->
        %{
          "name" => t.name,
          "description" => t.description,
          "input_schema" => t.parameters
        }
      end)

    body =
      %{
        "model" => model,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "messages" => formatted_messages
      }
      # The API rejects a nil system prompt; omit the field entirely when absent.
      |> then(fn map ->
        if system_prompt in [nil, ""], do: map, else: Map.put(map, "system", system_prompt)
      end)
      |> then(fn map ->
        if anthropic_tools != [] do
          Map.put(map, "tools", anthropic_tools)
        else
          map
        end
      end)

    url = String.trim_trailing(base_url, "/") <> "/v1/messages"

    if api_key == "" or api_key == nil do
      {:error, :no_api_key}
    else
      if stream? do
        request_opts = [
          provider: "anthropic",
          url: url,
          headers: headers,
          body: body,
          receive_timeout: Keyword.get(opts, :receive_timeout, 25_000),
          cancelled?: Keyword.get(opts, :cancelled?)
        ]

        case StreamClient.stream(request_opts, on_chunk) do
          {:ok, result} ->
            {:ok, ensure_usage(result)}

          {:error, %{status: status, body: body_resp}} when is_integer(status) ->
            {:error,
             %{status: status, body: body_to_string(body_resp), kind: kind_for_status(status)}}

          {:error, reason} ->
            {:error, %{status: nil, body: reason_to_string(reason), kind: :network}}
        end
      else
        case Req.post(url,
               json: body,
               headers: headers,
               receive_timeout: Keyword.get(opts, :receive_timeout, 25_000)
             ) do
          {:ok, %{status: 200, body: %{"content" => content_blocks} = resp}} ->
            text_blocks =
              content_blocks
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map(& &1["text"])
              |> Enum.join("")

            tool_calls =
              content_blocks
              |> Enum.filter(&(&1["type"] == "tool_use"))
              |> Enum.map(fn b ->
                %{
                  id: b["id"],
                  name: b["name"],
                  args: b["input"] || %{}
                }
              end)

            on_chunk.(text_blocks)

            {:ok,
             %{text: text_blocks, tool_calls: tool_calls, raw: resp, usage: extract_usage(resp)}}

          {:ok, %{status: status, body: body_resp}} ->
            {:error,
             %{status: status, body: body_to_string(body_resp), kind: kind_for_status(status)}}

          {:error, reason} ->
            {:error, %{status: nil, body: reason_to_string(reason), kind: :network}}
        end
      end
    end
  end

  # --- Message Formatting ---

  defp format_message(%{role: "user", content: c}), do: %{"role" => "user", "content" => c}

  defp format_message(%{role: "assistant"} = msg) do
    tool_blocks =
      msg
      |> field(:tool_calls)
      |> List.wrap()
      |> Enum.map(fn tc ->
        %{
          "type" => "tool_use",
          "id" => field(tc, :id),
          "name" => field(tc, :name) || get_in(tc, ["function", "name"]) || "unknown",
          "input" => decode_args(field(tc, :args) || get_in(tc, ["function", "arguments"]))
        }
      end)

    case tool_blocks do
      [] ->
        %{"role" => "assistant", "content" => field(msg, :content)}

      blocks ->
        text = field(msg, :content)
        text_block = if text in [nil, ""], do: [], else: [%{"type" => "text", "text" => text}]
        %{"role" => "assistant", "content" => text_block ++ blocks}
    end
  end

  defp format_message(%{role: "tool"} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => field(msg, :tool_call_id),
          "content" => field(msg, :content)
        }
      ]
    }
  end

  defp format_message(other) when is_map(other), do: other
  defp format_message(other), do: %{"role" => "user", "content" => to_string(other)}

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_args(args) when is_map(args), do: args
  defp decode_args(_), do: %{}

  # Collapses consecutive same-role messages (e.g. parallel tool results) into a
  # single message with multiple blocks so roles strictly alternate, as the
  # Messages API requires.
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce([], fn
      msg, [%{"role" => role} = prev | rest] ->
        if role == msg["role"] do
          [merge_contents(prev, msg) | rest]
        else
          [msg | [prev | rest]]
        end

      msg, acc ->
        [msg | acc]
    end)
  end

  defp merge_contents(prev, next) do
    %{
      "role" => prev["role"],
      "content" => to_blocks(prev["content"]) ++ to_blocks(next["content"])
    }
  end

  defp to_blocks(content) when is_list(content), do: content
  defp to_blocks(content) when is_binary(content), do: [%{"type" => "text", "text" => content}]
  defp to_blocks(_), do: []

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  # --- Error Shaping ---

  defp kind_for_status(429), do: :rate_limit
  defp kind_for_status(status) when status in [401, 403], do: :auth
  defp kind_for_status(status) when status >= 500 and status <= 599, do: :server
  defp kind_for_status(_status), do: :bad_request

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body), do: Jason.encode!(body)

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  # --- Usage Extraction ---

  defp ensure_usage(result) when is_map(result) do
    Map.put_new(result, :usage, %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0})
  end

  defp extract_usage(resp) do
    case resp do
      %{"usage" => usage} when is_map(usage) ->
        prompt = usage["input_tokens"] || 0
        completion = usage["output_tokens"] || 0

        %{
          prompt_tokens: prompt,
          completion_tokens: completion,
          total_tokens: usage["total_tokens"] || prompt + completion
        }

      _ ->
        %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    end
  end
end
