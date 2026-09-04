defmodule IexCode.Workflows.Steps.DeepResearchTest do
  use ExUnit.Case, async: true

  alias IexCode.Workflows.Steps.DeepResearch

  describe "execute/2" do
    test "executes deep research and produces source graph, conflict audit, and enriched report" do
      step = %{
        "id" => "step-1",
        "title" => "Research Step",
        "kind" => "deep_research",
        "params" => %{
          "query" => "Elixir OTP Supervision Trees",
          "level" => "deep",
          "max_sources" => 5
        }
      }

      context = %{}

      assert {:ok, output} = DeepResearch.execute(step, context)

      # 1. Core outputs
      assert output["query"] == "Elixir OTP Supervision Trees"
      assert output["level"] == "deep"
      assert output["status"] == "completed"
      assert is_integer(output["duration_ms"])
      assert output["sources_count"] >= 2

      # 2. Source Graph
      source_graph = output["source_graph"]
      assert is_map(source_graph)
      assert is_list(source_graph.nodes)
      assert is_list(source_graph.edges)
      assert is_map(source_graph.metrics)
      assert source_graph.metrics.total_nodes == length(source_graph.nodes)

      # 3. Enriched Citations
      assert is_list(output["citations"])
      first_cit = List.first(output["citations"])
      assert Map.has_key?(first_cit, "trust_score")
      assert Map.has_key?(first_cit, "domain")
      assert Map.has_key?(first_cit, "authority_category")
      assert Map.has_key?(first_cit, "relevance_score")

      # 4. Conflict Resolution Audit & Badges
      assert is_map(output["conflict_audit"])
      assert is_list(output["conflicts"])
      assert is_list(output["disputed_claims"])
      assert is_list(output["verified_claims"])
      assert is_list(output["consensus_claims"])
      assert is_binary(output["recommended_action"])

      # 5. Report Markdown formatting
      report = output["report"]
      assert String.contains?(report, "# Deep Research Report: Elixir OTP Supervision Trees")
      assert String.contains?(report, "## Executive Summary")
      assert String.contains?(report, "## Key Findings")
      assert String.contains?(report, "## Evidence Audit & Conflict Arbitration")
      assert String.contains?(report, "## Recommended Architectural Directives")
      assert String.contains?(report, "## Citation & Source Index")
    end

    test "returns error when query and research_topic are missing" do
      step = %{
        "id" => "step-bad",
        "title" => "",
        "kind" => "deep_research",
        "params" => %{}
      }

      assert {:error, msg} = DeepResearch.execute(step, %{})
      assert String.contains?(msg, "Missing query or research_topic")
    end

    test "falls back to research_topic or title when query is not explicitly specified" do
      step = %{
        "id" => "step-2",
        "title" => "Fallback Title Topic",
        "kind" => "deep_research",
        "params" => %{
          "research_topic" => "ETS Table Concurrency"
        }
      }

      assert {:ok, output} = DeepResearch.execute(step, %{})
      assert output["query"] == "ETS Table Concurrency"
      assert output["sources_count"] > 0
    end
  end
end
