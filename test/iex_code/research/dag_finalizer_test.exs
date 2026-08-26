defmodule IexCode.Research.DagFinalizerTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{DagContracts, DagFinalizer}
  alias IexCode.Runs.Run

  test "accepts only a completed checksummed verified terminal envelope" do
    assert {:ok, envelope} =
             DagContracts.wrap("research.verified_report", "research_verified_report", %{
               "verified" => true,
               "markdown" => "# Verified\n\nEvidence [1].",
               "sources" => [%{"id" => "one", "url" => "https://example.test"}],
               "claims" => [],
               "gaps" => []
             })

    step = %{
      id: "step-id",
      key: "research.report.verify",
      status: "completed",
      result: envelope
    }

    assert {:ok, verified} = DagFinalizer.verified_payload(step)
    assert verified.markdown =~ "Verified"
    assert verified.source_count == 1
    assert byte_size(verified.envelope_digest) == 64

    tampered = put_in(envelope, ["data", "markdown"], "tampered")

    assert {:error, :invalid_verified_research_payload} =
             DagFinalizer.verified_payload(%{step | result: tampered})

    assert {:error, :terminal_step_incomplete} =
             DagFinalizer.verified_payload(%{step | status: "running"})
  end

  test "rejects another contract, fabricated materialization, and oversized source sets" do
    assert {:ok, wrong} = DagContracts.wrap("research.report_draft", "research_report_draft", %{})

    assert {:error, :invalid_verified_research_payload} =
             DagFinalizer.verified_payload(%{
               key: "research.report.verify",
               status: "completed",
               result: wrong
             })

    sources =
      Enum.map(1..41, &%{"id" => Integer.to_string(&1), "url" => "https://example.test/#{&1}"})

    assert {:ok, oversized} =
             DagContracts.wrap("research.verified_report", "research_verified_report", %{
               "verified" => true,
               "markdown" => "# Verified\n\nEvidence [1].",
               "sources" => sources
             })

    assert {:error, :invalid_verified_research_payload} =
             DagFinalizer.verified_payload(%{
               key: "research.report.verify",
               status: "completed",
               result: oversized
             })
  end

  test "passes only a verified envelope to the idempotent public result commit boundary" do
    assert {:ok, envelope} =
             DagContracts.wrap("research.verified_report", "research_verified_report", %{
               "verified" => true,
               "markdown" => "# Verified\n\nEvidence [1].",
               "sources" => [%{"id" => "one", "url" => "https://example.test"}]
             })

    run = %Run{
      id: "00000000-0000-0000-0000-000000000001",
      kind: "deep_research",
      execution_engine: "dag_v1",
      status: "completed",
      manifest_hash: String.duplicate("a", 64)
    }

    step = %{
      id: "terminal-step",
      key: "research.report.verify",
      status: "completed",
      result: envelope
    }

    assert {:ok, %{status: "ready"}} =
             DagFinalizer.finalize(run,
               results_module: IexCode.TestResearchDagFinalizerResultsStub,
               step_resolver: fn ^run -> [step] end,
               root: "/tmp/research-finalizer-test"
             )

    assert_receive {:dag_finalizer_commit, %{id: 42}, markdown, opts}
    assert markdown =~ "Evidence"
    assert opts[:source_count] == 1
    assert opts[:root] == "/tmp/research-finalizer-test"
    assert opts[:metadata]["dag_step_id"] == "terminal-step"
    assert byte_size(opts[:metadata]["verified_envelope_sha256"]) == 64
  end
end
