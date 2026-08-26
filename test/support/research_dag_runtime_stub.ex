defmodule IexCode.TestResearchDagRuntimeStub do
  @moduledoc false

  def ranked_search(params, context, _opts) do
    if is_pid(context[:test_pid]), do: send(context.test_pid, {:ranked_runtime_params, params})

    {:ok,
     %{
       "provider" => params["provider"],
       "query" => params["query"],
       "results" => [
         %{
           "title" => "Official durable research documentation",
           "url" => "https://docs.example.test/durable",
           "snippet" => "Durable research persists evidence before synthesis.",
           "provider" => params["provider"]
         }
       ],
       "errors" => %{},
       "usage" => %{"request_count" => 1, "search_calls" => 1}
     }}
  end

  def grounded_search(params, _context, _opts) do
    {:ok,
     %{
       "provider" => params["provider"],
       "query" => params["query"],
       "answer" => "Evidence must be committed before synthesis.",
       "citations" => [
         %{
           "title" => "Grounded source",
           "url" => "https://grounded.example.test/source",
           "cited_text" => "Evidence must be committed before synthesis."
         }
       ],
       "search_calls" => [%{"queries" => [params["query"]], "status" => "completed"}],
       "usage" => %{
         "input_tokens" => 10,
         "output_tokens" => 8,
         "request_count" => 1,
         "search_calls" => 1
       }
     }}
  end

  def fetch_sources(params, _context, _opts) do
    sources =
      Enum.map(params["sources"], fn source ->
        source
        |> Map.put("snippet", "Fetched evidence body for #{source["title"]}")
        |> Map.put("fetched", true)
        |> Map.put("fetched_url", source["url"])
        |> Map.put("content_type", "text/html")
        |> Map.put("fetched_bytes", 100)
        |> Map.put("content_hash", "sha256:" <> String.duplicate("a", 64))
      end)

    {:ok, %{"sources" => sources, "usage" => %{"request_count" => length(sources)}}}
  end

  def synthesize_report(_params, _context, _opts) do
    {:ok,
     %{
       "markdown" => "# Findings\n\nDurable research preserves evidence before synthesis [1].",
       "usage" => %{"input_tokens" => 100, "output_tokens" => 30, "request_count" => 1}
     }}
  end
end
