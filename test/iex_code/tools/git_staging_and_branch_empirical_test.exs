defmodule IexCode.Tools.GitStagingAndBranchEmpiricalTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.Git

  setup do
    tmp_base =
      Path.join(
        System.tmp_dir!(),
        "git_empirical_#{System.system_time(:microsecond)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_base)

    repo_dir = Path.join(tmp_base, "repo")
    File.mkdir_p!(repo_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Empirical Challenger"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "challenger@iexcode.local"], cd: repo_dir)

    on_exit(fn ->
      File.rm_rf(tmp_base)
    end)

    {:ok, %{repo_dir: repo_dir, tmp_base: tmp_base}}
  end

  describe "Git.stage/2 and Git.unstage/2 with 2 string arguments" do
    test "Git.stage(repo, file) and Git.unstage(repo, file) execute cleanly with 2 string arguments",
         %{repo_dir: repo_dir} do
      file_rel = "lib/module_a.ex"
      file_full = Path.join(repo_dir, file_rel)
      File.mkdir_p!(Path.dirname(file_full))
      File.write!(file_full, "defmodule ModuleA, do: :v1\n")

      # Initially untracked
      assert {:ok, status1} = Git.status(repo_dir)
      assert file_rel in status1.untracked
      assert status1.staged == []

      # 1. Call Git.stage(repo, file) -> (repo_dir, "lib/module_a.ex")
      assert :ok = Git.stage(repo_dir, file_rel)

      assert {:ok, status2} = Git.status(repo_dir)
      assert Enum.any?(status2.staged, &(&1.path == file_rel))

      # 2. Call Git.unstage(repo, file) -> (repo_dir, "lib/module_a.ex")
      assert :ok = Git.unstage(repo_dir, file_rel)

      assert {:ok, status3} = Git.status(repo_dir)
      assert status3.staged == []
      assert file_rel in status3.untracked
    end

    test "Git.stage(file, repo) and Git.unstage(file, repo) execute cleanly with reversed string arguments",
         %{repo_dir: repo_dir} do
      file_rel = "lib/module_b.ex"
      file_full = Path.join(repo_dir, file_rel)
      File.mkdir_p!(Path.dirname(file_full))
      File.write!(file_full, "defmodule ModuleB, do: :v1\n")

      # 1. Call Git.stage(file, repo) -> ("lib/module_b.ex", repo_dir)
      assert :ok = Git.stage(file_rel, repo_dir)

      assert {:ok, status1} = Git.status(repo_dir)
      assert Enum.any?(status1.staged, &(&1.path == file_rel))

      # 2. Call Git.unstage(file, repo) -> ("lib/module_b.ex", repo_dir)
      assert :ok = Git.unstage(file_rel, repo_dir)

      assert {:ok, status2} = Git.status(repo_dir)
      assert status2.staged == []
    end

    test "Git.stage(repo, file) and Git.unstage(repo, file) handle modified tracked files",
         %{repo_dir: repo_dir} do
      file_rel = "lib/module_c.ex"
      file_full = Path.join(repo_dir, file_rel)
      File.mkdir_p!(Path.dirname(file_full))
      File.write!(file_full, "defmodule ModuleC, do: :v1\n")

      # Stage and commit
      assert :ok = Git.stage(repo_dir, file_rel)
      assert {:ok, _} = Git.commit("chore: init module c", repo_dir)

      # Modify file
      File.write!(file_full, "defmodule ModuleC, do: :v2\n")

      # Verify unstaged status
      assert {:ok, status1} = Git.status(repo_dir)
      assert Enum.any?(status1.unstaged, &(&1.path == file_rel and &1.status == :modified))
      assert status1.staged == []

      # Stage using (repo, file)
      assert :ok = Git.stage(repo_dir, file_rel)
      assert {:ok, status2} = Git.status(repo_dir)
      assert Enum.any?(status2.staged, &(&1.path == file_rel and &1.status == :modified))

      # Unstage using (repo, file)
      assert :ok = Git.unstage(repo_dir, file_rel)
      assert {:ok, status3} = Git.status(repo_dir)
      assert status3.staged == []
      assert Enum.any?(status3.unstaged, &(&1.path == file_rel and &1.status == :modified))
    end

    test "Git.stage(repo, file) and Git.unstage(repo, file) handle deleted files",
         %{repo_dir: repo_dir} do
      file_rel = "lib/module_d.ex"
      file_full = Path.join(repo_dir, file_rel)
      File.mkdir_p!(Path.dirname(file_full))
      File.write!(file_full, "defmodule ModuleD, do: :v1\n")

      # Stage and commit
      assert :ok = Git.stage(repo_dir, file_rel)
      assert {:ok, _} = Git.commit("chore: init module d", repo_dir)

      # Delete file
      File.rm!(file_full)

      # Stage deletion using (repo, file)
      assert :ok = Git.stage(repo_dir, file_rel)
      assert {:ok, status1} = Git.status(repo_dir)
      assert Enum.any?(status1.staged, &(&1.path == file_rel and &1.status == :deleted))

      # Unstage deletion using (repo, file)
      assert :ok = Git.unstage(repo_dir, file_rel)
      assert {:ok, status2} = Git.status(repo_dir)
      assert status2.staged == []
      assert Enum.any?(status2.unstaged, &(&1.path == file_rel and &1.status == :deleted))
    end
  end

  describe "Git branch listing and toggle rendering contract" do
    test "branches/1 returns maps with :current? boolean key and never raises KeyError on b.current?",
         %{repo_dir: repo_dir} do
      File.write!(Path.join(repo_dir, "init.txt"), "init\n")
      Git.stage(repo_dir, "init.txt")
      Git.commit("chore: init", repo_dir)

      Git.create_branch(repo_dir, "feature/alpha")
      Git.create_branch(repo_dir, "feature/beta")
      Git.switch_branch(repo_dir, "main")

      assert {:ok, branches} = Git.branches(repo_dir)
      assert is_list(branches)
      assert length(branches) >= 3

      for b <- branches do
        assert Map.has_key?(b, :name)
        assert Map.has_key?(b, :current?)
        assert is_boolean(b.current?)
        # Direct struct/map key access without KeyError
        assert b.current? in [true, false]
        assert is_binary(b.name)
      end

      # Verify exactly one active branch is main
      current_branches = Enum.filter(branches, & &1.current?)
      assert length(current_branches) == 1
      assert hd(current_branches).name == "main"
    end
  end
end
