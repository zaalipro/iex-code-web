defmodule IexCode.Engine.DynamicRoleAllocatorTest do
  use ExUnit.Case, async: true

  alias IexCode.Engine.DynamicRoleAllocator
  alias IexCode.Swarm.RoleSpec

  describe "Task Complexity Assessment" do
    test "evaluates Tier 1 complexity (score < 25) for single-file typo or comment fix" do
      prompt = "Fix typo in comment in core.ex"
      target_files = ["lib/iex_code/core.ex"]
      score = DynamicRoleAllocator.assess_task_complexity(prompt, target_files)

      assert is_float(score)
      assert score >= 0.0 and score < 25.0

      breakdown = DynamicRoleAllocator.assess_task_complexity_breakdown(prompt, target_files)
      assert breakdown.scope == 10.0
      assert breakdown.intent == 10.0
      assert breakdown.risk == 0.0
      assert breakdown.research == 0.0
    end

    test "evaluates Tier 2 complexity (25 <= score < 55) for standard module feature" do
      prompt = "Add feature endpoint to export session artifacts to json"
      target_files = ["lib/iex_code/sessions/exporter.ex", "lib/iex_code/sessions/formatters.ex"]
      score = DynamicRoleAllocator.assess_task_complexity(prompt, target_files)

      assert score >= 25.0 and score < 55.0
    end

    test "evaluates Tier 3 complexity (55 <= score < 80) for cross-module refactoring" do
      prompt = "Refactor and restructure engine coordinator to decouple supervisors and workers"

      target_files = [
        "lib/iex_code/engine/coordinator.ex",
        "lib/iex_code/engine/supervisor.ex",
        "lib/iex_code/workflows/dispatcher.ex",
        "lib/iex_code/workflows/policy.ex",
        "lib/iex_code/observability/metrics.ex"
      ]

      context = %{"verified_claims" => ["architecture spec"]}

      score = DynamicRoleAllocator.assess_task_complexity(prompt, target_files, context)
      assert score >= 55.0 and score < 80.0
    end

    test "evaluates Tier 4 complexity (score >= 80) for critical auth, crypto, and sandbox overhaul" do
      prompt =
        "Complete rewrite of the system security policy: crypto tokens, auth credentials, and sandbox shell execution permissions"

      target_files = [
        "lib/iex_code/security/auth.ex",
        "lib/iex_code/security/crypto_signer.ex",
        "lib/iex_code/tools/sandbox_executor.ex",
        "lib/iex_code/engine/policy.ex"
      ]

      context = %{
        "disputed_claims" => [
          %{topic: "Token Signing", status: :disputed}
        ]
      }

      score = DynamicRoleAllocator.assess_task_complexity(prompt, target_files, context)
      assert score >= 80.0 and score <= 100.0

      breakdown =
        DynamicRoleAllocator.assess_task_complexity_breakdown(prompt, target_files, context)

      assert breakdown.research == 85.0
      assert breakdown.risk >= 90.0
      assert breakdown.intent == 100.0
    end

    test "weights upstream research context properly" do
      prompt = "Build feature"
      files = ["lib/iex_code/file.ex"]

      score_no_res = DynamicRoleAllocator.assess_task_complexity(prompt, files, %{})

      score_verified =
        DynamicRoleAllocator.assess_task_complexity(prompt, files, %{
          "verified_claims" => ["spec1"]
        })

      score_disputed =
        DynamicRoleAllocator.assess_task_complexity(prompt, files, %{
          "disputed_claims" => ["conflict1"]
        })

      assert score_verified > score_no_res
      assert score_disputed > score_verified
      assert_in_delta score_verified - score_no_res, 50.0 * 0.15, 0.01
      assert_in_delta score_disputed - score_no_res, 85.0 * 0.15, 0.01
    end
  end

  describe "Roster Tier Allocation & Capability Profiles" do
    test "allocates Tier 1 roster (2 agents) for single-file typo or syntax fix" do
      roster = DynamicRoleAllocator.allocate_roster(15.0)

      assert length(roster) == 2
      roles = Enum.map(roster, & &1.role)
      assert :coder in roles
      assert :auditor in roles

      coder = Enum.find(roster, &(&1.role == :coder))
      assert coder.model_id =~ "haiku" or coder.model_id =~ "mini"
      assert coder.reasoning_effort in ["none", "low"]
      assert coder.temperature <= 0.3
    end

    test "allocates Tier 2 roster (4 agents) for standard module feature" do
      roster = DynamicRoleAllocator.allocate_roster(40.0)

      assert length(roster) == 4
      roles = Enum.map(roster, & &1.role)
      assert :explorer in roles
      assert :architect in roles
      assert :coder in roles
      assert :auditor in roles

      Enum.each(roster, fn spec ->
        assert spec.reasoning_effort in ["medium", :medium]
        assert spec.temperature <= 0.4
      end)
    end

    test "allocates Tier 3 roster (6 agents) with 2 explorer shards for cross-module refactor" do
      roster = DynamicRoleAllocator.allocate_roster(70.0)

      assert length(roster) == 6
      explorers = Enum.filter(roster, &(&1.role == :explorer))
      coders = Enum.filter(roster, &(&1.role == :coder))
      architects = Enum.filter(roster, &(&1.role == :architect))
      auditors = Enum.filter(roster, &(&1.role == :auditor))

      assert length(explorers) == 2
      assert length(coders) == 2
      assert length(architects) == 1
      assert length(auditors) == 1

      Enum.each(roster, fn spec ->
        assert spec.reasoning_effort in ["high", :high]
      end)
    end

    test "allocates Tier 4 roster (8+ agents) with dedicated SecurityAuditor for sensitive prompt" do
      manifest = DynamicRoleAllocator.allocate_roster(92.0, format: :manifest)

      assert manifest.tier == 4
      assert manifest.classification == :critical
      assert manifest.agent_count >= 8 and manifest.agent_count <= 12

      roster = manifest.agents
      sec_auditor = Enum.find(roster, &(&1.sub_role == :security_auditor))
      assert sec_auditor != nil
      assert sec_auditor.temperature == 0.0

      verifier = Enum.find(roster, &(&1.role == :verifier))
      assert verifier != nil
      assert :run_command in verifier.allowed_tools

      synthesizer = Enum.find(roster, &(&1.role == :synthesizer))
      assert synthesizer != nil
    end

    test "supports calling allocate_roster with prompt, target_files, and context" do
      roster =
        DynamicRoleAllocator.allocate_roster(
          "Fix small typo in comment",
          ["lib/iex_code/small.ex"],
          %{}
        )

      assert length(roster) == 2
    end
  end

  describe "RoleSpec Struct Validation" do
    test "correctly clamps temperature and configures reasoning effort per capability profile" do
      spec =
        RoleSpec.new(%{
          role: :coder,
          display_name: "Coder Agent",
          temperature: 1.8,
          reasoning_effort: "high"
        })

      assert spec.temperature == 1.0
      assert spec.reasoning_effort == "high"

      spec_low =
        RoleSpec.new(%{
          role: :coder,
          display_name: "Coder Agent",
          temperature: -0.5
        })

      assert spec_low.temperature == 0.0
    end

    test "assigns default tools based on role" do
      exp = RoleSpec.new(%{role: :explorer, display_name: "Explorer"})
      assert :view_file in exp.allowed_tools
      assert :list_dir in exp.allowed_tools

      coder = RoleSpec.new(%{role: :coder, display_name: "Coder"})
      assert :replace_file_content in coder.allowed_tools
      assert :write_to_file in coder.allowed_tools

      verifier = RoleSpec.new(%{role: :verifier, display_name: "Verifier"})
      assert :run_command in verifier.allowed_tools
    end
  end

  describe "Role State Machine Transitions" do
    test "Explorer: enforces legal transitions and rejects invalid state jumps" do
      assert {:ok, :scanning} =
               DynamicRoleAllocator.transition_state(:explorer, :unassigned, :scanning)

      assert {:ok, :synthesizing_context} =
               DynamicRoleAllocator.transition_state(:explorer, :scanning, :synthesizing_context)

      assert {:ok, :context_ready} =
               DynamicRoleAllocator.transition_state(
                 :explorer,
                 :synthesizing_context,
                 :context_ready
               )

      assert {:ok, :idle} =
               DynamicRoleAllocator.transition_state(:explorer, :context_ready, :idle)

      # Invalid transition
      assert {:error, {:invalid_transition, :unassigned, :context_ready}} =
               DynamicRoleAllocator.transition_state(:explorer, :unassigned, :context_ready)
    end

    test "Architect: enforces design and contract specification transitions" do
      assert {:ok, :designing} =
               DynamicRoleAllocator.transition_state(:architect, :waiting_context, :designing)

      assert {:ok, :spec_published} =
               DynamicRoleAllocator.transition_state(:architect, :designing, :spec_published)

      assert {:ok, :reviewing_proposals} =
               DynamicRoleAllocator.transition_state(
                 :architect,
                 :spec_published,
                 :reviewing_proposals
               )

      assert {:ok, :approved} =
               DynamicRoleAllocator.transition_state(:architect, :reviewing_proposals, :approved)

      assert {:error, {:invalid_transition, :waiting_context, :approved}} =
               DynamicRoleAllocator.transition_state(:architect, :waiting_context, :approved)
    end

    test "Coder: enforces code generation, self-testing, and revision loop" do
      assert {:ok, :generating_patch} =
               DynamicRoleAllocator.transition_state(:coder, :waiting_spec, :generating_patch)

      assert {:ok, :self_testing} =
               DynamicRoleAllocator.transition_state(:coder, :generating_patch, :self_testing)

      assert {:ok, :proposal_submitted} =
               DynamicRoleAllocator.transition_state(:coder, :self_testing, :proposal_submitted)

      assert {:ok, :revising} =
               DynamicRoleAllocator.transition_state(:coder, :proposal_submitted, :revising)

      assert {:ok, :generating_patch} =
               DynamicRoleAllocator.transition_state(:coder, :revising, :generating_patch)

      assert {:error, {:invalid_transition, :waiting_spec, :revising}} =
               DynamicRoleAllocator.transition_state(:coder, :waiting_spec, :revising)
    end

    test "Auditor: enforces review, scoring, and verdict emission" do
      assert {:ok, :auditing} =
               DynamicRoleAllocator.transition_state(:auditor, :waiting_proposal, :auditing)

      assert {:ok, :scoring} =
               DynamicRoleAllocator.transition_state(:auditor, :auditing, :scoring)

      assert {:ok, :verdict_emitted} =
               DynamicRoleAllocator.transition_state(:auditor, :scoring, :verdict_emitted)
    end

    test "updates RoleSpec struct state in place" do
      spec = RoleSpec.new(%{role: :coder, display_name: "Coder", state: :waiting_spec})
      assert {:ok, updated} = DynamicRoleAllocator.transition_state(spec, :generating_patch)
      assert updated.state == :generating_patch
    end

    test "supports 2-arity transition_state(current_state, target_state)" do
      assert {:ok, :scanning} = DynamicRoleAllocator.transition_state(:unassigned, :scanning)

      assert {:error, {:invalid_transition, :unassigned, :done}} =
               DynamicRoleAllocator.transition_state(:unassigned, :done)
    end
  end
end
