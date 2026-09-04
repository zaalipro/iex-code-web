defmodule IexCode.Workflows.Steps.SwarmCodeGenTest do
  use ExUnit.Case, async: false

  alias IexCode.Workflows.Steps.SwarmCodeGen
  alias IexCode.Swarm.PeerStream

  setup do
    swarm_id = "test-swarm-step-#{System.unique_integer([:positive])}"
    PeerStream.clear_history(swarm_id)

    on_exit(fn ->
      PeerStream.clear_history(swarm_id)
    end)

    {:ok, swarm_id: swarm_id}
  end

  describe "SwarmCodeGen Dynamic Role Allocation & Peer Coordination" do
    test "dynamically sizes swarm roster and emits peer handoff messages", %{swarm_id: swarm_id} do
      step = %{
        "id" => "step-code-1",
        "kind" => "swarm_code_gen",
        "title" => "Implement Feature Exporter",
        "params" => %{
          "prompt" => "Implement session exporter module and formatters",
          "target_files" => ["lib/iex_code/exporter.ex", "lib/iex_code/formatters.ex"]
        }
      }

      context = %{
        "run_id" => swarm_id,
        "session_id" => swarm_id
      }

      assert {:ok, output} = SwarmCodeGen.execute(step, context)

      # 1. Output structure
      assert output["status"] == "completed"
      assert is_list(output["patches"])
      assert length(output["patches"]) >= 1

      # 2. Dynamic Roster
      assert is_list(output["dynamic_roster"])
      assert length(output["dynamic_roster"]) >= 2
      roster_roles = Enum.map(output["dynamic_roster"], & &1[:role])
      assert :coder in roster_roles
      assert :auditor in roster_roles

      # 3. Consensus Matrix & Merge Gating
      assert is_map(output["consensus_matrix"])
      assert output["merge_verdict"] in [:approved, :revision_required]
      assert output["consensus_matrix"].decision == output["merge_verdict"]

      # 4. Live Peer Messages
      assert is_list(output["peer_messages"])
      assert length(output["peer_messages"]) >= 3

      types = Enum.map(output["peer_messages"], & &1.type)
      assert :context_handoff in types
      assert :architecture_spec in types
      assert :proposal_submission in types
      assert :consensus_verdict in types
    end

    test "integrates upstream research context and scales roster complexity", %{
      swarm_id: swarm_id
    } do
      step = %{
        "id" => "step-code-2",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Refactor and decouple auth permissions and crypto signing",
          "target_files" => [
            "lib/iex_code/auth/permissions.ex",
            "lib/iex_code/crypto/signer.ex",
            "lib/iex_code/tools/sandbox.ex"
          ]
        }
      }

      context = %{
        "run_id" => swarm_id,
        "steps" => %{
          "research_step" => %{
            "kind" => "deep_research",
            "state" => "completed",
            "output" => %{
              "query" => "Zero-Trust OTP Auth",
              "verified_claims" => [%{"recommendation" => "Use HMAC-SHA256"}],
              "disputed_claims" => [%{"rationale" => "Avoid custom RSA padding"}]
            }
          }
        }
      }

      assert {:ok, output} = SwarmCodeGen.execute(step, context)

      assert output["research_chained"] == true
      assert output["chained_research_query"] == "Zero-Trust OTP Auth"
      assert output["augmented_prompt"] =~ "RESEARCH ARCHITECTURE DIRECTIVES"

      # High complexity with disputed claims & sensitive security keywords allocates Tier 3/4
      assert length(output["dynamic_roster"]) >= 6
    end
  end

  describe "Consensus Merge Gating & Self-Healing Loop" do
    test "executes self-healing loop when revision is requested", %{swarm_id: swarm_id} do
      step = %{
        "id" => "step-code-heal",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Add robust validation to input parser",
          "target_files" => ["lib/parser.ex"],
          "mock_verdict" => "revision_required"
        }
      }

      context = %{"run_id" => swarm_id}

      assert {:ok, output} = SwarmCodeGen.execute(step, context)

      # Should have self-healed
      assert output["status"] == "completed"
      assert output["merge_verdict"] == :approved

      # Check that patches were revised
      first_patch = List.first(output["patches"])
      hunk_lines = hd(first_patch["hunks"])["lines"]
      assert Enum.any?(hunk_lines, &String.contains?(&1, "Self-Healing Consensus Revision"))
    end

    test "records rejection when security blocker cannot be resolved", %{swarm_id: swarm_id} do
      step = %{
        "id" => "step-code-reject",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Execute shell command directly from input",
          "target_files" => ["lib/shell.ex"],
          "mock_verdict" => "rejected"
        }
      }

      context = %{"run_id" => swarm_id}

      assert {:ok, output} = SwarmCodeGen.execute(step, context)

      assert output["status"] == "rejected"
      assert output["merge_verdict"] == :rejected
      assert output["consensus_matrix"].has_blocker? == true
    end

    test "enforces read_only safety policy by halting execution" do
      step = %{
        "id" => "step-ro",
        "kind" => "swarm_code_gen",
        "safety_policy" => "read_only",
        "params" => %{
          "prompt" => "Modify system file"
        }
      }

      assert {:error, msg} = SwarmCodeGen.execute(step, %{})
      assert msg =~ "read_only"
    end
  end
end
