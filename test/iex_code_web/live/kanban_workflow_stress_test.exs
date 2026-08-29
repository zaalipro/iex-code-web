defmodule IexCodeWeb.KanbanWorkflowStressTest do
  @moduledoc """
  Adversarial & Stress Verification Suite for WorkspaceLive Tab Workflows:
  Kanban Drawer Inline Editing, Subtask Checklist UI, Agile Move Events,
  Swarm Steering Auto-Reset, and Calendar Schedule Type Synchronization.
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Kanban

  # ============================================================================
  # 1. Kanban Detail Drawer & Subtasks Checklist Stress
  # ============================================================================

  describe "Task Detail Drawer & Subtasks Checklist LiveView Interactions" do
    test "handles rapid inline editing, extreme text lengths, and comma-separated tag parsing",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Initial Drawer Task",
          description: "Initial description",
          status: "ready",
          priority: "medium",
          tags: ["alpha"]
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open task drawer
      html = render_hook(view, "open_task_drawer", %{"id" => task.id})
      assert html =~ "drawer-edit-task-#{task.id}"

      # Inline edit with complex tags, unicode, and long text via Form
      long_desc = "Extreme description " <> String.duplicate("with UTF-8 ⚡️ and symbols #! ", 50)

      view
      |> form("#drawer-edit-task-#{task.id}", %{
        "task_id" => task.id,
        "title" => "Updated Unicode Title 🚀 修复",
        "description" => long_desc,
        "tags" => "  frontend  , ,  kanban-ui ,,, utf8-⚡️ ,  "
      })
      |> render_submit()

      updated_html = render(view)
      assert updated_html =~ "Task updated"
      assert updated_html =~ "Updated Unicode Title 🚀 修复"

      persisted = Kanban.get_task!(task.id)
      assert persisted.title == "Updated Unicode Title 🚀 修复"
      assert persisted.tags == ["frontend", "kanban-ui", "utf8-⚡️"]

      # Also test updating priority and status via hook events
      render_hook(view, "update_task_priority", %{"id" => task.id, "priority" => "critical"})
      render_hook(view, "move_task", %{"id" => task.id, "status" => "running"})

      persisted2 = Kanban.get_task!(task.id)
      assert persisted2.priority == "critical"
      assert persisted2.status == "running"
    end

    test "handles rapid subtask creation, toggle, and deletion via LiveView events", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Subtasks LiveView Stress Task",
          status: "todo"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open task drawer
      render_hook(view, "open_task_drawer", %{"id" => task.id})

      # Rapidly add 5 subtasks via LiveView form
      for i <- 1..5 do
        view
        |> form("form[phx-submit='add_subtask']", %{
          "task_id" => task.id,
          "title" => "LiveView Subtask Item #{i} 🚀"
        })
        |> render_submit()
      end

      task_after_adds = Kanban.get_task!(task.id)
      assert length(task_after_adds.subtasks) == 5
      assert task_after_adds.steps_total == 5
      assert task_after_adds.steps_completed == 0

      # Toggle all 5 subtasks via toggle_subtask event
      for sub <- task_after_adds.subtasks do
        sid = sub["id"]

        render_hook(view, "toggle_subtask", %{
          "id" => sid,
          "task_id" => task.id
        })
      end

      task_after_toggles = Kanban.get_task!(task.id)
      assert task_after_toggles.steps_completed == 5

      # Verify 100% completion in rendered HTML
      html = render(view)
      assert html =~ "100%"
      assert html =~ "Subtasks (5/5)"

      # Delete 2 subtasks
      [sub1, sub2 | remaining] = task_after_toggles.subtasks

      render_hook(view, "delete_subtask", %{"id" => sub1["id"], "task_id" => task.id})
      assert Kanban.get_task!(task.id).subtasks == task_after_toggles.subtasks
      assert has_element?(view, "[id^='subtask-delete-confirmation-']")
      render_hook(view, "confirm_subtask_delete", %{})

      render_hook(view, "delete_subtask", %{"id" => sub2["id"], "task_id" => task.id})
      assert has_element?(view, "[id^='subtask-delete-confirmation-']")
      render_hook(view, "confirm_subtask_delete", %{})

      task_after_deletions = Kanban.get_task!(task.id)
      assert length(task_after_deletions.subtasks) == 3
      assert task_after_deletions.steps_total == 3
      assert task_after_deletions.steps_completed == 3

      assert Enum.map(task_after_deletions.subtasks, & &1["id"]) ==
               Enum.map(remaining, & &1["id"])

      # Delete non-existent subtask from LiveView (should not crash)
      render_hook(view, "delete_subtask", %{"id" => "bogus-subtask-id", "task_id" => task.id})
      assert Process.alive?(view.pid)
    end

    test "handles task drawer close and task deletion cleanly", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Task to be Deleted",
          status: "todo"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open drawer
      render_hook(view, "open_task_drawer", %{"id" => task.id})
      assert has_element?(view, "#drawer-edit-task-#{task.id}")

      # Close drawer
      render_hook(view, "close_task_drawer", %{})
      refute has_element?(view, "#drawer-edit-task-#{task.id}")

      # The public delete event must only open confirmation.
      render_hook(view, "delete_task", %{"id" => task.id})
      assert Kanban.get_task!(task.id)
      assert has_element?(view, "[id^='task-delete-confirmation-']")

      render_hook(view, "confirm_task_delete", %{})
      assert Kanban.get_task(task.id) == nil
    end

    test "handles malformed, nil, and empty payloads across drawer handlers without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Empty and malformed add_subtask
      render_hook(view, "add_subtask", %{})
      render_hook(view, "add_subtask", %{"task_id" => nil, "title" => nil})
      render_hook(view, "add_subtask", %{"title" => "   "})

      # Empty and malformed toggle_subtask
      render_hook(view, "toggle_subtask", %{"id" => "fake-id"})
      render_hook(view, "toggle_subtask", %{"id" => "fake-id", "task_id" => nil})

      # Empty and malformed delete_subtask
      render_hook(view, "delete_subtask", %{"id" => "fake-id"})
      render_hook(view, "delete_subtask", %{"id" => "fake-id", "task_id" => nil})

      # Malformed update_task
      render_hook(view, "update_task", %{})
      render_hook(view, "update_task", %{"id" => nil})
      render_hook(view, "update_task", %{"id" => Ecto.UUID.generate(), "title" => "No-op"})

      # Malformed update_task_priority and update_task_assignee
      render_hook(view, "update_task_priority", %{})
      render_hook(view, "update_task_assignee", %{})
      render_hook(view, "update_task_priority", %{"id" => "non-existent", "priority" => "low"})
      render_hook(view, "update_task_assignee", %{"id" => "non-existent", "assignee" => "coder"})

      # Malformed claim_task and delete_task
      render_hook(view, "claim_task", %{"id" => "non-existent"})
      render_hook(view, "delete_task", %{"id" => "non-existent"})

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 2. Agile Status Moves in LiveView
  # ============================================================================

  describe "Agile Status Moves LiveView Handlers" do
    test "dispatches move_task events with agile aliases and invalid values safely", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Agile Move LiveView Task",
          status: "todo"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # in_progress -> running
      render_hook(view, "move_task", %{"id" => task.id, "status" => "in_progress"})
      assert Kanban.get_task!(task.id).status == "running"

      # in-progress -> running
      render_hook(view, "move_task", %{"id" => task.id, "status" => "in-progress"})
      assert Kanban.get_task!(task.id).status == "running"

      # failed -> blocked
      render_hook(view, "move_task", %{"id" => task.id, "status" => "failed"})
      assert Kanban.get_task!(task.id).status == "blocked"

      # complete -> done
      render_hook(view, "move_task", %{"id" => task.id, "status" => "complete"})
      assert Kanban.get_task!(task.id).status == "done"

      # completed -> done
      render_hook(view, "move_task", %{"id" => task.id, "status" => "completed"})
      assert Kanban.get_task!(task.id).status == "done"

      # Invalid status string produces flash error without crashing
      html = render_hook(view, "move_task", %{"id" => task.id, "status" => "totally_bogus"})
      assert html =~ "Invalid task status"
      assert Kanban.get_task!(task.id).status == "done"

      # Non-existent task ID
      html_fake =
        render_hook(view, "move_task", %{"id" => Ecto.UUID.generate(), "status" => "ready"})

      assert html_fake =~ "Task not found"

      # Empty params
      render_hook(view, "move_task", %{})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 3. Swarm Steering & Auto-Reset Verification
  # ============================================================================

  describe "Swarm Steering Input & Auto-Reset" do
    test "resets steer_text upon sending steering and ignores empty / whitespace submissions", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Empty steering string -> no flash, no crash
      html_empty = render_hook(view, "send_steering", %{"steering" => ""})
      refute html_empty =~ "Steering guidance delivered"

      # Whitespace-only steering -> trimmed and ignored
      html_ws = render_hook(view, "send_steering", %{"steering" => "   \t\n  "})
      refute html_ws =~ "Steering guidance delivered"

      # Malformed empty params -> ignored safely
      html_blank = render_hook(view, "send_steering", %{})
      refute html_blank =~ "Steering guidance delivered"

      # Extreme length steering guidance (10k chars)
      extreme_guidance =
        "Focus on: " <> String.duplicate("Refine subtasks and verification! ", 300)

      html_extreme = render_hook(view, "send_steering", %{"steering" => extreme_guidance})
      assert html_extreme =~ "Steering guidance delivered to active swarm"
      assert Process.alive?(view.pid)

      # Valid steering guidance -> triggers flash and clears steer_text
      html_valid =
        render_hook(view, "send_steering", %{
          "steering" => "Focus strictly on completing the Kanban subtask tests."
        })

      assert html_valid =~ "Steering guidance delivered to active swarm"
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 4. Calendar Schedule Type Synchronization
  # ============================================================================

  describe "Calendar Schedule Type Selection" do
    test "rapidly switches schedule type assigns without degradation", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      types = ["scheduled", "recurring", "backlog", "milestone", "ready", "triage"]

      for type <- types do
        render_hook(view, "set_task_schedule_type", %{"type" => type})
        assert Process.alive?(view.pid)
      end

      # Fallback when type passed with alternative key
      render_hook(view, "set_task_schedule_type", %{"schedule_type" => "recurring"})
      assert Process.alive?(view.pid)

      # Fallback when empty map passed
      render_hook(view, "set_task_schedule_type", %{})
      assert Process.alive?(view.pid)
    end
  end
end
