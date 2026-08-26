defmodule IexCode.Research.GroundedSearch.Providers.AnthropicMessages do
  @moduledoc """
  Anthropic Messages adapter for server-side web search. It defaults to current
  `web_search_20260318` with `allowed_callers: ["direct"]`, avoiding an implicit
  code-execution contract. Callers may select an allowlisted older version.

  `pause_turn` is continued by echoing the paused assistant content unchanged,
  but only up to `:max_continuations` (default 2, maximum 5). Embedded tool
  errors and mixed client-tool turns are returned as errors rather than being
  mistaken for a complete grounded answer.
  """
  @behaviour IexCode.Research.GroundedSearch.Provider

  alias IexCode.Research.GroundedSearch.{HTTP, Normalizer, ResponseHelpers}

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_tool_version "web_search_20260318"
  @tool_versions ~w(web_search_20250305 web_search_20260209 web_search_20260318)
  @tool_errors ~w(too_many_requests invalid_tool_input max_uses_exceeded query_too_long request_too_large unavailable)

  @impl true
  def id, do: :anthropic_messages

  @impl true
  def answer(query, opts) do
    result =
      with {:ok, query} <- Normalizer.query(query),
           {:ok, api_key, model} <- Normalizer.credentials(opts),
           {:ok, tool_version} <- tool_version(opts[:tool_version]),
           :ok <- validate_options(opts),
           {:ok, responses} <-
             request_until_complete(
               query,
               api_key,
               model,
               Keyword.put(opts, :tool_version, tool_version)
             ),
           :ok <- validate_tool_results(responses),
           {:ok, normalized} <- normalize(responses) do
        {:ok, normalized}
      end

    HTTP.sanitize_result(result, opts[:api_key])
  end

  defp request_until_complete(query, api_key, model, opts) do
    max_continuations = bounded_integer(opts[:max_continuations], 0, 5, 2)
    messages = [%{"role" => "user", "content" => query}]
    do_request(messages, api_key, model, opts, max_continuations, [])
  end

  defp do_request(messages, api_key, model, opts, remaining, responses) do
    tool_version = Keyword.fetch!(opts, :tool_version)

    tool =
      %{
        "type" => tool_version,
        "name" => "web_search",
        "max_uses" => bounded_integer(opts[:max_uses], 1, 20, 5),
        "allowed_callers" => ["direct"]
      }
      |> maybe_response_inclusion(tool_version)
      |> domain_filter(opts)

    body = %{
      "model" => model,
      "max_tokens" => bounded_integer(opts[:max_tokens], 1, 64_000, 4_096),
      "messages" => messages,
      "tools" => [tool]
    }

    with {:ok, response} <-
           HTTP.post(
             id(),
             @endpoint,
             api_key,
             [
               headers: [
                 {"x-api-key", api_key},
                 {"anthropic-version", "2023-06-01"},
                 {"content-type", "application/json"}
               ],
               json: body
             ],
             opts
           ),
         :ok <- embedded_tool_errors(response) do
      case response["stop_reason"] do
        "end_turn" ->
          {:ok, Enum.reverse([response | responses])}

        "pause_turn" when remaining > 0 ->
          assistant = %{"role" => "assistant", "content" => Normalizer.list(response["content"])}

          do_request(messages ++ [assistant], api_key, model, opts, remaining - 1, [
            response | responses
          ])

        "pause_turn" ->
          {:error, {:incomplete, :pause_turn_limit}}

        "tool_use" ->
          {:error, {:incomplete, :client_tool_required}}

        reason ->
          {:error, {:incomplete, reason || :missing_stop_reason}}
      end
    end
  end

  defp embedded_tool_errors(response) do
    response
    |> Map.get("content", [])
    |> Normalizer.list()
    |> Enum.find_value(:ok, fn block ->
      if Normalizer.value(block, :type) == "web_search_tool_result" do
        case Normalizer.value(block, :content) do
          %{} = content ->
            code = Normalizer.value(content, :error_code)
            if code in @tool_errors, do: {:error, {:provider_error, {:web_search, code}}}

          _ ->
            nil
        end
      end
    end)
  end

  defp normalize(responses) do
    final = List.last(responses) || %{}
    content = Normalizer.list(final["content"])
    {answer, citations} = ResponseHelpers.answer_and_citations([content], "text", :citations)

    calls =
      responses
      |> Enum.flat_map(&Normalizer.list(&1["content"]))
      |> Enum.filter(fn block ->
        Normalizer.value(block, :type) == "server_tool_use" and
          Normalizer.value(block, :name) == "web_search"
      end)
      |> Enum.map(fn block ->
        input = Normalizer.value(block, :input) || %{}

        %{
          id: Normalizer.value(block, :id),
          queries: List.wrap(Normalizer.value(input, :query)),
          status: "completed",
          metadata: %{}
        }
      end)

    Normalizer.build(
      id(),
      answer,
      citations,
      calls,
      ResponseHelpers.sum_usage(Enum.map(responses, &(&1["usage"] || %{}))),
      %{
        "response_id" => final["id"],
        "model" => final["model"],
        "stop_reason" => final["stop_reason"],
        "continuations" => max(length(responses) - 1, 0)
      }
    )
  end

  defp validate_tool_results(responses) do
    blocks = Enum.flat_map(responses, &Normalizer.list(&1["content"]))

    call_ids =
      blocks
      |> Enum.filter(fn block ->
        Normalizer.value(block, :type) == "server_tool_use" and
          Normalizer.value(block, :name) == "web_search"
      end)
      |> Enum.map(&Normalizer.value(&1, :id))

    result_ids =
      blocks
      |> Enum.filter(fn block ->
        Normalizer.value(block, :type) == "web_search_tool_result" and
          is_list(Normalizer.value(block, :content))
      end)
      |> Enum.map(&Normalizer.value(&1, :tool_use_id))

    if call_ids != [] and
         Enum.all?(call_ids, &(is_binary(&1) and &1 != "" and &1 in result_ids)),
       do: :ok,
       else: {:error, {:invalid_response, :unmatched_web_search_call}}
  end

  defp domain_filter(tool, opts) do
    allowed = valid_domains(opts[:allowed_domains])
    blocked = valid_domains(opts[:blocked_domains])

    cond do
      allowed != [] and blocked != [] -> tool
      allowed != [] -> Map.put(tool, "allowed_domains", allowed)
      blocked != [] -> Map.put(tool, "blocked_domains", blocked)
      true -> tool
    end
  end

  defp valid_domains(domains) when is_list(domains) do
    domains
    |> Enum.filter(&valid_domain?/1)
    |> Enum.take(100)
  end

  defp valid_domains(_domains), do: []

  defp valid_domain?(domain) do
    is_binary(domain) and domain != "" and byte_size(domain) <= 253 and
      not String.contains?(domain, ["://", "@", "\0", "\r", "\n", "\t", " "])
  end

  defp tool_version(nil), do: {:ok, @default_tool_version}

  defp tool_version(version) when is_atom(version),
    do: version |> Atom.to_string() |> tool_version()

  defp tool_version(version) when version in @tool_versions, do: {:ok, version}
  defp tool_version(_version), do: {:error, {:configuration, :unsupported_tool_version}}

  defp maybe_response_inclusion(tool, "web_search_20260318"),
    do: Map.put(tool, "response_inclusion", "full")

  defp maybe_response_inclusion(tool, _version), do: tool

  defp validate_options(opts) do
    with :ok <- validate_domain_list(opts[:allowed_domains], :allowed_domains),
         :ok <- validate_domain_list(opts[:blocked_domains], :blocked_domains),
         :ok <- validate_domain_exclusivity(opts),
         :ok <- validate_optional_integer(opts[:max_continuations], 0, 5, :max_continuations),
         :ok <- validate_optional_integer(opts[:max_uses], 1, 20, :max_uses),
         :ok <- validate_optional_integer(opts[:max_tokens], 1, 64_000, :max_tokens) do
      :ok
    end
  end

  defp validate_domain_list(nil, _field), do: :ok

  defp validate_domain_list(domains, _field) when is_list(domains) do
    bounded = Enum.take(domains, 101)

    if length(bounded) <= 100 and Enum.all?(bounded, &valid_domain?/1),
      do: :ok,
      else: {:error, {:configuration, :invalid_domain_filter}}
  end

  defp validate_domain_list(_domains, _field),
    do: {:error, {:configuration, :invalid_domain_filter}}

  defp validate_domain_exclusivity(opts) do
    if List.wrap(opts[:allowed_domains]) != [] and List.wrap(opts[:blocked_domains]) != [],
      do: {:error, {:configuration, :conflicting_domain_filters}},
      else: :ok
  end

  defp validate_optional_integer(nil, _min, _max, _field), do: :ok

  defp validate_optional_integer(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp validate_optional_integer(_value, _min, _max, field),
    do: {:error, {:configuration, {:invalid_option, field}}}

  defp bounded_integer(value, min, max, _default)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp bounded_integer(_value, _min, _max, default), do: default
end
