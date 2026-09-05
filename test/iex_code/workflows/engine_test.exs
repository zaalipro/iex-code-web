defmodule IexCode.Workflows.EngineTest do
  use IexCode.DataCase

  alias IexCode.Projects.Project
  alias IexCode.Workflows
  alias IexCode.Workflows.Engine
  alias IexCode.Workflows.WorkflowRun

  alias IexCode.Workflows.Steps.{
    DeepResearch,
    Dispatcher,
    GitCommit,
    SecurityAudit,
    SwarmCodeGen,
    TestVerification
  }

  defp create_test_project do
    root =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          "iex_code_workflow_test_#{System.unique_integer([:positive])}_#{System.monotonic_time()}"
        )
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    System.cmd("git", ["init", "-b", "main"], cd: root)
    System.cmd("git", ["config", "user.name", "Test User"], cd: root)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)

    %Project{}
    |> Project.changeset(%{
      name: "Workflow Engine Test",
      root_path: root,
      description: "Testing workflow engine"
    })
    |> Repo.insert!()
  end

  defp sample_workflow_attrs(project_id) do
    %{
      project_id: project_id,
      name: "Full 5 Step Pipeline",
      slug: "full-5-step-pipeline-#{System.unique_integer([:positive])}",
      variables: [
        %{"name" => "feature_name", "type" => "string", "default" => "Authentication"}
      ],
      steps: [
        %{
          "key" => "research",
          "kind" => "deep_research",
          "title" => "Research {{feature_name}}",
          "depends_on" => [],
          "params" => %{"query" => "{{feature_name}} OTP architecture"},
          "model_config" => %{"reasoning_effort" => "high"},
          "safety_policy" => "read_only"
        },
        %{
          "key" => "code_gen",
          "kind" => "swarm_code_gen",
          "title" => "Implement {{feature_name}}",
          "depends_on" => ["research"],
          "params" => %{
            "prompt" => "Implement {{feature_name}} based on research",
            "context_summary" => "{{steps.research.output.report}}"
          },
          "model_config" => %{"reasoning_effort" => "medium"},
          "safety_policy" => "full_auto"
        },
        %{
          "key" => "audit",
          "kind" => "security_audit",
          "title" => "Audit Security",
          "depends_on" => ["code_gen"],
          "params" => %{"strict" => false},
          "model_config" => %{"reasoning_effort" => "high"},
          "safety_policy" => "read_only"
        }
      ]
    }
  end

  describe "individual step handlers execution" do
    test "DeepResearch executes and returns structured report and citations" do
      step = %{
        "key" => "r1",
        "kind" => "deep_research",
        "title" => "Research Auth",
        "params" => %{"query" => "Elixir supervision trees", "level" => "high"}
      }

      assert {:ok, output} = DeepResearch.execute(step, %{})
      assert output["status"] == "completed"
      assert is_binary(output["report"])
      assert output["report"] =~ "Deep Research Report"
      assert is_list(output["findings"])
      assert length(output["findings"]) > 0
      assert is_list(output["citations"])
      assert output["sources_count"] > 0
    end

    test "SwarmCodeGen generates code patches and enforces read_only safety policy" do
      step = %{
        "key" => "c1",
        "kind" => "swarm_code_gen",
        "title" => "Implement Auth",
        "params" => %{"prompt" => "Build Auth module", "target_files" => ["lib/auth.ex"]},
        "safety_policy" => "full_auto"
      }

      assert {:ok, output} = SwarmCodeGen.execute(step, %{})
      assert output["status"] == "completed"
      assert output["modified_files"] == ["lib/auth.ex"]
      assert is_list(output["patches"])

      # Test safety policy rejection in read_only mode
      read_only_step = Map.put(step, "safety_policy", "read_only")
      assert {:error, msg} = SwarmCodeGen.execute(read_only_step, %{})
      assert msg =~ "read_only"
    end

    test "SecurityAudit scans diffs and flags critical secret patterns" do
      clean_step = %{
        "key" => "s1",
        "kind" => "security_audit",
        "title" => "Security Audit",
        "params" => %{"diff" => "def hello, do: :world"}
      }

      assert {:ok, clean_output} = SecurityAudit.execute(clean_step, %{})
      assert clean_output["verdict"] == "approved"
      assert clean_output["risk_score"] == 0
      assert clean_output["violations"] == []

      # Test secret detection
      leaky_step = %{
        "key" => "s2",
        "kind" => "security_audit",
        "title" => "Security Audit Leaky",
        "params" => %{"diff" => "api_key = \"sk-12345678901234567890123456789012\""}
      }

      assert {:ok, leaky_output} = SecurityAudit.execute(leaky_step, %{})
      assert leaky_output["verdict"] == "flagged"
      assert leaky_output["risk_score"] >= 30
      assert length(leaky_output["violations"]) > 0
    end

    test "TestVerification executes test runner and parses diagnostics" do
      step = %{
        "key" => "t1",
        "kind" => "test_verification",
        "title" => "Run Tests",
        "params" => %{
          "test_command" => "mix test test/iex_code/execution/command_parser_workflow_test.exs"
        }
      }

      assert {:ok, output} = TestVerification.execute(step, %{})
      assert output["verdict"] == "passed"
      assert output["total"] >= 1
      assert output["failed"] == 0
    end

    test "GitCommit stages and commits or handles clean working tree gracefully" do
      tmp_repo =
        Path.expand(
          Path.join(
            System.tmp_dir!(),
            "test_git_repo_#{System.unique_integer([:positive])}_#{System.monotonic_time()}"
          )
        )

      File.mkdir_p!(tmp_repo)
      on_exit(fn -> File.rm_rf(tmp_repo) end)

      System.cmd("git", ["init", "-b", "main"], cd: tmp_repo)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_repo)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_repo)

      sample_file = Path.join(tmp_repo, "sample.txt")
      File.write!(sample_file, "hello world", [:sync])

      step = %{
        "key" => "g1",
        "kind" => "git_commit",
        "title" => "Commit Step",
        "params" => %{"commit_message" => "chore: test commit"},
        "safety_policy" => "prompt_dangerous"
      }

      assert {:ok, output} = GitCommit.execute(step, %{repo_dir: tmp_repo})
      assert output["status"] == "committed"
      assert is_binary(output["commit_sha"])

      # Test clean status when nothing to commit
      assert {:ok, clean_output} = GitCommit.execute(step, %{repo_dir: tmp_repo})
      assert clean_output["status"] == "nothing_to_commit"
      assert clean_output["commit_sha"] == "clean"

      # Test safety policy rejection in read_only mode
      read_only_step = Map.put(step, "safety_policy", "read_only")
      assert {:error, msg} = GitCommit.execute(read_only_step, %{repo_dir: tmp_repo})
      assert msg =~ "read_only"
    end

    test "Dispatcher routes steps to registered handlers" do
      step = %{
        "key" => "r1",
        "kind" => "deep_research",
        "title" => "Research OTP",
        "params" => %{"query" => "Elixir OTP"}
      }

      assert {:ok, output} = Dispatcher.dispatch(step, %{})
      assert output["status"] == "completed"

      # Unknown handler
      assert {:error, {:unknown_step_kind, "invalid_kind"}} =
               Dispatcher.dispatch(%{"kind" => "invalid_kind"}, %{})
    end
  end

  describe "Engine workflow run orchestration" do
    test "fails closed when a persisted running step has no live task after restart" do
      project = create_test_project()

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Restarted Pipeline",
          slug: "restarted-pipeline-#{System.unique_integer([:positive])}",
          steps: [
            %{
              "key" => "effect",
              "kind" => "deep_research",
              "title" => "External effect",
              "depends_on" => [],
              "params" => %{"query" => "durable workflows"}
            }
          ]
        })

      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      run
      |> WorkflowRun.changeset(%{
        status: "running",
        current_step_key: "effect",
        step_states: %{"effect" => %{"status" => "running"}}
      })
      |> Repo.update!()

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      engine_pid = start_supervised!({Engine, run_id: run.id})
      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_run_failed, failed_run, reason}, 2_000
      assert reason =~ "interrupted while step(s) were in flight"
      assert failed_run.step_states["effect"]["status"] == "failed"
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2_000

      persisted = Workflows.get_run!(run.id)
      assert persisted.status == "failed"
      assert persisted.step_states["effect"]["status"] == "failed"
    end

    test "fails the run when an untrappable step task exit produces no result" do
      project = create_test_project()

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Killed Step Pipeline",
          slug: "killed-step-pipeline-#{System.unique_integer([:positive])}",
          steps: [
            %{
              "key" => "effect",
              "kind" => "deep_research",
              "title" => "External effect",
              "depends_on" => [],
              "params" => %{"query" => "durable workflows", "delay_ms" => 30_000}
            }
          ]
        })

      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      engine_pid = start_supervised!({Engine, run_id: run.id})
      engine_ref = Process.monitor(engine_pid)

      assert_receive {:workflow_step_started, "effect", _step}, 2_000
      %{active_tasks: %{"effect" => task_pid}} = :sys.get_state(engine_pid)
      Process.exit(task_pid, :kill)

      assert_receive {:workflow_step_failed, "effect", reason}, 2_000
      assert reason =~ "killed"
      assert_receive {:DOWN, ^engine_ref, :process, ^engine_pid, :normal}, 2_000

      persisted = Workflows.get_run!(run.id)
      assert persisted.status == "failed"
      assert persisted.step_states["effect"]["status"] == "failed"
    end

    test "terminates supervised step tasks when the engine is killed" do
      project = create_test_project()

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Engine Lifetime Pipeline",
          slug: "engine-lifetime-pipeline-#{System.unique_integer([:positive])}",
          steps: [
            %{
              "key" => "effect",
              "kind" => "deep_research",
              "title" => "External effect",
              "depends_on" => [],
              "params" => %{"query" => "durable workflows", "delay_ms" => 30_000}
            }
          ]
        })

      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      engine_pid = start_supervised!({Engine, run_id: run.id})
      assert_receive {:workflow_step_started, "effect", _step}, 2_000

      %{active_tasks: %{"effect" => task_pid}} = :sys.get_state(engine_pid)
      task_ref = Process.monitor(task_pid)
      Process.exit(engine_pid, :kill)

      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 2_000
      assert_receive {:workflow_run_failed, failed_run, reason}, 2_000
      assert reason =~ "interrupted while step(s) were in flight"
      assert failed_run.step_states["effect"]["status"] == "failed"
      assert Workflows.get_run!(run.id).status == "failed"
    end

    test "launches workflow, advances topologically, pipes variables, and broadcasts PubSub" do
      project = create_test_project()
      {:ok, workflow} = Workflows.create_workflow(sample_workflow_attrs(project.id))

      # Launch workflow synchronously in test without background supervisor
      assert {:ok, run} =
               Workflows.launch_workflow(workflow, %{"feature_name" => "UserAuth"}, async: false)

      # Subscribe to PubSub topic for this run
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start Engine directly
      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      # Assert on lifecycle broadcasts
      assert_receive {:workflow_run_started, _run}, 2000
      assert_receive {:workflow_step_started, "research", _step}, 2000
      assert_receive {:workflow_step_completed, "research", _output}, 3000

      # Step 2: code_gen should now receive the report piped from research step
      assert_receive {:workflow_step_started, "code_gen", _step}, 3000
      assert_receive {:workflow_step_completed, "code_gen", _output}, 3000

      # Step 3: audit
      assert_receive {:workflow_step_started, "audit", _step}, 3000
      assert_receive {:workflow_step_completed, "audit", _output}, 3000

      # Workflow run completed
      assert_receive {:workflow_run_completed, completed_run}, 3000
      assert completed_run.status == "completed"
      assert completed_run.progress == 100

      # Verify engine terminated normally after completion
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 3000

      # Verify DB record is persisted with completed states
      final_run = Workflows.get_run!(run.id)
      assert final_run.status == "completed"
      assert final_run.progress == 100
      assert Map.get(final_run.step_states["research"], "status") == "completed"
      assert Map.get(final_run.step_states["code_gen"], "status") == "completed"
      assert Map.get(final_run.step_states["audit"], "status") == "completed"
    end

    test "supports pause, resume, and cancel controls" do
      project = create_test_project()

      multi_step_workflow = %{
        project_id: project.id,
        name: "Controllable Pipeline",
        slug: "controllable-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          },
          %{
            "key" => "step_2",
            "kind" => "deep_research",
            "title" => "Step 2",
            "depends_on" => ["step_1"],
            "params" => %{"query" => "Query 2"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(multi_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)

      # Pause run
      assert :ok = Engine.pause_run(run.id)
      assert_receive {:workflow_run_paused, _paused_run}, 2000

      # Resume run
      assert :ok = Engine.resume_run(run.id)
      assert_receive {:workflow_run_resumed, _resumed_run}, 2000

      # Cancel run
      ref = Process.monitor(engine_pid)
      assert :ok = Engine.cancel_run(run.id)
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      cancelled_run = Workflows.get_run!(run.id)
      assert cancelled_run.status == "cancelled"
    end

    test "gracefully aborts workflow run when critical memory pressure persists beyond threshold" do
      project = create_test_project()

      single_step_workflow = %{
        project_id: project.id,
        name: "Memory Pressure Pipeline",
        slug: "mem-pressure-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(single_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start Engine with simulated persistent critical memory pressure
      {:ok, engine_pid} =
        Engine.start_link(
          run_id: run.id,
          memory_checker: fn -> true end,
          max_pressure_backoffs: 2,
          pressure_backoff_interval_ms: 10
        )

      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_run_started, _started_run}, 2000

      assert_receive {:workflow_run_failed, failed_run,
                      "Workflow run aborted: critical memory pressure persisted for >120s"},
                     2000

      assert failed_run.status == "failed"
      assert failed_run.error_message =~ "critical memory pressure persisted for >120s"

      # Engine shuts down gracefully with :normal exit
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      # DB record reflects failed status and explicit abort reason
      db_run = Workflows.get_run!(run.id)
      assert db_run.status == "failed"
      assert db_run.completed_at != nil
      assert db_run.step_states["step_1"]["status"] == "pending"

      assert db_run.error_message ==
               "Workflow run aborted: critical memory pressure persisted for >120s"
    end

    test "recovers and executes workflow steps when memory pressure subsides before threshold" do
      project = create_test_project()

      single_step_workflow = %{
        project_id: project.id,
        name: "Recovering Pipeline",
        slug: "recovering-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(single_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start with counter: first check is true, second check is false (cleared)
      agent = start_supervised!({Agent, fn -> 1 end})

      pressure_checker = fn ->
        Agent.get_and_update(agent, fn count ->
          {count > 0, count - 1}
        end)
      end

      {:ok, engine_pid} =
        Engine.start_link(
          run_id: run.id,
          memory_checker: pressure_checker,
          max_pressure_backoffs: 5,
          pressure_backoff_interval_ms: 10
        )

      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_run_started, _started_run}, 2000
      assert_receive {:workflow_step_started, "step_1", _step}, 2000
      assert_receive {:workflow_step_completed, "step_1", _output}, 3000
      assert_receive {:workflow_run_completed, completed_run}, 3000

      assert completed_run.status == "completed"
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      db_run = Workflows.get_run!(run.id)
      assert db_run.status == "completed"
    end

    test "tolerates exceptions in memory_checker without crashing engine and proceeds" do
      project = create_test_project()

      single_step_workflow = %{
        project_id: project.id,
        name: "Resilient Pipeline",
        slug: "resilient-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(single_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Memory checker raises an unhandled error
      faulty_checker = fn -> raise "Simulated memory subsystem failure" end

      {:ok, engine_pid} =
        Engine.start_link(
          run_id: run.id,
          memory_checker: faulty_checker,
          max_pressure_backoffs: 3,
          pressure_backoff_interval_ms: 10
        )

      ref = Process.monitor(engine_pid)

      # Engine survives the checker exception and proceeds to execute step
      assert_receive {:workflow_run_started, _started_run}, 2000
      assert_receive {:workflow_step_started, "step_1", _step}, 2000
      assert_receive {:workflow_step_completed, "step_1", _output}, 3000
      assert_receive {:workflow_run_completed, completed_run}, 3000

      assert completed_run.status == "completed"
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000
    end

    test "resets pressure backoff count when run is resumed" do
      project = create_test_project()

      single_step_workflow = %{
        project_id: project.id,
        name: "Backoff Reset Pipeline",
        slug: "backoff-reset-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(single_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      engine_pid =
        start_supervised!(
          {Engine,
           run_id: run.id,
           memory_checker: fn -> true end,
           max_pressure_backoffs: 10,
           pressure_backoff_interval_ms: 60_000}
        )

      # Drive checks through the mailbox; automatic retries stay outside the test window.
      send(engine_pid, :execute_next_layer)
      send(engine_pid, :execute_next_layer)
      {:ok, status} = Engine.get_status(run.id)
      assert status.pressure_backoff_count >= 2

      # Pause and resume
      assert :ok = Engine.pause_run(run.id)
      assert :ok = Engine.resume_run(run.id)

      {:ok, status_after} = Engine.get_status(run.id)
      # Resume schedules exactly one immediate pressure check after resetting.
      assert status_after.pressure_backoff_count == 1
    end

    test "step failure updates pending steps to failed and marks completed_at timestamp" do
      project = create_test_project()

      failing_step_workflow = %{
        project_id: project.id,
        name: "Failing Pipeline",
        slug: "failing-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "git_commit",
            "title" => "Will Fail",
            "depends_on" => [],
            "params" => %{"commit_message" => "test"},
            "safety_policy" => "read_only"
          },
          %{
            "key" => "step_2",
            "kind" => "deep_research",
            "title" => "Should Be Aborted",
            "depends_on" => ["step_1"],
            "params" => %{}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(failing_step_workflow)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      assert_receive {:workflow_run_started, _started_run}, 2000
      assert_receive {:workflow_step_failed, "step_1", _err}, 3000
      assert_receive {:workflow_run_failed, failed_run, _reason}, 3000
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000

      assert failed_run.status == "failed"

      db_run = Workflows.get_run!(run.id)
      assert db_run.status == "failed"
      assert db_run.completed_at != nil
      assert db_run.step_states["step_1"]["status"] == "failed"
      assert db_run.step_states["step_2"]["status"] == "pending"
    end

    test "Workflows.launch_workflow forwards engine options to Engine.start_run" do
      project = create_test_project()

      single_step_workflow = %{
        project_id: project.id,
        name: "Opts Forwarding Pipeline",
        slug: "opts-forward-pipeline-#{System.unique_integer([:positive])}",
        steps: [
          %{
            "key" => "step_1",
            "kind" => "deep_research",
            "title" => "Step 1",
            "depends_on" => [],
            "params" => %{"query" => "Query 1"}
          }
        ]
      }

      {:ok, workflow} = Workflows.create_workflow(single_step_workflow)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{workflow.id}")

      # Launch workflow with custom max_pressure_backoffs and interval via async Engine.start_run
      {:ok, run} =
        Workflows.launch_workflow(workflow, %{},
          async: true,
          memory_checker: fn -> true end,
          max_pressure_backoffs: 2,
          pressure_backoff_interval_ms: 10
        )

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      assert_receive {:workflow_run_failed, _failed_run,
                      "Workflow run aborted: critical memory pressure persisted for >120s"},
                     2000

      db_run = Workflows.get_run!(run.id)
      assert db_run.status == "failed"
      assert db_run.completed_at != nil
    end
  end
end
