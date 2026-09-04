defmodule IexCode.Swarm.ConsensusMatrix do
  @moduledoc """
  Multi-Model Consensus Matrix & Automated Merge Gating Engine.
  Computes pairwise agreement with reflexivity, symmetry, and boundedness [0.0, 1.0].
  Aggregates swarm concordance, weighted score, conflict detection, outlier identification,
  and automated merge gating (:approved, :revision_required, :rejected).
  """

  alias IexCode.Swarm.Assessment

  @standard_dimensions [:syntax, :correctness, :security, :architectural_fit, :maintainability]
  @all_dimensions [
    :syntax,
    :correctness,
    :security,
    :architectural_fit,
    :maintainability,
    :testability
  ]

  @doc """
  Computes pairwise vote concordance delta(v_i, v_j) between two votes or assessments:
  - same vote: 1.0
  - approve vs reject: 0.0
  - approve vs request_changes: 0.25
  - reject vs request_changes: 0.75
  """
  @spec vote_concordance(atom() | map(), atom() | map()) :: float()
  def vote_concordance(%{vote: v1}, %{vote: v2}), do: vote_concordance(v1, v2)
  def vote_concordance(%{vote: v1}, v2) when is_atom(v2), do: vote_concordance(v1, v2)
  def vote_concordance(v1, %{vote: v2}) when is_atom(v1), do: vote_concordance(v1, v2)

  def vote_concordance(v1, v2) do
    norm1 = normalize_vote_atom(v1)
    norm2 = normalize_vote_atom(v2)

    cond do
      norm1 == norm2 ->
        1.0

      (norm1 == :approve and norm2 == :reject) or (norm1 == :reject and norm2 == :approve) ->
        0.0

      (norm1 == :approve and norm2 == :request_changes) or
          (norm1 == :request_changes and norm2 == :approve) ->
        0.25

      (norm1 == :reject and norm2 == :request_changes) or
          (norm1 == :request_changes and norm2 == :reject) ->
        0.75

      true ->
        0.0
    end
  end

  @doc """
  Computes normalized Euclidean score distance d(S_i, S_j) across dimensional scores.
  """
  @spec dimensional_distance(map(), map()) :: float()
  def dimensional_distance(scores1, scores2) do
    dims = get_compared_dimensions(scores1, scores2)

    diff_sq_sum =
      Enum.reduce(dims, 0.0, fn dim, acc ->
        s1 = get_score_val(scores1, dim)
        s2 = get_score_val(scores2, dim)
        diff = s1 - s2
        acc + diff * diff
      end)

    :math.sqrt(diff_sq_sum)
  end

  @doc """
  Computes normalized score agreement sigma(S_i, S_j) = max(0.0, 1.0 - d / sqrt(K)).
  """
  @spec score_agreement(map(), map()) :: float()
  def score_agreement(scores1, scores2) do
    dims = get_compared_dimensions(scores1, scores2)
    k = max(1, length(dims))
    sqrt_k = :math.sqrt(k * 1.0)

    dist = dimensional_distance(scores1, scores2)
    max(0.0, 1.0 - dist / sqrt_k)
  end

  @doc """
  Computes composite pairwise agreement between two assessments:
  Agreement(i, j) = 0.60 * delta(v_i, v_j) + 0.40 * sigma(S_i, S_j)

  Guarantees:
  - Reflexivity: Agreement(i, i) == 1.0
  - Symmetry: Agreement(i, j) == Agreement(j, i)
  - Boundedness: 0.0 <= Agreement(i, j) <= 1.0
  """
  @spec pairwise_agreement(Assessment.t() | map(), Assessment.t() | map()) :: float()
  def pairwise_agreement(a, b) do
    same_reviewer? =
      is_binary(a.reviewer_id) and is_binary(b.reviewer_id) and a.reviewer_id == b.reviewer_id

    same_vote? = a.vote == b.vote
    same_scores? = a.scores == b.scores

    if (same_reviewer? and same_vote? and same_scores?) or a === b do
      1.0
    else
      delta = vote_concordance(a.vote, b.vote)
      sigma = score_agreement(a.scores, b.scores)

      composite = 0.60 * delta + 0.40 * sigma
      composite |> max(0.0) |> min(1.0)
    end
  end

  # ============================================================================
  # MATRIX AGGREGATION & DECISION ENGINE
  # ============================================================================

  @doc """
  Computes the full consensus matrix, swarm concordance, weighted score,
  dimensional averages, conflict detection, outlier detection, and merge gating.
  """
  @spec compute([Assessment.t() | map()], keyword()) :: map()
  def compute(assessments, opts \\ [])

  def compute([], _opts) do
    %{
      decision: :rejected,
      gating: :rejected,
      merge_verdict: :rejected,
      weighted_score: 0.0,
      swarm_concordance: 0.0,
      dimensional_averages: %{},
      pairwise_matrix: [],
      reviewer_agreements: %{},
      conflicts: [],
      conflicted_dimensions: [],
      outliers: [],
      has_blocker?: false,
      assessments: [],
      weights: %{}
    }
  end

  def compute(assessments, opts) when is_list(assessments) do
    m = length(assessments)

    # 1. Weights normalization & offline fallback
    normalized_weights = compute_normalized_weights(assessments, opts)

    # 2. Pairwise agreement matrix
    pairwise_matrix =
      for a <- assessments do
        for b <- assessments do
          pairwise_agreement(a, b)
        end
      end

    # 3. Swarm concordance \bar{A}
    swarm_concordance =
      if m <= 1 do
        1.0
      else
        pairs =
          for j <- 0..(m - 2), k <- (j + 1)..(m - 1) do
            pairwise_agreement(Enum.at(assessments, j), Enum.at(assessments, k))
          end

        Enum.sum(pairs) / length(pairs)
      end

    # 4. Overall Weighted Score C in [-1.0, 1.0]
    weighted_score =
      assessments
      |> Enum.zip(normalized_weights)
      |> Enum.reduce(0.0, fn {a, w}, acc ->
        v_val = vote_value(a.vote)
        conf = (a.confidence || 1.0) * 1.0
        acc + w * conf * v_val
      end)
      |> max(-1.0)
      |> min(1.0)

    # 5. Dimensional averages
    active_dims = determine_active_dimensions(assessments)

    dimensional_averages =
      Enum.reduce(active_dims, %{}, fn dim, acc ->
        avg =
          assessments
          |> Enum.zip(normalized_weights)
          |> Enum.reduce(0.0, fn {a, w}, d_acc ->
            d_acc + w * get_score_val(a.scores, dim)
          end)

        Map.put(acc, dim, Float.round(avg, 4))
      end)

    # 6. Blocker critique detection
    has_blocker? =
      Enum.any?(assessments, fn a ->
        Enum.any?(a.critique_points || [], fn c ->
          severity = Map.get(c, :severity) || Map.get(c, "severity")
          severity in [:blocker, "blocker"]
        end)
      end)

    # 7. Conflict detection (score spread > 0.40)
    conflicts = detect_conflicts(assessments, active_dims)
    conflicted_dimensions = Enum.map(conflicts, & &1.dimension)

    # 8. Outlier detection (A_i < \bar{A} - 1.5 * \sigma_A or A_i < 0.40)
    {reviewer_agreements, outliers} =
      detect_outliers(assessments, pairwise_matrix, swarm_concordance)

    # 9. Automated Merge Gating Evaluation
    decision =
      evaluate_merge_gating(weighted_score, swarm_concordance, dimensional_averages, has_blocker?)

    weights_map =
      assessments
      |> Enum.zip(normalized_weights)
      |> Enum.map(fn {a, w} -> {a.reviewer_id, w} end)
      |> Map.new()

    %{
      decision: decision,
      gating: decision,
      merge_verdict: decision,
      weighted_score: Float.round(weighted_score, 4),
      swarm_concordance: Float.round(swarm_concordance, 4),
      dimensional_averages: dimensional_averages,
      pairwise_matrix: pairwise_matrix,
      reviewer_agreements: reviewer_agreements,
      conflicts: conflicts,
      conflicted_dimensions: conflicted_dimensions,
      outliers: outliers,
      has_blocker?: has_blocker?,
      assessments: assessments,
      weights: weights_map
    }
  end

  @doc """
  Renormalizes weights dynamically when an offline model fails to submit an assessment.
  """
  @spec renormalize_weights(map() | list(), list(String.t())) :: map()
  def renormalize_weights(raw_weights, active_reviewers) when is_map(raw_weights) do
    filtered =
      Enum.filter(raw_weights, fn {id, _w} -> id in active_reviewers end)

    sum = Enum.reduce(filtered, 0.0, fn {_id, w}, acc -> acc + w end)

    if sum > 0.0 do
      Map.new(filtered, fn {id, w} -> {id, Float.round(w / sum, 4)} end)
    else
      n = max(1, length(active_reviewers))
      Map.new(active_reviewers, fn id -> {id, Float.round(1.0 / n, 4)} end)
    end
  end

  def renormalize_weights(assessments, active_reviewers) when is_list(assessments) do
    weights = Map.new(assessments, fn a -> {a.reviewer_id, 1.0} end)
    renormalize_weights(weights, active_reviewers)
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  defp evaluate_merge_gating(weighted_score, concordance, dim_avgs, has_blocker?) do
    sec_avg = Map.get(dim_avgs, :security, 0.8)
    syntax_avg = Map.get(dim_avgs, :syntax, 0.85)

    cond do
      # 1. Rejection rule: C < -0.40 OR (has_blocker? and security < 0.50)
      weighted_score < -0.40 or (has_blocker? and sec_avg < 0.50) ->
        :rejected

      # 2. Approval rule: C >= 0.65, Concordance >= 0.60, Security >= 0.70, Syntax >= 0.80, and NO blocker
      weighted_score >= 0.65 and concordance >= 0.60 and sec_avg >= 0.70 and syntax_avg >= 0.80 and
          not has_blocker? ->
        :approved

      # 3. Revision required: moderate scores or blocker with security >= 0.50
      true ->
        :revision_required
    end
  end

  defp detect_conflicts(assessments, dimensions) do
    Enum.reduce(dimensions, [], fn dim, acc ->
      scores = Enum.map(assessments, &get_score_val(&1.scores, dim))
      min_s = Enum.min(scores, fn -> 0.8 end)
      max_s = Enum.max(scores, fn -> 0.8 end)
      spread = Float.round(max_s - min_s, 4)

      if spread > 0.40 do
        acc ++ [%{dimension: dim, spread: spread, min: min_s, max: max_s}]
      else
        acc
      end
    end)
  end

  defp detect_outliers(assessments, pairwise_matrix, swarm_concordance) do
    m = length(assessments)

    if m < 2 do
      {%{}, []}
    else
      # Compute mean agreement for each reviewer i with all j != i
      mean_agreements =
        assessments
        |> Enum.with_index()
        |> Enum.map(fn {a, i} ->
          row = Enum.at(pairwise_matrix, i)

          others_agreements =
            row
            |> Enum.with_index()
            |> Enum.reject(fn {_val, j} -> j == i end)
            |> Enum.map(fn {val, _j} -> val end)

          mean_a =
            if others_agreements == [] do
              1.0
            else
              Enum.sum(others_agreements) / length(others_agreements)
            end

          {a.reviewer_id, Float.round(mean_a, 4)}
        end)

      agreements_map = Map.new(mean_agreements)

      outliers =
        if m >= 3 do
          values = Enum.map(mean_agreements, fn {_id, a} -> a end)
          mean_val = Enum.sum(values) / length(values)

          variance =
            values
            |> Enum.reduce(0.0, fn val, acc -> acc + :math.pow(val - mean_val, 2) end)
            |> Kernel./(max(1, length(values) - 1))

          std_dev = :math.sqrt(variance)
          threshold = swarm_concordance - 1.5 * std_dev

          mean_agreements
          |> Enum.filter(fn {_id, a_i} ->
            a_i < threshold or a_i < 0.40
          end)
          |> Enum.map(fn {id, _} -> id end)
        else
          # For m == 2, flag if agreement < 0.40
          mean_agreements
          |> Enum.filter(fn {_id, a_i} -> a_i < 0.40 end)
          |> Enum.map(fn {id, _} -> id end)
        end

      {agreements_map, outliers}
    end
  end

  defp compute_normalized_weights(assessments, opts) do
    m = length(assessments)
    weights_opt = Keyword.get(opts, :weights, %{})

    raw_weights =
      if is_map(weights_opt) and map_size(weights_opt) > 0 do
        Enum.map(assessments, fn a ->
          rev_id = a.reviewer_id || "reviewer"
          Map.get(weights_opt, rev_id, 1.0)
        end)
      else
        List.duplicate(1.0, m)
      end

    sum_w = Enum.sum(raw_weights)

    if sum_w > 0 do
      Enum.map(raw_weights, &(&1 / sum_w))
    else
      List.duplicate(1.0 / m, m)
    end
  end

  defp determine_active_dimensions(assessments) do
    present_dims =
      assessments
      |> Enum.flat_map(fn a ->
        if is_map(a.scores), do: Map.keys(a.scores), else: []
      end)
      |> Enum.map(&normalize_atom/1)
      |> Enum.uniq()

    if present_dims == [] do
      @standard_dimensions
    else
      # Preserve canonical ordering
      @all_dimensions
      |> Enum.filter(&(&1 in present_dims))
      |> case do
        [] -> @standard_dimensions
        list -> list
      end
    end
  end

  defp get_compared_dimensions(scores1, scores2) do
    keys1 = if is_map(scores1), do: Map.keys(scores1), else: []
    keys2 = if is_map(scores2), do: Map.keys(scores2), else: []

    shared =
      (keys1 ++ keys2)
      |> Enum.map(&normalize_atom/1)
      |> Enum.uniq()

    case Enum.filter(@all_dimensions, &(&1 in shared)) do
      [] -> @standard_dimensions
      list -> list
    end
  end

  defp get_score_val(scores, dim) when is_map(scores) do
    val =
      Map.get(scores, dim) ||
        Map.get(scores, to_string(dim)) ||
        case dim do
          :architectural_fit -> Map.get(scores, :architecture) || Map.get(scores, "architecture")
          :syntax -> Map.get(scores, :code_quality) || Map.get(scores, "code_quality")
          _ -> nil
        end || 0.8

    if is_number(val), do: val * 1.0, else: 0.8
  end

  defp get_score_val(_, _), do: 0.8

  defp vote_value(:approve), do: 1.0
  defp vote_value(:reject), do: -1.0
  defp vote_value(:request_changes), do: -0.25
  defp vote_value(_), do: 0.0

  defp normalize_vote_atom(:approve), do: :approve
  defp normalize_vote_atom("approve"), do: :approve
  defp normalize_vote_atom(:reject), do: :reject
  defp normalize_vote_atom("reject"), do: :reject
  defp normalize_vote_atom(:request_changes), do: :request_changes
  defp normalize_vote_atom("request_changes"), do: :request_changes
  defp normalize_vote_atom(_), do: :request_changes

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp normalize_atom(_), do: :unknown
end
