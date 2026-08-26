defmodule IexCode.Tools.AutoFix do
  @moduledoc """
  Instant Auto-Fix Engine.
  Analyzes compiler diagnostics and ExUnit test failures, resolves target files
  and line numbers from stack traces, generates targeted atomic patch proposals
  via heuristics and LLM synthesis, and applies them atomically via MultiPatch.
  """
  require Logger
  alias IexCode.Tools.{MultiPatch, ASTSearch}
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError, StackFrame}
  alias IexCode.LLM

  @type diagnostic ::
          Result.t()
          | Failure.t()
          | CompilationError.t()
          | String.t()
          | map()
          | list()

  @doc """
  Analyzes test failures and compiler diagnostics to extract target files,
  line numbers, error categories, and contextual source snippets.
  """
  @spec analyze_failures(Path.t(), diagnostic()) :: {:ok, [map()]} | {:error, term()}
  def analyze_failures(_project_root, nil), do: {:error, :nil_diagnostic}
  def analyze_failures(nil, _diagnostic), do: {:error, :nil_project_root}

  def analyze_failures(project_root, diagnostic) do
    failures = extract_failures_list(diagnostic)

    analyzed =
      Enum.map(failures, fn failure ->
        target = resolve_target_file_and_line(failure, project_root)
        error_type = classify_error(failure)
        context = read_surrounding_context(project_root, target.file, target.line)

        %{
          file: target.file,
          line: target.line,
          source: target.source,
          error_type: error_type,
          message: extract_message(failure),
          left: extract_field(failure, :left),
          right: extract_field(failure, :right),
          code_snippet: extract_field(failure, :code_snippet),
          context: context,
          raw: failure
        }
      end)

    {:ok, analyzed}
  rescue
    e -> {:error, "Failed to analyze failures: #{Exception.message(e)}"}
  end

  @doc """
  Generates targeted atomic patch proposals from test runner results or compiler errors.
  Returns `{:ok, [patch_spec]}`.

  Options:

    - `:use_llm` - fall back to LLM-generated patches when no heuristic matches
    - `:session` - LLM session enabling the LLM fallback
    - `:rewrite_assertions` - opt-in; allows rewriting failing assertions to
      match actual values (can mask bugs in the code under test, so it is
      disabled by default)
  """
  @spec generate_patch_proposals(Path.t(), diagnostic(), keyword()) ::
          {:ok, [MultiPatch.patch_spec()]} | {:error, term()}
  def generate_patch_proposals(project_root, diagnostic, opts \\ []) do
    with {:ok, analyzed_list} <- analyze_failures(project_root, diagnostic) do
      patches =
        analyzed_list
        |> Enum.flat_map(fn item ->
          case formulate_heuristic_patch(project_root, item, opts) do
            {:ok, proposals} when is_list(proposals) and proposals != [] ->
              proposals

            _ ->
              # Fallback to LLM if enabled or requested
              if opts[:use_llm] == true or opts[:session] != nil do
                formulate_llm_patch(project_root, item, opts)
              else
                []
              end
          end
        end)
        |> Enum.filter(&valid_patch_target?(project_root, &1))
        |> Enum.uniq()

      {:ok, patches}
    end
  rescue
    e -> {:error, "Failed to generate patch proposals: #{Exception.message(e)}"}
  end

  @doc """
  Generates and atomically applies patch proposals for the given failures.
  """
  @spec apply_auto_fix(Path.t(), diagnostic(), keyword()) ::
          {:ok, MultiPatch.patch_summary()} | {:error, term()}
  def apply_auto_fix(project_root, diagnostic, opts \\ []) do
    with :ok <- authorize_write(opts) do
      case generate_patch_proposals(project_root, diagnostic, opts) do
        {:ok, []} ->
          {:error, :no_applicable_patches}

        {:ok, patches} ->
          IexCode.Tools.multi_patch(patches, project_root, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, "Failed to apply auto fix: #{Exception.message(e)}"}
  end

  defp authorize_write(opts) do
    case Keyword.get(opts, :allowed_tools, :all) do
      :all ->
        :ok

      nil ->
        :ok

      allowed_tools when is_list(allowed_tools) ->
        if "multi_patch" in Enum.map(allowed_tools, &to_string/1),
          do: :ok,
          else: {:error, {:tool_not_allowed, "multi_patch"}}

      _other ->
        {:error, {:tool_not_allowed, "multi_patch"}}
    end
  end

  @doc """
  Formats structured diagnostic text for human inspection or LLM prompts.
  """
  @spec format_diagnostics(diagnostic()) :: String.t()
  def format_diagnostics(diagnostic) do
    case diagnostic do
      %Result{} = res ->
        header =
          "### Test Results (#{res.status}): #{res.passed}/#{res.total} passed, #{res.failures_count} failures\n\n"

        failures_text =
          Enum.map_join(res.failures, "\n\n", fn f ->
            """
            - **Failure #{f.index}: #{f.test_name}** (`#{f.file}:#{f.line}`)
              Message: #{f.message}
              #{if f.left && f.right, do: "Left: #{f.left}\n  Right: #{f.right}", else: ""}
              #{if f.code_snippet, do: "Snippet:\n```elixir\n#{f.code_snippet}\n```", else: ""}
            """
          end)

        comp_errors_text =
          Enum.map_join(res.compilation_errors, "\n\n", fn ce ->
            "- **#{ce.error_type}** in `#{ce.file}:#{ce.line}`: #{ce.message}"
          end)

        header <>
          failures_text <> if comp_errors_text != "", do: "\n\n" <> comp_errors_text, else: ""

      %Failure{} = f ->
        """
        **Test Failure**: #{f.test_name} (`#{f.file}:#{f.line}`)
        Message: #{f.message}
        #{if f.left && f.right, do: "Left: #{f.left}\nRight: #{f.right}", else: ""}
        """

      %CompilationError{} = ce ->
        "**Compilation Error** (`#{ce.file}:#{ce.line}`): #{ce.message}"

      str when is_binary(str) ->
        str

      list when is_list(list) ->
        Enum.map_join(list, "\n", &format_diagnostics/1)

      map when is_map(map) ->
        inspect(map)
    end
  end

  # ============================================================================
  # Internal Extraction & Resolution Helpers
  # ============================================================================

  defp extract_failures_list(%Result{failures: failures, compilation_errors: comp_errors}) do
    (failures || []) ++ (comp_errors || [])
  end

  defp extract_failures_list(%Failure{} = f), do: [f]
  defp extract_failures_list(%CompilationError{} = ce), do: [ce]
  defp extract_failures_list(list) when is_list(list), do: list

  defp extract_failures_list(%{failures: [], compilation_errors: []}), do: []

  defp extract_failures_list(%{result: %Result{} = res}) do
    extract_failures_list(res)
  end

  defp extract_failures_list(%{failures: failures, compilation_errors: comp_errors})
       when (is_list(failures) and failures != []) or
              (is_list(comp_errors) and comp_errors != []) do
    (failures || []) ++ (comp_errors || [])
  end

  defp extract_failures_list(%{failures: failures}) when is_list(failures) and failures != [] do
    failures
  end

  defp extract_failures_list(%{compilation_errors: comp_errors})
       when is_list(comp_errors) and comp_errors != [] do
    comp_errors
  end

  defp extract_failures_list(%{file: _file} = single_map) do
    [single_map]
  end

  defp extract_failures_list(%{summary: summary}) when is_binary(summary) and summary != "" do
    [%{message: summary, raw: summary}]
  end

  defp extract_failures_list(str) when is_binary(str) do
    # Convert raw error string into dummy failure struct
    [%{message: str, raw: str}]
  end

  defp extract_failures_list(map) when is_map(map) and map_size(map) > 0, do: [map]
  defp extract_failures_list(_), do: []

  defp resolve_target_file_and_line(
         %Failure{file: file, line: line, stacktrace: stack},
         project_root
       ) do
    # Find first stack frame in lib/
    lib_frame =
      Enum.find_value(stack || [], fn frame ->
        case extract_frame_file_and_line(frame) do
          {f, l} when is_binary(f) and f != "" ->
            norm = normalize_rel_path(f, project_root)

            if String.starts_with?(norm, "lib/") or String.contains?(f, "/lib/") do
              %{file: norm, line: l || 1, source: :stacktrace}
            else
              nil
            end

          _ ->
            nil
        end
      end)

    case lib_frame do
      %{file: _, line: _} = resolved ->
        resolved

      _ ->
        %{file: normalize_rel_path(file, project_root), line: line || 1, source: :test_file}
    end
  end

  defp resolve_target_file_and_line(%StackFrame{file: file, line: line}, project_root) do
    %{file: normalize_rel_path(file, project_root), line: line || 1, source: :stacktrace}
  end

  defp resolve_target_file_and_line(%CompilationError{file: file, line: line}, project_root) do
    %{file: normalize_rel_path(file, project_root), line: line || 1, source: :compilation_error}
  end

  defp resolve_target_file_and_line(%{file: file, line: line}, project_root)
       when is_binary(file) do
    %{file: normalize_rel_path(file, project_root), line: line || 1, source: :map}
  end

  defp resolve_target_file_and_line(%{"file" => file, "line" => line}, project_root)
       when is_binary(file) do
    %{file: normalize_rel_path(file, project_root), line: line || 1, source: :map}
  end

  defp resolve_target_file_and_line(%{message: msg}, project_root) when is_binary(msg) do
    # Try parsing file:line from string like "lib/calc.ex:12: error"
    case Regex.run(~r/([a-zA-Z0-9_\/.-]+\.(?:ex|exs)):(\d+)/, msg) do
      [_, file, line_str] ->
        %{
          file: normalize_rel_path(file, project_root),
          line: String.to_integer(line_str),
          source: :regex
        }

      _ ->
        %{file: "lib", line: 1, source: :unknown}
    end
  end

  defp resolve_target_file_and_line(str, project_root) when is_binary(str) do
    case Regex.run(~r/([a-zA-Z0-9_\/.-]+\.(?:ex|exs)):(\d+)/, str) do
      [_, file, line_str] ->
        %{
          file: normalize_rel_path(file, project_root),
          line: String.to_integer(line_str),
          source: :regex
        }

      _ ->
        %{file: "lib", line: 1, source: :unknown}
    end
  end

  defp resolve_target_file_and_line(_, _project_root) do
    %{file: "", line: 1, source: :unknown}
  end

  defp extract_frame_file_and_line(%StackFrame{file: file, line: line}), do: {file, line}

  defp extract_frame_file_and_line(%{file: file, line: line}) when is_binary(file),
    do: {file, line}

  defp extract_frame_file_and_line(%{"file" => file, "line" => line}) when is_binary(file),
    do: {file, line}

  defp extract_frame_file_and_line(str) when is_binary(str) do
    case Regex.run(~r/([a-zA-Z0-9_\/.-]+\.(?:ex|exs)):(\d+)/, str) do
      [_, file, line_str] -> {file, String.to_integer(line_str)}
      _ -> nil
    end
  end

  defp extract_frame_file_and_line(_), do: nil

  defp normalize_rel_path(nil, _), do: ""

  defp normalize_rel_path(path, project_root) when is_binary(path) and is_binary(project_root) do
    if Path.type(path) == :relative and not String.starts_with?(path, "/") do
      Path.relative_to(Path.expand(path, "/fake_root"), "/fake_root")
    else
      exp_path = realpath(path)
      exp_root = realpath(project_root)

      if String.starts_with?(exp_path, exp_root) do
        Path.relative_to(exp_path, exp_root)
      else
        exp_p = Path.expand(path)
        exp_r = Path.expand(project_root)
        rel = Path.relative_to(exp_p, exp_r)

        if rel != exp_p do
          rel
        else
          path
        end
      end
    end
  end

  defp normalize_rel_path(other, _), do: to_string(other || "")

  defp realpath(path) when is_binary(path) do
    expanded = Path.expand(path)
    resolve_symlink_parts(Path.split(expanded), [])
  end

  defp realpath(other), do: other

  defp resolve_symlink_parts([], acc), do: Path.join(Enum.reverse(acc))

  defp resolve_symlink_parts([head | tail], []) do
    resolve_symlink_parts(tail, [head])
  end

  defp resolve_symlink_parts([head | tail], acc) do
    current = Path.join(Enum.reverse([head | acc]))

    case :file.read_link(String.to_charlist(current)) do
      {:ok, link_target} ->
        target_str = List.to_string(link_target)

        resolved =
          if Path.type(target_str) == :absolute do
            target_str
          else
            Path.expand(target_str, Path.join(Enum.reverse(acc)))
          end

        new_acc = Enum.reverse(Path.split(resolved))
        resolve_symlink_parts(tail, new_acc)

      {:error, _} ->
        resolve_symlink_parts(tail, [head | acc])
    end
  end

  defp resolve_file_path(project_root, path) when is_binary(path) and is_binary(project_root) do
    if Path.type(path) == :absolute do
      if File.exists?(path) do
        path
      else
        rel = normalize_rel_path(path, project_root)
        candidate = Path.expand(Path.join(project_root, rel))
        if File.exists?(candidate), do: candidate, else: path
      end
    else
      Path.expand(Path.join(project_root, path))
    end
  end

  defp resolve_file_path(project_root, other) do
    Path.expand(Path.join(project_root, to_string(other)))
  end

  defp classify_error(%CompilationError{error_type: "SyntaxError"}) do
    :syntax_error
  end

  defp classify_error(%CompilationError{message: msg}) when is_binary(msg) do
    classify_message(msg)
  end

  defp classify_error(%Failure{message: msg}) when is_binary(msg) do
    classify_message(msg)
  end

  defp classify_error(%{error_type: "SyntaxError"}) do
    :syntax_error
  end

  defp classify_error(%{message: msg}) when is_binary(msg) do
    classify_message(msg)
  end

  defp classify_error(_), do: :generic

  defp classify_message(msg) do
    cond do
      String.contains?(msg, "is unused") ->
        :unused_variable

      String.contains?(msg, "is not available") ->
        :missing_alias

      String.contains?(msg, "UndefinedFunctionError") or String.contains?(msg, "is undefined") ->
        :undefined_function

      String.contains?(msg, "Assertion with ==") or String.contains?(msg, "assertion") ->
        :assertion_mismatch

      String.contains?(msg, "syntax error") or String.contains?(msg, "missing terminator") or
        String.contains?(msg, "SyntaxError") or String.contains?(msg, "unexpected reserved word") or
          String.contains?(msg, "unexpected") ->
        :syntax_error

      true ->
        :generic
    end
  end

  defp extract_message(%{message: msg}) when is_binary(msg), do: msg
  defp extract_message(%{raw: raw}) when is_binary(raw), do: raw
  defp extract_message(term), do: inspect(term)

  defp extract_field(struct_or_map, field) do
    case struct_or_map do
      %{^field => val} -> val
      _ -> nil
    end
  end

  defp read_surrounding_context(project_root, rel_path, target_line) do
    full_path = resolve_file_path(project_root, rel_path)

    if File.exists?(full_path) and not File.dir?(full_path) do
      lines = File.read!(full_path) |> String.split("\n")
      total = length(lines)
      start_line = max(1, (target_line || 1) - 15)
      end_line = min(total, (target_line || 1) + 15)

      sliced =
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1))
        |> Enum.with_index(start_line)
        |> Enum.map(fn {line, idx} -> "#{idx}: #{line}" end)
        |> Enum.join("\n")

      %{start_line: start_line, end_line: end_line, content: sliced}
    else
      %{start_line: 1, end_line: 1, content: ""}
    end
  rescue
    _ -> %{start_line: 1, end_line: 1, content: ""}
  end

  # ============================================================================
  # Heuristic Patch Formulation
  # ============================================================================

  defp formulate_heuristic_patch(project_root, item, opts) do
    full_path = resolve_file_path(project_root, item.file)

    if not File.exists?(full_path) or File.dir?(full_path) do
      {:error, :file_not_found}
    else
      content = File.read!(full_path)
      lines = String.split(content, "\n")
      target_line_idx = if is_integer(item.line), do: max(0, item.line - 1), else: 0
      current_line = Enum.at(lines, target_line_idx) || ""

      case item.error_type do
        :unused_variable ->
          fix_unused_variable(item, current_line)

        :missing_alias ->
          fix_missing_alias(project_root, item, content)

        :assertion_mismatch ->
          # Opt-in: rewriting assertions to match actual values can mask real
          # bugs in the code under test.
          if opts[:rewrite_assertions] == true do
            fix_assertion_mismatch(item, current_line)
          else
            {:error, :assertion_rewrite_disabled}
          end

        :syntax_error ->
          fix_syntax_error(item, current_line, content)

        :undefined_function ->
          fix_undefined_function(item, current_line, content)

        _ ->
          {:error, :no_heuristic}
      end
    end
  end

  # 1. Unused Variable: prefix the binding with an underscore, but only when
  # that is safe (never produce `_x = x + 1`, which would break the reference).
  defp fix_unused_variable(item, current_line) do
    case Regex.run(~r/variable "([a-zA-Z0-9_]+)" is unused/, item.message) do
      [_, var_name] ->
        pattern = ~r/\b#{Regex.escape(var_name)}\b/

        cond do
          assignment = Regex.run(~r/^(\s*)#{Regex.escape(var_name)}(\s*=\s*)(.+)$/, current_line) ->
            [_, indent, eq, rhs] = assignment

            if Regex.match?(pattern, rhs) do
              # The variable is referenced on the right-hand side; renaming the
              # binding would turn it into an undefined variable.
              {:error, :var_used_in_rhs}
            else
              new_line = "#{indent}_#{var_name}#{eq}#{rhs}"
              {:ok, [%{path: item.file, target: current_line, replacement: new_line}]}
            end

          # Single occurrence that is not a binding (e.g. a function parameter):
          # renaming it is always safe.
          length(Regex.scan(pattern, current_line)) == 1 ->
            new_line = Regex.replace(pattern, current_line, "_#{var_name}", global: false)
            {:ok, [%{path: item.file, target: current_line, replacement: new_line}]}

          true ->
            {:error, :var_rename_unsafe}
        end

      _ ->
        {:error, :var_name_not_extracted}
    end
  end

  # 2. Missing Module Alias
  defp fix_missing_alias(project_root, item, content) do
    case Regex.run(~r/module ([A-Z][a-zA-Z0-9_.]*) is not available/, item.message) do
      [_, mod_name] ->
        base_name = List.last(String.split(mod_name, "."))

        # Search AST for where this module is defined. Match on the module
        # NAME only: a full-text `query` match would also hit the caller's own
        # module whenever its body references the missing module (e.g. a
        # `Crypto.hash(user)` call makes `defmodule AppAuth.Session` match a
        # search for "Crypto"), and then the wrong alias gets inserted.
        case ASTSearch.search(project_root, %{type: "module", name: base_name}) do
          {:ok, candidates} when is_list(candidates) and candidates != [] ->
            candidates
            |> pick_missing_module(base_name, enclosing_module_name(content, item.line))
            |> case do
              %{} = found ->
                insert_alias_near_error(item, content, found.name)

              nil ->
                {:error, :module_ast_not_found}
            end

          _ ->
            {:error, :module_ast_not_found}
        end

      _ ->
        {:error, :module_not_extracted}
    end
  end

  # Picks the definition matching the missing module from the diagnostic:
  # prefer candidates whose last name segment equals the missing module's base
  # name, and never pick the module enclosing the erroring line (the caller
  # itself cannot be its own missing dependency).
  defp pick_missing_module(candidates, base_name, enclosing_name) do
    candidates
    |> Enum.reject(fn candidate ->
      is_binary(enclosing_name) and candidate.name == enclosing_name
    end)
    |> Enum.sort_by(fn candidate -> last_name_segment(candidate.name) == base_name end, :desc)
    |> List.first()
  end

  defp last_name_segment(name) when is_binary(name) do
    name |> String.split(".") |> List.last()
  end

  # Name of the innermost defmodule that starts before the erroring line.
  defp enclosing_module_name(content, line) when is_integer(line) do
    content
    |> String.split("\n")
    |> Enum.take(max(line, 0))
    |> Enum.reduce(nil, fn text, acc ->
      case Regex.run(~r/^\s*defmodule\s+([A-Z][\w.]*)\s+do\s*$/, text) do
        [_, name] -> name
        _ -> acc
      end
    end)
  end

  defp enclosing_module_name(_content, _line), do: nil

  # Inserts the alias right after the defmodule that encloses the erroring
  # line (innermost when nested), instead of always the first defmodule.
  defp insert_alias_near_error(item, content, full_module_name) do
    lines = String.split(content, "\n")

    candidates =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> line =~ ~r/^\s*defmodule\s+[A-Z][\w.]*\s+do\s*$/ end)

    enclosing =
      if is_integer(item.line) do
        candidates
        |> Enum.filter(fn {_line, lineno} -> lineno <= item.line end)
        |> List.last()
      else
        List.first(candidates)
      end

    case enclosing do
      {defmod_line, _lineno} ->
        replacement = "#{defmod_line}\n  alias #{full_module_name}"
        {:ok, [%{path: item.file, target: defmod_line, replacement: replacement}]}

      nil ->
        {:error, :defmodule_not_found}
    end
  end

  # 3. Assertion Value Mismatch
  defp fix_assertion_mismatch(item, current_line) do
    if item.left && item.right do
      # If right is expected and left is actual
      cond do
        String.contains?(current_line, item.right) ->
          # In test file: replace right with left
          new_line = String.replace(current_line, item.right, item.left, global: false)
          {:ok, [%{path: item.file, target: current_line, replacement: new_line}]}

        String.contains?(current_line, item.left) ->
          # In lib file: replace left with right
          new_line = String.replace(current_line, item.left, item.right, global: false)
          {:ok, [%{path: item.file, target: current_line, replacement: new_line}]}

        true ->
          {:error, :assertion_values_not_in_line}
      end
    else
      {:error, :no_left_right}
    end
  end

  # 4. Syntax Error
  defp fix_syntax_error(item, current_line, _content) do
    fix_missing_keyword_colon(item, current_line)
  end

  # Repairs the one mechanically-safe syntax error: a one-line clause using
  # keyword syntax without the colon (`def f(x), do "..."`). Only applied when
  # the clause head ends with `)` and the token after `do` is a double-quoted
  # string; anything else is left untouched rather than risk corrupting code.
  defp fix_missing_keyword_colon(item, current_line) do
    case Regex.run(~r/^(\s*.+?\)(?:\s*,)?\s*do)\s+"((?:[^"\\]|\\.)*)"\s*$/, current_line) do
      [_, head, body] ->
        new_line = "#{head}: \"#{body}\""
        {:ok, [%{path: item.file, target: current_line, replacement: new_line}]}

      _ ->
        {:error, :not_implemented}
    end
  end

  # 5. Undefined function / typo
  defp fix_undefined_function(_item, _current_line, _content) do
    # No reliable rename/stub heuristic exists yet; the previous fixture-specific
    # rewrites were removed to avoid corrupting real code.
    {:error, :not_implemented}
  end

  # ============================================================================
  # LLM-Assisted Targeted Patch Formulation
  # ============================================================================

  defp formulate_llm_patch(_project_root, item, opts) do
    session = opts[:session]

    prompt = """
    You are an automated Elixir patch generator.
    Fix the following error in `#{item.file}` at line #{item.line}:
    Error: #{item.message}
    #{if item.left && item.right, do: "Left (Actual): #{item.left}\nRight (Expected): #{item.right}", else: ""}

    Context:
    #{item.context.content}

    Respond ONLY with a JSON array of patch objects with exact keys:
    [{"path": "#{item.file}", "target": "exact string to replace", "replacement": "new replacement string"}]
    """

    system_prompt =
      "You output only valid JSON patch specifications without any surrounding markdown or explanation."

    messages = [%{role: "user", content: prompt}]

    case LLM.chat(messages, system_prompt, session) do
      {:ok, %{text: json_text}} ->
        parse_json_patches(json_text)

      _ ->
        []
    end
  end

  defp parse_json_patches(text) when is_binary(text) do
    # Extract JSON array substring
    cleaned =
      case Regex.run(~r/\[.*\]/s, text) do
        [json] -> json
        _ -> text
      end

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn item ->
          %{
            path: item["path"] || item[:path],
            target: item["target"] || item[:target],
            replacement: item["replacement"] || item[:replacement]
          }
        end)
        |> Enum.reject(fn p -> is_nil(p.path) or is_nil(p.target) or is_nil(p.replacement) end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp valid_patch_target?(project_root, %{path: path, target: target})
       when is_binary(path) and is_binary(target) and target != "" do
    full_path = resolve_file_path(project_root, path)
    project_root_abs = Path.expand(project_root)

    if within_project?(full_path, project_root_abs) and File.exists?(full_path) and
         not File.dir?(full_path) do
      content = File.read!(full_path)
      String.contains?(content, target)
    else
      false
    end
  rescue
    _ -> false
  end

  defp valid_patch_target?(_, _), do: false

  defp within_project?(full_path, project_root_abs) when is_binary(project_root_abs) do
    String.starts_with?(full_path, project_root_abs <> "/")
  end

  defp within_project?(_, _), do: false
end
