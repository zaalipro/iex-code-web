defmodule IexCode.Research.Providers.Linkup do
  @moduledoc """
  Linkup ranked Search API adapter.

  It always requests `searchResults`. Linkup's `sourcedAnswer` output is a
  grounded answer and intentionally remains outside the ranked provider plane.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}

  @impl true
  def name, do: :linkup

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         {:ok, include_domains, exclude_domains} <-
           Providers.domain_filters(
             Keyword.get(opts, :include_domains),
             Keyword.get(opts, :exclude_domains),
             max: 100
           ),
         {:ok, from_date} <-
           Providers.optional_date(Keyword.get(opts, :start_date), :iso8601, :invalid_start_date),
         {:ok, to_date} <-
           Providers.optional_date(Keyword.get(opts, :end_date), :iso8601, :invalid_end_date),
         :ok <- valid_date_range(from_date, to_date),
         {:ok, depth} <- depth(opts),
         url = HTTP.endpoint(opts, "https://api.linkup.so/v1/search", "/v1/search"),
         body =
           %{
             q: query,
             depth: depth,
             outputType: "searchResults",
             maxResults: HTTP.limit(opts)
           }
           |> maybe_put(:includeDomains, include_domains)
           |> maybe_put(:excludeDomains, exclude_domains)
           |> maybe_put(:fromDate, from_date)
           |> maybe_put(:toDate, to_date),
         request_opts =
           opts
           |> Keyword.put(:json, body)
           |> Keyword.put(:headers, HTTP.header("authorization", "Bearer #{api_key}")),
         {:ok, response} <- HTTP.request(:post, url, request_opts) do
      {:ok,
       Providers.results(name(), limited_rows(response["results"], HTTP.limit(opts)), fn row ->
         %{
           title: row["name"],
           url: row["url"],
           snippet: row["content"],
           metadata: row
         }
       end)}
    end
  end

  defp depth(opts) do
    case Keyword.get(opts, :search_depth) do
      nil -> {:ok, "standard"}
      value when value in ["fast", "standard", "deep"] -> {:ok, value}
      "quick" -> {:ok, "fast"}
      _ -> {:error, :invalid_search_depth}
    end
  end

  defp valid_date_range(nil, _to_date), do: :ok
  defp valid_date_range(_from_date, nil), do: :ok

  defp valid_date_range(from_date, to_date) do
    if Date.compare(Date.from_iso8601!(from_date), Date.from_iso8601!(to_date)) == :lt,
      do: :ok,
      else: {:error, :invalid_date_range}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp limited_rows(rows, limit) when is_list(rows), do: Enum.take(rows, limit)
  defp limited_rows(_rows, _limit), do: []
end
