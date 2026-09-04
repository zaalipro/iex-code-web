defmodule IexCode.Consensus.Arbitrator do
  @moduledoc """
  Multi-Model Consensus Arbitrator.
  Orchestrates panel reviews, enforces dynamic offline model weight renormalization,
  auto-approves high-concordance proposals, gates contested diffs behind RunApproval records,
  and manages human resolution of arbitration requests.
  """

  alias IexCode.Consensus.Matrix
  alias IexCode.Repo
  alias IexCode.Runs.RunApproval

  @doc """
  Arbitrates a collection of peer assessments against strict consensus thresholds.
  Renormalizes weights when offline models fail or timeout.
  """
  @spec arbitrate([term()], keyword()) :: map()
  def arbitrate(assessments, opts \\ []) when is_list(assessments) do
    run_id = Keyword.get(opts, :run_id)
    initial_weights = Keyword.get(opts, :initial_weights, %{})

    active_reviewer_ids =
      assessments
      |> Enum.map(& &1.reviewer_id)
      |> Enum.reject(&is_nil/1)

    # Dynamic Weight Renormalization
    active_weights =
      if is_map(initial_weights) and map_size(initial_weights) > 0 do
        filtered = Map.take(initial_weights, active_reviewer_ids)
        sum = filtered |> Map.values() |> Enum.sum()

        if sum > 0.0 do
          Map.new(filtered, fn {k, v} -> {k, v / sum} end)
        else
          %{}
        end
      else
        %{}
      end

    matrix_res = Matrix.compute(assessments, weights: active_weights)

    case matrix_res.decision do
      :approved ->
        %{
          decision: :approved,
          auto_approved: true,
          approval_record: nil,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }

      :rejected ->
        %{
          decision: :rejected,
          auto_approved: false,
          approval_record: nil,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }

      :requires_arbitration ->
        approval =
          if run_id do
            key = "consensus_arbitration_#{Ecto.UUID.generate()}"

            attrs = %{
              run_id: run_id,
              key: key,
              action: "consensus_arbitration",
              reason: "Contested multi-model consensus requires arbitration",
              requested_by: "consensus_arbitrator",
              target_attempt: 0,
              target_generation: 0,
              status: "pending",
              metadata: %{
                decision: :requires_arbitration,
                weighted_score: matrix_res.weighted_score,
                swarm_concordance: matrix_res.swarm_concordance
              }
            }

            case %RunApproval{run_id: run_id}
                 |> RunApproval.changeset(attrs)
                 |> Repo.insert() do
              {:ok, app} -> %{app | status: :pending}
              {:error, _} -> nil
            end
          else
            nil
          end

        %{
          decision: :requires_arbitration,
          auto_approved: false,
          approval_record: approval,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }
    end
  end

  @doc """
  Resolves a pending consensus arbitration RunApproval record.
  """
  @spec resolve_arbitration(String.t(), atom()) :: {:ok, RunApproval.t()} | {:error, term()}
  def resolve_arbitration(approval_id, resolution) when is_binary(approval_id) do
    case Repo.get(RunApproval, approval_id) do
      nil ->
        {:error, :not_found}

      approval ->
        status_str = to_string(resolution)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        changeset =
          RunApproval.changeset(approval, %{
            status: status_str,
            decided_at: now,
            decided_by: "human_arbitrator"
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            {:ok, %{updated | status: resolution}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
