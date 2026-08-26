defmodule IexCode.Runs.DagStepRegistry do
  @moduledoc "Closed registry of typed `dag_v1` step handlers and replay contracts."

  @handlers %{
    "project_inventory" => IexCode.Runs.DagStepHandlers.ProjectInventory,
    "read_file" => IexCode.Runs.DagStepHandlers.ReadFile,
    "aggregate" => IexCode.Runs.DagStepHandlers.Aggregate,
    "research_plan" => IexCode.Research.DagStepHandlers.Plan,
    "research_ranked_search" => IexCode.Research.DagStepHandlers.RankedSearch,
    "research_grounded_search" => IexCode.Research.DagStepHandlers.GroundedSearch,
    "research_evidence_merge" => IexCode.Research.DagStepHandlers.EvidenceMerge,
    "research_source_fetch" => IexCode.Research.DagStepHandlers.SourceFetch,
    "research_evidence_audit" => IexCode.Research.DagStepHandlers.EvidenceAudit,
    "research_report_synthesize" => IexCode.Research.DagStepHandlers.ReportSynthesize,
    "research_report_verify" => IexCode.Research.DagStepHandlers.ReportVerify
  }

  def fetch(kind) when is_binary(kind), do: Map.fetch(@handlers, kind)
  def fetch(_kind), do: :error

  def descriptors do
    @handlers
    |> Enum.map(fn {kind, module} -> Map.put(module.descriptor(), :kind, kind) end)
    |> Enum.sort_by(& &1.kind)
  end

  def kinds, do: @handlers |> Map.keys() |> Enum.sort()

  def descriptor!(kind) do
    {:ok, module} = fetch(kind)
    module.descriptor()
  end

  def validate_params(kind, params, dependencies) do
    with {:ok, module} <- fetch(kind) do
      module.validate_params(params, dependencies)
    else
      :error -> {:error, {:unsupported_kind, kind}}
    end
  end
end
