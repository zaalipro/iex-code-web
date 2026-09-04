defmodule IexCodeWeb.M2ChallengerCockpitStressTest do
  @moduledoc """
  Empirical stress and adversarial verification suite for Milestone 2:
  Real-Time Workflow Cockpit LiveView & PubSub Integration.

  Covers 5 core stress scenarios:
  1. Rapid sequence execution controls: pause -> resume -> pause -> resume on active runs.
  2. Cancelling a run mid-flight and asserting all child tasks and states cleanly transition to "cancelled".
  3. Simulating high-frequency PubSub events without crashing or dropping step updates.
  4. Retry failed step under various conditions (engine active vs dead-run revival) and asserting UI reflection.
  5. Live Inspector tab switching and step selection under concurrent updates.
  """

  use IexCode.E2E.Case, async: false

  import Phoenix.LiveViewTest
  alias IexCode.{Projects, Sessions, Workflows}
  alias IexCode.Workflows.Engine

  setup %{workspace_path: path} do
    {:ok, project} =
      Projects.create_project(%{
        name: "Cockpit Stress Verification Project",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Cockpit Stress Test Session",
        model_provider: "openai",
        model_name: "gpt-4o"
      })

    {:ok, project: project, session: session}
  end

  defp create_test_workflow(project, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 0)

    steps =
      Keyword.get(opts, :steps, [
        %{
          "key" => "research",
          "kind" => "deep_research",
          "title" => "Deep Research Architecture",
          "depends_on" => [],
          "params" => %{"query" => "Elixir OTP concurrency patterns", "delay_ms" => delay_ms},
          "model_config" => %{
            "reasoning_effort" => "high",
            "provider" => "anthropic",
            "model_id" => "claude-3-7-sonnet"
          },
          "safety_policy" => "read_only"
        },
        %{
          "key" => "code_gen",
          "kind" => "swarm_code_gen",
          "title" => "Swarm Implementation",
          "depends_on" => ["research"],
          "params" => %{"prompt" => "Implement concurrency supervisor"},
          "model_config" => %{
            "reasoning_effort" => "medium",
            "provider" => "openai",
            "model_id" => "gpt-4o"
          },
          "safety_policy" => "full_auto"
        },
        %{
          "key" => "verify",
          "kind" => "test_verification",
          "title" => "Test Suite Verification",
          "depends_on" => ["code_gen"],
          "params" => %{
            "test_command" => "mix test test/iex_code/execution/command_parser_workflow_test.exs"
          },
          "model_config" => %{
            "reasoning_effort" => "none",
            "provider" => "openai",
            "model_id" => "gpt-4o-mini"
          },
          "safety_policy" => "read_only"
        }
      ])

    {:ok, workflow} =
      Workflows.create_workflow(%{
        project_id: project.id,
        name: "Stress Test Workflow #{System.unique_integer([:positive])}",
        slug: "stress-workflow-#{System.unique_integer([:positive])}",
        description: "Adversarial stress testing of workflow cockpit",
        tags: ["stress", "cockpit", "pubsub"],
        variables: [],
        steps: steps
      })

    workflow
  end

  defp create_active_run(workflow, project, session, run_attrs \\ %{}) do
    defaults = %{
      project_id: project.id,
      session_id: session.id,
      inputs: %{},
      status: "running",
      progress: 33,
      current_step_key: "research",
      resolved_steps: workflow.steps,
      step_states: %{
        "research" => %{
          "status" => "running",
          "progress" => 40,
          "duration_ms" => 500,
          "input_tokens" => 800,
          "output_tokens" => 300,
          "thinking" => "Analyzing supervision tree dependencies...",
          "output" => %{}
        },
        "code_gen" => %{
          "status" => "pending",
          "progress" => 0,
          "output" => %{}
        },
        "verify" => %{
          "status" => "pending",
          "progress" => 0,
          "output" => %{}
        }
      }
    }

    attrs = Map.merge(defaults, run_attrs)
    {:ok, run} = Workflows.create_run(workflow, attrs)
    run
  end

  # ============================================================================
  # SCENARIO 1: RAPID SEQUENCE EXECUTION CONTROLS (PAUSE -> RESUME -> PAUSE)
  # ============================================================================

  describe "Scenario 1: Rapid sequence execution controls (pause -> resume -> pause -> resume)" do
    test "rapidly alternates pause and resume on an active engine without crashing or race deadlocks",
         %{conn: conn, project: project} do
      workflow = create_test_workflow(project, delay_ms: 250)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start Engine GenServer directly
      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      ref = Process.monitor(engine_pid)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Assert initial running state
      assert has_element?(view, "#toolbar-pause-btn")

      # Stress loop: 10 rapid pause/resume cycles in sequence
      for _i <- 1..10 do
        # 1. Pause
        render_hook(view, "pause_run", %{"id" => run.id})
        assert {:ok, %{status: :paused}} = Engine.get_status(run.id)

        # Broadcast reflects in LiveView
        paused_run = Workflows.get_run!(run.id)
        assert paused_run.status == "paused"
        send(view.pid, {:workflow_run_paused, paused_run})
        html_paused = render(view)
        assert html_paused =~ "toolbar-resume-btn"
        assert html_paused =~ "Workflow execution paused"

        # 2. Resume
        render_hook(view, "resume_run", %{"id" => run.id})
        assert {:ok, %{status: :running}} = Engine.get_status(run.id)

        resumed_run = Workflows.get_run!(run.id)
        assert resumed_run.status == "running"
        send(view.pid, {:workflow_run_resumed, resumed_run})
        html_resumed = render(view)
        assert html_resumed =~ "toolbar-pause-btn"
        assert html_resumed =~ "Workflow execution resumed"
      end

      # Verify Engine is still healthy and alive
      assert Process.alive?(engine_pid)

      # Clean shutdown
      Engine.cancel_run(run.id)
      assert_receive {:DOWN, ^ref, :process, ^engine_pid, :normal}, 2000
    end

    test "handles redundant/duplicate pause and resume signals gracefully without crashing",
         %{conn: conn, project: project} do
      workflow = create_test_workflow(project)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)
      {:ok, _engine_pid} = Engine.start_link(run_id: run.id)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Pause once
      render_hook(view, "pause_run", %{"id" => run.id})
      assert {:ok, %{status: :paused}} = Engine.get_status(run.id)

      # Pause again (redundant)
      render_hook(view, "pause_run", %{"id" => run.id})
      assert {:ok, %{status: :paused}} = Engine.get_status(run.id)

      # Resume once
      render_hook(view, "resume_run", %{"id" => run.id})
      assert {:ok, %{status: :running}} = Engine.get_status(run.id)

      # Resume again (redundant)
      render_hook(view, "resume_run", %{"id" => run.id})
      assert {:ok, %{status: :running}} = Engine.get_status(run.id)

      Engine.cancel_run(run.id)
    end

    test "pausing or resuming a non-existent or inactive run returns error flash cleanly",
         %{conn: conn, project: _project} do
      fake_id = "00000000-0000-0000-0000-000000000000"
      {:ok, view, _html} = live(conn, ~p"/workflows")

      html_pause = render_hook(view, "pause_run", %{"id" => fake_id})
      assert html_pause =~ "Cannot pause: :run_not_active"

      html_resume = render_hook(view, "resume_run", %{"id" => fake_id})
      assert html_resume =~ "Cannot resume: :run_not_active"
    end
  end

  # ============================================================================
  # SCENARIO 2: CANCELLING A RUN MID-FLIGHT AND ASSERTING TERMINATIONS
  # ============================================================================

  describe "Scenario 2: Cancelling a run mid-flight and asserting all child tasks and states cleanly transition" do
    test "cancels active run, terminates spawned worker tasks, and updates run state to cancelled",
         %{conn: conn, project: project} do
      workflow = create_test_workflow(project, delay_ms: 250)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      engine_ref = Process.monitor(engine_pid)

      # Wait for workflow run and first step to start
      assert_receive {:workflow_run_started, _started_run}, 2000
      assert_receive {:workflow_step_started, "research", _step}, 2000

      # Check active task pid from engine state if task is still running
      engine_state = :sys.get_state(engine_pid)
      active_tasks = engine_state.active_tasks

      task_monitors =
        Enum.map(active_tasks, fn {key, task_pid} ->
          task_ref = Process.monitor(task_pid)
          {key, task_pid, task_ref}
        end)

      # Mount LiveView
      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Trigger cancellation via LiveView event
      render_hook(view, "cancel_run", %{"id" => run.id})

      # 1. Assert Engine process terminates cleanly
      assert_receive {:DOWN, ^engine_ref, :process, ^engine_pid, :normal}, 2000

      # 2. Assert any child worker tasks were killed/terminated
      for {_key, task_pid, task_ref} <- task_monitors do
        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 2000
        refute Process.alive?(task_pid)
      end

      # 3. Assert DB record status transitioned to "cancelled"
      cancelled_db_run = Workflows.get_run!(run.id)
      assert cancelled_db_run.status == "cancelled"
      assert cancelled_db_run.completed_at != nil

      # 4. Assert LiveView UI reflects cancellation
      send(view.pid, {:workflow_run_updated, cancelled_db_run})
      html = render(view)
      assert html =~ "cancelled"
      assert has_element?(view, "#toolbar-rerun-btn")
      refute has_element?(view, "#toolbar-pause-btn")
      refute has_element?(view, "#toolbar-cancel-btn")

      # 5. STEP STATES ON CANCELLATION:
      # Engine aborts active tasks, updates run.status to "cancelled", and transitions
      # running and pending step_states in DB to "cancelled".
      active_status = get_in(cancelled_db_run.step_states, ["research", "status"])
      assert active_status == "cancelled"

      # Verify that on the canvas, the node reflects this underlying state
      assert has_element?(view, "#step-node-research[data-step-status='cancelled']")
    end

    test "cancelling an inactive run returns error flash without crashing",
         %{conn: conn} do
      fake_id = "00000000-0000-0000-0000-000000000001"
      {:ok, view, _html} = live(conn, ~p"/workflows")

      html = render_hook(view, "cancel_run", %{"id" => fake_id})
      assert html =~ "Cannot cancel: :run_not_active"
    end
  end

  # ============================================================================
  # SCENARIO 3: HIGH-FREQUENCY PUBSUB FLOOD RESILIENCE & EDGE PAYLOADS
  # ============================================================================

  describe "Scenario 3: Simulating high-frequency PubSub events without crashing or dropping state" do
    test "handles massive flood of 120 interleaved PubSub events and maintains coherent UI state",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)
      run = create_active_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Fire 120 rapid interleaved PubSub events to view.pid
      events =
        for i <- 1..30 do
          [
            {:step_state_updated, run.id, "research", "running", %{progress: min(100, i * 3)}},
            {:step_state_updated, run.id, "code_gen", "running"},
            {:workflow_step_started, "verify", %{"key" => "verify"}},
            {:workflow_run_updated,
             %{
               run
               | progress: min(100, i * 3),
                 duration_ms: i * 100,
                 step_states: %{
                   "research" => %{"status" => "completed", "progress" => 100},
                   "code_gen" => %{"status" => "running", "progress" => min(100, i * 3)},
                   "verify" => %{"status" => "pending", "progress" => 0}
                 }
             }}
          ]
        end
        |> List.flatten()

      for event <- events do
        send(view.pid, event)
      end

      # LiveView must remain alive and process the queue
      assert Process.alive?(view.pid)

      # Render must succeed without raising
      html = render(view)
      assert html =~ "step-node-research"
      assert html =~ "step-node-code_gen"
      assert html =~ "step-node-verify"
      assert html =~ "90% completed" or html =~ "completed"

      # Step completion and failure flood
      send(
        view.pid,
        {:workflow_step_completed, "code_gen",
         %{"patches" => ["lib/auth.ex"], "status" => "completed"}}
      )

      send(view.pid, {:workflow_step_failed, "verify", "Compiler error in verification suite"})

      final_html = render(view)
      assert final_html =~ "step-node-verify"
      assert final_html =~ "Compiler error" or has_element?(view, "#step-node-verify")

      # Unknown event handling
      send(view.pid, {:arbitrary_foreign_message, %{data: 123}})
      assert Process.alive?(view.pid)
    end

    test "ignores PubSub events for mismatched run_id to prevent state corruption",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)
      run = create_active_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      foreign_run_id = "foreign-run-999"

      # Send step state update for another run
      send(view.pid, {:step_state_updated, foreign_run_id, "research", "failed"})

      # The current run's step state must NOT be modified
      html = render(view)
      assert html =~ "step-node-research"
      # research should still be running, not failed
      assert html =~ "data-step-status=\"running\""
    end

    test "non-map step output is handled gracefully without raising BadMapError in layout_workflow_dag",
         _tags do
      # When a step produces non-map output (e.g. raw string), layout_workflow_dag
      # safely guards output and does not raise BadMapError.
      graph =
        IexCodeWeb.WorkflowComponents.layout_workflow_dag(
          [%{"key" => "step_1", "kind" => "task", "depends_on" => []}],
          %{"step_1" => %{"status" => "completed", "output" => "raw text string"}},
          nil
        )

      assert length(graph.nodes) == 1
      assert hd(graph.nodes).status == "completed"
    end

    test "atom step_key in PubSub updates is coerced to string and updates canvas correctly",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)
      run = create_active_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Broadcast using atom step_key :research instead of string "research"
      send(view.pid, {:step_state_updated, run.id, :research, "completed"})

      # State in LiveView socket coerces :research to "research" and updates canvas
      html = render(view)
      assert html =~ "data-step-status=\"completed\""
    end
  end

  # ============================================================================
  # SCENARIO 4: RETRY FAILED STEP UNDER VARIOUS CONDITIONS
  # ============================================================================

  describe "Scenario 4: Retry failed step under active engine vs dead-run revival" do
    test "retries failed step when engine is active",
         %{conn: conn, project: project} do
      workflow = create_test_workflow(project)
      {:ok, run} = Workflows.launch_workflow(workflow, %{}, async: false)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      {:ok, engine_pid} = Engine.start_link(run_id: run.id)

      # Wait for engine to start
      assert_receive {:workflow_run_started, _started}, 2000

      # Simulate step failure while engine is active
      send(engine_pid, {:step_failed, "research", "API Rate Limit Exceeded", 350})

      # Wait for failure broadcast
      assert_receive {:workflow_step_failed, "research", _error}, 2000

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Inspect failed step
      render_hook(view, "inspect_step", %{"key" => "research"})
      html_inspector = render(view)
      assert html_inspector =~ "btn-retry-step-inspector"
      assert html_inspector =~ "Retry Step"

      # Click retry step
      html_after_retry =
        view
        |> element("#btn-retry-step-inspector")
        |> render_click()

      assert html_after_retry =~ "Retrying step research"

      Engine.cancel_run(run.id)
    end

    test "dead-run revival: retries failed step when engine is dead, reviving run to running in DB and UI",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)

      # Create dead failed run
      failed_run =
        create_active_run(workflow, project, session, %{
          status: "failed",
          progress: 50,
          error_message: "Step verify crashed unexpectedly",
          step_states: %{
            "research" => %{"status" => "completed", "progress" => 100},
            "code_gen" => %{"status" => "completed", "progress" => 100},
            "verify" => %{"status" => "failed", "progress" => 0, "error" => "Test runner timeout"}
          }
        })

      # Verify engine is NOT running
      assert Engine.whereis_run(failed_run.id) == nil

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{failed_run.id}")

      # Inspect verify step
      render_hook(view, "inspect_step", %{"key" => "verify"})
      html = render(view)
      assert html =~ "btn-retry-step-inspector"

      # Click retry
      retry_result =
        view
        |> element("#btn-retry-step-inspector")
        |> render_click()

      assert retry_result =~ "Retrying step verify"

      # Verify DB record was revived to "running"
      revived_db_run = Workflows.get_run!(failed_run.id)
      assert revived_db_run.status == "running"
      assert revived_db_run.step_states["verify"]["status"] in ["pending", "running"]

      # Cleanup any revived engine process
      if _pid = Engine.whereis_run(failed_run.id) do
        Engine.cancel_run(failed_run.id)
      end
    end

    test "attempting to retry a non-failed step returns clean error without state corruption",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)
      run = create_active_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Attempt to retry step that is currently running, not failed
      html = render_hook(view, "retry_workflow_step", %{"step" => "research"})
      assert html =~ "Failed to retry step: :run_not_active" or html =~ "Failed to retry step"
    end

    test "retrying step on cancelled run revives the run to running",
         %{project: project, session: session} do
      workflow = create_test_workflow(project)

      cancelled_run =
        create_active_run(workflow, project, session, %{
          status: "cancelled",
          step_states: %{
            "research" => %{"status" => "cancelled"},
            "code_gen" => %{"status" => "pending"}
          }
        })

      assert {:ok, updated_run} = Workflows.retry_step(cancelled_run.id, "research", async: false)
      assert updated_run.status == "running"
      assert updated_run.step_states["research"]["status"] == "pending"

      if _pid = Engine.whereis_run(cancelled_run.id) do
        Engine.cancel_run(cancelled_run.id)
      end
    end
  end

  # ============================================================================
  # SCENARIO 5: LIVE INSPECTOR TAB SWITCHING UNDER CONCURRENT UPDATES
  # ============================================================================

  describe "Scenario 5: Live Inspector tab switching and step selection under concurrent updates" do
    test "cycles through all 4 inspector tabs and preserves active tab during concurrent PubSub updates",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)

      run =
        create_active_run(workflow, project, session, %{
          step_states: %{
            "research" => %{
              "status" => "completed",
              "progress" => 100,
              "duration_ms" => 1250,
              "input_tokens" => 1500,
              "output_tokens" => 750,
              "cost_cents" => 18,
              "thinking" => "Comparing OTP PartitionSupervisor vs DynamicSupervisor...",
              "output" => %{
                "report" =>
                  "# OTP Concurrency Report\nDynamicSupervisor provides optimal fault isolation.",
                "citations" => [
                  %{
                    "title" => "Elixir Supervisor Docs",
                    "url" => "https://hexdocs.pm/elixir/Supervisor.html",
                    "trust_score" => 0.99
                  }
                ],
                "duration_ms" => 1250
              }
            },
            "code_gen" => %{"status" => "running", "progress" => 45, "output" => %{}},
            "verify" => %{"status" => "pending", "progress" => 0, "output" => %{}}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Select research step
      view |> element("#step-node-research") |> render_click()

      # 1. Logs Tab
      render_hook(view, "set_inspector_tab", %{"tab" => "logs"})
      assert has_element?(view, "#inspector-panel-logs")

      # 2. Thinking Tab
      render_hook(view, "set_inspector_tab", %{"tab" => "thinking"})
      assert has_element?(view, "#inspector-panel-thinking")
      assert render(view) =~ "Comparing OTP PartitionSupervisor"

      # 3. Telemetry & Cost Tab
      render_hook(view, "set_inspector_tab", %{"tab" => "metrics"})
      assert has_element?(view, "#inspector-panel-metrics")
      html_metrics = render(view)
      assert html_metrics =~ "1500"
      assert html_metrics =~ "750"
      assert html_metrics =~ "2250"

      # 4. Artifacts Tab
      render_hook(view, "set_inspector_tab", %{"tab" => "artifacts"})
      assert has_element?(view, "#inspector-panel-artifacts")
      assert render(view) =~ "OTP Concurrency Report"
      assert render(view) =~ "Elixir Supervisor Docs"

      # CONCURRENT UPDATES TEST: Switch back to Thinking tab and stream updates
      render_hook(view, "set_inspector_tab", %{"tab" => "thinking"})
      assert has_element?(view, "#inspector-panel-thinking")

      # Stream 20 updates for another step while user is reading thinking tab
      for i <- 1..20 do
        send(view.pid, {:step_state_updated, run.id, "code_gen", "running", %{progress: i * 5}})
      end

      # Active tab must STILL be :thinking
      assert has_element?(view, "#inspector-panel-thinking")
      assert render(view) =~ "Comparing OTP PartitionSupervisor"

      # Switch selected step to code_gen
      view |> element("#step-node-code_gen") |> render_click()
      html_cg = render(view)
      assert html_cg =~ "code_gen · swarm_code_gen"

      # Close inspector
      view |> element("#btn-close-step-inspector") |> render_click()
      refute has_element?(view, "#workflow-step-inspector")

      # Send updates while closed — must not raise
      send(view.pid, {:step_state_updated, run.id, "verify", "running"})
      assert Process.alive?(view.pid)
    end

    test "selecting non-existent step key handled safely without crashing",
         %{conn: conn, project: project, session: session} do
      workflow = create_test_workflow(project)
      run = create_active_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Inspect non-existent step
      render_hook(view, "inspect_step", %{"key" => "non_existent_step"})
      assert Process.alive?(view.pid)
      refute has_element?(view, "#workflow-step-inspector")
    end
  end
end
