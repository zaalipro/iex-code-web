defmodule IexCode.Research.Providers.GoogleCSE do
  @moduledoc "Legacy Google Programmable Search (Custom Search JSON API) adapter."
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}
  @impl true
  def name, do: :google

  @impl true
  def search(query, opts) do
    cx = Keyword.get(opts, :cx) || Keyword.get(opts, :engine_id)

    with {:ok, api_key} <- Providers.api_key(opts),
         true <- (is_binary(cx) and cx != "") || {:error, :missing_cx},
         url =
           HTTP.endpoint(
             opts,
             "https://customsearch.googleapis.com/customsearch/v1",
             "/customsearch/v1"
           ),
         request_opts =
           Keyword.put(opts, :params, %{
             q: query,
             key: api_key,
             cx: cx,
             num: min(HTTP.limit(opts), 10)
           }),
         {:ok, response} <- HTTP.request(:get, url, request_opts) do
      {:ok,
       Providers.results(name(), response["items"], fn row ->
         %{title: row["title"], url: row["link"], snippet: row["snippet"], metadata: row}
       end)}
    end
  end
end
