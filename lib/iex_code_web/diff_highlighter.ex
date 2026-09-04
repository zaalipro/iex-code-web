defmodule IexCodeWeb.DiffHighlighter do
  @moduledoc """
  Intra-line word-level change highlighting, syntax coloration, and split-row alignment engine.

  Uses Elixir standard library Myers difference algorithms (`List.myers_difference/2`
  on token streams and `String.myers_difference/2` for character diffs) to compute
  clean, semantic word-level diffs preserving whitespace and punctuation.
  """

  use Phoenix.Component

  @max_line_bytes 2_000
  @default_similarity_threshold 0.25
  @token_regex ~r/\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/u

  @syntax_regex ~r"
    (?<comment>\#(?!\{).*$|\/\/.*$)
    | (?<string>\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*')
    | (?<atom>:[a-zA-Z_][a-zA-Z0-9_@]*[?!]?|[a-zA-Z_][a-zA-Z0-9_]*:(?!\:))
    | (?<keyword>\b(?:def|defp|defmodule|defmacro|defmacrop|defstruct|defimpl|defprotocol|use|import|alias|require|do|end|case|cond|if|else|unless|with|for|fn|receive|try|catch|rescue|after|raise|throw|quote|unquote|when|true|false|nil|and|or|not|in|return|const|let|var|function|class|async|await)\b)
    | (?<module>\b[A-Z][a-zA-Z0-9_]*\b)
    | (?<number>\b\d+(?:_\d+)*(?:\.\d+)?\b|0x[0-9a-fA-F]+)
    | (?<operator>\|>|->|=>|::|===|!==|==|!=|<=|>=|\+\+|--|[=+\-*\/&%^~<>!])
    | (?<text>[a-z_][a-zA-Z0-9_]*[?!]?|\s+|.)
  "ux

  @type diff_tag :: :eq | :del | :ins
  @type diff_segment :: {diff_tag(), String.t()}
  @type segment_kind :: :normal | :highlight
  @type line_segment :: {segment_kind(), String.t()}

  # ----------------------------------------------------------------------------
  # Public API: Word & Character Diffing
  # ----------------------------------------------------------------------------

  @doc """
  Computes word-level differences between `old_text` and `new_text`.
  Returns a list of `{tag, string}` chunks where `tag` is `:eq`, `:del`, or `:ins`.

  Guarantees:
  - Lossless reconstitution: `eq + del == old_text` and `eq + ins == new_text`.
  - Whitespace and punctuation preservation.
  - Automatic fallback to full line diff when lines are completely different or exceed `@max_line_bytes`.
  """
  @spec word_diff(String.t() | nil, String.t() | nil, keyword()) :: [diff_segment()]
  def word_diff(old_text, new_text, opts \\ [])

  def word_diff(nil, nil, _opts), do: []
  def word_diff(nil, new_text, _opts) when is_binary(new_text), do: [{:ins, new_text}]
  def word_diff(old_text, nil, _opts) when is_binary(old_text), do: [{:del, old_text}]

  def word_diff(text, text, _opts) when is_binary(text) do
    if text == "", do: [], else: [{:eq, text}]
  end

  def word_diff("", new_text, _opts) when is_binary(new_text), do: [{:ins, new_text}]
  def word_diff(old_text, "", _opts) when is_binary(old_text), do: [{:del, old_text}]

  def word_diff(old_text, new_text, opts) when is_binary(old_text) and is_binary(new_text) do
    if byte_size(old_text) > @max_line_bytes or byte_size(new_text) > @max_line_bytes do
      [{:del, old_text}, {:ins, new_text}]
    else
      t1 = split_tokens(old_text)
      t2 = split_tokens(new_text)

      raw_diff = List.myers_difference(t1, t2)
      collapsed = collapse_diff(raw_diff)

      threshold = Keyword.get(opts, :similarity_threshold, @default_similarity_threshold)

      if similar?(collapsed, old_text, new_text, threshold) do
        collapsed
      else
        [{:del, old_text}, {:ins, new_text}]
      end
    end
  end

  @doc """
  Computes character-level differences using Elixir's `String.myers_difference/2`.
  Useful when character-level precision is explicitly requested.
  """
  @spec char_diff(String.t() | nil, String.t() | nil) :: [diff_segment()]
  def char_diff(nil, nil), do: []
  def char_diff(nil, new_text) when is_binary(new_text), do: [{:ins, new_text}]
  def char_diff(old_text, nil) when is_binary(old_text), do: [{:del, old_text}]

  def char_diff(text, text) when is_binary(text) do
    if text == "", do: [], else: [{:eq, text}]
  end

  def char_diff(old_text, new_text) when is_binary(old_text) and is_binary(new_text) do
    if byte_size(old_text) > @max_line_bytes or byte_size(new_text) > @max_line_bytes do
      [{:del, old_text}, {:ins, new_text}]
    else
      String.myers_difference(old_text, new_text)
    end
  end

  # ----------------------------------------------------------------------------
  # Tokenization
  # ----------------------------------------------------------------------------

  @doc """
  Tokenizes a text line into words, whitespace chunks, and single punctuation marks.
  Guarantees `Enum.join(split_tokens(text)) == text`.
  """
  @spec split_tokens(String.t() | nil) :: [String.t()]
  def split_tokens(nil), do: []
  def split_tokens(""), do: []

  def split_tokens(text) when is_binary(text) do
    Regex.scan(@token_regex, text) |> List.flatten()
  end

  @doc """
  Syntax token classifier for code strings. Categorizes tokens into keywords,
  strings, atoms, comments, numbers, modules, operators, and text.
  Also supports `:words` mode to return word token strings.
  """
  @spec tokenize(String.t() | nil, :syntax | :words) :: [{atom(), String.t()}] | [String.t()]
  def tokenize(text, mode \\ :syntax)
  def tokenize(nil, _mode), do: []
  def tokenize("", _mode), do: []

  def tokenize(text, :words) when is_binary(text) do
    split_tokens(text)
  end

  def tokenize(code, :syntax) when is_binary(code) do
    Regex.scan(@syntax_regex, code, capture: :all_names)
    |> Enum.map(fn [atom_val, comment, keyword, module_val, number, operator, string, text] ->
      cond do
        comment != "" -> {:comment, comment}
        string != "" -> {:string, string}
        atom_val != "" -> {:atom, atom_val}
        keyword != "" -> {:keyword, keyword}
        module_val != "" -> {:module, module_val}
        number != "" -> {:number, number}
        operator != "" -> {:operator, operator}
        text != "" -> {:text, text}
        true -> {:text, ""}
      end
    end)
    |> Enum.reject(fn {_, text} -> text == "" end)
  end

  # ----------------------------------------------------------------------------
  # Line Segments & Row Pairing
  # ----------------------------------------------------------------------------

  @doc """
  Converts a `word_diff` result into styled line segments for rendering a specific line type:
  - `:deletion`: `:eq` -> `:normal`, `:del` -> `:highlight`, `:ins` omitted.
  - `:addition`: `:eq` -> `:normal`, `:ins` -> `:highlight`, `:del` omitted.
  - `:context` (or other): all text -> `:normal`.
  """
  @spec line_segments([diff_segment()], :deletion | :addition | :context | atom()) :: [
          line_segment()
        ]
  def line_segments(diff, type) when is_list(diff) do
    case type do
      :deletion ->
        diff
        |> Enum.filter(fn {tag, _} -> tag in [:eq, :del] end)
        |> Enum.map(fn
          {:eq, text} -> {:normal, text}
          {:del, text} -> {:highlight, text}
        end)
        |> collapse_segments()

      :addition ->
        diff
        |> Enum.filter(fn {tag, _} -> tag in [:eq, :ins] end)
        |> Enum.map(fn
          {:eq, text} -> {:normal, text}
          {:ins, text} -> {:highlight, text}
        end)
        |> collapse_segments()

      _ ->
        text = Enum.map_join(diff, fn {_, t} -> t end)
        if text == "", do: [], else: [{:normal, text}]
    end
  end

  @doc """
  Pairs lines in a hunk for split (side-by-side) diff viewing.
  Groups contiguous deletions and additions, pairs them 1-to-1, and inserts `spacer`
  (default `nil`) to guarantee identical row counts on both sides without vertical drift.
  """
  @spec pair_split_lines([map()] | nil, term()) :: [{map() | term(), map() | term()}]
  def pair_split_lines(lines, spacer \\ nil)
  def pair_split_lines(nil, _spacer), do: []
  def pair_split_lines([], _spacer), do: []

  def pair_split_lines(lines, spacer) when is_list(lines) do
    lines
    |> chunk_diff_lines()
    |> Enum.flat_map(&pair_chunk(&1, spacer))
  end

  @doc """
  Alternative entry point for pairing hunk lines, defaulting spacer to `:empty`.
  """
  @spec pair_hunk_lines([map()] | nil, term()) :: [{map() | term(), map() | term()}]
  def pair_hunk_lines(lines, spacer \\ :empty) do
    pair_split_lines(lines, spacer)
  end

  @doc """
  Pre-computes intra-line word diff segments for inline unified diff views.
  Pairs consecutive deletion and addition groups to highlight changed tokens.
  """
  @spec prepare_inline_lines([map()] | nil) :: [map()]
  def prepare_inline_lines(nil), do: []
  def prepare_inline_lines([]), do: []

  def prepare_inline_lines(lines) when is_list(lines) do
    lines
    |> chunk_diff_lines()
    |> Enum.flat_map(fn
      {:context, line} ->
        [%{line: line, segments: [{:normal, line.content || ""}]}]

      {:changes, change_lines} ->
        dels = Enum.filter(change_lines, &(&1.type == :deletion))
        adds = Enum.filter(change_lines, &(&1.type == :addition))

        paired_map =
          Enum.zip(dels, adds)
          |> Enum.reduce(%{}, fn {del, add}, acc ->
            c1 = del.content || ""
            c2 = add.content || ""
            diff = word_diff(c1, c2)
            del_segs = line_segments(diff, :deletion)
            add_segs = line_segments(diff, :addition)

            acc
            |> Map.put({:del, del}, del_segs)
            |> Map.put({:add, add}, add_segs)
          end)

        Enum.map(change_lines, fn line ->
          segments =
            case line.type do
              :deletion ->
                Map.get(paired_map, {:del, line}, [{:highlight, line.content || ""}])

              :addition ->
                Map.get(paired_map, {:add, line}, [{:highlight, line.content || ""}])

              _ ->
                [{:normal, line.content || ""}]
            end

          %{line: line, segments: segments}
        end)
    end)
  end

  # ----------------------------------------------------------------------------
  # HEEx Components
  # ----------------------------------------------------------------------------

  @doc """
  Renders line content with intra-line word diff chips and syntax token styling.
  """
  attr :segments, :list, required: true
  attr :type, :any, required: true

  def diff_line_content(assigns) do
    ~H"""
    <span class="whitespace-pre-wrap font-mono select-text">
      <%= for {kind, text} <- @segments do %>
        <%= case {@type, kind} do %>
          <% {:deletion, :highlight} -> %>
            <span class="bg-rose-500/30 text-rose-200 font-semibold rounded px-0.5">{text}</span>
          <% {:deletion, :normal} -> %>
            <span class="text-rose-300/90"><.syntax_tokens text={text} /></span>
          <% {:addition, :highlight} -> %>
            <span class="bg-emerald-500/30 text-emerald-200 font-semibold rounded px-0.5">{text}</span>
          <% {:addition, :normal} -> %>
            <span class="text-emerald-300/90"><.syntax_tokens text={text} /></span>
          <% {_, :highlight} -> %>
            <span class="bg-amber-500/30 text-amber-200 font-semibold rounded px-0.5">{text}</span>
          <% {_, _} -> %>
            <span class="text-gray-300"><.syntax_tokens text={text} /></span>
        <% end %>
      <% end %>
    </span>
    """
  end

  @doc """
  Renders syntax highlighted tokens for code snippets.
  """
  attr :text, :string, required: true

  def syntax_tokens(assigns) do
    tokens = tokenize(assigns.text, :syntax)
    assigns = assign(assigns, :tokens, tokens)

    ~H"""
    <%= for {type, text} <- @tokens do %>
      <span class={token_class(type)}>{text}</span>
    <% end %>
    """
  end

  defp token_class(:comment), do: "text-zinc-500 italic"
  defp token_class(:string), do: "text-emerald-400"
  defp token_class(:atom), do: "text-cyan-400"
  defp token_class(:keyword), do: "text-purple-400 font-semibold"
  defp token_class(:module), do: "text-amber-300 font-medium"
  defp token_class(:number), do: "text-amber-400"
  defp token_class(:operator), do: "text-rose-400/90"
  defp token_class(:text), do: ""
  defp token_class(_), do: ""

  # ----------------------------------------------------------------------------
  # Private Helpers
  # ----------------------------------------------------------------------------

  defp chunk_diff_lines(lines), do: do_chunk_diff_lines(lines, [], [])

  defp do_chunk_diff_lines([], [], acc), do: Enum.reverse(acc)

  defp do_chunk_diff_lines([], cur_changes, acc) do
    Enum.reverse([{:changes, Enum.reverse(cur_changes)} | acc])
  end

  defp do_chunk_diff_lines([line | rest], cur_changes, acc) do
    type = Map.get(line, :type)

    if type == :context do
      if cur_changes == [] do
        do_chunk_diff_lines(rest, [], [{:context, line} | acc])
      else
        change_chunk = {:changes, Enum.reverse(cur_changes)}
        do_chunk_diff_lines(rest, [], [{:context, line}, change_chunk | acc])
      end
    else
      do_chunk_diff_lines(rest, [line | cur_changes], acc)
    end
  end

  defp pair_chunk({:context, line}, _spacer), do: [{line, line}]

  defp pair_chunk({:changes, change_lines}, spacer) do
    {deletions, additions, _} =
      Enum.reduce(change_lines, {[], [], nil}, fn line, {dels, adds, last_type} ->
        case Map.get(line, :type) do
          :deletion ->
            {[line | dels], adds, :deletion}

          :addition ->
            {dels, [line | adds], :addition}

          :eof_newline ->
            if last_type == :addition do
              {dels, [line | adds], :addition}
            else
              {[line | dels], adds, :deletion}
            end

          _ ->
            {[line | dels], adds, last_type}
        end
      end)

    dels = Enum.reverse(deletions)
    adds = Enum.reverse(additions)

    del_count = length(dels)
    add_count = length(adds)
    max_count = max(del_count, add_count)

    padded_dels = dels ++ List.duplicate(spacer, max_count - del_count)
    padded_adds = adds ++ List.duplicate(spacer, max_count - add_count)

    Enum.zip(padded_dels, padded_adds)
  end

  defp collapse_diff([]), do: []

  defp collapse_diff(diff) do
    diff
    |> Enum.map(fn {tag, tokens} -> {tag, Enum.join(tokens)} end)
    |> collapse_consecutive_tags()
  end

  defp collapse_consecutive_tags([]), do: []

  defp collapse_consecutive_tags([{tag, text} | rest]) do
    Enum.reduce(rest, [{tag, text}], fn
      {t, next_text}, [{t, prev_text} | acc_rest] ->
        [{t, prev_text <> next_text} | acc_rest]

      {next_tag, next_text}, acc ->
        [{next_tag, next_text} | acc]
    end)
    |> Enum.reverse()
  end

  defp collapse_segments([]), do: []

  defp collapse_segments([{tag, text} | rest]) do
    Enum.reduce(rest, [{tag, text}], fn
      {t, next_text}, [{t, prev_text} | acc_rest] ->
        [{t, prev_text <> next_text} | acc_rest]

      {next_tag, next_text}, acc ->
        [{next_tag, next_text} | acc]
    end)
    |> Enum.reverse()
  end

  defp similar?(diff, old_text, new_text, threshold) do
    eq_chars =
      diff
      |> Enum.filter(fn {tag, _} -> tag == :eq end)
      |> Enum.map_join(fn {_, s} -> s end)
      |> String.replace(~r/\s+/, "")
      |> String.length()

    clean_old = String.replace(old_text, ~r/\s+/, "")
    clean_new = String.replace(new_text, ~r/\s+/, "")
    total_chars = max(String.length(clean_old), String.length(clean_new))

    if total_chars == 0 do
      true
    else
      eq_chars / total_chars >= threshold
    end
  end
end
