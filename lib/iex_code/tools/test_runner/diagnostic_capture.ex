defmodule IexCode.Tools.TestRunner.DiagnosticCapture do
  @moduledoc false

  @chunk_bytes 16 * 1_024
  @max_line_bytes 16 * 1_024
  @max_block_bytes 64 * 1_024
  @max_total_bytes 512 * 1_024
  @failure_header ~r/^\s*\d+\)\s+.+\s+\([A-Z][A-Za-z0-9_.]*\)\s*$/
  @compile_header ~r/^(?:== Compilation error in file |\s*\*\*\s+\([\w.]+Error\))/

  @spec from_file(Path.t()) :: binary()
  def from_file(path) when is_binary(path) do
    initial = %{pending: "", active: nil, captures: [], total_bytes: 0}

    state =
      path
      |> File.stream!([:read, :binary], @chunk_bytes)
      |> Enum.reduce(initial, &feed_chunk/2)
      |> flush_pending()
      |> finish_active()

    state.captures
    |> Enum.reverse()
    |> Enum.join("\n")
  rescue
    _error -> ""
  end

  defp feed_chunk(chunk, state) do
    parts = :binary.split(state.pending <> chunk, "\n", [:global])
    {complete, [pending]} = Enum.split(parts, -1)

    state = Enum.reduce(complete, %{state | pending: ""}, &consume_line(&1 <> "\n", &2))
    bound_pending(%{state | pending: pending})
  end

  defp bound_pending(%{pending: pending} = state) when byte_size(pending) <= @max_line_bytes,
    do: state

  defp bound_pending(%{pending: pending} = state) do
    <<fragment::binary-size(@max_line_bytes), rest::binary>> = pending
    state |> Map.put(:pending, rest) |> consume_line(fragment) |> bound_pending()
  end

  defp flush_pending(%{pending: ""} = state), do: state

  defp flush_pending(%{pending: pending} = state),
    do: consume_line(pending, %{state | pending: ""})

  defp consume_line(line, state) do
    clean = IexCode.Tools.TestRunner.Parser.strip_ansi(line)

    cond do
      diagnostic_header?(clean) ->
        state |> finish_active() |> start_active(line)

      not is_nil(state.active) and Regex.match?(~r/^Finished in /, clean) ->
        finish_active(state)

      not is_nil(state.active) ->
        append_active(state, line)

      true ->
        state
    end
  end

  defp diagnostic_header?(line),
    do: Regex.match?(@failure_header, line) or Regex.match?(@compile_header, line)

  defp start_active(state, line) do
    available = min(@max_block_bytes, @max_total_bytes - state.total_bytes)
    %{state | active: binary_part(line, 0, min(byte_size(line), max(available, 0)))}
  end

  defp append_active(%{active: active} = state, line) do
    available = min(@max_block_bytes - byte_size(active), @max_total_bytes - state.total_bytes)

    if available > 0 do
      %{state | active: active <> binary_part(line, 0, min(byte_size(line), available))}
    else
      state
    end
  end

  defp finish_active(%{active: nil} = state), do: state
  defp finish_active(%{active: ""} = state), do: %{state | active: nil}

  defp finish_active(%{active: active} = state) do
    %{
      state
      | active: nil,
        captures: [active | state.captures],
        total_bytes: state.total_bytes + byte_size(active)
    }
  end
end
