defmodule IexCode.Research.Providers.Firecrawl do
  @moduledoc """
  Firecrawl Search v2 ranked web-search adapter.

  The federated gateway requests result metadata rather than full scraped page
  bodies. Source fetching remains a separate bounded research stage.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}

  @impl true
  def name, do: :firecrawl

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         {:ok, country} <- Providers.optional_country(Keyword.get(opts, :country)),
         {:ok, location} <-
           Providers.optional_string(Keyword.get(opts, :location), 200, :invalid_location),
         {:ok, safe} <-
           Providers.optional_boolean(Keyword.get(opts, :safe), :invalid_safe_search),
         {:ok, include_domains, exclude_domains} <-
           Providers.domain_filters(
             Keyword.get(opts, :include_domains),
             Keyword.get(opts, :exclude_domains),
             mutually_exclusive: true,
             max: 100
           ),
         url = HTTP.endpoint(opts, "https://api.firecrawl.dev/v2/search", "/v2/search"),
         body =
           %{query: query, limit: HTTP.limit(opts), sources: ["web"]}
           |> maybe_put(:country, country)
           |> maybe_put(:location, location)
           |> maybe_put(:safe, safe)
           |> maybe_put(:includeDomains, include_domains)
           |> maybe_put(:excludeDomains, exclude_domains),
         request_opts =
           opts
           |> Keyword.put(:json, body)
           |> Keyword.put(:headers, HTTP.header("authorization", "Bearer #{api_key}")),
         {:ok, response} <- HTTP.request(:post, url, request_opts),
         :ok <- successful_response(response) do
      {:ok,
       Providers.results(
         name(),
         limited_rows(get_in(response, ["data", "web"]), HTTP.limit(opts)),
         fn row ->
           %{
             title: row["title"],
             url: row["url"],
             snippet: row["description"],
             metadata: row
           }
         end
       )}
    end
  end

  # Do not reflect an upstream error string: it may contain request credentials.
  defp successful_response(%{"success" => false}), do: {:error, :provider_error}

  defp successful_response(_response), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp limited_rows(rows, limit) when is_list(rows), do: Enum.take(rows, limit)
  defp limited_rows(_rows, _limit), do: []
end
