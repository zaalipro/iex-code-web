defmodule IexCodeWeb.WorkspaceLiveM3M4Test do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  alias IexCode.{Sessions, Kanban}
  alias IexCode.Engine.SessionServer

  setup %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    # Create a test file in the workspace
    test_file_path = Path.join(path, "lib/demo_worker.ex")
    File.mkdir_p!(Path.dirname(test_file_path))
    File.write!(test_file_path, "defmodule DemoWorker do\n  def work, do: :ok\nend\n")

    # Commit a git baseline BEFORE mounting so the Changes tab can render real
    # `git diff` hunks, then modify the file to produce uncommitted changes
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["config", "user.name", "IexCode Test"], cd: path)
    System.cmd("git", ["config", "user.email", "test@iexcode.local"], cd: path)
    System.cmd("git", ["add", "."], cd: path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)
    File.write!(test_file_path, "defmodule DemoWorker do\n  def work, do: :modified\nend\n")

    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    {:ok,
     conn: conn, project: project, session: session, view: view, html: html, workspace_path: path}
  end

  # ============================================================================
  # Milestone 3: Interactive Inline Code Editor Tests
  # ============================================================================

  describe "Interactive Inline Code Editor" do
    test "opens file in editor, manages multiple open buffers and dirty state", %{
      view: view,
      workspace_path: path
    } do
      # 1. Switch to Files view
      view |> element("#instrument-card-files") |> render_click()

      # 2. Select file
      view
      |> element("button[phx-click='select_file'][phx-value-path='lib/demo_worker.ex']")
      |> render_click()

      html = render(view)
      assert html =~ "lib/demo_worker.ex"
      assert html =~ "defmodule DemoWorker"
      assert has_element?(view, "#code-editor-viewport")

      # 3. Simulate content modification (dirty state)
      new_code = "defmodule DemoWorker do\n  def work, do: :modified_result\nend\n"
      html = render_hook(view, "file_content_changed", %{"content" => new_code})

      assert html =~ "Unsaved Changes"
      assert has_element?(view, "button[phx-click='save_file']")
      assert has_element?(view, "button[phx-click='revert_file_buffer']")

      # 4. Save file to disk
      render_hook(view, "save_file", %{"content" => new_code})

      saved_disk_content = File.read!(Path.join(path, "lib/demo_worker.ex"))
      assert saved_disk_content == new_code
      refute render(view) =~ "● Unsaved Changes"

      # 5. Revert unsaved edits test
      render_hook(view, "file_content_changed", %{"content" => "temporary broken code"})
      assert render(view) =~ "Unsaved Changes"

      view |> element("button[phx-click='revert_file_buffer']") |> render_click()
      refute render(view) =~ "temporary broken code"
      assert render(view) =~ "def work, do: :modified_result"

      # 6. Close buffer
      view
      |> element("button[phx-click='close_file_buffer'][phx-value-path='lib/demo_worker.ex']")
      |> render_click()

      assert render(view) =~ "Select a workspace file on the left to preview contents"
    end
  end

  # ============================================================================
  # Milestone 3: Interactive Diff Viewer & Hunk Actions Tests
  # ============================================================================

  describe "Interactive Diff Viewer & Granular Hunk Ops" do
    test "renders diff hunks with per-hunk action buttons and toggles display modes", %{
      view: view
    } do
      # 1. Switch to Changes view
      view |> element("#instrument-card-changes") |> render_click()

      html = render(view)
      assert html =~ "lib/demo_worker.ex"
      assert html =~ "Hunk hunk-1"
      assert has_element?(view, "button[phx-click='accept_hunk']")
      assert has_element?(view, "button[phx-click='reject_hunk']")
      assert has_element?(view, "button[phx-click='revert_hunk']")
      assert has_element?(view, "button[phx-click='accept_all_hunks']")
      assert has_element?(view, "button[phx-click='revert_file']")

      # 2. Toggle Side-by-Side (Split) mode
      view
      |> element("button[phx-click='set_diff_mode'][phx-value-mode='split']")
      |> render_click()

      assert render(view) =~ "Original"
      assert render(view) =~ "Modified"

      # 3. Toggle Inline mode
      view
      |> element("button[phx-click='set_diff_mode'][phx-value-mode='inline']")
      |> render_click()

      refute render(view) =~ "Original\n"

      # 4. Trigger accept hunk
      render_click(view, "accept_hunk", %{
        "file" => "lib/demo_worker.ex",
        "hunk_id" => "hunk-1"
      })

      # Verify LiveView process survives and updates flash / status
      assert Process.alive?(view.pid)

      # 5. Trigger reject hunk
      render_click(view, "reject_hunk", %{
        "file" => "lib/demo_worker.ex",
        "hunk_id" => "hunk-1"
      })

      assert Process.alive?(view.pid)

      # 6. Trigger revert file
      render_click(view, "revert_file", %{"file" => "lib/demo_worker.ex"})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # Milestone 4: Goal Lifecycle, Pause/Resume & Steering UI Tests
  # ============================================================================

  describe "Goal Lifecycle & Steering Controls" do
    test "creates autonomous goal as a durable run via modal form", %{
      view: view,
      session: session
    } do
      # 1. Switch to Swarm tab & open goal modal
      view |> element("#instrument-card-swarm") |> render_click()

      render_change(view, "update_run_setup", %{
        "run_setup" => %{
          "priority" => "high",
          "max_attempts" => "5",
          "time_budget_minutes" => "45",
          "token_budget" => "12000",
          "cost_budget_cents" => "750"
        }
      })

      assert has_element?(view, "#new-goal-button")
      view |> element("#new-goal-button") |> render_click()

      assert has_element?(view, "#goal-modal")
      assert has_element?(view, "#goal-modal-submit")
      assert has_element?(view, "#goal-modal-cancel")
      assert has_element?(view, "#goal-run-policy-summary")
      assert has_element?(view, "#goal-policy-priority", "High")
      assert has_element?(view, "#goal-policy-max-attempts", "5")
      assert has_element?(view, "#goal-policy-time-budget", "45 min")
      assert has_element?(view, "#goal-policy-token-budget", "12000")
      assert has_element?(view, "#goal-policy-cost-budget", "$7.50")

      # 2. Submit goal form
      html =
        render_submit(view, "create_goal", %{
          "goal" => %{
            "title" => "Build end-to-end telemetry pipeline",
            "description" => "Ensure latency and token counting are verified",
            "auto_start" => "true"
          }
        })

      refute render(view) =~ "Create Autonomous Goal"
      assert html =~ "Goal created and queued as a durable multi-agent run"

      [run] = IexCode.Runs.list_runs(session_id: session.id, limit: 10)
      assert run.kind == "coding_swarm"
      assert run.mode == "swarm"
      assert run.status == "queued"
      assert run.priority == "high"
      assert run.max_attempts == 5
      assert run.time_budget_ms == 2_700_000
      assert run.token_budget == 12_000
      assert run.cost_budget_cents == 750
      assert run.metadata["source"] == "autonomous_goal"
      assert run.metadata["goal_title"] == "Build end-to-end telemetry pipeline"
      assert run.metadata["goal_description"] == "Ensure latency and token counting are verified"
      assert is_binary(run.request_key)

      assert run.objective =~ "Build end-to-end telemetry pipeline"
      assert run.objective =~ "Ensure latency and token counting are verified"
    end

    test "starts a selected durable draft through its state-specific action", %{
      view: view,
      session: session
    } do
      start_run_dispatcher!()
      render_click(view, "switch_tab", %{"tab" => "swarm"})
      view |> element("#mission-control-mode-execution") |> render_click()
      render_click(view, "open_goal_modal")

      view
      |> form("#goal-create-form", %{
        "goal" => %{
          "title" => "Start this draft",
          "description" => "Exercise the explicit draft lifecycle",
          "auto_start" => "false"
        }
      })
      |> render_submit()

      [draft] = IexCode.Runs.list_runs(session_id: session.id, limit: 10)

      assert has_element?(view, "#async-run-#{draft.id}[data-run-status='draft']")
      assert has_element?(view, "#async-run-detail[data-run-status='draft']")
      assert has_element?(view, "#run-agent-fleet-empty", "Draft has not started")
      assert has_element?(view, "#run-agent-fleet-empty", "No worker instances are created")

      assert has_element?(
               view,
               "#start-async-run[phx-click='start_async_run'][phx-disable-with='Starting…']",
               "Start"
             )

      refute has_element?(view, "#resume-async-run")

      view |> element("#start-async-run") |> render_click()

      assert has_element?(view, "#flash-info", "Draft queued for execution")
      refute has_element?(view, "#async-run-detail[data-run-status='draft']")
      refute IexCode.Runs.get_run!(draft.id).status == "draft"
    end

    test "cancels a selected draft without implying execution rollback", %{
      view: view,
      session: session
    } do
      start_run_dispatcher!()
      render_click(view, "switch_tab", %{"tab" => "swarm"})
      view |> element("#mission-control-mode-execution") |> render_click()
      render_click(view, "open_goal_modal")

      view
      |> form("#goal-create-form", %{
        "goal" => %{
          "title" => "Cancel this draft",
          "description" => "This goal has not started",
          "auto_start" => "false"
        }
      })
      |> render_submit()

      [draft] = IexCode.Runs.list_runs(session_id: session.id, limit: 10)

      assert has_element?(
               view,
               "#cancel-async-run[data-confirm='Cancel this draft? It will be marked cancelled without starting any work.'][phx-disable-with='Cancelling…']"
             )

      view |> element("#cancel-async-run") |> render_click()

      assert has_element?(view, "#flash-info", "Draft cancelled")
      assert has_element?(view, "#async-run-#{draft.id}[data-run-status='cancelled']")
      assert has_element?(view, "#async-run-detail[data-run-status='cancelled']")
      refute has_element?(view, "#start-async-run")
      assert IexCode.Runs.get_run!(draft.id).status == "cancelled"
    end

    test "unchecked auto-start creates a durable draft without dispatching it", %{
      view: view,
      session: session
    } do
      render_click(view, "open_goal_modal")

      assert has_element?(
               view,
               "#goal-create-form input[type='hidden'][name='goal[auto_start]'][value='false']"
             )

      render_submit(view, "create_goal", %{
        "goal" => %{
          "title" => "Draft reliability goal",
          "description" => "Keep the complete description for later"
        }
      })

      [draft] = IexCode.Runs.list_runs(session_id: session.id, limit: 10)
      assert draft.status == "draft"
      assert draft.attempt == 0
      assert draft.lease_owner == nil
      assert draft.metadata["source"] == "autonomous_goal"
      assert is_binary(draft.request_key)
      assert draft.objective =~ "Draft reliability goal"
      assert draft.objective =~ "Keep the complete description for later"
    end

    test "the same goal request submitted twice selects one durable run", %{
      view: view,
      session: session
    } do
      request_key = Ecto.UUID.generate()

      params = %{
        "goal" => %{
          "title" => "Retry-safe goal",
          "description" => "Never duplicate this durable execution",
          "auto_start" => "true",
          "request_id" => request_key
        }
      }

      render_click(view, "open_goal_modal")
      render_submit(view, "create_goal", params)
      render_submit(view, "create_goal", params)

      assert [run] = IexCode.Runs.list_runs(session_id: session.id, limit: 10)
      assert run.request_key == request_key
      assert run.metadata["goal_title"] == "Retry-safe goal"
      assert run.metadata["goal_description"] == "Never duplicate this durable execution"
    end

    test "pauses, resumes, and cancels active session execution", %{
      view: view,
      session: session
    } do
      # 1. Switch to Swarm tab
      view |> element("#instrument-card-swarm") |> render_click()
      view |> element("#mission-control-mode-execution") |> render_click()
      assert has_element?(view, "#mission-control-panel-execution:not([hidden])")

      # Start a real interactive coordinator so the rendered pause control is
      # backed by an active session owner rather than an event-only shortcut.
      assert :ok = SessionServer.send_prompt(session.id, "/swarm Hold this session open")
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#mission-control-panel-execution button[phx-click='pause_session']"
             )

      assert has_element?(
               view,
               "#mission-control-panel-execution button[phx-click='open_cancel_modal']"
             )

      assert has_element?(
               view,
               "#mission-control-panel-execution #steering-form[phx-submit='send_steering']"
             )

      # 2. Pause session
      view
      |> element("#mission-control-panel-execution button[phx-click='pause_session']")
      |> render_click()

      assert has_element?(view, "#interactive-session-status", "Session status · PAUSED")

      assert has_element?(
               view,
               "#mission-control-panel-execution button[phx-click='resume_session']"
             )

      # 3. Resume session. The mock coordinator may finish before this render;
      # either durable RUNNING or the safe IDLE terminal race must agree with
      # the state-specific control shown next.
      view
      |> element("#mission-control-panel-execution button[phx-click='resume_session']")
      |> render_click()

      resumed_status = Sessions.get_session!(session.id).status
      assert resumed_status in ["running", "idle"]

      case resumed_status do
        "running" ->
          assert has_element?(view, "#interactive-session-status", "Session status · RUNNING")

          assert has_element?(
                   view,
                   "#mission-control-panel-execution button[phx-click='pause_session']"
                 )

        "idle" ->
          assert has_element?(view, "#interactive-session-status", "Session status · IDLE")

          assert has_element?(
                   view,
                   "#mission-control-panel-execution button[phx-click='resume_session']"
                 )
      end

      # 4. Open cancel modal
      view
      |> element("#mission-control-panel-execution button[phx-click='open_cancel_modal']")
      |> render_click()

      assert has_element?(view, "#cancel-session-modal[role='dialog'][aria-modal='true']")
      assert has_element?(view, "#cancel-session-modal-title", "Stop & Cancel Session")

      assert has_element?(
               view,
               "#cancel-session-modal button[phx-click='cancel_session'][phx-value-mode='rollback']",
               "Rollback Snapshots"
             )

      assert has_element?(
               view,
               "#cancel-session-modal button[phx-click='cancel_session'][phx-value-mode='commit']",
               "Commit Changes"
             )

      # 5. Cancel with rollback
      view
      |> element(
        "#cancel-session-modal button[phx-click='cancel_session'][phx-value-mode='rollback']"
      )
      |> render_click()

      refute has_element?(view, "#cancel-session-modal")
      assert has_element?(view, "#flash-info", "Session stopped")
    end

    test "delivers real-time steering directive to active swarm", %{view: view} do
      view |> element("#instrument-card-swarm") |> render_click()
      view |> element("#mission-control-mode-execution") |> render_click()

      view
      |> form("#steering-form", %{"steering" => "Focus on AST parser error recovery"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "Steering guidance delivered")
      assert has_element?(view, "#session-steering-input[value='']")
    end
  end

  # ============================================================================
  # Milestone 4: Dead Button Elimination & UI Controls Audit Tests
  # ============================================================================

  describe "UI Control Actions & Dead Button Elimination" do
    test "switches calendar months and dates", %{view: view} do
      view |> element("#instrument-card-calendar") |> render_click()

      # Next month
      render_click(view, "calendar_next_month")
      assert render(view) =~ "September, 2026"

      # Prev month back to August
      render_click(view, "calendar_prev_month")
      assert render(view) =~ "August, 2026"
    end

    test "modifies task priority and assignee from Task Drawer", %{
      view: view,
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Drawer Test Task",
          status: "ready",
          priority: "low",
          assignee: "default"
        })

      # Open drawer
      render_click(view, "switch_tab", %{"tab" => "kanban"})
      render_click(view, "open_task_drawer", %{"id" => task.id})
      assert render(view) =~ "Drawer Test Task"

      # Update priority to critical
      render_click(view, "update_task_priority", %{"id" => task.id, "priority" => "critical"})
      updated = Kanban.get_task!(task.id)
      assert updated.priority == "critical"

      # Update assignee to verifier
      render_click(view, "update_task_assignee", %{"id" => task.id, "assignee" => "verifier"})
      updated = Kanban.get_task!(task.id)
      assert updated.assignee == "verifier"

      # Delete task
      render_click(view, "delete_task", %{"id" => task.id})
      assert Kanban.get_task!(task.id)
      assert has_element?(view, "[id^='task-delete-confirmation-']")
      render_click(view, "confirm_task_delete")
      assert Kanban.get_task(task.id) == nil
    end

    test "toggles prompt bar tool pills while retired usage modal stays absent", %{view: view} do
      # Toggle tool pills
      render_click(view, "toggle_tool", %{"tool" => "ast_search"})
      render_click(view, "toggle_tool", %{"tool" => "swarm"})

      refute has_element?(view, "#all-usage-modal")
    end

    test "executes terminal commands, handles replay and stop", %{view: view} do
      view |> element("#instrument-card-terminal") |> render_click()

      # Execute terminal command
      view
      |> form("#terminal-form", %{"command" => "echo 'hello terminal runner'"})
      |> render_submit()

      assert Process.alive?(view.pid)

      # Replay command
      render_click(view, "replay_terminal_command")
      assert Process.alive?(view.pid)

      # Stop terminal command
      render_click(view, "stop_terminal_command")
      assert Process.alive?(view.pid)
    end

    test "renders thinking traces with collapsible disclosure and markdown", %{
      view: view,
      session: session
    } do
      # Switch to chat tab
      view |> element("#instrument-card-chat") |> render_click()

      # Simulate message with reasoning
      {:ok, msg} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "assistant",
          agent_name: "PlannerAgent",
          content:
            "<think>Decomposing milestone into 4 parallel tasks.</think>\n\n### Execution Strategy\nProceeding with task execution.",
          metadata: %{
            "reasoning" => "Decomposing milestone into 4 parallel tasks.",
            "duration_ms" => 125
          }
        })

      # Send PubSub broadcast
      Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{session.id}", {:message_created, msg})

      # Trigger render
      html = render(view)
      assert html =~ "Thought Process (Reasoning Trace)"
      assert html =~ "Decomposing milestone into 4 parallel tasks."
      assert html =~ "Execution Strategy"

      # Expand message modal
      render_click(view, "expand_message", %{"id" => msg.id})
      assert render(view) =~ "Execution Strategy"
      assert has_element?(view, "#copy-expanded-msg-btn")

      # Close expanded modal
      render_click(view, "close_expand_message")
      refute render(view) =~ "copy-expanded-msg-btn"
    end
  end

  defp start_run_dispatcher! do
    start_supervised!(
      {IexCode.Runs.RunDispatcher,
       name: IexCode.Runs.RunDispatcher,
       worker_id: "workspace-goal-ui-test-#{System.unique_integer([:positive])}",
       executor: IexCode.RunDispatcherTestExecutor,
       max_concurrency: 1,
       poll_interval: 60_000,
       heartbeat_interval: 60_000,
       lease_ms: 120_000,
       workspace_lock_retry_interval: 60_000,
       workspace_lock_lease_seconds: 120}
    )
  end
end
