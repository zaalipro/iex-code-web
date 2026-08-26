defmodule IexCode.Research.Providers.Serper do
  @moduledoc "Serper Google Search API adapter."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :serper

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         url = HTTP.endpoint(opts, "https://google.serper.dev/search", "/search"),
         request_opts =
           opts
           |> Keyword.put(:json, %{q: query, num: HTTP.limit(opts)})
           |> Keyword.put(:headers, HTTP.header("x-api-key", api_key)),
         {:ok, response} <- HTTP.request(:post, url, request_opts) do
      {:ok,
       Providers.results(name(), response["organic"], fn row ->
         %{
           title: row["title"],
           url: row["link"],
           snippet: row["snippet"],
           published_at: row["date"],
           score: row["position"],
           metadata: row
         }
       end)}
    end
  end
end
