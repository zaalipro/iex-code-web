defmodule IexCode.Workflows.WorkflowDagTest do
  use ExUnit.Case, async: true

  alias IexCode.Workflows.WorkflowDag

  defp valid_steps do
    [
      %{
        "key" => "step_1",
        "kind" => "deep_research",
        "title" => "Research Auth Spec",
        "depends_on" => [],
        "params" => %{"query" => "OAuth2 PKCE best practices"},
        "model_config" => %{"reasoning_effort" => "high"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "step_2",
        "kind" => "swarm_code_gen",
        "title" => "Implement Auth",
        "depends_on" => ["step_1"],
        "params" => %{
          "prompt" => "Generate auth modules",
          "summary" => "{{steps.step_1.output.report}}"
        },
        "model_config" => %{"reasoning_effort" => "medium"},
        "safety_policy" => "full_auto"
      },
      %{
        "key" => "step_3",
        "kind" => "test_verification",
        "title" => "Verify Tests",
        "depends_on" => ["step_2"],
        "params" => %{"test_command" => "mix test"},
        "model_config" => %{"reasoning_effort" => "none"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "step_4",
        "kind" => "security_audit",
        "title" => "Audit Security",
        "depends_on" => ["step_3"],
        "params" => %{"strict" => true},
        "model_config" => %{"reasoning_effort" => "high"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "step_5",
        "kind" => "git_commit",
        "title" => "Commit Changes",
        "depends_on" => ["step_4"],
        "params" => %{"commit_message" => "feat: add oauth2 auth"},
        "model_config" => %{"reasoning_effort" => "none"},
        "safety_policy" => "prompt_dangerous"
      }
    ]
  end

  describe "validate/2" do
    test "accepts valid acyclic workflow DAG" do
      assert :ok = WorkflowDag.validate(valid_steps())
    end

    test "rejects empty steps" do
      assert {:error, :empty_steps} = WorkflowDag.validate([])
      assert {:error, :invalid_steps_list} = WorkflowDag.validate(nil)
    end

    test "rejects steps exceeding max_steps limit" do
      oversized =
        for i <- 1..65 do
          %{
            "key" => "step_#{i}",
            "kind" => "deep_research",
            "title" => "Step #{i}",
            "depends_on" => []
          }
        end

      assert {:error, :too_many_steps} = WorkflowDag.validate(oversized)
    end

    test "rejects invalid step key formats" do
      bad_step = %{"key" => "invalid step key with spaces", "kind" => "deep_research"}

      assert {:error, {:invalid_step_key, "invalid step key with spaces"}} =
               WorkflowDag.validate([bad_step])

      empty_key = %{"key" => "", "kind" => "deep_research"}
      assert {:error, {:invalid_step_key, ""}} = WorkflowDag.validate([empty_key])
    end

    test "rejects unsupported step kinds" do
      bad_kind = %{"key" => "step_1", "kind" => "unsupported_magic_kind", "depends_on" => []}

      assert {:error, {:unsupported_kind, "unsupported_magic_kind"}} =
               WorkflowDag.validate([bad_kind])
    end

    test "rejects duplicate step keys" do
      dup_steps = [
        %{"key" => "step_1", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "step_1", "kind" => "swarm_code_gen", "depends_on" => []}
      ]

      assert {:error, :duplicate_step_keys} = WorkflowDag.validate(dup_steps)
    end

    test "rejects self-dependencies" do
      self_dep = [
        %{"key" => "step_1", "kind" => "deep_research", "depends_on" => ["step_1"]}
      ]

      assert {:error, {:self_dependency, "step_1"}} = WorkflowDag.validate(self_dep)
    end

    test "rejects missing dependencies" do
      missing_dep = [
        %{"key" => "step_1", "kind" => "deep_research", "depends_on" => ["nonexistent_step"]}
      ]

      assert {:error, {:missing_dependencies, "step_1", ["nonexistent_step"]}} =
               WorkflowDag.validate(missing_dep)
    end

    test "detects direct and indirect cycles using Kahn algorithm" do
      direct_cycle = [
        %{"key" => "A", "kind" => "deep_research", "depends_on" => ["B"]},
        %{"key" => "B", "kind" => "swarm_code_gen", "depends_on" => ["A"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(direct_cycle)

      three_node_cycle = [
        %{"key" => "A", "kind" => "deep_research", "depends_on" => ["C"]},
        %{"key" => "B", "kind" => "swarm_code_gen", "depends_on" => ["A"]},
        %{"key" => "C", "kind" => "test_verification", "depends_on" => ["B"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(three_node_cycle)
    end

    test "validates model reasoning effort and safety policies" do
      bad_reasoning = [
        %{
          "key" => "step_1",
          "kind" => "deep_research",
          "depends_on" => [],
          "model_config" => %{"reasoning_effort" => "super_ultra_max"}
        }
      ]

      assert {:error, {:invalid_reasoning_effort, "super_ultra_max"}} =
               WorkflowDag.validate(bad_reasoning)

      bad_safety = [
        %{
          "key" => "step_1",
          "kind" => "deep_research",
          "depends_on" => [],
          "safety_policy" => "ignore_all_rules"
        }
      ]

      assert {:error, {:invalid_safety_policy, "ignore_all_rules"}} =
               WorkflowDag.validate(bad_safety)
    end

    test "validates variable references against declared and step variables" do
      steps_with_vars = [
        %{
          "key" => "step_1",
          "kind" => "deep_research",
          "depends_on" => [],
          "params" => %{"query" => "Research for {{feature_name}}"}
        }
      ]

      # Missing declared variable
      assert {:error, {:invalid_variable_references, "step_1", ["feature_name"]}} =
               WorkflowDag.validate(steps_with_vars, [])

      # With declared variable
      assert :ok =
               WorkflowDag.validate(steps_with_vars, [
                 %{"name" => "feature_name", "type" => "string"}
               ])
    end
  end

  describe "topological_sort/1 and topological_layers/1" do
    test "computes topological sort order" do
      assert {:ok, sorted} = WorkflowDag.topological_sort(valid_steps())
      assert sorted == ["step_1", "step_2", "step_3", "step_4", "step_5"]
    end

    test "computes parallel layers for branching DAG" do
      branching_steps = [
        %{"key" => "root", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "branch_a", "kind" => "swarm_code_gen", "depends_on" => ["root"]},
        %{"key" => "branch_b", "kind" => "test_verification", "depends_on" => ["root"]},
        %{"key" => "join", "kind" => "git_commit", "depends_on" => ["branch_a", "branch_b"]}
      ]

      assert {:ok, layers} = WorkflowDag.topological_layers(branching_steps)
      assert length(layers) == 3

      layer_0_keys = Enum.map(Enum.at(layers, 0), &WorkflowDag.step_key/1)
      layer_1_keys = Enum.map(Enum.at(layers, 1), &WorkflowDag.step_key/1) |> Enum.sort()
      layer_2_keys = Enum.map(Enum.at(layers, 2), &WorkflowDag.step_key/1)

      assert layer_0_keys == ["root"]
      assert layer_1_keys == ["branch_a", "branch_b"]
      assert layer_2_keys == ["join"]
    end

    test "determines ready steps dynamically" do
      steps = valid_steps()

      # Initially, only step_1 (in-degree 0) is ready
      ready = WorkflowDag.ready_steps(steps, [])
      assert Enum.map(ready, &WorkflowDag.step_key/1) == ["step_1"]

      # When step_1 completes, step_2 becomes ready
      ready_2 = WorkflowDag.ready_steps(steps, ["step_1"])
      assert Enum.map(ready_2, &WorkflowDag.step_key/1) == ["step_2"]

      # When step_1 and step_2 complete, step_3 becomes ready
      ready_3 = WorkflowDag.ready_steps(steps, ["step_1", "step_2"])
      assert Enum.map(ready_3, &WorkflowDag.step_key/1) == ["step_3"]

      # If step_2 failed, it is not ready
      assert WorkflowDag.ready_steps(steps, ["step_1"], ["step_2"]) == []
    end
  end

  describe "extract_variable_references/1" do
    test "extracts variables from strings, lists, and maps" do
      assert WorkflowDag.extract_variable_references(
               "Hello {{name}}, welcome to {{project.name}}!"
             ) ==
               ["name", "project.name"]

      assert WorkflowDag.extract_variable_references(%{
               "a" => "Use {{token}}",
               "b" => ["Item {{item_id}}", 123]
             })
             |> Enum.sort() == ["item_id", "token"]
    end
  end
end
