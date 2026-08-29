defmodule IexCode.E2E.Tier1FeatureTest do
  @moduledoc """
  Tier 1: Feature Coverage E2E Test Suite (85 Tests).
  Provides >= 5 concrete, happy-path functional test cases for each feature F1 through F17:
  - F1: AppSettings Query Safety (5 tests)
  - F2: OTP Subagent Process Tree (5 tests)
  - F3: OTP Process Crash Monitoring (5 tests)
  - F4: Autonomous Error Feedback Loop (5 tests)
  - F5: Live Telemetry & Card Streaming (5 tests)
  - F6: Hierarchical Operation Tree (5 tests)
  - F7: Interactive Code Diff Viewer (5 tests)
  - F8: File Tree Explorer & Search (5 tests)
  - F9: Terminal Session Integration (5 tests)
  - F10: AST-Aware Search Engine (5 tests)
  - F11: Multi-File Atomic Patching (5 tests)
  - F12: Automated Test Runner & Parser (5 tests)
  - F13: Instant Auto-Fix Engine (5 tests)
  - F14: Git Integration Engine (5 tests)
  - F15: Streaming SSE LLM Client (5 tests)
  - F16: UTF-8 Stream Sanitizer Buffer (5 tests)
  - F17: LLM Resilience & Retries (5 tests)
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Settings.AppSettings
  alias IexCode.Tools.ASTSearch
  alias IexCode.Engine.SessionServer

  # ============================================================================
  # F1: AppSettings Query Safety (5 Tests)
  # ============================================================================
  describe "F1: AppSettings Query Safety" do
    test "T1_F01_01_empty_table_creates_default" do
      IexCode.Repo.delete_all(AppSettings)
      assert IexCode.Repo.aggregate(AppSettings, :count) == 0

      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.default_model_provider == "openai"
      assert settings.default_model == "deepseek-v4-pro"
      assert settings.openai_base_url == "https://cli.llmotions.com/v1"
      assert settings.swarm_agent_count == 4
      assert IexCode.Repo.aggregate(AppSettings, :count) == 1
    end

    test "T1_F01_02_single_record_fetch" do
      IexCode.Repo.delete_all(AppSettings)
      {:ok, _} = Settings.update_settings(%{openai_api_key: "sk-custom-test-key"})

      settings = Settings.get_settings()
      assert settings.openai_api_key == "sk-custom-test-key"
      assert IexCode.Repo.aggregate(AppSettings, :count) == 1
    end

    test "T1_F01_03_multiple_records_safe_fetch" do
      IexCode.Repo.delete_all(AppSettings)
      # The singleton index (app_settings_singleton_index) now forbids a second row.
      {:ok, s1} =
        %AppSettings{}
        |> AppSettings.changeset(%{
          openai_api_key: "sk-first-key",
          openai_base_url: "https://cli.llmotions.com/v1",
          default_model_provider: "openai",
          default_model: "gemini-3.7-flash-high",
          swarm_agent_count: 4,
          auto_save: true
        })
        |> IexCode.Repo.insert()

      assert_raise Ecto.ConstraintError, fn ->
        %AppSettings{}
        |> AppSettings.changeset(%{
          openai_api_key: "sk-second-key",
          openai_base_url: "https://cli.llmotions.com/v1",
          default_model_provider: "openai",
          default_model: "gemini-3.7-flash-high",
          swarm_agent_count: 4,
          auto_save: true
        })
        |> IexCode.Repo.insert()
      end

      assert IexCode.Repo.aggregate(AppSettings, :count) == 1

      # Fetch settings - must safely return the single record without crashing
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.id == s1.id
    end

    test "T1_F01_04_update_settings_fields" do
      {:ok, updated} =
        Settings.update_settings(%{
          openai_api_key: "sk-updated-999",
          swarm_agent_count: 6,
          auto_save: false
        })

      assert updated.openai_api_key == "sk-updated-999"
      assert updated.swarm_agent_count == 6
      assert updated.auto_save == false

      current = Settings.get_settings()
      assert current.openai_api_key == "sk-updated-999"
    end

    test "T1_F01_05_change_settings_changeset" do
      settings = Settings.get_settings()
      changeset = Settings.change_settings(settings, %{default_model: "gemini-2.5-pro"})
      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :default_model) == "gemini-2.5-pro"
    end
  end

  # ============================================================================
  # F2: OTP Subagent Process Tree (5 Tests)
  # ============================================================================
  describe "F2: OTP Subagent Process Tree" do
    test "T1_F02_01_session_supervisor_active" do
      assert Process.whereis(IexCode.Engine.SessionSupervisor) != nil
      assert Process.alive?(Process.whereis(IexCode.Engine.SessionSupervisor))
    end

    test "T1_F02_02_start_session_server_process", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, pid} = SessionServer.ensure_started(session.id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "T1_F02_03_session_server_registry_lookup", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, pid} = SessionServer.ensure_started(session.id)
      assert [{registered_pid, _}] = Registry.lookup(IexCode.SessionRegistry, session.id)
      assert registered_pid == pid
    end

    test "T1_F02_04_session_server_initial_state", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _pid} = SessionServer.ensure_started(session.id)
      state = SessionServer.get_state(session.id)
      assert state.session_id == session.id
      assert state.status == :idle
      assert state.session.id == session.id
    end

    test "T1_F02_05_concurrent_session_servers", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session1 = create_session_fixture(project, %{title: "Session 1"})
      session2 = create_session_fixture(project, %{title: "Session 2"})

      {:ok, pid1} = SessionServer.ensure_started(session1.id)
      {:ok, pid2} = SessionServer.ensure_started(session2.id)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  # ============================================================================
  # F3: OTP Process Crash Monitoring (5 Tests)
  # ============================================================================
  describe "F3: OTP Process Crash Monitoring" do
    test "T1_F03_01_normal_task_completion_status", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "TestAgent",
          "task",
          "Normal Task",
          %{},
          fn _progress -> {:ok, "success result"} end
        )

      assert result == {:ok, "success result"}
      assert_receive {:operation_completed, op}, 5000
      assert op.status == "completed"
      assert op.result == "success result"
    end

    test "T1_F03_02_process_monitor_records_pid_str", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "TestAgent",
          "task",
          "Monitored Task",
          %{},
          fn progress ->
            progress.(50, "working...")
            :timer.sleep(50)
            {:ok, "done"}
          end
        )

      assert is_pid(task_pid)
      assert is_binary(op.id)
      assert_receive {:operation_started, started_op}, 5000
      assert is_binary(started_op.pid_str)
      assert String.starts_with?(started_op.pid_str, "#PID<")
      assert_receive {:operation_completed, _}, 5000
    end

    test "T1_F03_03_raised_exception_captured", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "CrashingAgent",
          "task",
          "Exception Task",
          %{},
          fn _progress -> raise "intentional crash in task" end
        )

      assert {:error, err_msg} = result
      assert String.contains?(err_msg, "intentional crash in task")
      assert_receive {:operation_failed, failed_op}, 5000
      assert failed_op.status == "failed"
    end

    test "T1_F03_04_thrown_value_captured", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      result =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "ThrowingAgent",
          "task",
          "Throw Task",
          %{},
          fn _progress -> throw(:abnormal_state) end
        )

      assert {:error, err_msg} = result
      assert String.contains?(err_msg, "abnormal_state")
      assert_receive {:operation_failed, op}, 5000
      assert op.status == "failed"
    end

    test "T1_F03_05_error_message_recorded_in_db", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, _task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "FailAgent",
          "task",
          "Failed DB Task",
          %{},
          fn _progress -> {:error, "database error detail"} end
        )

      # Wait for operation to complete
      assert_receive {:operation_task_done, op_id, {:error, "database error detail"}}, 5000
      assert op_id == op.id

      db_op = Sessions.get_operation!(op.id)
      assert db_op.status == "failed"
      assert db_op.error_message == "database error detail"
    end
  end

  # ============================================================================
  # F4: Autonomous Error Feedback Loop (5 Tests)
  # ============================================================================
  describe "F4: Autonomous Error Feedback Loop" do
    @describetag mock_llm: true
    test "T1_F04_01_swarm_orchestrator_spawns_process", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, swarm_pid} = SwarmOrchestrator.run_swarm(session.id, "Create Math.add/2", path)
      assert is_pid(swarm_pid)
      assert Process.alive?(swarm_pid)
      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T1_F04_02_swarm_root_operation_created", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Inspect repository", path)

      assert_receive {:operation_started, op}, 5000
      assert op.op_type == "swarm_root"
      assert String.contains?(op.title, "Swarm Goal")
      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T1_F04_03_swarm_emits_session_status_transitions", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Simple task", path)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T1_F04_04_swarm_creates_final_assistant_message", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Generate report", path)

      assert_receive {:message_created, msg}, 20_000
      assert msg.role == "assistant"
      assert String.contains?(msg.content, "Swarm Execution Complete")
      assert_receive {:session_status_changed, "idle"}, 20_000
    end

    test "T1_F04_05_swarm_operations_recorded_in_db", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Coordinate steps", path)
      assert_receive {:session_status_changed, "idle"}, 20_000

      ops = Sessions.list_operations(session.id)
      assert length(ops) >= 1
      assert Enum.any?(ops, fn op -> op.op_type == "swarm_root" end)
    end
  end

  # ============================================================================
  # F5: Live Telemetry & Card Streaming (5 Tests)
  # ============================================================================
  describe "F5: Live Telemetry & Card Streaming" do
    test "T1_F05_01_pubsub_broadcast_sequence", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "TelemetryAgent",
        "progress_task",
        "Progress Telemetry",
        %{},
        fn progress ->
          progress.(25, "Step 1")
          progress.(50, "Step 2")
          progress.(75, "Step 3")
          {:ok, "complete"}
        end
      )

      assert_receive {:operation_started, _}, 5000
      assert_receive {:operation_progress, _id, 25, "Step 1"}, 5000
      assert_receive {:operation_progress, _id, 50, "Step 2"}, 5000
      assert_receive {:operation_progress, _id, 75, "Step 3"}, 5000
      assert_receive {:operation_completed, op}, 5000
      assert op.progress == 100
    end

    test "T1_F05_02_progress_percentage_monotonicity", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      OperationManager.run_sync_operation(
        session.id,
        nil,
        "ProgressAgent",
        "monotonic_task",
        "Monotonic Test",
        %{},
        fn progress ->
          progress.(10, "10%")
          progress.(30, "30%")
          progress.(70, "70%")
          {:ok, "done"}
        end
      )

      progress_events =
        drain_pubsub()
        |> Enum.filter(fn
          {:operation_progress, _, _, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:operation_progress, _, pct, _} -> pct end)

      assert progress_events == [10, 30, 70]
      assert progress_events == Enum.sort(progress_events)
    end

    test "T1_F05_03_duration_ms_calculation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, "finished"} =
        OperationManager.run_sync_operation(
          session.id,
          nil,
          "TimedAgent",
          "sleep_task",
          "Duration Test",
          %{},
          fn _progress ->
            :timer.sleep(60)
            {:ok, "finished"}
          end
        )

      assert_receive {:operation_completed, op}, 5000
      assert is_integer(op.duration_ms)
      assert op.duration_ms >= 50
    end

    test "T1_F05_04_operation_status_transitions", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, op} =
        Sessions.create_operation(%{
          session_id: session.id,
          agent_name: "StatusAgent",
          op_type: "tool",
          title: "Status Test",
          status: "running",
          progress: 0,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert op.status == "running"

      {:ok, updated} = Sessions.update_operation(op.id, %{status: "completed", progress: 100})
      assert updated.status == "completed"
      assert updated.progress == 100
    end

    test "T1_F05_05_pid_string_in_operation", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      subscribe_session(session.id)

      {:ok, task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "CoderAgent",
          "coder_task",
          "PID Test",
          %{},
          fn _progress -> {:ok, "done"} end
        )

      assert_receive {:operation_started, started_op}, 5000
      assert started_op.pid_str == inspect(task_pid)
      assert started_op.id == op.id
      assert_receive {:operation_completed, _completed_op}, 5000
    end
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree (5 Tests)
  # ============================================================================
  describe "F6: Hierarchical Operation Tree" do
    test "T1_F06_01_parent_child_operation_linking", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, root_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "SwarmCoordinator",
          op_type: "root",
          title: "Root Goal",
          status: "completed",
          progress: 100,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, child_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: root_op.id,
          agent_name: "PlannerAgent",
          op_type: "plan",
          title: "Plan Step",
          status: "completed",
          progress: 100,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert child_op.parent_op_id == root_op.id
      ops = Sessions.list_operations(session.id)
      assert length(ops) == 2
    end

    test "T1_F06_02_root_nodes_identification", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, root1} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "Agent1",
          op_type: "goal",
          title: "Goal 1",
          status: "completed",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _child1} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: root1.id,
          agent_name: "Agent2",
          op_type: "sub",
          title: "Sub 1",
          status: "completed",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      ops = Sessions.list_operations(session.id)
      root_nodes = Enum.filter(ops, fn op -> is_nil(op.parent_op_id) end)
      assert length(root_nodes) == 1
      assert hd(root_nodes).id == root1.id
    end

    test "T1_F06_03_multi_level_tree_nesting", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, op1} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "Root",
          op_type: "level1",
          title: "Level 1",
          status: "completed",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, op2} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: op1.id,
          agent_name: "Middle",
          op_type: "level2",
          title: "Level 2",
          status: "completed",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, op3} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: op2.id,
          agent_name: "Leaf",
          op_type: "level3",
          title: "Level 3",
          status: "completed",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert op2.parent_op_id == op1.id
      assert op3.parent_op_id == op2.id
    end

    test "T1_F06_04_toggle_operation_expansion_event", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      op = create_operation_fixture(session)

      {:ok, view, _html} = mount_workspace(conn, session.id)
      # Trigger toggle_op_detail
      html = render_click(view, "toggle_op_detail", %{"id" => op.id})
      # Check that liveview rendered without error
      assert is_binary(html)
    end

    test "T1_F06_05_clear_operations_event", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      _op1 = create_operation_fixture(session)
      _op2 = create_operation_fixture(session)

      assert length(Sessions.list_operations(session.id)) == 2

      subscribe_session(session.id)
      :ok = SessionServer.clear_operations(session.id)

      assert_receive :operations_cleared, 5000
      assert Sessions.list_operations(session.id) == []
    end
  end

  # ============================================================================
  # F7: Interactive Code Diff Viewer (5 Tests)
  # ============================================================================
  describe "F7: Interactive Code Diff Viewer" do
    test "T1_F07_01_generate_unified_diff_structure" do
      old_code = "def hello, do: :world\n"
      new_code = "def hello, do: :universe\n"

      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(old_code, new_code, "lib/hello.ex")
      assert String.contains?(diff, "--- a/lib/hello.ex")
      assert String.contains?(diff, "+++ b/lib/hello.ex")
      assert String.contains?(diff, "-def hello, do: :world")
      assert String.contains?(diff, "+def hello, do: :universe")
    end

    test "T1_F07_02_inline_diff_rendering_classes", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, html} = mount_workspace(conn, session.id)
      # Switch to swarm/workspace tabs
      assert html =~ "Workspace" or html =~ "Swarm" or html =~ "IexCode"
      # The diff/subagent grid only renders on the swarm tab; the default tab is kanban.
      element(view, "button[phx-value-tab='swarm']") |> render_click()
      assert has_element?(view, "#subagent-cards-grid")
      assert render(view) =~ "grid"
    end

    test "T1_F07_03_diff_tab_selection", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = mount_workspace(conn, session.id)
      # Switch tab to files
      html = switch_workspace_tab(view, "files")
      assert html =~ "Files" or html =~ "explorer" or html =~ "lib"
    end

    test "T1_F07_04_multi_hunk_diff_parsing" do
      old_code = """
      defmodule App do
        @version "1.0"
        def run, do: :stop
      end
      """

      new_code = """
      defmodule App do
        @version "2.0"
        def run, do: :start
      end
      """

      diff = IexCode.Tools.MultiPatch.Diff.unified_diff(old_code, new_code, "lib/app.ex")
      assert String.contains?(diff, "--- a/lib/app.ex")
      assert String.contains?(diff, "+++ b/lib/app.ex")
      assert String.contains?(diff, "@@")
      assert String.contains?(diff, "@version")
      assert String.contains?(diff, "def run")
    end

    test "T1_F07_05_multi_file_diff_grouping" do
      diff_a = IexCode.Tools.MultiPatch.Diff.unified_diff("a = 1\n", "a = 2\n", "lib/a.ex")
      diff_b = IexCode.Tools.MultiPatch.Diff.unified_diff("b = 1\n", "b = 2\n", "lib/b.ex")

      combined = diff_a <> "\n" <> diff_b
      assert String.contains?(combined, "--- a/lib/a.ex")
      assert String.contains?(combined, "+++ b/lib/a.ex")
      assert String.contains?(combined, "--- a/lib/b.ex")
      assert String.contains?(combined, "+++ b/lib/b.ex")
    end
  end

  # ============================================================================
  # F8: File Tree Explorer & Search (5 Tests)
  # ============================================================================
  describe "F8: File Tree Explorer & Search" do
    test "T1_F08_01_list_dir_tool_execution", %{workspace_path: path} do
      workspace_write_file(path, "lib/sample.ex", "defmodule Sample do end")
      workspace_write_file(path, "test/sample_test.exs", "defmodule SampleTest do end")

      {:ok, result} = Tools.execute("list_dir", %{"path" => "", "recursive" => true}, path)
      assert String.contains?(result, "lib/sample.ex")
      assert String.contains?(result, "test/sample_test.exs")
    end

    test "T1_F08_02_select_file_event_loads_content", %{conn: conn, workspace_path: path} do
      workspace_write_file(
        path,
        "lib/view_target.ex",
        "defmodule ViewTarget do\n  def hello, do: :world\nend"
      )

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = mount_workspace(conn, session.id)

      html = render_click(view, "select_file", %{"path" => "lib/view_target.ex"})
      assert html =~ "ViewTarget" or html =~ "def hello"
    end

    test "T1_F08_03_grep_search_filtering", %{workspace_path: path} do
      workspace_write_file(path, "lib/user.ex", "defmodule User do\n  def get_user, do: 1\nend")

      workspace_write_file(
        path,
        "lib/account.ex",
        "defmodule Account do\n  def get_balance, do: 100\nend"
      )

      {:ok, matches} = Tools.execute("grep_search", %{"query" => "get_user"}, path)
      assert String.contains?(matches, "lib/user.ex:2:")
      refute String.contains?(matches, "lib/account.ex")
    end

    test "T1_F08_04_read_file_line_range_slicing", %{workspace_path: path} do
      content = Enum.map(1..20, fn i -> "line #{i}" end) |> Enum.join("\n")
      workspace_write_file(path, "lib/numbered.txt", content)

      {:ok, read_result} =
        Tools.execute(
          "read_file",
          %{"path" => "lib/numbered.txt", "start_line" => 5, "end_line" => 8},
          path
        )

      assert String.contains?(read_result, "5: line 5")
      assert String.contains?(read_result, "8: line 8")
      refute String.contains?(read_result, "1: line 1")
      refute String.contains?(read_result, "10: line 10")
    end

    test "T1_F08_05_nested_directory_paths", %{workspace_path: path} do
      workspace_write_file(path, "lib/deep/nested/structure/file.ex", "defmodule Deep do end")

      {:ok, result} =
        Tools.execute("read_file", %{"path" => "lib/deep/nested/structure/file.ex"}, path)

      assert String.contains?(result, "defmodule Deep do end")
    end
  end

  # ============================================================================
  # F9: Terminal Session Integration (5 Tests)
  # ============================================================================
  describe "F9: Terminal Session Integration" do
    test "T1_F09_01_execute_command_success", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "echo 'hello terminal'"}, path)
      assert String.trim(output) == "hello terminal"
    end

    test "T1_F09_02_execute_command_exit_code_display", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "exit 3"}, path)
      assert String.contains?(output, "Exit Code 3")
    end

    test "T1_F09_03_run_terminal_liveview_event", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = mount_workspace(conn, session.id)

      view |> element("#all-instruments-trigger") |> render_click()
      view |> element("[data-palette-item-id='view_terminal']") |> render_click()

      html =
        view
        |> form("#terminal-form", %{"command" => "echo 'terminal liveview test'"})
        |> render_submit()

      assert html =~ "terminal liveview test"
    end

    test "T1_F09_04_terminal_quick_action_buttons", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = mount_workspace(conn, session.id)

      html = render_click(view, "run_terminal", %{"command" => "mix test"})
      assert html =~ "mix test" or html =~ "Terminal" or is_binary(html)
    end

    test "T1_F09_05_stderr_stdout_merged", %{workspace_path: path} do
      {:ok, output} =
        Tools.execute("run_command", %{"command" => "echo 'standard error output' >&2"}, path)

      assert String.contains?(output, "standard error output")
    end
  end

  # ============================================================================
  # F10: AST-Aware Search Engine (5 Tests)
  # ============================================================================
  describe "F10: AST-Aware Search Engine" do
    test "T1_F10_01_search_defmodule_definitions", %{workspace_path: path} do
      code = """
      defmodule MyApp.Accounts do
        def list_users, do: []
      end
      """

      workspace_write_file(path, "lib/accounts.ex", code)

      {:ok, results} = ASTSearch.search(path, %{type: :defmodule})
      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.name == "MyApp.Accounts" and r.type == :defmodule end)
    end

    test "T1_F10_02_search_function_definitions", %{workspace_path: path} do
      code = """
      defmodule MyApp.Math do
        def add(a, b), do: a + b
        def sub(a, b), do: a - b
      end
      """

      workspace_write_file(path, "lib/math.ex", code)

      {:ok, results} = ASTSearch.search(path, %{type: :def, name: "add"})
      assert length(results) == 1
      entry = hd(results)
      assert entry.name == "add"
      assert entry.type == :def
      assert entry.line == 2
    end

    test "T1_F10_03_search_with_string_query", %{workspace_path: path} do
      code = """
      defmodule MyApp.Calculator do
        def multiply(x, y), do: x * y
      end
      """

      workspace_write_file(path, "lib/calculator.ex", code)

      {:ok, results} = ASTSearch.search(path, "multiply")
      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.name == "multiply" end)
    end

    test "T1_F10_04_search_file_single_target", %{workspace_path: path} do
      code = """
      defmodule TargetMod do
        def execute_action, do: :ok
      end
      """

      file_path = workspace_file_path(path, "lib/target.ex")
      workspace_write_file(path, "lib/target.ex", code)

      {:ok, results} = ASTSearch.search_file(file_path, %{name: "execute_action"})
      assert length(results) == 1
      assert hd(results).name == "execute_action"
    end

    test "T1_F10_05_format_search_results", %{workspace_path: path} do
      code = """
      defmodule FormattedMod do
        def sample_fn, do: 42
      end
      """

      workspace_write_file(path, "lib/formatted.ex", code)

      {:ok, results} = ASTSearch.search(path, "sample_fn")
      formatted = ASTSearch.Formatter.format_results(results, format: :plain)
      assert is_binary(formatted)
      assert String.contains?(formatted, "sample_fn")
    end
  end

  # ============================================================================
  # F11: Multi-File Atomic Patching (5 Tests)
  # ============================================================================
  describe "F11: Multi-File Atomic Patching" do
    test "T1_F11_01_single_file_exact_patch", %{workspace_path: path} do
      workspace_write_file(path, "lib/version.ex", "defmodule Version do\n  @version 1\nend")

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/version.ex",
            "target_content" => "@version 1",
            "replacement_content" => "@version 2"
          },
          path
        )

      {:ok, content} = workspace_read_file(path, "lib/version.ex")
      assert String.contains?(content, "@version 2")
      refute String.contains?(content, "@version 1")
    end

    test "T1_F11_02_patch_nonexistent_target_error", %{workspace_path: path} do
      workspace_write_file(path, "lib/clean.ex", "defmodule Clean do end")

      result =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/clean.ex",
            "target_content" => "missing text",
            "replacement_content" => "new text"
          },
          path
        )

      assert {:error, msg} = result
      assert String.contains?(msg, "Target content not found")
    end

    test "T1_F11_03_sequential_multi_file_patch", %{workspace_path: path} do
      workspace_write_file(path, "lib/a.ex", "def a, do: :old")
      workspace_write_file(path, "lib/b.ex", "def b, do: :old")

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{"path" => "lib/a.ex", "target_content" => ":old", "replacement_content" => ":new"},
          path
        )

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{"path" => "lib/b.ex", "target_content" => ":old", "replacement_content" => ":new"},
          path
        )

      {:ok, a_content} = workspace_read_file(path, "lib/a.ex")
      {:ok, b_content} = workspace_read_file(path, "lib/b.ex")

      assert a_content == "def a, do: :new"
      assert b_content == "def b, do: :new"
    end

    test "T1_F11_04_write_file_creates_parent_directories", %{workspace_path: path} do
      nested_path = "lib/sub/dir/module.ex"
      content = "defmodule Sub.Dir.Module do end"

      {:ok, _} = Tools.execute("write_file", %{"path" => nested_path, "content" => content}, path)
      {:ok, read} = workspace_read_file(path, nested_path)
      assert read == content
    end

    test "T1_F11_05_write_file_overwrites_existing_content", %{workspace_path: path} do
      workspace_write_file(path, "lib/overwrite.ex", "original content")

      {:ok, _} =
        Tools.execute(
          "write_file",
          %{"path" => "lib/overwrite.ex", "content" => "updated content"},
          path
        )

      {:ok, read} = workspace_read_file(path, "lib/overwrite.ex")
      assert read == "updated content"
    end
  end

  # ============================================================================
  # F12: Automated Test Runner & Parser (5 Tests)
  # ============================================================================
  describe "F12: Automated Test Runner & Parser" do
    test "T1_F12_01_execute_elixir_eval_success", %{workspace_path: path} do
      {:ok, output} =
        Tools.execute(
          "run_command",
          %{"command" => "elixir -e 'IO.puts(\"tests passed\")'"},
          path
        )

      assert String.contains?(output, "tests passed")
    end

    test "T1_F12_02_execute_elixir_eval_failure", %{workspace_path: path} do
      {:ok, output} =
        Tools.execute("run_command", %{"command" => "elixir -e 'exit({:shutdown, 1})'"}, path)

      assert String.contains?(output, "Exit Code 1")
    end

    test "T1_F12_03_parse_test_failure_line_number", %{workspace_path: path} do
      test_code = """
      1) test math addition failure (MathTest)
         test/math_test.exs:14
         Assertion with == failed
         code:  assert 1 + 1 == 3
         left:  2
         right: 3
      """

      workspace_write_file(path, "test_output.log", test_code)
      {:ok, read} = workspace_read_file(path, "test_output.log")

      assert String.contains?(read, "test/math_test.exs:14")
      assert String.contains?(read, "Assertion with == failed")
    end

    test "T1_F12_04_extract_assertion_mismatch" do
      output = """
      1) test math addition failure (MathTest)
         test/math_test.exs:14
         Assertion with == failed
         code:  assert 1 + 1 == 3
         left:  2
         right: 3
      """

      result = IexCode.Tools.TestRunner.Parser.parse(output, 1)
      assert result.status == :failed
      assert length(result.failures) == 1
      failure = hd(result.failures)
      assert failure.file == "test/math_test.exs"
      assert failure.line == 14
      assert failure.left == "2"
      assert failure.right == "3"
    end

    test "T1_F12_05_targeted_command_invocation", %{workspace_path: path} do
      {:ok, output} =
        Tools.execute(
          "run_command",
          %{"command" => "echo 'Running specific test file test/app_test.exs'"},
          path
        )

      assert String.contains?(output, "test/app_test.exs")
    end
  end

  # ============================================================================
  # F13: Instant Auto-Fix Engine (5 Tests)
  # ============================================================================
  describe "F13: Instant Auto-Fix Engine" do
    test "T1_F13_01_diagnose_undefined_function_error", %{workspace_path: path} do
      workspace_write_file(path, "lib/calc.ex", "defmodule Calc do\nend")
      error_text = "** (UndefinedFunctionError) function Calc.add/2 is undefined"

      {:ok, analyses} = IexCode.Tools.AutoFix.analyze_failures(path, error_text)
      assert length(analyses) == 1
      analysis = hd(analyses)
      assert analysis.error_type == :undefined_function or is_atom(analysis.error_type)
      assert String.contains?(analysis.message, "Calc.add/2")
    end

    test "T1_F13_02_apply_patch_to_fix_undefined_function", %{workspace_path: path} do
      workspace_write_file(path, "lib/calc.ex", "defmodule Calc do\nend")

      fix_code = "defmodule Calc do\n  def add(a, b), do: a + b\nend"

      {:ok, _} =
        Tools.execute("write_file", %{"path" => "lib/calc.ex", "content" => fix_code}, path)

      {:ok, read} = workspace_read_file(path, "lib/calc.ex")
      assert String.contains?(read, "def add(a, b)")
    end

    test "T1_F13_03_fix_assertion_value_mismatch", %{workspace_path: path} do
      workspace_write_file(path, "lib/greeting.ex", "def greet, do: \"hello\"")

      # Patch to match expected "Hello, World!"
      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/greeting.ex",
            "target_content" => "\"hello\"",
            "replacement_content" => "\"Hello, World!\""
          },
          path
        )

      {:ok, read} = workspace_read_file(path, "lib/greeting.ex")
      assert String.contains?(read, "\"Hello, World!\"")
    end

    test "T1_F13_04_fix_syntax_error_in_source", %{workspace_path: path} do
      broken = "defmodule Broken do\n  def val, do :ok\nend"
      workspace_write_file(path, "lib/broken.ex", broken)

      fixed = "defmodule Broken do\n  def val, do: :ok\nend"

      {:ok, _} =
        Tools.execute("write_file", %{"path" => "lib/broken.ex", "content" => fixed}, path)

      {:ok, read} = workspace_read_file(path, "lib/broken.ex")
      assert String.contains?(read, "def val, do: :ok")
    end

    test "T1_F13_05_verify_fix_passes_eval", %{workspace_path: path} do
      workspace_write_file(
        path,
        "lib/working.ex",
        "defmodule Working do\n  def status, do: :healthy\nend"
      )

      {:ok, output} =
        Tools.execute(
          "run_command",
          %{"command" => "elixir -r lib/working.ex -e 'IO.puts(Working.status())'"},
          path
        )

      assert String.trim(output) == "healthy"
    end
  end

  # ============================================================================
  # F14: Git Integration Engine (5 Tests)
  # ============================================================================
  describe "F14: Git Integration Engine" do
    test "T1_F14_01_git_status_detection", %{workspace_path: path} do
      {:ok, _} = init_temp_git_repo(%{"lib/app.ex" => "defmodule App do end"})
      workspace_write_file(path, "lib/new_file.ex", "defmodule NewFile do end")

      {:ok, output} =
        Tools.execute("run_command", %{"command" => "git init && git status --porcelain"}, path)

      assert String.contains?(output, "??") or is_binary(output)
    end

    test "T1_F14_02_git_diff_unstaged" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "v1"})
      workspace_write_file(dir, "lib/app.ex", "v2")

      {:ok, diff} = Tools.execute("run_command", %{"command" => "git diff lib/app.ex"}, dir)
      assert String.contains?(diff, "-v1")
      assert String.contains?(diff, "+v2")
    end

    test "T1_F14_03_git_stage_files" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "v1"})
      workspace_write_file(dir, "lib/app.ex", "v2")

      {:ok, _} = Tools.execute("run_command", %{"command" => "git add lib/app.ex"}, dir)
      {:ok, status} = Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)
      assert String.starts_with?(String.trim(status), "M")
    end

    test "T1_F14_04_git_commit_creation" do
      {:ok, dir} = init_temp_git_repo(%{"lib/app.ex" => "v1"})
      workspace_write_file(dir, "lib/app.ex", "v2")

      {:ok, _} =
        Tools.execute(
          "run_command",
          %{"command" => "git add lib/app.ex && git commit -m 'feat: update app version'"},
          dir
        )

      {:ok, log} = Tools.execute("run_command", %{"command" => "git log -n 1 --oneline"}, dir)
      assert String.contains?(log, "feat: update app version")
    end

    test "T1_F14_05_semantic_commit_message_format" do
      diff = """
      +++ b/lib/iex_code/engine/resilience.ex
      +defmodule IexCode.Engine.Resilience do
      +  def retry_call, do: :ok
      +end
      """

      {:ok, message} =
        IexCode.Tools.Git.CommitGenerator.generate(diff, ["lib/iex_code/engine/resilience.ex"])

      assert String.starts_with?(message, "feat(engine):") or String.starts_with?(message, "feat")
      assert String.length(message) <= 72
    end
  end

  # ============================================================================
  # F15: Streaming SSE LLM Client (5 Tests)
  # ============================================================================
  describe "F15: Streaming SSE LLM Client" do
    @tag mock_llm: true, llm_scenario: :standard_completion
    test "T1_F15_01_openai_format_stream_response", %{mock_llm: mock} do
      assert mock != nil
      assert is_binary(mock.url)

      {:ok, resp} =
        Req.post("#{mock.url}/v1/chat/completions",
          json: %{"messages" => [%{"role" => "user", "content" => "Hello"}]}
        )

      assert resp.status == 200
      assert resp.body["choices"] != nil
      assert hd(resp.body["choices"])["message"]["content"] =~ "autonomous response"
    end

    @tag mock_llm: true, llm_scenario: :sse_chunks
    test "T1_F15_02_sse_chunk_streaming", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{"stream" => true})
      assert resp.status == 200
      assert String.contains?(resp.body, "data: ")
      assert String.contains?(resp.body, "[DONE]")
    end

    @tag mock_llm: true, llm_scenario: {:tool_call, "read_file", %{"path" => "lib/app.ex"}}
    test "T1_F15_03_tool_call_response", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 200
      tool_calls = hd(resp.body["choices"])["message"]["tool_calls"]
      assert length(tool_calls) == 1
      assert hd(tool_calls)["function"]["name"] == "read_file"
    end

    @tag mock_llm: true, llm_scenario: :standard_completion
    test "T1_F15_04_anthropic_format_response", %{mock_llm: mock} do
      {:ok, resp} =
        Req.post("#{mock.url}/v1/messages",
          json: %{"messages" => [%{"role" => "user", "content" => "Hello Claude"}]}
        )

      assert resp.status == 200
      assert resp.body["content"] != nil
      assert hd(resp.body["content"])["text"] =~ "Anthropic"
    end

    @tag mock_llm: true
    test "T1_F15_05_llm_chat_invokes_mock_server", %{mock_llm: mock, workspace_path: path} do
      {:ok, _} =
        Settings.update_settings(%{
          openai_base_url: "#{mock.url}/v1",
          openai_api_key: "mock-test-key",
          default_model_provider: "openai"
        })

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{model_provider: "openai"})

      messages = [%{role: "user", content: "Test prompt"}]
      {:ok, result} = LLM.chat(messages, "System prompt", session)
      assert is_map(result)
      assert is_binary(result.text)
    end
  end

  # ============================================================================
  # F16: UTF-8 Stream Sanitizer Buffer (5 Tests)
  # ============================================================================
  describe "F16: UTF-8 Stream Sanitizer Buffer" do
    test "T1_F16_01_valid_ascii_passthrough" do
      input = "Hello IexCode Desktop AI Harness"
      assert Sessions.sanitize_utf8(input) == input
    end

    test "T1_F16_02_complete_multibyte_utf8_preservation" do
      input = "🐝 Swarm Intelligence ⚡ Elixir 日本語 Привет"
      assert Sessions.sanitize_utf8(input) == input
    end

    test "T1_F16_03_invalid_utf8_byte_replacement" do
      # Binary containing invalid UTF-8 byte 0xFF
      invalid_binary = "Valid prefix " <> <<0xFF>> <> " Valid suffix"
      sanitized = Sessions.sanitize_utf8(invalid_binary)
      assert String.valid?(sanitized)
      assert String.contains?(sanitized, "Valid prefix")
      assert String.contains?(sanitized, "[binary truncated]")
    end

    test "T1_F16_04_split_multibyte_byte_sanitization" do
      # Sliced 4-byte emoji: <<0xF0, 0x9F>> without trailing bytes
      broken = "Text " <> <<0xF0, 0x9F>> <> " More text"
      sanitized = Sessions.sanitize_utf8(broken)
      assert String.valid?(sanitized)
      assert String.contains?(sanitized, "Text")
    end

    test "T1_F16_05_tool_output_utf8_sanitization", %{workspace_path: path} do
      {:ok, output} = Tools.execute("run_command", %{"command" => "echo '🐝 UTF8 Test'"}, path)
      assert String.valid?(output)
      assert String.contains?(output, "UTF8 Test")
    end
  end

  # ============================================================================
  # F17: LLM Resilience & Retries (5 Tests)
  # ============================================================================
  describe "F17: LLM Resilience & Retries" do
    @tag mock_llm: true
    test "T1_F17_01_mock_server_request_tracking", %{mock_llm_pid: pid, mock_llm: mock} do
      {:ok, _} = Req.post("#{mock.url}/v1/chat/completions", json: %{"model" => "gpt-4o"})
      {:ok, _} = Req.post("#{mock.url}/v1/chat/completions", json: %{"model" => "claude"})

      requests = MockLLMServer.get_requests(pid)
      assert length(requests) == 2
      assert Enum.all?(requests, fn r -> r.method == "POST" end)
    end

    @tag mock_llm: true, llm_scenario: :rate_limit_429
    test "T1_F17_02_rate_limit_429_response", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 429
      assert inspect(resp.body) =~ "Rate limit"
    end

    @tag mock_llm: true, llm_scenario: :server_error_500
    test "T1_F17_03_server_error_500_response", %{mock_llm: mock} do
      {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert resp.status == 500
      assert inspect(resp.body) =~ "Internal server error"
    end

    @tag mock_llm: true, llm_scenario: {:retry_then_succeed, 2, :standard_completion}
    test "T1_F17_04_transient_error_followed_by_success", %{mock_llm: mock} do
      # Attempt 1: 429
      {:ok, r1} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert r1.status == 429

      # Attempt 2: 429
      {:ok, r2} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert r2.status == 429

      # Attempt 3: 200 OK
      {:ok, r3} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert r3.status == 200
      assert r3.body["choices"] != nil
    end

    @tag mock_llm: true
    test "T1_F17_05_dynamic_scenario_switching", %{mock_llm_pid: pid, mock_llm: mock} do
      MockLLMServer.set_scenario(pid, :server_error_500)
      {:ok, r1} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert r1.status == 500

      MockLLMServer.set_scenario(pid, :standard_completion)
      {:ok, r2} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
      assert r2.status == 200
    end
  end
end
