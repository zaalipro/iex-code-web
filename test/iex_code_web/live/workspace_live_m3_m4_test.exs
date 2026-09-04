defmodule IexCodeWeb.WorkspaceLiveM3M4Test do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  alias IexCode.{Kanban, Runs, Sessions}
  alias IexCode.Tools.TerminalServer

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
      render_hook(view, "file_content_changed", %{"content" => new_code})

      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")
      assert has_element?(view, ".sf-file-atlas-dirty", "Unsaved changes")
      assert has_element?(view, "#save-file-btn[phx-click='save_file']")
      assert has_element?(view, "#file-buffer-revert-trigger")

      # 4. Save file to disk
      view |> element("#save-file-btn") |> render_click()

      saved_disk_content = File.read!(Path.join(path, "lib/demo_worker.ex"))
      assert saved_disk_content == new_code
      assert has_element?(view, "#files-buffer-signal", "Saved")
      refute has_element?(view, ".sf-file-atlas-dirty")

      # 5. Revert unsaved edits test
      render_hook(view, "file_content_changed", %{"content" => "temporary broken code"})
      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")

      view |> element("#file-buffer-revert-trigger") |> render_click()

      assert has_element?(
               view,
               "#file-buffer-revert-confirmation-dialog[role='dialog'][aria-modal='true']",
               "Revert unsaved changes?"
             )

      view |> element("#confirm-file-confirmation", "Revert changes") |> render_click()
      assert has_element?(view, "#files-buffer-signal", "Saved")
      assert has_element?(view, "#code-editor-textarea", "def work, do: :modified_result")
      refute has_element?(view, "#code-editor-textarea", "temporary broken code")

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

      assert has_element?(
               view,
               "#reject-hunk-trigger-hunk-1[phx-click='request_discard_git_hunk']"
             )

      assert has_element?(
               view,
               "#revert-hunk-trigger-hunk-1[phx-click='request_revert_git_hunk']"
             )

      assert has_element?(view, "button[phx-click='accept_all_hunks']")
      assert has_element?(view, "#git-file-revert-trigger[phx-click='request_revert_git_file']")

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

      assert has_element?(view, "[phx-click='select_diff_file'][phx-value-scope='staged']")
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

    test "pauses, resumes, and cancels the selected durable execution", %{
      view: view,
      project: project,
      session: session
    } do
      Process.register(self(), IexCode.RunDispatcherTestReceiver)

      on_exit(fn ->
        if Process.whereis(IexCode.RunDispatcherTestReceiver) == self(),
          do: Process.unregister(IexCode.RunDispatcherTestReceiver)
      end)

      start_run_dispatcher!()

      {:ok, run} =
        Runs.create_run_with_steps(
          %{
            project_id: project.id,
            session_id: session.id,
            objective: "Exercise selected mission lifecycle controls",
            kind: "analysis",
            mode: "single",
            status: "queued",
            max_attempts: 3
          },
          [
            %{key: "prepare", kind: "prepare", title: "Prepare mission", status: "ready"},
            %{
              key: "execute",
              kind: "execute",
              title: "Execute mission",
              status: "pending",
              position: 1,
              depends_on: ["prepare"]
            }
          ]
        )

      send(Process.whereis(IexCode.Runs.RunDispatcher), :drain)
      _ = :sys.get_state(Process.whereis(IexCode.Runs.RunDispatcher))
      assert_receive {:test_run_started, run_id, _worker_pid}, 2_000
      assert run_id == run.id

      # 1. Switch to the selected run's execution controls.
      view |> element("#instrument-card-swarm") |> render_click()
      view |> element("#mission-control-mode-execution") |> render_click()
      assert has_element?(view, "#mission-control-panel-execution:not([hidden])")
      _ = :sys.get_state(view.pid)

      current_run = Runs.get_run!(run.id)

      assert current_run.status == "running",
             "expected test run to start, got #{current_run.status}: #{inspect(current_run.error_message)} #{inspect(current_run.error_details)}"

      assert has_element?(view, "#async-run-detail[data-run-status='running']")
      assert has_element?(view, "#pause-async-run[phx-click='pause_async_run']", "Pause")

      # 2. Pause the selected durable run and verify the persisted outcome.
      view |> element("#pause-async-run") |> render_click()
      assert Runs.get_run!(run.id).status == "paused"
      assert has_element?(view, "#async-run-detail[data-run-status='paused']")
      assert has_element?(view, "#resume-async-run[phx-click='resume_async_run']", "Resume")

      # 3. Resume the selected durable run and verify its current control.
      view |> element("#resume-async-run") |> render_click()
      assert Runs.get_run!(run.id).status == "running"
      assert has_element?(view, "#async-run-detail[data-run-status='running']")
      assert has_element?(view, "#pause-async-run")

      # 4. Cancellation uses the browser confirmation contract and persists.
      assert has_element?(
               view,
               "#cancel-async-run[phx-click='cancel_async_run'][data-confirm='Cancel this run? Execution will stop after the request is persisted.']",
               "Cancel"
             )

      view |> element("#cancel-async-run") |> render_click()
      assert Runs.get_run!(run.id).status == "cancelled"
      assert has_element?(view, "#async-run-detail[data-run-status='cancelled']")
      refute has_element?(view, "#cancel-async-run")
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

      today = Date.utc_today()
      current_month_str = Calendar.strftime(today, "%B, %Y")

      next_month_date =
        if today.month == 12,
          do: Date.new!(today.year + 1, 1, 1),
          else: Date.new!(today.year, today.month + 1, 1)

      next_month_str = Calendar.strftime(next_month_date, "%B, %Y")

      # Next month
      render_click(view, "calendar_next_month")
      assert render(view) =~ next_month_str

      # Prev month back to current month
      render_click(view, "calendar_prev_month")
      assert render(view) =~ current_month_str
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
      session_id = :sys.get_state(view.pid).socket.assigns.session.id
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")

      # Execute terminal command
      view
      |> form("#terminal-form", %{"command" => "echo 'hello terminal runner'"})
      |> render_submit()

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command: "echo 'hello terminal runner'"}},
                     5_000

      assert has_element?(view, "#btn-terminal-replay:not([disabled])")

      # Replay command
      view |> element("#btn-terminal-replay") |> render_click()

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command: "echo 'hello terminal runner'"}},
                     5_000

      # Interrupt a real foreground process through the visible, confirmed control.
      view |> form("#terminal-form", %{"command" => "sleep 30"}) |> render_submit()
      assert has_element?(view, "#btn-terminal-kill:not([disabled])", "Interrupt")
      view |> element("#btn-terminal-kill") |> render_click()
      assert has_element?(view, "#terminal-interrupt-confirmation-dialog[role='dialog']")
      view |> element("#confirm-terminal-confirmation") |> render_click()

      assert_receive {:terminal_command_completed,
                      %{session_id: ^session_id, command: "sleep 30", exit_code: exit_code}},
                     5_000

      assert exit_code != 0
      assert {:ok, %{active_command_id: nil}} = TerminalServer.get_state(session_id)
      assert has_element?(view, "#flash-info", "Foreground process interrupted")
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
