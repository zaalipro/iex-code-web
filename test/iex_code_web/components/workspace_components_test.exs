defmodule IexCodeWeb.WorkspaceComponentsTest do
  use IexCode.E2E.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents
  alias IexCode.Sessions.Operation

  # ============================================================================
  # F5: Subagent Cards Tests
  # ============================================================================

  describe "<.subagent_cards />" do
    test "renders all 4 subagent personas with default idle states" do
      assigns = %{operations: [], active_agent: nil, active_stage: :init, swarm_mode: true}

      html =
        rendered_to_string(~H"""
        <.subagent_cards operations={@operations} active_agent={@active_agent} />
        """)

      assert html =~ "PlannerAgent"
      assert html =~ "ExplorerAgent"
      assert html =~ "CoderAgent"
      assert html =~ "VerifierAgent"
      assert html =~ "OTP Supervised"
      assert html =~ "IDLE"
      assert html =~ "Latency:"
    end

    test "renders running subagent with active neon glow, PID, duration, and progress bar" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      running_op = %Operation{
        id: "op-coder-1",
        session_id: "sess-1",
        agent_name: "CoderAgent",
        op_type: "patch_file",
        title: "Applying 3 atomic patches",
        status: "running",
        progress: 65,
        pid_str: "#PID<0.452.0>",
        duration_ms: 125,
        started_at: now
      }

      assigns = %{operations: [running_op]}

      html =
        rendered_to_string(~H"""
        <.subagent_cards operations={@operations} />
        """)

      assert html =~ "CoderAgent"
      assert html =~ "RUNNING"
      assert html =~ "#PID&lt;0.452.0&gt;" or html =~ "#PID<0.452.0>"
      assert html =~ "125ms"
      assert html =~ "65%"
      assert html =~ "Applying 3 atomic patches"
      assert html =~ "width: 65%"
    end

    test "renders completed and failed subagent badges properly" do
      completed_op = %Operation{
        id: "op-planner-1",
        session_id: "sess-1",
        agent_name: "PlannerAgent",
        op_type: "plan",
        title: "Decomposition complete",
        status: "completed",
        progress: 100,
        pid_str: "pid 90123",
        duration_ms: 45
      }

      failed_op = %Operation{
        id: "op-verifier-1",
        session_id: "sess-1",
        agent_name: "VerifierAgent",
        op_type: "run_tests",
        title: "Assertion failed",
        status: "failed",
        progress: 50,
        pid_str: "pid 90124",
        duration_ms: 220
      }

      assigns = %{operations: [completed_op, failed_op]}

      html =
        rendered_to_string(~H"""
        <.subagent_cards operations={@operations} />
        """)

      assert html =~ "COMPLETED"
      assert html =~ "FAILED"
      assert html =~ "45ms"
      assert html =~ "220ms"
      assert html =~ "pid 90123"
      assert html =~ "pid 90124"
    end
  end

  # ============================================================================
  # F6: Operation Tree Tests
  # ============================================================================

  describe "<.operation_tree />" do
    test "renders empty state when operations list is empty" do
      assigns = %{operations: [], expanded_ops: MapSet.new()}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "Execution Hierarchy"
      assert html =~ "0 ops"
      assert html =~ "No operations recorded in this session"
      assert html =~ "Clear Operations"
    end

    test "renders hierarchical parent-child operation tree with status and metrics" do
      root_op = %Operation{
        id: "root-1",
        parent_op_id: nil,
        agent_name: "SwarmCoordinator",
        op_type: "swarm_root",
        title: "Swarm Goal: Payment webhook",
        status: "completed",
        progress: 100,
        duration_ms: 350,
        pid_str: "pid 1001"
      }

      child_op = %Operation{
        id: "child-1",
        parent_op_id: "root-1",
        agent_name: "PlannerAgent",
        op_type: "plan",
        title: "Decomposing webhook steps",
        status: "completed",
        progress: 100,
        duration_ms: 80,
        pid_str: "pid 1002"
      }

      assigns = %{operations: [root_op, child_op], expanded_ops: MapSet.new(["root-1"])}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "2 ops"
      assert html =~ "2 done"
      assert html =~ "SwarmCoordinator"
      assert html =~ "Swarm Goal: Payment webhook"
      assert html =~ "PlannerAgent"
      assert html =~ "Decomposing webhook steps"
      assert html =~ "tree-node-connector"
    end

    test "renders expanded node detail drawer with error message and params" do
      failed_op = %Operation{
        id: "fail-1",
        parent_op_id: nil,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "ExUnit Suite Run",
        status: "failed",
        error_message: "Compilation error: undefined function Auth.login/2",
        params: %{"test_file" => "test/auth_test.exs"},
        result: "1 test, 1 failure"
      }

      assigns = %{operations: [failed_op], expanded_ops: MapSet.new(["fail-1"])}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "Error:"
      assert html =~ "undefined function Auth.login/2"
      assert html =~ "Result:"
      assert html =~ "1 test, 1 failure"
      assert html =~ "test/auth_test.exs"
    end
  end

  # ============================================================================
  # F7: Diff Viewer Tests
  # ============================================================================

  describe "<.diff_viewer />" do
    test "renders empty state when diff_text is empty" do
      assigns = %{diff_text: "", diff_mode: "inline", file_path: nil}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html =~ "No patch or diff selected"
      assert html =~ "Inline"
      assert html =~ "Side-by-Side"
      assert html =~ "Copy Diff"
    end

    test "renders inline diff with additions, deletions, and hunk headers" do
      diff = """
      --- a/lib/calc.ex
      +++ b/lib/calc.ex
      @@ -1,3 +1,3 @@
       defmodule Calc do
      -  def add(a, b), do: a - b
      +  def add(a, b), do: a + b
       end
      """

      assigns = %{diff_text: diff, diff_mode: "inline", file_path: "lib/calc.ex"}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html =~ "lib/calc.ex"
      assert html =~ "bg-emerald-950/40"
      assert html =~ "bg-rose-950/40"
      assert html =~ "text-emerald-300"
      assert html =~ "text-rose-300"
      assert html =~ "def add(a, b), do: a + b"
      assert html =~ "def add(a, b), do: a - b"
    end

    test "renders side-by-side split diff mode" do
      diff = """
      --- a/lib/calc.ex
      +++ b/lib/calc.ex
      @@ -1,2 +1,2 @@
      -old_value = 1
      +new_value = 2
      """

      assigns = %{diff_text: diff, diff_mode: "split", file_path: "lib/calc.ex"}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html =~ "Original"
      assert html =~ "Modified"
      assert html =~ "old_value = 1"
      assert html =~ "new_value = 2"
    end
  end

  # ============================================================================
  # F8: File Explorer Tests
  # ============================================================================

  describe "<.file_explorer />" do
    test "renders file listing and search filter" do
      files = ["lib/app.ex", "lib/engine.ex", "test/app_test.exs"]
      assigns = %{files: files, filter: "engine", selected_file: nil, file_content: nil}

      html =
        rendered_to_string(~H"""
        <.file_explorer
          files={@files}
          filter={@filter}
          selected_file={@selected_file}
          file_content={@file_content}
        />
        """)

      assert html =~ "1 files"
      assert html =~ "lib/engine.ex"
      refute html =~ "lib/app.ex"
      assert html =~ "Select a workspace file on the left to preview contents"
    end

    test "renders selected file content and copy button" do
      files = ["lib/user.ex"]
      content = "defmodule User do\n  def schema, do: :ok\nend"

      assigns = %{
        files: files,
        filter: "",
        selected_file: "lib/user.ex",
        file_content: content
      }

      html =
        rendered_to_string(~H"""
        <.file_explorer
          files={@files}
          filter={@filter}
          selected_file={@selected_file}
          file_content={@file_content}
        />
        """)

      assert html =~ "lib/user.ex"
      assert html =~ "defmodule User do"
      assert html =~ "def schema, do: :ok"
      assert html =~ "Copy"
    end

    test "exposes the configured autosave policy to the editor hook" do
      assigns = %{
        files: ["lib/user.ex"],
        filter: "",
        selected_file: "lib/user.ex",
        file_content: "defmodule User, do: nil",
        auto_save: true
      }

      html =
        rendered_to_string(~H"""
        <.file_explorer
          files={@files}
          filter={@filter}
          selected_file={@selected_file}
          file_content={@file_content}
          auto_save={@auto_save}
        />
        """)

      assert html =~ ~s(id="code-editor-viewport")
      assert html =~ ~s(data-auto-save="true")
    end
  end

  # ============================================================================
  # F9: Terminal Session & ANSI Parser Tests
  # ============================================================================

  describe "<.terminal_session /> and ansi_to_html/1" do
    test "renders quick action buttons, xterm hook container, and terminal controls" do
      assigns = %{session: %{id: "session-123"}, running: true, cols: 80, rows: 24}

      html =
        rendered_to_string(~H"""
        <.terminal_session session={@session} running={@running} cols={@cols} rows={@rows} />
        """)

      assert html =~ "btn-quick-iex"
      assert html =~ "btn-quick-test"
      assert html =~ "btn-quick-precommit"
      assert html =~ "btn-quick-git-status"
      assert html =~ "btn-quick-git-diff"
      assert html =~ "Clear"
      assert html =~ "Restart"
      assert html =~ "Kill"
      assert html =~ "terminal-xterm-container"
      assert html =~ "phx-hook=\"TerminalHook\""
      assert html =~ "phx-update=\"ignore\""
      assert html =~ "data-session-id=\"session-123\""
      assert html =~ "80x24"
    end

    test "ansi_to_html converts standard ANSI colors into styled spans" do
      raw_green = "\e[32mPASS: All checks succeeded\e[0m"
      html_green = Phoenix.HTML.safe_to_string(ansi_to_html(raw_green))
      assert html_green =~ "text-emerald-400"
      assert html_green =~ "PASS: All checks succeeded"

      raw_red = "\e[31mFAIL: 2 assertions failed\e[0m"
      html_red = Phoenix.HTML.safe_to_string(ansi_to_html(raw_red))
      assert html_red =~ "text-rose-400"
      assert html_red =~ "FAIL: 2 assertions failed"
    end

    test "ansi_to_html handles 24-bit TrueColor and compound SGR sequences" do
      truecolor = "\e[38;2;255;128;0mCustom RGB Color\e[0m"
      html = Phoenix.HTML.safe_to_string(ansi_to_html(truecolor))
      assert html =~ "color: rgb(255,128,0)"
      assert html =~ "Custom RGB Color"

      compound = "\e[1;32mBold Green Text\e[0m"
      html_compound = Phoenix.HTML.safe_to_string(ansi_to_html(compound))
      assert html_compound =~ "font-bold text-emerald-400"
      assert html_compound =~ "Bold Green Text"
    end

    test "ansi_to_html cleans unclosed escapes and handles nil gracefully" do
      assert Phoenix.HTML.safe_to_string(ansi_to_html(nil)) == ""

      control_escape = "Normal text \e[2K\e[?25h cleaned"
      html = Phoenix.HTML.safe_to_string(ansi_to_html(control_escape))
      assert html =~ "Normal text"
      assert html =~ "cleaned"
      refute html =~ "\e["
    end
  end

  # ============================================================================
  # F10: Test Runner Panel Component Tests
  # ============================================================================

  describe "<.test_runner_panel />" do
    alias IexCode.Tools.TestRunner.{Result, Failure, StackFrame}

    test "safely renders failure stacktrace with StackFrame structs and strings" do
      failure = %Failure{
        index: 1,
        test_name: "test math failure",
        module: "MathTest",
        file: "test/math_test.exs",
        line: 14,
        message: "Expected 2, got 3",
        left: "3",
        right: "2",
        code_snippet: "assert 1 + 2 == 2",
        stacktrace: [
          %StackFrame{
            app: "iex_code",
            file: "lib/math.ex",
            line: 42,
            context: "Math.calc/1",
            raw: "lib/math.ex:42: Math.calc/1"
          },
          "test/math_test.exs:14: (test)"
        ]
      }

      result = %Result{
        status: :failed,
        total: 1,
        passed: 0,
        failures_count: 1,
        skipped: 0,
        seed: 12345,
        duration_s: 0.12,
        failures: [failure],
        compilation_errors: []
      }

      assigns = %{
        test_runner_result: result,
        test_runner_status: :failed,
        test_runner_progress_pct: 100,
        test_runner_progress_msg: "Complete"
      }

      html =
        rendered_to_string(~H"""
        <.test_runner_panel
          test_runner_result={@test_runner_result}
          test_runner_status={@test_runner_status}
          test_runner_progress_pct={@test_runner_progress_pct}
          test_runner_progress_msg={@test_runner_progress_msg}
        />
        """)

      assert html =~ "test math failure"
      assert html =~ "Expected 2, got 3"
      assert html =~ "lib/math.ex:42: Math.calc/1"
      assert html =~ "test/math_test.exs:14: (test)"
      assert html =~ "Auto-Fix Failure"
    end
  end
end
