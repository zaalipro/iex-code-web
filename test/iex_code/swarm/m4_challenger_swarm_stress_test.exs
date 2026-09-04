defmodule IexCode.Swarm.M4ChallengerSwarmStressTest do
  use ExUnit.Case, async: false

  alias IexCode.Engine.DynamicRoleAllocator
  alias IexCode.Swarm.{Assessment, ConsensusMatrix, PeerStream, Proposal, RoleSpec}

  # ============================================================================
  # 1. DYNAMIC ROLE ALLOCATOR BOUNDARY & CLAMPING STRESS
  # ============================================================================

  describe "Dynamic Role Allocator Boundary Testing" do
    test "evaluates prompts with 0 target files, 100+ files, extreme keyword density, empty strings, and nil" do
      # 1. Nil / empty inputs
      score_nil = DynamicRoleAllocator.assess_task_complexity(nil, nil, %{})
      assert is_float(score_nil)
      assert score_nil >= 0.0 and score_nil <= 100.0

      score_empty = DynamicRoleAllocator.assess_task_complexity("", [], %{})
      assert is_float(score_empty)
      assert score_empty >= 0.0 and score_empty <= 100.0

      score_whitespace = DynamicRoleAllocator.assess_task_complexity("   \n\t  ", "", nil)
      assert is_float(score_whitespace)
      assert score_whitespace >= 0.0 and score_whitespace <= 100.0

      # 2. 0 Target files
      score_zero_files =
        DynamicRoleAllocator.assess_task_complexity("Implement small feature", [], %{})

      assert is_float(score_zero_files)
      assert score_zero_files >= 0.0 and score_zero_files <= 100.0

      # 3. 100+ Target files across multiple domains
      large_file_list =
        Enum.map(1..150, fn i ->
          sub = rem(i, 8)
          "lib/iex_code/subsystem_#{sub}/worker_node_#{i}.ex"
        end)

      # Target files boundary on Proposal struct
      proposal =
        Proposal.new(%{
          id: "prop-stress-01",
          run_id: "run-stress",
          coder_id: "coder-stress-1",
          patches: [],
          target_files: large_file_list
        })

      assert length(proposal.target_files) == 150
      assert proposal.role == :coder

      breakdown_large =
        DynamicRoleAllocator.assess_task_complexity_breakdown(
          "Refactor entire architecture across all subdomains",
          large_file_list,
          %{}
        )

      assert breakdown_large.scope == 100.0
      assert breakdown_large.intent == 75.0
      assert breakdown_large.composite >= 50.0 and breakdown_large.composite <= 100.0

      # With risk and research context
      score_high_risk =
        DynamicRoleAllocator.assess_task_complexity(
          "Refactor security auth crypto architecture across subdomains",
          large_file_list,
          %{"disputed_claims" => ["conflict-1"]}
        )

      assert score_high_risk >= 80.0 and score_high_risk <= 100.0

      # 4. Extreme keyword density (hundreds of security, risk, and rewrite keywords)
      risk_words = [
        "auth",
        "login",
        "password",
        "session",
        "oauth",
        "token",
        "credential",
        "jwt",
        "crypto",
        "hash",
        "cipher",
        "encrypt",
        "decrypt",
        "signature",
        "rsa",
        "ecdsa",
        "hmac",
        "security",
        "permission",
        "policy",
        "privilege",
        "admin",
        "role",
        "rbac",
        "sandbox",
        "isolation",
        "container",
        "jail",
        "drop",
        "delete",
        "truncate",
        "rollback",
        "purge",
        "shell",
        "exec",
        "cmd",
        "system",
        "eval",
        "dangerous",
        "from scratch",
        "complete rewrite of the system"
      ]

      dense_prompt =
        1..20
        |> Enum.flat_map(fn _ -> risk_words end)
        |> Enum.join(" ")

      breakdown =
        DynamicRoleAllocator.assess_task_complexity_breakdown(dense_prompt, large_file_list, %{
          "disputed_claims" => ["claim-1", "claim-2"]
        })

      assert breakdown.composite == 97.75
      assert breakdown.scope == 100.0
      assert breakdown.risk == 100.0
      assert breakdown.intent == 100.0
      assert breakdown.research == 85.0
    end

    test "strictly clamps S_task composite score to [0.0, 100.0] under adversarial inputs" do
      # Test 100 variations of adversarial inputs
      for i <- 1..50 do
        random_file_count = rem(i * 7, 120)

        files =
          if random_file_count == 0 do
            []
          else
            Enum.map(1..random_file_count, &"lib/file_#{&1}.ex")
          end

        prompt =
          case rem(i, 4) do
            0 -> nil
            1 -> ""
            2 -> "minor typo fix"
            3 -> "complete rewrite drop all tables auth security shell dangerous"
          end

        context =
          case rem(i, 3) do
            0 -> %{}
            1 -> %{"verified_claims" => ["v1"]}
            2 -> %{"disputed_claims" => ["d1", "d2"]}
          end

        score = DynamicRoleAllocator.assess_task_complexity(prompt, files, context)

        assert is_float(score), "Expected score to be float for iteration #{i}"
        assert score >= 0.0, "Score #{score} fell below 0.0 for iteration #{i}"
        assert score <= 100.0, "Score #{score} exceeded 100.0 for iteration #{i}"
      end
    end

    test "safely allocates rosters and manifests under out-of-bounds score inputs" do
      # Out-of-bounds negative score
      manifest_neg = DynamicRoleAllocator.allocate_roster(-999.0, format: :manifest)
      assert manifest_neg.tier == 1
      assert manifest_neg.classification == :trivial
      assert manifest_neg.agent_count == 2
      assert length(manifest_neg.agents) == 2

      # Out-of-bounds excessive score
      manifest_pos = DynamicRoleAllocator.allocate_roster(9999.99, format: :manifest)
      assert manifest_pos.tier == 4
      assert manifest_pos.classification == :critical
      assert manifest_pos.agent_count == 11
      assert length(manifest_pos.agents) == 11

      # Nil score defaults safely to Tier 2
      roster_nil = DynamicRoleAllocator.allocate_roster(nil)
      assert is_list(roster_nil)
      assert length(roster_nil) == 4

      # Map input with composite score
      manifest_map =
        DynamicRoleAllocator.allocate_roster(%{composite: 72.5}, format: :manifest)

      assert manifest_map.tier == 3
      assert manifest_map.classification == :refactor
      assert manifest_map.agent_count == 6
    end

    test "role state machine strictly rejects illegal state jumps" do
      # 1. Illegal jump: :unassigned -> :proposal_submitted on :coder
      assert {:error, {:invalid_transition, :unassigned, :proposal_submitted}} =
               DynamicRoleAllocator.transition_state(:coder, :unassigned, :proposal_submitted)

      # 2. Illegal jump: :unassigned -> :proposal_submitted on :explorer
      assert {:error, {:invalid_transition, :unassigned, :proposal_submitted}} =
               DynamicRoleAllocator.transition_state(:explorer, :unassigned, :proposal_submitted)

      # 3. Illegal jump: 2-arity transition_state(:unassigned, :proposal_submitted)
      assert {:error, {:invalid_transition, :unassigned, :proposal_submitted}} =
               DynamicRoleAllocator.transition_state(:unassigned, :proposal_submitted)

      # 4. Illegal jump on %RoleSpec{}
      coder_spec =
        RoleSpec.new(%{
          role: :coder,
          display_name: "Coder 1",
          state: :waiting_spec
        })

      assert {:error, {:invalid_transition, :waiting_spec, :proposal_submitted}} =
               DynamicRoleAllocator.transition_state(coder_spec, :proposal_submitted)

      assert {:error, {:invalid_transition, :waiting_spec, :approved}} =
               DynamicRoleAllocator.transition_state(coder_spec, :approved)

      # 5. Illegal jump on map
      auditor_map = %{role: :auditor, state: :waiting_proposal}

      assert {:error, {:invalid_transition, :waiting_proposal, :done}} =
               DynamicRoleAllocator.transition_state(auditor_map, :done)

      # 6. Legal transitions succeed
      assert {:ok, :generating_patch} =
               DynamicRoleAllocator.transition_state(:coder, :waiting_spec, :generating_patch)

      assert {:ok, :proposal_submitted} =
               DynamicRoleAllocator.transition_state(
                 :coder,
                 :generating_patch,
                 :proposal_submitted
               )

      assert {:ok, updated_spec} =
               DynamicRoleAllocator.transition_state(coder_spec, :generating_patch)

      assert updated_spec.state == :generating_patch

      # 7. Identity transition (current == target) is always legal
      assert {:ok, :waiting_spec} =
               DynamicRoleAllocator.transition_state(:coder, :waiting_spec, :waiting_spec)
    end

    test "strictly clamps RoleSpec temperature to [0.0, 1.0] under adversarial inputs" do
      spec_neg = RoleSpec.new(%{role: :coder, display_name: "Coder", temperature: -10.5})
      assert spec_neg.temperature == 0.0

      spec_high = RoleSpec.new(%{role: :coder, display_name: "Coder", temperature: 42.0})
      assert spec_high.temperature == 1.0

      spec_valid = RoleSpec.new(%{role: :coder, display_name: "Coder", temperature: 0.65})
      assert spec_valid.temperature == 0.65

      spec_nan = RoleSpec.new(%{role: :coder, display_name: "Coder", temperature: "not_a_number"})
      assert spec_nan.temperature == 0.3
    end
  end

  # ============================================================================
  # 2. CONSENSUS MATRIX MATHEMATICAL STRESS TESTING
  # ============================================================================

  describe "Consensus Matrix Mathematical Axiomatic Stress" do
    test "proves Reflexivity, Symmetry, and strict [0.0, 1.0] Boundedness under 60 randomized 5D vectors" do
      votes = [:approve, :request_changes, :reject]
      dimensions = [:syntax, :correctness, :security, :architectural_fit, :maintainability]

      # Generate 60 randomized assessments
      assessments =
        for i <- 1..60 do
          scores =
            Enum.into(dimensions, %{}, fn dim ->
              # Pseudo-random float in [0.0, 1.0] with varying distribution
              raw = :math.sin(i * 13 + :erlang.phash2(dim)) * 0.5 + 0.5
              {dim, Float.round(raw, 4)}
            end)

          vote = Enum.at(votes, rem(i, length(votes)))
          conf = Float.round(0.5 + 0.5 * (:math.cos(i * 7) * 0.5 + 0.5), 2)

          Assessment.new(%{
            id: "asmt-stress-#{i}",
            proposal_id: "prop-stress",
            reviewer_id: "rev-#{i}",
            vote: vote,
            confidence: conf,
            scores: scores
          })
        end

      # 1. Verify Reflexivity: Agreement(i, i) == 1.0 for all 60 assessments
      for a <- assessments do
        agr_self = ConsensusMatrix.pairwise_agreement(a, a)

        assert agr_self == 1.0,
               "Reflexivity violated for assessment #{a.id}: got #{agr_self}, expected 1.0"
      end

      # 2. Verify Symmetry: Agreement(i, j) == Agreement(j, i)
      # and Boundedness: 0.0 <= Agreement(i, j) <= 1.0 across distinct pairs
      pairs =
        for j <- 0..19, k <- (j + 1)..29 do
          {Enum.at(assessments, j), Enum.at(assessments, k)}
        end

      for {a_i, a_j} <- pairs do
        agr_ij = ConsensusMatrix.pairwise_agreement(a_i, a_j)
        agr_ji = ConsensusMatrix.pairwise_agreement(a_j, a_i)

        assert_in_delta agr_ij,
                        agr_ji,
                        1.0e-6,
                        "Symmetry violated for pair (#{a_i.id}, #{a_j.id}): #{agr_ij} != #{agr_ji}"

        assert agr_ij >= 0.0, "Agreement #{agr_ij} is below 0.0 for pair (#{a_i.id}, #{a_j.id})"
        assert agr_ij <= 1.0, "Agreement #{agr_ij} exceeds 1.0 for pair (#{a_i.id}, #{a_j.id})"
      end
    end

    test "reliably isolates outlier reviewer in N=10 panel where 1 reviewer has completely divergent votes" do
      # 9 Harmonious reviewers voting :approve with high scores
      harmonious_reviewers =
        for i <- 1..9 do
          Assessment.new(%{
            id: "asmt-harm-#{i}",
            proposal_id: "prop-outlier-test",
            reviewer_id: "reviewer-harmonious-#{i}",
            vote: :approve,
            confidence: 0.95,
            scores: %{
              syntax: 0.90 + rem(i, 3) * 0.02,
              correctness: 0.88 + rem(i, 2) * 0.03,
              security: 0.92,
              architectural_fit: 0.89,
              maintainability: 0.91
            }
          })
        end

      # 1 Rogue reviewer voting :reject with divergent scores
      rogue_reviewer =
        Assessment.new(%{
          id: "asmt-rogue-10",
          proposal_id: "prop-outlier-test",
          reviewer_id: "reviewer-rogue-divergent",
          vote: :reject,
          confidence: 0.90,
          scores: %{
            syntax: 0.10,
            correctness: 0.05,
            security: 0.08,
            architectural_fit: 0.12,
            maintainability: 0.05
          }
        })

      full_panel = harmonious_reviewers ++ [rogue_reviewer]
      assert length(full_panel) == 10

      matrix = ConsensusMatrix.compute(full_panel)

      # Assert outlier detection
      assert "reviewer-rogue-divergent" in matrix.outliers,
             "Expected rogue reviewer to be detected as outlier. Detected outliers: #{inspect(matrix.outliers)}"

      # Assert no harmonious reviewers are flagged as outliers
      for i <- 1..9 do
        refute "reviewer-harmonious-#{i}" in matrix.outliers,
               "Harmonious reviewer #{i} was erroneously flagged as an outlier"
      end

      # Assert rogue reviewer's mean agreement is significantly lower
      rogue_agreement = matrix.reviewer_agreements["reviewer-rogue-divergent"]
      assert rogue_agreement < 0.30

      for i <- 1..9 do
        harm_agreement = matrix.reviewer_agreements["reviewer-harmonious-#{i}"]
        assert harm_agreement > 0.70
      end
    end

    test "reliably detects conflict spread > 0.40 across arbitrary dimensions" do
      a1 =
        Assessment.new(%{
          id: "a1",
          proposal_id: "p1",
          reviewer_id: "rev-1",
          vote: :approve,
          confidence: 0.9,
          scores: %{security: 0.95, syntax: 0.85, correctness: 0.80}
        })

      a2 =
        Assessment.new(%{
          id: "a2",
          proposal_id: "p1",
          reviewer_id: "rev-2",
          vote: :approve,
          confidence: 0.9,
          scores: %{security: 0.50, syntax: 0.82, correctness: 0.78}
        })

      # Security spread = 0.95 - 0.50 = 0.45 > 0.40
      matrix = ConsensusMatrix.compute([a1, a2])

      assert :security in matrix.conflicted_dimensions
      refute :syntax in matrix.conflicted_dimensions
      refute :correctness in matrix.conflicted_dimensions

      conflict = Enum.find(matrix.conflicts, &(&1.dimension == :security))
      assert conflict != nil
      assert_in_delta conflict.spread, 0.45, 0.001
      assert conflict.spread > 0.40

      # Under harmonious spread <= 0.40, no conflict reported
      a3 =
        Assessment.new(%{
          id: "a3",
          proposal_id: "p1",
          reviewer_id: "rev-3",
          vote: :approve,
          confidence: 0.9,
          scores: %{security: 0.90, syntax: 0.85, correctness: 0.80}
        })

      matrix_harmonious = ConsensusMatrix.compute([a1, a3])
      assert matrix_harmonious.conflicted_dimensions == []
      assert matrix_harmonious.conflicts == []
    end

    test "fatal flaw gating: proposals with high average scores but security < 0.50 or blocker critiques are NEVER approved" do
      # Case 1: High average score across all dimensions, unanimous :approve, but security is 0.45 (< 0.50)
      a1 =
        Assessment.new(%{
          id: "1",
          proposal_id: "p",
          reviewer_id: "rev-1",
          vote: :approve,
          confidence: 1.0,
          scores: %{
            syntax: 0.95,
            correctness: 0.95,
            architectural_fit: 0.95,
            maintainability: 0.95,
            security: 0.45
          }
        })

      a2 =
        Assessment.new(%{
          id: "2",
          proposal_id: "p",
          reviewer_id: "rev-2",
          vote: :approve,
          confidence: 1.0,
          scores: %{
            syntax: 0.95,
            correctness: 0.95,
            architectural_fit: 0.95,
            maintainability: 0.95,
            security: 0.40
          }
        })

      matrix_low_sec = ConsensusMatrix.compute([a1, a2])

      refute matrix_low_sec.decision == :approved,
             "Proposal with security < 0.50 must NEVER be approved"

      assert matrix_low_sec.decision in [:rejected, :revision_required]

      # Case 2: High scores everywhere, security 0.90, unanimous :approve, but a fatal flaw blocker critique exists
      a3 =
        Assessment.new(%{
          id: "3",
          proposal_id: "p",
          reviewer_id: "sec-auditor",
          vote: :approve,
          confidence: 0.95,
          scores: %{
            syntax: 0.92,
            correctness: 0.90,
            security: 0.90,
            architectural_fit: 0.90,
            maintainability: 0.90
          },
          critique_points: [
            %{
              severity: :blocker,
              category: "security",
              description: "Remote code execution vector identified in parser module"
            }
          ]
        })

      a4 =
        Assessment.new(%{
          id: "4",
          proposal_id: "p",
          reviewer_id: "rev-4",
          vote: :approve,
          confidence: 0.95,
          scores: %{
            syntax: 0.90,
            correctness: 0.90,
            security: 0.90,
            architectural_fit: 0.90,
            maintainability: 0.90
          }
        })

      matrix_blocker = ConsensusMatrix.compute([a3, a4])

      assert matrix_blocker.has_blocker? == true

      refute matrix_blocker.decision == :approved,
             "Proposal with a blocker critique must NEVER be approved"

      assert matrix_blocker.decision == :revision_required

      # Case 3: Blocker critique combined with security < 0.50 strictly forces :rejected
      a5 =
        Assessment.new(%{
          id: "5",
          proposal_id: "p",
          reviewer_id: "sec-auditor-strict",
          vote: :reject,
          confidence: 1.0,
          scores: %{
            syntax: 0.85,
            correctness: 0.70,
            security: 0.30
          },
          critique_points: [
            %{
              severity: :blocker,
              category: "security",
              description: "Unauthenticated SQL injection in query builder"
            }
          ]
        })

      matrix_fatal = ConsensusMatrix.compute([a5, a1])
      assert matrix_fatal.has_blocker? == true
      assert matrix_fatal.decision == :rejected
      refute matrix_fatal.decision == :approved
    end
  end

  # ============================================================================
  # 3. PEERSTREAM HIGH-CONCURRENCY & ETS RETENTION STRESS
  # ============================================================================

  describe "PeerStream High-Concurrency & ETS Retention Stress" do
    setup do
      swarm_id = "stress-swarm-#{System.unique_integer([:positive])}"
      PeerStream.clear_history(swarm_id)

      on_exit(fn ->
        PeerStream.clear_history(swarm_id)
      end)

      {:ok, swarm_id: swarm_id}
    end

    test "broadcasts 120 concurrent messages via Task.async_stream with zero dropped messages in ETS",
         %{swarm_id: swarm_id} do
      # Subscribe calling process to verify pubsub distribution
      :ok = PeerStream.subscribe(swarm_id)

      message_count = 120

      # Broadcast 120 messages concurrently
      broadcast_results =
        1..message_count
        |> Task.async_stream(
          fn idx ->
            from_agent = "coder-shard-#{rem(idx, 4) + 1}"
            to_agent = "auditor-node-#{rem(idx, 3) + 1}"
            role = Enum.at([:coder, :auditor, :explorer, :architect], rem(idx, 4))
            type = Enum.at([:pulse, :patch_hunk, :critique, :telemetry], rem(idx, 4))

            payload = %{
              "index" => idx,
              "data" => "stress_payload_bytes_#{idx}",
              "timestamp" => System.monotonic_time(:microsecond)
            }

            PeerStream.broadcast_peer_message(
              swarm_id,
              from_agent,
              to_agent,
              role,
              type,
              payload
            )
          end,
          max_concurrency: 20,
          timeout: 10_000
        )
        |> Enum.to_list()

      # Assert all 120 async tasks succeeded
      assert length(broadcast_results) == message_count

      for result <- broadcast_results do
        assert {:ok, {:ok, msg}} = result
        assert is_binary(msg.id)
        assert msg.swarm_id == swarm_id
      end

      # Query ETS storage for accumulated history
      history = PeerStream.get_history(swarm_id)

      # Assert ZERO dropped messages
      assert length(history) == message_count,
             "Expected exactly #{message_count} messages in ETS, but found #{length(history)}"

      # Assert all message IDs are unique
      unique_ids = Enum.uniq_by(history, & &1.id)
      assert length(unique_ids) == message_count, "Found duplicate message IDs in ETS"

      # Assert all expected payloads were retained without corruption
      recorded_indices =
        history
        |> Enum.map(fn msg ->
          msg.payload["index"] || msg.payload[:index]
        end)
        |> Enum.sort()

      assert recorded_indices == Enum.to_list(1..message_count)
    end

    test "maintains strict chronological sequence numbers in ETS under sequential broadcasting",
         %{swarm_id: swarm_id} do
      for seq <- 1..15 do
        {:ok, _} =
          PeerStream.broadcast_peer_message(
            swarm_id,
            "agent-#{seq}",
            "agent-#{seq + 1}",
            :coder,
            :step,
            %{"seq" => seq, "label" => "step_#{seq}"}
          )

        # Microsecond separation ensures distinct monotonic keys
        :timer.sleep(1)
      end

      history = PeerStream.get_history(swarm_id)
      assert length(history) == 15

      seqs = Enum.map(history, fn msg -> msg.payload["seq"] end)

      assert seqs == Enum.to_list(1..15),
             "Expected history to maintain strict chronological order 1..15, got #{inspect(seqs)}"
    end

    test "maintains filter integrity by role and agent identifier under high data volume", %{
      swarm_id: swarm_id
    } do
      # Broadcast controlled numbers of messages per role
      # 25 explorer messages from "explorer-alpha" to "architect-lead"
      for i <- 1..25 do
        PeerStream.broadcast_peer_message(
          swarm_id,
          "explorer-alpha",
          "architect-lead",
          :explorer,
          :scan_result,
          %{"i" => i}
        )
      end

      # 30 architect messages from "architect-lead" to "coder-prime"
      for i <- 1..30 do
        PeerStream.broadcast_peer_message(
          swarm_id,
          "architect-lead",
          "coder-prime",
          :architect,
          :blueprint,
          %{"i" => i}
        )
      end

      # 45 coder messages from "coder-prime" to "auditor-gate"
      for i <- 1..45 do
        PeerStream.broadcast_peer_message(
          swarm_id,
          "coder-prime",
          "auditor-gate",
          :coder,
          :patch_submission,
          %{"i" => i}
        )
      end

      # 20 auditor messages from "auditor-gate" to "coder-prime"
      for i <- 1..20 do
        PeerStream.broadcast_peer_message(
          swarm_id,
          "auditor-gate",
          "coder-prime",
          :auditor,
          :critique_report,
          %{"i" => i}
        )
      end

      total_sent = 25 + 30 + 45 + 20
      assert total_sent == 120

      history = PeerStream.get_history(swarm_id)
      assert length(history) == 120

      # 1. Filter by role
      explorers = PeerStream.filter_by_role(history, :explorer)
      assert length(explorers) == 25
      assert Enum.all?(explorers, &(&1.role == :explorer))

      architects = PeerStream.filter_by_role(history, :architect)
      assert length(architects) == 30
      assert Enum.all?(architects, &(&1.role == :architect))

      coders = PeerStream.filter_by_role(history, :coder)
      assert length(coders) == 45
      assert Enum.all?(coders, &(&1.role == :coder))

      auditors = PeerStream.filter_by_role(history, :auditor)
      assert length(auditors) == 20
      assert Enum.all?(auditors, &(&1.role == :auditor))

      # Role string normalization filter
      assert length(PeerStream.filter_by_role(history, "coder")) == 45

      # 2. Filter by agent identifier (matches from_agent or to_agent)
      alpha_msgs = PeerStream.filter_by_agent(history, "explorer-alpha")
      assert length(alpha_msgs) == 25
      assert Enum.all?(alpha_msgs, &(&1.from_agent == "explorer-alpha"))

      # architect-lead received 25 from explorer-alpha and sent 30 to coder-prime = 55
      arch_msgs = PeerStream.filter_by_agent(history, "architect-lead")
      assert length(arch_msgs) == 55

      assert Enum.all?(
               arch_msgs,
               &(&1.from_agent == "architect-lead" or &1.to_agent == "architect-lead")
             )

      # coder-prime received 30 from arch, sent 45 to aud, received 20 from aud = 95
      coder_msgs = PeerStream.filter_by_agent(history, "coder-prime")
      assert length(coder_msgs) == 95

      assert Enum.all?(
               coder_msgs,
               &(&1.from_agent == "coder-prime" or &1.to_agent == "coder-prime")
             )
    end
  end
end
