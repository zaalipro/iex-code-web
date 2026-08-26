defmodule IexCode.Research.DagStepHandlersTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{DagAdapter, DagContracts}

  alias IexCode.Research.DagStepHandlers.{
    EvidenceAudit,
    EvidenceMerge,
    GroundedSearch,
    Plan,
    RankedSearch,
    ReportSynthesize,
    ReportVerify,
    SourceFetch
  }

  @modules %{
    "research_plan" => Plan,
    "research_ranked_search" => RankedSearch,
    "research_grounded_search" => GroundedSearch,
    "research_evidence_merge" => EvidenceMerge,
    "research_source_fetch" => SourceFetch,
    "research_evidence_audit" => EvidenceAudit,
    "research_report_synthesize" => ReportSynthesize,
    "research_report_verify" => ReportVerify
  }

  test "every adapter node has an exact deterministic typed handler contract" do
    assert {:ok, nodes} =
             DagAdapter.build("Research durable evidence",
               level: "medium",
               ranked_providers: ["tavily"],
               grounded_providers: ["openai_responses"]
             )

    assert length(nodes) == 14

    Enum.each(nodes, fn node ->
      module = Map.fetch!(@modules, node.kind)
      assert module.descriptor().kind == node.kind
      assert module.validate_params(node.params, node.depends_on) == :ok

      assert {:error, _reason} =
               module.validate_params(Map.put(node.params, "unknown", true), node.depends_on)
    end)
  end

  test "v1 synthesis validation remains compatible with manifests predating routing refs" do
    assert {:ok, nodes} =
             DagAdapter.build("Legacy synthesis manifest",
               level: "low",
               ranked_providers: ["tavily"]
             )

    synthesis = find(nodes, "research.report.synthesize")
    legacy_params = Map.delete(synthesis.params, "provider_snapshot_ref")

    assert :ok = ReportSynthesize.validate_params(legacy_params, synthesis.depends_on)

    assert {:error, {:params, :invalid_fields}} =
             ReportSynthesize.validate_params(
               Map.put(legacy_params, "unexpected", true),
               synthesis.depends_on
             )
  end

  test "executes one finite round through typed evidence and verified report boundaries" do
    assert {:ok, nodes} =
             DagAdapter.build("Research durable evidence",
               level: "low",
               ranked_providers: ["tavily"],
               grounded_providers: ["openai_responses"]
             )

    context = context(%{})
    plan_node = find(nodes, "research.plan.1")
    assert {:ok, plan} = Plan.execute(plan_node.params, context)
    assert plan["contract"] == "research.plan"

    ranked_node = find(nodes, "research.search.ranked.1.tavily")
    grounded_node = find(nodes, "research.search.grounded.1.openai_responses")
    plan_context = context(%{"research.plan.1" => plan})

    assert {:ok, ranked} =
             RankedSearch.execute(ranked_node.params, plan_context,
               runtime_module: IexCode.TestResearchDagRuntimeStub
             )

    assert {:ok, grounded} =
             GroundedSearch.execute(grounded_node.params, plan_context,
               runtime_module: IexCode.TestResearchDagRuntimeStub
             )

    merge_node = find(nodes, "research.evidence.merge.1")

    assert {:ok, evidence} =
             EvidenceMerge.execute(
               merge_node.params,
               context(%{"ranked" => ranked, "grounded" => grounded})
             )

    assert evidence["contract"] == "research.evidence"
    assert evidence["data"]["source_count"] == 2
    assert Enum.any?(evidence["data"]["sources"], &(&1["plane"] == "grounded_citation"))

    fetch_node = find(nodes, "research.source.fetch.1")

    assert {:ok, fetched} =
             SourceFetch.execute(fetch_node.params, context(%{"evidence" => evidence}),
               runtime_module: IexCode.TestResearchDagRuntimeStub
             )

    audit_node = find(nodes, "research.evidence.audit.1")
    assert {:ok, audit} = EvidenceAudit.execute(audit_node.params, context(%{"fetch" => fetched}))
    assert audit["contract"] == "research.audit"
    assert Enum.all?(audit["data"]["claims"], &(&1["evidence_ids"] != []))
    assert audit["data"]["conflict_audit"]["required"]
    assert audit["data"]["conflict_audit"]["checked"]
    assert Enum.all?(audit["data"]["claims"], & &1["conflict_checked"])

    synthesis_node = find(nodes, "research.report.synthesize")

    assert {:ok, draft} =
             ReportSynthesize.execute(synthesis_node.params, context(%{"audit" => audit}),
               runtime_module: IexCode.TestResearchDagRuntimeStub
             )

    verify_node = find(nodes, "research.report.verify")

    assert {:ok, verified} =
             ReportVerify.execute(
               verify_node.params,
               context(%{"draft" => draft, "audit" => audit})
             )

    assert verified["contract"] == "research.verified_report"
    assert verified["data"]["verified"]
    assert verified["data"]["markdown"] =~ "## Verified source index"
    assert verified["data"]["verification"]["claim_entailment"] == "not_automatically_proven"
    assert verified["data"]["verification"]["conflict_audit"]["checked"]
  end

  test "ranked provider queries never receive attached report content from the plan envelope" do
    {:ok, nodes} =
      DagAdapter.build("Raw bounded objective", level: "low", ranked_providers: ["tavily"])

    plan_node = find(nodes, "research.plan.1")

    {:ok, plan} =
      DagContracts.wrap("research.plan", "research_plan", %{
        "objective" => "Raw bounded objective",
        "round" => 1,
        "queries" => ["Raw bounded objective"],
        "ranked_providers" => ["tavily"],
        "grounded_providers" => [],
        "provider_snapshot_ref" => plan_node.params["provider_snapshot_ref"],
        "coverage_policy" => plan_node.params["coverage_policy"],
        "prior_gaps" => [],
        "prior_research_context" => "PRIVATE ATTACHMENT SENTINEL"
      })

    ranked_node = find(nodes, "research.search.ranked.1.tavily")

    assert {:ok, _ranked} =
             RankedSearch.execute(
               ranked_node.params,
               context(%{"research.plan.1" => plan}) |> Map.put(:test_pid, self()),
               runtime_module: IexCode.TestResearchDagRuntimeStub
             )

    assert_receive {:ranked_runtime_params, runtime_params}
    assert runtime_params["query"] == "Raw bounded objective"
    refute inspect(runtime_params) =~ "PRIVATE ATTACHMENT SENTINEL"
  end

  test "the 50 KB raw objective remains executable under ultra plan fanout" do
    objective = String.duplicate("x", 50_000)
    {:ok, nodes} = DagAdapter.build(objective, level: "ultra", ranked_providers: ["tavily"])
    plan_node = find(nodes, "research.plan.1")

    assert {:ok, plan} = Plan.execute(plan_node.params, context(%{}))
    assert plan["data"]["objective"] == objective
    assert hd(plan["data"]["queries"]) == objective
    assert length(plan["data"]["queries"]) == 10
  end

  test "required conflict auditing flags deterministic opposite-polarity evidence" do
    assert {:ok, nodes} =
             DagAdapter.build("Audit conflicts",
               level: "low",
               ranked_providers: ["tavily"],
               require_conflict_audit: true
             )

    sources = [
      %{
        "id" => "supports",
        "url" => "https://one.example",
        "title" => "Replication succeeds",
        "snippet" => "The durable replication protocol preserves committed records safely.",
        "fetched" => true,
        "content_hash" => "sha256:" <> String.duplicate("a", 64)
      },
      %{
        "id" => "rejects",
        "url" => "https://two.example",
        "title" => "Replication fails",
        "snippet" =>
          "The durable replication protocol does not preserve committed records safely.",
        "fetched" => true,
        "content_hash" => "sha256:" <> String.duplicate("b", 64)
      }
    ]

    assert {:ok, fetched} =
             DagContracts.wrap("research.fetched_evidence", "research_fetched_evidence", %{
               "sources" => sources
             })

    audit_node = find(nodes, "research.evidence.audit.1")
    assert {:ok, audit} = EvidenceAudit.execute(audit_node.params, context(%{"fetch" => fetched}))
    assert audit["data"]["conflict_audit"]["conflict_count"] == 1
    assert [conflict] = audit["data"]["conflict_audit"]["conflicts"]
    assert conflict["left_evidence_id"] == "supports"
    assert conflict["right_evidence_id"] == "rejects"
    assert "deterministic evidence conflict candidates require review" in audit["data"]["gaps"]
  end

  test "verification fails closed when required conflict audit is incomplete" do
    assert {:ok, draft} =
             DagContracts.wrap("research.report_draft", "research_report_draft", %{
               "markdown" => "# Finding\n\nSupported [1]."
             })

    source = %{
      "id" => "one",
      "url" => "https://one.example",
      "title" => "One",
      "provider" => "tavily",
      "snippet" => "Supported"
    }

    assert {:ok, audit} =
             DagContracts.wrap("research.audit", "research_claim_ledger", %{
               "sources" => [source],
               "claims" => [
                 %{
                   "claim_id" => "source:one",
                   "evidence_ids" => ["one"],
                   "conflict_checked" => false
                 }
               ],
               "gaps" => [],
               "conflict_audit" => %{
                 "required" => true,
                 "checked" => false,
                 "method" => "pending",
                 "conflict_count" => 0,
                 "conflicts" => []
               }
             })

    assert {:error, :conflict_audit_incomplete} =
             ReportVerify.execute(%{}, context(%{"draft" => draft, "audit" => audit}))
  end

  test "outputs reject secrets and provider errors collapse to stable codes" do
    assert {:error, :secret_payload_forbidden} =
             DagContracts.wrap("research.test", "research_test", %{
               "api_key" => "must-not-persist"
             })

    assert DagContracts.error_code({:http_error, %{body: "private detail"}}) == "http_error"
    assert DagContracts.error_code(%RuntimeError{message: "private detail"}) == "provider_error"
  end

  test "provider batches compact oversized runtime rows before durable wrapping" do
    assert {:ok, nodes} =
             DagAdapter.build("Bound provider output",
               level: "low",
               max_queries_per_round: 1,
               max_rounds: 1,
               ranked_providers: ["tavily"],
               grounded_providers: ["openai_responses"]
             )

    plan_node = find(nodes, "research.plan.1")
    assert {:ok, plan} = Plan.execute(plan_node.params, context(%{}))
    plan_context = context(%{"research.plan.1" => plan})
    runtime = IexCode.TestResearchDagRuntimeOversizedStub

    assert {:ok, ranked} =
             nodes
             |> find("research.search.ranked.1.tavily")
             |> then(&RankedSearch.execute(&1.params, plan_context, runtime_module: runtime))

    assert {:ok, grounded} =
             nodes
             |> find("research.search.grounded.1.openai_responses")
             |> then(&GroundedSearch.execute(&1.params, plan_context, runtime_module: runtime))

    ranked_entries = ranked["data"]["entries"]
    grounded_entries = grounded["data"]["entries"]
    assert Enum.all?(ranked_entries, &(length(&1["results"]) == 6))

    assert Enum.all?(
             ranked_entries,
             &(String.length(hd(&1["results"])["snippet"]) == 700)
           )

    assert Enum.all?(grounded_entries, &(length(&1["citations"]) == 8))
    assert Enum.all?(grounded_entries, &(length(&1["search_calls"]) == 4))
    assert Enum.all?(grounded_entries, &(String.length(&1["answer"]) == 5_000))
    refute inspect({ranked, grounded}) =~ "must-not-survive-compaction"
    assert byte_size(Jason.encode!(ranked)) < 240_000
    assert byte_size(Jason.encode!(grounded)) < 240_000
  end

  test "report verification enforces evidence hashes, sentence citations, and source URLs" do
    assert {:ok, nodes} =
             DagAdapter.build("Verify report predicates",
               level: "low",
               ranked_providers: ["tavily"]
             )

    params = find(nodes, "research.report.verify").params

    source_url = "https://example.test/source"

    source = %{
      "id" => :crypto.hash(:sha256, source_url) |> Base.encode16(case: :lower),
      "url" => source_url,
      "title" => "Verified source",
      "provider" => "test",
      "snippet" => "Evidence",
      "content_hash" => "sha256:" <> String.duplicate("b", 64)
    }

    audit_data = %{
      "sources" => [source],
      "claims" => [
        %{
          "claim_id" => "source:" <> source["id"],
          "evidence_ids" => [source["id"]],
          "conflict_checked" => true
        }
      ],
      "gaps" => [],
      "conflict_audit" => %{
        "required" => true,
        "checked" => true,
        "conflict_count" => 0,
        "conflicts" => []
      }
    }

    assert {:ok, audit} =
             DagContracts.wrap("research.audit", "research_claim_ledger", audit_data)

    verify = fn markdown, current_audit ->
      {:ok, draft} =
        DagContracts.wrap("research.report_draft", "research_report_draft", %{
          "markdown" => markdown
        })

      ReportVerify.execute(params, context(%{"draft" => draft, "audit" => current_audit}))
    end

    assert {:error, {:uncited_research_sentences, 1}} =
             verify.("Supported claim [1]. Unsupported sentence.", audit)

    assert {:error, :fabricated_research_url} =
             verify.("Unsupported link [evil](https://evil.test/) is rejected [1].", audit)

    missing_hash =
      put_in(audit, ["data", "sources", Access.at(0)], Map.delete(source, "content_hash"))

    assert {:error, :evidence_hash_missing} = verify.("Supported claim [1].", missing_hash)

    assert {:ok, verified} =
             verify.("Supported source [1] is at https://example.test/source [1].", audit)

    assert verified["data"]["verified"]
  end

  test "failed fetch candidates remain observable but are not cited evidence" do
    assert {:ok, nodes} =
             DagAdapter.build("Audit partial fetches",
               level: "low",
               ranked_providers: ["tavily"]
             )

    verified_url = "https://example.test/verified"

    verified = %{
      "id" => :crypto.hash(:sha256, verified_url) |> Base.encode16(case: :lower),
      "url" => verified_url,
      "title" => "Verified source",
      "provider" => "test",
      "plane" => "ranked_result",
      "snippet" => "Fetched evidence",
      "fetched" => true,
      "content_hash" => "sha256:" <> String.duplicate("a", 64)
    }

    failed = %{
      "id" => String.duplicate("b", 64),
      "url" => "https://example.test/blocked.pdf",
      "title" => "Blocked candidate",
      "provider" => "test",
      "plane" => "ranked_result",
      "snippet" => "Search-result snippet only",
      "fetch_error" => "source_fetch_failed"
    }

    {:ok, fetched} =
      DagContracts.wrap("research.fetched_evidence", "research_fetched_evidence", %{
        "sources" => [verified, failed]
      })

    audit_params = find(nodes, "research.evidence.audit.1").params
    assert {:ok, audit} = EvidenceAudit.execute(audit_params, context(%{"fetch" => fetched}))

    assert audit["data"]["sources"] == [verified]

    assert audit["data"]["fetch_failures"] == [
             Map.take(failed, ~w(id url title provider plane fetch_error))
           ]

    assert audit["data"]["coverage"]["candidate_source_count"] == 2
    assert audit["data"]["coverage"]["fetch_failure_count"] == 1
    assert Enum.all?(audit["data"]["claims"], &(&1["evidence_ids"] == [verified["id"]]))

    {:ok, draft} =
      DagContracts.wrap("research.report_draft", "research_report_draft", %{
        "markdown" => "Verified evidence is available at #{verified_url} [1]."
      })

    verify_params = find(nodes, "research.report.verify").params

    assert {:ok, report} =
             ReportVerify.execute(
               verify_params,
               context(%{"draft" => draft, "audit" => audit})
             )

    assert report["data"]["verified"]
    refute report["data"]["markdown"] =~ failed["url"]
  end

  defp find(nodes, key), do: Enum.find(nodes, &(&1.key == key))

  defp context(dependencies) do
    %{
      run: %{objective: "Research durable evidence"},
      dependency_results: dependencies,
      cancelled?: fn -> false end,
      checkpoint_callback: fn _checkpoint, _progress -> :ok end
    }
  end
end
