defmodule IexCode.Research.Providers.SearxNG do
  @moduledoc "Adapter for user-hosted SearxNG instances."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :searxng

  @impl true
  def search(query, opts) do
    case Keyword.get(opts, :base_url) do
      base when is_binary(base) and base != "" ->
        url = HTTP.endpoint(Keyword.put(opts, :allow_custom_endpoint, true), base, "/search")
        request_opts = Keyword.put(opts, :params, %{q: query, format: "json"})

        with {:ok, response} <- HTTP.request(:get, url, request_opts) do
          {:ok,
           Providers.results(
             name(),
             Enum.take(response["results"] || [], HTTP.limit(opts)),
             fn row ->
               %{
                 title: row["title"],
                 url: row["url"],
                 snippet: row["content"],
                 published_at: row["publishedDate"],
                 score: row["score"],
                 metadata: row
               }
             end
           )}
        end

      _ ->
        {:error, :missing_base_url}
    end
  end
end
