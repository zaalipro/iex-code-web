defmodule IexCode.Swarm.ConsensusMatrixTest do
  use ExUnit.Case, async: true

  alias IexCode.Swarm.{Assessment, ConsensusMatrix, Proposal}

  setup do
    proposal =
      Proposal.new(%{
        id: "prop-test-01",
        run_id: "run-01",
        coder_id: "coder-1",
        patches: [%{"file" => "lib/core.ex", "hunks" => []}],
        title: "Test Proposal",
        summary: "Summary of changes"
      })

    {:ok, proposal: proposal}
  end

  describe "Mathematical Axioms of Pairwise Agreement" do
    test "proves Reflexivity: Agreement(i, i) == 1.0" do
      a =
        Assessment.new(%{
          id: "a1",
          proposal_id: "p1",
          reviewer_id: "rev-1",
          vote: :approve,
          confidence: 0.95,
          scores: %{
            syntax: 0.90,
            correctness: 0.85,
            security: 0.80,
            architectural_fit: 0.75,
            maintainability: 0.70
          }
        })

      assert ConsensusMatrix.pairwise_agreement(a, a) == 1.0
    end

    test "proves Symmetry: Agreement(i, j) == Agreement(j, i)" do
      a1 =
        Assessment.new(%{
          id: "a1",
          proposal_id: "p1",
          reviewer_id: "rev-1",
          vote: :approve,
          confidence: 0.9,
          scores: %{
            syntax: 0.9,
            correctness: 0.85,
            security: 0.8,
            architectural_fit: 0.75,
            maintainability: 0.7
          }
        })

      a2 =
        Assessment.new(%{
          id: "a2",
          proposal_id: "p1",
          reviewer_id: "rev-2",
          vote: :request_changes,
          confidence: 0.8,
          scores: %{
            syntax: 0.7,
            correctness: 0.65,
            security: 0.7,
            architectural_fit: 0.6,
            maintainability: 0.65
          }
        })

      agr1 = ConsensusMatrix.pairwise_agreement(a1, a2)
      agr2 = ConsensusMatrix.pairwise_agreement(a2, a1)

      assert_in_delta agr1, agr2, 0.0001
    end

    test "proves Boundedness: 0.0 <= Agreement(i, j) <= 1.0 across diverse pairs" do
      votes = [:approve, :request_changes, :reject]

      for v1 <- votes, v2 <- votes do
        a1 =
          Assessment.new(%{
            id: "1",
            proposal_id: "p",
            reviewer_id: "r1",
            vote: v1,
            confidence: 1.0,
            scores: %{security: 1.0}
          })

        a2 =
          Assessment.new(%{
            id: "2",
            proposal_id: "p",
            reviewer_id: "r2",
            vote: v2,
            confidence: 1.0,
            scores: %{security: 0.0}
          })

        agreement = ConsensusMatrix.pairwise_agreement(a1, a2)
        assert agreement >= 0.0 and agreement <= 1.0
      end
    end
  end

  describe "Vote Concordance delta(v_i, v_j)" do
    test "calculates exact expected values across all 9 vote combinations" do
      # 1. Same votes -> 1.0
      assert ConsensusMatrix.vote_concordance(:approve, :approve) == 1.0
      assert ConsensusMatrix.vote_concordance(:reject, :reject) == 1.0
      assert ConsensusMatrix.vote_concordance(:request_changes, :request_changes) == 1.0

      # 2. Approve vs Reject -> 0.0
      assert ConsensusMatrix.vote_concordance(:approve, :reject) == 0.0
      assert ConsensusMatrix.vote_concordance(:reject, :approve) == 0.0

      # 3. Approve vs Request Changes -> 0.25
      assert ConsensusMatrix.vote_concordance(:approve, :request_changes) == 0.25
      assert ConsensusMatrix.vote_concordance(:request_changes, :approve) == 0.25

      # 4. Reject vs Request Changes -> 0.75
      assert ConsensusMatrix.vote_concordance(:reject, :request_changes) == 0.75
      assert ConsensusMatrix.vote_concordance(:request_changes, :reject) == 0.75
    end

    test "accepts Assessment structs directly for vote_concordance" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "r1",
          vote: :approve,
          confidence: 0.9
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "r2",
          vote: :request_changes,
          confidence: 0.9
        })

      assert ConsensusMatrix.vote_concordance(a1, a2) == 0.25
    end
  end

  describe "Dimensional Score Agreement" do
    test "yields 1.0 for identical scores and 0.0 for maximal distance" do
      scores1 = %{
        syntax: 1.0,
        correctness: 1.0,
        security: 1.0,
        architectural_fit: 1.0,
        maintainability: 1.0
      }

      scores2 = %{
        syntax: 1.0,
        correctness: 1.0,
        security: 1.0,
        architectural_fit: 1.0,
        maintainability: 1.0
      }

      scores_opp = %{
        syntax: 0.0,
        correctness: 0.0,
        security: 0.0,
        architectural_fit: 0.0,
        maintainability: 0.0
      }

      assert_in_delta ConsensusMatrix.score_agreement(scores1, scores2), 1.0, 0.0001
      assert_in_delta ConsensusMatrix.score_agreement(scores1, scores_opp), 0.0, 0.0001
    end

    test "detects dimensional conflict when score spread exceeds 0.40" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "r1",
          vote: :approve,
          confidence: 0.9,
          scores: %{security: 0.95}
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "r2",
          vote: :approve,
          confidence: 0.9,
          scores: %{security: 0.45}
        })

      matrix = ConsensusMatrix.compute([a1, a2])
      assert :security in matrix.conflicted_dimensions
      conflict = Enum.find(matrix.conflicts, &(&1.dimension == :security))
      assert conflict != nil
      assert conflict.spread > 0.40
    end
  end

  describe "Outlier Reviewer Detection" do
    test "detects outlier reviewer when mean agreement drops significantly below panel average" do
      # 3 harmonious reviewers and 1 rogue reviewer
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "claude",
          vote: :approve,
          confidence: 0.95,
          scores: %{security: 0.90, correctness: 0.90}
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "gpt4",
          vote: :approve,
          confidence: 0.90,
          scores: %{security: 0.88, correctness: 0.88}
        })

      a3 =
        Assessment.new(%{
          id: "3",
          proposal_id: "p",
          reviewer_id: "deepseek",
          vote: :approve,
          confidence: 0.92,
          scores: %{security: 0.91, correctness: 0.89}
        })

      rogue =
        Assessment.new(%{
          id: "4",
          proposal_id: "p",
          reviewer_id: "rogue",
          vote: :reject,
          confidence: 0.90,
          scores: %{security: 0.10, correctness: 0.10}
        })

      matrix = ConsensusMatrix.compute([a1, a2, a3, rogue])

      assert "rogue" in matrix.outliers
      refute "claude" in matrix.outliers
      refute "gpt4" in matrix.outliers
    end
  end

  describe "Automated Merge Gating" do
    test "approves when score >= 0.65, concordance >= 0.60, and security >= 0.70 without blockers" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "claude",
          vote: :approve,
          confidence: 0.95,
          scores: %{syntax: 0.90, security: 0.85, correctness: 0.88}
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "gpt4",
          vote: :approve,
          confidence: 0.90,
          scores: %{syntax: 0.88, security: 0.80, correctness: 0.85}
        })

      matrix = ConsensusMatrix.compute([a1, a2])

      assert matrix.decision == :approved
      assert matrix.weighted_score >= 0.65
      assert matrix.swarm_concordance >= 0.60
      assert matrix.has_blocker? == false
    end

    test "triggers revision_required when vote is request_changes or moderate confidence" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "claude",
          vote: :request_changes,
          confidence: 0.8,
          scores: %{syntax: 0.85, security: 0.70, correctness: 0.65}
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "gpt4",
          vote: :approve,
          confidence: 0.85,
          scores: %{syntax: 0.85, security: 0.75, correctness: 0.75}
        })

      matrix = ConsensusMatrix.compute([a1, a2])

      assert matrix.decision == :revision_required
    end

    test "rejects when blocker critique is present with low security" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "sec_audit",
          vote: :reject,
          confidence: 0.95,
          scores: %{security: 0.30, correctness: 0.40},
          critique_points: [%{severity: :blocker, description: "SQL injection vulnerability"}]
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "gpt4",
          vote: :reject,
          confidence: 0.90,
          scores: %{security: 0.40, correctness: 0.50}
        })

      matrix = ConsensusMatrix.compute([a1, a2])

      assert matrix.decision == :rejected
      assert matrix.has_blocker? == true
    end

    test "rejects when weighted score drops below -0.40" do
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "r1",
          vote: :reject,
          confidence: 0.95
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "r2",
          vote: :reject,
          confidence: 0.95
        })

      matrix = ConsensusMatrix.compute([a1, a2])
      assert matrix.decision == :rejected
      assert matrix.weighted_score <= -0.40
    end
  end

  describe "Dynamic Weight Renormalization" do
    test "renormalizes weights dynamically when an offline model fails to submit" do
      panel = %{"claude" => 0.4, "gpt4" => 0.4, "local_llama" => 0.2}
      active_reviewers = ["claude", "gpt4"]

      renormalized = ConsensusMatrix.renormalize_weights(panel, active_reviewers)

      assert Map.has_key?(renormalized, "claude")
      assert Map.has_key?(renormalized, "gpt4")
      refute Map.has_key?(renormalized, "local_llama")

      assert_in_delta renormalized["claude"], 0.50, 0.01
      assert_in_delta renormalized["gpt4"], 0.50, 0.01
      assert_in_delta Enum.sum(Map.values(renormalized)), 1.0, 0.001
    end
  end
end
