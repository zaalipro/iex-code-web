defmodule IexCodeWeb.Components.WorkflowComponentsTest do
  @moduledoc """
  Unit and component tests for WorkflowComponents (Requirement R2).
  Tests DAG coordinate layout, Bézier curve math, progress ring dashoffset,
  and rendering of canvas, inspector, toolbar, and workflow card.
  """

  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkflowComponents
  alias IexCode.Workflows.{Workflow, WorkflowRun}

  # ============================================================================
  # MATHEMATICAL & ALGORITHMIC TESTS
  # ============================================================================

  describe "layout_workflow_dag/3 mathematical coordinate positioning" do
    test "correctly levels linear 3-step DAG into 3 distinct columns" do
      steps = [
        %{"key" => "s1", "title" => "Step 1", "kind" => "deep_research", "depends_on" => []},
        %{"key" => "s2", "title" => "Step 2", "kind" => "swarm_code_gen", "depends_on" => ["s1"]},
        %{
          "key" => "s3",
          "title" => "Step 3",
          "kind" => "test_verification",
          "depends_on" => ["s2"]
        }
      ]

      graph = WorkflowComponents.layout_workflow_dag(steps, %{}, nil)

      assert length(graph.nodes) == 3
      assert length(graph.edges) == 2

      [n1, n2, n3] = graph.nodes
      assert n1.key == "s1"
      assert n2.key == "s2"
      assert n3.key == "s3"

      # Horizontal positions strictly monotonic by layer
      assert n1.x < n2.x
      assert n2.x < n3.x

      # Gap between columns matches (@node_width + @gap_x = 250 + 90 = 340)
      assert n2.x - n1.x == 340
      assert n3.x - n2.x == 340
    end

    test "correctly positions parallel diamond DAG branches with vertical offsets" do
      # Diamond: s1 -> (s2a, s2b) -> s3
      steps = [
        %{"key" => "root", "title" => "Root", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "branch_a",
          "title" => "Branch A",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "branch_b",
          "title" => "Branch B",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "sink",
          "title" => "Sink",
          "kind" => "git_commit",
          "depends_on" => ["branch_a", "branch_b"]
        }
      ]

      graph = WorkflowComponents.layout_workflow_dag(steps, %{}, nil)

      assert length(graph.nodes) == 4
      assert length(graph.edges) == 4

      node_map = Map.new(graph.nodes, &{&1.key, &1})

      root = node_map["root"]
      sink = node_map["sink"]
      b_a = node_map["branch_a"]
      b_b = node_map["branch_b"]

      # Root and Sink each have layer size 1, so their x coordinates are col 0 and col 2
      # Branches A and B are in layer 1 (col 1)
      assert root.x < b_a.x
      assert b_a.x == b_b.x
      assert b_a.x < sink.x

      # Branches A and B are vertically stacked
      assert b_a.y != b_b.y
      assert abs(b_b.y - b_a.y) == 115 + 45

      # Single node layers (root, sink) are centered relative to max layer height
      assert root.y > 60
      assert sink.y > 60
    end

    test "handles empty steps gracefully" do
      graph = WorkflowComponents.layout_workflow_dag([], %{}, nil)
      assert graph.nodes == []
      assert graph.edges == []
      assert graph.width >= 800
      assert graph.height >= 500
    end
  end

  describe "bezier_edge/2 parametric cubic curve calculations" do
    test "computes smooth cubic Bézier with strictly horizontal port tangents" do
      source = %{x: 60, y: 100, width: 250, height: 115}
      target = %{x: 400, y: 200, width: 250, height: 115}

      curve = WorkflowComponents.bezier_edge(source, target)

      # Start point on source right boundary
      assert curve.x1 == 60 + 250
      assert curve.y1 == 100 + 57

      # End point on target left boundary
      assert curve.x2 == 400
      assert curve.y2 == 200 + 57

      # Horizontal control point tangents
      assert curve.cy1 == curve.y1
      assert curve.cy2 == curve.y2

      # Positive control offset dx
      assert curve.cx1 > curve.x1
      assert curve.cx2 < curve.x2

      # SVG path syntax
      assert curve.d =~
               "M #{curve.x1} #{curve.y1} C #{curve.cx1} #{curve.cy1}, #{curve.cx2} #{curve.cy2}, #{curve.x2} #{curve.y2}"
    end
  end

  describe "calc_progress_dashoffset/2 circumference mathematics" do
    test "computes correct dashoffset for 0%, 50%, and 100%" do
      c = 94.2478

      # 0% -> full circumference (empty)
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(0, c), 94.2478, 0.001

      # 50% -> half circumference
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(50, c), 47.1239, 0.001

      # 100% -> zero offset (full ring)
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(100, c), 0.0, 0.001
    end

    test "clamps values below 0 and above 100" do
      c = 100.0
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(-20, c), 100.0, 0.001
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(150, c), 0.0, 0.001
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(nil, c), 100.0, 0.001
    end
  end

  # ============================================================================
  # COMPONENT RENDERING TESTS
  # ============================================================================

  describe "step_progress_ring component rendering" do
    test "renders circular SVG ring with status icon when pending" do
      html =
        render_component(&WorkflowComponents.step_progress_ring/1, status: "pending", progress: 0)

      assert html =~ "viewBox=\"0 0 36 36\""
      assert html =~ "stroke-dasharray=\"94.2478\""
      assert html =~ "stroke-dashoffset=\"94.2478\""
      assert html =~ "hero-clock"
    end

    test "renders percentage text when running with progress > 0" do
      html =
        render_component(&WorkflowComponents.step_progress_ring/1,
          status: "running",
          progress: 65
        )

      assert html =~ "65%"
      assert html =~ "stroke-cyan-400"
      # Offset for 65%: 94.2478 * (1 - 0.65) = 32.9867
      assert html =~ "stroke-dashoffset=\"32.9867\""
    end

    test "renders check icon and completed stroke when completed" do
      html =
        render_component(&WorkflowComponents.step_progress_ring/1,
          status: "completed",
          progress: 100
        )

      assert html =~ "stroke-emerald-400"
      assert html =~ "stroke-dashoffset=\"0.0\""
      assert html =~ "hero-check"
    end
  end

  describe "workflow_canvas component rendering" do
    test "renders SVG canvas with markers, defs, filters, and node cards" do
      workflow = %Workflow{
        id: "wf-1",
        name: "Test Canvas Workflow",
        steps: [
          %{
            "key" => "step_1",
            "title" => "Deep Research Task",
            "kind" => "deep_research",
            "depends_on" => [],
            "model_config" => %{"reasoning_effort" => "high"}
          },
          %{
            "key" => "step_2",
            "title" => "Swarm Generation",
            "kind" => "swarm_code_gen",
            "depends_on" => ["step_1"],
            "model_config" => %{"reasoning_effort" => "medium"}
          }
        ]
      }

      run = %WorkflowRun{
        id: "run-1",
        status: "running",
        current_step_key: "step_2",
        progress: 50,
        resolved_steps: workflow.steps,
        step_states: %{
          "step_1" => %{"status" => "completed", "progress" => 100, "duration_ms" => 1200},
          "step_2" => %{"status" => "running", "progress" => 50, "duration_ms" => 400}
        }
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-test",
          workflow: workflow,
          run: run,
          selected_step_key: "step_2",
          zoom_level: 1.0,
          pan_offset: %{x: 0.0, y: 0.0}
        )

      # SVG Structure
      assert html =~ "id=\"canvas-test-svg\""
      assert html =~ "id=\"canvas-test-arrow-running\""
      assert html =~ "id=\"canvas-test-arrow-completed\""
      assert html =~ "id=\"canvas-test-glow-running\""

      # Node cards
      assert html =~ "step-node-step_1"
      assert html =~ "step-node-step_2"
      assert html =~ "Deep Research Task"
      assert html =~ "Swarm Generation"

      # Active pulse on edge from completed step_1 to running step_2
      assert html =~ "edge-step_1--step_2"
      assert html =~ "active-edge-flow"
      assert html =~ "animateMotion"

      # Selected step glowing halo
      assert html =~ "ring-2 ring-cyan-400"

      # Colocated hook
      assert html =~ "WorkflowCanvasHook"
    end
  end

  describe "step_inspector component rendering" do
    test "renders 4 tabs: logs, thinking, metrics, artifacts" do
      step = %{
        "key" => "audit_step",
        "title" => "Security Audit",
        "kind" => "security_audit",
        "model_config" => %{
          "reasoning_effort" => "high",
          "provider" => "anthropic",
          "model_id" => "claude-3-7-sonnet"
        },
        "safety_policy" => "prompt_dangerous"
      }

      run = %WorkflowRun{
        id: "run-99",
        status: "running",
        step_states: %{
          "audit_step" => %{
            "status" => "running",
            "progress" => 40,
            "input_tokens" => 800,
            "output_tokens" => 250,
            "duration_ms" => 950,
            "cost_cents" => 12,
            "thinking" => "Inspecting AST for shell injection risks...",
            "output" => %{
              "verdict" => "passed",
              "risk_score" => 0,
              "violations" => []
            }
          }
        }
      }

      # Logs tab
      html_logs =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :logs
        )

      assert html_logs =~ "workflow-step-inspector"
      assert html_logs =~ "inspector-tab-logs"
      assert html_logs =~ "inspector-tab-thinking"
      assert html_logs =~ "inspector-tab-metrics"
      assert html_logs =~ "inspector-tab-artifacts"
      assert html_logs =~ "Execution Output and Terminal Stream"

      # Thinking tab
      html_thinking =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :thinking
        )

      assert html_thinking =~ "Inspecting AST for shell injection risks..."
      assert html_thinking =~ "Effort: high"
      assert html_thinking =~ "Provider: anthropic"

      # Metrics tab
      html_metrics =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :metrics
        )

      assert html_metrics =~ "800"
      assert html_metrics =~ "250"
      assert html_metrics =~ "1050"
      assert html_metrics =~ "prompt_dangerous"
      assert html_metrics =~ "claude-3-7-sonnet"

      # Artifacts tab
      html_artifacts =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :artifacts
        )

      assert html_artifacts =~ "Security Audit Summary"
      assert html_artifacts =~ "Verdict: passed"
    end

    test "renders Retry Step button when step has failed" do
      step = %{
        "key" => "broken_step",
        "title" => "Broken Step",
        "kind" => "test_verification"
      }

      run = %WorkflowRun{
        id: "run-failed",
        status: "failed",
        step_states: %{
          "broken_step" => %{
            "status" => "failed",
            "error" => "Assertion failed: expected true, got false"
          }
        }
      }

      html =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :logs
        )

      assert html =~ "btn-retry-step-inspector"
      assert html =~ "Retry Step"
      assert html =~ "Assertion failed: expected true, got false"
    end
  end

  describe "execution_toolbar component rendering" do
    test "renders Pause and Cancel when status is running" do
      workflow = %Workflow{id: "wf-1", name: "Deploy Pipeline"}
      run = %WorkflowRun{id: "run-123", status: "running", progress: 50, duration_ms: 3200}

      html =
        render_component(&WorkflowComponents.execution_toolbar/1, workflow: workflow, run: run)

      assert html =~ "toolbar-pause-btn"
      assert html =~ "toolbar-cancel-btn"
      refute html =~ "toolbar-resume-btn"
      refute html =~ "toolbar-rerun-btn"
      assert html =~ "50% completed"
    end

    test "renders Resume and Cancel when status is paused" do
      workflow = %Workflow{id: "wf-1", name: "Deploy Pipeline"}
      run = %WorkflowRun{id: "run-123", status: "paused", progress: 50, duration_ms: 3200}

      html =
        render_component(&WorkflowComponents.execution_toolbar/1, workflow: workflow, run: run)

      assert html =~ "toolbar-resume-btn"
      assert html =~ "toolbar-cancel-btn"
      refute html =~ "toolbar-pause-btn"
    end

    test "renders Run Again when status is completed" do
      workflow = %Workflow{id: "wf-1", name: "Deploy Pipeline"}
      run = %WorkflowRun{id: "run-123", status: "completed", progress: 100, duration_ms: 5400}

      html =
        render_component(&WorkflowComponents.execution_toolbar/1, workflow: workflow, run: run)

      assert html =~ "toolbar-rerun-btn"
      refute html =~ "toolbar-pause-btn"
      refute html =~ "toolbar-resume-btn"
      refute html =~ "toolbar-cancel-btn"
    end
  end

  describe "workflow_card component rendering" do
    test "renders card with title, slug, step pills, tags, and launch button" do
      workflow = %Workflow{
        id: "wf-card-1",
        name: "Full-Cycle Autonomous Builder",
        slug: "full-cycle-builder",
        description: "Automated end-to-end implementation",
        tags: ["autonomous", "swarm"],
        steps: [
          %{"key" => "res", "title" => "Research", "kind" => "deep_research"},
          %{"key" => "gen", "title" => "Code Gen", "kind" => "swarm_code_gen"},
          %{"key" => "test", "title" => "Verify", "kind" => "test_verification"}
        ]
      }

      html = render_component(&WorkflowComponents.workflow_card/1, workflow: workflow)

      assert html =~ "workflow-card-wf-card-1"
      assert html =~ "Full-Cycle Autonomous Builder"
      assert html =~ "full-cycle-builder"
      assert html =~ "Pipeline Steps (3)"
      assert html =~ "Research"
      assert html =~ "Code Gen"
      assert html =~ "Verify"
      assert html =~ "#autonomous"
      assert html =~ "#swarm"
      assert html =~ "btn-launch-wf-card-1"
    end
  end
end
