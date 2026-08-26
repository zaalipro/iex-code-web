defmodule IexCode.Research.Providers.Brave do
  @moduledoc "Brave Web Search API adapter."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :brave

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         url =
           HTTP.endpoint(
             opts,
             "https://api.search.brave.com/res/v1/web/search",
             "/web/search"
           ),
         request_opts =
           opts
           |> Keyword.put(:params, %{q: query, count: HTTP.limit(opts)})
           |> Keyword.put(:headers, HTTP.header("x-subscription-token", api_key)),
         {:ok, response} <- HTTP.request(:get, url, request_opts) do
      {:ok,
       Providers.results(name(), get_in(response, ["web", "results"]), fn row ->
         %{
           title: row["title"],
           url: row["url"],
           snippet: row["description"],
           published_at: row["age"],
           metadata: row
         }
       end)}
    end
  end
end
