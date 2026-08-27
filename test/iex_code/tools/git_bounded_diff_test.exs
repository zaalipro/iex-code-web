defmodule IexCode.Tools.GitBoundedDiffTest do
  use ExUnit.Case, async: true

  alias IexCode.Tools
  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.HunkOps

  setup do
    root = Path.join(System.tmp_dir!(), "bounded-git-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: root)
    {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
    File.write!(Path.join(root, "large.txt"), "base\n")
    {_output, 0} = System.cmd("git", ["add", "."], cd: root)
    {_output, 0} = System.cmd("git", ["commit", "-m", "base"], cd: root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "spools a large producer and retains only the configured preview", %{root: root} do
    File.write!(Path.join(root, "large.txt"), String.duplicate("changed line\n", 10_000))

    assert {:ok, %{content: preview, bytes: bytes, truncated?: true}} =
             Git.diff_bounded(root, max_bytes: 1_024, unified: 3)

    assert byte_size(preview) == 1_024
    assert bytes > byte_size(preview)
  end

  test "returns a complete small diff without marking it truncated", %{root: root} do
    File.write!(Path.join(root, "large.txt"), "small change\n")

    assert {:ok, %{content: preview, truncated?: false}} =
             Git.diff_bounded(root, max_bytes: 100_000, unified: 3)

    assert preview =~ "+small change"
  end

  test "terminates a diff producer at the hard disk-spool ceiling", %{root: root} do
    File.write!(Path.join(root, "large.txt"), String.duplicate("changed line\n", 10_000))

    assert {:error, :output_limit_exceeded} =
             Git.diff_bounded(root, max_bytes: 1_024, producer_limit_bytes: 2_048)
  end

  test "status retains a bounded useful prefix and exposes truncation metadata", %{root: root} do
    for index <- 1..40 do
      File.write!(
        Path.join(root, "untracked-#{String.pad_leading(to_string(index), 3, "0")}.txt"),
        "x"
      )
    end

    assert {:ok, status} = Git.status(root, path_limit: 10)
    assert status.branch == "main"
    refute status.clean?
    assert status.truncated?
    assert status.retained_paths == 10
    assert status.path_limit == 10
    assert length(status.untracked) == 10
    assert hd(status.untracked) == "untracked-001.txt"
  end

  test "status producer cap never returns a partial porcelain path", %{root: root} do
    File.write!(Path.join(root, "short.txt"), "x")
    File.write!(Path.join(root, String.duplicate("long-name-", 20) <> ".txt"), "x")

    assert {:ok, status} = Git.status(root, output_limit_bytes: 64)
    assert status.truncated?
    assert status.producer_limit_bytes == 64
    assert Enum.all?(status.untracked, &String.ends_with?(&1, ".txt"))
  end

  test "git_status tool formats only its bounded retention and gives continuation guidance", %{
    root: root
  } do
    for index <- 1..340 do
      File.write!(
        Path.join(root, "tool-file-#{String.pad_leading(to_string(index), 4, "0")}.txt"),
        "x"
      )
    end

    assert {:ok, output} = Tools.execute("git_status", %{"path" => ""}, root)
    assert output =~ "Untracked retained (300)"
    assert output =~ "[git status truncated after retaining 300 paths"
    assert output =~ "git status --short -- <path>"
    assert byte_size(output) < 100_000
  end

  test "path-scoped status preserves untracked revert behavior beyond the global prefix", %{
    root: root
  } do
    for index <- 1..30 do
      File.write!(Path.join(root, "a-file-#{index}.txt"), "x")
    end

    omitted_path = "z-target.txt"
    File.write!(Path.join(root, omitted_path), "temporary")
    assert {:ok, %{truncated?: true}} = Git.status(root, path_limit: 5)

    assert {:ok, :reverted} = HunkOps.revert_file(root, omitted_path)
    refute File.exists?(Path.join(root, omitted_path))
  end
end
