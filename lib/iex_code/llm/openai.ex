defmodule IexCode.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible client supporting GPT-4o, o1, o3-mini, Gemini proxies,
  and function calling with SSE streaming.
  """
  require Logger
  alias IexCode.LLM.StreamClient

  def chat(messages, system_prompt, opts, on_chunk \\ fn _c -> :ok end) do
    api_key = Keyword.get(opts, :api_key, "")
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com/v1")
    model = Keyword.get(opts, :model, "gpt-4o")
    tools = Keyword.get(opts, :tools, [])
    stream? = Keyword.get(opts, :stream, true)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    system_messages =
      if system_prompt in [nil, ""] do
        []
      else
        [%{"role" => "system", "content" => system_prompt}]
      end

    formatted_messages = system_messages ++ Enum.map(messages, &format_message/1)

    openai_tools =
      Enum.map(tools, fn t ->
        %{
          "type" => "function",
          "function" => %{
            "name" => t.name,
            "description" => t.description,
            "parameters" => t.parameters
          }
        }
      end)

    body =
      %{"model" => model, "messages" => formatted_messages}
      # Reasoning models (o1/o3) reject temperature; only send it when explicitly provided.
      |> put_optional("temperature", Keyword.get(opts, :temperature))
      |> put_optional("max_tokens", Keyword.get(opts, :max_tokens))
      |> then(fn map ->
        if openai_tools != [] do
          Map.put(map, "tools", openai_tools)
        else
          map
        end
      end)

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    if api_key == "" or api_key == nil do
      {:error, :no_api_key}
    else
      if stream? do
        request_opts = [
          provider: "openai",
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
          {:ok, %{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
            msg = choice["message"] || %{}
            text = msg["content"] || ""

            tool_calls =
              (msg["tool_calls"] || [])
              |> Enum.map(fn tc ->
                args =
                  case Jason.decode(tc["function"]["arguments"] || "{}") do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                %{
                  id: tc["id"],
                  name: tc["function"]["name"],
                  args: args
                }
              end)

            on_chunk.(text)
            {:ok, %{text: text, tool_calls: tool_calls, raw: resp, usage: extract_usage(resp)}}

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
    base = %{"role" => "assistant", "content" => field(msg, :content)}

    case normalize_tool_calls(field(msg, :tool_calls)) do
      [] -> base
      tool_calls -> Map.put(base, "tool_calls", tool_calls)
    end
  end

  defp format_message(%{role: "tool"} = msg) do
    %{
      "role" => "tool",
      "tool_call_id" => field(msg, :tool_call_id),
      "content" => field(msg, :content)
    }
  end

  defp format_message(other) when is_map(other), do: other
  defp format_message(other), do: %{"role" => "user", "content" => to_string(other)}

  # Replays prior assistant tool-call requests so multi-turn tool loops stay valid;
  # the API rejects a tool reply whose preceding assistant message lacks tool_calls.
  defp normalize_tool_calls(nil), do: []

  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        "id" => field(tc, :id),
        "type" => "function",
        "function" => %{
          "name" => field(tc, :name) || get_in(tc, ["function", "name"]),
          "arguments" => encode_args(field(tc, :args) || get_in(tc, ["function", "arguments"]))
        }
      }
    end)
  end

  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args), do: Jason.encode!(args || %{})

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  # --- Request Body Helpers ---

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

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
        prompt = usage["prompt_tokens"] || 0
        completion = usage["completion_tokens"] || 0

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
