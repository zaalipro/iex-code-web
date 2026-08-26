defmodule IexCode.Research.DagAdapter do
  @moduledoc """
  Produces the bounded, plain-node manifest for finite multi-pass research.

  Nodes use the canonical `IexCode.Runs.DagManifest` fields and resolve through
  the closed typed registry. Named levels bind immutable round and asynchronous
  fanout limits; no manifest-supplied module or executable callback is accepted.
  """

  alias IexCode.Research.{GroundedSearch, Launch, LevelPolicy, Registry}

  @required_kinds ~w(
    research_plan
    research_ranked_search
    research_grounded_search
    research_evidence_merge
    research_source_fetch
    research_evidence_audit
    research_report_synthesize
    research_report_verify
  )
  @max_rounds 4
  @max_manifest_steps 128

  @type dag_node :: %{
          required(:key) => String.t(),
          required(:kind) => String.t(),
          required(:title) => String.t(),
          required(:depends_on) => [String.t()],
          required(:params) => map(),
          required(:max_attempts) => pos_integer()
        }

  @doc "Registered research handler kinds required by this manifest."
  @spec required_kinds() :: [String.t()]
  def required_kinds, do: @required_kinds

  @doc "Builds canonical plain nodes for the activated finite research engine."
  @spec build(String.t(), keyword()) :: {:ok, [dag_node()]} | {:error, term()}
  def build(objective, opts \\ [])

  def build(objective, opts) when is_binary(objective) and is_list(opts) do
    objective = String.trim(objective)

    with :ok <- valid_objective(objective),
         {:ok, ranked} <- ranked_providers(Keyword.get(opts, :ranked_providers, [])),
         {:ok, grounded} <- grounded_providers(Keyword.get(opts, :grounded_providers, [])),
         :ok <- evidence_plane(ranked, grounded),
         {:ok, level_policy} <- LevelPolicy.fetch(Keyword.get(opts, :level, "medium")),
         {:ok, max_sources} <- Launch.normalize_max_sources(Keyword.get(opts, :max_sources)),
         :ok <- validate_round_override(opts[:max_rounds], level_policy.multistep_rounds),
         :ok <- manifest_size(level_policy.multistep_rounds, length(ranked) + length(grounded)) do
      opts = Keyword.put(opts, :max_sources, max_sources)
      nodes = nodes(objective, ranked, grounded, level_policy.multistep_rounds, opts)
      {:ok, apply_level_policy(nodes, level_policy)}
    end
  end

  def build(_objective, _opts), do: {:error, :invalid_research_objective}

  defp nodes(objective, ranked, grounded, rounds, opts) do
    {round_nodes, final_audit} =
      Enum.reduce(1..rounds, {[], nil}, fn round, {nodes, prior_audit} ->
        plan = plan_node(objective, ranked, grounded, round, prior_audit, opts)
        searches = search_nodes(ranked, grounded, round, plan.key, opts)
        merge = merge_node(round, searches, prior_audit, opts)
        fetch = fetch_node(round, merge.key, opts)
        audit = audit_node(round, fetch.key, opts)
        {nodes ++ [plan] ++ searches ++ [merge, fetch, audit], audit.key}
      end)

    synthesis = synthesis_node(final_audit, opts)
    round_nodes ++ [synthesis, verification_node(synthesis.key, final_audit, opts)]
  end

  defp plan_node(objective, ranked, grounded, round, prior_audit, opts) do
    node(
      "research.plan.#{round}",
      "research_plan",
      if(round == 1, do: "Plan evidence acquisition", else: "Adapt research round #{round}"),
      List.wrap(prior_audit),
      %{
        "objective" => objective,
        "round" => round,
        "ranked_providers" => ranked,
        "grounded_providers" => grounded,
        "provider_snapshot_ref" => provider_snapshot_ref(opts[:provider_snapshot_ref]),
        "max_queries" => bounded(opts[:max_queries_per_round], 1, 32, 8),
        "max_cost_cents" => bounded(opts[:plan_cost_cents], 0, 100_000, 500),
        "coverage_policy" => %{
          "minimum_primary_sources" => bounded(opts[:minimum_primary_sources], 0, 50, 3),
          "minimum_independent_domains" => bounded(opts[:minimum_independent_domains], 1, 50, 4),
          "require_conflict_audit" => Keyword.get(opts, :require_conflict_audit, true),
          "skip_round_when_prior_audit_is_sufficient" => round > 1
        },
        "artifact_kind" => "research_plan"
      },
      2
    )
  end

  defp search_nodes(ranked, grounded, round, plan_key, opts) do
    ranked_nodes =
      Enum.map(ranked, fn provider ->
        node(
          "research.search.ranked.#{round}.#{provider}",
          "research_ranked_search",
          "Ranked search · #{provider} · round #{round}",
          [plan_key],
          %{
            "plane" => "ranked_results",
            "provider" => provider,
            "round" => round,
            "provider_snapshot_ref" => provider_snapshot_ref(opts[:provider_snapshot_ref]),
            "max_search_calls" => bounded(opts[:max_queries_per_round], 1, 32, 8),
            "max_results" => bounded(opts[:max_results_per_provider], 1, 50, 20),
            "max_cost_cents" => bounded(opts[:ranked_search_cost_cents], 0, 100_000, 500),
            "artifact_kind" => "research_query_ledger"
          },
          2
        )
      end)

    grounded_nodes =
      Enum.map(grounded, fn provider ->
        node(
          "research.search.grounded.#{round}.#{provider}",
          "research_grounded_search",
          "Grounded search · #{provider} · round #{round}",
          [plan_key],
          %{
            "plane" => "grounded_answer",
            "provider" => provider,
            "round" => round,
            "provider_snapshot_ref" => provider_snapshot_ref(opts[:provider_snapshot_ref]),
            "max_search_calls" => bounded(opts[:max_grounded_calls_per_round], 1, 16, 4),
            "max_input_tokens" => bounded(opts[:grounded_input_tokens], 256, 100_000, 12_000),
            "max_output_tokens" => bounded(opts[:grounded_output_tokens], 256, 100_000, 4_096),
            "max_cost_cents" => bounded(opts[:grounded_search_cost_cents], 0, 100_000, 1_000),
            "artifact_kind" => "research_grounded_answer"
          },
          2
        )
      end)

    ranked_nodes ++ grounded_nodes
  end

  defp merge_node(round, searches, prior_audit, opts) do
    node(
      "research.evidence.merge.#{round}",
      "research_evidence_merge",
      "Normalize and merge evidence · round #{round}",
      Enum.map(searches, & &1.key) ++ List.wrap(prior_audit),
      %{
        "round" => round,
        "max_sources" => bounded(opts[:max_sources], 1, Launch.max_sources(), 40),
        "preserve_provider_rank" => true,
        "grounded_answers_are_not_ranked_rows" => true,
        "canonicalize_urls" => true,
        "artifact_kind" => "research_evidence"
      },
      2
    )
  end

  defp fetch_node(round, merge_key, opts) do
    node(
      "research.source.fetch.#{round}",
      "research_source_fetch",
      "Fetch bounded public evidence · round #{round}",
      [merge_key],
      %{
        "round" => round,
        "max_sources" => bounded(opts[:max_sources], 1, Launch.max_sources(), 40),
        "max_requests" => bounded(opts[:max_sources], 1, Launch.max_sources(), 40),
        "max_cost_cents" => bounded(opts[:source_fetch_cost_cents], 0, 100_000, 0),
        "max_parallel_fetches" => bounded(opts[:fetch_parallelism], 1, 16, 6),
        "max_body_bytes" => bounded(opts[:max_body_bytes], 1_000, 5_000_000, 750_000),
        "max_text_chars" => bounded(opts[:max_text_chars], 1_000, 200_000, 20_000),
        "require_public_destination" => true,
        "artifact_kind" => "research_fetched_evidence"
      },
      2
    )
  end

  defp audit_node(round, fetch_key, opts) do
    node(
      "research.evidence.audit.#{round}",
      "research_evidence_audit",
      "Audit coverage and conflicts · round #{round}",
      [fetch_key],
      %{
        "round" => round,
        "max_input_tokens" => bounded(opts[:audit_input_tokens], 256, 100_000, 24_000),
        "max_output_tokens" => bounded(opts[:audit_output_tokens], 256, 32_000, 4_096),
        "max_cost_cents" => bounded(opts[:audit_cost_cents], 0, 100_000, 500),
        "require_claim_evidence_links" => true,
        "require_conflict_detection" => Keyword.get(opts, :require_conflict_audit, true),
        "artifact_kind" => "research_claim_ledger"
      },
      2
    )
  end

  defp synthesis_node(audit_key, opts) do
    node(
      "research.report.synthesize",
      "research_report_synthesize",
      "Synthesize evidence-grounded report",
      [audit_key],
      %{
        "max_input_tokens" => bounded(opts[:synthesis_input_tokens], 256, 200_000, 64_000),
        "max_output_tokens" => bounded(opts[:synthesis_output_tokens], 256, 100_000, 12_000),
        "max_cost_cents" => bounded(opts[:synthesis_cost_cents], 0, 100_000, 2_000),
        "provider_snapshot_ref" => provider_snapshot_ref(opts[:provider_snapshot_ref]),
        "require_claim_ledger" => true,
        "attachment_refs" => attachment_refs(opts[:attachment_refs]),
        "artifact_kind" => "research_report_draft"
      },
      2
    )
  end

  defp verification_node(synthesis_key, audit_key, opts) do
    node(
      "research.report.verify",
      "research_report_verify",
      "Verify report claims and citations",
      [synthesis_key, audit_key],
      %{
        "max_input_tokens" => bounded(opts[:verification_input_tokens], 256, 200_000, 64_000),
        "max_output_tokens" => bounded(opts[:verification_output_tokens], 256, 32_000, 4_096),
        "max_cost_cents" => bounded(opts[:verification_cost_cents], 0, 100_000, 1_000),
        "require_sentence_level_citations" => true,
        "reject_missing_evidence_hashes" => true,
        "reject_fabricated_urls" => true,
        "artifact_kind" => "research_verified_report"
      },
      2
    )
  end

  defp node(key, kind, title, depends_on, params, max_attempts) do
    %{
      key: key,
      kind: kind,
      title: title,
      depends_on: depends_on,
      params: params,
      max_attempts: max_attempts
    }
  end

  defp ranked_providers(values) when is_list(values) do
    normalize_providers(values, fn provider ->
      match?({:ok, _}, Registry.descriptor(provider)) and
        Registry.automatically_selectable?(provider)
    end)
  end

  defp ranked_providers(_values), do: {:error, :invalid_ranked_providers}

  defp grounded_providers(values) when is_list(values) do
    normalize_providers(values, fn provider ->
      match?({:ok, %{status: :supported}}, GroundedSearch.descriptor(provider))
    end)
  end

  defp grounded_providers(_values), do: {:error, :invalid_grounded_providers}

  defp normalize_providers(values, valid?) do
    normalized = Enum.map(values, &provider_id/1)

    cond do
      Enum.any?(normalized, &is_nil/1) -> {:error, :invalid_research_provider}
      Enum.any?(normalized, &(not valid?.(&1))) -> {:error, :unsupported_research_provider}
      true -> {:ok, Enum.uniq(normalized)}
    end
  end

  defp provider_id(value) when is_atom(value), do: Atom.to_string(value)
  defp provider_id(value) when is_binary(value), do: String.trim(value)
  defp provider_id(_value), do: nil

  defp evidence_plane([], []), do: {:error, :no_research_provider}
  defp evidence_plane(_ranked, _grounded), do: :ok

  defp manifest_size(requested, provider_count) when requested in 1..@max_rounds do
    steps_per_round = provider_count + 4
    maximum = div(@max_manifest_steps - 2, steps_per_round)

    if requested <= maximum,
      do: :ok,
      else: {:error, {:research_manifest_too_large, @max_manifest_steps}}
  end

  defp validate_round_override(nil, _expected), do: :ok
  defp validate_round_override(expected, expected), do: :ok
  defp validate_round_override(_requested, _expected), do: {:error, :research_level_policy_drift}

  defp apply_level_policy(nodes, policy) do
    durable = LevelPolicy.durable(policy)

    Enum.map(nodes, fn node ->
      params =
        node.params
        |> Map.put("level_policy", durable)
        |> ensure_subagent_work(node.kind, policy.async_subagents)

      %{node | params: params}
    end)
  end

  defp ensure_subagent_work(params, "research_plan", subagents),
    do: Map.put(params, "max_queries", subagents)

  defp ensure_subagent_work(params, kind, subagents)
       when kind in ["research_ranked_search", "research_grounded_search"],
       do: Map.put(params, "max_search_calls", subagents)

  defp ensure_subagent_work(params, _kind, _subagents), do: params

  # Leaves ample room below DagManifest's 64 KB JSON params ceiling for policy.
  defp valid_objective(value) when byte_size(value) in 1..50_000, do: :ok
  defp valid_objective(_value), do: {:error, :invalid_research_objective}

  defp provider_snapshot_ref(value) when is_binary(value) and byte_size(value) in 1..500,
    do: value

  defp provider_snapshot_ref(_value), do: "settings://search-providers/current"

  defp attachment_refs(refs) when is_list(refs), do: refs
  defp attachment_refs(_refs), do: []

  defp bounded(value, min, max, _default)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp bounded(_value, _min, _max, default), do: default
end
