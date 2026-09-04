defmodule IexCode.Workflows.ResearchChainingTest do
  use ExUnit.Case, async: true

  alias IexCode.Workflows.Steps.{DeepResearch, SwarmCodeGen}
  alias IexCode.Workflows.VariableInterpolator

  describe "research-to-code chaining" do
    test "SwarmCodeGen automatically extracts upstream research and augments coder prompt" do
      # 1. Execute upstream research step
      research_step = %{
        "id" => "step-research",
        "title" => "Deep Research",
        "kind" => "deep_research",
        "params" => %{
          "query" => "Fault-Tolerant DynamicSupervisor Architecture",
          "level" => "deep"
        }
      }

      assert {:ok, research_output} = DeepResearch.execute(research_step, %{})

      # 2. Build execution context with completed upstream research
      context = %{
        "steps" => %{
          "step_research" => %{
            "id" => "step-research",
            "kind" => "deep_research",
            "state" => "completed",
            "output" => research_output
          }
        }
      }

      # 3. Execute downstream swarm code generation step
      code_step = %{
        "id" => "step-code",
        "title" => "Swarm Code Generation",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Build the DynamicSupervisor worker pool module.",
          "target_files" => ["lib/iex_code/worker_pool.ex"]
        }
      }

      assert {:ok, code_output} = SwarmCodeGen.execute(code_step, context)

      # 4. Verify research chaining provenance
      assert code_output["research_chained"] == true

      assert code_output["chained_research_query"] ==
               "Fault-Tolerant DynamicSupervisor Architecture"

      # 5. Verify augmented prompt contains directives
      augmented = code_output["augmented_prompt"]
      assert String.contains?(augmented, "Build the DynamicSupervisor worker pool module.")

      assert String.contains?(
               augmented,
               "[RESEARCH ARCHITECTURE DIRECTIVES & VERIFIED CONSTRAINTS]"
             )

      assert String.contains?(augmented, "Fault-Tolerant DynamicSupervisor Architecture")
      assert String.contains?(augmented, "Verified Specifications to Enforce")
      assert String.contains?(augmented, "Architectural Antipatterns & Trade-offs to Avoid")
    end

    test "interpolates {{steps.research.output.report}} and query through VariableInterpolator" do
      research_output = %{
        "query" => "ETS Table Concurrency",
        "report" => "# Full Research Report\nDetails on ETS concurrency...",
        "verified_claims" => [
          %{"recommendation" => "Use :read_concurrency: true for read-heavy workloads."}
        ],
        "disputed_claims" => []
      }

      context = %{
        "steps" => %{
          "research" => %{
            "kind" => "deep_research",
            "state" => "completed",
            "output" => research_output
          }
        }
      }

      raw_step = %{
        "id" => "code-1",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Implement ETS storage for {{steps.research.output.query}}",
          "context_summary" => "{{steps.research.output.report}}"
        }
      }

      assert {:ok, interpolated_step} = VariableInterpolator.interpolate(raw_step, context)

      assert interpolated_step["params"]["prompt"] ==
               "Implement ETS storage for ETS Table Concurrency"

      assert String.contains?(
               interpolated_step["params"]["context_summary"],
               "# Full Research Report"
             )

      assert {:ok, output} = SwarmCodeGen.execute(interpolated_step, context)
      assert output["research_chained"] == true

      assert String.contains?(
               output["augmented_prompt"],
               "Implement ETS storage for ETS Table Concurrency"
             )
    end

    test "executes normally without research directives when no upstream research exists" do
      code_step = %{
        "id" => "step-code-standalone",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Create simple math module"
        }
      }

      assert {:ok, output} = SwarmCodeGen.execute(code_step, %{})
      assert output["research_chained"] == false
      assert output["chained_research_query"] == nil
      assert output["augmented_prompt"] == "Create simple math module"
    end
  end
end
