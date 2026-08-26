defmodule IexCodeWeb.EmpiricalLiveviewMutationTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Kanban

  # ============================================================================
  # ITEM 5: WorkspaceLive.handle_event/3 Defensive Task Mutation Handling
  # ============================================================================
  describe "Item 5: WorkspaceLive.handle_event/3 defensive task mutation handling" do
    test "survives malformed payloads on all task mutation events", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Mutation Target Task",
          status: "ready",
          priority: "medium",
          assignee: "coder"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Test move_task with corrupt and unexpected payloads
      malformed_move_payloads = [
        %{},
        %{"id" => task.id, "status" => "unwhitelisted_status_123"},
        %{"id" => "non_existent_uuid", "status" => "done"},
        %{"unexpected_key" => "value"},
        %{"id" => task.id},
        %{"status" => "done"}
      ]

      for payload <- malformed_move_payloads do
        render_click(view, "move_task", payload)

        assert Process.alive?(view.pid),
               "LiveView crashed on move_task with payload #{inspect(payload)}"
      end

      # 2. Test update_task_priority with corrupt payloads
      malformed_priority_payloads = [
        %{},
        %{"id" => task.id, "priority" => "invalid_p"},
        %{"id" => "non_existent_uuid", "priority" => "high"},
        %{"invalid_key" => 123},
        %{"id" => task.id},
        %{"priority" => "critical"}
      ]

      for payload <- malformed_priority_payloads do
        render_click(view, "update_task_priority", payload)

        assert Process.alive?(view.pid),
               "LiveView crashed on update_task_priority with payload #{inspect(payload)}"
      end

      # 3. Test update_task_assignee with corrupt payloads
      malformed_assignee_payloads = [
        %{},
        %{"id" => "non_existent_uuid", "assignee" => "coder"},
        %{"unexpected" => "payload"},
        %{"id" => task.id}
      ]

      for payload <- malformed_assignee_payloads do
        render_click(view, "update_task_assignee", payload)

        assert Process.alive?(view.pid),
               "LiveView crashed on update_task_assignee with payload #{inspect(payload)}"
      end

      # 4. Test update_task with corrupt and nested payloads
      malformed_update_payloads = [
        %{},
        %{"id" => "non_existent_uuid", "task" => %{"title" => "New Title"}},
        %{"id" => task.id, "task" => %{}},
        %{"id" => task.id, "task" => %{"status" => "invalid_status", "priority" => "invalid_p"}},
        %{"corrupted_data" => 9999}
      ]

      for payload <- malformed_update_payloads do
        render_click(view, "update_task", payload)

        assert Process.alive?(view.pid),
               "LiveView crashed on update_task with payload #{inspect(payload)}"
      end

      # 5. Test delete_task with non-existent id
      render_click(view, "delete_task", %{"id" => "non_existent_uuid"})
      assert Process.alive?(view.pid)

      # 6. Finally delete the valid task
      render_click(view, "delete_task", %{"id" => task.id})
      assert Process.alive?(view.pid)
      assert Kanban.get_task(task.id) == nil
    end
  end
end
