defmodule IexCodeWeb.WorkflowsLiveTest do
  @moduledoc """
  End-to-End LiveView integration tests for Milestone 2:
  WorkflowsLive Gallery, Builder, Details, and Real-Time SVG Cockpit (Requirement R1, R2).
  """

  use IexCode.E2E.Case, async: false

  import Phoenix.LiveViewTest
  alias IexCode.{Projects, Sessions, Workflows}

  setup %{workspace_path: path} do
    {:ok, project} =
      Projects.create_project(%{
        name: "Workflows Studio Project",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Workflows Test Session",
        model_provider: "openai",
        model_name: "gpt-4o"
      })

    {:ok, project: project, session: session}
  end

  defp create_sample_workflow(project) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        project_id: project.id,
        name: "Autonomous Full-Cycle Pipeline",
        slug: "autonomous-pipeline-#{System.unique_integer([:positive])}",
        description:
          "Autonomous pipeline with deep research, code generation, verification, and audit.",
        tags: ["autonomous", "full-cycle", "swarm"],
        variables: [
          %{
            "name" => "feature_name",
            "type" => "string",
            "default" => "OAuth2 Auth",
            "required" => true
          }
        ],
        steps: [
          %{
            "key" => "research",
            "kind" => "deep_research",
            "title" => "Deep Research Auth Architecture",
            "depends_on" => [],
            "params" => %{"query" => "{{feature_name}} architecture"},
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
            "title" => "Swarm Code Implementation",
            "depends_on" => ["research"],
            "params" => %{"prompt" => "Implement auth module for {{feature_name}}"},
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
            "title" => "Automated Test Suite",
            "depends_on" => ["code_gen"],
            "params" => %{"test_filter" => "auth_test.exs"},
            "model_config" => %{
              "reasoning_effort" => "none",
              "provider" => "openai",
              "model_id" => "gpt-4o-mini"
            },
            "safety_policy" => "read_only"
          }
        ]
      })

    workflow
  end

  defp create_sample_run(workflow, project, session) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        project_id: project.id,
        session_id: session.id,
        inputs: %{"feature_name" => "OAuth2 Auth"},
        status: "running",
        progress: 33,
        current_step_key: "code_gen",
        resolved_steps: workflow.steps,
        step_states: %{
          "research" => %{
            "status" => "completed",
            "progress" => 100,
            "duration_ms" => 1840,
            "input_tokens" => 1200,
            "output_tokens" => 640,
            "cost_cents" => 15,
            "thinking" => "Comparing JWT and session cookie architectures...",
            "output" => %{
              "report" => "# OAuth2 Architecture Report\n\nRecommended OAuth2 flow with PKCE.",
              "citations" => [
                %{
                  "title" => "RFC 7636",
                  "url" => "https://tools.ietf.org/html/rfc7636",
                  "trust_score" => 0.98
                }
              ],
              "duration_ms" => 1840
            }
          },
          "code_gen" => %{
            "status" => "running",
            "progress" => 50,
            "duration_ms" => 920,
            "input_tokens" => 2100,
            "output_tokens" => 350,
            "cost_cents" => 22,
            "thinking" => "Synthesizing AuthController with secure password hashing...",
            "output" => %{}
          },
          "verify" => %{
            "status" => "pending",
            "progress" => 0,
            "output" => %{}
          }
        }
      })

    run
  end

  # ============================================================================
  # 1. GALLERY VIEW TESTS
  # ============================================================================

  describe "WorkflowsLive :index & :session_index gallery" do
    test "mounts /workflows cleanly and renders banner, cards, and quick metrics", %{
      conn: conn,
      project: project
    } do
      workflow = create_sample_workflow(project)

      {:ok, view, html} = live(conn, ~p"/workflows")

      assert html =~ "Project Workflows"
      assert html =~ "Grok-Like Autonomous Execution Engine"
      assert has_element?(view, "#workflows-gallery")
      assert has_element?(view, "#workflow-card-#{workflow.id}")
      assert html =~ workflow.name
      assert html =~ "Pipeline Steps (3)"
      assert html =~ "Deep Research Auth Architecture"
      assert html =~ "#autonomous"
      assert html =~ "#full-cycle"
    end

    test "mounts session-scoped route /sessions/:id/workflows", %{
      conn: conn,
      project: project,
      session: session
    } do
      workflow = create_sample_workflow(project)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/workflows")

      assert has_element?(view, "#workflows-gallery")
      assert has_element?(view, "#workflow-card-#{workflow.id}")
      assert html =~ workflow.name
    end

    test "search input filters displayed workflows", %{conn: conn, project: project} do
      _w1 = create_sample_workflow(project)

      {:ok, view, _html} = live(conn, ~p"/workflows")

      assert render_hook(view, "search", %{"query" => "Autonomous"}) =~
               "Autonomous Full-Cycle Pipeline"
    end

    test "launching a workflow without missing required variables starts execution and redirects to cockpit",
         %{conn: conn, project: project} do
      workflow = create_sample_workflow(project)

      {:ok, view, _html} = live(conn, ~p"/workflows")

      result =
        view
        |> element("#btn-launch-#{workflow.id}")
        |> render_click()

      # Should navigate to cockpit
      assert {:error, {:live_redirect, %{to: target_path}}} = result
      assert target_path =~ "/workflows/#{workflow.id}/runs/"
    end
  end

  # ============================================================================
  # 2. WORKFLOW BUILDER / ASSISTANT TESTS
  # ============================================================================

  describe "WorkflowsLive :new & :session_new builder" do
    test "mounts /workflows/new and renders assistant and form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workflows/new")

      assert html =~ "Create New Workflow"
      assert has_element?(view, "#blueprint-prompt-form")
      assert has_element?(view, "#blueprint-prompt-input")
      assert has_element?(view, "#workflow-config-form")
      assert has_element?(view, "#btn-synthesize-blueprint")
      assert has_element?(view, "#btn-save-workflow")
    end

    test "mounts alternative route /create-workflow", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/create-workflow")

      assert html =~ "Create New Workflow"
      assert has_element?(view, "#blueprint-prompt-form")
    end

    test "synthesizes 5-step DAG blueprint from prompt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/new")

      html =
        view
        |> form("#blueprint-prompt-form", %{
          "prompt" => "Implement User Registration and Auth with rate limits"
        })
        |> render_submit()

      assert html =~ "Workflow blueprint synthesized successfully"
      assert html =~ "Configured DAG Steps"
      assert html =~ "deep_research"
      assert html =~ "swarm_code_gen"
      assert html =~ "test_verification"
      assert html =~ "security_audit"
      assert html =~ "git_commit"
    end

    test "metadata validation preserves generated steps when saving a session workflow", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows/new")
      slug = "review-generated-dag-#{System.unique_integer([:positive])}"

      assert has_element?(view, "#workflow-config-form")

      view
      |> form("#workflow-config-form", %{
        "workflow" => %{
          "name" => "Reviewed Generated DAG",
          "slug" => slug,
          "description" => "Metadata edited after synthesis"
        }
      })
      |> render_change()

      result =
        view
        |> form("#workflow-config-form", %{
          "workflow" => %{
            "name" => "Reviewed Generated DAG",
            "slug" => slug,
            "description" => "Metadata edited after synthesis"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: target_path}}} = result
      workflow = Workflows.get_workflow_by_slug(project.id, slug)

      assert target_path == ~p"/sessions/#{session.id}/workflows/#{workflow.id}"
      assert length(workflow.steps) == 5
    end

    test "submits valid workflow and navigates to workflow show view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/new")

      # First synthesize blueprint to populate steps
      view
      |> form("#blueprint-prompt-form", %{"prompt" => "Deploy Microservice Pipeline"})
      |> render_submit()

      slug = "deploy-microservice-#{System.unique_integer([:positive])}"

      result =
        view
        |> form("#workflow-config-form", %{
          "workflow" => %{
            "name" => "Deploy Microservice Pipeline",
            "slug" => slug,
            "description" => "Autonomous microservice deployment"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: target_path}}} = result
      assert target_path =~ "/workflows/"
    end
  end

  # ============================================================================
  # 3. WORKFLOW SHOW VIEW TESTS
  # ============================================================================

  describe "WorkflowsLive :show workflow details" do
    test "mounts /workflows/:id and displays DAG architecture preview", %{
      conn: conn,
      project: project
    } do
      workflow = create_sample_workflow(project)

      {:ok, view, html} = live(conn, ~p"/workflows/#{workflow.id}")

      assert html =~ workflow.name
      assert html =~ workflow.slug
      assert html =~ "Directed Graph Architecture"
      assert has_element?(view, "#details-preview-canvas")
      assert has_element?(view, "#btn-launch-details")
    end
  end

  # ============================================================================
  # 4. REAL-TIME SVG EXECUTION COCKPIT TESTS
  # ============================================================================

  describe "WorkflowsLive :run cockpit and interactive canvas" do
    test "mounts cockpit and renders execution toolbar, SVG canvas with Bézier edges and node halos",
         %{
           conn: conn,
           project: project,
           session: session
         } do
      workflow = create_sample_workflow(project)
      run = create_sample_run(workflow, project, session)

      {:ok, view, html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Execution Toolbar
      assert has_element?(view, "#workflow-execution-toolbar")
      assert has_element?(view, "#toolbar-pause-btn")
      assert has_element?(view, "#toolbar-cancel-btn")
      assert html =~ "33% completed"

      # SVG Canvas
      assert has_element?(view, "#cockpit-canvas")
      assert has_element?(view, "#cockpit-canvas-svg")
      assert has_element?(view, "#edge-research--code_gen")
      assert has_element?(view, "#step-node-research")
      assert has_element?(view, "#step-node-code_gen")
      assert has_element?(view, "#step-node-verify")

      # Visual halos & states
      # running halo on code_gen
      assert html =~ "shadow-[0_0_24px_rgba(34,211,238,0.45)]"
      # active pulse on running edge
      assert html =~ "active-edge-flow"
      # traveling pulse orb particle
      assert html =~ "animateMotion"
    end

    test "clicking a node opens live slide-over step inspector and tab switching functions", %{
      conn: conn,
      project: project,
      session: session
    } do
      workflow = create_sample_workflow(project)
      run = create_sample_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Click on completed research node
      html =
        view
        |> element("#step-node-research")
        |> render_click()

      assert html =~ "workflow-step-inspector"
      assert html =~ "Deep Research Auth Architecture"
      assert html =~ "research · deep_research"
      assert has_element?(view, "#inspector-tab-logs")
      assert has_element?(view, "#inspector-tab-thinking")
      assert has_element?(view, "#inspector-tab-metrics")
      assert has_element?(view, "#inspector-tab-artifacts")

      # Switch to Thinking tab
      html_thinking =
        view
        |> element("#inspector-tab-thinking")
        |> render_click()

      assert html_thinking =~ "Comparing JWT and session cookie architectures..."
      assert html_thinking =~ "Effort: high"

      # Switch to Telemetry & Cost tab
      html_metrics =
        view
        |> element("#inspector-tab-metrics")
        |> render_click()

      # input tokens
      assert html_metrics =~ "1200"
      # output tokens
      assert html_metrics =~ "640"
      # total tokens
      assert html_metrics =~ "1840"
      assert html_metrics =~ "claude-3-7-sonnet"

      # Switch to Artifacts tab
      html_artifacts =
        view
        |> element("#inspector-tab-artifacts")
        |> render_click()

      assert html_artifacts =~ "Deep Research Report"
      assert html_artifacts =~ "RFC 7636"

      # Close inspector
      html_closed =
        view
        |> element("#btn-close-step-inspector")
        |> render_click()

      refute html_closed =~ "workflow-step-inspector"
    end

    test "handles pan and zoom client events on the canvas", %{
      conn: conn,
      project: project,
      session: session
    } do
      workflow = create_sample_workflow(project)
      run = create_sample_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Zoom in
      assert render_hook(view, "canvas_zoom", %{"direction" => "in"}) =~ "115%"

      # Zoom out
      assert render_hook(view, "canvas_zoom", %{"direction" => "out"}) =~ "100%"

      # Set zoom directly
      assert render_hook(view, "canvas_zoom", %{"level" => 1.5}) =~ "150%"

      # Pan offset
      render_hook(view, "canvas_pan", %{"x" => 120.0, "y" => 80.0})
      assert view |> element("#cockpit-canvas") |> render() =~ "data-pan-x=\"120.0\""
    end

    test "handles real-time PubSub updates smoothly without page reload", %{
      conn: conn,
      project: project,
      session: session
    } do
      workflow = create_sample_workflow(project)
      run = create_sample_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Simulate step state update: verify step starts running
      send(view.pid, {:step_state_updated, run.id, "verify", "running"})
      html = render(view)
      assert html =~ "step-node-verify"

      # Simulate step completed
      send(
        view.pid,
        {:workflow_step_completed, "verify",
         %{"verdict" => "passed", "total" => 10, "passed" => 10, "failed" => 0}}
      )

      html = render(view)
      assert html =~ "step-node-verify"

      # Simulate run completed
      updated_run = %{run | status: "completed", progress: 100, duration_ms: 3800}
      send(view.pid, {:workflow_run_updated, updated_run})
      html = render(view)
      assert html =~ "100% completed"
      assert has_element?(view, "#toolbar-rerun-btn")
    end

    test "execution controls: pause, resume, cancel, and step retry", %{
      conn: conn,
      project: project,
      session: session
    } do
      workflow = create_sample_workflow(project)
      run = create_sample_run(workflow, project, session)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}/runs/#{run.id}")

      # Pause run
      render_hook(view, "pause_run", %{"id" => run.id})
      # PubSub simulation of pause
      paused_run = %{run | status: "paused"}
      send(view.pid, {:workflow_run_paused, paused_run})
      assert render(view) =~ "toolbar-resume-btn"

      # Resume run
      render_hook(view, "resume_run", %{"id" => run.id})
      resumed_run = %{run | status: "running"}
      send(view.pid, {:workflow_run_resumed, resumed_run})
      assert render(view) =~ "toolbar-pause-btn"

      # Step failure and retry button
      send(view.pid, {:workflow_step_failed, "verify", "Test suite execution crashed"})
      html = render(view)
      assert html =~ "step-node-verify"

      # Open failed step inspector and verify retry button
      html_failed_inspector =
        view
        |> element("#step-node-verify")
        |> render_click()

      assert html_failed_inspector =~ "btn-retry-step-inspector"
      assert html_failed_inspector =~ "Retry Step"

      # Click retry step
      retry_html =
        view
        |> element("#btn-retry-step-inspector")
        |> render_click()

      assert retry_html =~ "Retrying step verify"
    end
  end
end
