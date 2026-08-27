defmodule IexCode.Tools.TestRunner.StackFrame do
  @moduledoc """
  Represents a single frame in an ExUnit stack trace.
  """
  @type t :: %__MODULE__{
          app: String.t() | nil,
          file: String.t(),
          line: pos_integer(),
          context: String.t() | nil,
          raw: String.t()
        }
  defstruct [:app, :file, :line, :context, :raw]
end

defmodule IexCode.Tools.TestRunner.Failure do
  @moduledoc """
  Represents an individual ExUnit test failure with structured diagnostics.
  """
  alias IexCode.Tools.TestRunner.StackFrame

  @type t :: %__MODULE__{
          index: pos_integer(),
          test_name: String.t(),
          module: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t(),
          code_snippet: String.t() | nil,
          left: String.t() | nil,
          right: String.t() | nil,
          stacktrace: [StackFrame.t()]
        }
  defstruct [
    :index,
    :test_name,
    :module,
    :file,
    :line,
    :message,
    :code_snippet,
    :left,
    :right,
    stacktrace: []
  ]
end

defmodule IexCode.Tools.TestRunner.CompilationError do
  @moduledoc """
  Represents a compiler or syntax error encountered during test execution.
  """
  @type t :: %__MODULE__{
          error_type: String.t(),
          file: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          message: String.t(),
          raw: String.t()
        }
  defstruct [:error_type, :file, :line, :column, :message, :raw]
end

defmodule IexCode.Tools.TestRunner.Result do
  @moduledoc """
  Structured result of a test suite run.
  """
  alias IexCode.Tools.TestRunner.{Failure, CompilationError}

  @type status :: :passed | :failed | :compilation_error | :timeout | :error

  @type t :: %__MODULE__{
          status: status(),
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failures_count: non_neg_integer(),
          excluded: non_neg_integer(),
          skipped: non_neg_integer(),
          invalid: non_neg_integer(),
          duration_s: float(),
          seed: integer() | nil,
          failures: [Failure.t()],
          compilation_errors: [CompilationError.t()],
          raw_output: String.t(),
          exit_code: integer(),
          artifact_id: Ecto.UUID.t() | nil,
          output_bytes: non_neg_integer(),
          output_truncated?: boolean()
        }
  defstruct status: :passed,
            total: 0,
            passed: 0,
            failures_count: 0,
            excluded: 0,
            skipped: 0,
            invalid: 0,
            duration_s: 0.0,
            seed: nil,
            failures: [],
            compilation_errors: [],
            raw_output: "",
            exit_code: 0,
            artifact_id: nil,
            output_bytes: 0,
            output_truncated?: false
end

defmodule IexCode.Tools.TestRunner.Parser do
  @moduledoc """
  Pure functional parser for ExUnit output, failures, stack traces, and compilation errors.
  """

  alias IexCode.Tools.TestRunner.{Result, Failure, StackFrame, CompilationError}

  @doc """
  Parses raw CLI test output and exit code into a structured `Result`.
  """
  @spec parse(binary(), integer()) :: Result.t()
  def parse(raw_output, exit_code \\ 0) when is_binary(raw_output) do
    clean_text = strip_ansi(raw_output)

    compilation_errors = parse_compilation_errors(clean_text)
    summary = parse_summary(clean_text)
    failures = parse_failures(clean_text)
    seed = parse_seed(clean_text)
    duration = parse_duration(clean_text)

    failures_count = Map.get(summary, :failures_count, length(failures))
    total = Map.get(summary, :total, 0)
    excluded = Map.get(summary, :excluded, 0)
    skipped = Map.get(summary, :skipped, 0)
    invalid = Map.get(summary, :invalid, 0)
    passed = max(0, total - failures_count - excluded - skipped - invalid)

    status =
      cond do
        compilation_errors != [] and total == 0 ->
          :compilation_error

        failures_count > 0 or exit_code != 0 ->
          :failed

        true ->
          :passed
      end

    %Result{
      status: status,
      total: total,
      passed: passed,
      failures_count: failures_count,
      excluded: excluded,
      skipped: skipped,
      invalid: invalid,
      duration_s: duration,
      seed: seed,
      failures: failures,
      compilation_errors: compilation_errors,
      raw_output: clean_text,
      exit_code: exit_code
    }
  end

  @doc """
  Strips ANSI color and cursor control escape codes from binary text.
  """
  @spec strip_ansi(binary()) :: binary()
  def strip_ansi(text) when is_binary(text) do
    text
    |> String.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\[[0-9;]*[mK]/, "")
  end

  @doc """
  Parses summary test metrics (total, failures, excluded, skipped, invalid).

  The real summary is the *last* "N tests, M failures" occurrence in the
  output; failure body text can contain similar phrasing, so earlier matches
  are ignored.
  """
  @spec parse_summary(binary()) :: map()
  def parse_summary(text) do
    summary_line =
      text
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.find("", &(&1 =~ ~r/\d+\s+tests?,\s+\d+\s+failures?/))

    case Regex.run(~r/(\d+)\s+tests?,\s+(\d+)\s+failures?/, summary_line) do
      [_, total_str, failures_str] ->
        %{
          total: String.to_integer(total_str),
          failures_count: String.to_integer(failures_str),
          excluded: count_in_summary(summary_line, "excluded"),
          skipped: count_in_summary(summary_line, "skipped"),
          invalid: count_in_summary(summary_line, "invalid")
        }

      _ ->
        %{total: 0, failures_count: 0, excluded: 0, skipped: 0, invalid: 0}
    end
  end

  defp count_in_summary(line, keyword) do
    case Regex.run(~r/(\d+)\s+#{keyword}/, line) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  @doc """
  Parses individual ExUnit failure blocks from test output.
  """
  @spec parse_failures(binary()) :: [Failure.t()]
  def parse_failures(text) do
    # Split text by failure headers: "  1) test name (Module)"
    # The module part must look like an actual module name to avoid matching
    # body lines that merely resemble failure headers.
    failure_pattern = ~r/^\s*(\d+)\)\s+(.+?)\s+\(([A-Z][A-Za-z0-9_.]*)\)\s*$/m

    case Regex.scan(failure_pattern, text, return: :index) do
      [] ->
        []

      matches ->
        # Extract slices between each match
        slices =
          matches
          |> reject_phantom_matches(text)
          |> extract_failure_slices(text)

        Enum.map(slices, fn {idx, test_name, module, block_text} ->
          parse_single_failure(idx, test_name, module, block_text)
        end)
    end
  end

  @doc """
  Parses compiler/syntax errors if compilation failed before tests.
  """
  @spec parse_compilation_errors(binary()) :: [CompilationError.t()]
  def parse_compilation_errors(text) do
    errors = []

    # Pattern 1: ** (CompileError) file:line: message
    errors1 =
      Regex.scan(~r/\*\*\s+\(([\w\.]+Error)\)\s+([^:\n]+):(\d+)(?::(\d+))?:\s*(.+)/, text)
      |> Enum.map(fn [raw, err_type, file, line_str, col_str, msg] ->
        %CompilationError{
          error_type: err_type,
          file: String.trim(file),
          line: String.to_integer(line_str),
          column: if(col_str != "", do: String.to_integer(col_str), else: nil),
          message: String.trim(msg),
          raw: raw
        }
      end)

    # Pattern 2: == Compilation error in file <file> ==
    errors2 =
      Regex.scan(
        ~r/== Compilation error in file ([^=]+) ==\s*\n\*\*\s+\(([\w\.]+Error)\)\s*(.+)/,
        text
      )
      |> Enum.map(fn [raw, file, err_type, msg] ->
        %CompilationError{
          error_type: err_type,
          file: String.trim(file),
          line: nil,
          column: nil,
          message: String.trim(msg),
          raw: raw
        }
      end)

    (errors ++ errors1 ++ errors2) |> Enum.uniq_by(&{&1.file, &1.line, &1.message})
  end

  # --- Internal Helpers ---

  defp parse_seed(text) do
    case Regex.run(~r/Running ExUnit with seed:\s*(\d+)/, text) do
      [_, seed_str] -> String.to_integer(seed_str)
      _ -> nil
    end
  end

  defp parse_duration(text) do
    case Regex.run(~r/Finished in ([\d\.]+) seconds/, text) do
      [_, dur_str] ->
        case Float.parse(dur_str) do
          {f, _} -> f
          _ -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp extract_failure_slices(matches, text) do
    matches
    |> Enum.with_index()
    |> Enum.map(fn {match_list, idx} ->
      [{start_pos, _}, {num_pos, num_len}, {name_pos, name_len}, {mod_pos, mod_len}] = match_list
      num_str = binary_part(text, num_pos, num_len)
      test_name = binary_part(text, name_pos, name_len)
      module = binary_part(text, mod_pos, mod_len)

      next_start =
        case Enum.at(matches, idx + 1) do
          [{next_pos, _} | _] ->
            next_pos

          _ ->
            # Stop at "Finished in" or end of text
            case Regex.run(~r/\nFinished in/, text, return: :index) do
              [{fin_pos, _}] -> fin_pos
              _ -> byte_size(text)
            end
        end

      block_len = max(0, next_start - start_pos)
      block = binary_part(text, start_pos, block_len)
      {String.to_integer(num_str), test_name, module, block}
    end)
  end

  # ExUnit numbers failures sequentially starting at 1. Body lines that merely
  # resemble failure headers (phantom matches) don't continue the sequence and
  # are dropped here.
  defp reject_phantom_matches(matches, text) do
    {kept, _next} =
      Enum.reduce(matches, {[], 1}, fn match, {acc, expected} ->
        [{_start, _}, {num_pos, num_len} | _] = match
        num = String.to_integer(binary_part(text, num_pos, num_len))

        if num == expected do
          {[match | acc], expected + 1}
        else
          {acc, expected}
        end
      end)

    Enum.reverse(kept)
  end

  defp parse_single_failure(idx, test_name, module, block) do
    lines = String.split(block, ~r/\r?\n/)

    # Location line is usually line 2: "     test/my_app/calc_test.exs:42"
    {file, line} =
      Enum.find_value(lines, {nil, nil}, fn l ->
        case Regex.run(~r/^\s+([^:\n\s]+):(\d+)\s*$/, l) do
          [_, f, line_str] -> {f, String.to_integer(line_str)}
          _ -> nil
        end
      end)

    # Extract assertion details
    code_snippet =
      case Regex.run(~r/\s+code:\s+(.+)/, block) do
        [_, c] -> String.trim(c)
        _ -> nil
      end

    left =
      case Regex.run(~r/\s+left:\s+(.+)/, block) do
        [_, l] -> String.trim(l)
        _ -> nil
      end

    right =
      case Regex.run(~r/\s+right:\s+(.+)/, block) do
        [_, r] -> String.trim(r)
        _ -> nil
      end

    # Extract primary message
    message = extract_failure_message(lines)

    # Extract stacktrace frames
    stacktrace = extract_stacktrace(block)

    %Failure{
      index: idx,
      test_name: test_name,
      module: module,
      file: file,
      line: line,
      message: message,
      code_snippet: code_snippet,
      left: left,
      right: right,
      stacktrace: stacktrace
    }
  end

  defp extract_failure_message(lines) do
    # Lines between location line and "code:" / "stacktrace:"
    body_lines =
      lines
      |> Enum.drop(2)
      |> Enum.take_while(fn l ->
        not String.contains?(l, "code:") and
          not String.contains?(l, "stacktrace:") and
          not String.contains?(l, "left:")
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.join(body_lines, " ")
  end

  defp extract_stacktrace(block) do
    case String.split(block, ~r/\s+stacktrace:\r?\n/) do
      [_, stack_text | _] ->
        stack_text
        |> String.split(~r/\r?\n/)
        |> Enum.map(&parse_stack_frame/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_stack_frame(line) do
    line_trim = String.trim(line)

    if line_trim == "" or String.starts_with?(line_trim, "Finished in") do
      nil
    else
      # Frame regex: (app 0.1.0) lib/calc.ex:25: MyApp.do_calc/2
      # or test/foo_test.exs:44: (test)
      case Regex.run(
             ~r/^(?:\(([\w\.\-]+)\s+[\w\.\-]+\)\s+)?([^:\n]+):(\d+):(?:\s*(.+))?/,
             line_trim
           ) do
        [_, app, file, line_str, context] ->
          %StackFrame{
            app: if(app != "", do: app, else: nil),
            file: file,
            line: String.to_integer(line_str),
            context: if(context != "", do: String.trim(context), else: nil),
            raw: line_trim
          }

        [_, file, line_str, context] ->
          %StackFrame{
            app: nil,
            file: file,
            line: String.to_integer(line_str),
            context: if(context != "", do: String.trim(context), else: nil),
            raw: line_trim
          }

        _ ->
          nil
      end
    end
  end
end
