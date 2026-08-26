defmodule IexCode.Tools.GitStagingAdversarialStressTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.HunkOps

  setup do
    tmp_base =
      Path.join(
        System.tmp_dir!(),
        "git_stress_#{System.system_time(:microsecond)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_base)

    repo_dir = Path.join(tmp_base, "test_repo")
    File.mkdir_p!(repo_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Stress Tester"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "tester@iexcode.local"], cd: repo_dir)

    on_exit(fn ->
      File.rm_rf(tmp_base)
    end)

    {:ok, %{repo_dir: repo_dir, tmp_base: tmp_base}}
  end

  describe "Branch Operations & Listing" do
    test "lists local and remote branches with upstream tracking and active branch flag", %{
      repo_dir: repo_dir,
      tmp_base: tmp_base
    } do
      # Initial commit on main
      File.write!(Path.join(repo_dir, "init.txt"), "init")
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: initial commit")

      # Create feature branches
      assert {:ok, _} = Git.create_branch(repo_dir, "feature/auth")
      assert {:ok, _} = Git.create_branch(repo_dir, "bugfix/login")
      assert {:ok, _} = Git.switch_branch(repo_dir, "main")

      # Set up bare remote and clone to test remote tracking
      bare_remote = Path.join(tmp_base, "remote.git")
      {_, 0} = System.cmd("git", ["init", "--bare", bare_remote])
      {_, 0} = System.cmd("git", ["remote", "add", "origin", bare_remote], cd: repo_dir)
      {_, 0} = System.cmd("git", ["push", "-u", "origin", "main"], cd: repo_dir)

      # List branches
      assert {:ok, branches} = Git.branches(repo_dir)
      branch_names = Enum.map(branches, & &1.name)

      assert "main" in branch_names
      assert "feature/auth" in branch_names
      assert "bugfix/login" in branch_names
      assert "origin/main" in branch_names

      # Verify current branch metadata
      main_entry = Enum.find(branches, &(&1.name == "main"))
      assert main_entry.current? == true
      assert main_entry.remote? == false
      assert main_entry.upstream == "origin/main"

      # Verify current_branch/1 helper
      assert {:ok, "main"} = Git.current_branch(repo_dir)
    end

    test "handles branch creation errors and invalid branch names", %{repo_dir: repo_dir} do
      File.write!(Path.join(repo_dir, "init.txt"), "init")
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: initial commit")

      # Duplicate branch creation fails
      assert {:ok, _} = Git.create_branch(repo_dir, "feature/dup")
      assert {:error, _} = Git.create_branch(repo_dir, "feature/dup")

      # Invalid branch name
      assert {:error, _} = Git.create_branch(repo_dir, "bad..branch..name")
      assert {:error, _} = Git.switch_branch(repo_dir, "non_existent_branch")
    end
  end

  describe "Remote Synchronization (Fetch & Pull)" do
    test "fetches remote refs and pulls upstream commits cleanly with rebase", %{
      repo_dir: repo1,
      tmp_base: tmp_base
    } do
      # Commit on repo1
      File.write!(Path.join(repo1, "file1.txt"), "hello v1\n")
      Git.stage(:all, repo1)
      assert {:ok, _} = Git.commit(repo1, "feat: v1")

      # Setup remote
      bare_remote = Path.join(tmp_base, "bare_remote.git")
      {_, 0} = System.cmd("git", ["init", "--bare", bare_remote])
      {_, 0} = System.cmd("git", ["remote", "add", "origin", bare_remote], cd: repo1)
      {_, 0} = System.cmd("git", ["push", "-u", "origin", "main"], cd: repo1)

      # Clone repo2 from bare remote
      repo2 = Path.join(tmp_base, "repo2")
      {_, 0} = System.cmd("git", ["clone", bare_remote, repo2])
      {_, 0} = System.cmd("git", ["config", "user.name", "Tester 2"], cd: repo2)
      {_, 0} = System.cmd("git", ["config", "user.email", "tester2@iexcode.local"], cd: repo2)

      # Push new commit from repo2
      File.write!(Path.join(repo2, "file2.txt"), "repo2 addition\n")
      Git.stage(:all, repo2)
      assert {:ok, _} = Git.commit(repo2, "feat: add file2 from repo2")
      {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: repo2)

      # Fetch in repo1
      assert {:ok, _} = Git.fetch(repo1)

      # Pull with rebase in repo1
      assert {:ok, _} = Git.pull(repo1, rebase: true)
      assert File.exists?(Path.join(repo1, "file2.txt"))
      assert File.read!(Path.join(repo1, "file2.txt")) =~ "repo2 addition"
    end

    test "handles remote error when remote is missing", %{repo_dir: repo_dir} do
      assert {:error, _} = Git.fetch(repo_dir, remote: "nonexistent_remote")
      assert {:error, _} = Git.pull(repo_dir)
    end
  end

  describe "Multi-File Staging & Unstaging (Standard (files, repo_dir) convention)" do
    test "stages and unstages files individually and in bulk across all lifecycle states", %{
      repo_dir: repo_dir
    } do
      File.write!(Path.join(repo_dir, "tracked.txt"), "tracked v1\n")
      File.write!(Path.join(repo_dir, "to_delete.txt"), "delete me\n")
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: init")

      # Create changes:
      # 1. Modify tracked
      File.write!(Path.join(repo_dir, "tracked.txt"), "tracked v2\n")
      # 2. Delete to_delete
      File.rm!(Path.join(repo_dir, "to_delete.txt"))
      # 3. Create new untracked
      File.write!(Path.join(repo_dir, "new_file.txt"), "new file\n")

      assert {:ok, status1} = Git.status(repo_dir)
      assert status1.staged == []
      assert length(status1.unstaged) >= 1
      assert "new_file.txt" in status1.untracked

      # Stage individual file using (file, repo_dir) convention
      assert :ok = Git.stage("tracked.txt", repo_dir)
      assert {:ok, status2} = Git.status(repo_dir)
      staged_paths = Enum.map(status2.staged, & &1.path)
      assert "tracked.txt" in staged_paths
      refute "new_file.txt" in staged_paths

      # Unstage individual file using (file, repo_dir) convention
      assert :ok = Git.unstage("tracked.txt", repo_dir)
      assert {:ok, status3} = Git.status(repo_dir)
      assert status3.staged == []

      # Stage All (:all, repo_dir)
      assert :ok = Git.stage(:all, repo_dir)
      assert {:ok, status4} = Git.status(repo_dir)
      staged_all = Enum.map(status4.staged, & &1.path)
      assert "tracked.txt" in staged_all
      assert "new_file.txt" in staged_all
      assert "to_delete.txt" in staged_all

      # Unstage All (:all, repo_dir)
      assert :ok = Git.unstage(:all, repo_dir)
      assert {:ok, status5} = Git.status(repo_dir)
      assert status5.staged == []
    end

    test "reverts tracked changes and safely removes untracked files", %{repo_dir: repo_dir} do
      File.write!(Path.join(repo_dir, "important.txt"), "original content\n")
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: save important")

      # Modify tracked and create untracked
      File.write!(Path.join(repo_dir, "important.txt"), "corrupted content\n")
      File.write!(Path.join(repo_dir, "temp_junk.txt"), "junk\n")

      # Revert tracked file
      assert {:ok, :reverted} = HunkOps.revert_file(repo_dir, "important.txt")
      assert File.read!(Path.join(repo_dir, "important.txt")) == "original content\n"

      # Revert untracked file (deletes it)
      assert {:ok, :reverted} = HunkOps.revert_file(repo_dir, "temp_junk.txt")
      refute File.exists?(Path.join(repo_dir, "temp_junk.txt"))
    end
  end

  describe "Granular Diff Hunk Unstaging (HunkOps.unstage_hunk/4)" do
    test "unstages an individual hunk from the index while keeping other staged hunks and working tree intact",
         %{repo_dir: repo_dir} do
      multihunk_path = Path.join(repo_dir, "lib/multihunk.ex")
      File.mkdir_p!(Path.dirname(multihunk_path))

      initial_content = """
      defmodule MultiHunk do
        # Section 1: Alpha
        def alpha, do: 1

        # Spacer 1
        def noop1_1, do: :ok
        def noop1_2, do: :ok
        def noop1_3, do: :ok
        def noop1_4, do: :ok
        def noop1_5, do: :ok
        def noop1_6, do: :ok
        def noop1_7, do: :ok
        def noop1_8, do: :ok

        # Section 2: Beta
        def beta, do: 2

        # Spacer 2
        def noop2_1, do: :ok
        def noop2_2, do: :ok
        def noop2_3, do: :ok
        def noop2_4, do: :ok
        def noop2_5, do: :ok
        def noop2_6, do: :ok
        def noop2_7, do: :ok
        def noop2_8, do: :ok

        # Section 3: Gamma
        def gamma, do: 3
      end
      """

      File.write!(multihunk_path, initial_content)
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: initial multihunk baseline")

      # Modify 3 separate sections
      modified_content = """
      defmodule MultiHunk do
        # Section 1: Alpha MODIFIED
        def alpha, do: :alpha_modified

        # Spacer 1
        def noop1_1, do: :ok
        def noop1_2, do: :ok
        def noop1_3, do: :ok
        def noop1_4, do: :ok
        def noop1_5, do: :ok
        def noop1_6, do: :ok
        def noop1_7, do: :ok
        def noop1_8, do: :ok

        # Section 2: Beta MODIFIED
        def beta, do: :beta_modified

        # Spacer 2
        def noop2_1, do: :ok
        def noop2_2, do: :ok
        def noop2_3, do: :ok
        def noop2_4, do: :ok
        def noop2_5, do: :ok
        def noop2_6, do: :ok
        def noop2_7, do: :ok
        def noop2_8, do: :ok

        # Section 3: Gamma MODIFIED
        def gamma, do: :gamma_modified
      end
      """

      File.write!(multihunk_path, modified_content)

      # Stage the entire file (all 3 hunks are staged)
      assert :ok = Git.stage("lib/multihunk.ex", repo_dir)

      assert {:ok, staged_diff} = Git.diff(repo_dir, staged: true, paths: ["lib/multihunk.ex"])
      assert staged_diff =~ ":alpha_modified"
      assert staged_diff =~ ":beta_modified"
      assert staged_diff =~ ":gamma_modified"

      # Parse hunks to get initial hunk IDs
      assert {:ok, [file_diff]} = Git.DiffParser.parse(staged_diff)
      assert length(file_diff.hunks) == 3

      # Unstage hunk 2 from the index
      assert {:ok, _remaining} = HunkOps.unstage_hunk(repo_dir, "lib/multihunk.ex", "hunk-2")

      # Staged index should now contain hunk 1 and hunk 3, but NOT hunk 2
      assert {:ok, staged_after_hunk2} =
               Git.diff(repo_dir, staged: true, paths: ["lib/multihunk.ex"])

      assert staged_after_hunk2 =~ ":alpha_modified"
      refute staged_after_hunk2 =~ ":beta_modified"
      assert staged_after_hunk2 =~ ":gamma_modified"

      # Working tree should still contain all 3 modifications
      assert File.read!(multihunk_path) == modified_content

      # Unstage the first of the remaining staged hunks (hunk-1)
      assert {:ok, _} = HunkOps.unstage_hunk(repo_dir, "lib/multihunk.ex", "hunk-1")

      # Staged index should now ONLY contain the third modification (:gamma_modified)
      assert {:ok, staged_after_hunk1} =
               Git.diff(repo_dir, staged: true, paths: ["lib/multihunk.ex"])

      refute staged_after_hunk1 =~ ":alpha_modified"
      refute staged_after_hunk1 =~ ":beta_modified"
      assert staged_after_hunk1 =~ ":gamma_modified"

      # Unstage the final remaining staged hunk (hunk-1 / index 1)
      assert {:ok, _} = HunkOps.unstage_hunk(repo_dir, "lib/multihunk.ex", 1)

      # Staged diff is now completely empty
      assert {:ok, staged_final} = Git.diff(repo_dir, staged: true, paths: ["lib/multihunk.ex"])
      assert String.trim(staged_final) == ""

      # Working tree is still fully intact with all modifications
      assert File.read!(multihunk_path) == modified_content
    end
  end

  describe "AI Commit Message Generation & Commit Execution" do
    test "generates conventional commit message, enforces staged check, and creates verifiable commit",
         %{repo_dir: repo_dir} do
      File.write!(Path.join(repo_dir, "core.ex"), "defmodule Core, do: :v1\n")
      Git.stage(:all, repo_dir)
      assert {:ok, _} = Git.commit(repo_dir, "chore: initial")

      # Attempting to commit with nothing staged fails
      assert {:error, :nothing_staged} = Git.commit(repo_dir, "feat: ghost commit")

      # Make change and stage
      File.write!(Path.join(repo_dir, "core.ex"), "defmodule Core, do: :v2\n")
      Git.stage("core.ex", repo_dir)

      # Generate commit message
      assert {:ok, message} = Git.generate_commit_message(repo_dir)
      assert message =~ "feat" or message =~ "update" or message =~ "core"

      # Commit
      assert {:ok, result} = Git.commit(repo_dir, message)
      assert is_binary(result.commit_hash)
      assert String.length(result.commit_hash) == 40
      assert String.length(result.short_hash) == 7
      assert result.message == message

      # Check Git log
      assert {:ok, [latest_log | _]} = Git.log(repo_dir, limit: 5)
      assert latest_log.hash == result.commit_hash
      assert latest_log.short_hash == result.short_hash
      assert String.starts_with?(result.message, latest_log.subject)
    end
  end
end
