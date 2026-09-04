defmodule IexCode.Consensus.Matrix do
  @moduledoc """
  Mathematical Consensus Matrix & Swarm Voting Engine.
  Computes pairwise agreement A_{j,k}, swarm concordance \bar{A}, weighted confidence score C,
  and enforces strict multi-model decision rule thresholds (:approved, :rejected, :requires_arbitration).
  """

  alias IexCode.Consensus.Assessment

  @dimensions [:correctness, :security, :architectural_fit, :maintainability, :testability]
  @sqrt_5 :math.sqrt(5.0)

  @doc """
  Computes vote concordance between two assessments:
  - same vote: 1.0
  - approve vs reject: 0.0
  - approve vs request_changes: 0.25
  - reject vs request_changes: 0.75
  """
  @spec vote_concordance(Assessment.t(), Assessment.t()) :: float()
  def vote_concordance(%{vote: v1}, %{vote: v2}) do
    cond do
      v1 == v2 ->
        1.0

      (v1 == :approve and v2 == :reject) or (v1 == :reject and v2 == :approve) ->
        0.0

      (v1 == :approve and v2 == :request_changes) or (v1 == :request_changes and v2 == :approve) ->
        0.25

      (v1 == :reject and v2 == :request_changes) or (v1 == :request_changes and v2 == :reject) ->
        0.75

      true ->
        0.0
    end
  end

  @doc """
  Computes pairwise agreement A_{j,k} between two assessments satisfying:
  - Reflexivity: A_{j,j} == 1.0
  - Symmetry: A_{j,k} == A_{k,j}
  - Boundedness: 0.0 <= A_{j,k} <= 1.0
  Formula: A_{j,k} = 0.60 * vote_concordance + 0.40 * (1.0 - norm_diff / sqrt(5))
  """
  @spec pairwise_agreement(Assessment.t(), Assessment.t()) :: float()
  def pairwise_agreement(a, b) do
    if a.reviewer_id == b.reviewer_id and a.vote == b.vote and a.scores == b.scores do
      1.0
    else
      delta_vote = vote_concordance(a, b)

      diff_sq_sum =
        Enum.reduce(@dimensions, 0.0, fn dim, acc ->
          s1 = Map.get(a.scores, dim, 0.8)
          s2 = Map.get(b.scores, dim, 0.8)
          diff = s1 - s2
          acc + diff * diff
        end)

      norm_diff = :math.sqrt(diff_sq_sum)
      score_agreement = max(0.0, 1.0 - norm_diff / @sqrt_5)

      agreement = 0.60 * delta_vote + 0.40 * score_agreement
      clamp(agreement, 0.0, 1.0)
    end
  end

  @doc """
  Computes the full consensus matrix, swarm concordance, weighted score, and arbitration decision.
  """
  @spec compute([Assessment.t()], keyword()) :: map()
  def compute(assessments, opts \\ [])

  def compute([], _opts) do
    %{
      decision: :requires_arbitration,
      weighted_score: 0.0,
      swarm_concordance: 0.0,
      dimensional_averages: %{},
      pairwise_matrix: [],
      has_blocker?: false,
      assessments: []
    }
  end

  def compute(assessments, opts) when is_list(assessments) do
    m = length(assessments)

    # 1. Normalized weights
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

    normalized_weights =
      if sum_w > 0 do
        Enum.map(raw_weights, &(&1 / sum_w))
      else
        List.duplicate(1.0 / m, m)
      end

    # 2. Pairwise agreement matrix
    matrix_grid =
      for a <- assessments do
        for b <- assessments do
          pairwise_agreement(a, b)
        end
      end

    # 3. Swarm concordance \bar{A}
    swarm_concordance =
      if m == 1 do
        1.0
      else
        pairs =
          for j <- 0..(m - 2), k <- (j + 1)..(m - 1) do
            pairwise_agreement(Enum.at(assessments, j), Enum.at(assessments, k))
          end

        Enum.sum(pairs) / length(pairs)
      end

    # 4. Weighted score C
    weighted_score =
      assessments
      |> Enum.zip(normalized_weights)
      |> Enum.reduce(0.0, fn {a, w}, acc ->
        v_val = vote_value(a.vote)
        conf = a.confidence || 1.0
        acc + w * conf * v_val
      end)

    # 5. Dimensional averages \bar{S}
    dimensional_averages =
      Enum.reduce(@dimensions, %{}, fn dim, acc ->
        avg =
          assessments
          |> Enum.zip(normalized_weights)
          |> Enum.reduce(0.0, fn {a, w}, d_acc ->
            d_acc + w * Map.get(a.scores, dim, 0.8)
          end)

        Map.put(acc, dim, avg)
      end)

    # 6. Blocker critique detection
    has_blocker? =
      Enum.any?(assessments, fn a ->
        Enum.any?(a.critique_points || [], fn c ->
          c[:severity] in [:blocker, "blocker"] or c["severity"] in [:blocker, "blocker"]
        end)
      end)

    # 7. Decision rule evaluation
    decision =
      cond do
        has_blocker? ->
          if weighted_score <= -0.40 or Map.get(dimensional_averages, :security, 1.0) < 0.5 do
            :rejected
          else
            :requires_arbitration
          end

        weighted_score >= 0.65 and swarm_concordance >= 0.60 and
            Map.get(dimensional_averages, :security, 1.0) >= 0.70 ->
          :approved

        weighted_score <= -0.40 ->
          :rejected

        true ->
          :requires_arbitration
      end

    %{
      decision: decision,
      weighted_score: weighted_score,
      swarm_concordance: swarm_concordance,
      dimensional_averages: dimensional_averages,
      pairwise_matrix: matrix_grid,
      has_blocker?: has_blocker?,
      assessments: assessments
    }
  end

  defp vote_value(:approve), do: 1.0
  defp vote_value(:reject), do: -1.0
  defp vote_value(:request_changes), do: -0.25
  defp vote_value(_), do: 0.0

  defp clamp(val, min_val, _max_val) when val < min_val, do: min_val
  defp clamp(val, _min_val, max_val) when val > max_val, do: max_val
  defp clamp(val, _min_val, _max_val), do: val
end
