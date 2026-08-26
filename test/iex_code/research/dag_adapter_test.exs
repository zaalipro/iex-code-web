defmodule IexCode.Research.DagAdapterTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.DagAdapter
  alias IexCode.Runs.DagManifest

  @canonical_fields ~w(key kind title depends_on params max_attempts)a

  test "emits canonical static nodes with adaptive rounds and visible provider fanout" do
    assert {:ok, nodes} =
             DagAdapter.build("Compare durable asynchronous coding harnesses",
               ranked_providers: [:tavily, "brave"],
               grounded_providers: [:openai_responses],
               level: "medium",
               max_queries_per_round: 10,
               max_sources: 40,
               provider_snapshot_ref: "settings://search-providers/revision/42"
             )

    assert length(nodes) == 16
    assert Enum.all?(nodes, &(Map.keys(&1) |> Enum.sort() == Enum.sort(@canonical_fields)))

    first_plan = Enum.find(nodes, &(&1.key == "research.plan.1"))
    second_plan = Enum.find(nodes, &(&1.key == "research.plan.2"))
    assert first_plan.depends_on == []
    assert second_plan.depends_on == ["research.evidence.audit.1"]
    assert second_plan.params["coverage_policy"]["skip_round_when_prior_audit_is_sufficient"]

    ranked = Enum.filter(nodes, &(&1.kind == "research_ranked_search"))
    grounded = Enum.filter(nodes, &(&1.kind == "research_grounded_search"))
    assert length(ranked) == 4
    assert length(grounded) == 2
    assert Enum.all?(ranked, &(&1.params["plane"] == "ranked_results"))
    assert Enum.all?(grounded, &(&1.params["plane"] == "grounded_answer"))

    merge = Enum.find(nodes, &(&1.key == "research.evidence.merge.1"))
    assert merge.params["grounded_answers_are_not_ranked_rows"]

    assert Enum.sort(merge.depends_on) ==
             Enum.sort([
               "research.search.ranked.1.tavily",
               "research.search.ranked.1.brave",
               "research.search.grounded.1.openai_responses"
             ])

    assert List.last(nodes).kind == "research_report_verify"
  end

  test "fails closed for missing, unknown, or unsupported provider identifiers" do
    assert {:error, :no_research_provider} = DagAdapter.build("Research", [])

    assert {:error, :unsupported_research_provider} =
             DagAdapter.build("Research", ranked_providers: ["made_up"])

    assert {:error, :unsupported_research_provider} =
             DagAdapter.build("Research", grounded_providers: ["azure_foundry"])

    assert {:error, :unsupported_research_provider} =
             DagAdapter.build("Research", ranked_providers: ["bing"])
  end

  test "rejects a source count above the finalizer contract instead of truncating" do
    assert {:error, {:research_max_sources_out_of_range, %{minimum: 1, maximum: 40, value: 41}}} =
             DagAdapter.build("Research",
               ranked_providers: ["duckduckgo"],
               max_sources: 41
             )
  end

  test "canonical registry accepts the fully registered typed research manifest" do
    assert {:ok, nodes} =
             DagAdapter.build("Research", ranked_providers: ["duckduckgo"], level: "low")

    assert {:ok, normalized} = DagManifest.normalize(nodes)
    assert length(normalized) == length(nodes)

    assert Enum.all?(DagAdapter.required_kinds(), &(&1 in DagManifest.kinds()))
  end

  test "keeps credentials out, exposes artifact boundaries, and bounds node count" do
    assert {:ok, nodes} =
             DagAdapter.build("Research",
               ranked_providers: ["duckduckgo"],
               grounded_providers: ["anthropic_messages"],
               level: "ultra",
               provider_snapshot_ref: "settings://search-providers/current"
             )

    assert length(nodes) <= 128
    encoded = Jason.encode!(nodes)
    refute encoded =~ "api_key"
    refute encoded =~ "authorization"

    kinds = nodes |> Enum.map(& &1.params["artifact_kind"]) |> Enum.uniq()
    assert "research_query_ledger" in kinds
    assert "research_claim_ledger" in kinds
    assert "research_verified_report" in kinds

    assert DagAdapter.required_kinds() ==
             ~w(
               research_plan
               research_ranked_search
               research_grounded_search
               research_evidence_merge
               research_source_fetch
               research_evidence_audit
               research_report_synthesize
               research_report_verify
             )
  end

  test "all current providers at ultra remain within the canonical 128-step limit" do
    ranked =
      ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google searxng duckduckgo)

    grounded = ~w(openai_responses anthropic_messages gemini_interactions)

    assert {:ok, nodes} =
             DagAdapter.build("Research",
               ranked_providers: ranked,
               grounded_providers: grounded,
               level: "ultra"
             )

    assert length(nodes) == 74
    assert length(nodes) <= 128
    assert Enum.count(nodes, &(&1.kind == "research_ranked_search")) == 44
    assert Enum.count(nodes, &(&1.kind == "research_grounded_search")) == 12

    assert Enum.all?(Enum.filter(nodes, &(&1.kind == "research_plan")), fn node ->
             node.params["max_queries"] == 10
           end)

    assert Enum.all?(
             Enum.filter(
               nodes,
               &(&1.kind in ~w(research_ranked_search research_grounded_search))
             ),
             fn node -> node.params["max_search_calls"] == 10 end
           )

    assert Enum.all?(nodes, fn node ->
             node.params["level_policy"] == %{
               "level" => "ultra",
               "multistep_rounds" => 4,
               "lead_per_step" => 1,
               "async_subagents" => 10
             }
           end)
  end

  test "rejects a manual round override that drifts from the named level" do
    assert {:error, :research_level_policy_drift} =
             DagAdapter.build("Research",
               ranked_providers: ["duckduckgo"],
               level: "high",
               max_rounds: 4
             )
  end

  test "all named levels produce their exact immutable DAG shape" do
    for {level, rounds, subagents, node_count} <- [
          {"low", 1, 2, 7},
          {"medium", 2, 3, 12},
          {"high", 3, 4, 17},
          {"ultra", 4, 10, 22}
        ] do
      assert {:ok, nodes} =
               DagAdapter.build("Exact #{level} shape",
                 ranked_providers: ["duckduckgo"],
                 level: level
               )

      assert length(nodes) == node_count
      assert Enum.count(nodes, &(&1.kind == "research_plan")) == rounds
      assert Enum.count(nodes, &(&1.kind == "research_ranked_search")) == rounds
      assert Enum.count(nodes, &(&1.kind == "research_evidence_merge")) == rounds
      assert Enum.count(nodes, &(&1.kind == "research_source_fetch")) == rounds
      assert Enum.count(nodes, &(&1.kind == "research_evidence_audit")) == rounds
      assert Enum.count(nodes, &(&1.kind == "research_report_synthesize")) == 1
      assert Enum.count(nodes, &(&1.kind == "research_report_verify")) == 1

      assert Enum.all?(nodes, fn node ->
               node.params["level_policy"] == %{
                 "level" => level,
                 "multistep_rounds" => rounds,
                 "lead_per_step" => 1,
                 "async_subagents" => subagents
               }
             end)
    end
  end
end
