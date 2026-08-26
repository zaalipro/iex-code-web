defmodule IexCode.Research.GroundedSearch.Providers.OpenAIResponses do
  @moduledoc "OpenAI Responses API adapter for the hosted `web_search` tool."
  @behaviour IexCode.Research.GroundedSearch.Provider

  alias IexCode.Research.GroundedSearch.{HTTP, Normalizer, ResponseHelpers}

  @endpoint "https://api.openai.com/v1/responses"

  @impl true
  def id, do: :openai_responses

  @impl true
  def answer(query, opts) do
    result =
      with {:ok, query} <- Normalizer.query(query),
           {:ok, api_key, model} <- Normalizer.credentials(opts),
           :ok <- validate_options(opts),
           {:ok, response} <- request(query, api_key, model, opts),
           :ok <- complete?(response),
           :ok <- search_calls_complete?(response),
           {:ok, normalized} <- normalize(response) do
        {:ok, normalized}
      end

    HTTP.sanitize_result(result, opts[:api_key])
  end

  defp request(query, api_key, model, opts) do
    tool =
      %{"type" => "web_search"}
      |> maybe_put("search_context_size", enum(opts[:search_context_size], ~w(low medium high)))
      |> maybe_put("external_web_access", boolean(opts[:external_web_access]))
      |> maybe_allowed_domains(opts[:allowed_domains])

    body =
      %{
        "model" => model,
        "input" => query,
        "tools" => [tool],
        "tool_choice" => "required",
        "include" => ["web_search_call.action.sources"]
      }
      |> maybe_put("max_output_tokens", bounded_integer(opts[:max_output_tokens], 1, 100_000))

    HTTP.post(
      id(),
      @endpoint,
      api_key,
      [
        headers: [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}],
        json: body
      ],
      opts
    )
  end

  defp complete?(%{"error" => error}) when not is_nil(error),
    do: {:error, {:provider_error, error}}

  defp complete?(%{"status" => "completed"}), do: :ok
  defp complete?(%{"status" => status}), do: {:error, {:incomplete, status}}
  defp complete?(_response), do: {:error, {:invalid_response, :missing_status}}

  defp search_calls_complete?(response) do
    response
    |> Map.get("output", [])
    |> Normalizer.list()
    |> Enum.find_value(:ok, fn item ->
      if Normalizer.value(item, :type) == "web_search_call" and
           Normalizer.value(item, :status) != "completed" do
        {:error, {:provider_error, {:web_search, Normalizer.value(item, :status)}}}
      end
    end)
  end

  defp normalize(response) do
    output = Normalizer.list(response["output"])

    message_groups =
      output
      |> Enum.filter(&(Normalizer.value(&1, :type) == "message"))
      |> Enum.map(&Normalizer.value(&1, :content))

    {answer, citations} = ResponseHelpers.answer_and_citations(message_groups, "output_text")

    calls =
      output
      |> Enum.filter(&(Normalizer.value(&1, :type) == "web_search_call"))
      |> Enum.map(fn call ->
        action = Normalizer.value(call, :action) || %{}

        %{
          id: Normalizer.value(call, :id),
          queries: queries(action),
          status: Normalizer.value(call, :status),
          metadata: %{"action" => Normalizer.value(action, :type)}
        }
      end)

    Normalizer.build(id(), answer, citations, calls, response["usage"] || %{}, %{
      "response_id" => response["id"],
      "model" => response["model"],
      "status" => response["status"]
    })
  end

  defp queries(action) do
    cond do
      is_list(Normalizer.value(action, :queries)) -> Normalizer.value(action, :queries)
      is_binary(Normalizer.value(action, :query)) -> [Normalizer.value(action, :query)]
      true -> []
    end
  end

  defp maybe_allowed_domains(tool, domains) when is_list(domains) do
    domains = domains |> Enum.filter(&valid_domain?/1) |> Enum.take(100)
    if domains == [], do: tool, else: Map.put(tool, "filters", %{"allowed_domains" => domains})
  end

  defp maybe_allowed_domains(tool, _domains), do: tool

  defp valid_domain?(domain),
    do:
      is_binary(domain) and domain != "" and byte_size(domain) <= 253 and
        not String.contains?(domain, ["://", "/", "@", "\0", "\r", "\n", "\t", " "])

  defp validate_options(opts) do
    with :ok <- validate_domains(opts[:allowed_domains]),
         :ok <-
           validate_enum(opts[:search_context_size], ~w(low medium high), :search_context_size),
         :ok <- validate_boolean(opts[:external_web_access], :external_web_access),
         :ok <-
           validate_optional_integer(opts[:max_output_tokens], 1, 100_000, :max_output_tokens) do
      :ok
    end
  end

  defp validate_domains(nil), do: :ok

  defp validate_domains(domains) when is_list(domains) do
    bounded = Enum.take(domains, 101)

    if length(bounded) <= 100 and Enum.all?(bounded, &valid_domain?/1),
      do: :ok,
      else: {:error, {:configuration, :invalid_allowed_domains}}
  end

  defp validate_domains(_domains), do: {:error, {:configuration, :invalid_allowed_domains}}

  defp validate_enum(nil, _allowed, _field), do: :ok

  defp validate_enum(value, allowed, field) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if is_binary(normalized) and Enum.member?(allowed, normalized),
      do: :ok,
      else: {:error, {:configuration, {:invalid_option, field}}}
  end

  defp validate_boolean(nil, _field), do: :ok
  defp validate_boolean(value, _field) when is_boolean(value), do: :ok
  defp validate_boolean(_value, field), do: {:error, {:configuration, {:invalid_option, field}}}

  defp validate_optional_integer(nil, _min, _max, _field), do: :ok

  defp validate_optional_integer(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp validate_optional_integer(_value, _min, _max, field),
    do: {:error, {:configuration, {:invalid_option, field}}}

  defp enum(value, allowed) when is_binary(value) do
    if Enum.member?(allowed, value), do: value
  end

  defp enum(value, allowed) when is_atom(value), do: value |> Atom.to_string() |> enum(allowed)
  defp enum(_value, _allowed), do: nil
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil

  defp bounded_integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp bounded_integer(_value, _min, _max), do: nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
