defmodule IexCode.Tools.Git.DiffParser do
  @moduledoc """
  Pure Elixir parser converting unified diff strings (`git diff`, `patch`) into
  structured `%FileDiff{}` and `%Hunk{}` records.

  Robustly handles:
  - Standard modified files with multiple hunks
  - New files (`--- /dev/null`, `+++ b/file`, `new file mode`)
  - Deleted files (`--- a/file`, `+++ /dev/null`, `deleted file mode`)
  - Renamed files (`similarity index`, `rename from`, `rename to`)
  - Binary files (`Binary files a/... and b/... differ`, `GIT binary patch`)
  - Missing newlines at EOF (`\\ No newline at end of file`)
  - Hunks with omitted line counts (`@@ -1 +1 @@`)
  - Sequential line numbering for deletions, additions, and context lines
  """

  defmodule Line do
    @moduledoc """
    Individual line in a diff hunk.
    """
    @type line_type :: :context | :addition | :deletion | :eof_newline | :header
    @type t :: %__MODULE__{
            type: line_type(),
            content: String.t(),
            old_num: integer() | nil,
            new_num: integer() | nil
          }
    defstruct [:type, :content, :old_num, :new_num]
  end

  defmodule Hunk do
    @moduledoc """
    Structured diff hunk entity with line range boundaries and lines.
    """
    alias IexCode.Tools.Git.DiffParser.Line

    @type status :: :pending | :accepted | :rejected
    @type t :: %__MODULE__{
            id: String.t(),
            file_path: String.t() | nil,
            header: String.t(),
            lines: [Line.t()],
            old_start: integer(),
            old_lines: integer(),
            new_start: integer(),
            new_lines: integer(),
            old_count: integer(),
            new_count: integer(),
            counts_valid?: boolean(),
            crlf?: boolean(),
            status: status()
          }
    defstruct [
      :id,
      :file_path,
      :header,
      :old_start,
      :old_lines,
      :new_start,
      :new_lines,
      old_count: 0,
      new_count: 0,
      # false when the declared @@ header counts do not match the parsed body
      counts_valid?: true,
      # true when the source diff used CRLF line endings (round-trips on regenerate)
      crlf?: false,
      lines: [],
      status: :pending
    ]
  end

  defmodule FileDiff do
    @moduledoc """
    Structured representation of all diff hunks and metadata for a single file.
    """
    alias IexCode.Tools.Git.DiffParser.Hunk

    @type diff_status :: :modified | :added | :deleted | :renamed | :binary | :copied
    @type t :: %__MODULE__{
            path: String.t(),
            old_path: String.t() | nil,
            new_path: String.t() | nil,
            status: diff_status(),
            hunks: [Hunk.t()],
            additions: non_neg_integer(),
            deletions: non_neg_integer(),
            binary?: boolean()
          }
    defstruct [
      :path,
      :old_path,
      :new_path,
      :status,
      hunks: [],
      additions: 0,
      deletions: 0,
      binary?: false
    ]
  end

  alias __MODULE__.{Line, Hunk, FileDiff}

  @hunk_header_regex ~r/^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(?: *(.*))?$/

  @doc """
  Parses a raw unified diff string into a list of `%FileDiff{}` structs.

  Returns `{:ok, [FileDiff.t()]}`, or `{:error, :not_a_unified_diff}` when the
  input is non-blank text that contains no diff-like structure at all (multi-line
  garbage with no `diff`/`@@`/`--- `/`+++ ` marker lines). Truncated or corrupted
  diffs that still contain recognizable markers are parsed leniently; invalid
  hunks are flagged via `Hunk.counts_valid?` rather than crashing the parse.
  """
  @spec parse(String.t() | nil) :: {:ok, [FileDiff.t()]} | {:error, :not_a_unified_diff}
  def parse(nil), do: {:ok, []}

  def parse(raw_diff) when is_binary(raw_diff) do
    cond do
      String.trim(raw_diff) == "" ->
        {:ok, []}

      garbage_input?(raw_diff) ->
        {:error, :not_a_unified_diff}

      true ->
        file_chunks = split_into_file_chunks(raw_diff)
        parsed_files = Enum.map(file_chunks, &parse_file_chunk/1)
        {:ok, tag_crlf(parsed_files, raw_diff)}
    end
  end

  # Multi-line text with no diff marker lines at all is treated as garbage.
  # Short fragments (e.g. truncated diffs) are still parsed leniently.
  defp garbage_input?(raw_diff) do
    lines =
      raw_diff
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))

    length(lines) >= 3 and not Enum.any?(lines, &diff_marker_line?/1)
  end

  defp diff_marker_line?(line) do
    String.starts_with?(line, "diff --git") or String.starts_with?(line, "diff -") or
      String.starts_with?(line, "@@") or String.starts_with?(line, "--- ") or
      String.starts_with?(line, "+++ ") or String.starts_with?(line, "Index: ")
  end

  defp tag_crlf(file_diffs, raw_diff) do
    if String.contains?(raw_diff, "\r\n") do
      Enum.map(file_diffs, fn file_diff ->
        %{file_diff | hunks: Enum.map(file_diff.hunks, &%{&1 | crlf?: true})}
      end)
    else
      file_diffs
    end
  end

  @doc """
  Parses a raw unified diff string, returning the list of `%FileDiff{}` directly.

  Raises `ArgumentError` when `parse/1` returns an error.
  """
  @spec parse!(String.t() | nil) :: [FileDiff.t()]
  def parse!(raw_diff) do
    case parse(raw_diff) do
      {:ok, files} -> files
      {:error, reason} -> raise ArgumentError, "DiffParser.parse!/1 failed: #{inspect(reason)}"
    end
  end

  @doc """
  Finds a specific hunk within a `%FileDiff{}` or a list of `%FileDiff{}` structs.
  Matches by hunk `id` or string/integer index.
  """
  @spec find_hunk([FileDiff.t()] | FileDiff.t(), String.t() | integer()) ::
          {:ok, {FileDiff.t(), Hunk.t()}} | {:error, :hunk_not_found}
  def find_hunk(%FileDiff{} = file_diff, hunk_id) do
    find_hunk([file_diff], hunk_id)
  end

  def find_hunk(file_diffs, hunk_id) when is_list(file_diffs) do
    id_str = to_string(hunk_id)

    result =
      Enum.find_value(file_diffs, fn file_diff ->
        matching_hunk =
          Enum.find(file_diff.hunks, fn hunk ->
            hunk.id == id_str or
              hunk.id == "hunk-#{id_str}" or
              String.ends_with?(hunk.id, "-#{id_str}") or
              hunk.header == id_str
          end) ||
            if is_integer(hunk_id) or Regex.match?(~r/^\d+$/, id_str) do
              idx = if is_integer(hunk_id), do: hunk_id, else: String.to_integer(id_str)

              # Ids are 1-based; guard against idx 0 wrapping to the last hunk
              # via Enum.at(-1). Index 0 is tolerated as the first hunk.
              cond do
                idx >= 1 -> Enum.at(file_diff.hunks, idx - 1) || Enum.at(file_diff.hunks, idx)
                true -> Enum.at(file_diff.hunks, 0)
              end
            end

        if matching_hunk, do: {file_diff, matching_hunk}
      end)

    case result do
      {file_diff, hunk} -> {:ok, {file_diff, hunk}}
      nil -> {:error, :hunk_not_found}
    end
  end

  @doc """
  Generates a standalone unified diff patch string for a single hunk.
  The output can be directly passed to `git apply`, `git apply --cached`, or `git apply --reverse`.
  """
  @spec format_hunk_patch(Hunk.t()) :: String.t()
  @spec format_hunk_patch(FileDiff.t(), Hunk.t()) :: String.t()
  def format_hunk_patch(%Hunk{} = hunk) do
    file_path = hunk.file_path || "file"

    file_diff = %FileDiff{
      path: file_path,
      old_path: file_path,
      new_path: file_path,
      status: :modified
    }

    format_hunk_patch(file_diff, hunk)
  end

  def format_hunk_patch(%FileDiff{} = file_diff, %Hunk{} = hunk) do
    old_path = file_diff.old_path || file_diff.path || hunk.file_path || "a"
    new_path = file_diff.new_path || file_diff.path || hunk.file_path || "b"
    eol = if hunk.crlf?, do: "\r\n", else: "\n"

    header_lines =
      cond do
        file_diff.status == :added or is_nil(file_diff.old_path) ->
          [
            "diff --git a/#{new_path} b/#{new_path}",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/#{new_path}"
          ]

        file_diff.status == :deleted or is_nil(file_diff.new_path) ->
          [
            "diff --git a/#{old_path} b/#{old_path}",
            "deleted file mode 100644",
            "--- a/#{old_path}",
            "+++ /dev/null"
          ]

        file_diff.status == :renamed and old_path != new_path ->
          [
            "diff --git a/#{old_path} b/#{new_path}",
            "rename from #{old_path}",
            "rename to #{new_path}",
            "--- a/#{old_path}",
            "+++ b/#{new_path}"
          ]

        true ->
          [
            "diff --git a/#{old_path} b/#{new_path}",
            "--- a/#{old_path}",
            "+++ b/#{new_path}"
          ]
      end

    hunk_header =
      "@@ -#{hunk.old_start},#{hunk.old_lines} +#{hunk.new_start},#{hunk.new_lines} @@"

    body_lines =
      Enum.map(hunk.lines, fn line ->
        case line.type do
          :addition -> "+#{line.content}"
          :deletion -> "-#{line.content}"
          :context -> " #{line.content}"
          :eof_newline -> line.content
          _ -> " #{line.content}"
        end
      end)

    (header_lines ++ [hunk_header | body_lines])
    |> Enum.join(eol)
    |> Kernel.<>(eol)
  end

  @doc """
  Calculates aggregate summary metrics from a list of `%FileDiff{}` structs.
  """
  @spec summary([FileDiff.t()]) :: %{
          files_count: non_neg_integer(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks_count: non_neg_integer()
        }
  def summary(file_diffs) when is_list(file_diffs) do
    files_count = length(file_diffs)

    additions =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + f.additions end)

    deletions =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + f.deletions end)

    hunks_count =
      Enum.reduce(file_diffs, 0, fn f, acc -> acc + length(f.hunks) end)

    %{
      files_count: files_count,
      additions: additions,
      deletions: deletions,
      hunks_count: hunks_count
    }
  end

  # --- Internal Parsing Logic ---

  defp split_into_file_chunks(raw_diff) do
    lines = String.split(raw_diff, ~r/\r?\n/)

    {chunks, current_chunk} =
      Enum.reduce(lines, {[], []}, fn line, {acc_chunks, current_lines} ->
        if is_file_boundary?(line, current_lines) do
          {[Enum.reverse(current_lines) | acc_chunks], [line]}
        else
          {acc_chunks, [line | current_lines]}
        end
      end)

    all_chunks =
      if current_chunk != [] do
        [Enum.reverse(current_chunk) | chunks]
      else
        chunks
      end
      |> Enum.reverse()
      |> Enum.reject(&(&1 == [] or Enum.all?(&1, fn l -> String.trim(l) == "" end)))

    all_chunks
  end

  defp is_file_boundary?(line, current_lines) do
    cond do
      current_lines == [] ->
        false

      String.starts_with?(line, "diff --git ") ->
        true

      # A "--- " line only starts a new file before any hunk header was seen;
      # inside a hunk body it is a deletion of content like "-- foo".
      String.starts_with?(line, "--- ") and
        not Enum.any?(current_lines, &String.starts_with?(&1, "diff --git ")) and
        Enum.any?(current_lines, &String.starts_with?(&1, "+++ ")) and
          not Enum.any?(current_lines, &String.starts_with?(&1, "@@")) ->
        true

      true ->
        false
    end
  end

  defp parse_file_chunk(lines) do
    {header_lines, hunk_lines} =
      Enum.split_while(lines, fn line ->
        not String.starts_with?(line, "@@")
      end)

    file_diff = parse_file_headers(header_lines)
    hunks = parse_hunks(hunk_lines, file_diff.path)

    additions =
      Enum.reduce(hunks, 0, fn hunk, acc ->
        acc + Enum.count(hunk.lines, &(&1.type == :addition))
      end)

    deletions =
      Enum.reduce(hunks, 0, fn hunk, acc ->
        acc + Enum.count(hunk.lines, &(&1.type == :deletion))
      end)

    status =
      cond do
        file_diff.binary? ->
          :binary

        file_diff.status != nil ->
          file_diff.status

        file_diff.old_path == nil and file_diff.new_path != nil ->
          :added

        file_diff.old_path != nil and file_diff.new_path == nil ->
          :deleted

        file_diff.old_path != nil and file_diff.new_path != nil and
            file_diff.old_path != file_diff.new_path ->
          :renamed

        true ->
          :modified
      end

    resolved_path = file_diff.new_path || file_diff.old_path || file_diff.path || "unknown"
    old_path = if status == :added, do: nil, else: file_diff.old_path || resolved_path
    new_path = if status == :deleted, do: nil, else: file_diff.new_path || resolved_path
    primary_path = if status == :deleted, do: old_path, else: new_path || resolved_path

    %{
      file_diff
      | path: primary_path,
        old_path: old_path,
        new_path: new_path,
        hunks: hunks,
        additions: additions,
        deletions: deletions,
        status: status
    }
  end

  defp parse_file_headers(header_lines) do
    Enum.reduce(header_lines, %FileDiff{status: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "diff --git ") ->
          {old_p, new_p} = parse_diff_git_paths(line)
          %{acc | old_path: old_p, new_path: new_p, path: new_p || old_p}

        String.starts_with?(line, "--- ") ->
          path = parse_header_path(line, "--- ")
          old_p = if path == "/dev/null", do: nil, else: path
          new_status = if path == "/dev/null", do: :added, else: acc.status
          %{acc | old_path: old_p, status: new_status}

        String.starts_with?(line, "+++ ") ->
          path = parse_header_path(line, "+++ ")
          new_p = if path == "/dev/null", do: nil, else: path
          new_status = if path == "/dev/null", do: :deleted, else: acc.status
          %{acc | new_path: new_p, path: new_p || acc.path, status: new_status}

        String.starts_with?(line, "new file mode") ->
          %{acc | status: :added}

        String.starts_with?(line, "deleted file mode") ->
          %{acc | status: :deleted}

        String.starts_with?(line, "similarity index ") ->
          %{acc | status: :renamed}

        String.starts_with?(line, "rename from ") ->
          old_p = clean_rename_path(String.replace_prefix(line, "rename from ", ""))
          %{acc | old_path: old_p, status: :renamed}

        String.starts_with?(line, "rename to ") ->
          new_p = clean_rename_path(String.replace_prefix(line, "rename to ", ""))
          %{acc | new_path: new_p, path: new_p, status: :renamed}

        String.starts_with?(line, "Binary files ") or String.contains?(line, "GIT binary patch") ->
          %{acc | binary?: true, status: :binary}

        true ->
          acc
      end
    end)
  end

  defp parse_diff_git_paths(line) do
    rest = String.replace_prefix(line, "diff --git ", "")

    case Regex.run(~r/^(?:"a\/(.*?)"|a\/(.*?))\s+(?:"b\/(.*?)"|b\/(.*?))$/, rest) do
      [_, q1, u1, q2, u2] ->
        old_p = if q1 != "", do: q1, else: u1
        new_p = if q2 != "", do: q2, else: u2

        # The regex already consumed the a/ b/ prefix — only trim the capture,
        # otherwise a real top-level dir (e.g. `a/b/build/out`) gets mangled.
        {clean_rename_path(old_p), clean_rename_path(new_p)}

      _ ->
        case String.split(rest, " ") do
          [a, b] -> {clean_path(a), clean_path(b)}
          _ -> {nil, nil}
        end
    end
  end

  defp parse_header_path(line, prefix) do
    raw = String.replace_prefix(line, prefix, "") |> String.trim()
    path_part = raw |> String.split("\t") |> List.first() |> String.trim()
    clean_path(path_part)
  end

  defp clean_path(nil), do: nil
  defp clean_path(""), do: nil
  defp clean_path("/dev/null"), do: "/dev/null"

  # Strips exactly one git diff prefix (`a/` or `b/`) so real top-level
  # directories named `a` or `b` deeper in the path are preserved.
  defp clean_path(path) do
    path
    |> String.trim("\"")
    |> strip_diff_prefix()
  end

  defp strip_diff_prefix("a/" <> rest), do: rest
  defp strip_diff_prefix("b/" <> rest), do: rest
  defp strip_diff_prefix(path), do: path

  # `rename from`/`rename to` paths carry no a/ b/ prefix — only unquote them,
  # so genuine top-level directories named `a` or `b` are not mangled.
  defp clean_rename_path(path) do
    path
    |> String.trim("\"")
    |> String.trim()
  end

  defp parse_hunks(lines, file_path) do
    {hunk_chunks, current_hunk} =
      Enum.reduce(lines, {[], []}, fn line, {acc_chunks, current_lines} ->
        if String.starts_with?(line, "@@") and current_lines != [] do
          {[Enum.reverse(current_lines) | acc_chunks], [line]}
        else
          {acc_chunks, [line | current_lines]}
        end
      end)

    all_hunk_chunks =
      if current_hunk != [] do
        [Enum.reverse(current_hunk) | hunk_chunks]
      else
        hunk_chunks
      end
      |> Enum.reverse()

    all_hunk_chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {hunk_lines, index} ->
      parse_single_hunk(hunk_lines, file_path, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_hunk([], _file_path, _index), do: nil

  defp parse_single_hunk([header_line | body_lines], file_path, index) do
    case Regex.run(@hunk_header_regex, header_line) do
      [_, os_str, ol_str, ns_str, nl_str | _] ->
        old_start = String.to_integer(os_str)
        old_lines = parse_count(ol_str)
        new_start = String.to_integer(ns_str)
        new_lines = parse_count(nl_str)

        hunk_id = "hunk-#{index}"

        {lines, actual_old, actual_new} =
          body_lines
          |> reject_trailing_empty()
          |> take_hunk_body()
          |> Enum.reduce({[], old_start, new_start}, fn line, {acc_lines, cur_old, cur_new} ->
            case line do
              "+" <> content ->
                line_struct = %Line{
                  type: :addition,
                  content: content,
                  old_num: nil,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old, cur_new + 1}

              "-" <> content ->
                line_struct = %Line{
                  type: :deletion,
                  content: content,
                  old_num: cur_old,
                  new_num: nil
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new}

              " " <> content ->
                line_struct = %Line{
                  type: :context,
                  content: content,
                  old_num: cur_old,
                  new_num: cur_new
                }

                {[line_struct | acc_lines], cur_old + 1, cur_new + 1}

              "\\ No newline" <> _ = marker ->
                line_struct = %Line{
                  type: :eof_newline,
                  content: marker,
                  old_num: nil,
                  new_num: nil
                }

                {[line_struct | acc_lines], cur_old, cur_new}
            end
          end)

        # Validate declared header counts against the parsed body so corrupted
        # hunks are flagged instead of silently accepted.
        counts_valid? = actual_old == old_lines and actual_new == new_lines

        %Hunk{
          id: hunk_id,
          file_path: file_path,
          header: header_line,
          old_start: old_start,
          old_lines: old_lines,
          new_start: new_start,
          new_lines: new_lines,
          old_count: old_lines,
          new_count: new_lines,
          counts_valid?: counts_valid?,
          lines: Enum.reverse(lines),
          status: :pending
        }

      _ ->
        nil
    end
  end

  defp parse_count(""), do: 1
  defp parse_count(count_str), do: String.to_integer(count_str)

  # Only well-formed hunk body lines are consumed. Blank/garbage lines and the
  # email-signature delimiter ("-- ") terminate the body so trailing garbage
  # (e.g. `git format-patch` signatures) never becomes :context content.
  defp take_hunk_body(lines) do
    Enum.take_while(lines, fn line ->
      not signature_delimiter?(line) and valid_body_line?(line)
    end)
  end

  defp signature_delimiter?(line), do: String.trim(line) == "--"

  defp valid_body_line?(line) do
    case line do
      "" -> false
      "+" <> _ -> true
      "-" <> _ -> true
      " " <> _ -> true
      "\\ No newline" <> _ -> true
      _ -> false
    end
  end

  defp reject_trailing_empty(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end
end
