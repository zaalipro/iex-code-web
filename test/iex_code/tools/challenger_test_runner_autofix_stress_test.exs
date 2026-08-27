defmodule IexCode.Tools.ChallengerTestRunnerAutoFixStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Tools.TestRunner
  alias IexCode.Tools.TestRunner.{Parser, Failure, CompilationError}
  alias IexCode.Tools.AutoFix
  alias IexCode.Tools.MultiPatch

  # ============================================================================
  # 1. TestRunner Parser Fuzzing & Stress
  # ============================================================================
  describe "TestRunner.Parser Output Parsing & Stress" do
    test "strips nested and advanced ANSI escape sequences cleanly" do
      colored_text =
        "\e[31m\e[1m1) test failure (CalcTest)\e[0m\n" <>
          "\e[38;2;255;100;50m     test/calc_test.exs:42\e[0m\n" <>
          "\e[33m     Assertion with == failed\e[0m\n" <>
          "\e[32m     Finished in 0.12 seconds\e[0m\n" <>
          "\e[36m5 tests, 1 failure\e[0m\n"

      cleaned = Parser.strip_ansi(colored_text)
      refute cleaned =~ "\e["
      assert cleaned =~ "1) test failure (CalcTest)"
      assert cleaned =~ "test/calc_test.exs:42"
      assert cleaned =~ "5 tests, 1 failure"
    end

    test "correctly parses complex ExUnit failure output with Left/Right and multiline traces" do
      raw_output = """
      Running ExUnit with seed: 443322

        1) test map equality verification (IexCode.DataTest)
           test/iex_code/data_test.exs:25
           Assertion with == failed
           code:  assert actual_user == expected_user
           left:  %{age: 30, name: "Alice", role: :member}
           right: %{age: 30, name: "Alice", role: :admin}
           stacktrace:
             (iex_code 0.1.0) lib/iex_code/accounts.ex:50: IexCode.Accounts.get_user/1
             (elixir 1.18.0) lib/enum.ex:1234: Enum.map/2
             test/iex_code/data_test.exs:25: (test)

        2) test timeout handling (IexCode.WorkerTest)
           test/iex_code/worker_test.exs:80
           ** (RuntimeError) worker failed to respond within 5000ms
           code:  Worker.call_timeout(pid)
           stacktrace:
             (iex_code 0.1.0) lib/iex_code/worker.ex:110: IexCode.Worker.call_timeout/1
             test/iex_code/worker_test.exs:80: (test)

      Finished in 0.45 seconds (0.10s async, 0.35s sync)
      12 tests, 2 failures, 1 excluded, 2 skipped
      """

      result = Parser.parse(raw_output, 1)

      assert result.status == :failed
      assert result.total == 12
      assert result.failures_count == 2
      assert result.excluded == 1
      assert result.skipped == 2
      assert result.passed == 7
      assert result.duration_s == 0.45
      assert result.seed == 443_322
      assert length(result.failures) == 2

      # Check Failure 1 details
      f1 = hd(result.failures)
      assert f1.index == 1
      assert f1.test_name == "test map equality verification"
      assert f1.module == "IexCode.DataTest"
      assert f1.file == "test/iex_code/data_test.exs"
      assert f1.line == 25
      assert f1.code_snippet == "assert actual_user == expected_user"
      assert f1.left == "%{age: 30, name: \"Alice\", role: :member}"
      assert f1.right == "%{age: 30, name: \"Alice\", role: :admin}"
      assert length(f1.stacktrace) == 3

      # Check Failure 2 details
      f2 = Enum.at(result.failures, 1)
      assert f2.index == 2
      assert f2.test_name == "test timeout handling"
      assert f2.module == "IexCode.WorkerTest"
      assert f2.file == "test/iex_code/worker_test.exs"
      assert f2.line == 80
      assert f2.message =~ "worker failed to respond"
    end

    test "handles phantom failure headers inside test error bodies without corrupting sequence" do
      phantom_output = """
        1) test log printer formatting (IexCode.LoggerTest)
           test/iex_code/logger_test.exs:15
           Assertion with == failed
           code:  assert output == expected
           left:  "  1) fake inner failure line"
           right: "  2) another fake line"
           stacktrace:
             test/iex_code/logger_test.exs:15: (test)

      Finished in 0.05 seconds
      1 test, 1 failure
      """

      result = Parser.parse(phantom_output, 1)
      # Must still only parse 1 real failure, ignoring fake inner lines
      assert result.failures_count == 1
      assert length(result.failures) == 1
      assert hd(result.failures).index == 1
    end

    test "parses compilation and syntax errors across different compiler formats" do
      compile_err_output = """
      == Compilation error in file lib/broken.ex ==
      ** (CompileError) lib/broken.ex:14: undefined function calculate_total/2 (expected calculate_total/1)
      ** (SyntaxError) lib/broken_syntax.ex:5:12: syntax error before: "do"

      """

      result = Parser.parse(compile_err_output, 1)
      assert result.status == :compilation_error
      assert length(result.compilation_errors) >= 2

      err1 = Enum.find(result.compilation_errors, &(&1.file =~ "broken.ex"))
      assert err1 != nil
      assert err1.line == 14
      assert err1.message =~ "undefined function calculate_total/2"

      err2 = Enum.find(result.compilation_errors, &(&1.file =~ "broken_syntax.ex"))
      assert err2 != nil
      assert err2.line == 5
      assert err2.column == 12
    end

    test "picks the final summary line when previous failure logs contained summary patterns" do
      tricky_output = """
        1) test runner parsing (IexCode.RunnerTest)
           test/iex_code/runner_test.exs:10
           Assertion failed
           left:  "Finished in 1.0 seconds\\n100 tests, 0 failures"
           right: "Finished in 2.0 seconds\\n50 tests, 1 failure"

      Finished in 0.02 seconds
      1 test, 1 failure
      """

      result = Parser.parse(tricky_output, 1)
      assert result.total == 1
      assert result.failures_count == 1
      assert result.passed == 0
    end
  end

  # ============================================================================
  # 2. TestRunner Invocation & Execution Options
  # ============================================================================
  describe "TestRunner Runner API" do
    test "provides run_file/3 helper for targeted file runs" do
      # Verifies module contract exists
      assert is_function(&TestRunner.run/1, 1)
      assert is_function(&TestRunner.run/2, 2)
      assert is_function(&TestRunner.run_file/3, 3)
    end
  end

  # ============================================================================
  # 3. AutoFix Heuristic Formulation & MultiPatch Verification
  # ============================================================================
  describe "AutoFix Heuristic Formulation & MultiPatch Atomic Apply" do
    setup %{workspace_path: path} do
      # Set up files for each heuristic fix type
      unused_var_file = "lib/sample_unused.ex"
      missing_alias_target = "lib/auth/token_vault.ex"
      missing_alias_caller = "lib/services/login_service.ex"
      syntax_err_file = "lib/syntax_clause.ex"

      workspace_write_file(
        path,
        unused_var_file,
        """
        defmodule SampleUnused do
          def compute(x, unused_weight) do
            x * 10
          end

          def assign_unused do
            temp_var = compute(2, 3)
            :ok
          end

          def unsafe_rhs do
            y = y + 1
            y
          end
        end
        """
      )

      workspace_write_file(
        path,
        missing_alias_target,
        """
        defmodule Auth.TokenVault do
          def sign(payload), do: "signed_\#{payload}"
        end
        """
      )

      workspace_write_file(
        path,
        missing_alias_caller,
        """
        defmodule Services.LoginService do
          def create_session(user) do
            TokenVault.sign(user)
          end
        end
        """
      )

      workspace_write_file(
        path,
        syntax_err_file,
        """
        defmodule SyntaxClause do
          def greeting(name), do "Hello \#{name}"
        end
        """
      )

      {:ok,
       %{
         unused_var_file: unused_var_file,
         missing_alias_target: missing_alias_target,
         missing_alias_caller: missing_alias_caller,
         syntax_err_file: syntax_err_file
       }}
    end

    test "fixes unused function argument and unused assignment variable via heuristic", %{
      workspace_path: path,
      unused_var_file: file
    } do
      # 1. Unused parameter: variable "unused_weight" is unused
      diag1 = %CompilationError{
        error_type: "CompileError",
        file: file,
        line: 2,
        message:
          "variable \"unused_weight\" is unused (if the variable is not meant to be used, prefix it with an underscore like _unused_weight)"
      }

      {:ok, [patch1]} = AutoFix.generate_patch_proposals(path, diag1)
      assert patch1.path == file
      assert patch1.replacement =~ "_unused_weight"

      # Apply patch 1 atomically
      {:ok, summary1} = MultiPatch.apply_patches(path, [patch1])
      assert summary1.applied == 1

      content_after1 = File.read!(Path.join(path, file))
      assert content_after1 =~ "_unused_weight"

      # 2. Unused local binding: variable "temp_var" is unused
      diag2 = %CompilationError{
        error_type: "CompileError",
        file: file,
        line: 7,
        message:
          "variable \"temp_var\" is unused (if the variable is not meant to be used, prefix it with an underscore like _temp_var)"
      }

      {:ok, [patch2]} = AutoFix.generate_patch_proposals(path, diag2)
      assert patch2.path == file
      assert patch2.replacement =~ "_temp_var"

      # 3. Unsafe case: variable referenced in RHS (y = y + 1)
      diag_unsafe = %CompilationError{
        error_type: "CompileError",
        file: file,
        line: 12,
        message: "variable \"y\" is unused"
      }

      # Should safely decline to generate patch rather than producing broken code (_y = y + 1)
      {:ok, proposals} = AutoFix.generate_patch_proposals(path, diag_unsafe)
      assert proposals == []
    end

    test "fixes missing module alias by discovering definition in AST", %{
      workspace_path: path,
      missing_alias_caller: caller_file
    } do
      diag = %CompilationError{
        error_type: "CompileError",
        file: caller_file,
        line: 3,
        message: "module TokenVault is not available and cannot be expanded"
      }

      {:ok, [patch]} = AutoFix.generate_patch_proposals(path, diag)
      assert patch.path == caller_file
      assert patch.replacement =~ "alias Auth.TokenVault"

      # Preview diff
      {:ok, preview} = MultiPatch.preview_patches(path, [patch])
      assert preview.diff =~ "+  alias Auth.TokenVault"

      # Apply patch atomically
      {:ok, %{transaction_id: tx_id}} = MultiPatch.apply_patches(path, [patch])
      content = File.read!(Path.join(path, caller_file))
      assert content =~ "alias Auth.TokenVault"

      # Rollback patch atomically
      {:ok, _} = MultiPatch.rollback(tx_id)
      restored_content = File.read!(Path.join(path, caller_file))
      refute restored_content =~ "alias Auth.TokenVault"
    end

    test "fixes single-line keyword syntax error missing colon", %{
      workspace_path: path,
      syntax_err_file: file
    } do
      diag = %CompilationError{
        error_type: "SyntaxError",
        file: file,
        line: 2,
        message: "syntax error before: \"do\""
      }

      {:ok, [patch]} = AutoFix.generate_patch_proposals(path, diag)
      assert patch.path == file
      assert patch.replacement =~ "def greeting(name), do: \"Hello \#{name}\""

      # Apply and verify
      {:ok, _} = MultiPatch.apply_patches(path, [patch])
      content = File.read!(Path.join(path, file))
      assert content =~ "do: \"Hello \#{name}\""
    end

    test "handles assertion mismatches based on rewrite_assertions opt-in flag", %{
      workspace_path: path
    } do
      calc_file = "lib/calc_mismatch.ex"

      workspace_write_file(
        path,
        calc_file,
        "defmodule CalcMismatch do\n  def result, do: 42\nend"
      )

      failure = %Failure{
        index: 1,
        test_name: "test result",
        module: "CalcMismatchTest",
        file: calc_file,
        line: 2,
        message: "Assertion with == failed",
        left: "42",
        right: "99",
        code_snippet: "assert CalcMismatch.result() == 99"
      }

      # Default: rewrite_assertions is false (disabled to avoid masking bugs)
      {:ok, proposals_default} = AutoFix.generate_patch_proposals(path, failure)
      assert proposals_default == []

      # Opt-in: rewrite_assertions is true
      {:ok, [proposal_optin]} =
        AutoFix.generate_patch_proposals(path, failure, rewrite_assertions: true)

      assert proposal_optin.path == calc_file
      assert proposal_optin.replacement =~ "99"
    end
  end
end
