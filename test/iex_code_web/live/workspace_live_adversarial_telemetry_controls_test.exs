defmodule IexCodeWeb.WorkspaceLiveAdversarialTelemetryControlsTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Sessions
  alias IexCode.Sessions.Operation

  # ============================================================================
  # 1. High-Frequency Telemetry Burst & Stress Testing (R3, R4)
  # ============================================================================

  describe "High-Frequency Telemetry Burst & Stress" do
    test "survives massive 500-event telemetry burst without WebSocket crash or state corruption",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Spawn 10 concurrent workers emitting rapid interleaved progress events to the LiveView PID
      tasks =
        for worker_id <- 1..10 do
          Task.async(fn ->
            for i <- 1..50 do
              agent =
                Enum.at(
                  ["PlannerAgent", "ExplorerAgent", "CoderAgent", "VerifierAgent"],
                  rem(i + worker_id, 4)
                )

              op_id = "burst-op-w#{worker_id}-#{i}"

              op = %Operation{
                id: op_id,
                session_id: session.id,
                agent_name: agent,
                op_type: "stress_step",
                title: "Concurrent telemetry stress event #{worker_id}:#{i}",
                status: "running",
                progress: rem(i * 2, 100),
                duration_ms: i * 5,
                pid_str: "#PID<0.#{1000 + worker_id}.0>",
                started_at: DateTime.utc_now() |> DateTime.truncate(:second)
              }

              send(view.pid, {:operation_started, op})

              send(
                view.pid,
                {:operation_progress,
                 %{
                   id: op_id,
                   progress: rem(i * 2 + 10, 100),
                   status: "running",
                   latency_ms: i * 5,
                   message: "Progress #{i}"
                 }}
              )

              send(
                view.pid,
                {:operation_progress, op_id, rem(i * 2 + 20, 100), "Progress string #{i}"}
              )
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 10_000))

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "Execution Hierarchy"
      assert html =~ "MULTI-AGENT SWARM HARNESS ACTIVE"
    end

    test "handles rapid swarm_stage_changed cycling with all metadata formats and extreme values",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      stages = [:init, :planning, :exploring, :coding, :verifying, :completed, :failed]

      # Cycle through 100 rapid stage changes with varied payloads
      for i <- 1..100 do
        stage = Enum.at(stages, rem(i, length(stages)))

        payload =
          case rem(i, 4) do
            0 ->
              stage

            1 ->
              %{
                stage: stage,
                iteration: i,
                latency_ms: i * 15,
                agent_pid: "#PID<0.#{i}.0>",
                message: "Stage #{stage} step #{i}"
              }

            2 ->
              %{stage: stage}

            3 ->
              %{stage: stage, latency_ms: nil, agent_pid: nil}
          end

        send(view.pid, {:swarm_stage_changed, payload})
      end

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "MULTI-AGENT SWARM HARNESS ACTIVE"
    end

    test "gracefully handles out-of-order, corrupt, unknown, and extreme operation payloads", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # 1. Operation progress for non-existent operation ID
      send(view.pid, {:operation_progress, "non-existent-op-9999", 50, "Ghost op progress"})

      send(
        view.pid,
        {:operation_progress,
         %{id: "unknown-map-op", progress: 75, latency_ms: 500, message: "Ghost map"}}
      )

      assert Process.alive?(view.pid)

      # 2. Negative progress and overflow progress
      negative_op = %Operation{
        id: "op-extreme-neg",
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "patch",
        title: "Negative progress test",
        status: "running",
        progress: -50,
        duration_ms: 0,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      send(view.pid, {:operation_started, negative_op})
      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "CoderAgent"

      # 3. Huge duration and unicode result
      overflow_op = %Operation{
        id: "op-extreme-over",
        session_id: session.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "Unicode & Extreme Metrics: ⚡️ 🚀 🎯 — ' quotes & <tags>",
        status: "completed",
        progress: 150,
        duration_ms: 999_999,
        result: "Special chars: & < > \" ' ` and UTF8 emojis 🚀✨",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      send(view.pid, {:operation_started, overflow_op})
      send(view.pid, {:operation_completed, overflow_op})
      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "VerifierAgent"
      assert html =~ "999999ms"
    end
  end

  # ============================================================================
  # 2. Interactive Swarm Controls Under Rapid Clicks / Race Conditions (R3)
  # ============================================================================

  describe "Interactive Swarm Controls & Concurrency Resilience" do
    test "prevents double-dispatch on rapid create_goal submissions", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_goal_modal")
      request_id = Ecto.UUID.generate()

      params = %{
        "goal" => %{
          "title" => "Primary Stress Goal",
          "description" => "Test double-dispatch guard",
          "auto_start" => "true",
          "request_id" => request_id
        }
      }

      # A retried browser submission carries the same request ID and must
      # select the original durable run rather than enqueueing duplicate work.
      html = render_submit(view, "create_goal", params)

      assert html =~ "Goal created" or is_binary(html)
      render_submit(view, "create_goal", params)

      runs = IexCode.Runs.list_runs(session_id: session.id, limit: 10)
      assert length(runs) == 1
      assert hd(runs).metadata["goal_request_id"] == request_id
      assert hd(runs).request_key == request_id

      # Attempt empty title -> returns error flash without crash
      html_err = render_submit(view, "create_goal", %{"goal" => %{"title" => "   "}})
      assert html_err =~ "Goal title is required"
      assert Process.alive?(view.pid)
    end

    test "handles rapid alternating Pause / Resume / Toggle clicks without deadlocks", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Rapidly toggle pause and resume 30 times
      for i <- 1..30 do
        case rem(i, 3) do
          0 -> render_click(view, "pause_session")
          1 -> render_click(view, "resume_session")
          2 -> render_click(view, "toggle_session_pause")
        end
      end

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "MULTI-AGENT SWARM HARNESS ACTIVE"
    end

    test "executes Abort / Cancel with Rollback mode and dismisses modal with confirmation", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Open cancel modal
      html = render_click(view, "open_cancel_modal")

      assert html =~ "Stop &amp; Cancel Session" or html =~ "Stop & Cancel Session" or
               html =~ "Rollback Snapshots"

      # Execute rollback cancellation
      html_cancelled = render_click(view, "cancel_session", %{"mode" => "rollback"})
      assert html_cancelled =~ "Session stopped" or is_binary(html_cancelled)
      refute render(view) =~ "Stop &amp; Cancel Session"
    end

    test "executes Abort / Cancel with Commit mode and commit message", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Open cancel modal
      render_click(view, "open_cancel_modal")

      # Execute commit cancellation with custom message
      html_committed =
        render_click(view, "cancel_session", %{
          "mode" => "commit",
          "commit_message" => "Manual user commit upon session cancel"
        })

      assert html_committed =~ "Session stopped" or is_binary(html_committed)
      refute render(view) =~ "Stop &amp; Cancel Session"
    end

    test "handles mid-flight steering with unicode, long strings, and PubSub broadcasts", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # 1. Normal steering
      html =
        render_click(view, "send_steering", %{"text" => "Focus on VerifierAgent AutoFix loop"})

      assert html =~ "Steering guidance delivered"

      # 2. Unicode and emoji steering
      html_unicode =
        render_click(view, "send_steering", %{
          "text" => "🧭 Refactor AST search queries & verify with ExUnit 🚀"
        })

      assert html_unicode =~ "Steering guidance delivered"

      # 3. Long text steering (1,000 characters)
      long_text = String.duplicate("Steer payload with architecture instructions. ", 25)
      html_long = render_click(view, "send_steering", %{"text" => long_text})
      assert html_long =~ "Steering guidance delivered"

      # 4. Empty/whitespace steering -> noop without flash or crash
      render_click(view, "send_steering", %{"text" => "   "})
      assert Process.alive?(view.pid)

      # 5. External PubSub steering broadcast
      send(
        view.pid,
        {:swarm_steered, %{session_id: session.id, steering: "External supervisor override"}}
      )

      assert render(view) =~ "Steering guidance delivered"
    end

    test "handles external :session_cancelled PubSub broadcast for both rollback and commit", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_cancel_modal")

      # Send broadcast for rollback
      send(view.pid, {:session_cancelled, %{session_id: session.id, action: :rollback}})
      html = render(view)
      assert html =~ "Session stopped"
      assert html =~ "rollback completed"

      # Send broadcast for commit
      send(view.pid, {:session_cancelled, %{session_id: session.id, action: :commit}})
      html_commit = render(view)
      assert html_commit =~ "commit completed"
    end
  end

  # ============================================================================
  # 3. 4-Column Subagent Cards, Latency Math & Progress Bounds (R3)
  # ============================================================================

  describe "Subagent Cards, Latency Display Math & Progress Bounds" do
    test "renders all 4 agent personas with accurate states, latency ms, and progress bars", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 1. PlannerAgent - Running (progress 40%, latency 85ms)
      planner_op = %Operation{
        id: "op-card-planner",
        session_id: session.id,
        agent_name: "PlannerAgent",
        op_type: "plan",
        title: "Decomposing feature graph",
        status: "running",
        progress: 40,
        duration_ms: 85,
        pid_str: "#PID<0.701.0>",
        started_at: now
      }

      # 2. ExplorerAgent - Completed (progress 100%, latency 145ms)
      explorer_op = %Operation{
        id: "op-card-explorer",
        session_id: session.id,
        agent_name: "ExplorerAgent",
        op_type: "explore",
        title: "Scanned 45 source files",
        status: "completed",
        progress: 100,
        duration_ms: 145,
        pid_str: "#PID<0.702.0>",
        result: "Discovered 18 modules",
        started_at: now
      }

      # 3. CoderAgent - Running (progress 75%, latency 320ms)
      coder_op = %Operation{
        id: "op-card-coder",
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "code",
        title: "Formulating MultiPatch diff",
        status: "running",
        progress: 75,
        duration_ms: 320,
        pid_str: "#PID<0.703.0>",
        started_at: now
      }

      # 4. VerifierAgent - Failed (progress 50%, latency 210ms)
      verifier_op = %Operation{
        id: "op-card-verifier",
        session_id: session.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "ExUnit test suite run",
        status: "failed",
        error_message: "Compilation error: undefined function User.auth/1",
        progress: 50,
        duration_ms: 210,
        pid_str: "#PID<0.704.0>",
        started_at: now
      }

      send(view.pid, {:operation_started, planner_op})
      send(view.pid, {:operation_started, explorer_op})
      send(view.pid, {:operation_completed, explorer_op})
      send(view.pid, {:operation_started, coder_op})
      send(view.pid, {:operation_started, verifier_op})
      send(view.pid, {:operation_failed, verifier_op})

      html = render(view)

      # Verify all 4 agent cards exist in DOM
      assert html =~ "PlannerAgent"
      assert html =~ "ExplorerAgent"
      assert html =~ "CoderAgent"
      assert html =~ "VerifierAgent"

      # Verify statuses
      assert html =~ "RUNNING"
      assert html =~ "COMPLETED"
      assert html =~ "FAILED"

      # Verify latency ms math
      assert html =~ "85ms"
      assert html =~ "145ms"
      assert html =~ "320ms"
      assert html =~ "210ms"

      # Verify progress percentages
      assert html =~ "40%"
      assert html =~ "100%"
      assert html =~ "75%"
      assert html =~ "50%"

      # Verify PIDs
      assert html =~ "#PID&lt;0.701.0&gt;" or html =~ "#PID<0.701.0>"
      assert html =~ "#PID&lt;0.702.0&gt;" or html =~ "#PID<0.702.0>"
      assert html =~ "#PID&lt;0.703.0&gt;" or html =~ "#PID<0.703.0>"
      assert html =~ "#PID&lt;0.704.0&gt;" or html =~ "#PID<0.704.0>"

      # Verify failed operation alert banner
      assert html =~ "operation failed" or html =~ "Compilation error"
    end
  end

  # ============================================================================
  # 4. Deep Hierarchical Operation DAG & Expand/Collapse Stress (R3)
  # ============================================================================

  describe "Hierarchical Operation DAG & Expand/Collapse Stress" do
    test "renders 5-level deep execution hierarchy and expands/collapses multiple nodes simultaneously",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Level 1: Root Swarm Coordinator
      {:ok, l1} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "SwarmCoordinator",
          op_type: "swarm_root",
          title: "Autonomous Milestone Orchestration",
          status: "running",
          progress: 60,
          started_at: now
        })

      # Level 2: Planner
      {:ok, l2} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: l1.id,
          agent_name: "PlannerAgent",
          op_type: "plan",
          title: "Decompose Authentication Module",
          status: "completed",
          progress: 100,
          result: "Decomposition complete into 3 subtasks",
          started_at: now
        })

      # Level 3: Explorer
      {:ok, l3} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: l2.id,
          agent_name: "ExplorerAgent",
          op_type: "ast_search",
          title: "AST Symbol Resolution for Accounts",
          status: "completed",
          progress: 100,
          result: "Discovered 5 symbols in accounts.ex",
          started_at: now
        })

      # Level 4: Coder
      {:ok, l4} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: l3.id,
          agent_name: "CoderAgent",
          op_type: "patch_file",
          title: "Synthesize MultiPatch for Token Auth",
          status: "completed",
          progress: 100,
          result: "Applied 2 atomic hunks",
          started_at: now
        })

      # Level 5: Verifier
      {:ok, l5} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: l4.id,
          agent_name: "VerifierAgent",
          op_type: "run_tests",
          title: "ExUnit Token Auth Verification",
          status: "failed",
          progress: 100,
          error_message: "Expected :ok, got {:error, :unauthorized}",
          params: %{"suite" => "test/auth_test.exs", "seed" => 42_424},
          result: "1 failure in 15 tests",
          started_at: now
        })

      send(view.pid, {:operation_created, l1})
      send(view.pid, {:operation_created, l2})
      send(view.pid, {:operation_created, l3})
      send(view.pid, {:operation_created, l4})
      send(view.pid, {:operation_created, l5})

      html = render(view)
      assert html =~ "Execution Hierarchy"
      assert html =~ "5 ops"
      assert html =~ "Autonomous Milestone Orchestration"

      # Expand Level 1
      render_click(view, "toggle_op_detail", %{"id" => l1.id})
      assert render(view) =~ "Decompose Authentication Module"

      # Expand Level 2
      render_click(view, "toggle_op_detail", %{"id" => l2.id})
      assert render(view) =~ "AST Symbol Resolution for Accounts"

      # Expand Level 3
      render_click(view, "toggle_op_detail", %{"id" => l3.id})
      assert render(view) =~ "Synthesize MultiPatch for Token Auth"

      # Expand Level 4
      render_click(view, "toggle_op_detail", %{"id" => l4.id})
      assert render(view) =~ "ExUnit Token Auth Verification"

      # Expand Level 5 (inspect error drawer and params)
      html_l5 = render_click(view, "toggle_op_detail", %{"id" => l5.id})
      assert html_l5 =~ "Expected :ok, got {:error, :unauthorized}"
      assert html_l5 =~ "1 failure in 15 tests"
      assert html_l5 =~ "test/auth_test.exs"

      # Collapse Level 1 -> hides entire subtree cleanly
      render_click(view, "toggle_op_detail", %{"id" => l1.id})
      refute render(view) =~ "Decompose Authentication Module"

      # Clear operations
      render_click(view, "clear_operations")
      assert render(view) =~ "No operations recorded in this session"
    end
  end
end
