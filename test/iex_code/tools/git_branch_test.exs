defmodule IexCode.Tools.GitBranchTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo_dir = Path.join(tmp_dir, "test_repo")
    File.mkdir_p!(repo_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    file_path = Path.join(repo_dir, "README.md")
    File.write!(file_path, "# Initial Repository\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: repo_dir)

    {:ok, %{repo_dir: repo_dir}}
  end

  # ============================================================================
  # 1. Git.branches/1 Tests
  # ============================================================================
  describe "Git.branches/1" do
    test "lists active branches and marks current active branch", %{repo_dir: repo_dir} do
      assert {:ok, branches} = Git.branches(repo_dir)
      assert is_list(branches)
      assert length(branches) >= 1

      main_branch = Enum.find(branches, fn b -> b.name in ["main", "master"] end)
      assert main_branch != nil
      assert main_branch.current? == true
      assert main_branch.remote? == false
    end

    test "reflects newly created branches and active branch switches", %{repo_dir: repo_dir} do
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/auth"], cd: repo_dir)

      assert {:ok, branches} = Git.branches(repo_dir)
      assert length(branches) == 2

      feature = Enum.find(branches, &(&1.name == "feature/auth"))
      assert feature != nil
      assert feature.current? == true

      main = Enum.find(branches, &(&1.name in ["main", "master"]))
      assert main != nil
      assert main.current? == false
    end

    test "handles non-git directory with structured error", %{tmp_dir: tmp_dir} do
      non_git_dir = Path.join(tmp_dir, "empty_dir")
      File.mkdir_p!(non_git_dir)

      assert {:error, :not_a_git_repo} = Git.branches(non_git_dir)
    end
  end

  # ============================================================================
  # 2. Git.switch_branch/3 Tests
  # ============================================================================
  describe "Git.switch_branch/3" do
    test "switches between existing branches cleanly", %{repo_dir: repo_dir} do
      {_, 0} = System.cmd("git", ["branch", "develop"], cd: repo_dir)

      assert {:ok, _output} = Git.switch_branch(repo_dir, "develop")
      assert {:ok, "develop"} = Git.current_branch(repo_dir)

      assert {:ok, _output} = Git.switch_branch(repo_dir, "main")
      assert {:ok, "main"} = Git.current_branch(repo_dir)
    end

    test "creates and switches to a new branch with create: true", %{repo_dir: repo_dir} do
      assert {:ok, _output} = Git.switch_branch(repo_dir, "feature/ast-explorer", create: true)
      assert {:ok, "feature/ast-explorer"} = Git.current_branch(repo_dir)

      assert {:ok, branches} = Git.branches(repo_dir)
      assert Enum.any?(branches, &(&1.name == "feature/ast-explorer" and &1.current? == true))
    end

    test "returns error when attempting to switch to non-existent branch without create flag", %{
      repo_dir: repo_dir
    } do
      assert {:error, _reason} = Git.switch_branch(repo_dir, "non-existent-branch")
      assert {:ok, "main"} = Git.current_branch(repo_dir)
    end

    test "returns error in non-git directory", %{tmp_dir: tmp_dir} do
      non_git_dir = Path.join(tmp_dir, "not_git")
      File.mkdir_p!(non_git_dir)

      assert {:error, :not_a_git_repo} = Git.switch_branch(non_git_dir, "main")
    end

    test "rejects an option-looking ref without forcing dirty files", %{
      repo_dir: repo_dir
    } do
      {_, 0} = System.cmd("git", ["update-ref", "refs/heads/-f", "HEAD"], cd: repo_dir)
      dirty = Path.join(repo_dir, "README.md")
      File.write!(dirty, "# Dirty worktree must survive\n")

      assert {:error, :invalid_branch_name} = Git.switch_branch(repo_dir, "-f")
      assert {:ok, "main"} = Git.current_branch(repo_dir)
      assert File.read!(dirty) == "# Dirty worktree must survive\n"
    end
  end

  # ============================================================================
  # 3. Git.create_branch/3 (Direct Helper or Switch Delegate)
  # ============================================================================
  describe "Git.create_branch/3" do
    test "creates a new branch from current HEAD", %{repo_dir: repo_dir} do
      # Test either dedicated create_branch/3 or switch_branch with create: true
      result =
        if function_exported?(Git, :create_branch, 3) do
          Git.create_branch(repo_dir, "hotfix/v1.0.1", [])
        else
          Git.switch_branch(repo_dir, "hotfix/v1.0.1", create: true)
        end

      assert {:ok, _} = result
      assert {:ok, branches} = Git.branches(repo_dir)
      assert Enum.any?(branches, &(&1.name == "hotfix/v1.0.1"))
    end
  end

  # ============================================================================
  # 4. Git.fetch/2 and Git.pull/3 with Local Remote Fixture
  # ============================================================================
  describe "Git.fetch/2 and Git.pull/3" do
    setup %{tmp_dir: tmp_dir, repo_dir: repo_dir} do
      bare_dir = Path.join(tmp_dir, "bare_remote.git")
      {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", bare_dir])

      # Add bare remote to repo_dir and push main
      {_, 0} = System.cmd("git", ["remote", "add", "origin", bare_dir], cd: repo_dir)
      {_, 0} = System.cmd("git", ["push", "-u", "origin", "main"], cd: repo_dir)

      # Create a secondary clone to produce remote commits
      clone_dir = Path.join(tmp_dir, "second_clone")
      {_, 0} = System.cmd("git", ["clone", "--branch", "main", bare_dir, clone_dir])
      {_, 0} = System.cmd("git", ["config", "user.name", "Second User"], cd: clone_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "second@example.com"], cd: clone_dir)

      {:ok, %{bare_dir: bare_dir, clone_dir: clone_dir}}
    end

    test "fetches remote refs successfully", %{repo_dir: repo_dir} do
      assert {:ok, _output} = Git.fetch(repo_dir, remote: "origin")
    end

    test "pulls remote commits and updates working tree", %{
      repo_dir: repo_dir,
      clone_dir: clone_dir
    } do
      # Make commit in clone and push
      remote_file = Path.join(clone_dir, "remote_change.txt")
      File.write!(remote_file, "Created in secondary clone\n")
      {_, 0} = System.cmd("git", ["add", "remote_change.txt"], cd: clone_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Remote update"], cd: clone_dir)
      {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: clone_dir)

      # Pull in original repo
      assert {:ok, _output} = Git.pull(repo_dir, rebase: false)
      assert File.exists?(Path.join(repo_dir, "remote_change.txt"))
      assert File.read!(Path.join(repo_dir, "remote_change.txt")) =~ "secondary clone"
    end

    test "handles fetch failure gracefully when remote does not exist", %{repo_dir: repo_dir} do
      assert {:error, _reason} = Git.fetch(repo_dir, remote: "non_existent_remote")
    end
  end
end
