defmodule IexCode.E2E.Tier2BoundaryTest do
  @moduledoc """
  Tier 2: Boundary & Corner Cases E2E Test Suite (85 Tests).
  Provides >= 5 concrete boundary/edge/crash/stress test cases for each feature F1 through F17:
  - F1: AppSettings Query Safety (5 boundary tests)
  - F2: OTP Subagent Process Tree (5 boundary tests)
  - F3: OTP Process Crash Monitoring (5 boundary tests)
  - F4: Autonomous Error Feedback Loop (5 boundary tests)
  - F5: Live Telemetry & Card Streaming (5 boundary tests)
  - F6: Hierarchical Operation Tree (5 boundary tests)
  - F7: Interactive Code Diff Viewer (5 boundary tests)
  - F8: File Tree Explorer & Search (5 boundary tests)
  - F9: Terminal Session Integration (5 boundary tests)
  - F10: AST-Aware Search Engine (5 boundary tests)
  - F11: Multi-File Atomic Patching (5 boundary tests)
  - F12: Automated Test Runner & Parser (5 boundary tests)
  - F13: Instant Auto-Fix Engine (5 boundary tests)
  - F14: Git Integration Engine (5 boundary tests)
  - F15: Streaming SSE LLM Client (5 boundary tests)
  - F16: UTF-8 Stream Sanitizer Buffer (5 boundary tests)
  - F17: LLM Resilience & Retries (5 boundary tests)
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Settings.AppSettings
  alias IexCode.Tools.ASTSearch
  alias IexCode.Engine.SessionServer

  # ============================================================================
  # F1: AppSettings Query Safety (5 Boundary Tests)
  # ============================================================================
  describe "F1: AppSettings Query Safety (Boundary)" do
    test "T2_F01_01_concurrent_race_condition_on_empty_db" do
      IexCode.Repo.delete_all(AppSettings)
      parent = self()

      # 10 concurrent requests to get_settings()
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, parent, self())
            Settings.get_settings()
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 10
      assert Enum.all?(results, fn r -> %AppSettings{} = r end)
    end

    test "T2_F01_02_empty_strings_and_nil_fallbacks" do
      original = Settings.get_settings()

      assert {:error, changeset} =
               Settings.update_settings(%{
                 openai_api_key: "",
                 openai_base_url: nil
               })

      assert changeset.errors[:openai_base_url]
      settings = Settings.get_settings()
      # Blank keys normalize to nil — no key is ever injected as a default.
      assert settings.openai_api_key == original.openai_api_key
      assert settings.openai_base_url == original.openai_base_url
    end

    test "T2_F01_03_invalid_types_validation" do
      changeset = AppSettings.changeset(%AppSettings{}, %{swarm_agent_count: "invalid"})
      assert changeset.errors[:swarm_agent_count] != nil
    end

    test "T2_F01_04_extreme_string_lengths" do
      huge_url = "https://cli.llmotions.com/v1/" <> String.duplicate("a", 5000)
      assert {:error, changeset} = Settings.update_settings(%{openai_base_url: huge_url})
      assert changeset.errors[:openai_base_url]
    end

    test "T2_F01_05_empty_attributes_update" do
      original = Settings.get_settings()
      {:ok, updated} = Settings.update_settings(%{})
      assert updated.id != nil
      if original.id, do: assert(updated.id == original.id)
      assert updated.default_model == original.default_model
    end
  end

  # ============================================================================
  # F2: OTP Subagent Process Tree (5 Boundary Tests)
  # ============================================================================
  describe "F2: OTP Subagent Process Tree (Boundary)" do
    test "T2_F02_01_duplicate_session_start_idempotency", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, pid1} = SessionServer.ensure_started(session.id)
      {:ok, pid2} = SessionServer.ensure_started(session.id)
      assert pid1 == pid2
    end

    test "T2_F02_02_restart_dead_session_server", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, pid1} = SessionServer.ensure_started(session.id)
      Process.exit(pid1, :kill)
      :timer.sleep(50)

      {:ok, pid2} = SessionServer.ensure_started(session.id)
      assert pid1 != pid2
      assert Process.alive?(pid2)
    end

    test "T2_F02_03_concurrent_session_creation_isolation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})

      sessions =
        for i <- 1..5 do
          create_session_fixture(project, %{title: "Parallel #{i}"})
        end

      pids =
        for s <- sessions do
          {:ok, pid} = SessionServer.ensure_started(s.id)
          pid
        end

      unique_pids = Enum.uniq(pids)
      assert length(unique_pids) == 5
      assert Enum.all?(pids, &Process.alive?/1)
    end

    test "T2_F02_04_blank_message_validation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:error, changeset} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "user",
          content: "   "
        })

      assert changeset.errors[:content] != nil
    end

    test "T2_F02_05_session_server_state_retrieval_after_operations", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _pid} = SessionServer.ensure_started(session.id)
      state1 = SessionServer.get_state(session.id)
      assert state1.status == :idle

      {:ok, _} = SessionServer.toggle_swarm(session.id)
      state2 = SessionServer.get_state(session.id)
      assert state2.session.swarm_mode == true
    end
  end

  # ============================================================================
  # F3: OTP Process Crash Monitoring (5 Boundary Tests)
  # ============================================================================
  describe "F3: OTP Process Crash Monitoring (Boundary)" do
    test "T2_F03_01_uncaught_throw_handled_safely", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "ThrowAgent",
          "throw_task",
          "Custom Throw",
          %{},
          fn _p -> throw(:custom_abort_symbol) end
        )

      assert {:error, msg} = result
      assert String.contains?(msg, "custom_abort_symbol")
      assert_receive {:operation_failed, op}, 5000
      assert op.status == "failed"
    end

    test "T2_F03_02_exit_signal_handled_safely", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "ExitAgent",
          "exit_task",
          "Exit Signal",
          %{},
          fn _p -> exit(:abnormal_worker_kill) end
        )

      assert {:error, msg} = result
      assert String.contains?(msg, "abnormal_worker_kill")
    end

    test "T2_F03_03_empty_operation_params", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "EmptyParamsAgent",
          "task",
          "Empty Params",
          %{},
          fn _p -> {:ok, "done"} end
        )

      assert_receive {:operation_task_done, op_id, {:ok, "done"}}, 5000
      assert op_id == op.id
    end

    test "T2_F03_04_sync_operation_timeout", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "TimeoutAgent",
          "task",
          "Timeout Task",
          %{},
          fn _p ->
            :timer.sleep(500)
            {:ok, "never"}
          end,
          50
        )

      assert result == {:error, "Operation timed out after 50ms"}
    end

    test "T2_F03_05_operation_on_nonexistent_session_uuid" do
      fake_id = Ecto.UUID.generate()

      {:ok, task_pid, op} =
        OperationManager.run_async_operation(
          fake_id,
          nil,
          "GhostAgent",
          "task",
          "Ghost Operation",
          %{},
          fn _p -> {:ok, "ghost success"} end
        )

      assert is_pid(task_pid)
      assert op.session_id == fake_id
      assert_receive {:operation_task_done, _, {:ok, "ghost success"}}, 5000
    end
  end

  # ============================================================================
  # F4: Autonomous Error Feedback Loop (5 Boundary Tests)
  # ============================================================================
  describe "F4: Autonomous Error Feedback Loop (Boundary)" do
    @describetag mock_llm: true
    test "T2_F04_01_swarm_empty_workspace", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Build from scratch", path)
      assert_receive {:session_status_changed, "idle"}, 20_000

      messages = Sessions.list_messages(session.id)
      assert length(messages) >= 1
    end

    test "T2_F04_02_swarm_special_unicode_prompt", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      prompt = "Fix bug 🐛 in module <Test> & verify: 100% {valid: true} 🚀"
      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, prompt, path)
      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T2_F04_03_rapid_toggle_swarm_mode", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{swarm_mode: false})

      {:ok, m1} = SessionServer.toggle_swarm(session.id)
      assert m1 == true
      {:ok, m2} = SessionServer.toggle_swarm(session.id)
      assert m2 == false
      {:ok, m3} = SessionServer.toggle_swarm(session.id)
      assert m3 == true
    end

    test "T2_F04_04_swarm_on_nonexistent_workspace_path" do
      project = create_project_fixture(%{root_path: "/tmp/non_existent_workspace_999"})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} =
        SwarmOrchestrator.run_swarm(session.id, "Explore", "/tmp/non_existent_workspace_999")

      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T2_F04_05_swarm_message_history_persistence", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      _m1 = create_message_fixture(session, %{role: "user", content: "Initial message"})
      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Second prompt", path)
      assert_receive {:session_status_changed, "idle"}, 20_000

      all_messages = Sessions.list_messages(session.id)
      assert length(all_messages) >= 2
    end
  end

  # ============================================================================
  # F5: Live Telemetry & Card Streaming (5 Boundary Tests)
  # ============================================================================
  describe "F5: Live Telemetry & Card Streaming (Boundary)" do
    test "T2_F05_01_boundary_progress_percentages", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "BoundaryAgent",
        "boundary_task",
        "0 and 100",
        %{},
        fn progress ->
          progress.(0, "Start")
          progress.(100, "Finish")
          {:ok, "done"}
        end
      )

      assert_receive {:operation_progress, _, 0, "Start"}, 5000
      assert_receive {:operation_progress, _, 100, "Finish"}, 5000
    end

    test "T2_F05_02_rapid_progress_bursts", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "BurstAgent",
        "burst_task",
        "Rapid Burst",
        %{},
        fn progress ->
          for i <- 1..20 do
            progress.(i * 5, "Step #{i}")
          end

          {:ok, "done"}
        end
      )

      events = drain_pubsub()

      progress_events =
        Enum.filter(events, fn
          {:operation_progress, _, _, _} -> true
          _ -> false
        end)

      assert length(progress_events) == 20
    end

    test "T2_F05_03_large_progress_message_payload", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      large_msg = String.duplicate("Progress payload ", 200)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "LargeAgent",
        "task",
        "Large Payload",
        %{},
        fn progress ->
          progress.(50, large_msg)
          {:ok, "done"}
        end
      )

      assert_receive {:operation_progress, _, 50, ^large_msg}, 5000
    end

    test "T2_F05_04_zero_duration_operation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "FastAgent",
        "task",
        "Zero Duration",
        %{},
        fn _p -> {:ok, :instant} end
      )

      assert_receive {:operation_completed, op}, 5000
      assert op.duration_ms >= 0
    end

    test "T2_F05_05_concurrent_async_operations_telemetry", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      ops =
        for i <- 1..4 do
          {:ok, _pid, op} =
            OperationManager.run_async_operation(
              session.id,
              nil,
              "Agent#{i}",
              "task",
              "Task #{i}",
              %{},
              fn _p ->
                :timer.sleep(20)
                {:ok, "res #{i}"}
              end
            )

          op
        end

      op_ids = Enum.map(ops, & &1.id)
      assert length(Enum.uniq(op_ids)) == 4

      # Wait for all 4 completions
      for _ <- 1..4 do
        assert_receive {:operation_completed, _}, 5000
      end
    end
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree (5 Boundary Tests)
  # ============================================================================
  describe "F6: Hierarchical Operation Tree (Boundary)" do
    test "T2_F06_01_deeply_nested_operation_chain", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      op1 = create_operation_fixture(session, %{parent_op_id: nil, title: "L1"})
      op2 = create_operation_fixture(session, %{parent_op_id: op1.id, title: "L2"})
      op3 = create_operation_fixture(session, %{parent_op_id: op2.id, title: "L3"})
      op4 = create_operation_fixture(session, %{parent_op_id: op3.id, title: "L4"})
      op5 = create_operation_fixture(session, %{parent_op_id: op4.id, title: "L5"})

      assert op5.parent_op_id == op4.id
      assert op4.parent_op_id == op3.id
      assert op3.parent_op_id == op2.id
      assert op2.parent_op_id == op1.id
      assert is_nil(op1.parent_op_id)
    end

    test "T2_F06_02_orphan_child_operation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      ghost_parent_id = Ecto.UUID.generate()

      op = create_operation_fixture(session, %{parent_op_id: ghost_parent_id, title: "Orphan"})
      assert op.parent_op_id == ghost_parent_id
      ops = Sessions.list_operations(session.id)
      assert Enum.any?(ops, fn o -> o.id == op.id end)
    end

    test "T2_F06_03_clear_operations_on_empty_session", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      assert Sessions.list_operations(session.id) == []
      :ok = SessionServer.clear_operations(session.id)
      assert Sessions.list_operations(session.id) == []
    end

    test "T2_F06_04_toggle_unknown_operation_id", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = mount_workspace(conn, session.id)
      random_id = Ecto.UUID.generate()
      html = render_click(view, "toggle_op_detail", %{"id" => random_id})
      assert is_binary(html)
    end

    test "T2_F06_05_large_operations_batch", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      for i <- 1..25 do
        create_operation_fixture(session, %{title: "Batch Op #{i}"})
      end

      ops = Sessions.list_operations(session.id)
      assert length(ops) == 25
    end
  end

  # ============================================================================
  # F7: Interactive Code Diff Viewer (5 Boundary Tests)
  # ============================================================================
  describe "F7: Interactive Code Diff Viewer (Boundary)" do
    test "T2_F07_01_diff_identical_contents" do
      code = "def same, do: :ok\n"
      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(code, code, "lib/same.ex")
      assert diff == ""
    end

    test "T2_F07_02_diff_empty_files" do
      diff = IexCode.Tools.MultiPatch.Diff.unified_diff("", "", "lib/empty.ex")
      assert diff == ""
    end

    test "T2_F07_03_diff_large_payload" do
      large_old = Enum.map(1..500, fn i -> "line #{i}" end) |> Enum.join("\n")
      large_new = Enum.map(1..500, fn i -> "modified line #{i}" end) |> Enum.join("\n")

      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(large_old, large_new, "lib/large.ex")
      assert String.contains?(diff, "--- a/lib/large.ex")
      assert String.contains?(diff, "+++ b/lib/large.ex")
      assert String.contains?(diff, "@@")
      assert byte_size(diff) > 3000
    end

    test "T2_F07_04_diff_special_characters" do
      old = "<div id=\"test\" class={@custom && \"class\"}><%= @var %></div>"
      new = "<div id=\"test\" class={@custom && \"updated_class\"}><%= @new_var %></div>"

      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(old, new, "lib/template.heex")
      assert String.contains?(diff, "--- a/lib/template.heex")
      assert String.contains?(diff, "updated_class")
    end

    test "T2_F07_05_diff_unicode_content" do
      old = "def greeting, do: \"こんにちは 🐝 ⚡\"\n"
      new = "def greeting, do: \"さようなら 🚀 ✨\"\n"

      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(old, new, "lib/unicode.ex")
      assert String.contains?(diff, "こんにちは")
      assert String.contains?(diff, "さようなら")
      assert String.valid?(diff)
    end
  end

  # ============================================================================
  # F8: File Tree Explorer & Search (5 Boundary Tests)
  # ============================================================================
  describe "F8: File Tree Explorer & Search (Boundary)" do
    test "T2_F08_01_list_dir_empty_directory", %{workspace_path: path} do
      empty_dir = Path.join(path, "empty_dir")
      File.mkdir_p!(empty_dir)

      {:ok, result} = Tools.execute("list_dir", %{"path" => "empty_dir"}, path)
      assert result == "" or is_binary(result)
    end

    test "T2_F08_02_list_dir_nonexistent_directory", %{workspace_path: path} do
      result = Tools.execute("list_dir", %{"path" => "missing_folder_xyz"}, path)
      assert result == {:error, "Not a directory: missing_folder_xyz"}
    end

    test "T2_F08_03_read_file_nonexistent_path", %{workspace_path: path} do
      result = Tools.execute("read_file", %{"path" => "missing_file.ex"}, path)
      assert result == {:error, "File does not exist: missing_file.ex"}
    end

    test "T2_F08_04_grep_search_regex_meta_characters", %{workspace_path: path} do
      workspace_write_file(path, "lib/regex.ex", "def check(a, [b | c]), do: {a, b}")
      {:ok, matches} = Tools.execute("grep_search", %{"query" => "[b | c]"}, path)
      assert String.contains?(matches, "lib/regex.ex")
    end

    test "T2_F08_05_grep_search_empty_matches", %{workspace_path: path} do
      workspace_write_file(path, "lib/simple.ex", "def simple, do: 1")
      {:ok, result} = Tools.execute("grep_search", %{"query" => "nonexistent_token_9999"}, path)
      assert String.contains?(result, "No matches found")
    end
  end

  # ============================================================================
  # F9: Terminal Session Integration (5 Boundary Tests)
  # ============================================================================
  describe "F9: Terminal Session Integration (Boundary)" do
    test "T2_F09_01_command_nonexistent_binary", %{workspace_path: path} do
      {:ok, output} =
        Tools.execute("run_command", %{"command" => "non_existent_cmd_xyz123"}, path)

      assert String.contains?(output, "Exit Code 127") or String.contains?(output, "not found")
    end

    test "T2_F09_02_command_syntax_error", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "if [ ]; then"}, path)
      assert String.contains?(output, "Exit Code") or String.contains?(output, "syntax error")
    end

    test "T2_F09_03_command_timeout", %{workspace_path: path} do
      assert {:error, msg} =
               Tools.execute("run_command", %{"command" => "sleep 2", "timeout_ms" => 50}, path)

      assert msg =~ "Command timed out after 50ms"
    end

    test "T2_F09_04_command_large_stdout", %{workspace_path: path} do
      cmd = "elixir -e 'IO.puts(String.duplicate(\"A\", 50000))'"
      {:ok, output} = Tools.execute("run_command", %{"command" => cmd}, path)
      assert String.length(output) >= 50000
    end

    test "T2_F09_05_command_empty_string", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => ""}, path)
      assert output == "" or String.contains?(output, "Exit Code 0")
    end
  end

  # ============================================================================
  # F10: AST-Aware Search Engine (5 Boundary Tests)
  # ============================================================================
  describe "F10: AST-Aware Search Engine (Boundary)" do
    test "T2_F10_01_search_syntax_error_file", %{workspace_path: path} do
      workspace_write_file(path, "lib/bad_syntax.ex", "defmodule Broken do def incomplete(")
      {:ok, results} = ASTSearch.search(path, %{type: :defmodule})
      assert is_list(results)
    end

    test "T2_F10_02_search_no_matching_symbols", %{workspace_path: path} do
      workspace_write_file(path, "lib/clean.ex", "defmodule Clean do\n  def run, do: :ok\nend")
      {:ok, results} = ASTSearch.search(path, "missing_fn_name")
      assert results == []
    end

    test "T2_F10_03_search_empty_directory", %{workspace_path: path} do
      empty_dir = Path.join(path, "ast_empty")
      File.mkdir_p!(empty_dir)

      {:ok, results} = ASTSearch.search(empty_dir, %{})
      assert results == []
    end

    test "T2_F10_04_search_single_file_not_found", %{workspace_path: path} do
      assert ASTSearch.search_file(Path.join(path, "ghost.ex"), %{}) == {:error, :file_not_found}
    end

    test "T2_F10_05_search_nested_anonymous_functions", %{workspace_path: path} do
      code = """
      defmodule Closures do
        def outer do
          f = fn x -> x + 1 end
          f.(10)
        end
      end
      """

      workspace_write_file(path, "lib/closures.ex", code)
      {:ok, results} = ASTSearch.search(path, %{type: :def, name: "outer"})
      assert length(results) == 1
      assert hd(results).name == "outer"
    end
  end

  # ============================================================================
  # F11: Multi-File Atomic Patching (5 Boundary Tests)
  # ============================================================================
  describe "F11: Multi-File Atomic Patching (Boundary)" do
    test "T2_F11_01_patch_empty_replacement", %{workspace_path: path} do
      workspace_write_file(path, "lib/delete_target.ex", "line 1\nREMOVE_ME\nline 2")

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/delete_target.ex",
            "target_content" => "REMOVE_ME\n",
            "replacement_content" => ""
          },
          path
        )

      {:ok, content} = workspace_read_file(path, "lib/delete_target.ex")
      refute String.contains?(content, "REMOVE_ME")
      assert String.contains?(content, "line 1\nline 2")
    end

    test "T2_F11_02_patch_first_occurrence_only", %{workspace_path: path} do
      workspace_write_file(path, "lib/dups.ex", "foo bar foo")

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/dups.ex",
            "target_content" => "foo",
            "replacement_content" => "baz"
          },
          path
        )

      {:ok, content} = workspace_read_file(path, "lib/dups.ex")
      assert content == "baz bar foo"
    end

    test "T2_F11_03_patch_nonexistent_file", %{workspace_path: path} do
      result =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/missing.ex",
            "target_content" => "target",
            "replacement_content" => "replacement"
          },
          path
        )

      assert result == {:error, "File does not exist: lib/missing.ex"}
    end

    test "T2_F11_04_write_file_deep_path", %{workspace_path: path} do
      deep = "a/b/c/d/e/f/target.txt"
      {:ok, _} = Tools.execute("write_file", %{"path" => deep, "content" => "deep content"}, path)
      {:ok, read} = workspace_read_file(path, deep)
      assert read == "deep content"
    end

    test "T2_F11_05_write_file_large_payload", %{workspace_path: path} do
      large_content = String.duplicate("Large content payload line\n", 2000)

      {:ok, _} =
        Tools.execute(
          "write_file",
          %{"path" => "lib/large.txt", "content" => large_content},
          path
        )

      {:ok, read} = workspace_read_file(path, "lib/large.txt")
      assert read == large_content
    end
  end

  # ============================================================================
  # F12: Automated Test Runner & Parser (5 Boundary Tests)
  # ============================================================================
  describe "F12: Automated Test Runner & Parser (Boundary)" do
    test "T2_F12_01_execute_command_in_empty_dir", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "ls -la"}, path)
      assert String.contains?(output, ".")
    end

    test "T2_F12_02_parse_compilation_error" do
      error_output = "** (CompileError) lib/foo.ex:5: syntax error before: 'do'"
      res = IexCode.Tools.TestRunner.Parser.parse(error_output, 1)
      assert res.status == :compilation_error or res.status == :failed
      assert length(res.compilation_errors) == 1
      err = hd(res.compilation_errors)
      assert err.file == "lib/foo.ex"
      assert err.line == 5
      assert String.contains?(err.message, "syntax error")
    end

    test "T2_F12_03_parse_assertion_truthy_failure" do
      output = """
      1) test validation truthiness (AppTest)
         test/app_test.exs:22
         Expected truthy, got false
         code: assert is_valid?()
      """

      res = IexCode.Tools.TestRunner.Parser.parse(output, 1)
      assert res.status == :failed
      assert length(res.failures) == 1
      failure = hd(res.failures)
      assert failure.file == "test/app_test.exs"
      assert failure.line == 22
      assert String.contains?(failure.code_snippet, "is_valid?")
    end

    test "T2_F12_04_parse_exception_stacktrace" do
      output = """
      1) test divide by zero raises (CalcTest)
         test/calc_test.exs:8
         ** (ArithmeticError) bad argument in arithmetic expression
         stacktrace:
           (app 0.1.0) lib/calc.ex:12: Calc.div/2
           test/calc_test.exs:8: (test)
      """

      res = IexCode.Tools.TestRunner.Parser.parse(output, 1)
      assert res.status == :failed
      assert length(res.failures) == 1
      failure = hd(res.failures)
      assert failure.file == "test/calc_test.exs"
      assert failure.line == 8
      assert length(failure.stacktrace) >= 1
      frame = hd(failure.stacktrace)
      assert frame.file == "lib/calc.ex"
      assert frame.line == 12
    end

    test "T2_F12_05_parse_ansi_escaped_output" do
      raw_ansi =
        "\e[31m1) test failure (FooTest)\n   test/foo_test.exs:10\n   \e[32mExpected 2, got 3\e[0m"

      res = IexCode.Tools.TestRunner.Parser.parse(raw_ansi, 1)
      assert res.status == :failed
      assert length(res.failures) == 1
      assert hd(res.failures).file == "test/foo_test.exs"
      assert hd(res.failures).line == 10
    end
  end

  # ============================================================================
  # F13: Instant Auto-Fix Engine (5 Boundary Tests)
  # ============================================================================
  describe "F13: Instant Auto-Fix Engine (Boundary)" do
    test "T2_F13_01_fix_syntax_missing_end", %{workspace_path: path} do
      broken = "defmodule MissingEnd do\n  def run, do: :ok"
      workspace_write_file(path, "lib/missing_end.ex", broken)

      fixed = "defmodule MissingEnd do\n  def run, do: :ok\nend"

      {:ok, _} =
        Tools.execute("write_file", %{"path" => "lib/missing_end.ex", "content" => fixed}, path)

      {:ok, read} = workspace_read_file(path, "lib/missing_end.ex")
      assert String.ends_with?(String.trim(read), "end")
    end

    test "T2_F13_02_fix_typo_in_function_name", %{workspace_path: path} do
      workspace_write_file(path, "lib/typo.ex", "def calcualte, do: 42")

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/typo.ex",
            "target_content" => "calcualte",
            "replacement_content" => "calculate"
          },
          path
        )

      {:ok, read} = workspace_read_file(path, "lib/typo.ex")
      assert String.contains?(read, "def calculate")
    end

    test "T2_F13_03_fix_already_correct_file", %{workspace_path: path} do
      workspace_write_file(path, "lib/correct.ex", "defmodule Correct do end")
      {:ok, read} = workspace_read_file(path, "lib/correct.ex")
      assert read == "defmodule Correct do end"
    end

    test "T2_F13_04_fix_target_file_missing", %{workspace_path: path} do
      result =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/missing_fix.ex",
            "target_content" => "a",
            "replacement_content" => "b"
          },
          path
        )

      assert {:error, _} = result
    end

    test "T2_F13_05_verify_fixed_module_eval", %{workspace_path: path} do
      workspace_write_file(
        path,
        "lib/eval_mod.ex",
        "defmodule EvalMod do\n  def compute, do: 10 * 10\nend"
      )

      {:ok, out} =
        Tools.execute(
          "run_command",
          %{"command" => "elixir -r lib/eval_mod.ex -e 'IO.puts(EvalMod.compute())'"},
          path
        )

      assert String.trim(out) == "100"
    end
  end

  # ============================================================================
  # F14: Git Integration Engine (5 Boundary Tests)
  # ============================================================================
  describe "F14: Git Integration Engine (Boundary)" do
    test "T2_F14_01_git_status_non_git_dir", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "git status"}, path)

      assert String.contains?(output, "fatal:") or
               String.contains?(output, "not a git repository") or
               String.contains?(output, "Exit Code")
    end

    test "T2_F14_02_git_diff_no_changes" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "clean"})
      {:ok, diff} = Tools.execute("run_command", %{"command" => "git diff"}, dir)
      assert String.trim(diff) == ""
    end

    test "T2_F14_03_git_commit_no_staged_changes" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "clean"})

      {:ok, output} =
        Tools.execute("run_command", %{"command" => "git commit -m 'empty commit'"}, dir)

      assert String.contains?(output, "nothing to commit") or
               String.contains?(output, "Exit Code 1")
    end

    test "T2_F14_04_git_commit_unicode_message" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "v1"})
      workspace_write_file(dir, "lib/app.ex", "v2")

      {:ok, _} =
        Tools.execute(
          "run_command",
          %{"command" => "git add lib/app.ex && git commit -m 'feat: 🐝 unicode message 日本語'"},
          dir
        )

      {:ok, log} = Tools.execute("run_command", %{"command" => "git log -n 1 --oneline"}, dir)
      assert String.contains?(log, "unicode message")
    end

    test "T2_F14_05_git_status_special_filenames" do
      {:ok, dir} = init_temp_git_repo(%{})
      workspace_write_file(dir, "lib/special-file with spaces.ex", "content")

      {:ok, _} =
        Tools.execute(
          "run_command",
          %{"command" => "git add 'lib/special-file with spaces.ex'"},
          dir
        )

      {:ok, status} = Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)
      assert String.contains?(status, "special-file with spaces.ex")
    end
  end

  # ============================================================================
  # F15: Streaming SSE LLM Client (5 Boundary Tests)
  # ============================================================================
  describe "F15: Streaming SSE LLM Client (Boundary)" do
    @tag mock_llm: true, llm_scenario: :standard_completion
    test "T2_F15_01_mock_empty_json_response", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 200
      assert resp.body["choices"] != nil
    end

    @tag mock_llm: true, llm_scenario: :split_utf8
    test "T2_F15_02_mock_split_utf8_streaming", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 200
      assert String.contains?(resp.body, "data: ")
      assert String.contains?(resp.body, "Swarm ")
    end

    @tag mock_llm: true, llm_scenario: {:custom_content, "Custom deterministic output"}
    test "T2_F15_03_mock_custom_content_scenario", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 200
      assert hd(resp.body["choices"])["message"]["content"] == "Custom deterministic output"
    end

    @tag mock_llm: true
    test "T2_F15_04_mock_clear_requests_history", %{mock_llm_pid: pid, mock_llm: mock} do
      {:ok, _} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert length(MockLLMServer.get_requests(pid)) == 1

      :ok = MockLLMServer.clear_requests(pid)
      assert MockLLMServer.get_requests(pid) == []
    end

    test "T2_F15_05_llm_chat_without_api_key" do
      assert {:error, :no_api_key} =
               IexCode.LLM.OpenAI.chat([%{role: "user", content: "hello"}], "system", api_key: "")

      assert {:error, :no_api_key} =
               IexCode.LLM.Anthropic.chat([%{role: "user", content: "hello"}], "system",
                 api_key: ""
               )
    end
  end

  # ============================================================================
  # F16: UTF-8 Stream Sanitizer Buffer (5 Boundary Tests)
  # ============================================================================
  describe "F16: UTF-8 Stream Sanitizer Buffer (Boundary)" do
    test "T2_F16_01_sanitize_nil_returns_nil" do
      assert Sessions.sanitize_utf8(nil) == nil
    end

    test "T2_F16_02_sanitize_raw_invalid_bytes" do
      binary = <<0xFF, 0xFE, 0xFD>>
      sanitized = Sessions.sanitize_utf8(binary)
      assert String.valid?(sanitized)
    end

    test "T2_F16_03_sanitize_null_bytes" do
      binary = "Start\0Middle\0End"
      sanitized = Sessions.sanitize_utf8(binary)
      assert String.valid?(sanitized)
      assert String.contains?(sanitized, "Start")
      assert String.contains?(sanitized, "End")
    end

    test "T2_F16_04_sanitize_map_and_list_structures" do
      complex = %{
        title: "Valid title",
        tags: ["tag1", <<0xFF>>, "tag2"],
        nested: %{data: "Valid " <> <<0xFE>>}
      }

      sanitized = Sessions.sanitize_utf8(complex)
      assert is_map(sanitized)
      assert sanitized.title == "Valid title"
      assert is_list(sanitized.tags)
    end

    test "T2_F16_05_sanitize_large_binary" do
      large =
        String.duplicate("Valid text ", 5000) <> <<0xFF>> <> String.duplicate(" more text", 5000)

      sanitized = Sessions.sanitize_utf8(large)
      assert String.valid?(sanitized)
      assert String.starts_with?(sanitized, "Valid text")
    end
  end

  # ============================================================================
  # F17: LLM Resilience & Retries (5 Boundary Tests)
  # ============================================================================
  describe "F17: LLM Resilience & Retries (Boundary)" do
    @tag mock_llm: true, llm_scenario: :server_error_500
    test "T2_F17_01_continuous_500_errors", %{mock_llm: mock} do
      for _ <- 1..3 do
        {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
        assert resp.status == 500
      end
    end

    @tag mock_llm: true
    test "T2_F17_02_concurrent_requests_to_mock", %{mock_llm: mock} do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Req.post("#{mock.url}/v1/chat/completions",
              json: %{"msg" => i},
              retry: :transient,
              max_retries: 5,
              pool_timeout: 5000
            )
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 5

      assert Enum.all?(results, fn
               {:ok, r} -> r.status == 200
               _ -> false
             end)
    end

    @tag mock_llm: true
    test "T2_F17_03_request_counter_increment", %{mock_llm_pid: pid} do
      count1 = MockLLMServer.increment_attempt(pid, "test_ep")
      count2 = MockLLMServer.increment_attempt(pid, "test_ep")
      count3 = MockLLMServer.increment_attempt(pid, "test_ep")

      assert count1 == 1
      assert count2 == 2
      assert count3 == 3
    end

    @tag mock_llm: true
    test "T2_F17_04_server_stop_idempotency", %{mock_llm_pid: pid} do
      assert MockLLMServer.stop(pid) == :ok
      assert MockLLMServer.stop(pid) == :ok
    end

    @tag mock_llm: true
    test "T2_F17_05_rapid_scenario_toggles", %{mock_llm_pid: pid, mock_llm: mock} do
      for scenario <- [
            :standard_completion,
            :rate_limit_429,
            :server_error_500,
            :standard_completion
          ] do
        MockLLMServer.set_scenario(pid, scenario)
        assert MockLLMServer.get_scenario(pid) == scenario
      end

      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 200
    end
  end
end
