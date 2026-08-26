defmodule IexCode.Tools.MultiPatch.Diff do
  @moduledoc """
  Unified diff generator for text changes across files.
  """

  @doc """
  Generates a unified diff string comparing `orig` to `new` for `path`.
  CRLF line endings are preserved when present in the inputs.
  """
  @spec unified_diff(String.t(), String.t(), Path.t()) :: String.t()
  def unified_diff(orig, new, path \\ "file") do
    eol = detect_eol(orig, new)
    orig_lines = split_lines(orig)
    new_lines = split_lines(new)

    if orig_lines == new_lines do
      ""
    else
      header = "--- a/#{path}" <> eol <> "+++ b/#{path}" <> eol
      diff_body = generate_hunks(orig_lines, new_lines, eol)
      header <> diff_body
    end
  end

  defp split_lines(text), do: String.split(text || "", ~r/\r?\n/)

  defp detect_eol(orig, new) do
    cond do
      String.contains?(orig || "", "\r\n") -> "\r\n"
      String.contains?(new || "", "\r\n") -> "\r\n"
      true -> "\n"
    end
  end

  defp generate_hunks(orig_lines, new_lines, eol) do
    # Simple line-by-line diff generation
    changes = List.myers_difference(orig_lines, new_lines)

    lines =
      Enum.flat_map(changes, fn
        {:eq, list} ->
          Enum.map(list, fn l -> " " <> l end)

        {:del, list} ->
          Enum.map(list, fn l -> "-" <> l end)

        {:ins, list} ->
          Enum.map(list, fn l -> "+" <> l end)
      end)

    orig_count = length(orig_lines)
    new_count = length(new_lines)
    hunk_header = "@@ -1,#{orig_count} +1,#{new_count} @@" <> eol
    hunk_header <> Enum.join(lines, eol) <> eol
  end
end
