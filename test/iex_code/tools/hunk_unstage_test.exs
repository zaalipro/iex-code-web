defmodule IexCode.Tools.HunkUnstageTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.HunkOps
  alias IexCode.Tools.Git.DiffParser

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo_dir = Path.join(tmp_dir, "hunk_repo")
    File.mkdir_p!(repo_dir)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    # Create initial file with sufficient separation for 2 distinct hunks
    calc_path = Path.join(repo_dir, "lib/calculator.ex")
    File.mkdir_p!(Path.dirname(calc_path))

    initial_content = """
    defmodule Calculator do
      # Section 1: Addition
      def add(a, b) do
        a + b
      end

      # Separator padding lines to ensure distinct diff hunks
      def noop1, do: :ok
      def noop2, do: :ok
      def noop3, do: :ok
      def noop4, do: :ok
      def noop5, do: :ok
      def noop6, do: :ok
      def noop7, do: :ok
      def noop8, do: :ok

      # Section 2: Subtraction
      def subtract(a, b) do
        a - b
      end
    end
    """

    File.write!(calc_path, initial_content)
    {_, 0} = System.cmd("git", ["add", "lib/calculator.ex"], cd: repo_dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit with calculator"], cd: repo_dir)

    {:ok, %{repo_dir: repo_dir, calc_path: calc_path}}
  end

  # ============================================================================
  # 1. Granular Hunk Unstaging Functionality
  # ============================================================================
  describe "HunkOps.unstage_hunk/4" do
    test "unstages a single hunk while keeping other hunks staged in the Git index", %{
      repo_dir: repo_dir,
      calc_path: calc_path
    } do
      # Modify both Section 1 and Section 2
      modified_content = """
      defmodule Calculator do
        # Section 1: Addition with Logging
        def add(a, b) do
          IO.puts("Adding")
          a + b
        end

        # Separator padding lines to ensure distinct diff hunks
        def noop1, do: :ok
        def noop2, do: :ok
        def noop3, do: :ok
        def noop4, do: :ok
        def noop5, do: :ok
        def noop6, do: :ok
        def noop7, do: :ok
        def noop8, do: :ok

        # Section 2: Subtraction with Validation
        def subtract(a, b) do
          if is_number(a) and is_number(b), do: a - b, else: 0
        end
      end
      """

      File.write!(calc_path, modified_content)

      # Stage the entire file so both hunks are in the index
      assert :ok = Git.stage("lib/calculator.ex", repo_dir)

      # Verify staged diff contains both modifications
      assert {:ok, staged_diff} = Git.diff(repo_dir, staged: true)
      assert staged_diff =~ "Adding"
      assert staged_diff =~ "Validation"

      # Parse staged diff and verify 2 distinct hunks exist
      assert {:ok, [file_diff]} = DiffParser.parse(staged_diff)
      assert length(file_diff.hunks) == 2

      # Unstage only the first hunk (hunk-1)
      assert {:ok, _remaining_diff} =
               HunkOps.unstage_hunk(repo_dir, "lib/calculator.ex", "hunk-1")

      # Staged diff should now only contain Section 2 modification
      assert {:ok, new_staged_diff} = Git.diff(repo_dir, staged: true)
      assert new_staged_diff =~ "Validation"
      refute new_staged_diff =~ "Adding"

      # Unstaged (working) diff should now contain Section 1 modification
      assert {:ok, unstaged_diff} = Git.diff(repo_dir)
      assert unstaged_diff =~ "Adding"
      refute unstaged_diff =~ "Validation"

      # Working tree file on disk remains unchanged (both modifications intact)
      disk_content = File.read!(calc_path)
      assert disk_content =~ "Adding"
      assert disk_content =~ "Validation"
    end

    test "supports numeric 1-based integer hunk index for unstaging", %{
      repo_dir: repo_dir,
      calc_path: calc_path
    } do
      modified_content = """
      defmodule Calculator do
        # Section 1: Modified Header
        def add(a, b) do
          a + b
        end

        # Separator padding lines to ensure distinct diff hunks
        def noop1, do: :ok
        def noop2, do: :ok
        def noop3, do: :ok
        def noop4, do: :ok
        def noop5, do: :ok
        def noop6, do: :ok
        def noop7, do: :ok
        def noop8, do: :ok

        # Section 2: Modified Subtraction
        def subtract(a, b) do
          (a - b) * 1
        end
      end
      """

      File.write!(calc_path, modified_content)
      assert :ok = Git.stage("lib/calculator.ex", repo_dir)

      # Unstage using integer index 1
      assert {:ok, _} = HunkOps.unstage_hunk(repo_dir, "lib/calculator.ex", 1)

      assert {:ok, staged_diff} = Git.diff(repo_dir, staged: true)
      assert staged_diff =~ "Modified Subtraction"
      refute staged_diff =~ "Modified Header"
    end
  end

  # ============================================================================
  # 2. Edge Cases and Boundary Conditions
  # ============================================================================
  describe "HunkOps.unstage_hunk/4 Error & Boundary Cases" do
    test "returns structured error when no staged diff exists for the file", %{repo_dir: repo_dir} do
      # Index is clean
      assert {:error, _reason} = HunkOps.unstage_hunk(repo_dir, "lib/calculator.ex", "hunk-1")
    end

    test "returns error when requested hunk_id does not exist", %{
      repo_dir: repo_dir,
      calc_path: calc_path
    } do
      File.write!(calc_path, "defmodule Calculator, do: :modified\n")
      assert :ok = Git.stage("lib/calculator.ex", repo_dir)

      assert {:error, {:hunk_not_found, "hunk-999"}} =
               HunkOps.unstage_hunk(repo_dir, "lib/calculator.ex", "hunk-999")
    end

    test "returns error when file does not exist in repo", %{repo_dir: repo_dir} do
      assert {:error, _reason} =
               HunkOps.unstage_hunk(repo_dir, "lib/does_not_exist.ex", "hunk-1")
    end
  end
end
