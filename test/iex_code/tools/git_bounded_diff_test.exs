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

  test "direct status producer retains one tracked PID boundary through completion", %{root: root} do
    {fake_git, producer_path, _child_path} = fake_git(root, :complete)

    assert {:ok, status} = Git.status(root, _git_executable: fake_git)
    assert "runner-visible.txt" in status.untracked

    {pid, process_group, session} = read_process_boundary!(producer_path)
    assert pid == process_group
    assert pid == session
  end

  test "diff producer cap kills the tracked process group and its descendant", %{root: root} do
    {fake_git, producer_path, child_path} = fake_git(root, :produce_forever)
    cleanup_processes_on_exit([producer_path, child_path])

    assert {:error, :output_limit_exceeded} =
             Git.diff_bounded(root,
               max_bytes: 1_024,
               producer_limit_bytes: 2_048,
               _git_executable: fake_git
             )

    assert_boundary_and_descendant_dead(producer_path, child_path)
  end

  test "short status timeout kills the tracked process group and its descendant", %{root: root} do
    {fake_git, producer_path, child_path} = fake_git(root, :wait_forever)
    cleanup_processes_on_exit([producer_path, child_path])

    assert {:error, :timeout} =
             Git.status(root, _git_executable: fake_git, _timeout_ms: 2_000)

    assert_boundary_and_descendant_dead(producer_path, child_path)
  end

  defp fake_git(root, mode) do
    suffix = System.unique_integer([:positive, :monotonic])
    executable = Path.join(root, "fake-git-#{suffix}")
    producer_path = executable <> ".producer"
    child_path = executable <> ".child"

    body =
      case mode do
        :complete ->
          """
          with open(producer_path, "w") as output:
              output.write(f"{os.getpid()} {os.getpgrp()} {os.getsid(0)}")
          time.sleep(0.05)
          os.write(1, b"## main\\n?? runner-visible.txt\\n")
          """

        :produce_forever ->
          producer_body("""
          while True:
              os.write(1, b"x" * 65536)
          """)

        :wait_forever ->
          producer_body("""
          while True:
              time.sleep(60)
          """)
      end

    File.write!(executable, """
    #!/usr/bin/env python3
    import os
    import subprocess
    import sys
    import time

    producer_path = #{inspect(producer_path)}
    child_path = #{inspect(child_path)}
    #{body}
    """)

    File.chmod!(executable, 0o700)
    {executable, producer_path, child_path}
  end

  defp producer_body(loop) do
    """
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    with open(producer_path, "w") as output:
        output.write(f"{os.getpid()} {os.getpgrp()} {os.getsid(0)}")
    with open(child_path, "w") as output:
        output.write(str(child.pid))
    #{loop}
    """
  end

  defp assert_boundary_and_descendant_dead(producer_path, child_path) do
    {producer_pid, process_group, session} = read_process_boundary!(producer_path)
    child_pid = child_path |> File.read!() |> String.to_integer()

    assert producer_pid == process_group
    assert producer_pid == session
    assert child_pid != producer_pid
    assert_process_dead(producer_pid)
    assert_process_dead(child_pid)
  end

  defp read_process_boundary!(path) do
    [pid, process_group, session] = path |> File.read!() |> String.split()
    {String.to_integer(pid), String.to_integer(process_group), String.to_integer(session)}
  end

  defp assert_process_dead(pid) do
    python = System.find_executable("python3") || System.find_executable("python")

    script = """
    import os, sys, time
    pid = int(sys.argv[1])
    for _ in range(100):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            sys.exit(0)
        time.sleep(0.02)
    sys.exit(1)
    """

    assert {_output, 0} =
             System.cmd(python, ["-c", script, Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp cleanup_processes_on_exit(paths) do
    on_exit(fn ->
      Enum.each(paths, fn path ->
        with {:ok, content} <- File.read(path),
             {pid, _rest} <- Integer.parse(content) do
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end)
    end)
  end
end
