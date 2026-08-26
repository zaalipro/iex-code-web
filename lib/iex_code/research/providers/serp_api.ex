defmodule IexCode.Research.Providers.SerpApi do
  @moduledoc """
  SerpApi ranked search-results adapter.

  Google is the default engine. Other engines may be added only through an
  explicit allowlist so persisted configuration cannot select arbitrary paths.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}

  @engines ~w(google bing duckduckgo baidu yahoo yandex)

  @impl true
  def name, do: :serpapi

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         {:ok, engine} <- engine(opts),
         {:ok, country} <- Providers.optional_country(Keyword.get(opts, :country)),
         {:ok, language} <- language(Keyword.get(opts, :language)),
         url = HTTP.endpoint(opts, "https://serpapi.com/search.json", "/search.json"),
         params =
           %{q: query, engine: engine, api_key: api_key, num: HTTP.limit(opts)}
           |> maybe_put(:gl, country && String.downcase(country))
           |> maybe_put(:hl, language),
         {:ok, response} <- HTTP.request(:get, url, Keyword.put(opts, :params, params)),
         :ok <- successful_response(response) do
      {:ok,
       Providers.results(
         name(),
         limited_rows(response["organic_results"], HTTP.limit(opts)),
         fn row ->
           %{
             title: row["title"],
             url: row["link"],
             snippet: row["snippet"],
             published_at: row["date"],
             score: row["position"],
             metadata: row
           }
         end
       )}
    end
  end

  defp engine(opts) do
    case Keyword.get(opts, :engine, "google") do
      engine when engine in @engines -> {:ok, engine}
      _ -> {:error, :unsupported_engine}
    end
  end

  defp language(nil), do: {:ok, nil}

  defp language(value) do
    case Providers.language_filter(value) do
      {:ok, [language]} -> {:ok, language}
      {:ok, nil} -> {:ok, nil}
      _ -> {:error, :invalid_language}
    end
  end

  # SerpApi can encode provider failures in a successful HTTP response. Never
  # reflect that text because upstream messages may echo query credentials.
  defp successful_response(%{"error" => _error}), do: {:error, :provider_error}
  defp successful_response(_response), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp limited_rows(rows, limit) when is_list(rows), do: Enum.take(rows, limit)
  defp limited_rows(_rows, _limit), do: []
end
