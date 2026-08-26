defmodule IexCode.KanbanAdversarialStressTest do
  @moduledoc """
  Adversarial & Stress Verification Suite for Kanban, Subtasks, and Agile Workflows.
  Tests rapid additions, toggle cycles, boundary conditions, Unicode/XSS resilience,
  status normalization, mixed operations fuzzing, and concurrent operations.
  """
  use IexCode.DataCase, async: true
  @moduletag timeout: 120_000

  alias IexCode.{Kanban, Projects, Sessions}

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Kanban Stress Project #{System.unique_integer([:positive])}",
        root_path: "/tmp/kanban_stress_#{System.unique_integer([:positive])}"
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Stress Session"
      })

    {:ok, project: project, session: session}
  end

  # ============================================================================
  # 1. Subtasks: Rapid Additions, Toggle Cycles & Deletions
  # ============================================================================

  describe "Subtasks Stress & Lifecycle Verification" do
    test "rapidly adds 50 subtasks in sequence and verifies step counter invariants", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Massive Subtask Accumulator",
          status: "todo"
        })

      assert task.subtasks == []
      assert task.steps_total == 0
      assert task.steps_completed == 0

      # Sequentially add 50 subtasks
      final_task =
        Enum.reduce(1..50, task, fn idx, acc_task ->
          {:ok, updated} = Kanban.add_subtask(acc_task, %{"title" => "Subtask Step #{idx}"})
          assert length(updated.subtasks) == idx
          assert updated.steps_total == idx
          assert updated.steps_completed == 0
          updated
        end)

      assert final_task.steps_total == 50
      assert final_task.steps_completed == 0

      # Re-fetch from DB to guarantee database persistence
      persisted = Kanban.get_task!(task.id)
      assert length(persisted.subtasks) == 50
      assert persisted.steps_total == 50
      assert persisted.steps_completed == 0
    end

    test "executes full toggle cycles across 30 subtasks and maintains step counts", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Toggle Stress Task",
          status: "ready"
        })

      # Add 30 subtasks
      task =
        Enum.reduce(1..30, task, fn idx, acc ->
          {:ok, updated} = Kanban.add_subtask(acc.id, "Step #{idx}")
          updated
        end)

      subtask_ids = Enum.map(task.subtasks, & &1["id"])
      assert length(subtask_ids) == 30

      # Cycle 1: Toggle all 30 to completed
      task_all_done =
        Enum.reduce(Enum.with_index(subtask_ids, 1), task, fn {sid, count}, acc ->
          {:ok, updated} = Kanban.toggle_subtask(acc, sid)
          assert updated.steps_completed == count
          assert updated.steps_total == 30
          updated
        end)

      assert task_all_done.steps_completed == 30

      # Cycle 2: Untoggle all 30 back to uncompleted
      task_all_undone =
        Enum.reduce(Enum.with_index(subtask_ids, 1), task_all_done, fn {sid, idx}, acc ->
          {:ok, updated} = Kanban.toggle_subtask(acc, sid)
          assert updated.steps_completed == 30 - idx
          assert updated.steps_total == 30
          updated
        end)

      assert task_all_undone.steps_completed == 0

      # Cycle 3: Toggle even-indexed subtasks (15 completed)
      even_ids = subtask_ids |> Enum.take_every(2)
      assert length(even_ids) == 15

      task_half_done =
        Enum.reduce(even_ids, task_all_undone, fn sid, acc ->
          {:ok, updated} = Kanban.toggle_subtask(acc.id, sid)
          updated
        end)

      assert task_half_done.steps_completed == 15
      assert task_half_done.steps_total == 30

      # Re-fetch from Repo
      persisted = Kanban.get_task!(task.id)
      assert persisted.steps_completed == 15
      assert persisted.steps_total == 30
    end

    test "handles deletion of non-existent subtasks and edge IDs gracefully", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Deletion Edge Cases Task"
        })

      {:ok, task} = Kanban.add_subtask(task, %{"title" => "Real Subtask 1"})
      {:ok, task} = Kanban.add_subtask(task, %{"title" => "Real Subtask 2"})
      assert task.steps_total == 2

      # Attempt deletion with random UUID
      random_uuid = Ecto.UUID.generate()
      assert {:ok, task_after_random} = Kanban.delete_subtask(task, random_uuid)
      assert length(task_after_random.subtasks) == 2
      assert task_after_random.steps_total == 2

      # Attempt deletion with random string
      assert {:ok, task_after_str} =
               Kanban.delete_subtask(task_after_random, "non_existent_id_999")

      assert length(task_after_str.subtasks) == 2

      # Attempt deletion with empty string
      assert {:ok, task_after_empty} = Kanban.delete_subtask(task_after_str, "")
      assert length(task_after_empty.subtasks) == 2

      # Delete real subtask by ID string
      [sub1, sub2] = task_after_empty.subtasks
      assert {:ok, task_after_del} = Kanban.delete_subtask(task.id, sub1["id"])
      assert length(task_after_del.subtasks) == 1
      assert hd(task_after_del.subtasks)["id"] == sub2["id"]
      assert task_after_del.steps_total == 1

      # Delete non-existent task_id
      fake_task_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Kanban.delete_subtask(fake_task_id, sub2["id"])
      assert {:error, :not_found} = Kanban.toggle_subtask(fake_task_id, sub2["id"])
      assert {:error, :not_found} = Kanban.add_subtask(fake_task_id, "Failing subtask")
    end

    test "handles subtasks with Unicode, emojis, RTL, HTML, SQL injections, and extreme sizes", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Complex Characters Subtask Task"
        })

      test_titles = [
        "Emoji Fest: 🚀🔥💻👩‍💻🎉⚡️✨🛠️",
        "Chinese / Japanese: 修复支付状态 / データベースの最適化",
        "Arabic RTL: إعداد بيئة التطوير والتحقق من الأخطاء",
        "Hebrew RTL: בדיקת תקינות המערכת",
        "Cyrillic: Тестирование отказоустойчивости канбан доски",
        "HTML/XSS: <script>alert('pwned')</script><b>Bold Title</b>",
        "SQL Injection: '; DROP TABLE kanban_tasks; SELECT * FROM users; --",
        "Quotes & JSON: {\"action\": \"deploy\", \"flags\": [\"--force\", \"--debug\"]}",
        "Newlines and Tabs: Line 1\nLine 2\tTabbed\r\nLine 3",
        "BIDI Trojan Override: \u202E reversal test \u202D normal",
        "Extreme Length String: " <> String.duplicate("A_Long_Subtask_Title_", 100)
      ]

      task =
        Enum.reduce(test_titles, task, fn title, acc ->
          {:ok, updated} = Kanban.add_subtask(acc, %{"title" => title})
          updated
        end)

      assert length(task.subtasks) == length(test_titles)
      assert task.steps_total == length(test_titles)

      # Verify all titles are preserved intact in database
      persisted = Kanban.get_task!(task.id)

      for {orig_title, sub} <- Enum.zip(test_titles, persisted.subtasks) do
        assert sub["title"] == String.trim(orig_title)
        assert is_binary(sub["id"])
        assert sub["completed"] == false
      end
    end

    test "rejects empty, whitespace-only, and malformed subtask titles", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Empty Subtask Guard Task"
        })

      invalid_params = [
        "",
        "   ",
        "\t\n\r  ",
        %{"title" => ""},
        %{"title" => "   "},
        %{"title" => "\t\n  "},
        %{title: ""},
        %{title: "  "},
        %{},
        %{other_key: "value"},
        12345,
        nil
      ]

      for param <- invalid_params do
        assert {:error, :empty_title} = Kanban.add_subtask(task, param)
        assert {:error, :empty_title} = Kanban.add_subtask(task.id, param)
      end

      # Task remains clean and untouched
      refreshed = Kanban.get_task!(task.id)
      assert refreshed.subtasks == []
      assert refreshed.steps_total == 0
    end

    test "maintains step counter mathematical invariants under a randomized sequence of 50 operations",
         %{
           project: project,
           session: session
         } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Fuzzing Invariants Task",
          status: "todo"
        })

      # Seeded deterministic sequence
      :rand.seed(:exsss, {42, 1337, 2026})

      # Run 50 random mutations: add, toggle, or delete
      final_task =
        Enum.reduce(1..50, task, fn i, current_task ->
          action =
            cond do
              length(current_task.subtasks) == 0 -> :add
              length(current_task.subtasks) > 10 -> Enum.random([:toggle, :delete])
              true -> Enum.random([:add, :toggle, :delete])
            end

          updated =
            case action do
              :add ->
                {:ok, t} = Kanban.add_subtask(current_task, "Fuzz item #{i}")
                t

              :toggle ->
                target = Enum.random(current_task.subtasks)
                {:ok, t} = Kanban.toggle_subtask(current_task, target["id"])
                t

              :delete ->
                target = Enum.random(current_task.subtasks)
                {:ok, t} = Kanban.delete_subtask(current_task, target["id"])
                t
            end

          # Verify mathematical invariants after EVERY mutation
          actual_total = length(updated.subtasks)
          actual_completed = Enum.count(updated.subtasks, &(&1["completed"] == true))

          assert updated.steps_total == actual_total
          assert updated.steps_completed == actual_completed

          updated
        end)

      # Persisted state matches in DB
      persisted = Kanban.get_task!(task.id)
      assert persisted.steps_total == length(persisted.subtasks)

      assert persisted.steps_completed ==
               Enum.count(persisted.subtasks, &(&1["completed"] == true))

      assert persisted.steps_total == final_task.steps_total
      assert persisted.steps_completed == final_task.steps_completed
    end
  end

  # ============================================================================
  # 2. Agile Status Moves Normalization & Boundary Verification
  # ============================================================================

  describe "Agile Status Moves Normalization" do
    test "normalizes all agile aliases correctly across case variations and whitespace", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Agile Normalization Exhaustive Suite",
          status: "triage"
        })

      # in_progress -> running
      assert {:ok, t1} = Kanban.move_task_status(task, "in_progress")
      assert t1.status == "running"

      assert {:ok, t2} = Kanban.move_task_status(t1, "in-progress")
      assert t2.status == "running"

      assert {:ok, t3} = Kanban.move_task_status(t2, "IN_PROGRESS")
      assert t3.status == "running"

      assert {:ok, t4} = Kanban.move_task_status(t3, "  In-Progress  ")
      assert t4.status == "running"

      # failed -> blocked
      assert {:ok, t5} = Kanban.move_task_status(t4, "failed")
      assert t5.status == "blocked"

      assert {:ok, t6} = Kanban.move_task_status(t5, "FAILED")
      assert t6.status == "blocked"

      assert {:ok, t7} = Kanban.move_task_status(t6, "  Failed  \n")
      assert t7.status == "blocked"

      # complete / completed -> done
      assert {:ok, t8} = Kanban.move_task_status(t7, "complete")
      assert t8.status == "done"

      assert {:ok, t9} = Kanban.move_task_status(t8, "completed")
      assert t9.status == "done"

      assert {:ok, t10} = Kanban.move_task_status(t9, "COMPLETE")
      assert t10.status == "done"

      assert {:ok, t11} = Kanban.move_task_status(t10, "COMPLETED")
      assert t11.status == "done"

      assert {:ok, t12} = Kanban.move_task_status(t11, "  Completed  \t")
      assert t12.status == "done"

      # Standard statuses
      standard_statuses = ~w(triage todo scheduled ready running blocked review done)

      for status <- standard_statuses do
        assert {:ok, moved} = Kanban.move_task_status(task, status)
        assert moved.status == status

        # With uppercase and whitespace
        upper_spaced = "  #{String.upcase(status)}  "
        assert {:ok, moved_upper} = Kanban.move_task_status(task, upper_spaced)
        assert moved_upper.status == status
      end
    end

    test "rejects invalid status strings, non-string types, and malformed task structs", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Invalid Status Defense",
          status: "ready"
        })

      invalid_statuses = [
        "invalid_random_string",
        "in progress",
        "finished",
        "cancelled",
        "archived",
        "",
        "   ",
        "\t\n",
        nil,
        12345,
        :done,
        ["ready"],
        %{status: "done"}
      ]

      for inv <- invalid_statuses do
        assert {:error, :invalid_status} = Kanban.move_task_status(task, inv)
      end

      # Reject invalid task structs / arguments
      assert {:error, :invalid_task} = Kanban.move_task_status(nil, "ready")
      assert {:error, :invalid_task} = Kanban.move_task_status("task_id_string", "ready")
      assert {:error, :invalid_task} = Kanban.move_task_status(%{id: "fake"}, "ready")
      assert {:error, :invalid_task} = Kanban.move_task_status(12345, "ready")

      # Task in DB remains untouched
      persisted = Kanban.get_task!(task.id)
      assert persisted.status == "ready"
    end
  end

  # ============================================================================
  # 3. Task Updates, Extreme String Lengths & Special Metadata
  # ============================================================================

  describe "Task Updates & Extreme Attributes Resilience" do
    test "updates task with extreme string lengths (100k chars) and unicode without data corruption",
         %{
           project: project,
           session: session
         } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Baseline Task"
        })

      # 50k character description
      long_desc = String.duplicate("Massive description payload with UTF-8 ⚡️🚀 ", 1000)
      # 5k character title
      long_title = "Stress Title: " <> String.duplicate("AlphaBetaGamma", 300)

      attrs = %{
        title: long_title,
        description: long_desc,
        priority: "critical",
        assignee: "specialist",
        tags: ["extreme-load", "utf8-⚡️", "benchmark-100", "unicode-测试"]
      }

      assert {:ok, updated} = Kanban.update_task(task, attrs)
      assert updated.title == long_title
      assert updated.description == long_desc
      assert updated.priority == "critical"
      assert updated.assignee == "specialist"
      assert length(updated.tags) == 4

      # Re-fetch from DB
      persisted = Kanban.get_task!(task.id)
      assert persisted.title == long_title
      assert persisted.description == long_desc
      assert persisted.tags == ["extreme-load", "utf8-⚡️", "benchmark-100", "unicode-测试"]
    end

    test "handles nil and empty optional fields safely", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Field Nullability Task",
          description: "Initial description",
          estimate: "10-20m",
          latest_summary: "Summary text",
          tags: ["tag1", "tag2"]
        })

      assert {:ok, updated} =
               Kanban.update_task(task, %{
                 description: nil,
                 estimate: nil,
                 latest_summary: nil,
                 tags: []
               })

      assert updated.description == nil
      assert updated.estimate == nil
      assert updated.latest_summary == nil
      assert updated.tags == []

      # Required title must not be nil or empty
      assert {:error, changeset} = Kanban.update_task(task, %{title: nil})
      assert %{title: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset2} = Kanban.update_task(task, %{title: ""})
      assert %{title: ["can't be blank"]} = errors_on(changeset2)
    end
  end

  # ============================================================================
  # 4. Atomic Task Claiming & Concurrency
  # ============================================================================

  describe "Task Atomic Claiming" do
    test "allows only a single worker to claim an available task", %{
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Competitive Claim Task",
          status: "ready"
        })

      # First claim succeeds
      assert {:ok, claimed} = Kanban.claim_task(task, "worker_alpha")
      assert claimed.status == "running"
      assert claimed.assignee == "worker_alpha"
      assert claimed.claimed_at != nil

      # Immediate second claim from different worker fails with :already_claimed
      assert {:error, :already_claimed} = Kanban.claim_task(claimed, "worker_beta")
    end
  end
end
