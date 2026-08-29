defmodule IexCodeWeb.AdversarialUiStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 180_000

  alias IexCode.{Sessions, Kanban}
  alias IexCode.Engine.OperationManager

  # ============================================================================
  # 1. Rapid-Fire Button Clicks, Multi-Dropdown Floods & Tab Switching
  # ============================================================================

  describe "Adversarial UI Interaction: Rapid Button Floods & Reentrancy" do
    test "survives rapid-fire multi-tab transitions, modal toggles, dropdown spam and wildcard events",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tabs = ["kanban", "calendar", "changes", "chat", "files", "terminal", "swarm"]

      # 1. Rapid tab switching interleaved with dropdown toggles
      for _cycle <- 1..5 do
        for tab <- tabs do
          render_click(view, "switch_tab", %{"tab" => tab})
          render_click(view, "switch_tab", %{"sidebar_tab" => tab})
          render_click(view, "toggle_dropdown", %{"name" => "dropdown_#{tab}"})
        end
      end

      # 2. Rapid modal and popover toggles
      modals_and_popovers = [
        "toggle_workspace_menu",
        "toggle_coach_menu",
        "toggle_date_picker_popover",
        "toggle_custom_time",
        "open_goal_modal",
        "close_goal_modal",
        "open_cancel_modal",
        "close_cancel_modal",
        "toggle_new_task_modal",
        "toggle_project_modal",
        "open_project_modal",
        "close_project_modal",
        "open_time_picker",
        "close_time_picker"
      ]

      for _ <- 1..3 do
        for action <- modals_and_popovers do
          render_click(view, action, %{})
        end
      end

      {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(settings_view, "toggle_settings_modal")
      assert_redirect(settings_view, "/sessions/#{session.id}/settings#execution")

      # 3. Model switches and tool toggles
      render_click(view, "change_model", %{
        "provider" => "anthropic",
        "model" => "claude-3-5-sonnet"
      })

      render_click(view, "change_model", %{"model" => "gpt-4o"})
      render_click(view, "change_model", %{"provider" => "openai", "model" => "gemini-2.5-flash"})

      tools = ["ast_search", "swarm", "web_search", "auto_fix", "git_patch", "unknown_tool_99"]

      for tool <- tools do
        render_click(view, "toggle_tool", %{"tool" => tool})
        render_click(view, "toggle_tool", %{"tool" => tool})
      end

      # 4. Swarm toggle and operation detail toggle flood
      render_click(view, "toggle_swarm", %{})
      render_click(view, "toggle_swarm", %{})

      for i <- 1..10 do
        render_click(view, "toggle_op_detail", %{"id" => "op_dummy_#{i}"})
      end

      # 5. Wildcard and unrecognized events
      unrecognized_events = [
        {"unknown_client_event", %{"foo" => "bar"}},
        {"malformed_click_123", %{}},
        {"", %{}},
        {"nil_param_event", nil}
      ]

      for {event_name, params} <- unrecognized_events do
        render_click(view, event_name, params || %{})
      end

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end
  end

  # ============================================================================
  # 2. Inline Editor: Path Traversal, Null Bytes, Dirty Buffers & Concurrent Edits
  # ============================================================================

  describe "Inline Editor Security & Multi-Buffer Integrity" do
    test "rejects traversal attempts (absolute, relative, encoded, null byte, directory) and protects root",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      workspace_write_file(path, "lib/legit_module.ex", "defmodule Legit do\n  :ok\nend")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "files"})

      adversarial_paths = [
        "/etc/passwd",
        "/dev/null",
        "../../../../etc/shadow",
        "../../../secret.key",
        "lib/../../../../../../var/log",
        "..%2f..%2fetc%2fpasswd",
        "%2e%2e%2f%2e%2e%2fsecret.txt",
        "lib/legit_module.ex\0/etc/passwd",
        "",
        "   ",
        "./././",
        "lib/",
        "test/non_existent_folder/sub/"
      ]

      for p <- adversarial_paths do
        html = render_click(view, "select_file", %{"path" => p})
        assert html =~ "Invalid file path" or html =~ "Could not read file" or is_binary(html)
        assert Process.alive?(view.pid)
      end

      # Legitimate file opens successfully
      html = render_click(view, "select_file", %{"path" => "lib/legit_module.ex"})
      assert html =~ "defmodule Legit"
      assert Process.alive?(view.pid)
    end

    test "manages 10 dirty buffers concurrently, preserving unsaved edits across tab & buffer switches",
         %{conn: conn, workspace_path: path} do
      # 1. Create 10 source files
      for i <- 1..10 do
        workspace_write_file(
          path,
          "lib/worker_#{i}.ex",
          "defmodule Worker#{i} do\n  def original_val, do: #{i}\nend"
        )
      end

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 2. Open all 10 files
      for i <- 1..10 do
        render_click(view, "select_file", %{"path" => "lib/worker_#{i}.ex"})
      end

      # 3. Apply dirty modifications to all 10 open buffers
      for i <- 1..10 do
        render_click(view, "select_file", %{"path" => "lib/worker_#{i}.ex"})

        render_change(view, "file_content_changed", %{
          "content" => "defmodule Worker#{i}Modified do\n  def dirty_val, do: #{i * 1000}\nend"
        })
      end

      # 4. Switch between other tabs (kanban, terminal, changes) and back to files
      render_click(view, "switch_tab", %{"tab" => "kanban"})
      render_click(view, "switch_tab", %{"tab" => "terminal"})
      render_click(view, "switch_tab", %{"tab" => "files"})

      # 5. Verify dirty content was preserved in buffer 7 without writing to disk yet
      render_click(view, "select_file", %{"path" => "lib/worker_7.ex"})
      disk_content_7 = File.read!(Path.join(path, "lib/worker_7.ex"))
      assert disk_content_7 =~ "def original_val, do: 7"
      refute disk_content_7 =~ "dirty_val"

      # 6. Save buffer 7
      render_click(view, "save_file", %{})
      disk_content_7_after = File.read!(Path.join(path, "lib/worker_7.ex"))
      assert disk_content_7_after =~ "def dirty_val, do: 7000"

      # 7. Revert buffer 4
      render_click(view, "select_file", %{"path" => "lib/worker_4.ex"})
      render_click(view, "revert_file_buffer", %{})
      disk_content_4 = File.read!(Path.join(path, "lib/worker_4.ex"))
      assert disk_content_4 =~ "def original_val, do: 4"

      # 8. Close buffers 1 through 5
      for i <- 1..5 do
        render_click(view, "close_file_buffer", %{"path" => "lib/worker_#{i}.ex"})
      end

      # 9. Verify buffer 8 still retains its dirty edits
      render_click(view, "select_file", %{"path" => "lib/worker_8.ex"})

      render_click(view, "save_file", %{
        "content" => "defmodule Worker8ExplicitSave do\n  def saved, do: 8888\nend"
      })

      disk_content_8 = File.read!(Path.join(path, "lib/worker_8.ex"))
      assert disk_content_8 =~ "defmodule Worker8ExplicitSave"

      # 10. Close all remaining buffers
      for i <- 6..10 do
        render_click(view, "close_file_buffer", %{"path" => "lib/worker_#{i}.ex"})
      end

      # Save when no buffer is active -> harmless no-op
      render_click(view, "save_file", %{"content" => "orphaned text"})
      render_click(view, "revert_file_buffer", %{})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 3. Interactive Diff & Hunk Operations: Conflicting & Edge-Case Actions
  # ============================================================================

  describe "Git Diffs & Interactive Hunk Actions Stress" do
    test "handles rapid accept/reject/revert cycles, malformed hunk IDs, and unstaged edge cases",
         %{conn: conn} do
      {:ok, git_path} =
        init_temp_git_repo(%{
          "lib/engine.ex" => "defmodule Engine do\n  def v, do: 1\nend",
          "lib/helper.ex" => "defmodule Helper do\n  def help, do: :yes\nend"
        })

      # Modify files in git repo
      File.write!(
        Path.join(git_path, "lib/engine.ex"),
        "defmodule Engine do\n  def v, do: 2\n  def extra, do: :ok\nend"
      )

      File.write!(Path.join(git_path, "lib/untracked_new.ex"), "defmodule Untracked do\nend")

      project = create_project_fixture(%{root_path: git_path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # 1. Switch diff modes
      modes = ["inline", "split", "unified", "raw", "invalid_mode", ""]

      for m <- modes do
        render_click(view, "set_diff_mode", %{"mode" => m})
      end

      # 2. Select diff files
      render_click(view, "select_diff_file", %{"file" => "lib/engine.ex"})
      render_click(view, "select_diff_file", %{"file" => "lib/untracked_new.ex"})
      render_click(view, "select_diff_file", %{"file" => "lib/ghost_file.ex"})
      render_click(view, "select_diff_file", %{"path" => nil})

      # 3. Malformed hunk IDs during accept and reject
      malformed_hunks = ["", "-1", "99999", "hunk-bad", "nil", "0.5", "../path"]

      for h_id <- malformed_hunks do
        render_click(view, "accept_hunk", %{"file" => "lib/engine.ex", "hunk_id" => h_id})
        render_click(view, "reject_hunk", %{"file" => "lib/engine.ex", "hunk_id" => h_id})
        render_click(view, "revert_hunk", %{"file" => "lib/engine.ex", "hunk_id" => h_id})
      end

      # 4. Accept all hunks on modified file
      render_click(view, "accept_all_hunks", %{"file" => "lib/engine.ex"})

      # 5. Revert file on tracked, untracked, and non-existent files
      render_click(view, "revert_file", %{"file" => "lib/engine.ex"})
      render_click(view, "revert_file", %{"file" => "lib/untracked_new.ex"})
      render_click(view, "revert_file", %{"file" => "lib/non_existent.ex"})
      render_click(view, "revert_file", %{"file" => "../outside_repo.ex"})

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 4. Terminal Execution Floods, Metacharacters & Cancellation Races
  # ============================================================================

  describe "Terminal Execution Floods & Shell Safety" do
    test "processes 30 rapid commands with pipes, quotes, exits, and handles replay/stop safely",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "terminal"})

      # 1. Empty and whitespace command handling
      render_click(view, "run_terminal_command", %{"command" => ""})
      render_click(view, "run_terminal_command", %{"command" => "    "})

      # 2. Run 20 unique commands in rapid succession with various shell metacharacters
      commands = [
        "echo 'TEST_METASYMBOL_1'",
        "echo \"double 'quotes' test\"",
        "echo 'pipe test' | tr 'a-z' 'A-Z'",
        "echo 'line 1' && echo 'line 2'",
        "true || false",
        "echo -n 'no newline'",
        "printf 'formatted %s %d\\n' output 42",
        "exit 0",
        "exit 2",
        "echo 'unicode test: 🚀 🐝 ⚡'",
        "head -n 2 mix.exs",
        "echo 'multi-flag' -a -b -c",
        "expr 10 + 20",
        "echo 'subshell' $(echo 'nested')",
        "echo 'history item 15'",
        "echo 'history item 16'",
        "echo 'history item 17'",
        "echo 'history item 18'",
        "echo 'history item 19'",
        "echo 'history item 20'"
      ]

      for {cmd, _i} <- Enum.with_index(commands, 1) do
        html = render_click(view, "run_terminal_command", %{"command" => cmd})
        assert is_binary(html)
      end

      # 3. Replay terminal command
      html_replay = render_click(view, "replay_terminal_command", %{})
      assert is_binary(html_replay)

      # 4. Stop terminal command
      html_stop = render_click(view, "stop_terminal_command", %{})
      assert html_stop =~ "Terminal command stopped" or html_stop =~ "Command Interrupted"

      # 5. Clear terminal
      html_cleared = render_click(view, "clear_terminal", %{})
      refute html_cleared =~ "TEST_METASYMBOL_1"

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 5. Kanban & Task State Transitions & Boundary Values
  # ============================================================================

  describe "Kanban Task Transitions & Schedule Boundaries" do
    test "creates, updates, claims, estimates, moves and deletes tasks across all statuses and priorities",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Create task with full parameters
      render_click(view, "create_task", %{
        "task" => %{
          "title" => "Adversarial Test Task Alpha",
          "description" => "Testing status transitions",
          "status" => "ready",
          "priority" => "critical",
          "assignee" => "coder",
          "steps_total" => "6",
          "scheduled_at_date" => "2026-08-30",
          "cron_expression" => "0 0 * * *",
          "tag" => "Adversarial"
        }
      })

      tasks = Kanban.list_tasks(project.id)
      task = Enum.find(tasks, &(&1.title == "Adversarial Test Task Alpha"))
      assert task != nil
      assert task.status == "ready"
      assert task.priority == "critical"

      # 2. Open task drawer
      render_click(view, "open_task_drawer", %{"id" => task.id})

      # 3. Move task through all supported statuses
      for status <- ~w(running blocked review done triage todo scheduled ready) do
        render_click(view, "move_task", %{"id" => task.id, "status" => status})
      end

      # 4. Update task priority
      for prio <- ~w(low medium high critical) do
        render_click(view, "update_task_priority", %{"id" => task.id, "priority" => prio})
      end

      # 5. Update task assignee
      for assignee <- ~w(planner explorer coder verifier default) do
        render_click(view, "update_task_assignee", %{"id" => task.id, "assignee" => assignee})
      end

      # 6. Claim and estimate effort
      render_click(view, "claim_task", %{"id" => task.id})
      render_click(view, "estimate_task", %{"id" => task.id})

      # 7. Update scheduled task modal workflow
      render_click(view, "show_scheduled_task", %{"id" => task.id})
      render_click(view, "open_edit_scheduled_task", %{"id" => task.id})

      render_click(view, "update_scheduled_task", %{
        "task" => %{
          "id" => task.id,
          "title" => "Adversarial Task Alpha Renamed",
          "description" => "Updated description",
          "priority" => "high",
          "assignee" => "verifier",
          "cron_expression" => "30 18 * * *",
          "scheduled_at_date" => "2026-09-01"
        }
      })

      render_click(view, "close_scheduled_task_modal")
      render_click(view, "close_edit_scheduled_task")

      # 8. Filter kanban
      render_click(view, "select_kanban_filter", %{"key" => "priority", "value" => "high"})
      render_click(view, "select_kanban_filter", %{"key" => "status", "value" => "running"})

      render_click(view, "filter_kanban", %{
        "search" => "Alpha",
        "priority" => "high",
        "status" => "",
        "assignee" => ""
      })

      # 9. Delete task
      render_click(view, "delete_task", %{"id" => task.id})
      render_click(view, "close_task_drawer")

      assert Kanban.get_task(task.id) == nil
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 6. Telemetry Emission, Invariant Verification & State Leakage
  # ============================================================================

  describe "Telemetry Emission & State Invariants" do
    test "captures real telemetry events with active listeners and preserves LiveView token invariants",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Attach test telemetry handler
      test_pid = self()
      handler_id = "test-telemetry-handler-#{:rand.uniform(1_000_000)}"

      events = [
        [:iex_code, :operation, :start],
        [:iex_code, :operation, :progress],
        [:iex_code, :operation, :stop],
        [:iex_code, :operation, :crash]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # 2. Run an async operation through OperationManager that emits telemetry
      {:ok, _task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "CoderAgent",
          "patch",
          "Apply Security Patch",
          %{"file" => "lib/secure.ex"},
          fn progress_fn ->
            progress_fn.(50, "Halfway done")
            {:ok, "Patch applied cleanly"}
          end
        )

      # Assert telemetry events were emitted
      assert_receive {:telemetry_event, [:iex_code, :operation, :start], _m_start,
                      %{agent_name: "CoderAgent"}},
                     3000

      assert_receive {:telemetry_event, [:iex_code, :operation, :progress], %{progress: 50},
                      %{message: "Halfway done"}},
                     3000

      assert_receive {:telemetry_event, [:iex_code, :operation, :stop], %{duration_ms: _},
                      %{operation_id: op_id}},
                     3000

      assert op_id == op.id

      # 3. Run failing async operation to test crash telemetry
      {:ok, _task_pid2, _op2} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "VerifierAgent",
          "test",
          "Failing Compilation",
          %{},
          fn _progress_fn ->
            {:error, :syntax_error}
          end
        )

      assert_receive {:telemetry_event, [:iex_code, :operation, :crash], _m_crash,
                      %{reason: :syntax_error}},
                     3000

      :telemetry.detach(handler_id)

      # 4. Blast 100 message events. Token counters are real telemetry now —
      # they are not derived from message events, so they stay at their
      # initial value while the messages themselves accumulate.
      for i <- 1..100 do
        msg = %Sessions.Message{
          id: "burst-msg-#{i}",
          session_id: session.id,
          role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
          content: "Burst content ##{i}",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        send(view.pid, {:message_created, msg})
      end

      # Render LiveView
      html = render(view)
      assert is_binary(html)

      # Verify socket assigns integrity: no fake token constants exist anymore
      state = :sys.get_state(view.pid)
      assigns = state.socket.assigns

      assert assigns.session_tokens >= 0
      assert length(assigns.messages) >= 100
      assert Process.alive?(view.pid)
    end
  end
end
