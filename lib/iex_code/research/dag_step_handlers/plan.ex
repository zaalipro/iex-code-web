defmodule IexCode.Research.DagStepHandlers.Plan do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.DagContracts

  @fields ~w(objective round ranked_providers grounded_providers provider_snapshot_ref max_queries max_cost_cents coverage_policy artifact_kind level_policy)

  @impl true
  def descriptor do
    %{
      kind: "research_plan",
      version: 1,
      effect_class: :pure,
      replay_policy: :safe,
      resource_contract: "research_evidence_read_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 30_000
    }
  end

  @impl true
  def validate_params(params, dependencies) do
    with :ok <- DagContracts.exact_fields(params, @fields),
         :ok <- DagContracts.bounded_string(params["objective"], 50_000, :objective),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <- DagContracts.string_list(params["ranked_providers"], 32, 80, :ranked_providers),
         :ok <-
           DagContracts.string_list(params["grounded_providers"], 16, 80, :grounded_providers),
         :ok <- DagContracts.bounded_string(params["provider_snapshot_ref"], 500, :snapshot),
         :ok <- DagContracts.integer(params["max_queries"], 1..32, :max_queries),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :max_cost_cents),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         :ok <- validate_coverage(params["coverage_policy"]),
         :ok <- validate_dependencies(params["round"], dependencies),
         true <- params["artifact_kind"] == "research_plan" or {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def execute(params, context) do
    if DagContracts.cancelled?(context) do
      {:error, :cancelled}
    else
      gaps = prior_gaps(context)
      desired = params["level_policy"]["async_subagents"]

      queries =
        params["objective"]
        |> queries(params["round"], gaps)
        |> pad_queries(params["objective"], params["round"], desired)
        |> Enum.uniq()
        |> Enum.take(params["max_queries"])

      DagContracts.wrap("research.plan", "research_plan", %{
        "objective" => params["objective"],
        "round" => params["round"],
        "queries" => queries,
        "ranked_providers" => params["ranked_providers"],
        "grounded_providers" => params["grounded_providers"],
        "provider_snapshot_ref" => params["provider_snapshot_ref"],
        "coverage_policy" => params["coverage_policy"],
        "prior_gaps" => gaps
      })
    end
  end

  defp validate_coverage(policy) when is_map(policy) do
    fields =
      ~w(minimum_primary_sources minimum_independent_domains require_conflict_audit skip_round_when_prior_audit_is_sufficient)

    with :ok <- DagContracts.exact_fields(policy, fields),
         :ok <- DagContracts.integer(policy["minimum_primary_sources"], 0..50, :primary),
         :ok <- DagContracts.integer(policy["minimum_independent_domains"], 1..50, :domains),
         :ok <- DagContracts.boolean(policy["require_conflict_audit"], :conflict),
         :ok <- DagContracts.boolean(policy["skip_round_when_prior_audit_is_sufficient"], :skip) do
      :ok
    end
  end

  defp validate_coverage(_policy), do: {:error, {:params, :coverage_policy}}
  defp validate_dependencies(1, []), do: :ok
  defp validate_dependencies(round, [_one]) when round > 1, do: :ok
  defp validate_dependencies(_round, _dependencies), do: {:error, :invalid_plan_dependencies}

  defp prior_gaps(context) do
    case DagContracts.dependency(context, "research.audit") do
      {:ok, result} -> result |> DagContracts.data() |> Map.get("gaps", []) |> Enum.take(16)
      {:error, _reason} -> []
    end
  end

  defp queries(objective, 1, _gaps) do
    basis = query_basis(objective)

    [
      objective,
      "#{basis} primary sources official documentation",
      "#{basis} recent developments current evidence",
      "#{basis} limitations risks criticism",
      "#{basis} alternatives comparison",
      "#{basis} implementation case studies",
      "#{basis} empirical measurements benchmarks",
      "#{basis} security reliability failure modes",
      "#{basis} cost operational tradeoffs",
      "#{basis} future roadmap open questions"
    ]
  end

  defp queries(objective, _round, []) do
    [
      objective
      | queries(objective, 1, []) |> Enum.drop(1) |> Enum.map(&(&1 <> " updated evidence"))
    ]
  end

  defp queries(objective, _round, gaps) do
    basis = query_basis(objective)

    [
      objective
      | Enum.map(gaps, &"#{basis} #{String.slice(&1, 0, 500)}")
    ]
  end

  defp pad_queries(queries, objective, round, desired) do
    basis = query_basis(objective)

    padding =
      Enum.map(1..desired, fn ordinal ->
        "#{basis} research round #{round} evidence angle #{ordinal}"
      end)

    (queries ++ padding) |> Enum.uniq() |> Enum.take(desired)
  end

  defp query_basis(objective) when byte_size(objective) <= 8_000, do: objective

  defp query_basis(objective) do
    objective
    |> binary_part(0, 8_000)
    |> String.replace_invalid()
  end
end
