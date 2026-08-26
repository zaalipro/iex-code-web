defmodule IexCode.Research.GroundedSearch.Normalizer do
  @moduledoc false

  alias IexCode.Research.GroundedSearch.GroundedAnswer
  alias IexCode.Execution.Limits

  @max_answer_bytes 250_000
  @max_citations 200
  @max_search_calls 100
  @max_query_bytes 20_000
  @max_title_bytes 2_000
  @max_cited_text_bytes 4_000

  def build(provider, answer, citations, search_calls, usage, metadata) do
    answer = bounded_string(answer, @max_answer_bytes)

    citations =
      citations
      |> Enum.take(@max_citations)
      |> Enum.flat_map(&citation/1)
      |> Enum.filter(&valid_citation_range?(&1, answer))

    search_calls = search_calls |> Enum.take(@max_search_calls) |> Enum.map(&search_call/1)

    cond do
      answer == "" ->
        {:error, {:invalid_response, :missing_answer}}

      search_calls == [] ->
        {:error, {:ungrounded_response, :no_search_calls}}

      citations == [] ->
        {:error, {:ungrounded_response, :no_citations}}

      true ->
        {:ok,
         %GroundedAnswer{
           answer: answer,
           citations: citations,
           search_calls: search_calls,
           usage: bounded_map(usage),
           provider: provider,
           metadata: bounded_map(metadata)
         }}
    end
  end

  def query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:error, {:configuration, :empty_query}}
      byte_size(query) > 100_000 -> {:error, {:configuration, :query_too_large}}
      true -> {:ok, query}
    end
  end

  def query(_query), do: {:error, {:configuration, :invalid_query}}

  def credentials(opts) do
    with api_key when is_binary(api_key) and api_key != "" and byte_size(api_key) <= 16_000 <-
           opts[:api_key],
         model when is_binary(model) <- opts[:model],
         true <- Limits.valid_model_name?(model) do
      {:ok, api_key, model}
    else
      nil -> {:error, {:configuration, :missing_api_key_or_model}}
      _ -> {:error, {:configuration, :invalid_api_key_or_model}}
    end
  end

  def cancelled?(opts) do
    case opts[:cancelled?] do
      fun when is_function(fun, 0) ->
        try do
          fun.() == true
        rescue
          _ -> true
        catch
          _, _ -> true
        end

      nil ->
        false

      _other ->
        true
    end
  end

  def text_blocks(blocks, type) when is_list(blocks) do
    blocks
    |> Enum.filter(&(value(&1, :type) == type))
    |> Enum.map(&(value(&1, :text) || ""))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  def text_blocks(_blocks, _type), do: ""

  def value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  def value(_map, _key), do: nil

  def list(value) when is_list(value), do: value
  def list(_value), do: []

  def bounded_string(value, limit) when is_binary(value) do
    value = String.replace_invalid(value)

    if byte_size(value) <= limit,
      do: value,
      else: value |> binary_part(0, limit) |> String.replace_invalid()
  end

  def bounded_string(value, limit), do: value |> to_string() |> bounded_string(limit)

  def bounded_map(value) when is_map(value) do
    value
    |> Enum.take(100)
    |> Map.new(fn {key, item} -> {bounded_key(key), bounded_value(item, 4)} end)
  end

  def bounded_map(_value), do: %{}

  defp citation(row) when is_map(row) do
    url = value(row, :url)

    if public_http_url?(url) do
      [
        %{
          url: bounded_string(url, 8_000),
          title: optional_string(value(row, :title), @max_title_bytes),
          start_index: nonnegative(value(row, :start_index)),
          end_index: nonnegative(value(row, :end_index)),
          cited_text: optional_string(value(row, :cited_text), @max_cited_text_bytes),
          metadata: bounded_map(value(row, :metadata))
        }
      ]
    else
      []
    end
  end

  defp citation(_row), do: []

  defp valid_citation_range?(%{start_index: nil, end_index: nil}, _answer), do: true

  defp valid_citation_range?(
         %{start_index: start_index, end_index: end_index, metadata: metadata},
         answer
       )
       when is_integer(start_index) and is_integer(end_index) do
    limit =
      if value(metadata, :index_unit) == "bytes",
        do: byte_size(answer),
        else: String.length(answer)

    start_index <= end_index and end_index <= limit
  end

  defp valid_citation_range?(_citation, _answer), do: false

  defp search_call(row) do
    queries =
      row
      |> value(:queries)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&bounded_string(&1, @max_query_bytes))
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(50)

    %{
      id: optional_string(value(row, :id), 500),
      queries: queries,
      status: optional_string(value(row, :status), 100),
      metadata: bounded_map(value(row, :metadata))
    }
  end

  defp public_http_url?(url) when is_binary(url) do
    if byte_size(url) <= 8_000 and not String.contains?(url, ["\0", "\r", "\n", "\t"]) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] ->
          safe_citation_host?(host)

        _ ->
          false
      end
    else
      false
    end
  end

  defp public_http_url?(_url), do: false

  defp safe_citation_host?(host) when is_binary(host) and host != "" do
    host = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      host == "localhost" or String.ends_with?(host, ".localhost") ->
        false

      String.contains?(host, ["%", "\\", "/", "\0", "\r", "\n", "\t", " "]) ->
        false

      true ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, address} -> IexCode.Research.URLGuard.public_address?(address)
          {:error, _reason} -> true
        end
    end
  end

  defp safe_citation_host?(_host), do: false

  defp optional_string(nil, _limit), do: nil
  defp optional_string(value, limit), do: bounded_string(value, limit)

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: nil

  defp bounded_key(key) when is_atom(key), do: key
  defp bounded_key(key) when is_binary(key), do: bounded_string(key, 200)
  defp bounded_key(_key), do: "redacted"

  defp bounded_value(_value, 0), do: :truncated

  defp bounded_value(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp bounded_value(value, _depth) when is_binary(value), do: bounded_string(value, 8_000)

  defp bounded_value(value, depth) when is_map(value),
    do:
      value
      |> Enum.take(100)
      |> Map.new(fn {key, item} -> {bounded_key(key), bounded_value(item, depth - 1)} end)

  defp bounded_value(value, depth) when is_list(value),
    do: value |> Enum.take(100) |> Enum.map(&bounded_value(&1, depth - 1))

  defp bounded_value(_value, _depth), do: :redacted
end
