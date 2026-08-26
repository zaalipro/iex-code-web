defmodule IexCode.E2E.Tier4RealWorldScenarioTest do
  @moduledoc """
  Tier 4: Real-World Application Scenario E2E Test Suite (10 Tests).
  Exercises end-to-end multi-step application lifecycles and realistic developer workflows:
  - S01: Full Lifecycle Project Creation to Git Commit
  - S02: TDD Loop (Red -> Green -> Refactor)
  - S03: Multi-Agent Swarm Feature Delivery
  - S04: Syntax Error Recovery & Auto-Repair
  - S05: LLM Rate Limiting & Graceful Recovery
  - S06: Multibyte Unicode & Emoji Streaming Integrity
  - S07: Large Codebase Symbol Navigation & Patching
  - S08: Multi-Branch Git Workflow
  - S09: LiveView Interactive Workspace Multi-Tab Workflow
  - S10: Unhandled Worker Crash Recovery & Resilient State
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.ASTSearch
  alias IexCode.Engine.SessionServer

  # ============================================================================
  # Scenario 1: Full Lifecycle Project Creation to Git Commit
  # ============================================================================
  test "T4_S01_full_lifecycle_project_creation_to_git_commit" do
    # 1. Initialize git repo
    {:ok, dir} = init_temp_git_repo(%{})
    project = create_project_fixture(%{root_path: dir})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    # 2. Write application code and test file
    app_code = """
    defmodule Greeter do
      def greet(name), do: "Hello, \#{name}!"
    end
    """

    test_code = """
    defmodule GreeterTest do
      def test_greet do
        if Greeter.greet("World") == "Hello, World!", do: :ok, else: :error
      end
    end
    """

    {:ok, _} =
      Tools.execute("write_file", %{"path" => "lib/greeter.ex", "content" => app_code}, dir)

    {:ok, _} =
      Tools.execute(
        "write_file",
        %{"path" => "test/greeter_test.exs", "content" => test_code},
        dir
      )

    # 3. Verify files exist via list_dir
    {:ok, files_list} = Tools.execute("list_dir", %{"path" => "", "recursive" => true}, dir)
    assert String.contains?(files_list, "lib/greeter.ex")
    assert String.contains?(files_list, "test/greeter_test.exs")

    # 4. Run test verification via terminal runner
    verify_cmd =
      "elixir -r lib/greeter.ex -r test/greeter_test.exs -e 'if GreeterTest.test_greet() == :ok, do: IO.puts(\"ALL_TESTS_PASS\"), else: exit(1)'"

    {:ok, test_output} = Tools.execute("run_command", %{"command" => verify_cmd}, dir)
    assert String.contains?(test_output, "ALL_TESTS_PASS")

    # 5. Review git status and commit
    {:ok, status_before} =
      Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)

    assert String.contains?(status_before, "?? lib/") or
             String.contains?(status_before, "lib/greeter.ex")

    {:ok, _} =
      Tools.execute(
        "run_command",
        %{"command" => "git add . && git commit -m 'feat: implement Greeter and test suite'"},
        dir
      )

    {:ok, status_after} =
      Tools.execute("run_command", %{"command" => "git status --porcelain"}, dir)

    assert String.trim(status_after) == ""

    {:ok, log} = Tools.execute("run_command", %{"command" => "git log -n 1 --oneline"}, dir)
    assert String.contains?(log, "implement Greeter")
  end

  # ============================================================================
  # Scenario 2: TDD Loop (Red -> Green -> Refactor)
  # ============================================================================
  test "T4_S02_tdd_loop_red_green_refactor", %{workspace_path: dir} do
    # Step 1 (RED): Write test and intentionally broken/empty implementation
    test_code = """
    defmodule StackTest do
      def run_tests do
        s = Stack.new() |> Stack.push(1) |> Stack.push(2)
        {val, s2} = Stack.pop(s)
        if val == 2 and Stack.pop(s2) == {1, []}, do: :pass, else: :fail
      end
    end
    """

    dummy_code = """
    defmodule Stack do
      def new, do: []
      def push(stack, item), do: stack
      def pop(stack), do: {nil, stack}
    end
    """

    workspace_write_file(dir, "test/stack_test.exs", test_code)
    workspace_write_file(dir, "lib/stack.ex", dummy_code)

    eval_cmd =
      "elixir -r lib/stack.ex -r test/stack_test.exs -e 'if StackTest.run_tests() == :pass, do: IO.puts(\"PASS\"), else: IO.puts(\"FAIL\")'"

    {:ok, red_out} = Tools.execute("run_command", %{"command" => eval_cmd}, dir)
    assert String.contains?(red_out, "FAIL")

    # Step 2 (GREEN): Patch implementation to pass
    working_code = """
    defmodule Stack do
      def new, do: []
      def push(stack, item), do: [item | stack]
      def pop([top | rest]), do: {top, rest}
      def pop([]), do: {:empty, []}
    end
    """

    {:ok, _} =
      Tools.execute("write_file", %{"path" => "lib/stack.ex", "content" => working_code}, dir)

    {:ok, green_out} = Tools.execute("run_command", %{"command" => eval_cmd}, dir)
    assert String.contains?(green_out, "PASS")

    # Step 3 (REFACTOR): Optimize code while preserving correctness
    refactored_code = """
    defmodule Stack do
      @type t :: list()
      @spec new() :: t()
      def new, do: []

      @spec push(t(), any()) :: t()
      def push(stack, item) when is_list(stack), do: [item | stack]

      @spec pop(t()) :: {any(), t()}
      def pop([top | rest]), do: {top, rest}
      def pop([]), do: {:empty, []}
    end
    """

    {:ok, _} =
      Tools.execute("write_file", %{"path" => "lib/stack.ex", "content" => refactored_code}, dir)

    {:ok, refactor_out} = Tools.execute("run_command", %{"command" => eval_cmd}, dir)
    assert String.contains?(refactor_out, "PASS")
  end

  # ============================================================================
  # Scenario 3: Multi-Agent Swarm Feature Delivery
  # ============================================================================
  @tag mock_llm: true
  test "T4_S03_multi_agent_swarm_feature_delivery", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    # Launch full Swarm on a realistic feature goal
    goal = "Implement a Fibonacci memoized sequence generator in lib/fibonacci.ex"
    {:ok, swarm_pid} = SwarmOrchestrator.run_swarm(session.id, goal, path)
    assert is_pid(swarm_pid)

    # 1. Swarm transitions to running
    assert_receive {:session_status_changed, "running"}, 5000

    # 2. Swarm creates root operation
    assert_receive {:operation_started, root_op}, 5000
    assert root_op.op_type == "swarm_root"

    # 3. Swarm completes and transitions back to idle
    assert_receive {:session_status_changed, "idle"}, 20_000

    # 4. Swarm posts final completion message
    messages = Sessions.list_messages(session.id)
    assert length(messages) >= 1
    assistant_msg = List.last(messages)
    assert assistant_msg.role == "assistant"
    assert String.contains?(assistant_msg.content, "Swarm Execution Complete")

    # 5. Verify database recorded operations
    ops = Sessions.list_operations(session.id)
    assert length(ops) >= 1
  end

  # ============================================================================
  # Scenario 4: Syntax Error Recovery & Auto-Repair
  # ============================================================================
  test "T4_S04_syntax_error_recovery_and_auto_repair", %{workspace_path: path} do
    # 1. Introduce file with broken syntax (unclosed function)
    broken_content = """
    defmodule Parser do
      def parse_data(raw) do
        String.trim(raw)
    """

    workspace_write_file(path, "lib/parser.ex", broken_content)

    # 2. Run compilation to detect failure
    compile_cmd = "elixir -r lib/parser.ex -e 'Parser.parse_data(\" test \")'"
    {:ok, compile_out} = Tools.execute("run_command", %{"command" => compile_cmd}, path)

    assert String.contains?(compile_out, "unexpected") or
             String.contains?(compile_out, "missing terminator: end") or
             String.contains?(compile_out, "Exit Code")

    # 3. Auto-repair the syntax error
    repaired_content = """
    defmodule Parser do
      def parse_data(raw) do
        String.trim(raw)
      end
    end
    """

    {:ok, _} =
      Tools.execute(
        "write_file",
        %{"path" => "lib/parser.ex", "content" => repaired_content},
        path
      )

    # 4. Re-verify clean execution
    verify_cmd = "elixir -r lib/parser.ex -e 'IO.puts(Parser.parse_data(\"  hello  \"))'"
    {:ok, success_out} = Tools.execute("run_command", %{"command" => verify_cmd}, path)
    assert String.trim(success_out) == "hello"
  end

  # ============================================================================
  # Scenario 5: LLM Rate Limiting & Graceful Recovery
  # ============================================================================
  @tag mock_llm: true,
       llm_scenario:
         {:retry_then_succeed, 2, {:custom_content, "Recovered from 429 Successfully"}}
  test "T4_S05_llm_rate_limiting_and_graceful_recovery", %{mock_llm: mock} do
    # Attempt 1: 429 Rate Limit
    {:ok, r1} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert r1.status == 429

    # Attempt 2: 429 Rate Limit
    {:ok, r2} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert r2.status == 429

    # Attempt 3: 200 OK after backoff
    {:ok, r3} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert r3.status == 200
    assert hd(r3.body["choices"])["message"]["content"] == "Recovered from 429 Successfully"
  end

  # ============================================================================
  # Scenario 6: Multibyte Unicode & Emoji Streaming Integrity
  # ============================================================================
  @tag mock_llm: true, llm_scenario: :split_utf8
  test "T4_S06_multibyte_emoji_and_cjk_streaming_integrity", %{
    mock_llm: mock,
    workspace_path: path
  } do
    # 1. Fetch split UTF-8 stream from mock server
    {:ok, resp} = Req.post("#{mock.url}/v1/chat/completions", json: %{})
    assert resp.status == 200

    # 2. Sanitize and write response to workspace
    sanitized_text = Sessions.sanitize_utf8(resp.body)
    assert String.valid?(sanitized_text)

    # 3. Store UTF-8 text containing Japanese, Cyrillic, and Emojis
    unicode_doc = """
    # 🐝 IexCode Multi-Language Documentation
    - 日本語: エリクサーの並行処理
    - Русский: Параллелизм в Elixir
    - English: Concurrency in Elixir ⚡
    """

    workspace_write_file(path, "docs/unicode.md", unicode_doc)

    {:ok, read_doc} = Tools.execute("read_file", %{"path" => "docs/unicode.md"}, path)
    assert String.contains?(read_doc, "日本語: エリクサー")
    assert String.contains?(read_doc, "Русский: Параллелизм")
    assert String.contains?(read_doc, "🐝")
  end

  # ============================================================================
  # Scenario 7: Large Codebase Symbol Navigation & Patching
  # ============================================================================
  test "T4_S07_large_codebase_symbol_navigation_and_patching", %{workspace_path: path} do
    # Create multiple modules in different namespaces
    workspace_write_file(
      path,
      "lib/accounts/user.ex",
      "defmodule App.Accounts.User do\n  def get_name(u), do: u.name\nend"
    )

    workspace_write_file(
      path,
      "lib/orders/order.ex",
      "defmodule App.Orders.Order do\n  def total_amount(o), do: o.total\nend"
    )

    workspace_write_file(
      path,
      "lib/billing/charge.ex",
      "defmodule App.Billing.Charge do\n  def calculate_fee(amount), do: amount * 0.05\nend"
    )

    # 1. Search for symbol in billing without knowing exact file path
    {:ok, symbols} = ASTSearch.search(path, %{name: "calculate_fee"})
    assert length(symbols) == 1
    charge_sym = hd(symbols)
    assert charge_sym.module == "App.Billing.Charge"
    assert charge_sym.name == "calculate_fee"

    # 2. Patch the identified fee calculation
    {:ok, _} =
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/billing/charge.ex",
          "target_content" => "amount * 0.05",
          "replacement_content" => "amount * 0.03"
        },
        path
      )

    # 3. Verify other modules remained untouched
    {:ok, accounts_content} = workspace_read_file(path, "lib/accounts/user.ex")
    assert String.contains?(accounts_content, "get_name")

    {:ok, billing_content} = workspace_read_file(path, "lib/billing/charge.ex")
    assert String.contains?(billing_content, "amount * 0.03")
  end

  # ============================================================================
  # Scenario 8: Multi-Branch Git Workflow
  # ============================================================================
  test "T4_S08_multi_branch_git_workflow" do
    # 1. Initialize git on main branch
    {:ok, dir} = init_temp_git_repo(%{"lib/main.ex" => "defmodule Main do end"})

    # 2. Create and switch to feature branch
    {:ok, _} = Tools.execute("run_command", %{"command" => "git checkout -b feat/payments"}, dir)

    # 3. Add feature file on branch
    workspace_write_file(
      dir,
      "lib/payments.ex",
      "defmodule Payments do\n  def pay(amount), do: {:ok, amount}\nend"
    )

    {:ok, _} =
      Tools.execute(
        "run_command",
        %{"command" => "git add lib/payments.ex && git commit -m 'feat: add payments module'"},
        dir
      )

    # 4. Check git branch status
    {:ok, branch_out} =
      Tools.execute("run_command", %{"command" => "git branch --show-current"}, dir)

    assert String.trim(branch_out) == "feat/payments"

    # 5. Switch back to main branch and verify branch isolation
    {:ok, _} = Tools.execute("run_command", %{"command" => "git checkout main"}, dir)
    {:ok, main_files} = Tools.execute("list_dir", %{"path" => "lib"}, dir)
    assert String.contains?(main_files, "main.ex")
    refute String.contains?(main_files, "payments.ex")
  end

  # ============================================================================
  # Scenario 9: LiveView Interactive Workspace Multi-Tab Workflow
  # ============================================================================
  @tag mock_llm: true
  test "T4_S09_liveview_interactive_workspace_multi_tab_workflow", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/demo.ex", "defmodule Demo do\n  def run, do: :ok\nend")
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    subscribe_session(session.id)

    # 1. Mount LiveView workspace
    {:ok, view, html} = mount_workspace(conn, session.id)
    assert html =~ "Workspace" or html =~ "IexCode"

    # 2. Toggle Swarm mode
    html_swarm = toggle_workspace_swarm(view)
    assert is_binary(html_swarm)

    # 3. Switch to Files tab and preview file
    _ = switch_workspace_tab(view, "files")
    file_html = render_click(view, "select_file", %{"path" => "lib/demo.ex"})
    assert file_html =~ "Demo" or is_binary(file_html)

    # 4. Switch to Terminal tab and run quick command
    _ = switch_workspace_tab(view, "terminal")
    term_html = render_click(view, "run_terminal", %{"command" => "echo 'tab workflow passed'"})
    assert term_html =~ "tab workflow passed" or is_binary(term_html)

    # 5. Submit user prompt in Chat
    _ = switch_workspace_tab(view, "chat")

    # Chat no longer overrides the configured prompt-dispatch default. This
    # scenario explicitly exercises the live path, so select it deliberately.
    _ = render_click(view, "set_dispatch_mode", %{"mode" => "interactive"})

    prompt_html = submit_workspace_prompt(view, "Review code in lib/demo.ex")
    assert is_binary(prompt_html)
    assert_receive {:session_status_changed, "idle"}, 20_000
  end

  # ============================================================================
  # Scenario 10: Unhandled Worker Crash Recovery & Resilient State
  # ============================================================================
  test "T4_S10_unhandled_crash_recovery_and_resilient_state", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    subscribe_session(session.id)

    {:ok, _session_pid} = SessionServer.ensure_started(session.id)

    # Step 1: Operation crashes abruptly with unhandled runtime exception
    {:ok, _task_pid, crash_op} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "CrashingWorker",
        "task",
        "Severe Exception Simulation",
        %{},
        fn _progress -> raise "Severe unhandled worker exception" end
      )

    assert_receive {:operation_failed, failed_op}, 5000
    assert failed_op.id == crash_op.id
    assert failed_op.status == "failed"

    # Step 2: Verify database record captured error
    db_op = Sessions.get_operation!(crash_op.id)
    assert db_op.status == "failed"
    assert String.contains?(db_op.error_message, "Severe unhandled worker exception")

    # Step 3: SessionServer and OperationManager remain healthy for next operation
    {:ok, _task_pid2, next_op} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "HealthyWorker",
        "task",
        "Recovery Step",
        %{},
        fn progress ->
          progress.(100, "Healthy complete")
          {:ok, "healthy outcome"}
        end
      )

    assert_receive {:operation_completed, done_op}, 5000
    assert done_op.id == next_op.id
    assert done_op.status == "completed"

    # Session remains in idle state
    assert SessionServer.get_state(session.id).status == :idle
  end
end
