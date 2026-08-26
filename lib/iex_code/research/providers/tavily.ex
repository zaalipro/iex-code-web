defmodule IexCode.Research.Providers.Tavily do
  @moduledoc "Tavily Search API adapter."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :tavily

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         url = HTTP.endpoint(opts, "https://api.tavily.com/search", "/search"),
         body = %{
           api_key: api_key,
           query: query,
           max_results: HTTP.limit(opts),
           include_answer: false
         },
         {:ok, response} <- HTTP.request(:post, url, Keyword.put(opts, :json, body)) do
      {:ok,
       Providers.results(name(), response["results"], fn row ->
         %{
           title: row["title"],
           url: row["url"],
           snippet: row["content"],
           score: row["score"],
           metadata: row
         }
       end)}
    end
  end
end
