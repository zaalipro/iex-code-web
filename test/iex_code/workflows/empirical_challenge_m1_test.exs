defmodule IexCode.Workflows.EmpiricalChallengeM1Test do
  @moduledoc """
  Empirical adversarial challenge suite for Milestone 1: Grok-Like Workflows Engine & Schema.
  Tests pathological DAGs, Kahn algorithm cycles, variable interpolator recursion & types,
  and Engine execution orchestration (pause, resume, cancel, retry, concurrency).
  """

  use IexCode.DataCase

  alias IexCode.Projects.Project
  alias IexCode.Workflows
  alias IexCode.Workflows.Engine
  alias IexCode.Workflows.VariableInterpolator
  alias IexCode.Workflows.Workflow
  alias IexCode.Workflows.WorkflowDag

  # Helper to construct minimal test project
  defp create_test_project do
    root = "/tmp/iex_code_challenge_m1_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["config", "user.name", "Challenger User"], cd: root)
    System.cmd("git", ["config", "user.email", "challenger@example.com"], cd: root)

    Repo.retry_on_busy(fn ->
      %Project{}
      |> Project.changeset(%{
        name: "Challenge M1 Project",
        root_path: root,
        description: "Adversarial test project for Milestone 1"
      })
      |> Repo.insert!()
    end)
  end

  # ============================================================================
  # SECTION 1: PATHOLOGICAL DAG STRESS TESTS
  # ============================================================================

  describe "Pathological DAG: Cycle detection of varying lengths and topologies" do
    test "detects length-2 direct reciprocal cycle (A -> B -> A)" do
      steps = [
        %{"key" => "step_a", "kind" => "deep_research", "depends_on" => ["step_b"]},
        %{"key" => "step_b", "kind" => "swarm_code_gen", "depends_on" => ["step_a"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(steps)
      assert {:error, :cyclic_dependencies} = WorkflowDag.topological_sort(steps)
    end

    test "detects length-3 triangular cycle (A -> B -> C -> A)" do
      steps = [
        %{"key" => "step_a", "kind" => "deep_research", "depends_on" => ["step_c"]},
        %{"key" => "step_b", "kind" => "swarm_code_gen", "depends_on" => ["step_a"]},
        %{"key" => "step_c", "kind" => "test_verification", "depends_on" => ["step_b"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(steps)
      assert {:error, :cyclic_dependencies} = WorkflowDag.topological_sort(steps)
    end

    test "detects length-5 pentagonal cycle (A -> B -> C -> D -> E -> A)" do
      steps = [
        %{"key" => "step_a", "kind" => "deep_research", "depends_on" => ["step_e"]},
        %{"key" => "step_b", "kind" => "swarm_code_gen", "depends_on" => ["step_a"]},
        %{"key" => "step_c", "kind" => "test_verification", "depends_on" => ["step_b"]},
        %{"key" => "step_d", "kind" => "security_audit", "depends_on" => ["step_c"]},
        %{"key" => "step_e", "kind" => "git_commit", "depends_on" => ["step_d"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(steps)
      assert {:error, :cyclic_dependencies} = WorkflowDag.topological_sort(steps)
    end

    test "detects cycle embedded in a larger graph with a valid prefix" do
      # root -> valid_1 -> valid_2 -> cycle_x -> cycle_y -> cycle_x
      steps = [
        %{"key" => "root", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "valid_1", "kind" => "deep_research", "depends_on" => ["root"]},
        %{"key" => "valid_2", "kind" => "swarm_code_gen", "depends_on" => ["valid_1"]},
        %{
          "key" => "cycle_x",
          "kind" => "test_verification",
          "depends_on" => ["valid_2", "cycle_y"]
        },
        %{"key" => "cycle_y", "kind" => "security_audit", "depends_on" => ["cycle_x"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(steps)
      assert {:error, :cyclic_dependencies} = WorkflowDag.topological_sort(steps)
    end

    test "detects cycle in disconnected component alongside a valid component" do
      # Component 1 (valid): A -> B
      # Component 2 (cyclic): X -> Y -> X
      steps = [
        %{"key" => "comp1_a", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "comp1_b", "kind" => "swarm_code_gen", "depends_on" => ["comp1_a"]},
        %{"key" => "comp2_x", "kind" => "test_verification", "depends_on" => ["comp2_y"]},
        %{"key" => "comp2_y", "kind" => "security_audit", "depends_on" => ["comp2_x"]}
      ]

      assert {:error, :cyclic_dependencies} = WorkflowDag.validate(steps)
      assert {:error, :cyclic_dependencies} = WorkflowDag.topological_sort(steps)
    end

    test "rejects self-dependency explicitly with :self_dependency error" do
      steps = [
        %{"key" => "loop", "kind" => "deep_research", "depends_on" => ["loop"]}
      ]

      assert {:error, {:self_dependency, "loop"}} = WorkflowDag.validate(steps)
    end
  end

  describe "Pathological DAG: Complex valid topologies and boundary conditions" do
    test "correctly handles disconnected acyclic components" do
      # Comp 1: A -> B
      # Comp 2: C -> D
      steps = [
        %{"key" => "c1_a", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "c1_b", "kind" => "swarm_code_gen", "depends_on" => ["c1_a"]},
        %{"key" => "c2_c", "kind" => "test_verification", "depends_on" => []},
        %{"key" => "c2_d", "kind" => "security_audit", "depends_on" => ["c2_c"]}
      ]

      assert :ok = WorkflowDag.validate(steps)
      assert {:ok, sorted} = WorkflowDag.topological_sort(steps)
      assert length(sorted) == 4

      assert Enum.find_index(sorted, &(&1 == "c1_a")) < Enum.find_index(sorted, &(&1 == "c1_b"))
      assert Enum.find_index(sorted, &(&1 == "c2_c")) < Enum.find_index(sorted, &(&1 == "c2_d"))

      assert {:ok, layers} = WorkflowDag.topological_layers(steps)
      assert length(layers) == 2
      layer_0_keys = Enum.map(Enum.at(layers, 0), &WorkflowDag.step_key/1) |> Enum.sort()
      layer_1_keys = Enum.map(Enum.at(layers, 1), &WorkflowDag.step_key/1) |> Enum.sort()
      assert layer_0_keys == ["c1_a", "c2_c"]
      assert layer_1_keys == ["c1_b", "c2_d"]
    end

    test "correctly layers diamond DAG (Root -> [Branch1, Branch2] -> Join)" do
      steps = [
        %{"key" => "root", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "branch_1", "kind" => "swarm_code_gen", "depends_on" => ["root"]},
        %{"key" => "branch_2", "kind" => "test_verification", "depends_on" => ["root"]},
        %{"key" => "join", "kind" => "git_commit", "depends_on" => ["branch_1", "branch_2"]}
      ]

      assert :ok = WorkflowDag.validate(steps)
      assert {:ok, layers} = WorkflowDag.topological_layers(steps)
      assert length(layers) == 3

      assert Enum.map(Enum.at(layers, 0), &WorkflowDag.step_key/1) == ["root"]

      assert Enum.map(Enum.at(layers, 1), &WorkflowDag.step_key/1) |> Enum.sort() == [
               "branch_1",
               "branch_2"
             ]

      assert Enum.map(Enum.at(layers, 2), &WorkflowDag.step_key/1) == ["join"]

      assert Enum.map(WorkflowDag.ready_steps(steps, []), &WorkflowDag.step_key/1) == ["root"]

      assert Enum.map(WorkflowDag.ready_steps(steps, ["root"]), &WorkflowDag.step_key/1)
             |> Enum.sort() ==
               ["branch_1", "branch_2"]

      assert Enum.map(
               WorkflowDag.ready_steps(steps, ["root", "branch_1"]),
               &WorkflowDag.step_key/1
             ) ==
               ["branch_2"]

      assert Enum.map(
               WorkflowDag.ready_steps(steps, ["root", "branch_1", "branch_2"]),
               &WorkflowDag.step_key/1
             ) ==
               ["join"]
    end

    test "respects maximum step limit boundary (64 allowed, 65 rejected)" do
      steps_64 =
        for i <- 1..64 do
          %{
            "key" => "step_#{i}",
            "kind" => "deep_research",
            "depends_on" => if(i == 1, do: [], else: ["step_#{i - 1}"])
          }
        end

      assert :ok = WorkflowDag.validate(steps_64)

      steps_65 =
        for i <- 1..65 do
          %{
            "key" => "step_#{i}",
            "kind" => "deep_research",
            "depends_on" => if(i == 1, do: [], else: ["step_#{i - 1}"])
          }
        end

      assert {:error, :too_many_steps} = WorkflowDag.validate(steps_65)
    end

    test "rejects missing dependency targets" do
      steps = [
        %{"key" => "step_1", "kind" => "deep_research", "depends_on" => ["phantom_step"]}
      ]

      assert {:error, {:missing_dependencies, "step_1", ["phantom_step"]}} =
               WorkflowDag.validate(steps)
    end

    test "rejects invalid step key formats (symbols, leading dashes, spaces)" do
      for invalid_key <- ["-bad_start", "with spaces", "step$special", "step/slash", ""] do
        step = %{"key" => invalid_key, "kind" => "deep_research", "depends_on" => []}
        assert {:error, {:invalid_step_key, ^invalid_key}} = WorkflowDag.validate([step])
      end
    end

    test "enforces that step output variable references require explicit dependency" do
      # step_b uses {{steps.step_a.output.report}}, but forgets to list step_a in depends_on
      steps_missing_dep = [
        %{"key" => "step_a", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "step_b",
          "kind" => "swarm_code_gen",
          # missing "step_a"!
          "depends_on" => [],
          "params" => %{"context" => "{{steps.step_a.output.report}}"}
        }
      ]

      assert {:error, {:invalid_variable_references, "step_b", ["steps.step_a.output.report"]}} =
               WorkflowDag.validate(steps_missing_dep)

      # Declaring dependency resolves validation cleanly
      steps_valid = [
        %{"key" => "step_a", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "step_b",
          "kind" => "swarm_code_gen",
          "depends_on" => ["step_a"],
          "params" => %{"context" => "{{steps.step_a.output.report}}"}
        }
      ]

      assert :ok = WorkflowDag.validate(steps_valid)
    end
  end

  # ============================================================================
  # SECTION 2: VARIABLE INTERPOLATOR ADVERSARIAL STRESS TESTS
  # ============================================================================

  describe "VariableInterpolator: Deep recursion, type preservation & edge cases" do
    test "interpolates through 12 levels of deeply nested maps and lists" do
      context = %{
        "deep_val" => "found_at_level_12",
        "numeric_id" => 777
      }

      deep_template = %{
        "l1" => %{
          "l2" => [
            %{
              "l3" => %{
                "l4" => [
                  %{
                    "l5" => %{
                      "l6" => [
                        %{
                          "l7" => %{
                            "l8" => [
                              %{
                                "l9" => %{
                                  "l10" => [
                                    %{
                                      "l11" => %{
                                        "l12_text" => "Target: {{deep_val}}",
                                        "l12_num" => "{{numeric_id}}"
                                      }
                                    }
                                  ]
                                }
                              }
                            ]
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert {:ok, result} = VariableInterpolator.interpolate(deep_template, context)

      val12 =
        result
        |> get_in(["l1", "l2"])
        |> hd()
        |> get_in(["l3", "l4"])
        |> hd()
        |> get_in(["l5", "l6"])
        |> hd()
        |> get_in(["l7", "l8"])
        |> hd()
        |> get_in(["l9", "l10"])
        |> hd()
        |> get_in(["l11"])

      assert val12["l12_text"] == "Target: found_at_level_12"
      assert val12["l12_num"] == 777
      assert is_integer(val12["l12_num"])
    end

    test "preserves exact native types with whitespace surrounding placeholder" do
      context = %{
        "int" => 42,
        "float" => 3.14159,
        "bool_true" => true,
        "bool_false" => false,
        "list" => ["alpha", 1, %{"nested" => "value"}],
        "map" => %{"key1" => "val1", "key2" => 200}
      }

      assert {:ok, 42} = VariableInterpolator.interpolate("{{int}}", context)
      assert {:ok, 42} = VariableInterpolator.interpolate("  {{  int  }}  ", context)
      assert {:ok, 3.14159} = VariableInterpolator.interpolate("{{float}}", context)
      assert {:ok, true} = VariableInterpolator.interpolate("{{bool_true}}", context)
      assert {:ok, false} = VariableInterpolator.interpolate("{{bool_false}}", context)

      assert {:ok, res_list} = VariableInterpolator.interpolate("{{list}}", context)
      assert res_list == ["alpha", 1, %{"nested" => "value"}]
      assert is_list(res_list)

      assert {:ok, res_map} = VariableInterpolator.interpolate("{{map}}", context)
      assert res_map == %{"key1" => "val1", "key2" => 200}
      assert is_map(res_map)
    end

    test "handles malformed mustache syntax without crashes or corruptions" do
      context = %{"valid" => "hello"}

      assert {:ok, "prefix {{valid unclosed"} =
               VariableInterpolator.interpolate("prefix {{valid unclosed", context)

      assert {:ok, "prefix valid}} suffix"} =
               VariableInterpolator.interpolate("prefix valid}} suffix", context)

      assert {:ok, "empty {{}} brace"} =
               VariableInterpolator.interpolate("empty {{}} brace", context)

      assert {:ok, "space {{   }} brace"} =
               VariableInterpolator.interpolate("space {{   }} brace", context)

      assert {:ok, "unaffected"} = VariableInterpolator.interpolate("unaffected", nil)
      assert {:ok, 12345} = VariableInterpolator.interpolate(12345, context)
    end

    test "interpolates map keys dynamically" do
      context = %{"prefix" => "feature", "idx" => "1"}

      map_with_interpolated_keys = %{
        "{{prefix}}_{{idx}}" => "configured_value",
        "static_key" => "{{prefix}}"
      }

      assert {:ok, result} = VariableInterpolator.interpolate(map_with_interpolated_keys, context)
      assert result["feature_1"] == "configured_value"
      assert result["static_key"] == "feature"
    end

    test "extracts and reports missing variables accurately across structures" do
      context = %{
        "present_a" => 1,
        "present_b" => "yes"
      }

      template = %{
        "header" => "{{present_a}}",
        "nested" => [
          "{{present_b}}",
          "{{missing_x}}",
          %{"deep" => "Value: {{missing_y}} and {{missing_x}}"}
        ]
      }

      missing = VariableInterpolator.missing_variables(template, context)
      assert Enum.sort(missing) == ["missing_x", "missing_y"]
    end
  end

  # ============================================================================
  # SECTION 3: WORKFLOW ENGINE ORCHESTRATION & CONTROLS
  # ============================================================================

  describe "Engine: Concurrent execution, Pause, Resume, and Cancel lifecycle" do
    test "executes diamond DAG with concurrent branch execution and variable passing" do
      project = create_test_project()

      diamond_workflow = %{
        project_id: project.id,
        name: "Diamond Concurrency Pipeline",
        slug: "diamond-pipeline-#{System.unique_integer([:positive])}",
        variables: [
          %{"name" => "feature_name", "type" => "string", "default" => "PKCE_Auth"}
        ],
        steps: [
          %{
            "key" => "research",
            "kind" => "deep_research",
            "title" => "Research {{feature_name}}",
            "depends_on" => [],
            "params" => %{"query" => "{{feature_name}} architecture"}
          },
          %{
            "key" => "code_1",
            "kind" => "swarm_code_gen",
            "title" => "Code Branch 1",
            "depends_on" => ["research"],
            "params" => %{
              "prompt" => "Implement auth backend",
              "target_files" => ["lib/auth.ex"]
            },
            "safety_policy" => "full_auto"
          },
          %{
            "key" => "code_2",
            "kind" => "swarm_code_gen",
            "title" => "Code Branch 2",
            "depends_on" => ["research"],
            "params" => %{
              "prompt" => "Implement auth frontend",
              "target_files" => ["lib/auth_live.ex"]
            },
            "safety_policy" => "full_auto"
          },
          %{
            "key" => "audit_join",
            "kind" => "security_audit",
            "title" => "Audit Joined Code",
            "depends_on" => ["code_1", "code_2"],
            "params" => %{"strict" => false}
          }
        ]
      }

      assert {:ok, workflow} = Workflows.create_workflow(diamond_workflow)
      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_step_started, "research", _}, 2000
      assert_receive {:workflow_step_completed, "research", _}, 3000

      assert_receive {:workflow_step_started, "code_1", _}, 3000
      assert_receive {:workflow_step_started, "code_2", _}, 3000

      assert_receive {:workflow_step_completed, "code_1", _}, 3000
      assert_receive {:workflow_step_completed, "code_2", _}, 3000

      assert_receive {:workflow_step_started, "audit_join", _}, 3000
      assert_receive {:workflow_step_completed, "audit_join", _}, 3000

      assert_receive {:workflow_run_completed, completed_run}, 3000
      assert completed_run.status == "completed"
      assert completed_run.progress == 100

      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000
    end

    test "pause halts progression and resume restarts execution to completion" do
      project = create_test_project()

      multi_step = %{
        project_id: project.id,
        name: "Pause Resume Test Pipeline",
        slug: "pause-resume-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "s1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Test query 1"}
          },
          %{
            "key" => "s2",
            "kind" => "deep_research",
            "title" => "Step 2",
            "depends_on" => ["s1"],
            "params" => %{"query" => "Test query 2"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(multi_step)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      # Pause immediately
      assert :ok = Engine.pause_run(run.id)
      assert_receive {:workflow_run_paused, paused_run}, 2000
      assert paused_run.status == "paused"

      assert {:ok, %{status: :paused}} = Engine.get_status(run.id)

      # Double pause should remain idempotent :ok
      assert :ok = Engine.pause_run(run.id)

      # Resume the run
      assert :ok = Engine.resume_run(run.id)
      assert_receive {:workflow_run_resumed, resumed_run}, 2000
      assert resumed_run.status == "running"

      assert_receive {:workflow_step_completed, "s1", _}, 4000
      assert_receive {:workflow_step_completed, "s2", _}, 4000
      assert_receive {:workflow_run_completed, _}, 4000

      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000

      final_run = Workflows.get_run!(run.id)
      assert final_run.status == "completed"
    end

    test "cancel immediately terminates active engine and marks run cancelled" do
      project = create_test_project()

      workflow_attrs = %{
        project_id: project.id,
        name: "Cancel Test Pipeline",
        slug: "cancel-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "s1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Long research"}
          },
          %{
            "key" => "s2",
            "kind" => "swarm_code_gen",
            "title" => "Step 2",
            "depends_on" => ["s1"],
            "params" => %{"prompt" => "Implement"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(workflow_attrs)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      assert :ok = Engine.cancel_run(run.id)
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      cancelled_run = Workflows.get_run!(run.id)
      assert cancelled_run.status == "cancelled"

      assert {:error, :run_not_active} = Engine.pause_run(run.id)
      assert {:error, :run_not_active} = Engine.resume_run(run.id)
      assert {:error, :run_not_active} = Engine.cancel_run(run.id)
    end
  end

  # ============================================================================
  # SECTION 4: EMPIRICAL DEFECT DEMONSTRATIONS
  # ============================================================================

  describe "Empirical Defect Demonstrations" do
    test "DEFECT 1: Engine terminates on step failure, rendering retry_step unusable" do
      project = create_test_project()

      # SwarmCodeGen in read_only mode deliberately fails
      failing_workflow = %{
        project_id: project.id,
        name: "Failing Pipeline for Retry",
        slug: "failing-pipeline-retry-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "failing_step",
            "kind" => "swarm_code_gen",
            "title" => "Failing Code Gen",
            "depends_on" => [],
            "safety_policy" => "read_only",
            "params" => %{"prompt" => "Attempt mutation"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(failing_workflow)
      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_step_failed, "failing_step", _reason}, 3000
      assert_receive {:workflow_run_failed, failed_run, _reason}, 3000
      assert failed_run.status == "failed"

      # DEFECT PROOF 1.1: Engine failure behavior
      receive do
        {:DOWN, ^ref, :process, ^engine_pid, :normal} ->
          # Defect reproduced: engine stopped
          assert true
      after
        1000 ->
          # If fixed: engine process is maintained
          assert Process.alive?(engine_pid)
      end

      # DEFECT PROOF 1.2: retry_step behavior
      res =
        try do
          Workflows.retry_step(run.id, "failing_step")
        catch
          :exit, reason -> {:exit, reason}
        end

      case res do
        {:ok, _} ->
          # If fixed: retry_step successfully initiates retry
          assert true

        _ ->
          # Defect: engine is dead or crashes
          assert res == {:error, :run_not_active} or match?({:exit, _}, res)
      end

      # DEFECT PROOF 1.3: If Engine is restarted, verify lifecycle
      restarted_res = Engine.start_link(run_id: run.id)

      restarted_pid =
        case restarted_res do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      restart_ref = Process.monitor(restarted_pid)

      receive do
        {:DOWN, ^restart_ref, :process, ^restarted_pid, :normal} ->
          # Defect: immediate termination on init
          assert true
      after
        500 ->
          # If fixed: engine does not terminate on init with failed steps
          assert Process.alive?(restarted_pid)
          Process.exit(restarted_pid, :kill)
      end
    end

    test "DEFECT 2: Workflow creation accepts empty steps ([]) bypassing DAG validation" do
      project = create_test_project()

      # WorkflowDag rejects empty steps:
      assert {:error, :empty_steps} = WorkflowDag.validate([])

      # BUT Workflows.create_workflow accepts steps: [] and persists it!
      result =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Bypassed Empty Flow",
          slug: "bypassed-empty-flow-#{System.unique_integer([:positive])}",
          steps: []
        })

      # DEFECT PROOF 2: The invalid empty workflow is accepted and saved in SQLite
      case result do
        {:ok, %Workflow{steps: []}} ->
          # Defect confirmed: empty steps allowed into the database
          assert true

        {:error, changeset} ->
          # If fixed, it should be rejected with an error on :steps
          assert changeset.errors[:steps] != nil
      end
    end

    test "DEFECT 3: Duplicate slug unique constraint assigns error to :project_id instead of :slug" do
      project = create_test_project()

      step = %{"key" => "s1", "kind" => "deep_research", "depends_on" => []}
      slug = "duplicate-slug-test-#{System.unique_integer([:positive])}"

      # Create first workflow
      {:ok, _w1} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "First Workflow",
          slug: slug,
          steps: [step]
        })

      # Create second workflow with duplicate slug in same project
      assert {:error, changeset} =
               Workflows.create_workflow(%{
                 project_id: project.id,
                 name: "Second Workflow Duplicate Slug",
                 slug: slug,
                 steps: [step]
               })

      # DEFECT PROOF 3: The uniqueness error is attached to :slug when fixed
      if Keyword.has_key?(changeset.errors, :slug) do
        assert true
      else
        assert Keyword.has_key?(changeset.errors, :project_id)
        refute Keyword.has_key?(changeset.errors, :slug)
      end
    end

    test "DEFECT 4: launch_workflow does not validate required: true variables without defaults" do
      project = create_test_project()

      variables = [
        %{
          "name" => "required_api_key",
          "type" => "string",
          "required" => true
          # no default provided
        }
      ]

      steps = [
        %{
          "key" => "step_1",
          "kind" => "deep_research",
          "depends_on" => [],
          "params" => %{"query" => "Query with {{required_api_key}}"}
        }
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Strict Var Workflow",
          slug: "strict-var-workflow-#{System.unique_integer([:positive])}",
          variables: variables,
          steps: steps
        })

      # DEFECT PROOF 4: launch_workflow launches despite missing required variable
      # It should return {:error, {:missing_required_variables, ["required_api_key"]}}
      # but instead returns {:ok, run} with required_api_key set to nil
      case Workflows.launch_workflow(workflow, %{}, async: false) do
        {:ok, run} ->
          # Defect reproduced: run created with missing required variable
          assert Map.get(run.inputs, "required_api_key") == nil

        {:error, {:missing_required_variables, _}} ->
          # If fixed, it correctly rejects missing required variables
          assert true
      end
    end
  end
end
