defmodule IexCode.Tools.MultiPatch.Matcher do
  @moduledoc """
  3-Tier Patch Matching Engine:
  1. Tier 1: AST Structural Matching (opt-in only via `tier: :ast`)
  2. Tier 2: Exact String / Substring Matching
  3. Tier 3: Fuzzy Normalization (whitespace & indentation alignment)

  Ambiguous matches are rejected with `{:error, :not_found}` unless
  `allow_multiple: true` is set or an `:anchor_line` hint disambiguates them.
  """

  @type tier :: :ast | :exact | :fuzzy

  @doc """
  Attempts to match and replace `target` with `replacement` in `content`.
  In `:auto` mode applies Tier 2 -> Tier 3; Tier 1 is only used when explicitly
  requested with `tier: :ast`, because an AST round-trip destroys comments —
  the AST tier is restricted to whole-expression replacement that splices only
  the matched expression's source range, preserving all surrounding comments.

  Options:

    * `:allow_multiple` - replace every occurrence instead of requiring a
      unique match (default `false`)
    * `:tier` - `:auto` (default), `:exact`, `:fuzzy`, or `:ast`
    * `:anchor_line` - optional 1-based line hint (e.g. a diff hunk's
      `old_start`) used to disambiguate multiple fuzzy matches
  """
  @spec patch(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), tier: tier()}} | {:error, :not_found}
  def patch(content, target, replacement, opts \\ [])
      when is_binary(content) and is_binary(target) and is_binary(replacement) do
    allow_multiple = Keyword.get(opts, :allow_multiple, false)
    preferred_tier = Keyword.get(opts, :tier, :auto)
    anchor_line = Keyword.get(opts, :anchor_line)

    if target == "" do
      # An empty target would insert `replacement` between every character.
      {:error, :not_found}
    else
      case preferred_tier do
        :ast ->
          tier1_ast_match(content, target, replacement, allow_multiple)

        :exact ->
          tier2_exact_match(content, target, replacement, allow_multiple)

        :fuzzy ->
          tier3_fuzzy_match(content, target, replacement, allow_multiple, anchor_line)

        _auto ->
          # Try Tier 2 (exact) first as it preserves verbatim layout, then
          # Tier 3 (fuzzy). Tier 1 is deliberately not tried in auto mode.
          case tier2_exact_match(content, target, replacement, allow_multiple) do
            {:ok, _} = res ->
              res

            {:error, :not_found} ->
              tier3_fuzzy_match(content, target, replacement, allow_multiple, anchor_line)
          end
      end
    end
  end

  # --- Tier 1: AST Matching (opt-in via `tier: :ast`) ---
  #
  # Performs whole-expression replacement only: the matched expression's exact
  # source range is spliced out and replaced, so comments outside the replaced
  # expression are preserved (a full AST round-trip via Macro.to_string/1 would
  # destroy them). Whenever precise source ranges are unavailable, this tier
  # returns {:error, :not_found} instead of rewriting the whole file.

  defp tier1_ast_match(content, target, replacement, allow_multiple) do
    with {:ok, content_ast} <- parse_quoted(content),
         {:ok, target_ast} <- parse_quoted(target),
         {:ok, _repl_ast} <- parse_quoted(replacement) do
      target_clean = strip_meta(target_ast)
      ranges = content |> expression_ranges(content_ast, target_clean) |> non_overlapping()

      cond do
        ranges == [] ->
          {:error, :not_found}

        length(ranges) > 1 and not allow_multiple ->
          {:error, :not_found}

        true ->
          {:ok, %{content: replace_ranges(content, ranges, replacement), tier: :ast}}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_quoted(source) do
    Code.string_to_quoted(source, token_metadata: true, emit_warnings: false)
  end

  defp expression_ranges(content, ast, target_clean) do
    offsets = line_offsets(content)

    {_, ranges} =
      Macro.prewalk(ast, [], fn node, acc ->
        case ast_source_range(node) do
          {start_pos, end_pos} ->
            if strip_meta(node) == target_clean do
              case absolute_range(offsets, start_pos, end_pos, content) do
                {:ok, range} -> {node, [range | acc]}
                :error -> {node, acc}
              end
            else
              {node, acc}
            end

          nil ->
            {node, acc}
        end
      end)

    Enum.reverse(ranges)
  end

  defp ast_source_range({_, meta, _}) when is_list(meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)
    end_line = Keyword.get(meta, :ending_line)
    end_column = Keyword.get(meta, :ending_column)

    if line && column && end_line && end_column do
      {{line, column}, {end_line, end_column}}
    end
  end

  defp ast_source_range(_), do: nil

  defp absolute_range(offsets, {line, column}, {end_line, end_column}, content) do
    start_offset = line_start(offsets, line) + (column - 1)
    end_offset = line_start(offsets, end_line) + (end_column - 1)

    if start_offset >= 0 and end_offset > start_offset and end_offset <= byte_size(content) do
      {:ok, {start_offset, end_offset}}
    else
      :error
    end
  end

  defp line_offsets(content) do
    content
    |> String.split("\n")
    |> Enum.map_reduce(0, fn line, acc ->
      {acc, acc + byte_size(line) + 1}
    end)
    |> elem(0)
  end

  defp line_start(offsets, line), do: Enum.at(offsets, line - 1, -1)

  # Keeps only non-overlapping ranges (outermost wins) so a target that also
  # matches a nested expression is not spliced twice.
  defp non_overlapping(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce({[], -1}, fn
      {start, stop}, {acc, last_end} when start >= last_end ->
        {[{start, stop} | acc], stop}

      _, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp replace_ranges(content, ranges, replacement) do
    ranges
    |> Enum.reverse()
    |> Enum.reduce(content, fn {start, stop}, acc ->
      binary_part(acc, 0, start) <> replacement <> binary_part(acc, stop, byte_size(acc) - stop)
    end)
  end

  defp strip_meta({form, _meta, args}) when is_list(args) do
    {form, [], Enum.map(args, &strip_meta/1)}
  end

  defp strip_meta({form, _meta, arg}) do
    {form, [], strip_meta(arg)}
  end

  defp strip_meta(list) when is_list(list) do
    Enum.map(list, &strip_meta/1)
  end

  defp strip_meta(other), do: other

  # --- Tier 2: Exact Matching ---

  defp tier2_exact_match(content, target, replacement, allow_multiple) do
    if String.contains?(content, target) do
      new_content =
        if allow_multiple do
          String.replace(content, target, replacement)
        else
          String.replace(content, target, replacement, global: false)
        end

      {:ok, %{content: new_content, tier: :exact}}
    else
      {:error, :not_found}
    end
  end

  # --- Tier 3: Fuzzy Matching & Indentation Alignment ---

  defp tier3_fuzzy_match(content, target, replacement, allow_multiple, anchor_line) do
    content_lines = split_lines(content)
    target_lines = split_lines(target)

    # Remove leading and trailing empty lines from target for matching
    {trimmed_target_lines, _prefix_empty, _suffix_empty} = trim_empty_surrounding(target_lines)

    if trimmed_target_lines == [] do
      {:error, :not_found}
    else
      norm_target = Enum.map(trimmed_target_lines, &normalize_line/1)
      target_len = length(norm_target)
      matches = find_all_window_matches(content_lines, norm_target, target_len)

      case select_matches(matches, allow_multiple, anchor_line) do
        {:ok, selected} ->
          apply_fuzzy_replacement(
            content,
            content_lines,
            trimmed_target_lines,
            target_len,
            selected,
            replacement
          )

        :error ->
          {:error, :not_found}
      end
    end
  end

  # Rejects ambiguous matches: multiple candidates require `allow_multiple`,
  # or a unique closest match relative to `anchor_line` (e.g. a diff hunk's
  # old_start) to be selected.
  defp select_matches([], _allow_multiple, _anchor_line), do: :error

  defp select_matches(matches, allow_multiple, anchor_line) do
    cond do
      length(matches) == 1 or allow_multiple ->
        {:ok, matches}

      anchor_line != nil ->
        disambiguate_by_anchor(matches, anchor_line)

      true ->
        :error
    end
  end

  defp disambiguate_by_anchor(matches, anchor_line) do
    [best | rest] = Enum.sort_by(matches, &abs(&1 - anchor_line))

    case rest do
      [] ->
        {:ok, [best]}

      [next | _] ->
        if abs(best - anchor_line) < abs(next - anchor_line) do
          {:ok, [best]}
        else
          :error
        end
    end
  end

  defp find_all_window_matches(content_lines, norm_target, target_len) do
    if length(content_lines) < target_len do
      []
    else
      Enum.filter(0..(length(content_lines) - target_len), fn idx ->
        content_lines
        |> Enum.slice(idx, target_len)
        |> Enum.map(&normalize_line/1) == norm_target
      end)
    end
  end

  defp apply_fuzzy_replacement(
         content,
         content_lines,
         trimmed_target_lines,
         target_len,
         match_idxs,
         replacement
       ) do
    replacement_lines = split_lines(replacement)
    first_target_line = hd(trimmed_target_lines)
    target_indent = extract_indent(first_target_line)

    # Apply bottom-up so earlier match indices stay valid while splicing.
    new_lines =
      match_idxs
      |> Enum.sort(:desc)
      |> Enum.reduce(content_lines, fn match_idx, acc_lines ->
        file_indent = acc_lines |> Enum.at(match_idx) |> extract_indent()
        reindented = reindent_lines(replacement_lines, file_indent, target_indent)

        before_lines = Enum.take(acc_lines, match_idx)
        after_lines = Enum.drop(acc_lines, match_idx + target_len)

        before_lines ++ reindented ++ after_lines
      end)

    eol = detect_eol(content)
    new_content = Enum.join(new_lines, eol)

    # Preserve trailing newline if original content had it
    final_content =
      if String.ends_with?(content, "\n") and not String.ends_with?(new_content, "\n") do
        new_content <> eol
      else
        new_content
      end

    {:ok, %{content: final_content, tier: :fuzzy}}
  end

  defp reindent_lines(replacement_lines, file_indent, target_indent) do
    Enum.map(replacement_lines, fn line ->
      cond do
        String.trim(line) == "" ->
          ""

        String.starts_with?(line, target_indent) ->
          rel = String.replace_prefix(line, target_indent, "")
          file_indent <> rel

        true ->
          file_indent <> String.trim_leading(line)
      end
    end)
  end

  defp split_lines(text), do: String.split(text, ~r/\r?\n/)

  defp detect_eol(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  defp normalize_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp extract_indent(line) do
    case Regex.run(~r/^[ \t]*/, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  defp trim_empty_surrounding(lines) do
    prefix_empty = Enum.take_while(lines, &(String.trim(&1) == ""))
    after_prefix = Enum.drop_while(lines, &(String.trim(&1) == ""))
    reversed = Enum.reverse(after_prefix)
    suffix_empty = Enum.take_while(reversed, &(String.trim(&1) == ""))
    trimmed = reversed |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()
    {trimmed, length(prefix_empty), length(suffix_empty)}
  end
end
