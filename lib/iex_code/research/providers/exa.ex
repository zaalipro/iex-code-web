defmodule IexCode.Research.Providers.Exa do
  @moduledoc "Exa neural search adapter."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :exa

  @impl true
  def search(query, opts) do
    with {:ok, api_key} <- Providers.api_key(opts),
         url = HTTP.endpoint(opts, "https://api.exa.ai/search", "/search"),
         body = %{
           query: query,
           numResults: HTTP.limit(opts),
           contents: %{text: %{maxCharacters: 1_000}}
         },
         request_opts =
           opts
           |> Keyword.put(:json, body)
           |> Keyword.put(:headers, HTTP.header("x-api-key", api_key)),
         {:ok, response} <- HTTP.request(:post, url, request_opts) do
      {:ok,
       Providers.results(name(), response["results"], fn row ->
         %{
           title: row["title"],
           url: row["url"],
           snippet: Providers.text(row["text"] || row["highlights"]),
           published_at: row["publishedDate"],
           score: row["score"],
           metadata: row
         }
       end)}
    end
  end
end
