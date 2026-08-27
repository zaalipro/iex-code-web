defmodule IexCode.Tools.BoundedFilesTest do
  use ExUnit.Case, async: true

  alias IexCode.Tools

  @tag :tmp_dir
  test "read_file streams bounded pages and preserves line numbering and UTF-8", %{tmp_dir: root} do
    path = Path.join(root, "large.txt")

    File.write!(
      path,
      1..1_700
      |> Enum.map_join("\n", fn line -> "héllo-#{line}" end)
    )

    assert {:ok, first} = Tools.execute("read_file", %{"path" => "large.txt"}, root)
    assert first =~ "1: héllo-1"
    assert first =~ "800: héllo-800"
    assert first =~ "continue with start_line=801"
    refute first =~ "801: héllo-801"
    assert String.valid?(first)

    assert {:ok, second} =
             Tools.execute(
               "read_file",
               %{"path" => "large.txt", "start_line" => 801, "end_line" => 1_600},
               root
             )

    assert second =~ "801: héllo-801"
    assert second =~ "1600: héllo-1600"
    refute second =~ "1601: héllo-1601"
  end

  @tag :tmp_dir
  test "read_file caps explicit giant ranges and oversized single lines", %{tmp_dir: root} do
    File.write!(Path.join(root, "many.txt"), Enum.map_join(1..2_000, "\n", &"line-#{&1}"))

    assert {:ok, range} =
             Tools.execute(
               "read_file",
               %{"path" => "many.txt", "start_line" => 100, "end_line" => 2_000},
               root
             )

    assert range =~ "100: line-100"
    assert range =~ "899: line-899"
    assert range =~ "continue with start_line=900"
    refute range =~ "900: line-900"

    huge_path = Path.join(root, "one-line.txt")
    write_repeated(huge_path, "x", 2 * 1_024 * 1_024)

    assert {:ok, huge} = Tools.execute("read_file", %{"path" => "one-line.txt"}, root)
    assert byte_size(huge) < 1_100_000
    assert huge =~ "line is too large for an agent response"
    assert String.valid?(huge)
  end

  @tag :tmp_dir
  test "read_file pauses a distant line scan and accepts its continuation cursor", %{
    tmp_dir: root
  } do
    path = Path.join(root, "distant.txt")
    line = String.duplicate("a", 1_020) <> "\n"
    write_repeated(path, line, 40_000)

    assert {:ok, paused} =
             Tools.execute(
               "read_file",
               %{"path" => "distant.txt", "start_line" => 35_000, "end_line" => 35_001},
               root
             )

    assert paused =~ "scan paused"
    assert [_, offset] = Regex.run(~r/scan_offset=(\d+)/, paused)
    assert [_, line_number] = Regex.run(~r/scan_start_line=(\d+)/, paused)

    assert {:ok, continued} =
             Tools.execute(
               "read_file",
               %{
                 "path" => "distant.txt",
                 "start_line" => 35_000,
                 "end_line" => 35_001,
                 "scan_offset" => String.to_integer(offset),
                 "scan_start_line" => String.to_integer(line_number)
               },
               root
             )

    assert continued =~ "35000: "
    assert continued =~ "35001: "
    refute continued =~ "scan paused"
  end

  @tag :tmp_dir
  test "read_file keeps the requested line when it begins at the scan boundary", %{tmp_dir: root} do
    path = Path.join(root, "boundary.txt")
    prefix = String.duplicate("a", 32 * 1_024 * 1_024 - 8) <> "\n"
    File.write!(path, prefix <> "boundary-line\n")

    assert {:ok, output} =
             Tools.execute(
               "read_file",
               %{"path" => "boundary.txt", "start_line" => 2, "end_line" => 2},
               root
             )

    assert output =~ "2: boundary-line"
    refute output =~ "scan paused"
  end

  @tag :tmp_dir
  test "list_dir paginates without following symlink directories", %{tmp_dir: root} do
    Enum.each(1..230, fn index ->
      File.write!(
        Path.join(root, "file-#{String.pad_leading(Integer.to_string(index), 3, "0")}"),
        "x"
      )
    end)

    outside = root <> "-outside"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "not workspace content")
    on_exit(fn -> File.rm_rf(outside) end)
    File.ln_s!(outside, Path.join(root, "linked-outside"))

    assert {:ok, first} =
             Tools.execute(
               "list_dir",
               %{"path" => "", "recursive" => true, "limit" => 100},
               root
             )

    assert first =~ "listing truncated; continue with offset=100"
    refute first =~ "linked-outside/secret"

    assert {:ok, second} =
             Tools.execute(
               "list_dir",
               %{"path" => "", "recursive" => true, "offset" => 100, "limit" => 100},
               root
             )

    assert second =~ "listing truncated; continue with offset=200"
  end

  @tag :tmp_dir
  test "grep_search bounds retained matches, previews, and reports per-file omissions", %{
    tmp_dir: root
  } do
    long_suffix = String.duplicate("z", 32 * 1_024)

    File.write!(
      Path.join(root, "matches.txt"),
      Enum.map_join(1..25, "\n", fn index -> "needle-#{index}-#{long_suffix}" end)
    )

    assert {:ok, output} = Tools.execute("grep_search", %{"query" => "needle"}, root)
    assert output =~ "matches.txt:1: needle-1"
    assert output =~ "line preview truncated"
    assert output =~ "search truncated"
    assert byte_size(output) < 100_000
    assert String.valid?(output)
  end

  defp write_repeated(path, content, repetitions) do
    {:ok, io} = File.open(path, [:write, :binary])
    batch_repetitions = max(div(1_024 * 1_024, max(byte_size(content), 1)), 1)

    try do
      write_batches(io, content, repetitions, batch_repetitions)
    after
      File.close(io)
    end
  end

  defp write_batches(_io, _content, 0, _batch_repetitions), do: :ok

  defp write_batches(io, content, remaining, batch_repetitions) do
    count = min(remaining, batch_repetitions)
    IO.binwrite(io, String.duplicate(content, count))
    write_batches(io, content, remaining - count, batch_repetitions)
  end
end
