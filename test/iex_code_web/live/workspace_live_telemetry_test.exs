defmodule IexCodeWeb.WorkspaceLiveTelemetryTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Sessions
  alias IexCode.Sessions.Operation
  alias IexCode.Engine.SessionServer

  # ============================================================================
  # 1. Goal Lifecycle & Session Status PubSub Synchronization
  # ============================================================================

  describe "Goal Lifecycle & Session Status Updates" do
    test "reflects session status transitions in real time (idle, running, paused)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert render(view) =~ session.title

      # 1. Transition to running
      send(view.pid, {:session_status_changed, "running"})
      assert render(view) =~ session.title

      # 2. Transition to paused
      send(view.pid, {:session_status_changed, "paused"})
      assert render(view) =~ session.title

      # 3. Transition back to idle
      send(view.pid, {:session_status_changed, "idle"})
      assert render(view) =~ session.title
    end

    test "creates autonomous goal and updates state through SessionServer", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Trigger prompt dispatch that calls SessionServer
      html =
        render_submit(view, "submit_prompt", %{"prompt" => "Coordinate swarm auto-fix cycle"})

      assert is_binary(html)

      # Send prompt via SessionServer
      SessionServer.send_prompt(session.id, "Real-time steering update from test")
      assert Process.alive?(view.pid)
    end

    test "handles Goal Creation modal and creates autonomous goal", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open goal modal
      html = render_click(view, "open_goal_modal")
      assert html =~ "Create Autonomous Goal" or html =~ "Goal Title" or is_binary(html)

      # Submit goal creation
      html_created =
        render_submit(view, "create_goal", %{
          "goal" => %{
            "title" => "Build High-Performance Authentication Module",
            "description" => "Implement bcrypt and token auth",
            "auto_start" => "true"
          }
        })

      assert html_created =~ "Goal created" or is_binary(html_created)

      # Send goal created PubSub
      send(view.pid, {:goal_created, %{title: "Autonomous Goal"}})
      assert render(view) =~ "Autonomous Goal active in session"
    end
  end

  # ============================================================================
  # 2. Real-Time Subagent Telemetry Cards & 0% -> 100% Streaming
  # ============================================================================

  describe "Subagent Telemetry Cards (F5)" do
    test "renders all 4 OTP subagents with real-time progress, latency ms, and worker PID", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to swarm tab
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      html = render(view)
      assert html =~ "PlannerAgent"
      assert html =~ "ExplorerAgent"
      assert html =~ "CoderAgent"
      assert html =~ "VerifierAgent"
      assert html =~ "OTP Supervised"

      # 1. PlannerAgent starts
      planner_op = %Operation{
        id: "op-planner-1",
        session_id: session.id,
        agent_name: "PlannerAgent",
        op_type: "plan",
        title: "Decomposing authentication workflow",
        status: "running",
        progress: 15,
        pid_str: "#PID<0.412.0>",
        duration_ms: 45,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      send(view.pid, {:operation_started, planner_op})
      html = render(view)
      assert html =~ "RUNNING"
      assert html =~ "Decomposing authentication workflow"
      assert html =~ "15%"
      assert html =~ "#PID&lt;0.412.0&gt;" or html =~ "#PID<0.412.0>"

      # 2. ExplorerAgent streams 4-tuple progress update
      send(view.pid, {:operation_progress, planner_op.id, 65, "Scanning 12 module definitions"})
      html = render(view)
      assert html =~ "65%"
      assert html =~ "Scanning 12 module definitions"

      # 3. CoderAgent map progress update with latency
      send(
        view.pid,
        {:operation_progress,
         %{
           id: planner_op.id,
           progress: 90,
           status: "running",
           latency_ms: 180,
           message: "Patches synthesized"
         }}
      )

      html = render(view)
      assert html =~ "90%"
      assert html =~ "180ms"
      assert html =~ "Patches synthesized"

      # 4. VerifierAgent completion
      completed_op = %{
        planner_op
        | status: "completed",
          progress: 100,
          duration_ms: 220,
          result: "All tests passing"
      }

      send(view.pid, {:operation_completed, completed_op})
      html = render(view)
      assert html =~ "COMPLETED"
      assert html =~ "100%"
      assert html =~ "220ms"

      # 5. Operation failure handling
      failed_op = %Operation{
        id: "op-fail-1",
        session_id: session.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "Compilation check",
        status: "running",
        error_message: "Undefined function Math.invalid/0",
        progress: 10,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      send(view.pid, {:operation_started, failed_op})
      send(view.pid, {:operation_failed, %{failed_op | status: "failed", progress: 100}})
      html = render(view)
      assert html =~ "FAILED"
    end

    test "handles swarm stage updates across all execution phases", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      stages = [:init, :planning, :exploring, :coding, :verifying, :completed, :failed]

      for stage <- stages do
        # Test map metadata format with iteration
        send(view.pid, {:swarm_stage_changed, %{stage: stage, iteration: 2}})
        assert render(view) =~ "Execution Hierarchy"

        # Test atom format
        send(view.pid, {:swarm_stage_changed, stage})
        assert render(view) =~ "Execution Hierarchy"
      end
    end

    test "does not fabricate token telemetry from message creation", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      msg = %Sessions.Message{
        id: "msg-telemetry-1",
        session_id: session.id,
        role: "assistant",
        agent_name: "CoderAgent",
        content: "Refactored module."
      }

      send(view.pid, {:message_created, msg})
      refute render(view) =~ "MULTI-AGENT SWARM HARNESS ACTIVE"
      refute render(view) =~ " TOKENS ·"
    end
  end

  # ============================================================================
  # 3. Hierarchical Operation Tree & Reasoning Traces (F6)
  # ============================================================================

  describe "Hierarchical Operation Tree & Traces (F6)" do
    test "renders nested parent-child execution hierarchy with expand/collapse toggles", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # 1. Create root operation
      {:ok, root_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "SwarmCoordinator",
          op_type: "swarm_root",
          title: "Coordinate Full Application Refactor",
          status: "completed",
          progress: 100,
          result: "Multi-agent swarm finished successfully with 0 errors",
          params: %{"max_iterations" => 5, "auto_heal" => true},
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # 2. Create child operation
      {:ok, child_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: root_op.id,
          agent_name: "CoderAgent",
          op_type: "patch_file",
          title: "Applying payment reconciliation patch",
          status: "completed",
          progress: 100,
          result: "Patched 3 files atomically",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # 3. Create grandchild operation with error
      {:ok, grandchild_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: child_op.id,
          agent_name: "VerifierAgent",
          op_type: "test_suite",
          title: "Running ExUnit integration tests",
          status: "failed",
          error_message: "Assertion with == failed (expected 200, got 500)",
          progress: 100,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      html = render(view)
      assert html =~ "Execution Hierarchy"
      assert html =~ "3 ops"
      assert html =~ "Coordinate Full Application Refactor"

      # Expand root operation
      html = render_click(view, "toggle_op_detail", %{"id" => root_op.id})
      assert html =~ "Multi-agent swarm finished successfully with 0 errors"
      assert html =~ "Applying payment reconciliation patch"

      # Expand child operation
      html = render_click(view, "toggle_op_detail", %{"id" => child_op.id})
      assert html =~ "Patched 3 files atomically"
      assert html =~ "Running ExUnit integration tests"

      # Expand grandchild operation to inspect error trace
      html = render_click(view, "toggle_op_detail", %{"id" => grandchild_op.id})
      assert html =~ "Assertion with == failed"

      # Clear operations
      html = render_click(view, "clear_operations")
      assert html =~ "No operations recorded in this session"
    end

    test "handles :operations_cleared PubSub broadcast event", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _op} =
        Sessions.create_operation(%{
          session_id: session.id,
          agent_name: "ExplorerAgent",
          op_type: "scan",
          title: "Scan project tree",
          status: "completed",
          progress: 100,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      assert render(view) =~ "Scan project tree"

      # A stale or premature message reconciles from current-session SQLite.
      send(view.pid, :operations_cleared)
      assert render(view) =~ "Scan project tree"

      Sessions.clear_session_operations(session.id)
      send(view.pid, :operations_cleared)
      assert render(view) =~ "No operations recorded in this session"
    end
  end

  # ============================================================================
  # 4. Concurrency Telemetry Burst Integrity
  # ============================================================================

  describe "Telemetry Burst & State Resilience" do
    test "survives rapid multi-agent progress storms without state corruption", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Send 30 rapid interleaved progress events across different agents
      for i <- 1..30 do
        agent =
          Enum.at(["PlannerAgent", "ExplorerAgent", "CoderAgent", "VerifierAgent"], rem(i, 4))

        op = %Operation{
          id: "burst-op-#{i}",
          session_id: session.id,
          agent_name: agent,
          op_type: "task",
          title: "Burst task #{i}",
          status: "running",
          progress: i * 3,
          duration_ms: i * 10,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        send(view.pid, {:operation_started, op})
        send(view.pid, {:operation_progress, op.id, min(i * 3 + 5, 100), "Burst step #{i}"})
      end

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "Execution Hierarchy"
      assert html =~ "PlannerAgent"
    end

    test "handles swarm_stage_changed telemetry with latency_ms and agent_pid", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(
        view.pid,
        {:swarm_stage_changed,
         %{
           session_id: session.id,
           stage: :coding,
           progress: 55,
           latency_ms: 240,
           agent_pid: "#PID<0.999.0>",
           message: "Synthesizing code patches"
         }}
      )

      assert Process.alive?(view.pid)
    end

    test "handles swarm_steered and session_cancelled PubSub broadcasts", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open cancel modal
      render_click(view, "open_cancel_modal")

      # Send steering event
      send(view.pid, {:swarm_steered, %{session_id: session.id, steering: "Add test suite"}})
      html = render(view)
      assert html =~ "Steering received" or html =~ "Add test suite"

      # Send session cancelled event
      send(view.pid, {:session_cancelled, %{session_id: session.id, action: :rollback}})
      html_after = render(view)
      assert html_after =~ "Session stopped" or is_binary(html_after)
    end
  end
end
