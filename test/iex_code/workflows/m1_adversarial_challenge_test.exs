defmodule IexCode.Workflows.M1AdversarialChallengeTest do
  use IexCode.DataCase

  alias IexCode.Execution.{CommandError, CommandParser, Intent}
  alias IexCode.Projects.Project
  alias IexCode.Repo
  alias IexCode.Workflows
  alias IexCode.Workflows.{Engine, Workflow}

  defp create_test_project(name \\ "Challenge Project") do
    root = "/tmp/iex_code_m1_chal_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["config", "user.name", "Challenger"], cd: root)
    System.cmd("git", ["config", "user.email", "challenger@example.com"], cd: root)

    Repo.retry_on_busy(fn ->
      %Project{}
      |> Project.changeset(%{
        name: name,
        root_path: root,
        description: "Milestone 1 adversarial challenge test sandbox"
      })
      |> Repo.insert!()
    end)
  end

  defp valid_step(key, kind, deps \\ [], params \\ %{}, extra \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "kind" => kind,
        "title" => "Step #{key}",
        "depends_on" => deps,
        "params" => params,
        "model_config" => %{"reasoning_effort" => "none"},
        "safety_policy" => "read_only"
      },
      extra
    )
  end

  # ============================================================================
  # 1. COMMAND PARSER EDGE CASES
  # ============================================================================
  describe "1. Command Parser edge cases" do
    test "/create-workflow handles complex whitespace boundaries" do
      # 1.1 Leading and trailing spaces without objective -> objective: nil
      assert {:ok,
              %Intent{kind: :create_workflow, objective: nil, raw_command: "/create-workflow"}} =
               CommandParser.parse("   /create-workflow   ")

      # 1.2 Multi-space separator between command and objective
      assert {:ok, %Intent{kind: :create_workflow, objective: "Build oauth2 PKCE flow"}} =
               CommandParser.parse("/create-workflow       Build oauth2 PKCE flow")

      # 1.3 Leading whitespace, multiple internal spaces, trailing whitespace
      assert {:ok, %Intent{kind: :create_workflow, objective: "deploy to    production"}} =
               CommandParser.parse("   /create-workflow    deploy to    production   ")

      # 1.4 Tab characters and newlines
      assert {:ok, %Intent{kind: :create_workflow, objective: "refactor\nlogin\tcontroller"}} =
               CommandParser.parse("/create-workflow \t refactor\nlogin\tcontroller \n ")

      # 1.5 Whitespace only after command -> treated as nil objective
      assert {:ok, %Intent{kind: :create_workflow, objective: nil}} =
               CommandParser.parse("/create-workflow \t  \n  ")
    end

    test "/create-workflow arguments, options, and flag preservation" do
      # 2.1 Flags passed to /create-workflow are retained inside the objective prompt string
      assert {:ok,
              %Intent{kind: :create_workflow, objective: "--template microservice --dry-run"}} =
               CommandParser.parse("/create-workflow --template microservice --dry-run")

      # 2.2 Objective with quotes, special characters, and Unicode
      unicode_obj = "Строим 🚀 GraphQL API с 100% test coverage & schema=v2"

      assert {:ok, %Intent{kind: :create_workflow, objective: ^unicode_obj}} =
               CommandParser.parse("/create-workflow #{unicode_obj}")

      # 2.3 Objective with JSON-like structure
      json_obj = ~s({"goal": "build api", "steps": 3})

      assert {:ok, %Intent{kind: :create_workflow, objective: ^json_obj}} =
               CommandParser.parse("/create-workflow #{json_obj}")
    end

    test "/workflows strict argument rejection" do
      # 3.1 Plain /workflows alone succeeds
      assert {:ok, %Intent{kind: :navigate, objective: "workflows", mode: :navigation}} =
               CommandParser.parse("/workflows")

      # 3.2 Whitespace surrounding /workflows alone succeeds
      assert {:ok, %Intent{kind: :navigate, objective: "workflows"}} =
               CommandParser.parse("   /workflows   ")

      # 3.3 Trailing arguments are strictly rejected with :unexpected_arguments
      assert {:error, %CommandError{code: :unexpected_arguments, command: "/workflows"}} =
               CommandParser.parse("/workflows extra_arg")

      assert {:error, %CommandError{code: :unexpected_arguments, command: "/workflows"}} =
               CommandParser.parse("/workflows --all")

      assert {:error, %CommandError{code: :unexpected_arguments, command: "/workflows"}} =
               CommandParser.parse("/workflows 12345")

      assert {:error, %CommandError{code: :unexpected_arguments, command: "/workflows"}} =
               CommandParser.parse("/workflows   foo bar baz")
    end

    test "Case sensitivity and command collision prevention" do
      # 4.1 Uppercase / mixed-case commands must be rejected as unknown commands
      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/CREATE-WORKFLOW")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/Create-Workflow my objective")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/WORKFLOWS")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/Workflows")

      # 4.2 Prefix / suffix / typo collision attempts
      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/create_workflow")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/create-workflows")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/workflow")

      assert {:error, %CommandError{code: :unknown_command}} =
               CommandParser.parse("/workflows_list")
    end

    test "Extreme payloads: size boundary and invalid encoding" do
      # 5.1 Input exceeding 100,000 bytes is rejected
      large_obj = String.duplicate("a", 100_001)

      assert {:error, %CommandError{code: :input_too_large}} =
               CommandParser.parse("/create-workflow #{large_obj}")

      # 5.2 Exactly 100,000 bytes is accepted
      boundary_obj = String.duplicate("b", 100_000 - byte_size("/create-workflow "))

      assert {:ok, %Intent{kind: :create_workflow}} =
               CommandParser.parse("/create-workflow #{boundary_obj}")

      # 5.3 Non-UTF8 binary payload rejected
      invalid_utf8 = <<0xFF, 0xFE, 0xFD>>

      assert {:error, %CommandError{code: :invalid_encoding}} =
               CommandParser.parse(invalid_utf8)
    end
  end

  # ============================================================================
  # 2. WORKFLOWS CONTEXT & VALIDATION
  # ============================================================================
  describe "2. Workflows Context & Validation" do
    test "Duplicate slug enforcement per-project vs cross-project isolation" do
      p1 = create_test_project("Project Alpha")
      p2 = create_test_project("Project Beta")

      steps = [
        valid_step("s1", "deep_research", [], %{"query" => "Test"})
      ]

      # 2.1 First workflow in Project 1 succeeds
      assert {:ok, %Workflow{} = w1} =
               Workflows.create_workflow(%{
                 project_id: p1.id,
                 name: "Autonomous Pipeline",
                 slug: "autonomous-pipeline",
                 steps: steps
               })

      assert w1.slug == "autonomous-pipeline"

      # 2.2 Second workflow in Project 1 with exact same slug MUST fail with uniqueness error
      # Defect Finding: Currently unique_constraint([:project_id, :slug]) puts error on project_id instead of slug!
      assert {:error, changeset} =
               Workflows.create_workflow(%{
                 project_id: p1.id,
                 name: "Autonomous Pipeline Duplicate",
                 slug: "autonomous-pipeline",
                 steps: steps
               })

      # Contract expectation: error belongs on :slug, not foreign key :project_id
      assert "has already been taken" in errors_on(changeset).slug

      # 2.3 Auto-generated slug collision in Project 1
      assert {:error, changeset_auto} =
               Workflows.create_workflow(%{
                 project_id: p1.id,
                 name: "Autonomous Pipeline",
                 steps: steps
               })

      assert "has already been taken" in errors_on(changeset_auto).slug

      # 2.4 Same slug in a DIFFERENT project (Project 2) MUST succeed (cross-project isolation)
      assert {:ok, %Workflow{} = w2} =
               Workflows.create_workflow(%{
                 project_id: p2.id,
                 name: "Autonomous Pipeline",
                 slug: "autonomous-pipeline",
                 steps: steps
               })

      assert w2.project_id == p2.id
      assert w2.slug == "autonomous-pipeline"
      assert w2.id != w1.id
    end

    test "Empty steps, invalid step types, and invalid step structure rejection" do
      p = create_test_project()

      # 2.5 Empty steps list rejected
      # Defect Finding: Schema default `steps: []` causes Ecto to bypass validate_change(:steps) on empty list!
      assert {:error, cs_empty} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Empty Steps Flow",
                 steps: []
               })

      assert cs_empty.errors[:steps] != nil

      # 2.6 Nil steps rejected
      assert {:error, cs_nil} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Nil Steps Flow",
                 steps: nil
               })

      assert cs_nil.errors[:steps] != nil

      # 2.7 Unsupported step kind rejected
      assert {:error, cs_kind} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Unsupported Kind Flow",
                 steps: [
                   %{
                     "key" => "step_bad",
                     "kind" => "unsupported_kind_foo_bar",
                     "title" => "Bad Kind",
                     "depends_on" => []
                   }
                 ]
               })

      assert cs_kind.errors[:steps] != nil
      {msg, _} = cs_kind.errors[:steps]
      assert msg =~ "unsupported_kind"

      # 2.8 Invalid step key format (spaces, special characters, empty)
      assert {:error, cs_bad_key} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Bad Key Flow",
                 steps: [
                   %{
                     "key" => "step with spaces!",
                     "kind" => "deep_research",
                     "depends_on" => []
                   }
                 ]
               })

      assert cs_bad_key.errors[:steps] != nil

      # 2.9 Duplicate step keys in same workflow
      assert {:error, cs_dup_keys} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Duplicate Step Keys Flow",
                 steps: [
                   valid_step("dup_key", "deep_research"),
                   valid_step("dup_key", "security_audit")
                 ]
               })

      assert cs_dup_keys.errors[:steps] != nil
      {msg, _} = cs_dup_keys.errors[:steps]
      assert msg =~ "duplicate_step_keys"
    end

    test "Missing variable references and undeclared step dependencies" do
      p = create_test_project()

      # 2.10 Step references variable that is NOT declared in workflow variables
      step_with_missing_var =
        valid_step("research", "deep_research", [], %{
          "query" => "Deep research on {{undeclared_target_feature}}"
        })

      assert {:error, cs_missing_var} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Undeclared Var Flow",
                 variables: [],
                 steps: [step_with_missing_var]
               })

      assert cs_missing_var.errors[:steps] != nil
      {msg, _} = cs_missing_var.errors[:steps]
      assert msg =~ "invalid_variable_references"
      assert msg =~ "undeclared_target_feature"

      # 2.11 Step references upstream output {{steps.upstream.output.report}}
      # but fails to declare "upstream" in its depends_on
      step_upstream = valid_step("upstream", "deep_research")

      step_downstream_no_dep =
        valid_step(
          "downstream",
          "swarm_code_gen",
          [],
          # depends_on is empty!
          %{"context" => "{{steps.upstream.output.report}}"}
        )

      assert {:error, cs_no_dep} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Missing Upstream Dep Flow",
                 steps: [step_upstream, step_downstream_no_dep]
               })

      assert cs_no_dep.errors[:steps] != nil
      {msg, _} = cs_no_dep.errors[:steps]
      assert msg =~ "invalid_variable_references"

      # 2.12 Correctly declaring depends_on: ["upstream"] succeeds
      step_downstream_with_dep =
        valid_step(
          "downstream",
          "swarm_code_gen",
          ["upstream"],
          %{"context" => "{{steps.upstream.output.report}}"}
        )

      assert {:ok, %Workflow{}} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Valid Upstream Dep Flow",
                 steps: [step_upstream, step_downstream_with_dep]
               })
    end

    test "DAG cycle detection and self-dependency rejection" do
      p = create_test_project()

      # 2.13 Self dependency A -> A
      self_dep = [
        valid_step("A", "deep_research", ["A"])
      ]

      assert {:error, cs_self} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Self Dep Flow",
                 steps: self_dep
               })

      assert cs_self.errors[:steps] != nil

      # 2.14 Indirect 3-node cycle: A -> B -> C -> A
      cycle_steps = [
        valid_step("A", "deep_research", ["C"]),
        valid_step("B", "swarm_code_gen", ["A"]),
        valid_step("C", "test_verification", ["B"])
      ]

      assert {:error, cs_cycle} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Cycle Flow",
                 steps: cycle_steps
               })

      assert cs_cycle.errors[:steps] != nil
      {msg, _} = cs_cycle.errors[:steps]
      assert msg =~ "cyclic_dependencies"
    end

    test "Model configuration and safety policy validation" do
      p = create_test_project()

      # 2.15 Invalid reasoning effort
      bad_reasoning_step =
        valid_step(
          "r1",
          "deep_research",
          [],
          %{},
          %{"model_config" => %{"reasoning_effort" => "ultra_extreme"}}
        )

      assert {:error, cs_reasoning} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Bad Reasoning Flow",
                 steps: [bad_reasoning_step]
               })

      assert cs_reasoning.errors[:steps] != nil
      {msg, _} = cs_reasoning.errors[:steps]
      assert msg =~ "invalid_reasoning_effort"

      # 2.16 Invalid safety policy
      bad_safety_step =
        valid_step(
          "s1",
          "git_commit",
          [],
          %{},
          %{"safety_policy" => "dangerous_unrestricted"}
        )

      assert {:error, cs_safety} =
               Workflows.create_workflow(%{
                 project_id: p.id,
                 name: "Bad Safety Flow",
                 steps: [bad_safety_step]
               })

      assert cs_safety.errors[:steps] != nil
      {msg, _} = cs_safety.errors[:steps]
      assert msg =~ "invalid_safety_policy"
    end

    test "launch_workflow/3 input variable resolution and default fallbacks" do
      p = create_test_project()

      variables = [
        %{
          "name" => "target_module",
          "type" => "string",
          "default" => "Accounts",
          "required" => true
        },
        %{
          "name" => "max_retries",
          "type" => "integer",
          "default" => 3,
          "required" => false
        }
      ]

      steps = [
        valid_step("research", "deep_research", [], %{
          "query" => "Architecture for {{target_module}} (retries={{max_retries}})"
        })
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: p.id,
          name: "Parametrized Workflow",
          variables: variables,
          steps: steps
        })

      # 2.17 Launch with empty inputs: falls back to defaults
      assert {:ok, run1} = Workflows.launch_workflow(workflow, %{}, async: false)
      assert run1.inputs["target_module"] == "Accounts"
      assert run1.inputs["max_retries"] == 3

      # Check interpolated step in run1.resolved_steps
      [res_step1] = run1.resolved_steps
      assert res_step1["params"]["query"] == "Architecture for Accounts (retries=3)"

      # 2.18 Launch with custom overrides
      assert {:ok, run2} =
               Workflows.launch_workflow(
                 workflow,
                 %{"target_module" => "Billing", "max_retries" => 5},
                 async: false
               )

      assert run2.inputs["target_module"] == "Billing"
      assert run2.inputs["max_retries"] == 5

      [res_step2] = run2.resolved_steps
      assert res_step2["params"]["query"] == "Architecture for Billing (retries=5)"
    end
  end

  # ============================================================================
  # 3. ENGINE FAILURE HANDLING & ERROR STATE RECORDING
  # ============================================================================
  describe "3. Engine failure handling and error state recording" do
    test "Step failure halts downstream execution and records comprehensive error state" do
      p = create_test_project()

      # Workflow:
      # Step 1: deep_research (succeeds)
      # Step 2: security_audit (fails: strict: true with simulated leaked secret in diff)
      # Step 3: git_commit (depends on Step 2 -> must NOT execute)
      steps = [
        valid_step("step_1_research", "deep_research", [], %{"query" => "OTP spec"}),
        valid_step(
          "step_2_audit_strict",
          "security_audit",
          ["step_1_research"],
          %{
            "diff" => "api_key = \"sk-12345678901234567890123456789012\"",
            "strict" => true
          }
        ),
        valid_step(
          "step_3_commit",
          "git_commit",
          ["step_2_audit_strict"],
          %{"commit_message" => "chore: won't run"},
          %{"safety_policy" => "prompt_dangerous"}
        )
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: p.id,
          name: "Strict Audit Failure Pipeline",
          steps: steps
        })

      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      # Subscribe to run PubSub events
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start Engine
      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      # 3.1 Step 1 executes and completes
      assert_receive {:workflow_step_started, "step_1_research", _}, 3000
      assert_receive {:workflow_step_completed, "step_1_research", _}, 3000

      # 3.2 Step 2 executes and fails due to strict audit secret detection
      assert_receive {:workflow_step_started, "step_2_audit_strict", _}, 3000
      assert_receive {:workflow_step_failed, "step_2_audit_strict", err_msg}, 3000
      assert is_binary(err_msg)

      # 3.3 Overall run fails and broadcasts failure
      assert_receive {:workflow_run_failed, failed_run, _reason}, 3000
      assert failed_run.status == "failed"

      # 3.4 Engine process exits normally after terminal failure
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000

      # 3.5 Step 3 MUST NEVER have started
      refute_received {:workflow_step_started, "step_3_commit", _}

      # 3.6 Inspect database record for exact error state recording
      persisted_run = Workflows.get_run!(run.id)
      assert persisted_run.status == "failed"
      assert is_binary(persisted_run.error_message)
      assert persisted_run.error_message =~ "step_2_audit_strict"

      # Verify step_states map
      step_states = persisted_run.step_states
      assert step_states["step_1_research"]["status"] == "completed"
      assert step_states["step_1_research"]["duration_ms"] >= 0

      assert step_states["step_2_audit_strict"]["status"] == "failed"
      assert is_binary(step_states["step_2_audit_strict"]["error"])
      assert is_binary(step_states["step_2_audit_strict"]["failed_at"])
      assert step_states["step_2_audit_strict"]["duration_ms"] >= 0

      # Step 3 remains pending
      assert step_states["step_3_commit"]["status"] == "pending"
    end

    test "Safety policy violation halts execution with explicit error" do
      p = create_test_project()

      # SwarmCodeGen in read_only mode violates safety policy when asked to mutate files
      steps = [
        valid_step(
          "mutate_code",
          "swarm_code_gen",
          [],
          %{"prompt" => "Write authentication module", "target_files" => ["lib/auth.ex"]},
          %{"safety_policy" => "read_only"}
        )
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: p.id,
          name: "Safety Policy Failure Pipeline",
          steps: steps
        })

      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_step_started, "mutate_code", _}, 2000
      assert_receive {:workflow_step_failed, "mutate_code", err_msg}, 2000
      assert err_msg =~ "read_only"

      assert_receive {:workflow_run_failed, _failed_run, _}, 2000
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      persisted = Workflows.get_run!(run.id)
      assert persisted.status == "failed"
      assert persisted.step_states["mutate_code"]["status"] == "failed"
      assert persisted.step_states["mutate_code"]["error"] =~ "read_only"
    end

    test "Interactive retry_step behavior after run failure" do
      p = create_test_project()

      # Step 1 fails on strict audit
      steps = [
        valid_step(
          "audit_step",
          "security_audit",
          [],
          %{
            "diff" => "def secret, do: \"sk-12345678901234567890123456789012\"",
            "strict" => true
          }
        )
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: p.id,
          name: "Retryable Flow",
          steps: steps
        })

      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      # Start Engine
      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      # Wait for engine to terminate on step failure
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000

      failed_run = Workflows.get_run!(run.id)
      assert failed_run.status == "failed"

      # Defect Finding:
      # Because Engine GenServer terminates when a run fails (map_size(active_tasks) == 0 -> {:stop, :normal}),
      # calling Workflows.retry_step/2 returns {:error, :run_not_active} instead of reviving the run!
      # And restarting Engine immediately re-terminates in execute_next_layer because failed_keys != [].
      assert {:ok, _} = Workflows.retry_step(run.id, "audit_step")

      if pid = Engine.whereis_run(run.id) do
        retry_ref = Process.monitor(pid)
        assert_receive {:DOWN, ^retry_ref, :process, ^pid, :normal}, 3000
      end
    end

    test "Multi-branch execution failure isolation" do
      p = create_test_project()

      # Branching workflow:
      # root (succeeds)
      # ├── branch_fail (security audit with leak, strict: true)
      # └── branch_pass (deep research, succeeds)
      # └── join (depends on branch_fail, branch_pass)
      steps = [
        valid_step("root", "deep_research", [], %{"query" => "root"}),
        valid_step(
          "branch_fail",
          "security_audit",
          ["root"],
          %{
            "diff" => "token = \"sk-12345678901234567890123456789012\"",
            "strict" => true
          }
        ),
        valid_step("branch_pass", "deep_research", ["root"], %{"query" => "branch"}),
        valid_step("join", "git_commit", ["branch_fail", "branch_pass"], %{}, %{
          "safety_policy" => "prompt_dangerous"
        })
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: p.id,
          name: "Branch Failure Flow",
          steps: steps
        })

      assert {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      # Root completes
      assert_receive {:workflow_step_completed, "root", _}, 3000

      # Both branches are launched in parallel
      assert_receive {:workflow_step_started, "branch_fail", _}, 3000
      assert_receive {:workflow_step_started, "branch_pass", _}, 3000

      # branch_pass completes
      assert_receive {:workflow_step_completed, "branch_pass", _}, 3000

      # branch_fail fails
      assert_receive {:workflow_step_failed, "branch_fail", _}, 3000

      # Run finishes as failed
      assert_receive {:workflow_run_failed, _failed_run, _}, 3000
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000

      # Join step was blocked and never started
      refute_received {:workflow_step_started, "join", _}

      final_run = Workflows.get_run!(run.id)
      assert final_run.status == "failed"
      assert final_run.step_states["root"]["status"] == "completed"
      assert final_run.step_states["branch_pass"]["status"] == "completed"
      assert final_run.step_states["branch_fail"]["status"] == "failed"
      assert final_run.step_states["join"]["status"] == "pending"
    end
  end
end
