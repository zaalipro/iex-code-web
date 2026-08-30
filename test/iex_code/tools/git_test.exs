defmodule IexCode.Tools.GitTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.{StatusResult, CommitResult, LogEntry, CommitGenerator}

  @tag :tmp_dir
  test "Git operations lifecycle (init, status, stage, unstage, commit, diff, log)", %{
    tmp_dir: tmp_dir
  } do
    # Initialize a clean git repo in tmp_dir
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: tmp_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)

    # Initial status
    assert {:ok, %StatusResult{} = status} = Git.status(tmp_dir)
    assert status.branch in ["main", "master"]

    # Create a new file
    file_path = Path.join(tmp_dir, "lib/sample.ex")
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "defmodule Sample, do: :ok\n")

    # Status shows untracked
    assert {:ok, %StatusResult{} = status2} = Git.status(tmp_dir)
    assert "lib/sample.ex" in status2.untracked

    # Stage file
    assert :ok = Git.stage("lib/sample.ex", tmp_dir)
    assert {:ok, %StatusResult{} = status3} = Git.status(tmp_dir)
    assert Enum.any?(status3.staged, &(&1.path == "lib/sample.ex" and &1.status == :added))

    # Commit staged file
    assert {:ok, %CommitResult{} = commit_res} =
             Git.commit("feat(sample): initial sample", tmp_dir)

    assert commit_res.commit_hash != ""
    assert commit_res.short_hash != ""
    assert commit_res.message == "feat(sample): initial sample"

    # Status is now clean
    assert {:ok, %StatusResult{} = status4} = Git.status(tmp_dir)
    assert status4.clean? == true

    # Modify file and check diff
    File.write!(file_path, "defmodule Sample, do: :modified\n")
    assert {:ok, diff} = Git.diff(tmp_dir)
    assert diff =~ "-defmodule Sample, do: :ok"
    assert diff =~ "+defmodule Sample, do: :modified"

    # Log history
    assert {:ok, [log_entry | _]} = Git.log(tmp_dir)
    assert %LogEntry{} = log_entry
    assert log_entry.subject == "feat(sample): initial sample"
    assert log_entry.hash == commit_res.commit_hash
  end

  describe "CommitGenerator.generate/2" do
    test "generates feat(test-runner) for new TestRunner module" do
      diff = """
      --- a/lib/iex_code/tools/test_runner.ex
      +++ b/lib/iex_code/tools/test_runner.ex
      @@ -0,0 +1,10 @@
      +defmodule IexCode.Tools.TestRunner do
      +  def run, do: :ok
      +end
      """

      assert {:ok, msg} = CommitGenerator.generate(diff, ["lib/iex_code/tools/test_runner.ex"])
      assert msg == "feat(test-runner): implement TestRunner module"
    end

    test "generates fix(settings) for Repo.one crash fix" do
      diff = """
      --- a/lib/iex_code/settings.ex
      +++ b/lib/iex_code/settings.ex
      @@ -10,2 +10,4 @@
      -    Repo.one(AppSettings)
      +    # Fix MultipleResultsError crash
      +    Repo.one(from s in AppSettings, limit: 1)
      """

      assert {:ok, msg} = CommitGenerator.generate(diff, ["lib/iex_code/settings.ex"])
      assert msg == "fix(settings): prevent crash on multiple settings records"
    end

    test "generates test for test file changes" do
      diff = """
      --- a/test/iex_code/tools/test_runner_test.exs
      +++ b/test/iex_code/tools/test_runner_test.exs
      @@ -1,2 +1,3 @@
      +  test "new test" do
      """

      assert {:ok, msg} =
               CommitGenerator.generate(diff, ["test/iex_code/tools/test_runner_test.exs"])

      assert msg == "test: update test_runner_test"
    end
  end

  describe "Git.apply_patch/3 and Git.restore_file/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)

      sample_file = Path.join(tmp_dir, "lib/hello.ex")
      File.mkdir_p!(Path.dirname(sample_file))
      File.write!(sample_file, "defmodule Hello do\n  def world, do: :hi\nend\n")

      System.cmd("git", ["add", "lib/hello.ex"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp_dir)

      {:ok, %{tmp_dir: tmp_dir, sample_file: sample_file}}
    end

    test "apply_patch applies patch to working tree and can reverse it", %{
      tmp_dir: tmp_dir,
      sample_file: sample_file
    } do
      patch = """
      diff --git a/lib/hello.ex b/lib/hello.ex
      --- a/lib/hello.ex
      +++ b/lib/hello.ex
      @@ -1,3 +1,3 @@
       defmodule Hello do
      -  def world, do: :hi
      +  def world, do: :hello_world
       end
      """

      assert {:ok, _} = Git.apply_patch(tmp_dir, patch)
      assert File.read!(sample_file) =~ ":hello_world"

      # Apply in reverse
      assert {:ok, _} = Git.apply_patch(tmp_dir, patch, reverse: true)
      assert File.read!(sample_file) =~ ":hi"
    end

    test "apply_patch with cached: true stages changes directly into index", %{
      tmp_dir: tmp_dir,
      sample_file: sample_file
    } do
      patch = """
      diff --git a/lib/hello.ex b/lib/hello.ex
      --- a/lib/hello.ex
      +++ b/lib/hello.ex
      @@ -1,3 +1,3 @@
       defmodule Hello do
      -  def world, do: :hi
      +  def world, do: :cached_change
       end
      """

      assert {:ok, _} = Git.apply_patch(tmp_dir, patch, cached: true)

      assert {:ok, staged_diff} = Git.diff(tmp_dir, staged: true)
      assert staged_diff =~ ":cached_change"

      # Working tree file was untouched
      assert File.read!(sample_file) =~ ":hi"
    end

    test "restore_file restores working tree file and unstages", %{
      tmp_dir: tmp_dir,
      sample_file: sample_file
    } do
      File.write!(sample_file, "modified content\n")
      Git.stage("lib/hello.ex", tmp_dir)

      assert {:ok, _} = Git.restore_file(tmp_dir, "lib/hello.ex")
      assert File.read!(sample_file) =~ "defmodule Hello do"

      assert {:ok, status} = Git.status(tmp_dir)
      assert status.clean? == true
    end

    test "old Git worktree fallback restores from the index rather than HEAD", %{
      tmp_dir: tmp_dir
    } do
      fake_bin = Path.join(tmp_dir, "fake-bin")
      log = Path.join(tmp_dir, "git-argv.log")
      File.mkdir_p!(fake_bin)

      File.write!(
        Path.join(fake_bin, "git"),
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GIT_ARGV_LOG\"\n" <>
          "if [ \"$1\" = restore ]; then exit 1; fi\nexit 0\n"
      )

      File.chmod!(Path.join(fake_bin, "git"), 0o755)
      old_path = System.get_env("PATH")
      old_log = System.get_env("GIT_ARGV_LOG")
      System.put_env("PATH", fake_bin <> ":" <> old_path)
      System.put_env("GIT_ARGV_LOG", log)

      on_exit(fn ->
        System.put_env("PATH", old_path)

        if old_log,
          do: System.put_env("GIT_ARGV_LOG", old_log),
          else: System.delete_env("GIT_ARGV_LOG")
      end)

      assert {:ok, _} =
               Git.restore_file(tmp_dir, "lib/hello.ex", staged: false, worktree: true)

      assert File.read!(log) == "restore -- lib/hello.ex\ncheckout -- lib/hello.ex\n"
    end

    test "combined restore of an index-added file fails without partial mutation", %{
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "lib/added.ex")
      File.write!(file, "staged added\n")
      assert :ok = Git.stage("lib/added.ex", tmp_dir)

      {index_before, 0} =
        System.cmd("git", ["ls-files", "--stage", "--", "lib/added.ex"], cd: tmp_dir)

      {diff_before, 0} =
        System.cmd("git", ["diff", "--cached", "--binary", "--", "lib/added.ex"], cd: tmp_dir)

      assert {:error, _reason} = Git.restore_file(tmp_dir, "lib/added.ex")

      assert File.read!(file) == "staged added\n"

      assert {^index_before, 0} =
               System.cmd("git", ["ls-files", "--stage", "--", "lib/added.ex"], cd: tmp_dir)

      assert {^diff_before, 0} =
               System.cmd("git", ["diff", "--cached", "--binary", "--", "lib/added.ex"],
                 cd: tmp_dir
               )
    end

    test "stage/2 and unstage/2 handle (repo_dir, files), (files, repo_dir), (files, opts), and empty lists",
         %{tmp_dir: tmp_dir, sample_file: sample_file} do
      File.write!(sample_file, "changed 1\n")

      # (repo_dir, files)
      assert :ok = Git.stage(tmp_dir, ["lib/hello.ex"])
      assert {:ok, status} = Git.status(tmp_dir)
      assert Enum.any?(status.staged, &(&1.path == "lib/hello.ex"))

      # (repo_dir, files) unstage
      assert :ok = Git.unstage(tmp_dir, ["lib/hello.ex"])
      assert {:ok, status2} = Git.status(tmp_dir)
      assert status2.staged == []

      # (files, opts)
      assert :ok = Git.stage(["lib/hello.ex"], repo_dir: tmp_dir)
      assert {:ok, status3} = Git.status(tmp_dir)
      assert Enum.any?(status3.staged, &(&1.path == "lib/hello.ex"))

      # (files, opts) unstage
      assert :ok = Git.unstage(["lib/hello.ex"], repo_dir: tmp_dir)
      assert {:ok, status4} = Git.status(tmp_dir)
      assert status4.staged == []

      # Empty list handling
      assert :ok = Git.stage([], tmp_dir)
      assert :ok = Git.stage(tmp_dir, [])
      assert :ok = Git.unstage([], tmp_dir)
      assert :ok = Git.unstage(tmp_dir, [])
    end
  end
end
