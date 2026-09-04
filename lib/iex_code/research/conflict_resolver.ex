defmodule IexCode.Research.ConflictResolver do
  @moduledoc """
  Multi-source claim verification and contradiction resolution for Deep Research.

  Features:
  - Atomic claim extraction from snippets, research findings, and documentation
  - Semantic contradiction identification via subject co-occurrence and opposing polarity
  - Confidence-weighted consensus arbitration based on domain trust and relevance scores
  - Status badges (:verified, :consensus, :disputed) with color codes and rationales
  - Summary metrics and actionable architectural recommendations
  """

  alias IexCode.Research.SourceGraph

  @type status_type :: :verified | :consensus | :disputed

  @type claim :: %{
          id: String.t(),
          topic: String.t(),
          text: String.t(),
          source_id: String.t(),
          domain: String.t(),
          trust_score: float(),
          relevance_score: float(),
          composite_weight: float(),
          polarity: :positive | :negative,
          keywords: list(String.t()),
          statement_type: :architecture | :security | :version | :recommendation
        }

  @type conflict :: %{
          id: String.t(),
          topic: String.t(),
          status: status_type(),
          badge_label: String.t(),
          badge_color: String.t(),
          claim_a: claim(),
          claim_b: claim(),
          winning_claim: claim() | nil,
          confidence_ratio: float(),
          rationale: String.t(),
          recommendation: String.t()
        }

  @type resolution_result :: %{
          conflicts: list(conflict()),
          claims: list(claim()),
          summary: %{
            total_claims: non_neg_integer(),
            total_conflicts: non_neg_integer(),
            verified_count: non_neg_integer(),
            consensus_count: non_neg_integer(),
            disputed_count: non_neg_integer()
          },
          recommended_action: String.t()
        }

  @negation_indicators ~w(
    not never cannot cant doesn't does not shouldn't should not
    deprecated incompatible prohibited avoid unsupported antipattern anti-pattern
    unsafe fails broken obsolete unrecommended leaks bottleneck
  )

  @positive_indicators ~w(
    recommended supports supported compatible standard idiom idiomatic
    optimal verified essential canonical safe best-practice best practice
    performant scalable resilient robust
  )

  @doc """
  Extracts claims, evaluates contradictory statements, and synthesizes confidence-weighted resolutions.
  """
  @spec resolve(list() | map(), keyword()) :: resolution_result()
  def resolve(sources_or_result, opts \\ [])

  def resolve(%{citations: citations} = result, opts) when is_list(citations) do
    query = opts[:query] || Map.get(result, :query) || Map.get(result, "query") || ""
    resolve(citations, Keyword.put(opts, :query, query))
  end

  def resolve(%{"citations" => citations} = result, opts) when is_list(citations) do
    query = opts[:query] || Map.get(result, "query") || ""
    resolve(citations, Keyword.put(opts, :query, query))
  end

  def resolve(sources, opts) when is_list(sources) do
    query = to_string(opts[:query] || "")

    # 1. Extract atomic claims from sources
    claims = extract_claims(sources, query, opts)

    # 2. Identify and evaluate contradictory pairs
    conflicts = evaluate_conflicts(claims)

    # 3. Compute summary statistics
    verified_count = Enum.count(conflicts, &(&1.status == :verified))
    consensus_count = Enum.count(conflicts, &(&1.status == :consensus))
    disputed_count = Enum.count(conflicts, &(&1.status == :disputed))

    summary = %{
      total_claims: length(claims),
      total_conflicts: length(conflicts),
      verified_count: verified_count,
      consensus_count: consensus_count,
      disputed_count: disputed_count
    }

    # 4. Synthesize overarching recommended action
    recommended_action = synthesize_recommendations(conflicts, claims, query)

    %{
      conflicts: conflicts,
      claims: claims,
      summary: summary,
      recommended_action: recommended_action
    }
  end

  def resolve(_, _opts) do
    %{
      conflicts: [],
      claims: [],
      summary: %{
        total_claims: 0,
        total_conflicts: 0,
        verified_count: 0,
        consensus_count: 0,
        disputed_count: 0
      },
      recommended_action: "No sources provided for conflict audit."
    }
  end

  # ============================================================================
  # CLAIM EXTRACTION
  # ============================================================================

  @doc """
  Extracts structured claims from a list of sources or findings.
  """
  @spec extract_claims(list(), String.t(), keyword()) :: list(claim())
  def extract_claims(sources, query \\ "", opts \\ []) when is_list(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {source, s_idx} ->
      extract_claims_from_source(source, s_idx, query, opts)
    end)
  end

  defp extract_claims_from_source(source, s_idx, query, opts) when is_map(source) do
    url = get_val(source, :url) || get_val(source, "url") || "https://example.com/#{s_idx}"
    domain = get_val(source, :domain) || get_val(source, "domain") || extract_domain(url)

    trust_score =
      case get_val(source, :trust_score) || get_val(source, "trust_score") do
        s when is_number(s) -> Float.round(s * 1.0, 3)
        _ -> SourceGraph.calculate_trust(url, opts)
      end

    relevance_score =
      case get_val(source, :relevance_score) || get_val(source, "relevance_score") do
        r when is_number(r) ->
          Float.round(r * 1.0, 3)

        _ ->
          SourceGraph.calculate_relevance(
            query,
            get_val(source, :title) || "",
            get_val(source, :snippet) || "",
            opts
          )
      end

    source_id = to_string(get_val(source, :id) || get_val(source, "id") || url)

    # Check if explicit claim or findings exist
    explicit_claim = get_val(source, :claim) || get_val(source, "claim")
    snippet = get_val(source, :snippet) || get_val(source, "snippet") || ""
    title = get_val(source, :title) || get_val(source, "title") || ""

    sentences =
      cond do
        explicit_claim && explicit_claim != "" ->
          [explicit_claim]

        snippet != "" ->
          snippet
          |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
          |> Enum.filter(&(String.length(String.trim(&1)) > 15))

        title != "" ->
          [title]

        true ->
          []
      end

    sentences
    |> Enum.with_index(1)
    |> Enum.map(fn {sentence, c_idx} ->
      text = String.trim(sentence)
      polarity = detect_polarity(text)
      keywords = extract_keywords(text)
      topic = determine_topic(keywords, text, query)
      stmt_type = determine_statement_type(text)

      weight = Float.round(:math.pow(trust_score, 2.5) * relevance_score, 3)

      %{
        id: "#{source_id}-c#{c_idx}",
        topic: topic,
        text: text,
        source_id: source_id,
        domain: domain,
        trust_score: trust_score,
        relevance_score: relevance_score,
        composite_weight: weight,
        polarity: polarity,
        keywords: keywords,
        statement_type: stmt_type
      }
    end)
  end

  defp extract_claims_from_source(_, _, _, _), do: []

  # ============================================================================
  # CONFLICT EVALUATION & ARBITRATION
  # ============================================================================

  defp evaluate_conflicts(claims) do
    # Form distinct pairs of claims from different sources
    pairs =
      for a <- claims,
          b <- claims,
          a.id < b.id,
          a.source_id != b.source_id,
          do: {a, b}

    pairs
    |> Enum.filter(fn {a, b} -> is_contradictory?(a, b) end)
    |> Enum.map(fn {a, b} -> arbitrate_conflict(a, b) end)
    |> deduplicate_conflicts()
  end

  defp is_contradictory?(a, b) do
    # Condition 1: Opposing polarity on shared topic/keywords
    shared_keywords =
      MapSet.intersection(MapSet.new(a.keywords), MapSet.new(b.keywords))
      |> MapSet.to_list()

    has_shared_topic =
      length(shared_keywords) >= 2 or
        (length(shared_keywords) >= 1 and
           (a.topic == b.topic or String.contains?(a.topic, b.topic) or
              String.contains?(b.topic, a.topic) or
              (a.statement_type == :version and b.statement_type == :version) or
              (a.statement_type == :security and b.statement_type == :security)))

    cond do
      has_shared_topic and a.polarity != b.polarity ->
        true

      # Condition 2: Version conflict (e.g., supported vs deprecated in vX)
      a.statement_type == :version and b.statement_type == :version and has_shared_topic ->
        a.polarity != b.polarity

      # Condition 3: Explicit architectural divergence (e.g., GenStage vs Broadway, Task.async vs DynamicSupervisor)
      has_architectural_divergence?(a, b) ->
        true

      true ->
        false
    end
  end

  defp has_architectural_divergence?(a, b) do
    text_a = String.downcase(a.text)
    text_b = String.downcase(b.text)

    pairs = [
      {"broadway", "genstage"},
      {"dynamic_supervisor", "task.async"},
      {"ets", "agent"},
      {"partition_supervisor", "registry"}
    ]

    Enum.any?(pairs, fn {x, y} ->
      (String.contains?(text_a, x) and String.contains?(text_b, y) and
         (a.polarity == :positive and b.polarity == :positive)) or
        (String.contains?(text_a, x) and String.contains?(text_a, "avoid") and
           String.contains?(text_b, x) and String.contains?(text_b, "recommended"))
    end)
  end

  defp arbitrate_conflict(a, b) do
    total_weight = a.composite_weight + b.composite_weight

    {dominant, subordinate, ratio} =
      if total_weight > 0 do
        if a.composite_weight >= b.composite_weight do
          {a, b, Float.round(a.composite_weight / total_weight, 3)}
        else
          {b, a, Float.round(b.composite_weight / total_weight, 3)}
        end
      else
        {a, b, 0.50}
      end

    topic =
      if a.topic != "General", do: a.topic, else: b.topic

    conflict_id = "conflict-#{dominant.id}-vs-#{subordinate.id}"

    # Arbitration rules:
    # 1. :verified (ratio >= 0.80 and dominant has high trust >= 0.88, subordinate has lower trust < 0.75)
    # 2. :consensus (ratio >= 0.65 and < 0.80, or clear majority recommendation)
    # 3. :disputed (split ratio 0.35..0.65, or competing high-authority sources)
    cond do
      ratio >= 0.75 and dominant.trust_score >= 0.88 and subordinate.trust_score < 0.75 ->
        %{
          id: conflict_id,
          topic: topic,
          status: :verified,
          badge_label: "VERIFIED",
          badge_color: "emerald",
          claim_a: a,
          claim_b: b,
          winning_claim: dominant,
          confidence_ratio: ratio,
          rationale:
            "Verified by authoritative source #{dominant.domain} (Trust: #{round(dominant.trust_score * 100)}%). Dissenting claim from #{subordinate.domain} (Trust: #{round(subordinate.trust_score * 100)}%) is superseded or inaccurate.",
          recommendation: "Adopt verified specification: #{dominant.text}"
        }

      (ratio >= 0.60 and ratio < 0.80) or (ratio >= 0.75 and subordinate.trust_score >= 0.75) ->
        %{
          id: conflict_id,
          topic: topic,
          status: :consensus,
          badge_label: "CONSENSUS",
          badge_color: "cyan",
          claim_a: a,
          claim_b: b,
          winning_claim: dominant,
          confidence_ratio: ratio,
          rationale:
            "Established ecosystem consensus favors #{dominant.domain} (#{round(ratio * 100)}% weighted agreement). Nuance from #{subordinate.domain} should be noted for non-standard workloads.",
          recommendation:
            "Implement consensus recommendation from #{dominant.domain}: #{dominant.text}"
        }

      true ->
        %{
          id: conflict_id,
          topic: topic,
          status: :disputed,
          badge_label: "DISPUTED",
          badge_color: "amber",
          claim_a: a,
          claim_b: b,
          winning_claim: nil,
          confidence_ratio: ratio,
          rationale:
            "Disputed architectural trade-off between #{a.domain} (#{round(a.composite_weight * 100)} pts) and #{b.domain} (#{round(b.composite_weight * 100)} pts). Both approaches present valid engineering trade-offs.",
          recommendation:
            "Architectural decision required: Evaluate '#{a.text}' against '#{b.text}' based on throughput and latency requirements."
        }
    end
  end

  defp deduplicate_conflicts(conflicts) do
    conflicts
    |> Enum.uniq_by(fn c ->
      topics = Enum.sort([c.claim_a.domain, c.claim_b.domain])
      "#{c.topic}-#{Enum.join(topics, "-")}"
    end)
  end

  # ============================================================================
  # SYNTHESIS & RECOMMENDATIONS
  # ============================================================================

  defp synthesize_recommendations(conflicts, claims, query) do
    verified = Enum.filter(conflicts, &(&1.status == :verified))
    consensus = Enum.filter(conflicts, &(&1.status == :consensus))
    disputed = Enum.filter(conflicts, &(&1.status == :disputed))

    cond do
      conflicts == [] and claims == [] ->
        "No conflicting evidence detected. Proceed with baseline architectural patterns."

      conflicts == [] ->
        "All #{length(claims)} evaluated claims exhibit consistent alignment with official specifications for #{query}."

      true ->
        parts = []

        parts =
          if verified != [] do
            items =
              verified
              |> Enum.map(&"- Mandatory Constraint: #{&1.recommendation}")
              |> Enum.join("\n")

            [items | parts]
          else
            parts
          end

        parts =
          if consensus != [] do
            items =
              consensus
              |> Enum.map(&"- Standard Convention: #{&1.recommendation}")
              |> Enum.join("\n")

            [items | parts]
          else
            parts
          end

        parts =
          if disputed != [] do
            items =
              disputed
              |> Enum.map(&"- Caution (Architectural Trade-Off): #{&1.recommendation}")
              |> Enum.join("\n")

            [items | parts]
          else
            parts
          end

        parts
        |> Enum.reverse()
        |> Enum.join("\n")
    end
  end

  # ============================================================================
  # CLASSIFICATION & LINGUISTIC HELPERS
  # ============================================================================

  defp detect_polarity(text) do
    normalized = String.downcase(text)

    has_neg = Enum.any?(@negation_indicators, &word_match?(normalized, &1))
    has_pos = Enum.any?(@positive_indicators, &word_match?(normalized, &1))

    cond do
      has_neg and not has_pos ->
        :negative

      has_neg and has_pos ->
        neg_count = Enum.count(@negation_indicators, &word_match?(normalized, &1))
        pos_count = Enum.count(@positive_indicators, &word_match?(normalized, &1))
        if neg_count >= pos_count, do: :negative, else: :positive

      true ->
        :positive
    end
  end

  defp word_match?(text, word) do
    Regex.match?(~r/(^|[^\p{L}\p{N}])#{Regex.escape(word)}([^\p{L}\p{N}]|$)/u, text)
  end

  defp determine_statement_type(text) do
    normalized = String.downcase(text)

    cond do
      String.match?(normalized, ~r/\b(v\d+|\d+\.\d+|version|release|otp \d+|deprecated in)\b/) ->
        :version

      String.match?(
        normalized,
        ~r/\b(security|vulnerability|leak|injection|sanitize|safe|exploit)\b/
      ) ->
        :security

      String.match?(
        normalized,
        ~r/\b(architecture|supervision|process|concurrency|pipeline|throughput|latency|memory|ets)\b/
      ) ->
        :architecture

      true ->
        :recommendation
    end
  end

  defp determine_topic(keywords, text, query) do
    key_phrases = [
      {"OTP Supervision", ~r/supervis/i},
      {"Concurrency & Backpressure", ~r/(concurrency|backpressure|broadway|genstage)/i},
      {"Memory Management", ~r/(memory|leak|garbage|heap|binary)/i},
      {"Process Architecture", ~r/(process|genserver|task|registry)/i},
      {"LiveView Interop", ~r/(liveview|hook|socket|colocated)/i},
      {"Database & Persistence", ~r/(ecto|sqlite|postgres|repo|transaction)/i},
      {"Security & Sandbox", ~r/(security|sandbox|permission|sanitize)/i}
    ]

    matched =
      Enum.find_value(key_phrases, fn {label, regex} ->
        if String.match?(text, regex), do: label, else: nil
      end)

    cond do
      matched ->
        matched

      keywords != [] ->
        keywords
        |> Enum.take(2)
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")

      query != "" ->
        query

      true ->
        "General"
    end
  end

  defp extract_keywords(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\s-]/u, " ")
    |> String.split(~r/[\s_]+/, trim: true)
    |> Enum.reject(fn word ->
      String.length(word) < 3 or word in SourceGraph.stop_words()
    end)
    |> Enum.uniq()
  end

  defp extract_domain(url) do
    case URI.parse(to_string(url)) do
      %URI{host: host} when is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        "unknown-domain"
    end
  end

  defp get_val(map, key) when is_map(map) do
    Map.get(map, key)
  end

  defp get_val(_, _), do: nil
end
