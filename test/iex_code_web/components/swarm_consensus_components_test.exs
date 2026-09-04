defmodule IexCodeWeb.SwarmConsensusComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias IexCode.Swarm.{Assessment, ConsensusMatrix}
  import IexCodeWeb.SwarmConsensusComponents

  setup do
    a1 =
      Assessment.new(%{
        id: "a1",
        proposal_id: "p1",
        reviewer_id: "claude-3-7",
        role: :auditor,
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        vote: :approve,
        confidence: 0.95,
        scores: %{
          syntax: 0.92,
          correctness: 0.90,
          security: 0.88,
          architectural_fit: 0.85,
          maintainability: 0.82,
          testability: 0.88
        }
      })

    a2 =
      Assessment.new(%{
        id: "a2",
        proposal_id: "p1",
        reviewer_id: "gpt-4o",
        role: :auditor,
        model_provider: "openai",
        model_id: "gpt-4o",
        vote: :approve,
        confidence: 0.90,
        scores: %{
          syntax: 0.90,
          correctness: 0.88,
          security: 0.85,
          architectural_fit: 0.80,
          maintainability: 0.80,
          testability: 0.85
        }
      })

    matrix = ConsensusMatrix.compute([a1, a2])

    {:ok, a1: a1, a2: a2, matrix: matrix}
  end

  describe "Consensus Matrix Heatmap Component" do
    test "renders N x N cell grid with percentage agreement and reviewer badges", %{
      matrix: matrix
    } do
      html =
        render_component(&consensus_heatmap/1,
          id: "test-heatmap",
          matrix: matrix
        )

      assert html =~ "Consensus Agreement Heatmap"
      assert html =~ "claude-3-7"
      assert html =~ "gpt-4o"

      # Reflexive cells on diagonal must show 100.0%
      assert html =~ "100.0%"
      # Cells styled with emerald badge (agreement >= 0.80)
      assert html =~ "bg-emerald-950"
      assert html =~ "text-emerald-300"
    end

    test "renders amber and rose badges for lower agreement levels" do
      # Disagreeing reviewers
      a_app =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "rev-app",
          vote: :approve,
          confidence: 1.0,
          scores: %{security: 1.0}
        })

      a_rej =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "rev-rej",
          vote: :reject,
          confidence: 1.0,
          scores: %{security: 0.0}
        })

      matrix = ConsensusMatrix.compute([a_app, a_rej])

      html =
        render_component(&consensus_heatmap/1,
          id: "disagreement-heatmap",
          matrix: matrix
        )

      # Off-diagonal cell is < 50%, should have rose badge
      assert html =~ "bg-rose-950"
      assert html =~ "text-rose-300"
    end
  end

  describe "5-Dimensional Score Progress Bars Component" do
    test "renders all 5 canonical dimensions with exact percentage widths", %{matrix: matrix} do
      html =
        render_component(&dimensional_score_bars/1,
          id: "test-score-bars",
          scores: matrix.dimensional_averages
        )

      assert html =~ "Correctness"
      assert html =~ "Security"
      assert html =~ "Architecture"
      assert html =~ "Maintainability"
      assert html =~ "Testability"

      # Verify progress bar fill widths exist in style attributes
      assert html =~ "style=\"width: 89%\"" or html =~ "style=\"width: 90%\""
      assert html =~ "style=\"width: 86%\"" or html =~ "style=\"width: 87%\""
      assert html =~ "bg-emerald-500"
      assert html =~ "bg-cyan-500"
      assert html =~ "bg-purple-500"
      assert html =~ "bg-indigo-500"
      assert html =~ "bg-blue-500"
    end
  end

  describe "Live Peer Message Stream Timeline Component" do
    test "renders chronological peer stream with role avatar chips and message payloads" do
      messages = [
        %{
          id: "m1",
          from_agent: "explorer-1",
          to_agent: "architect-lead",
          role: :explorer,
          type: :context_handoff,
          payload: %{"target_files" => ["lib/core.ex"]},
          timestamp: ~U[2026-09-04 12:00:00Z]
        },
        %{
          id: "m2",
          from_agent: "architect-lead",
          to_agent: "coder-1",
          role: :architect,
          type: :architecture_spec,
          payload: %{"interfaces" => "public API contract"},
          timestamp: ~U[2026-09-04 12:01:00Z]
        },
        %{
          id: "m3",
          from_agent: "coder-1",
          to_agent: "auditor-1",
          role: :coder,
          type: :proposal_submission,
          payload: %{"hunks" => 2},
          timestamp: ~U[2026-09-04 12:02:00Z]
        },
        %{
          id: "m4",
          from_agent: "auditor-1",
          to_agent: "coder-1",
          role: :auditor,
          type: :audit_critique,
          payload: %{"severity" => "none"},
          timestamp: ~U[2026-09-04 12:03:00Z]
        }
      ]

      html =
        render_component(&peer_message_timeline/1,
          id: "test-peer-timeline",
          messages: messages
        )

      assert html =~ "Live Peer Message Stream"
      assert html =~ "4 Exchanges"

      # Avatar chips for each role
      assert html =~ "border-cyan-400"
      assert html =~ "border-violet-400"
      assert html =~ "border-emerald-400"
      assert html =~ "border-amber-400"

      assert html =~ "explorer-1"
      assert html =~ "architect-lead"
      assert html =~ "coder-1"
      assert html =~ "auditor-1"
      assert html =~ "public API contract"
    end

    test "filters messages when active_role_filter is set" do
      messages = [
        %{from_agent: "exp-1", to_agent: "arch", role: :explorer, type: :msg, payload: %{}},
        %{from_agent: "code-1", to_agent: "aud", role: :coder, type: :msg, payload: %{}}
      ]

      html =
        render_component(&peer_message_timeline/1,
          id: "filtered-peer-timeline",
          messages: messages,
          active_role_filter: "coder"
        )

      assert html =~ "code-1"
      refute html =~ "exp-1"
    end
  end

  describe "Merge Gating Badge & Roster Pills" do
    test "renders merge gating badges with appropriate iconography and styling" do
      html_app = render_component(&merge_gating_badge/1, decision: :approved)
      assert html_app =~ "APPROVED (GATED MERGE)"
      assert html_app =~ "text-emerald-300"

      html_rev = render_component(&merge_gating_badge/1, decision: :revision_required)
      assert html_rev =~ "REVISION REQUIRED"
      assert html_rev =~ "text-amber-300"

      html_rej = render_component(&merge_gating_badge/1, decision: :rejected)
      assert html_rej =~ "REJECTED (HALTED)"
      assert html_rej =~ "text-rose-300"
    end

    test "renders swarm roster pills with role avatars and model badges" do
      roster = [
        %{role: :explorer, display_name: "Explorer Lead", model_id: "claude-3-7-sonnet"},
        %{role: :coder, display_name: "Coder Agent", model_id: "o3-mini"}
      ]

      html = render_component(&swarm_roster_pills/1, roster: roster)
      assert html =~ "Explorer Lead"
      assert html =~ "claude-3-7-sonnet"
      assert html =~ "Coder Agent"
      assert html =~ "o3-mini"
    end
  end
end
