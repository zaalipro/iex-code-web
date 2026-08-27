defmodule IexCode.Tools.BoundedFiles do
  @moduledoc false

  @read_chunk_bytes 64 * 1_024
  @read_max_lines 800
  @read_max_bytes 1 * 1_024 * 1_024
  @read_max_scan_bytes 32 * 1_024 * 1_024
  @list_max_entries 200
  @grep_max_files 500
  @grep_max_matches 100
  @grep_matches_per_file 10
  @grep_max_line_bytes 256 * 1_024
  @grep_match_preview_bytes 8 * 1_024
  @grep_max_result_bytes 1 * 1_024 * 1_024
  @grep_max_scanned_bytes 32 * 1_024 * 1_024
  @max_walk_depth 128

  @excluded_dirs MapSet.new(["_build", "deps", "node_modules", ".git"])
  @excluded_extensions MapSet.new([
                         ".db",
                         ".db-wal",
                         ".db-shm",
                         ".beam",
                         ".png",
                         ".jpg",
                         ".jpeg",
                         ".ico",
                         ".svg",
                         ".lock",
                         ".dump",
                         ".gz",
                         ".zip"
                       ])

  @spec read_range(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_range(path, opts \\ []) do
    with {:ok, start_line, requested_end, scan_offset, scan_start_line} <-
           normalize_line_range(opts),
         {:ok, io} <- File.open(path, [:read, :binary]),
         {:ok, _position} <- :file.position(io, scan_offset) do
      effective_end =
        min(
          requested_end || start_line + @read_max_lines - 1,
          start_line + @read_max_lines - 1
        )

      state = %{
        start_line: start_line,
        requested_end: requested_end,
        effective_end: effective_end,
        line_number: scan_start_line,
        partial: <<>>,
        lines: [],
        content_bytes: 0,
        scan_offset: scan_offset,
        scanned_bytes: 0,
        scan_limited?: false,
        halted?: false,
        truncated?: false,
        byte_truncated?: false
      }

      try do
        with {:ok, final_state} <- read_chunks(io, state) do
          lines = Enum.reverse(final_state.lines)

          {:ok,
           %{
             content: format_numbered_lines(lines),
             lines_read: length(lines),
             first_line: first_line_number(lines),
             last_line: last_line_number(lines),
             next_line: next_line(final_state, lines),
             truncated?: final_state.truncated?,
             byte_truncated?: final_state.byte_truncated?,
             scan_limited?: final_state.scan_limited?,
             next_scan_offset: next_scan_offset(final_state),
             next_scan_start_line: next_scan_start_line(final_state),
             byte_limit: @read_max_bytes,
             scan_limit: @read_max_scan_bytes,
             line_limit: @read_max_lines
           }}
        end
      after
        File.close(io)
      end
    end
  end

  @spec list(Path.t(), keyword()) :: {:ok, map()}
  def list(path, opts \\ []) do
    recursive? = Keyword.get(opts, :recursive, false)
    offset = normalize_offset(Keyword.get(opts, :offset, 0))
    requested_limit = normalize_limit(Keyword.get(opts, :limit), @list_max_entries)
    take = min(requested_limit, @list_max_entries)

    initial = %{
      skipped: 0,
      offset: offset,
      take: take,
      entries: [],
      count: 0,
      extra?: false,
      depth_limited?: false,
      stop?: false
    }

    state = walk(path, "", recursive?, 0, initial, &collect_entry/3)
    entries = Enum.reverse(state.entries)
    truncated? = state.extra? or state.depth_limited?

    {:ok,
     %{
       entries: entries,
       truncated?: truncated?,
       next_offset: if(truncated?, do: offset + length(entries), else: nil),
       limit: take,
       depth_limited?: state.depth_limited?
     }}
  end

  @spec grep(Path.t(), Path.t(), String.t(), keyword()) :: {:ok, map()}
  def grep(search_path, workspace_root, query, opts \\ []) do
    case_sensitive? = Keyword.get(opts, :case_sensitive, false)
    file_offset = normalize_offset(Keyword.get(opts, :offset, 0))
    matcher = build_matcher(query, case_sensitive?)

    initial = %{
      workspace_root: workspace_root,
      matcher: matcher,
      case_sensitive?: case_sensitive?,
      file_offset: file_offset,
      eligible_files: 0,
      scanned_files: 0,
      scanned_bytes: 0,
      matches: [],
      match_count: 0,
      result_bytes: 0,
      truncated?: false,
      depth_limited?: false,
      next_offset: nil,
      stop?: false
    }

    relative = Path.relative_to(search_path, workspace_root)
    relative = if relative == ".", do: "", else: relative

    state =
      if File.regular?(search_path) do
        case File.lstat(search_path) do
          {:ok, stat} -> grep_entry({search_path, relative, :file, stat}, initial, 0)
          {:error, _reason} -> initial
        end
      else
        walk(search_path, relative, true, 0, initial, &grep_entry/3)
      end

    {:ok,
     %{
       matches: Enum.reverse(state.matches),
       truncated?: state.truncated? or state.depth_limited?,
       next_offset: state.next_offset,
       scanned_files: state.scanned_files,
       scanned_bytes: state.scanned_bytes,
       depth_limited?: state.depth_limited?
     }}
  end

  defp normalize_line_range(opts) do
    start_line = Keyword.get(opts, :start_line) || 1
    end_line = Keyword.get(opts, :end_line)
    scan_offset = Keyword.get(opts, :scan_offset) || 0
    scan_start_line = Keyword.get(opts, :scan_start_line) || 1

    cond do
      not (is_integer(start_line) and start_line >= 1) ->
        {:error, :invalid_line_range}

      not (is_nil(end_line) or (is_integer(end_line) and end_line >= start_line)) ->
        {:error, :invalid_line_range}

      not (is_integer(scan_offset) and scan_offset >= 0) ->
        {:error, :invalid_line_range}

      not (is_integer(scan_start_line) and scan_start_line >= 1 and
               scan_start_line <= start_line) ->
        {:error, :invalid_line_range}

      true ->
        {:ok, start_line, end_line, scan_offset, scan_start_line}
    end
  end

  defp read_chunks(_io, %{halted?: true} = state), do: {:ok, state}

  defp read_chunks(
         _io,
         %{scanned_bytes: bytes, line_number: line_number, start_line: start_line} = state
       )
       when bytes >= @read_max_scan_bytes and line_number < start_line do
    {:ok, %{state | scan_limited?: true, truncated?: true}}
  end

  defp read_chunks(io, state) do
    case IO.binread(io, @read_chunk_bytes) do
      :eof ->
        {:ok, finish_read(state)}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        state = %{state | scanned_bytes: state.scanned_bytes + byte_size(chunk)}

        case consume_read_chunk(chunk, state) do
          %{halted?: true} = halted -> {:ok, halted}
          next_state -> read_chunks(io, next_state)
        end
    end
  end

  defp consume_read_chunk(<<>>, state), do: state

  defp consume_read_chunk(chunk, state) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        append_read_segment(state, chunk)

      {index, 1} ->
        segment = binary_part(chunk, 0, index)
        rest_size = byte_size(chunk) - index - 1
        rest = binary_part(chunk, index + 1, rest_size)

        state = append_read_segment(state, segment)

        if state.halted? do
          state
        else
          state
          |> finish_read_line()
          |> then(fn next_state ->
            if next_state.halted?, do: next_state, else: consume_read_chunk(rest, next_state)
          end)
        end
    end
  end

  defp append_read_segment(%{line_number: number, start_line: start} = state, _segment)
       when number < start,
       do: state

  defp append_read_segment(%{line_number: number, effective_end: last} = state, _segment)
       when number > last,
       do: %{state | halted?: true, truncated?: continuation_expected?(state)}

  defp append_read_segment(state, segment) do
    remaining = @read_max_bytes - state.content_bytes - byte_size(state.partial)

    cond do
      byte_size(segment) <= remaining ->
        %{state | partial: state.partial <> segment}

      true ->
        prefix = if remaining > 0, do: binary_part(segment, 0, remaining), else: <<>>
        partial = state.partial <> prefix

        state
        |> put_read_line(partial)
        |> Map.merge(%{halted?: true, truncated?: true, byte_truncated?: true, partial: <<>>})
    end
  end

  defp finish_read_line(%{line_number: number, start_line: start} = state) when number < start do
    %{state | line_number: number + 1, partial: <<>>}
  end

  defp finish_read_line(state) do
    state = put_read_line(state, trim_carriage_return(state.partial))

    if state.line_number >= state.effective_end do
      %{
        state
        | halted?: true,
          truncated?: continuation_expected?(state),
          partial: <<>>
      }
    else
      %{state | line_number: state.line_number + 1, partial: <<>>}
    end
  end

  # String.split/2 historically represented an empty file and the content after
  # a final newline as an empty logical line, so finalize the current line at EOF.
  defp finish_read(state) do
    cond do
      state.halted? ->
        state

      state.line_number < state.start_line ->
        state

      state.line_number > state.effective_end ->
        state

      true ->
        put_read_line(state, trim_carriage_return(state.partial))
    end
  end

  defp put_read_line(state, line) do
    %{
      state
      | lines: [{state.line_number, line} | state.lines],
        content_bytes: state.content_bytes + byte_size(line)
    }
  end

  defp continuation_expected?(%{requested_end: nil}), do: true

  defp continuation_expected?(state),
    do: state.requested_end > state.effective_end

  defp trim_carriage_return(<<>>), do: <<>>

  defp trim_carriage_return(line) do
    if :binary.last(line) == ?\r do
      binary_part(line, 0, byte_size(line) - 1)
    else
      line
    end
  end

  defp format_numbered_lines(lines) do
    Enum.map_join(lines, "\n", fn {number, line} -> "#{number}: #{line}" end)
  end

  defp first_line_number([{number, _line} | _]), do: number
  defp first_line_number([]), do: nil

  defp last_line_number(lines) do
    case List.last(lines) do
      {number, _line} -> number
      nil -> nil
    end
  end

  defp next_line(%{truncated?: true}, lines) do
    case last_line_number(lines) do
      nil -> nil
      number -> number + 1
    end
  end

  defp next_line(_state, _lines), do: nil

  defp next_scan_offset(%{scan_limited?: true} = state),
    do: state.scan_offset + state.scanned_bytes

  defp next_scan_offset(_state), do: nil

  defp next_scan_start_line(%{scan_limited?: true} = state), do: state.line_number
  defp next_scan_start_line(_state), do: nil

  defp walk(_path, _relative, _recursive?, _depth, %{stop?: true} = state, _fun), do: state

  defp walk(_path, _relative, _recursive?, depth, state, _fun) when depth > @max_walk_depth,
    do: Map.put(state, :depth_limited?, true)

  defp walk(path, relative, recursive?, depth, state, fun) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(state, fn name, acc ->
          if Map.get(acc, :stop?, false) do
            {:halt, acc}
          else
            child_path = Path.join(path, name)
            child_relative = if relative == "", do: name, else: Path.join(relative, name)

            case File.lstat(child_path) do
              {:ok, %{type: :directory} = stat} ->
                if MapSet.member?(@excluded_dirs, name) do
                  {:cont, acc}
                else
                  next = fun.({child_path, child_relative, :directory, stat}, acc, depth)

                  next =
                    if recursive? and not Map.get(next, :stop?, false) do
                      walk(child_path, child_relative, true, depth + 1, next, fun)
                    else
                      next
                    end

                  if Map.get(next, :stop?, false), do: {:halt, next}, else: {:cont, next}
                end

              {:ok, %{type: :symlink} = stat} ->
                next = fun.({child_path, child_relative, :symlink, stat}, acc, depth)
                if Map.get(next, :stop?, false), do: {:halt, next}, else: {:cont, next}

              {:ok, %{type: :regular} = stat} ->
                next = fun.({child_path, child_relative, :file, stat}, acc, depth)
                if Map.get(next, :stop?, false), do: {:halt, next}, else: {:cont, next}

              {:ok, %{type: type} = stat} ->
                next = fun.({child_path, child_relative, type, stat}, acc, depth)
                if Map.get(next, :stop?, false), do: {:halt, next}, else: {:cont, next}

              {:error, _reason} ->
                {:cont, acc}
            end
          end
        end)

      {:error, _reason} ->
        state
    end
  end

  defp collect_entry({_path, relative, type, stat}, state, _depth) do
    cond do
      state.skipped < state.offset ->
        %{state | skipped: state.skipped + 1}

      state.count < state.take ->
        entry_type = if type == :directory, do: "dir", else: Atom.to_string(type)
        size = if type == :directory, do: "-", else: "#{stat.size}B"

        %{
          state
          | entries: ["#{entry_type}\t#{size}\t#{relative}" | state.entries],
            count: state.count + 1
        }

      true ->
        %{state | extra?: true, stop?: true}
    end
  end

  defp grep_entry({_path, _relative, type, _stat}, state, _depth)
       when type != :file,
       do: state

  defp grep_entry({path, relative, :file, _stat}, state, _depth) do
    if excluded_file?(path) do
      state
    else
      eligible_files = state.eligible_files + 1
      state = %{state | eligible_files: eligible_files}

      cond do
        eligible_files <= state.file_offset ->
          state

        state.scanned_files >= @grep_max_files ->
          %{
            state
            | truncated?: true,
              stop?: true,
              next_offset: state.file_offset + state.scanned_files
          }

        state.scanned_bytes >= @grep_max_scanned_bytes ->
          %{state | truncated?: true, stop?: true}

        true ->
          remaining_bytes = @grep_max_scanned_bytes - state.scanned_bytes

          case scan_file(path, relative, state.matcher, state.case_sensitive?, remaining_bytes) do
            {:ok, matches, bytes, fully_scanned?, file_omissions?} ->
              available = @grep_max_matches - state.match_count
              available_bytes = @grep_max_result_bytes - state.result_bytes

              {kept, result_bytes, result_omissions?} =
                take_bounded_matches(matches, max(available, 0), max(available_bytes, 0))

              total_match_count = state.match_count + length(kept)

              hit_match_limit? =
                length(matches) > length(kept) or total_match_count >= @grep_max_matches or
                  result_omissions?

              %{
                state
                | scanned_files: state.scanned_files + 1,
                  scanned_bytes: state.scanned_bytes + bytes,
                  matches: Enum.reverse(kept, state.matches),
                  match_count: total_match_count,
                  result_bytes: state.result_bytes + result_bytes,
                  truncated?:
                    state.truncated? or not fully_scanned? or file_omissions? or
                      hit_match_limit?,
                  stop?: not fully_scanned? or hit_match_limit?,
                  next_offset:
                    if(hit_match_limit? and fully_scanned?,
                      do: state.file_offset + state.scanned_files + 1,
                      else: state.next_offset
                    )
              }

            {:error, _reason} ->
              %{state | scanned_files: state.scanned_files + 1}
          end
      end
    end
  end

  defp scan_file(path, relative, matcher, case_sensitive?, byte_budget) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          scan_file_chunks(io, relative, matcher, case_sensitive?, byte_budget, %{
            carry: <<>>,
            oversized?: false,
            line_number: 1,
            matches: [],
            match_count: 0,
            match_overflow?: false,
            bytes: 0,
            omissions?: false
          })
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan_file_chunks(_io, _relative, _matcher, _case_sensitive?, budget, state)
       when state.bytes >= budget,
       do: {:ok, Enum.reverse(state.matches), state.bytes, false, true}

  defp scan_file_chunks(io, relative, matcher, case_sensitive?, budget, state) do
    read_size = min(@read_chunk_bytes, budget - state.bytes)

    case IO.binread(io, read_size) do
      :eof ->
        state = finish_grep_line(state, relative, matcher, case_sensitive?)
        {:ok, Enum.reverse(state.matches), state.bytes, true, state.omissions?}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        state = %{state | bytes: state.bytes + byte_size(chunk)}
        state = consume_grep_chunk(chunk, state, relative, matcher, case_sensitive?)
        scan_file_chunks(io, relative, matcher, case_sensitive?, budget, state)
    end
  end

  defp consume_grep_chunk(<<>>, state, _relative, _matcher, _case_sensitive?), do: state

  defp consume_grep_chunk(chunk, state, relative, matcher, case_sensitive?) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        append_grep_segment(state, chunk)

      {index, 1} ->
        segment = binary_part(chunk, 0, index)
        rest = binary_part(chunk, index + 1, byte_size(chunk) - index - 1)

        state =
          state
          |> append_grep_segment(segment)
          |> finish_grep_line(relative, matcher, case_sensitive?)

        consume_grep_chunk(rest, state, relative, matcher, case_sensitive?)
    end
  end

  defp append_grep_segment(%{oversized?: true} = state, _segment), do: state

  defp append_grep_segment(state, segment) do
    available = @grep_max_line_bytes - byte_size(state.carry)

    if byte_size(segment) <= available do
      %{state | carry: state.carry <> segment}
    else
      %{state | carry: <<>>, oversized?: true}
    end
  end

  defp finish_grep_line(%{oversized?: true} = state, _relative, _matcher, _case_sensitive?) do
    %{
      state
      | carry: <<>>,
        oversized?: false,
        line_number: state.line_number + 1,
        omissions?: true
    }
  end

  defp finish_grep_line(state, relative, matcher, case_sensitive?) do
    line = trim_carriage_return(state.carry)

    matched? = String.valid?(line) and line_matches?(line, matcher, case_sensitive?)

    {matches, match_count, match_overflow?} =
      cond do
        matched? and state.match_count < @grep_matches_per_file ->
          match = format_grep_match(relative, state.line_number, line)
          {[match | state.matches], state.match_count + 1, state.match_overflow?}

        matched? ->
          {state.matches, state.match_count, true}

        true ->
          {state.matches, state.match_count, state.match_overflow?}
      end

    %{
      state
      | carry: <<>>,
        line_number: state.line_number + 1,
        matches: matches,
        match_count: match_count,
        match_overflow?: match_overflow?,
        omissions?: state.omissions? or match_overflow?
    }
  end

  defp take_bounded_matches(matches, count_budget, byte_budget) do
    matches
    |> Enum.reduce_while({[], 0}, fn match, {kept, bytes} ->
      added_bytes = byte_size(match) + if(kept == [], do: 0, else: 1)

      if length(kept) < count_budget and bytes + added_bytes <= byte_budget do
        {:cont, {[match | kept], bytes + added_bytes}}
      else
        {:halt, {kept, bytes}}
      end
    end)
    |> then(fn {reversed, bytes} ->
      kept = Enum.reverse(reversed)
      {kept, bytes, length(kept) < length(matches)}
    end)
  end

  defp format_grep_match(relative, line_number, line) do
    trimmed = String.trim(line)

    preview =
      if byte_size(trimmed) > @grep_match_preview_bytes do
        prefix = binary_part(trimmed, 0, @grep_match_preview_bytes)
        IexCode.Sessions.sanitize_utf8(prefix) <> "… [line preview truncated]"
      else
        trimmed
      end

    "#{relative}:#{line_number}: #{preview}"
  end

  defp excluded_file?(path) do
    MapSet.member?(@excluded_extensions, path |> Path.extname() |> String.downcase())
  end

  defp build_matcher(query, case_sensitive?) do
    case Regex.compile(query, if(case_sensitive?, do: "", else: "i")) do
      {:ok, regex} -> {:regex, regex}
      {:error, _invalid} -> {:text, if(case_sensitive?, do: query, else: String.downcase(query))}
    end
  end

  defp line_matches?(line, {:regex, regex}, _case_sensitive?), do: Regex.match?(regex, line)

  defp line_matches?(line, {:text, needle}, case_sensitive?) do
    if case_sensitive?,
      do: String.contains?(line, needle),
      else: String.contains?(String.downcase(line), needle)
  end

  defp normalize_offset(value) when is_integer(value) and value >= 0, do: value
  defp normalize_offset(_value), do: 0

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, default), do: default
end
