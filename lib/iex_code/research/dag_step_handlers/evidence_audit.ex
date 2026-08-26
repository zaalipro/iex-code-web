defmodule IexCode.Research.DagStepHandlers.EvidenceAudit do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.DagContracts

  @fields ~w(round max_input_tokens max_output_tokens max_cost_cents require_claim_evidence_links require_conflict_detection artifact_kind level_policy)

  @impl true
  def descriptor do
    %{
      kind: "research_evidence_audit",
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
  def validate_params(params, [_fetched]) do
    with :ok <- DagContracts.exact_fields(params, @fields),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <- DagContracts.integer(params["max_input_tokens"], 256..100_000, :input_tokens),
         :ok <- DagContracts.integer(params["max_output_tokens"], 256..32_000, :output_tokens),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         true <- params["require_claim_evidence_links"] or {:error, {:params, :claims}},
         :ok <- DagContracts.boolean(params["require_conflict_detection"], :conflicts),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_claim_ledger" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies), do: {:error, :audit_requires_fetched_evidence}

  @impl true
  def execute(params, context) do
    with false <- DagContracts.cancelled?(context),
         {:ok, fetched} <- DagContracts.dependency(context, "research.fetched_evidence"),
         sources when is_list(sources) <- DagContracts.data(fetched)["sources"],
         false <- sources == [] do
      {sources, fetch_failures} = Enum.split_with(sources, &verified_source?/1)

      domains =
        sources |> Enum.map(&domain/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

      primary = Enum.count(sources, &primary_source?/1)
      fetched_count = length(sources)
      grounded_count = Enum.count(sources, &(Map.get(&1, "plane") == "grounded_citation"))
      policy = params["level_policy"]

      conflict_audit = conflict_audit(sources, params["require_conflict_detection"])

      gaps =
        []
        |> maybe_gap(length(sources) < policy["async_subagents"], "insufficient source diversity")
        |> maybe_gap(
          length(domains) < min(policy["async_subagents"], 4),
          "too few independent domains"
        )
        |> maybe_gap(primary == 0, "no likely primary or official source identified")
        |> maybe_gap(fetched_count == 0, "no source body fetched successfully")
        |> maybe_gap(
          conflict_audit["conflict_count"] > 0,
          "deterministic evidence conflict candidates require review"
        )

      claims =
        sources
        |> Enum.map(fn source ->
          %{
            "claim_id" => "source:" <> Map.get(source, "id", "unknown"),
            "evidence_ids" => [Map.get(source, "id", "unknown")],
            "status" => "evidence_candidate",
            "conflict_checked" => conflict_audit["checked"]
          }
        end)

      DagContracts.wrap("research.audit", "research_claim_ledger", %{
        "round" => params["round"],
        "sources" => sources,
        "fetch_failures" => Enum.map(fetch_failures, &fetch_failure/1),
        "claims" => claims,
        "gaps" => gaps,
        "conflict_audit" => conflict_audit,
        "coverage" => %{
          "source_count" => length(sources),
          "candidate_source_count" => length(sources) + length(fetch_failures),
          "fetch_failure_count" => length(fetch_failures),
          "domain_count" => length(domains),
          "likely_primary_source_count" => primary,
          "fetched_source_count" => fetched_count,
          "grounded_citation_count" => grounded_count,
          "sufficient" => gaps == []
        }
      })
    else
      true -> {:error, :cancelled}
      nil -> {:error, :invalid_fetched_evidence}
      {:error, _reason} = error -> error
    end
  end

  # This is deliberately a bounded, deterministic evidence-level audit rather
  # than a semantic entailment claim. It flags source pairs that discuss the
  # same material terms with opposite explicit negation polarity. The durable
  # method name makes that limited contract visible to synthesis and replay.
  defp conflict_audit(_sources, false) do
    %{
      "required" => false,
      "checked" => true,
      "method" => "not_requested",
      "conflict_count" => 0,
      "conflicts" => []
    }
  end

  defp conflict_audit(sources, true) do
    candidates =
      sources
      |> Enum.map(&conflict_candidate/1)
      |> Enum.with_index()

    conflicts =
      for {left, left_index} <- candidates,
          {right, right_index} <- candidates,
          left_index < right_index,
          conflict_candidate?(left, right),
          reduce: [] do
        acc ->
          [
            %{
              "left_evidence_id" => left.id,
              "right_evidence_id" => right.id,
              "shared_terms" =>
                left.terms
                |> MapSet.intersection(right.terms)
                |> MapSet.to_list()
                |> Enum.sort()
                |> Enum.take(12),
              "reason" => "opposite_explicit_negation_polarity"
            }
            | acc
          ]
      end
      |> Enum.reverse()
      |> Enum.take(100)

    %{
      "required" => true,
      "checked" => true,
      "method" => "deterministic_negation_overlap_v1",
      "conflict_count" => length(conflicts),
      "conflicts" => conflicts
    }
  end

  defp conflict_candidate(source) do
    text = Enum.join([Map.get(source, "title", ""), Map.get(source, "snippet", "")], " ")
    normalized = String.downcase(text)

    terms =
      normalized
      |> String.split(~r/[^[:alnum:]]+/u, trim: true)
      |> Enum.reject(&(String.length(&1) < 4 or &1 in stop_terms()))
      |> Enum.take(200)
      |> MapSet.new()

    %{
      id: Map.get(source, "id", "unknown"),
      negated?:
        Regex.match?(~r/\b(?:no|not|never|cannot|can't|without|fails?|failed)\b/u, normalized),
      terms: terms
    }
  end

  defp conflict_candidate?(left, right) do
    left.negated? != right.negated? and
      MapSet.size(MapSet.intersection(left.terms, right.terms)) >= 3
  end

  defp stop_terms,
    do:
      ~w(about after also been being between could evidence from have into more most other over source than that their there these they this those under using were what when where which while with would)

  defp domain(source) do
    case URI.parse(Map.get(source, "url", "")) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _uri -> nil
    end
  end

  defp primary_source?(source) do
    url = Map.get(source, "url", "")
    title = Map.get(source, "title", "")

    Regex.match?(
      ~r/(?:\.gov|\.edu|docs\.|documentation|standard|specification)/i,
      url <> " " <> title
    )
  end

  defp verified_source?(source) do
    Map.get(source, "fetched") == true and
      match?("sha256:" <> digest when byte_size(digest) == 64, Map.get(source, "content_hash")) and
      Regex.match?(~r/^sha256:[0-9a-f]{64}$/, Map.get(source, "content_hash"))
  end

  defp fetch_failure(source) do
    source
    |> Map.take(~w(id url title provider plane fetch_error))
    |> Map.put_new("fetch_error", "missing_verified_content_hash")
  end

  defp maybe_gap(gaps, true, gap), do: gaps ++ [gap]
  defp maybe_gap(gaps, false, _gap), do: gaps
end
