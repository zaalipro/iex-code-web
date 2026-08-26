defmodule IexCode.TestResearchDagRuntimeOversizedStub do
  @moduledoc false

  def ranked_search(params, _context, _opts) do
    row = %{
      "provider" => params["provider"],
      "title" => String.duplicate("title", 1_000),
      "url" => "https://example.test/" <> String.duplicate("u", 4_000),
      "snippet" => String.duplicate("evidence", 5_000),
      "published_at" => String.duplicate("date", 200),
      "score" => 0.9,
      "metadata" => %{"api_key" => "must-not-survive-compaction"}
    }

    {:ok,
     %{
       "provider" => params["provider"],
       "query" => params["query"],
       "results" => List.duplicate(row, 20),
       "errors" => %{},
       "usage" => %{"request_count" => 1, "search_calls" => 1}
     }}
  end

  def grounded_search(params, _context, _opts) do
    citation = %{
      "url" => "https://example.test/" <> String.duplicate("u", 4_000),
      "title" => String.duplicate("title", 1_000),
      "cited_text" => String.duplicate("evidence", 5_000),
      "metadata" => %{"api_key" => "must-not-survive-compaction"}
    }

    call = %{
      "id" => String.duplicate("call", 200),
      "status" => "completed",
      "queries" => List.duplicate(String.duplicate("query", 500), 12),
      "metadata" => %{"api_key" => "must-not-survive-compaction"}
    }

    {:ok,
     %{
       "provider" => params["provider"],
       "query" => params["query"],
       "answer" => String.duplicate("answer", 5_000),
       "citations" => List.duplicate(citation, 20),
       "search_calls" => List.duplicate(call, 12),
       "usage" => %{"request_count" => 1, "search_calls" => 1}
     }}
  end
end
