defmodule IexCode.Tools.TestRunner.ParserTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.TestRunner.Parser
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError}

  @passing_output """
  Running ExUnit with seed: 671462, max_cases: 1
  ................
  Finished in 0.2 seconds (0.1s async, 0.1s sync)
  16 tests, 0 failures
  """

  @failure_output """
  Running ExUnit with seed: 12345, max_cases: 1
  ..F..

    1) test calculate total with discount (MyApp.CalculatorTest)
       test/my_app/calculator_test.exs:42
       Assertion with == failed
       code:  assert Calculator.total([10, 20], discount: 5) == 20
       left:  25
       right: 20
       stacktrace:
         (my_app 0.1.0) lib/my_app/calc.ex:25: MyApp.Calc.do_calc/2
         test/my_app/calculator_test.exs:44: (test)

  Finished in 0.15 seconds (0.05s async, 0.10s sync)
  5 tests, 1 failure, 1 excluded, 1 skipped
  """

  @compile_error_output """
  == Compilation error in file lib/iex_code/broken.ex ==
  ** (CompileError) lib/iex_code/broken.ex:15: undefined function non_existent_fn/0
      (stdlib 5.2.3) lists.erl:1338: :lists.foreach/2
      (stdlib 5.2.3) erl_eval.erl:748: :erl_eval.do_apply/7
  """

  describe "parse/2" do
    test "parses passing ExUnit output successfully" do
      result = Parser.parse(@passing_output, 0)

      assert %Result{} = result
      assert result.status == :passed
      assert result.total == 16
      assert result.passed == 16
      assert result.failures_count == 0
      assert result.seed == 671_462
      assert result.duration_s == 0.2
      assert result.failures == []
    end

    test "parses single assertion failure with detailed failure struct" do
      result = Parser.parse(@failure_output, 1)

      assert %Result{} = result
      assert result.status == :failed
      assert result.total == 5
      assert result.failures_count == 1
      assert result.passed == 2
      assert result.excluded == 1
      assert result.skipped == 1

      assert length(result.failures) == 1
      [failure] = result.failures
      assert %Failure{} = failure
      assert failure.index == 1
      assert failure.test_name == "test calculate total with discount"
      assert failure.module == "MyApp.CalculatorTest"
      assert failure.file == "test/my_app/calculator_test.exs"
      assert failure.line == 42
      assert failure.message =~ "Assertion with == failed"
      assert failure.code_snippet =~ "assert Calculator.total([10, 20], discount: 5) == 20"
      assert failure.left == "25"
      assert failure.right == "20"

      assert length(failure.stacktrace) == 2
      [frame1, frame2] = failure.stacktrace
      assert frame1.file == "lib/my_app/calc.ex"
      assert frame1.line == 25
      assert frame1.app == "my_app"
      assert frame1.context == "MyApp.Calc.do_calc/2"

      assert frame2.file == "test/my_app/calculator_test.exs"
      assert frame2.line == 44
    end

    test "parses compilation error before tests execute" do
      result = Parser.parse(@compile_error_output, 1)

      assert %Result{} = result
      assert result.status == :compilation_error
      assert length(result.compilation_errors) >= 1
      [err | _] = result.compilation_errors
      assert %CompilationError{} = err
      assert err.error_type == "CompileError"
      assert err.file == "lib/iex_code/broken.ex"
      assert err.message =~ "undefined function non_existent_fn/0"
    end

    test "strip_ansi/1 removes ANSI color codes transparently" do
      colored = "\e[31m1 failure\e[0m in \e[32m16 tests\e[0m"
      assert Parser.strip_ansi(colored) == "1 failure in 16 tests"
    end
  end
end
