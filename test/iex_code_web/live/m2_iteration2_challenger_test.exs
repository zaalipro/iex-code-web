defmodule IexCodeWeb.M2Iteration2ChallengerTest do
  @moduledoc """
  Milestone 2 Iteration 2 Adversarial & Empirical Verification Suite.
  Empirically verifies the remediation of all defects reported in Iteration 1:

  1. Mid-flight cancellation state transitions and Cockpit SVG rendering:
     - All active and pending steps in step_states strictly set to "cancelled" in DB.
     - SVG Canvas renders step as "cancelled".
     - Cockpit canvas does NOT render active glowing halos or traveling Bézier pulse particles.
  2. Robust handling of non-map step outputs:
     - String, list, integer, float, boolean, and nil outputs handled gracefully without BadMapError
       in both layout_workflow_dag and step_inspector across all 4 tabs.
  3. Reviving cancelled runs:
     - Calling Workflows.retry_step on a cancelled run revives the run to "running" and restarts the engine.
  4. PubSub atom step keys:
     - Broadcasting atom keys (:research, :code_gen, :verify) updates canvas nodes seamlessly.
  """

  use IexCode.E2E.Case, async: false

  import Phoenix.LiveViewTest
  alias IexCode.{Projects, Sessions, Workflows}
  alias IexCode.Workflows.{Engine, Workflow, WorkflowRun}
  alias IexCodeWeb.WorkflowComponents

  setup %{workspace_path: path} do
    {:ok, project} =
      Projects.create_project(%{
        name: "M2 Iteration 2 Challenger Verification",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "M2 Iteration 2 Verification Session",
        model_provider: "openai",
        model_name: "gpt-4o"
      })

    {:ok, project: project, session: session}
  end

  defp create_3step_workflow(project) do
    steps = [
      %{
        "key" => "research",
        "kind" => "deep_research",
        "title" => "Deep Research Step",
        "depends_on" => [],
        "params" => %{"query" => "Test query"},
        "model_config" => %{
          "reasoning_effort" => "high",
          "provider" => "openai",
          "model_id" => "o3-mini"
        },
        "safety_policy" => "read_only"
      },
      %{
        "key" => "code_gen",
        "kind" => "swarm_code_gen",
        "title" => "Code Generation Step",
        "depends_on" => ["research"],
        "params" => %{"prompt" => "Implement feature"},
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
        "title" => "Verification Step",
        "depends_on" => ["code_gen"],
        "params" => %{"test_command" => "mix test"},
        "model_config" => %{
          "reasoning_effort" => "none",
          "provider" => "openai",
          "model_id" => "gpt-4o"
        },
        "safety_policy" => "read_only"
      }
    ]

    {:ok, workflow} =
      Workflows.create_workflow(%{
        project_id: project.id,
        name: "3-Step Challenger Workflow #{System.unique_integer([:positive])}",
        slug: "challenger-workflow-#{System.unique_integer([:positive])}",
        description: "Milestone 2 Iteration 2 Verification",
        tags: ["verification", "recheck"],
        variables: [],
        steps: steps
      })

    workflow
  end

  defp create_test_run(workflow, project, session, run_attrs \\ %{}) do
    defaults = %{
      project_id: project.id,
      session_id: session.id,
      inputs: %{},
      status: "running",
      progress: 33,
      current_step_key: "research",
      resolved_steps: workflow.steps,
      step_states: %{
        "research" => %{"status" => "running", "progress" => 50, "output" => %{}},
        "code_gen" => %{"status" => "pending", "progress" => 0, "output" => %{}},
        "verify" => %{"status" => "pending", "progress" => 0, "output" => %{}}
      }
    }

    attrs = Map.merge(defaults, run_attrs)
    {:ok, run} = Workflows.create_run(workflow, attrs)
    run
  end

  # ============================================================================
  # VERIFICATION 1: MID-FLIGHT CANCELLATION STATE & SVG CANVAS RENDERING
  # ============================================================================

  describe "1. Mid-flight cancellation state transitions and Cockpit SVG rendering" do
    test "mid-flight cancellation transitions running AND pending steps to 'cancelled' in DB and broadcasts",
         %{conn: conn, project: project, session: session} do
      workflow = create_3step_workflow(project)
      run = create_test_run(workflow, project, session)

      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run.id}")

      # Start live engine for run
      {:ok, engine_pid} = Engine.start_link(run_id: run.id)
      assert Process.alive?(engine_pid)

      # Connect LiveView cockpit
      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Cancel run mid-flight
      assert :ok = Workflows.cancel_run(run.id)

      # Engine must terminate
      _ = :sys.get_state(view.pid)
      refute Process.alive?(engine_pid)

      # Assert DB record: run status and step_states strictly set to "cancelled"
      reloaded_run = Workflows.get_run!(run.id)
      assert reloaded_run.status == "cancelled"
      assert reloaded_run.completed_at != nil

      assert get_in(reloaded_run.step_states, ["research", "status"]) == "cancelled",
             "Expected research status to be 'cancelled', got: #{inspect(get_in(reloaded_run.step_states, ["research", "status"]))}"

      assert get_in(reloaded_run.step_states, ["code_gen", "status"]) == "cancelled",
             "Expected code_gen status to be 'cancelled', got: #{inspect(get_in(reloaded_run.step_states, ["code_gen", "status"]))}"

      assert get_in(reloaded_run.step_states, ["verify", "status"]) == "cancelled",
             "Expected verify status to be 'cancelled', got: #{inspect(get_in(reloaded_run.step_states, ["verify", "status"]))}"

      # Assert LiveView UI reflects cancelled state
      send(view.pid, {:workflow_run_updated, reloaded_run})
      html = render(view)

      assert html =~ "cancelled"
      assert has_element?(view, "#step-node-research[data-step-status='cancelled']")
      assert has_element?(view, "#step-node-code_gen[data-step-status='cancelled']")
      assert has_element?(view, "#step-node-verify[data-step-status='cancelled']")

      # Canvas nodes must NOT render active running halos or pulsating dots
      refute html =~ "shadow-[0_0_24px_rgba(34,211,238,0.45)]",
             "Cancelled canvas must not render active cyan halo glow"

      refute html =~ "bg-cyan-400 animate-ping",
             "Cancelled canvas must not render active pinging dot"

      # Canvas must NOT render traveling Bézier pulse particles (<animateMotion>)
      refute html =~ "<animateMotion",
             "Cancelled canvas must not render active animated particles"
    end

    test "workflow_canvas component renders cancelled run without active halos or particles" do
      steps = [
        %{"key" => "step_a", "title" => "Step A", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "step_b",
          "title" => "Step B",
          "kind" => "swarm_code_gen",
          "depends_on" => ["step_a"]
        }
      ]

      workflow = %Workflow{id: "wf-cancel-test", name: "Cancel Test", steps: steps}

      cancelled_run = %WorkflowRun{
        id: "run-cancel-test",
        status: "cancelled",
        current_step_key: nil,
        resolved_steps: steps,
        step_states: %{
          "step_a" => %{"status" => "cancelled"},
          "step_b" => %{"status" => "cancelled"}
        }
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-cancel-test",
          workflow: workflow,
          run: cancelled_run
        )

      # Must render nodes with cancelled status
      assert html =~ "step-node-step_a"
      assert html =~ "data-step-status=\"cancelled\""
      assert html =~ "step-node-step_b"

      # Must render hero-x-mark icon for cancelled step
      assert html =~ "hero-x-mark"

      # Must render shadow-none and border-zinc-600
      assert html =~ "shadow-none"
      assert html =~ "border-zinc-600"

      # Must NOT render active pulse particles or halos
      refute html =~ "<animateMotion"
      refute html =~ "shadow-[0_0_24px_rgba(34,211,238,0.45)]"
      refute html =~ "animate-ping"
    end
  end

  # ============================================================================
  # VERIFICATION 2: NON-MAP STEP OUTPUTS (STRINGS, LISTS, INTEGERS, FLOATS, NIL)
  # ============================================================================

  describe "2. Non-map step outputs handled gracefully without BadMapError" do
    @non_map_payloads [
      {"raw string output", "Build completed successfully in 320ms with 0 warnings."},
      {"multiline log string", "Line 1: starting worker\nLine 2: processing items\nLine 3: done"},
      {"integer output", 42},
      {"float output", 1337.89},
      {"list of strings", ["item_1", "item_2", "item_3"]},
      {"list of maps", [%{"id" => 1}, %{"id" => 2}]},
      {"boolean true", true},
      {"boolean false", false},
      {"nil output", nil}
    ]

    for {label, payload} <- @non_map_payloads do
      @tag payload_label: label
      test "layout_workflow_dag handles #{label} without BadMapError", _tags do
        steps = [%{"key" => "step_test", "kind" => "deep_research", "depends_on" => []}]

        step_states = %{
          "step_test" => %{"status" => "completed", "output" => unquote(Macro.escape(payload))}
        }

        graph = WorkflowComponents.layout_workflow_dag(steps, step_states, nil, "completed")
        assert is_map(graph)
        assert length(graph.nodes) == 1
        assert hd(graph.nodes).status == "completed"
      end

      @tag payload_label: label
      test "step_inspector renders #{label} cleanly across all 4 tabs without BadMapError" do
        step = %{
          "key" => "step_test",
          "title" => "Test Step",
          "kind" => "deep_research",
          "depends_on" => [],
          "model_config" => %{
            "reasoning_effort" => "medium",
            "provider" => "openai",
            "model_id" => "gpt-4o"
          }
        }

        run = %WorkflowRun{
          id: "run-inspect-test",
          status: "completed",
          current_step_key: "step_test",
          resolved_steps: [step],
          step_states: %{
            "step_test" => %{
              "status" => "completed",
              "output" => unquote(Macro.escape(payload)),
              "duration_ms" => 120,
              "input_tokens" => 500,
              "output_tokens" => 200
            }
          }
        }

        for tab <- [:logs, :thinking, :metrics, :artifacts] do
          html =
            render_component(&WorkflowComponents.step_inspector/1,
              id: "inspector-test-#{tab}",
              step: step,
              run: run,
              active_tab: tab,
              on_close: "close_inspector",
              on_set_tab: "set_inspector_tab",
              on_retry: "retry_step"
            )

          assert is_binary(html)
          assert html =~ "workflow-step-inspector"
          assert html =~ "step_test"
        end
      end
    end

    test "step_inspector displays raw string output in logs tab" do
      step = %{
        "key" => "build_step",
        "title" => "Compilation",
        "kind" => "test_verification",
        "depends_on" => []
      }

      raw_text = "== Compilation complete: 42 modules, 0 warnings =="

      run = %WorkflowRun{
        id: "run-string-log",
        status: "completed",
        current_step_key: "build_step",
        resolved_steps: [step],
        step_states: %{
          "build_step" => %{
            "status" => "completed",
            "output" => raw_text
          }
        }
      }

      html =
        render_component(&WorkflowComponents.step_inspector/1,
          id: "inspector-string-log",
          step: step,
          run: run,
          active_tab: :logs,
          on_close: "close_inspector",
          on_set_tab: "set_inspector_tab",
          on_retry: "retry_step"
        )

      assert html =~ "== Compilation complete: 42 modules, 0 warnings =="
    end
  end

  # ============================================================================
  # VERIFICATION 3: REVIVING CANCELLED RUNS WITH WORKFLOWS.RETRY_STEP
  # ============================================================================

  describe "3. Reviving cancelled runs with Workflows.retry_step" do
    test "calling Workflows.retry_step on a cancelled run revives the run to 'running' and restarts engine",
         %{project: project, session: session} do
      workflow = create_3step_workflow(project)

      cancelled_run =
        create_test_run(workflow, project, session, %{
          status: "cancelled",
          completed_at: DateTime.utc_now(),
          step_states: %{
            "research" => %{"status" => "cancelled"},
            "code_gen" => %{"status" => "cancelled"},
            "verify" => %{"status" => "cancelled"}
          }
        })

      # Verify engine is currently dead
      refute Engine.whereis_run(cancelled_run.id),
             "Engine should not be running for cancelled run before retry"

      # Invoke Workflows.retry_step with async: true (restarts engine under supervisor)
      assert {:ok, updated_run} = Workflows.retry_step(cancelled_run.id, "research", async: true)

      # 1. DB run status must be revived to "running"
      assert updated_run.status == "running"

      # 2. Retried step status must be set to "pending"
      assert updated_run.step_states["research"]["status"] == "pending"

      # 3. Reload from DB to verify persistence
      db_run = Workflows.get_run!(cancelled_run.id)
      assert db_run.status == "running"
      assert db_run.step_states["research"]["status"] == "pending"

      # 4. Engine process must be alive and registered
      # Allow a brief moment for supervisor start
      engine_pid =
        Enum.find_value(1..10, fn _ ->
          case Engine.whereis_run(cancelled_run.id) do
            pid when is_pid(pid) ->
              pid

            _ ->
              Process.sleep(50)
              nil
          end
        end)

      assert is_pid(engine_pid), "Expected Engine GenServer to be started and registered"
      assert Process.alive?(engine_pid)

      # Clean up engine
      Engine.cancel_run(cancelled_run.id)
    end
  end

  # ============================================================================
  # VERIFICATION 4: PUBSUB ATOM STEP KEYS COERCION
  # ============================================================================

  describe "4. PubSub atom step keys coercion in LiveView" do
    test "broadcasting atom step keys (:research, :code_gen, :verify) properly updates canvas nodes",
         %{conn: conn, project: project, session: session} do
      workflow = create_3step_workflow(project)
      run = create_test_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Broadcast atom step keys via PubSub events
      send(view.pid, {:step_state_updated, run.id, :research, "completed"})
      send(view.pid, {:step_state_updated, run.id, :code_gen, "running"})
      send(view.pid, {:workflow_step_failed, :verify, "Failed test execution"})

      _ = :sys.get_state(view.pid)

      # Verify each node on the canvas reflects the updated status
      assert has_element?(view, "#step-node-research[data-step-status='completed']"),
             "Expected step-node-research to have status 'completed'"

      assert has_element?(view, "#step-node-code_gen[data-step-status='running']"),
             "Expected step-node-code_gen to have status 'running'"

      assert has_element?(view, "#step-node-verify[data-step-status='failed']"),
             "Expected step-node-verify to have status 'failed'"

      # Verify no atom keys leak into the socket's step_states map
      step_states = :sys.get_state(view.pid).socket.assigns.run.step_states

      refute Map.has_key?(step_states, :research),
             "Atom key :research should not be in step_states"

      refute Map.has_key?(step_states, :code_gen),
             "Atom key :code_gen should not be in step_states"

      refute Map.has_key?(step_states, :verify), "Atom key :verify should not be in step_states"

      assert Map.has_key?(step_states, "research")
      assert Map.has_key?(step_states, "code_gen")
      assert Map.has_key?(step_states, "verify")
    end

    test "broadcasting 5-element tuple with atom step key is coerced and handled",
         %{conn: conn, project: project, session: session} do
      workflow = create_3step_workflow(project)
      run = create_test_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Send 5-element tuple: {:step_state_updated, run_id, step_key, new_state, metrics}
      metrics = %{duration_ms: 350, input_tokens: 120, output_tokens: 80}
      send(view.pid, {:step_state_updated, run.id, :code_gen, "completed", metrics})

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#step-node-code_gen[data-step-status='completed']")
    end
  end
end
