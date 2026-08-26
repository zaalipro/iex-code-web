defmodule IexCode.Research.Providers.Perplexity do
  @moduledoc """
  Perplexity's first-party ranked Search API adapter.

  This calls the structured `/search` API. It deliberately does not call Sonar,
  which is a model-native grounded-answer API with a different response shape.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}

  @impl true
  def name, do: :perplexity

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         {:ok, country} <- Providers.optional_country(Keyword.get(opts, :country)),
         {:ok, languages} <- Providers.language_filter(Keyword.get(opts, :language)),
         {:ok, context_size} <- context_size(opts),
         {:ok, domains, _excluded} <-
           Providers.domain_filters(Keyword.get(opts, :include_domains), nil, max: 20),
         {:ok, after_date} <-
           Providers.optional_date(
             Keyword.get(opts, :search_after_date),
             :mdy,
             :invalid_search_after_date
           ),
         {:ok, before_date} <-
           Providers.optional_date(
             Keyword.get(opts, :search_before_date),
             :mdy,
             :invalid_search_before_date
           ),
         {:ok, recency} <-
           Providers.optional_enum(
             Keyword.get(opts, :recency),
             ~w(hour day week month year),
             :invalid_recency
           ),
         url = HTTP.endpoint(opts, "https://api.perplexity.ai/search", "/search"),
         body =
           %{query: query, max_results: min(HTTP.limit(opts), 20)}
           |> maybe_put(:country, country)
           |> maybe_put(:search_context_size, context_size)
           |> maybe_put(:search_language_filter, languages)
           |> maybe_put(:search_domain_filter, domains)
           |> maybe_put(:search_after_date_filter, after_date)
           |> maybe_put(:search_before_date_filter, before_date)
           |> maybe_put(:search_recency_filter, recency),
         request_opts =
           opts
           |> Keyword.put(:json, body)
           |> Keyword.put(:headers, HTTP.header("authorization", "Bearer #{api_key}")),
         {:ok, response} <- HTTP.request(:post, url, request_opts) do
      {:ok,
       Providers.results(
         name(),
         limited_rows(response["results"], min(HTTP.limit(opts), 20)),
         fn row ->
           %{
             title: row["title"],
             url: row["url"],
             snippet: row["snippet"],
             published_at: row["date"],
             metadata: row
           }
         end
       )}
    end
  end

  defp context_size(opts) do
    case Keyword.get(opts, :search_depth) do
      nil -> {:ok, nil}
      value when value in ["low", "medium", "high"] -> {:ok, value}
      "quick" -> {:ok, "low"}
      "standard" -> {:ok, "medium"}
      "deep" -> {:ok, "high"}
      _ -> {:error, :invalid_search_depth}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp limited_rows(rows, limit) when is_list(rows), do: Enum.take(rows, limit)
  defp limited_rows(_rows, _limit), do: []
end
