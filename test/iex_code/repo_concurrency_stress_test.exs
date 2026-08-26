defmodule IexCode.RepoConcurrencyStressTest do
  use IexCode.DataCase, async: false
  alias IexCode.{Projects, Sessions, Settings, Kanban}

  describe "SQLite Concurrent Lock Resilience & Stress Test" do
    test "survives 30 concurrent tasks updating settings simultaneously" do
      # Pre-seed settings
      {:ok, _} =
        Settings.update_settings(%{default_model_provider: "openai", swarm_agent_count: 4})

      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            result =
              Settings.update_settings(%{
                openai_api_key: "sk-test-key-#{i}",
                swarm_agent_count: rem(i, 5) + 4,
                auto_save: rem(i, 2) == 0
              })

            case result do
              {:ok, s} ->
                assert s.swarm_agent_count in 4..8
                :ok

              {:error, changeset} ->
                flunk("Settings update failed with changeset error: #{inspect(changeset.errors)}")
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 30
      assert Enum.all?(results, &(&1 == :ok))

      final_settings = Settings.get_settings()
      assert final_settings.swarm_agent_count in 4..8
    end

    test "survives 50 concurrent processes creating projects, sessions, tasks, and messages" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Concurrency Test Proj",
          root_path: "/tmp/concurrency_test"
        })

      {:ok, session} =
        Sessions.create_session(%{project_id: project.id, title: "Concurrency Session"})

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            # Create a task in Kanban
            {:ok, task} =
              Kanban.create_task(%{
                project_id: project.id,
                session_id: session.id,
                title: "Concurrent Task #{i}",
                status: "todo",
                priority: "medium",
                assignee: "default"
              })

            # Create a message in Session
            {:ok, msg} =
              Sessions.create_message(%{
                session_id: session.id,
                role: "user",
                content: "Concurrent message #{i}"
              })

            # Create an operation in Session
            {:ok, op} =
              Sessions.create_operation(%{
                session_id: session.id,
                title: "Concurrent Op #{i}",
                status: "completed",
                agent_name: "explorer",
                op_type: "grep_search"
              })

            {task.id, msg.id, op.id}
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 50

      # Verify counts in DB
      tasks_in_db = Kanban.list_tasks(project.id)
      messages_in_db = Sessions.list_messages(session.id)
      ops_in_db = Sessions.list_operations(session.id)

      assert length(tasks_in_db) >= 50
      assert length(messages_in_db) >= 50
      assert length(ops_in_db) >= 50
    end

    test "handles rapid interleaved read-write transactions without SQLITE_BUSY or deadlocks" do
      {:ok, project} =
        Projects.create_project(%{name: "Interleaved RW Proj", root_path: "/tmp/rw_test"})

      {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "RW Session"})

      tasks =
        for i <- 1..40 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Writer: transaction with write
              Repo.transaction(fn ->
                {:ok, _} =
                  Sessions.create_message(%{
                    session_id: session.id,
                    role: "assistant",
                    content: "RW Writer msg #{i}"
                  })
              end)
            else
              # Reader: transaction with query
              Repo.transaction(fn ->
                msgs = Sessions.list_messages(session.id)
                length(msgs)
              end)
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 40

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end
end
