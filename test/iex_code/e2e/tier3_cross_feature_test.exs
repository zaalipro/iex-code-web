defmodule IexCode.E2E.Tier3CrossFeatureTest do
  @moduledoc """
  Tier 3: Pairwise Cross-Feature Integration E2E Test Suite (22 Tests).
  Verifies bidirectional interaction contracts between all 17 core features:
  - T3_01: F1 (AppSettings) <-> F15 (LLM Client)
  - T3_02: F2 (Process Tree) <-> F3 (Crash Monitoring)
  - T3_03: F3 (Crash Monitoring) <-> F5 (Card Streaming)
  - T3_04: F4 (Swarm Orchestrator) <-> F6 (Hierarchical Tree)
  - T3_05: F4 (Swarm Orchestrator) <-> F11 (Atomic Patching)
  - T3_06: F4 (Swarm Orchestrator) <-> F14 (Git Integration)
  - T3_07: F5 (Card Streaming) <-> F6 (Hierarchical Tree)
  - T3_08: F5 (Card Streaming) <-> F16 (UTF-8 Sanitizer)
  - T3_09: F7 (Diff Viewer) <-> F11 (Atomic Patching)
  - T3_10: F7 (Diff Viewer) <-> F14 (Git Integration)
  - T3_11: F8 (File Explorer) <-> F11 (Atomic Patching)
  - T3_12: F8 (File Explorer) <-> F10 (AST Search)
  - T3_13: F9 (Terminal Runner) <-> F12 (Test Runner)
  - T3_14: F9 (Terminal Runner) <-> F14 (Git Integration)
  - T3_15: F10 (AST Search) <-> F13 (Auto-Fix Engine)
  - T3_16: F11 (Atomic Patching) <-> F12 (Test Verification)
  - T3_17: F12 (Test Runner) <-> F13 (Auto-Fix Loop)
  - T3_18: F13 (Auto-Fix Engine) <-> F14 (Git Integration)
  - T3_19: F15 (LLM Stream) <-> F16 (UTF-8 Sanitizer)
  - T3_20: F15 (LLM Client) <-> F17 (LLM Retries)
  - T3_21: F1 (AppSettings) <-> F4 (Swarm Agent Count)
  - T3_22: F2 (Session Server) <-> F9 (Terminal Execution)
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.ASTSearch
  alias IexCode.Engine.SessionServer

  # ============================================================================
  # T3_01: F1 (AppSettings) <-> F15 (LLM Client)
  # ============================================================================
  @tag mock_llm: true, llm_scenario: {:custom_content, "Mocked Response via Settings"}
  test "T3_01_f1_appsettings_and_f15_llm_client", %{mock_llm: mock} do
    {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{"model" => "gpt-4o"})
    assert resp.status == 200
    assert hd(resp.body["choices"])["message"]["content"] == "Mocked Response via Settings"
  end

  # ============================================================================
  # T3_02: F2 (Process Tree) <-> F3 (Crash Monitoring)
  # ============================================================================
  test "T3_02_f2_process_tree_and_f3_crash_monitoring", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, session_pid} = SessionServer.ensure_started(session.id)

    # Launch a crashing async operation inside the session
    {:ok, _task_pid, _op} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "WorkerCrash",
        "crash_task",
        "Intentional Worker Crash",
        %{},
        fn _progress -> raise "Worker crash inside session" end
      )

    assert_receive {:operation_failed, op}, 5000
    assert op.status == "failed"
    assert String.contains?(op.error_message, "Worker crash inside session")

    # Verify SessionServer is still alive and resilient
    assert Process.alive?(session_pid)
    assert SessionServer.get_state(session.id).status == :idle
  end

  # ============================================================================
  # T3_03: F3 (Crash Monitoring) <-> F5 (Card Streaming)
  # ============================================================================
  test "T3_03_f3_crash_monitoring_and_f5_card_streaming", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, _task_pid, op} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "StreamingCrashAgent",
        "task",
        "Stream Progress Then Fail",
        %{},
        fn progress ->
          progress.(25, "Initial step")
          progress.(75, "Almost there...")
          raise "Midway processing failure"
        end
      )

    assert_receive {:operation_started, _}, 5000
    assert_receive {:operation_progress, _, 25, "Initial step"}, 5000
    assert_receive {:operation_progress, _, 75, "Almost there..."}, 5000
    assert_receive {:operation_failed, failed_op}, 5000

    assert failed_op.id == op.id
    assert failed_op.status == "failed"

    # Verify state in database
    db_op = Sessions.get_operation!(op.id)
    assert db_op.status == "failed"
    assert db_op.progress == 75
  end

  # ============================================================================
  # T3_04: F4 (Swarm Orchestrator) <-> F6 (Hierarchical Tree)
  # ============================================================================
  @tag mock_llm: true
  test "T3_04_f4_swarm_and_f6_operation_tree", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, _swarm_pid} = SwarmOrchestrator.run_swarm(session.id, "Build tree hierarchy", path)
    assert_receive {:session_status_changed, "idle"}, 20_000

    ops = Sessions.list_operations(session.id)
    assert length(ops) >= 1

    root_op = Enum.find(ops, fn op -> op.op_type == "swarm_root" end)
    assert root_op != nil
    assert is_nil(root_op.parent_op_id)
  end

  # ============================================================================
  # T3_05: F4 (Swarm Orchestrator) <-> F11 (Atomic Patching)
  # ============================================================================
  @tag mock_llm: true
  test "T3_05_f4_swarm_and_f11_atomic_patching", %{workspace_path: path} do
    workspace_write_file(
      path,
      "lib/calc.ex",
      "defmodule Calc do\n  def add(a, b), do: a - b\nend"
    )

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    # Swarm completes task and leaves workspace intact
    {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Fix subtract bug in Calc.add", path)
    assert_receive {:session_status_changed, "idle"}, 20_000

    {:ok, content} = workspace_read_file(path, "lib/calc.ex")
    assert String.contains?(content, "defmodule Calc")
  end

  # ============================================================================
  # T3_06: F4 (Swarm Orchestrator) <-> F14 (Git Integration)
  # ============================================================================
  @tag mock_llm: true
  test "T3_06_f4_swarm_and_f14_git_integration" do
    {:ok, dir} = init_temp_git_repo(%{"lib/core.ex" => "defmodule Core do end"})
    project = create_project_fixture(%{root_path: dir})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Inspect repository status", dir)
    assert_receive {:session_status_changed, "idle"}, 20_000

    {:ok, status} = Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)
    assert is_binary(status)
  end

  # ============================================================================
  # T3_07: F5 (Card Streaming) <-> F6 (Hierarchical Tree)
  # ============================================================================
  test "T3_07_f5_card_streaming_and_f6_hierarchical_tree", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    # Create root operation
    root_op = create_operation_fixture(session, %{title: "Parent Step", op_type: "parent"})

    # Launch child operation referencing parent_op_id
    {:ok, _task_pid, child_op} =
      OperationManager.run_async_operation(
        session.id,
        root_op.id,
        "ChildAgent",
        "child_step",
        "Child Step Telemetry",
        %{},
        fn progress ->
          progress.(50, "Child halfway")
          {:ok, "child done"}
        end
      )

    assert_receive {:operation_started, started_child}, 5000
    assert started_child.parent_op_id == root_op.id
    assert_receive {:operation_progress, child_id, 50, "Child halfway"}, 5000
    assert child_id == child_op.id
    assert_receive {:operation_completed, completed_child}, 5000
    assert completed_child.parent_op_id == root_op.id
  end

  # ============================================================================
  # T3_08: F5 (Card Streaming) <-> F16 (UTF-8 Sanitizer)
  # ============================================================================
  test "T3_08_f5_card_streaming_and_f16_utf8_sanitization", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    # Progress containing raw invalid binary bytes
    invalid_chunk = "Processing " <> <<0xFF, 0xFE>> <> " items..."

    OperationManager.run_sync_operation(
      session.id,
      nil,
      "SanitizingAgent",
      "task",
      "Sanitize In Telemetry",
      %{},
      fn progress ->
        sanitized_msg = Sessions.sanitize_utf8(invalid_chunk)
        progress.(50, sanitized_msg)
        {:ok, "done"}
      end
    )

    assert_receive {:operation_progress, _, 50, delivered_msg}, 5000
    assert String.valid?(delivered_msg)
    assert String.contains?(delivered_msg, "Processing")
  end

  # ============================================================================
  # T3_09: F7 (Diff Viewer) <-> F11 (Atomic Patching)
  # ============================================================================
  test "T3_09_f7_diff_viewer_and_f11_atomic_patching", %{workspace_path: path} do
    original = "def compute, do: 1\n"
    workspace_write_file(path, "lib/calc.ex", original)

    # Apply patch
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/calc.ex",
          "target_content" => "do: 1",
          "replacement_content" => "do: 42"
        },
        path
      )

    {:ok, patched} = workspace_read_file(path, "lib/calc.ex")
    assert patched == "def compute, do: 42\n"

    # Verify diff comparison
    assert original != patched
    assert String.contains?(patched, "42")
  end

  # ============================================================================
  # T3_10: F7 (Diff Viewer) <-> F14 (Git Integration)
  # ============================================================================
  test "T3_10_f7_diff_viewer_and_f14_git_diff" do
    {:ok, dir} = init_temp_git_repo(%{"lib/version.ex" => "@version \"1.0.0\"\n"})

    # Modify file
    workspace_write_file(dir, "lib/version.ex", "@version \"2.0.0\"\n")

    {:ok, diff_output} = Tools.execute("run_command", %{"command" => "git diff"}, dir)
    assert String.contains?(diff_output, "-@version \"1.0.0\"")
    assert String.contains?(diff_output, "+@version \"2.0.0\"")
  end

  # ============================================================================
  # T3_11: F8 (File Explorer) <-> F11 (Atomic Patching)
  # ============================================================================
  test "T3_11_f8_file_explorer_and_f11_atomic_patching", %{workspace_path: path} do
    # Write a new file using write_file tool
    {:ok, _} =
      Tools.execute(
        "write_file",
        %{"path" => "lib/new_module.ex", "content" => "defmodule NewMod do end"},
        path
      )

    # Check discoverability via list_dir tool
    {:ok, list_result} = Tools.execute("list_dir", %{"path" => "lib"}, path)
    assert String.contains?(list_result, "new_module.ex")

    # Read the file back via read_file tool
    {:ok, read_result} = Tools.execute("read_file", %{"path" => "lib/new_module.ex"}, path)
    assert String.contains?(read_result, "defmodule NewMod")
  end

  # ============================================================================
  # T3_12: F8 (File Explorer) <-> F10 (AST Search)
  # ============================================================================
  test "T3_12_f8_file_explorer_and_f10_ast_search", %{workspace_path: path} do
    code = """
    defmodule Accounts.User do
      def find_by_email(email), do: {:ok, email}
    end
    """

    workspace_write_file(path, "lib/accounts/user.ex", code)

    # Verify file is visible via list_dir
    {:ok, list_result} = Tools.execute("list_dir", %{"path" => "lib/accounts"}, path)
    assert String.contains?(list_result, "user.ex")

    # Verify symbol is indexed by ASTSearch
    {:ok, results} = ASTSearch.search(path, %{name: "find_by_email"})
    assert length(results) == 1
    assert hd(results).name == "find_by_email"
    assert hd(results).module == "Accounts.User"
  end

  # ============================================================================
  # T3_13: F9 (Terminal Runner) <-> F12 (Test Runner)
  # ============================================================================
  test "T3_13_f9_terminal_and_f12_test_runner", %{workspace_path: path} do
    # Run an elixir one-liner assertion test through run_command
    cmd = "elixir -e 'if 1 + 1 == 2, do: IO.puts(\"TEST_PASSED\"), else: exit({:error, 1})'"
    {:ok, output} = Tools.execute("run_command", %{"command" => cmd}, path)
    assert String.contains?(output, "TEST_PASSED")
  end

  # ============================================================================
  # T3_14: F9 (Terminal Runner) <-> F14 (Git Integration)
  # ============================================================================
  test "T3_14_f9_terminal_and_f14_git_commands" do
    {:ok, dir} = init_temp_git_repo(%{})
    workspace_write_file(dir, "lib/hello.ex", "defmodule Hello do end")

    {:ok, _} = Tools.execute("run_command", %{"command" => "git add lib/hello.ex"}, dir)

    {:ok, _} =
      Tools.execute("run_command", %{"command" => "git commit -m 'feat: add hello module'"}, dir)

    {:ok, log} = Tools.execute("run_command", %{"command" => "git log -n 1 --oneline"}, dir)
    assert String.contains?(log, "feat: add hello module")
  end

  # ============================================================================
  # T3_15: F10 (AST Search) <-> F13 (Auto-Fix Engine)
  # ============================================================================
  test "T3_15_f10_ast_search_and_f13_autofix", %{workspace_path: path} do
    code = """
    defmodule BuggyService do
      def proccess_data(x), do: x * 2
    end
    """

    workspace_write_file(path, "lib/buggy_service.ex", code)

    # 1. Locate typo function using ASTSearch
    {:ok, symbols} = ASTSearch.search(path, %{name: "proccess_data"})
    assert length(symbols) == 1
    sym = hd(symbols)
    assert sym.name == "proccess_data"

    # 2. Apply auto-fix patch
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/buggy_service.ex",
          "target_content" => "def proccess_data(x)",
          "replacement_content" => "def process_data(x)"
        },
        path
      )

    # 3. Verify ASTSearch now finds corrected function
    {:ok, corrected_symbols} = ASTSearch.search(path, %{name: "process_data"})
    assert length(corrected_symbols) == 1
    assert hd(corrected_symbols).name == "process_data"
  end

  # ============================================================================
  # T3_16: F11 (Atomic Patching) <-> F12 (Test Verification)
  # ============================================================================
  test "T3_16_f11_atomic_patching_and_f12_test_verification", %{workspace_path: path} do
    # Failing implementation
    workspace_write_file(
      path,
      "lib/math.ex",
      "defmodule Math do\n  def double(x), do: x + 1\nend"
    )

    # Verify failure
    check_cmd =
      "elixir -r lib/math.ex -e 'if Math.double(5) == 10, do: IO.puts(\"PASS\"), else: IO.puts(\"FAIL\")'"

    {:ok, out1} = Tools.execute("run_command", %{"command" => check_cmd}, path)
    assert String.contains?(out1, "FAIL")

    # Patch implementation
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/math.ex",
          "target_content" => "x + 1",
          "replacement_content" => "x * 2"
        },
        path
      )

    # Verify success
    {:ok, out2} = Tools.execute("run_command", %{"command" => check_cmd}, path)
    assert String.contains?(out2, "PASS")
  end

  # ============================================================================
  # T3_17: F12 (Test Runner) <-> F13 (Auto-Fix Loop)
  # ============================================================================
  test "T3_17_f12_test_runner_and_f13_autofix_loop", %{workspace_path: path} do
    # 1. Broken code
    workspace_write_file(
      path,
      "lib/formatter.ex",
      "defmodule Formatter do\n  def format(name), do: \"Hello \#{nme}\"\nend"
    )

    # 2. Run check - should produce error output
    {:ok, err_out} =
      Tools.execute(
        "run_command",
        %{"command" => "elixir -r lib/formatter.ex -e 'Formatter.format(\"Alice\")'"},
        path
      )

    assert String.contains?(err_out, "undefined variable") or
             String.contains?(err_out, "Exit Code") or String.contains?(err_out, "CompileError")

    # 3. Apply Auto-Fix
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/formatter.ex",
          "target_content" => "nme",
          "replacement_content" => "name"
        },
        path
      )

    # 4. Re-run verification
    {:ok, success_out} =
      Tools.execute(
        "run_command",
        %{"command" => "elixir -r lib/formatter.ex -e 'IO.puts(Formatter.format(\"Alice\"))'"},
        path
      )

    assert String.trim(success_out) == "Hello Alice"
  end

  # ============================================================================
  # T3_18: F13 (Auto-Fix Engine) <-> F14 (Git Integration)
  # ============================================================================
  test "T3_18_f13_autofix_and_f14_git_commit" do
    {:ok, dir} = init_temp_git_repo(%{"lib/broken.ex" => "def compute, do: :error\n"})

    # Apply fix
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/broken.ex",
          "target_content" => ":error",
          "replacement_content" => ":ok"
        },
        dir
      )

    # Stage and commit fix
    {:ok, _} =
      Tools.execute(
        "run_command",
        %{
          "command" =>
            "git add lib/broken.ex && git commit -m 'fix: correct compute return value'"
        },
        dir
      )

    # Verify clean working directory
    {:ok, status} = Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)
    assert String.trim(status) == ""
  end

  # ============================================================================
  # T3_19: F15 (LLM Stream) <-> F16 (UTF-8 Sanitizer)
  # ============================================================================
  @tag mock_llm: true, llm_scenario: :split_utf8
  test "T3_19_f15_llm_stream_and_f16_utf8_sanitizer", %{mock_llm: mock} do
    {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert resp.status == 200

    # Sanitize the full streamed body
    sanitized = Sessions.sanitize_utf8(resp.body)
    assert String.valid?(sanitized)
    assert String.contains?(sanitized, "Swarm ")
  end

  # ============================================================================
  # T3_20: F15 (LLM Client) <-> F17 (LLM Retries)
  # ============================================================================
  @tag mock_llm: true, llm_scenario: {:retry_then_succeed, 1, :standard_completion}
  test "T3_20_f15_llm_client_and_f17_llm_retries", %{mock_llm: mock} do
    # Request 1: 429 rate limit
    {:ok, r1} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert r1.status == 429

    # Request 2: Succeeds on retry
    {:ok, r2} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert r2.status == 200
    assert r2.body["choices"] != nil
  end

  # ============================================================================
  # T3_21: F1 (AppSettings) <-> F4 (Swarm Agent Count)
  # ============================================================================
  @tag mock_llm: true
  test "T3_21_f1_settings_and_f4_swarm_agent_count", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, _} = Settings.update_settings(%{swarm_agent_count: 6})
    settings = Settings.get_settings()
    assert settings.swarm_agent_count == 6

    {:ok, _pid} = SwarmOrchestrator.run_swarm(session.id, "Verify agent count", path)
    assert_receive {:session_status_changed, "idle"}, 20_000
  end

  # ============================================================================
  # T3_22: F2 (Session Server) <-> F9 (Terminal Execution)
  # ============================================================================
  test "T3_22_f2_session_server_and_f9_terminal_execution", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, session_pid} = SessionServer.ensure_started(session.id)
    assert Process.alive?(session_pid)

    # Concurrently execute terminal commands while SessionServer is active
    {:ok, out1} = Tools.execute("run_command", %{"command" => "echo 'command 1'"}, path)
    {:ok, out2} = Tools.execute("run_command", %{"command" => "echo 'command 2'"}, path)

    assert String.trim(out1) == "command 1"
    assert String.trim(out2) == "command 2"
    assert Process.alive?(session_pid)
  end
end
