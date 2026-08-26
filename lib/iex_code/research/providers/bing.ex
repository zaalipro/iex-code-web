defmodule IexCode.Research.Providers.Bing do
  @moduledoc """
  Retired Microsoft Bing Web Search API compatibility adapter.

  Microsoft retired the Bing Search APIs on August 11, 2025. The adapter is
  retained only for explicit compatibility requests and is never selected by
  configuration-driven provider discovery.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :bing

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         url = HTTP.endpoint(opts, "https://api.bing.microsoft.com/v7.0/search", "/search"),
         request_opts =
           opts
           |> Keyword.put(:params, %{q: query, count: HTTP.limit(opts)})
           |> Keyword.put(:headers, HTTP.header("ocp-apim-subscription-key", api_key)),
         {:ok, response} <- HTTP.request(:get, url, request_opts) do
      {:ok,
       Providers.results(name(), get_in(response, ["webPages", "value"]), fn row ->
         %{
           title: row["name"],
           url: row["url"],
           snippet: row["snippet"],
           published_at: row["dateLastCrawled"],
           metadata: row
         }
       end)}
    end
  end
end
