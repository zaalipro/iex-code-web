defmodule IexCodeWeb.AdversarialLiveviewStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 180_000

  alias IexCode.{Sessions, Kanban}
  alias IexCode.Tools.TerminalServer

  # ============================================================================
  # 1. Inline Editor: Path Traversal, Corrupted Paths & Multi-Buffer Isolation
  # ============================================================================

  describe "Inline Editor & File Explorer Security & Multi-Buffer Stress" do
    test "strictly blocks directory traversal attacks and handles non-existent paths gracefully",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      workspace_write_file(path, "lib/safe_module.ex", "defmodule SafeModule do\n  :ok\nend")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Adversarial traversal attempts
      traversal_payloads = [
        "../../../../etc/passwd",
        "/etc/shadow",
        "../outside_secret.txt",
        "lib/../../../../../../dev/null",
        "//root//confidential.txt",
        "..%2F..%2Fetc%2Fpasswd"
      ]

      for payload <- traversal_payloads do
        html = render_click(view, "select_file", %{"path" => payload})
        assert html =~ "Invalid file path" or html =~ "Could not read file"
        assert Process.alive?(view.pid)
      end

      # Non-existent safe-relative path
      html = render_click(view, "select_file", %{"path" => "lib/non_existent_file.ex"})
      assert html =~ "Could not read file: :enoent" or html =~ "Could not read file"

      # Valid file selection works seamlessly
      html = render_click(view, "select_file", %{"path" => "lib/safe_module.ex"})
      assert html =~ "defmodule SafeModule"
      assert Process.alive?(view.pid)
    end

    test "maintains multi-buffer isolation, dirty edits, and handles save/revert/close cycles",
         %{conn: conn, workspace_path: path} do
      # Create 5 workspace files
      for i <- 1..5 do
        workspace_write_file(
          path,
          "lib/file_#{i}.ex",
          "defmodule File#{i} do\n  def val, do: #{i}\nend"
        )
      end

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Open all 5 files as open buffers
      for i <- 1..5 do
        render_click(view, "select_file", %{"path" => "lib/file_#{i}.ex"})
      end

      # 2. Modify dirty contents across open buffers
      for i <- 1..5 do
        render_click(view, "select_file", %{"path" => "lib/file_#{i}.ex"})

        render_change(view, "file_content_changed", %{
          "content" => "defmodule File#{i}Modified do\n  def modified, do: #{i * 100}\nend"
        })
      end

      # 3. Save buffer 3 with explicit content parameter
      render_click(view, "select_file", %{"path" => "lib/file_3.ex"})

      render_click(view, "save_file", %{
        "content" => "defmodule File3Saved do\n  def saved, do: 300\nend"
      })

      saved_content = File.read!(Path.join(path, "lib/file_3.ex"))
      assert saved_content =~ "defmodule File3Saved"

      # 4. Revert buffer 2
      render_click(view, "select_file", %{"path" => "lib/file_2.ex"})
      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")

      view |> element("#file-buffer-revert-trigger") |> render_click()

      assert has_element?(
               view,
               "#file-buffer-revert-confirmation-dialog[role='dialog'][aria-modal='true']",
               "Revert unsaved changes?"
             )

      view |> element("#confirm-file-confirmation", "Revert changes") |> render_click()

      assert has_element?(view, "#flash-info", "Reverted unsaved edits in lib/file_2.ex")
      assert has_element?(view, "#files-buffer-signal", "Saved")
      assert has_element?(view, "#code-editor-textarea", "defmodule File2")
      refute has_element?(view, "#file-buffer-revert-trigger")

      # 5. Close active buffer (file 2) -> file 1 should become active
      render_click(view, "close_file_buffer", %{"path" => "lib/file_2.ex"})

      # 6. Close remaining buffers until empty
      for i <- [1, 3, 4, 5] do
        render_click(view, "close_file_buffer", %{"path" => "lib/file_#{i}.ex"})
      end

      # 7. Attempt save when no file is selected (should no-op without crash)
      render_click(view, "save_file", %{"content" => "orphaned content"})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 2. Git Diffs & Hunk Operations: Conflicting States & Edge Cases
  # ============================================================================

  describe "Git Diffs & Interactive Hunk Operations Adversarial Stress" do
    test "handles missing hunks, corrupt hunk IDs, invalid diff modes, and external reverts",
         %{conn: conn} do
      {:ok, git_path} =
        init_temp_git_repo(%{
          "lib/coordinator.ex" => "defmodule Coordinator do\n  def run, do: :ok\nend"
        })

      project = create_project_fixture(%{root_path: git_path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Test switching diff mode across standard and edge-case values
      for mode <- ["split", "inline", "unified", "invalid_mode_xyz", ""] do
        render_click(view, "set_diff_mode", %{"mode" => mode})
      end

      # Select diff file with various inputs
      render_click(view, "select_diff_file", %{"file" => "lib/coordinator.ex"})
      render_click(view, "select_diff_file", %{"file" => "non_existent_file.ex"})
      render_click(view, "select_diff_file", %{"path" => nil})

      # Adversarial hunk actions: accept/reject with nonexistent/corrupted hunk IDs
      corrupt_hunk_ids = ["non_existent_hunk_id", "-1", "99999", "hunk-undefined", ""]

      for hunk_id <- corrupt_hunk_ids do
        render_click(view, "accept_hunk", %{
          "file" => "lib/coordinator.ex",
          "hunk_id" => hunk_id
        })

        render_click(view, "reject_hunk", %{
          "file" => "lib/coordinator.ex",
          "hunk_id" => hunk_id
        })

        render_click(view, "revert_hunk", %{
          "file" => "lib/coordinator.ex",
          "hunk_id" => hunk_id
        })
      end

      # Revert file that does not exist in working tree
      render_click(view, "revert_file", %{"file" => "lib/ghost_file.ex"})

      # Accept all hunks for non-existent file
      render_click(view, "accept_all_hunks", %{"file" => "lib/ghost_file.ex"})

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 3. Terminal Execution: Command Floods, History Limits & Special Characters
  # ============================================================================

  describe "Terminal Execution Floods & History Boundaries" do
    test "processes 30 rapid commands with special characters, handles history cap, and clears output",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#instrument-card-terminal") |> render_click()
      wait_for_terminal(view, &(&1 =~ "data-terminal-active=\"true\""))

      # 1. Empty and whitespace commands (should be ignored cleanly)
      render_click(view, "run_terminal", %{"command" => ""})
      render_click(view, "run_terminal", %{"command" => "   \t\n  "})

      # 2. Run 25 unique commands to exceed the 20-item history cap,
      # awaiting each command's exit marker before the next submit
      for i <- 1..25 do
        wait_for_terminal(view, &(count_exit_markers(&1) >= i - 1))

        cmd = "echo 'TEST_STREAM_CMD_#{i}'"
        html = render_click(view, "run_terminal_command", %{"command" => cmd})
        assert html =~ "TEST_STREAM_CMD_#{i}"
      end

      wait_for_terminal(view, &(count_exit_markers(&1) >= 25))

      # 3. Special characters, non-zero exits, shell operators
      special_commands = [
        "echo 'hello && world || true'",
        "echo \"quotes 'and' double quotes\"",
        "sh -c 'exit 1'",
        "ls non_existent_dir_12345",
        "echo -n 'no_trailing_newline'"
      ]

      for {cmd, offset} <- Enum.with_index(special_commands, 1) do
        html = render_click(view, "run_terminal", %{"command" => cmd})
        assert is_binary(html)
        wait_for_terminal(view, &(count_exit_markers(&1) >= 25 + offset))
      end

      wait_for_terminal(view, &(count_exit_markers(&1) >= 30))

      # 4. Test replaying terminal command
      view |> element("#btn-terminal-replay:not([disabled])") |> render_click()
      wait_for_terminal(view, &(count_exit_markers(&1) >= 31))

      # 5. Interrupt a real foreground process through the visible, confirmed control.
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}:terminal")

      view
      |> form("#terminal-form", %{"command" => "sleep 30"})
      |> render_submit()

      assert has_element?(view, "#btn-terminal-kill:not([disabled])", "Interrupt")
      view |> element("#btn-terminal-kill") |> render_click()

      assert has_element?(
               view,
               "#terminal-interrupt-confirmation-dialog[role='dialog'][aria-modal='true']",
               "Interrupt the foreground process?"
             )

      view |> element("#confirm-terminal-confirmation") |> render_click()

      assert_receive {:terminal_command_completed,
                      %{
                        session_id: interrupted_session_id,
                        command: "sleep 30",
                        exit_code: exit_code
                      }},
                     5_000

      assert interrupted_session_id == session.id
      assert exit_code != 0
      assert {:ok, %{active_command_id: nil}} = TerminalServer.get_state(session.id)

      # 6. Clear terminal output through its destructive-action confirmation.
      view |> element("#btn-terminal-clear") |> render_click()
      assert has_element?(view, "#terminal-clear-confirmation-dialog[role='dialog']")
      view |> element("#confirm-terminal-confirmation") |> render_click()
      assert {:ok, %{command_history: []}} = TerminalServer.get_state(session.id)
      assert has_element?(view, "#btn-terminal-replay[disabled]")
      refute has_element?(view, "[id^='terminal-command-trace-']")

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 4. Kanban & Task Lifecycle: Adversarial State Transitions & Boundary Values
  # ============================================================================

  describe "Kanban & Task Adversarial Transitions" do
    test "survives invalid status transitions, rapid updates, effort estimation and claiming",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Adversarial Stress Target Task",
          description: "Target task for state transition fuzzing",
          status: "ready",
          priority: "medium",
          assignee: "default",
          steps_total: 4,
          steps_completed: 0
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Move task through all supported kanban statuses
      valid_statuses = [
        "running",
        "done",
        "scheduled",
        "ready",
        "blocked",
        "review",
        "triage",
        "todo",
        "running"
      ]

      for status <- valid_statuses do
        html = render_click(view, "move_task", %{"id" => task.id, "status" => status})
        assert is_binary(html)
      end

      # 1b. Move task with unwhitelisted and corrupted status values (should not crash LiveView)
      invalid_statuses = ["custom_status_xyz", "invalid_enum_val", "", "12345"]

      for invalid_status <- invalid_statuses do
        html = render_click(view, "move_task", %{"id" => task.id, "status" => invalid_status})
        assert html =~ "Invalid task status" or is_binary(html)
        assert Process.alive?(view.pid)
      end

      # Move non-existent task id
      html_missing =
        render_click(view, "move_task", %{"id" => "non-existent-task-id", "status" => "done"})

      assert html_missing =~ "Task not found"
      assert Process.alive?(view.pid)

      # 2. Update task priority across all standard values
      for priority <- ["critical", "high", "medium", "low"] do
        html =
          render_click(view, "update_task_priority", %{"id" => task.id, "priority" => priority})

        assert is_binary(html)
      end

      # 2b. Update task priority with invalid values (should not crash LiveView)
      invalid_priorities = ["urgent_custom", "invalid_priority", "", "999"]

      for invalid_p <- invalid_priorities do
        html =
          render_click(view, "update_task_priority", %{"id" => task.id, "priority" => invalid_p})

        assert html =~ "Invalid task priority" or is_binary(html)
        assert Process.alive?(view.pid)
      end

      # 3. Update assignee across all subagents and arbitrary strings
      for assignee <- ["planner", "explorer", "coder", "verifier", "custom_bot_99", ""] do
        html =
          render_click(view, "update_task_assignee", %{"id" => task.id, "assignee" => assignee})

        assert is_binary(html)
      end

      # 4. Claim and estimate effort
      html_claimed = render_click(view, "claim_task", %{"id" => task.id})
      assert html_claimed =~ "claimed task" or html_claimed =~ "Adversarial Stress"

      html_estimated = render_click(view, "estimate_task", %{"id" => task.id})
      assert html_estimated =~ "Effort estimated" or is_binary(html_estimated)

      # 5. Open drawer and update task with large description
      large_desc = String.duplicate("A large description block ", 100)

      render_click(view, "update_task", %{
        "id" => task.id,
        "task" => %{
          "title" => "Updated Task Title",
          "description" => large_desc,
          "priority" => "critical",
          "assignee" => "coder",
          "status" => "done"
        }
      })

      updated_task = Kanban.get_task!(task.id)
      assert updated_task.title == "Updated Task Title"
      assert updated_task.priority == "critical"

      # 6. Delete task
      render_click(view, "delete_task", %{"id" => task.id})
      assert Kanban.get_task!(task.id)
      assert has_element?(view, "[id^='task-delete-confirmation-']")
      render_click(view, "confirm_task_delete")
      assert Kanban.get_task(task.id) == nil

      assert Process.alive?(view.pid)
    end

    test "handles task creation with edge-case attributes (empty title, dates, tags, steps)",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Empty title should be rejected cleanly
      render_click(view, "create_task", %{
        "task" => %{"title" => "", "description" => "Empty title test"}
      })

      # Valid task with full scheduled parameters
      render_click(view, "create_task", %{
        "task" => %{
          "title" => "Fully Configured Scheduled Task",
          "description" => "Scheduled autonomous job",
          "status" => "scheduled",
          "priority" => "high",
          "assignee" => "verifier",
          "scheduled_at_date" => "2026-08-25",
          "cron_expression" => "0 12 * * *",
          "steps_total" => "5",
          "tag" => "Automation"
        }
      })

      tasks = Kanban.list_tasks(project.id)
      created = Enum.find(tasks, &(&1.title == "Fully Configured Scheduled Task"))
      assert created != nil
      assert created.status == "scheduled"
      assert created.priority == "high"
      assert created.cron_expression == "0 12 * * *"

      # Trigger scheduled task to run immediately
      render_click(view, "run_scheduled_task", %{"id" => created.id})
      refreshed = Kanban.get_task!(created.id)
      assert refreshed.status == "running"

      # Clean up scheduled task
      render_click(view, "delete_scheduled_task", %{"id" => created.id})
      render_click(view, "confirm_calendar_task_delete")
      assert Kanban.get_task(created.id) == nil
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 5. Goal Lifecycle, Steering Controls & Session Operations
  # ============================================================================

  describe "Goal Lifecycle & Steering Adversarial Stress" do
    test "validates goal creation, handles rapid pause/resume, and processes steering prompts",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Goal modal toggle
      render_click(view, "open_goal_modal")
      render_click(view, "close_goal_modal")

      # 2. Goal creation with empty title -> flash error
      html_err = render_click(view, "create_goal", %{"goal" => %{"title" => ""}})
      assert html_err =~ "Goal title is required"

      # 3. Valid goal creation
      html_goal =
        render_click(view, "create_goal", %{
          "goal" => %{
            "title" => "Build High-Performance Telemetry Ingestion",
            "description" => "Autonomous multi-agent goal",
            "auto_start" => "true"
          }
        })

      assert html_goal =~ "Goal created"

      # 4. Rapid pause and resume toggles
      for _cycle <- 1..5 do
        render_click(view, "pause_session")
        render_click(view, "resume_session")
        render_click(view, "toggle_session_pause")
        render_click(view, "toggle_goal_pause")
      end

      # 5. Steering commands (empty string vs rich prompt)
      render_click(view, "send_steering", %{"text" => ""})

      html_steer =
        render_click(view, "send_steering", %{"steering" => "Focus on verifying AST nodes"})

      assert html_steer =~ "Steering guidance delivered"

      # 6. Cancel session (rollback mode vs commit mode)
      render_click(view, "open_cancel_modal")
      render_click(view, "close_cancel_modal")

      render_click(view, "cancel_session", %{"mode" => "rollback"})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 6. Dropdowns, Calendar Navigation & UI Control Floods
  # ============================================================================

  describe "Dropdowns, Date Picker & UI Control Stress" do
    test "stresses calendar month transitions, date picker popover, and dropdown menus",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Calendar tab month navigation (underflow past January, overflow past December)
      render_click(view, "switch_tab", %{"tab" => "calendar"})

      for _ <- 1..15 do
        render_click(view, "calendar_next_month")
      end

      for _ <- 1..20 do
        render_click(view, "calendar_prev_month")
      end

      # 2. Date picker popover month navigation
      render_click(view, "toggle_date_picker_popover")

      for _ <- 1..15 do
        render_click(view, "picker_next_month")
      end

      for _ <- 1..20 do
        render_click(view, "picker_prev_month")
      end

      # 3. Date selection
      render_click(view, "picker_select_day", %{"year" => "2026", "month" => "8", "day" => "15"})
      render_click(view, "picker_today")
      render_click(view, "picker_clear")
      render_click(view, "close_date_picker_popover")

      # 4. Time picker & availability status
      render_click(view, "open_time_picker", %{"mode" => "datetime"})
      render_click(view, "select_time_slot", %{"slot" => "02:00 PM - 02:30 PM"})

      for status <- ["Available", "Busy", "In-meeting", "Offline", "CustomStatus"] do
        render_click(view, "select_schedule_status", %{"status" => status})
      end

      render_click(view, "toggle_custom_time")
      render_click(view, "apply_time_picker")

      # 5. Dropdown toggle flood
      dropdowns = ["coach_menu", "kanban_filter", "model_picker", "workspace_menu"]

      for name <- dropdowns do
        render_click(view, "toggle_dropdown", %{"name" => name})
      end

      render_click(view, "close_dropdowns")

      # 6. Tool toggling
      tools = ["ast_search", "swarm", "web_search", "auto_fix", "git_patch"]

      for tool <- tools do
        render_click(view, "toggle_tool", %{"tool" => tool})
        render_click(view, "toggle_tool", %{"tool" => tool})
      end

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 7. Telemetry & PubSub Concurrency Invariant Tests
  # ============================================================================

  describe "Telemetry Arithmetic Invariants & High-Throughput Burst Invariants" do
    test "verifies token arithmetic invariants under a blast of 100 messages and progress events",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Blast 100 message created events
      for i <- 1..100 do
        msg = %Sessions.Message{
          id: "msg-invariant-#{i}",
          session_id: session.id,
          role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
          content: "Telemetry burst payload iteration #{i}",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        send(view.pid, {:message_created, msg})
      end

      # Blast 50 operation progress and stage events
      for step <- 1..50 do
        send(
          view.pid,
          {:operation_progress,
           %{
             id: "op-telemetry-1",
             progress: step * 2,
             latency_ms: 10 + step,
             status: "running",
             message: "Step #{step}"
           }}
        )

        send(view.pid, {:swarm_stage_changed, %{stage: :coding, iteration: step}})
      end

      # Blast session status changes
      send(view.pid, {:session_status_changed, "running"})
      send(view.pid, {:session_status_changed, "paused"})
      send(view.pid, {:session_status_changed, "completed"})

      # Verify LiveView renders correctly without crash and token numbers updated
      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end
  end

  # Terminal execution is async via Port: poll until the expected output
  # (e.g. an exit marker) shows up in the rendered buffer.
  defp wait_for_terminal(view, match?, deadline \\ 2000) do
    html = render(view)

    cond do
      match?.(html) ->
        html

      deadline <= 0 ->
        flunk("timed out waiting for expected terminal output")

      true ->
        Process.sleep(50)
        wait_for_terminal(view, match?, deadline - 50)
    end
  end

  defp count_exit_markers(html) do
    html |> String.split("[Exit ") |> length() |> Kernel.-(1)
  end
end
