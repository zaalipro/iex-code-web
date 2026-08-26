defmodule IexCode.Research.DagStepHandlers.ReportSynthesize do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.{DagContracts, DagRuntime, Results}

  @fields ~w(max_input_tokens max_output_tokens max_cost_cents provider_snapshot_ref require_claim_ledger attachment_refs artifact_kind level_policy)
  @legacy_fields @fields -- ["provider_snapshot_ref"]

  @impl true
  def descriptor do
    %{
      kind: "research_report_synthesize",
      version: 1,
      effect_class: :provider,
      replay_policy: :safe,
      resource_contract: "research_model_request_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 180_000
    }
  end

  @impl true
  def validate_params(params, [_audit]) do
    with :ok <- validate_fields(params),
         :ok <- DagContracts.integer(params["max_input_tokens"], 256..200_000, :input_tokens),
         :ok <- DagContracts.integer(params["max_output_tokens"], 256..100_000, :output_tokens),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         :ok <- validate_snapshot_ref(params),
         true <- params["require_claim_ledger"] or {:error, {:params, :claims}},
         :ok <- DagContracts.attachment_refs(params["attachment_refs"]),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_report_draft" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies), do: {:error, :synthesis_requires_audit}

  @impl true
  def execute(params, context), do: execute(params, context, [])

  @doc false
  def execute(params, context, opts) when is_list(opts) do
    runtime = Keyword.get(opts, :runtime_module, DagRuntime)

    with {:ok, audit} <- DagContracts.dependency(context, "research.audit"),
         data <- DagContracts.data(audit),
         sources when is_list(sources) and sources != [] <- data["sources"],
         {:ok, attachment_context} <- attachment_context(params, context),
         {:ok, result} <-
           runtime.synthesize_report(
             %{
               "objective" => context.run.objective,
               "depth" => params["level_policy"]["level"],
               "sources" => sources,
               "claims" => data["claims"],
               "gaps" => data["gaps"],
               "attachment_context" => attachment_context,
               "max_input_tokens" => params["max_input_tokens"],
               "max_output_tokens" => params["max_output_tokens"],
               "max_cost_cents" => params["max_cost_cents"],
               "provider_snapshot_ref" => params["provider_snapshot_ref"]
             },
             context,
             opts
           ),
         markdown when is_binary(markdown) and markdown != "" <- result["markdown"] do
      DagContracts.wrap(
        "research.report_draft",
        "research_report_draft",
        %{
          "markdown" => markdown,
          "source_count" => length(sources),
          "claim_count" => length(data["claims"] || []),
          "gap_count" => length(data["gaps"] || [])
        },
        result["usage"] || %{}
      )
    else
      nil -> {:error, :invalid_audit_output}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_synthesis_output}
    end
  end

  defp attachment_context(%{"attachment_refs" => []}, _context), do: {:ok, []}

  defp attachment_context(%{"attachment_refs" => refs}, %{run: %{session_id: session_id}})
       when is_binary(session_id),
       do: Results.resolve_attachment_refs(refs, session_id, max_bytes: 90_000)

  defp attachment_context(_params, _context),
    do: {:error, :invalid_research_attachment_context}

  defp validate_fields(params) do
    case DagContracts.exact_fields(params, @fields) do
      :ok -> :ok
      {:error, _reason} -> DagContracts.exact_fields(params, @legacy_fields)
    end
  end

  defp validate_snapshot_ref(%{"provider_snapshot_ref" => reference}),
    do: DagContracts.bounded_string(reference, 500, :snapshot)

  defp validate_snapshot_ref(_params), do: :ok
end
