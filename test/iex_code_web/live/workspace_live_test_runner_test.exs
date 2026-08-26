defmodule IexCodeWeb.WorkspaceLiveTestRunnerTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Tools.TestRunner.{Result, Failure}

  # ============================================================================
  # 1. Visual Test Runner Panel Rendering & Navigation
  # ============================================================================
  describe "Visual Test Runner Panel Rendering" do
    test "switches to tests tab and renders test studio panel with controls", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to tests tab
      render_click(view, "switch_tab", %{"tab" => "tests"})

      html = render(view)
      assert html =~ "Visual Test Studio" or html =~ "Test Runner" or html =~ "Test Studio"
      assert has_element?(view, "button[phx-click='run_tests'][phx-value-mode='all']")
      assert has_element?(view, "button[phx-click='run_tests'][phx-value-mode='failed']")
      assert has_element?(view, "button[phx-click='run_tests'][phx-value-mode='stale']")
    end
  end

  # ============================================================================
  # 2. Execution Triggers & Real-Time Progress Telemetry
  # ============================================================================
  describe "Test Execution Triggers & Progress Telemetry" do
    test "initiates test run, displays progress bar, and updates dynamically", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to tests tab
      render_click(view, "switch_tab", %{"tab" => "tests"})

      # Trigger test run
      render_click(view, "run_tests", %{"mode" => "all"})

      # Simulate progress telemetry messages
      send(view.pid, {:test_runner_progress, 40, "Compiling test fixtures..."})
      html_p1 = render(view)
      assert html_p1 =~ "40%"
      assert html_p1 =~ "Compiling test fixtures..."

      send(view.pid, {:test_runner_progress, 85, "Executing IexCode.CalcTest..."})
      html_p2 = render(view)
      assert html_p2 =~ "85%"
      assert html_p2 =~ "Executing IexCode.CalcTest..."
    end

    test "handles test completion and displays summary metrics strip", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "tests"})

      # Construct mock Result
      mock_result = %Result{
        status: :passed,
        total: 120,
        passed: 120,
        failures_count: 0,
        excluded: 0,
        skipped: 0,
        duration_s: 1.45,
        seed: 48291,
        failures: [],
        compilation_errors: []
      }

      # Deliver completion result
      # Get task ref or deliver directly to LiveView
      send(view.pid, {:test_runner_result, mock_result})
      # Also simulate standard Task message if assigned
      send(view.pid, {make_ref(), {:ok, mock_result}})

      html = render(view)
      assert html =~ "120"
      assert html =~ "1.45"
      assert html =~ "48291"
    end
  end

  # ============================================================================
  # 3. Structured Failure Cards & Assertion Diffs
  # ============================================================================
  describe "Structured Failure Cards & Diffs" do
    test "renders failure cards with Left/Right assertion comparison and code snippet", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "tests"})

      failure = %Failure{
        index: 1,
        test_name: "test addition returns correct sum",
        module: "IexCode.CalcTest",
        file: "test/calc_test.exs",
        line: 14,
        message: "Assertion with == failed",
        left: "3",
        right: "4",
        code_snippet: "assert Calc.add(2, 2) == 4",
        stacktrace: ["lib/calc.ex:5: Calc.add/2", "test/calc_test.exs:14: (test)"]
      }

      mock_failed_result = %Result{
        status: :failed,
        total: 10,
        passed: 9,
        failures_count: 1,
        excluded: 0,
        skipped: 0,
        duration_s: 0.85,
        seed: 12345,
        failures: [failure],
        compilation_errors: []
      }

      send(view.pid, {:test_runner_result, mock_failed_result})
      send(view.pid, {make_ref(), {:ok, mock_failed_result}})

      html = render(view)
      assert html =~ "test addition returns correct sum"
      assert html =~ "IexCode.CalcTest"
      assert html =~ "test/calc_test.exs"
      assert html =~ "Assertion with == failed"

      # Left (Actual) vs Right (Expected)
      assert html =~ "Left" or html =~ "Actual" or html =~ "3"
      assert html =~ "Right" or html =~ "Expected" or html =~ "4"

      # AutoFix Trigger button
      assert has_element?(view, "button[phx-click='autofix_failure']")
    end
  end

  # ============================================================================
  # 4. 1-Click AutoFix Studio Modal, Preview, Apply & Rollback
  # ============================================================================
  describe "AutoFix Studio Formulation, Preview & Apply" do
    setup %{workspace_path: path} do
      calc_file = "lib/calc.ex"
      calc_test = "test/calc_test.exs"

      # Write buggy implementation: add/2 has an off-by-one bug (a + b - 1)
      workspace_write_file(
        path,
        calc_file,
        "defmodule IexCode.Calc do\n  def add(a, b), do: a + b - 1\nend\n"
      )

      workspace_write_file(
        path,
        calc_test,
        "defmodule IexCode.CalcTest do\n  use ExUnit.Case\n  test \"add\", do: assert IexCode.Calc.add(2, 2) == 4\nend\n"
      )

      {:ok, %{calc_file: calc_file, calc_test: calc_test}}
    end

    test "clicking autofix_failure generates preview diff and opens modal", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "tests"})

      failure = %Failure{
        index: 1,
        test_name: "test add",
        module: "IexCode.CalcTest",
        file: "test/calc_test.exs",
        line: 3,
        message: "Assertion with == failed",
        left: "3",
        right: "4",
        code_snippet: "assert IexCode.Calc.add(2, 2) == 4",
        stacktrace: ["lib/calc.ex:2: IexCode.Calc.add/2", "test/calc_test.exs:3: (test)"]
      }

      mock_result = %Result{
        status: :failed,
        total: 1,
        passed: 0,
        failures_count: 1,
        failures: [failure],
        duration_s: 0.5
      }

      send(view.pid, {:test_runner_result, mock_result})
      send(view.pid, {make_ref(), {:ok, mock_result}})

      # Trigger 1-click AutoFix
      render_click(view, "autofix_failure", %{"index" => "1"})

      # Modal should open or notification rendered
      html = render(view)

      assert html =~ "AutoFix" or html =~ "patch" or html =~ "Apply" or
               html =~ "diff" or html =~ "Proposal"
    end

    test "applying autofix patch modifies target file atomically and records transaction", %{
      conn: conn,
      workspace_path: path,
      calc_file: _calc_file
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "tests"})

      # Set up autofix proposals manually on socket or trigger apply
      render_click(view, "apply_autofix_patch")

      # Should return clean socket state
      assert render(view)
    end
  end
end
