defmodule IexCode.Tools.Git.CommitGenerator do
  @moduledoc """
  Heuristic Conventional Commit generator analyzing diffs and staged file paths.
  Produces formatted commit messages like `feat(test-runner): implement TestRunner module`.
  """

  @doc """
  Generates a conventional commit message from diff text and optional staged file list.

  ## Options
  - `:include_body` - Boolean, appends a diff-stat body line (default: false)
  """
  @spec generate(String.t(), [String.t()], keyword()) :: {:ok, String.t()}
  def generate(diff, paths \\ [], opts \\ []) when is_binary(diff) do
    extracted_paths =
      if paths != [] do
        paths
      else
        extract_paths_from_diff(diff)
      end

    type = infer_type(diff, extracted_paths)
    scope = infer_scope(extracted_paths)
    description = infer_description(diff, extracted_paths, type)

    commit_msg =
      if scope && scope != "" do
        "#{type}(#{scope}): #{description}"
      else
        "#{type}: #{description}"
      end

    commit_msg =
      if Keyword.get(opts, :include_body, false) do
        commit_msg <> "\n\n" <> diff_stats_body(diff, extracted_paths)
      else
        commit_msg
      end

    {:ok, commit_msg}
  end

  # --- Helpers ---

  defp extract_paths_from_diff(diff) do
    Regex.scan(~r/^\+\+\+ b\/(.+)$/m, diff)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp infer_type(diff, paths) do
    diff_down = String.downcase(diff)

    cond do
      paths != [] and Enum.all?(paths, &String.starts_with?(&1, "test/")) ->
        "test"

      paths != [] and
          Enum.all?(paths, &(String.ends_with?(&1, ".md") or String.starts_with?(&1, "docs/"))) ->
        "docs"

      paths != [] and
          Enum.all?(paths, fn p ->
            p in ["mix.exs", "mix.lock", ".formatter.exs", ".gitignore"] or
                String.starts_with?(p, "config/")
          end) ->
        "chore"

      # Match keywords on word boundaries so substrings like "prefix" or
      # "fixture" don't classify every diff as a fix.
      Regex.match?(~r/\bfix(ed|es|ing)?\b/, diff_down) or
        String.contains?(diff_down, "multipleresultserror") or
        Regex.match?(~r/\bcrash(ed|es|ing)?\b/, diff_down) or
        Regex.match?(~r/\bbugs?\b/, diff_down) or
        Regex.match?(~r/\brescue\b/, diff_down) or
          String.contains?(diff_down, "safely query") ->
        "fix"

      Regex.match?(~r/\b(refactor|restructure|cleanup)\b/, diff_down) ->
        "refactor"

      Regex.match?(~r/\b(optimize|optimise|benchmark|cache)\b/, diff_down) ->
        "perf"

      String.contains?(diff, "defmodule ") or
        String.contains?(diff, "def ") or
        String.contains?(diff_down, "implement ") or
          String.contains?(diff_down, "add ") ->
        "feat"

      true ->
        "feat"
    end
  end

  defp infer_scope(paths) do
    primary_path = List.first(paths) || ""

    cond do
      String.starts_with?(primary_path, "lib/iex_code/tools/test_runner") -> "test-runner"
      String.starts_with?(primary_path, "lib/iex_code/tools/git") -> "git"
      String.starts_with?(primary_path, "lib/iex_code/tools/ast_search") -> "ast-search"
      String.starts_with?(primary_path, "lib/iex_code/tools/multi_patch") -> "multi-patch"
      String.starts_with?(primary_path, "lib/iex_code/tools/") -> "tools"
      String.starts_with?(primary_path, "lib/iex_code/llm/stream") -> "llm-stream"
      String.starts_with?(primary_path, "lib/iex_code/llm/utf8") -> "utf8-buffer"
      String.starts_with?(primary_path, "lib/iex_code/llm/resilience") -> "resilience"
      String.starts_with?(primary_path, "lib/iex_code/llm/sse") -> "sse-parser"
      String.starts_with?(primary_path, "lib/iex_code/llm/") -> "llm"
      String.starts_with?(primary_path, "lib/iex_code/settings") -> "settings"
      String.starts_with?(primary_path, "lib/iex_code/sessions") -> "sessions"
      String.starts_with?(primary_path, "lib/iex_code/engine") -> "engine"
      String.starts_with?(primary_path, "lib/iex_code_web") -> "ui"
      String.starts_with?(primary_path, "test/") -> nil
      true -> nil
    end
  end

  defp infer_description(diff, paths, type) do
    diff_down = String.downcase(diff)
    primary_path = List.first(paths) || ""

    cond do
      type == "test" ->
        test_file = Path.basename(primary_path, ".exs")
        "update #{test_file}"

      type == "fix" and String.contains?(diff_down, "multipleresultserror") ->
        "prevent crash on multiple settings records"

      type == "feat" and String.contains?(diff, "defmodule ") ->
        case Regex.run(~r/defmodule\s+([A-Za-z0-9\._]+)/, diff) do
          [_, mod] ->
            short_mod = mod |> String.split(".") |> List.last()
            "implement #{short_mod} module"

          _ ->
            "implement new features in #{Path.basename(primary_path)}"
        end

      true ->
        if primary_path != "" do
          "update #{Path.basename(primary_path)}"
        else
          "update project files"
        end
    end
  end

  # Builds a `git diff --stat`-style body line from the actual diff content.
  defp diff_stats_body(diff, paths) do
    files_changed =
      if paths != [] do
        length(paths)
      else
        diff |> extract_paths_from_diff() |> length()
      end

    insertions = count_matching_lines(diff, ~r/^\+(?!\+\+)/m)
    deletions = count_matching_lines(diff, ~r/^-(?!--)/m)

    "#{plural(files_changed, "file")} changed, " <>
      "#{plural(insertions, "insertion")}(+), #{plural(deletions, "deletion")}(-)"
  end

  defp count_matching_lines(text, regex) do
    Regex.scan(regex, text) |> length()
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
