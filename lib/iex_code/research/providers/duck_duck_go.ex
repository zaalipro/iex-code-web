defmodule IexCode.Research.Providers.DuckDuckGo do
  @moduledoc """
  Unofficial credential-free DuckDuckGo HTML search adapter.

  This parses DuckDuckGo's public HTML results and is not an official or
  stability-guaranteed DuckDuckGo API.
  """
  @behaviour IexCode.Research.Provider

  alias IexCode.Research.{HTTP, Providers}

  @impl true
  def name, do: :duckduckgo

  @impl true
  def search(query, opts) do
    url = HTTP.endpoint(opts, "https://html.duckduckgo.com/html/", "/html/")

    with {:ok, html} <- HTTP.request(:post, url, Keyword.put(opts, :form, q: query)),
         {:ok, document} <- Floki.parse_document(html) do
      rows =
        document
        |> Floki.find(".result")
        |> Enum.map(fn result ->
          link = result |> Floki.find(".result__a") |> List.first()

          %{
            title: link && Floki.text(link),
            url: link && link |> Floki.attribute("href") |> List.first() |> unwrap_url(),
            snippet: result |> Floki.find(".result__snippet") |> Floki.text()
          }
        end)

      {:ok, Providers.results(name(), Enum.take(rows, HTTP.limit(opts)), & &1)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_url(nil), do: nil

  defp unwrap_url(url) do
    case URI.parse(url) do
      %URI{query: query} when is_binary(query) -> URI.decode_query(query)["uddg"] || url
      _ -> url
    end
  end
end
