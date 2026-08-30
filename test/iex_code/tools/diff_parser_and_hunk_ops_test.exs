defmodule IexCode.Tools.DiffParserAndHunkOpsTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.Git.DiffParser.{FileDiff, Hunk, Line}
  alias IexCode.Tools.Git.HunkOps

  describe "DiffParser.parse/1" do
    test "handles empty or whitespace diff strings" do
      assert {:ok, []} = DiffParser.parse("")
      assert {:ok, []} = DiffParser.parse("   \n\n  \t ")
      assert {:ok, []} = DiffParser.parse(nil)
    end

    test "parses a standard single file diff with 1 hunk" do
      diff =
        "diff --git a/lib/calculator.ex b/lib/calculator.ex\n" <>
          "index 1111111..2222222 100644\n" <>
          "--- a/lib/calculator.ex\n" <>
          "+++ b/lib/calculator.ex\n" <>
          "@@ -5,4 +5,5 @@ defmodule Calculator do\n" <>
          "   def add(a, b) do\n" <>
          "-    a + b\n" <>
          "+    # Perform addition\n" <>
          "+    a + b\n" <>
          "   end\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert %FileDiff{} = file_diff
      assert file_diff.path == "lib/calculator.ex"
      assert file_diff.old_path == "lib/calculator.ex"
      assert file_diff.new_path == "lib/calculator.ex"
      assert file_diff.status == :modified
      assert file_diff.additions == 2
      assert file_diff.deletions == 1
      assert file_diff.binary? == false

      assert [hunk] = file_diff.hunks
      assert %Hunk{} = hunk
      assert hunk.id == "hunk-1"
      assert hunk.file_path == "lib/calculator.ex"
      assert hunk.old_start == 5
      assert hunk.old_lines == 4
      assert hunk.new_start == 5
      assert hunk.new_lines == 5
      assert hunk.old_count == 4
      assert hunk.new_count == 5
      assert hunk.status == :pending
      assert hunk.header == "@@ -5,4 +5,5 @@ defmodule Calculator do"

      lines = hunk.lines
      assert length(lines) == 5

      [l1, l2, l3, l4, l5] = lines

      assert l1 == %Line{type: :context, content: "  def add(a, b) do", old_num: 5, new_num: 5}
      assert l2 == %Line{type: :deletion, content: "    a + b", old_num: 6, new_num: nil}

      assert l3 == %Line{
               type: :addition,
               content: "    # Perform addition",
               old_num: nil,
               new_num: 6
             }

      assert l4 == %Line{type: :addition, content: "    a + b", old_num: nil, new_num: 7}
      assert l5 == %Line{type: :context, content: "  end", old_num: 7, new_num: 8}
    end

    test "parses a multi-hunk diff for a single file" do
      diff =
        "diff --git a/lib/app.ex b/lib/app.ex\n" <>
          "index aaaaaaa..bbbbbbb 100644\n" <>
          "--- a/lib/app.ex\n" <>
          "+++ b/lib/app.ex\n" <>
          "@@ -1,5 +1,6 @@\n" <>
          " defmodule App do\n" <>
          "-  @version \"1.0.0\"\n" <>
          "+  @version \"1.1.0\"\n" <>
          "+  @author \"IexCode\"\n" <>
          "   def start, do: :ok\n" <>
          " end\n" <>
          "@@ -20,4 +21,3 @@\n" <>
          "   def stop do\n" <>
          "-    :stopping\n" <>
          "-    :ok\n" <>
          "+    :stopped\n" <>
          "   end\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "lib/app.ex"
      assert length(file_diff.hunks) == 2
      assert file_diff.additions == 3
      assert file_diff.deletions == 3

      [hunk1, hunk2] = file_diff.hunks
      assert hunk1.id == "hunk-1"
      assert hunk1.old_start == 1
      assert hunk1.new_start == 1
      assert hunk1.old_lines == 5
      assert hunk1.new_lines == 6

      assert hunk2.id == "hunk-2"
      assert hunk2.old_start == 20
      assert hunk2.new_start == 21
      assert hunk2.old_lines == 4
      assert hunk2.new_lines == 3
    end

    test "parses a multi-file diff" do
      diff =
        "diff --git a/lib/first.ex b/lib/first.ex\n" <>
          "--- a/lib/first.ex\n" <>
          "+++ b/lib/first.ex\n" <>
          "@@ -1,3 +1,3 @@\n" <>
          " defmodule First do\n" <>
          "-  def one, do: 1\n" <>
          "+  def one, do: :one\n" <>
          " end\n" <>
          "diff --git a/lib/second.ex b/lib/second.ex\n" <>
          "--- a/lib/second.ex\n" <>
          "+++ b/lib/second.ex\n" <>
          "@@ -1,3 +1,3 @@\n" <>
          " defmodule Second do\n" <>
          "-  def two, do: 2\n" <>
          "+  def two, do: :two\n" <>
          " end\n"

      assert {:ok, [f1, f2]} = DiffParser.parse(diff)
      assert f1.path == "lib/first.ex"
      assert f1.additions == 1
      assert f1.deletions == 1

      assert f2.path == "lib/second.ex"
      assert f2.additions == 1
      assert f2.deletions == 1
    end

    test "parses new file creation (status: :added)" do
      diff =
        "diff --git a/lib/new_module.ex b/lib/new_module.ex\n" <>
          "new file mode 100644\n" <>
          "index 0000000..1234567\n" <>
          "--- /dev/null\n" <>
          "+++ b/lib/new_module.ex\n" <>
          "@@ -0,0 +1,4 @@\n" <>
          "+defmodule NewModule do\n" <>
          "+  def test, do: :ok\n" <>
          "+end\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "lib/new_module.ex"
      assert file_diff.old_path == nil
      assert file_diff.new_path == "lib/new_module.ex"
      assert file_diff.status == :added
      assert file_diff.additions == 3
      assert file_diff.deletions == 0

      [hunk] = file_diff.hunks
      assert hunk.old_start == 0
      assert hunk.old_lines == 0
      assert hunk.new_start == 1
      assert hunk.new_lines == 4

      assert Enum.all?(hunk.lines, fn l ->
               l.type == :addition and is_nil(l.old_num) and is_integer(l.new_num)
             end)
    end

    test "parses deleted file (status: :deleted)" do
      diff =
        "diff --git a/lib/obsolete.ex b/lib/obsolete.ex\n" <>
          "deleted file mode 100644\n" <>
          "index 1234567..0000000\n" <>
          "--- a/lib/obsolete.ex\n" <>
          "+++ /dev/null\n" <>
          "@@ -1,4 +0,0 @@\n" <>
          "-defmodule Obsolete do\n" <>
          "-  def unused, do: :bad\n" <>
          "-end\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "lib/obsolete.ex"
      assert file_diff.old_path == "lib/obsolete.ex"
      assert file_diff.new_path == nil
      assert file_diff.status == :deleted
      assert file_diff.additions == 0
      assert file_diff.deletions == 3

      [hunk] = file_diff.hunks
      assert hunk.old_start == 1
      assert hunk.old_lines == 4
      assert hunk.new_start == 0
      assert hunk.new_lines == 0

      assert Enum.all?(hunk.lines, fn l ->
               l.type == :deletion and is_integer(l.old_num) and is_nil(l.new_num)
             end)
    end

    test "parses renamed file (status: :renamed)" do
      diff =
        "diff --git a/lib/old_name.ex b/lib/new_name.ex\n" <>
          "similarity index 90%\n" <>
          "rename from lib/old_name.ex\n" <>
          "rename to lib/new_name.ex\n" <>
          "index 1111111..2222222 100644\n" <>
          "--- a/lib/old_name.ex\n" <>
          "+++ b/lib/new_name.ex\n" <>
          "@@ -1,3 +1,3 @@\n" <>
          "-defmodule OldName do\n" <>
          "+defmodule NewName do\n" <>
          "   def call, do: :ok\n" <>
          " end\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "lib/new_name.ex"
      assert file_diff.old_path == "lib/old_name.ex"
      assert file_diff.new_path == "lib/new_name.ex"
      assert file_diff.status == :renamed
      assert file_diff.additions == 1
      assert file_diff.deletions == 1
    end

    test "parses binary file diff (status: :binary)" do
      diff =
        "diff --git a/assets/logo.png b/assets/logo.png\n" <>
          "index 1234567..89abcdef 100644\n" <>
          "Binary files a/assets/logo.png and b/assets/logo.png differ\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "assets/logo.png"
      assert file_diff.status == :binary
      assert file_diff.binary? == true
      assert file_diff.hunks == []
    end

    test "handles missing newline at EOF marker" do
      diff =
        "diff --git a/file.txt b/file.txt\n" <>
          "--- a/file.txt\n" <>
          "+++ b/file.txt\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          " header\n" <>
          "-old eof\n" <>
          "\\ No newline at end of file\n" <>
          "+new eof\n" <>
          "\\ No newline at end of file\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks
      assert Enum.any?(hunk.lines, fn l -> l.type == :eof_newline end)
    end

    test "handles single line hunks with omitted counts (@@ -1 +1 @@)" do
      diff =
        "--- a/file.txt\n" <>
          "+++ b/file.txt\n" <>
          "@@ -1 +1 @@\n" <>
          "-foo\n" <>
          "+bar\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks
      assert hunk.old_start == 1
      assert hunk.old_lines == 1
      assert hunk.new_start == 1
      assert hunk.new_lines == 1
    end

    test "handles quoted file paths with spaces" do
      diff =
        "diff --git \"a/path with spaces/file one.ex\" \"b/path with spaces/file one.ex\"\n" <>
          "--- \"a/path with spaces/file one.ex\"\n" <>
          "+++ \"b/path with spaces/file one.ex\"\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          "-a\n" <>
          "+b\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "path with spaces/file one.ex"
      assert file_diff.old_path == "path with spaces/file one.ex"
      assert file_diff.new_path == "path with spaces/file one.ex"
    end

    test "parse!/1 returns files directly" do
      diff =
        "--- a/foo.ex\n" <>
          "+++ b/foo.ex\n" <>
          "@@ -1,1 +1,1 @@\n" <>
          "-a\n" <>
          "+b\n"

      files = DiffParser.parse!(diff)
      assert length(files) == 1
      assert hd(files).path == "foo.ex"
    end
  end

  describe "DiffParser helpers (find_hunk, format_hunk_patch, summary)" do
    test "find_hunk finds by id and index" do
      diff =
        "diff --git a/lib/test.ex b/lib/test.ex\n" <>
          "--- a/lib/test.ex\n" <>
          "+++ b/lib/test.ex\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          "-a\n" <>
          "+b\n" <>
          "@@ -10,2 +10,2 @@\n" <>
          "-c\n" <>
          "+d\n"

      {:ok, [file_diff]} = DiffParser.parse(diff)

      assert {:ok, {_, hunk1}} = DiffParser.find_hunk(file_diff, "hunk-1")
      assert hunk1.id == "hunk-1"

      assert {:ok, {_, hunk2}} = DiffParser.find_hunk(file_diff, 2)
      assert hunk2.id == "hunk-2"

      assert {:error, :hunk_not_found} = DiffParser.find_hunk(file_diff, "nonexistent")
    end

    test "format_hunk_patch formats a valid git patch" do
      diff =
        "diff --git a/lib/test.ex b/lib/test.ex\n" <>
          "--- a/lib/test.ex\n" <>
          "+++ b/lib/test.ex\n" <>
          "@@ -1,3 +1,3 @@\n" <>
          " context\n" <>
          "-old\n" <>
          "+new\n" <>
          " context2\n"

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks

      patch = DiffParser.format_hunk_patch(file_diff, hunk)
      assert patch =~ "diff --git a/lib/test.ex b/lib/test.ex"
      assert patch =~ "--- a/lib/test.ex"
      assert patch =~ "+++ b/lib/test.ex"
      assert patch =~ "@@ -1,3 +1,3 @@"
      assert patch =~ "-old"
      assert patch =~ "+new"
    end

    test "summary calculates aggregate stats across files" do
      diff =
        "diff --git a/lib/a.ex b/lib/a.ex\n" <>
          "--- a/lib/a.ex\n" <>
          "+++ b/lib/a.ex\n" <>
          "@@ -1,2 +1,3 @@\n" <>
          "-1\n" <>
          "+2\n" <>
          "+3\n" <>
          "diff --git a/lib/b.ex b/lib/b.ex\n" <>
          "--- a/lib/b.ex\n" <>
          "+++ b/lib/b.ex\n" <>
          "@@ -1,3 +1,2 @@\n" <>
          "-1\n" <>
          "-2\n" <>
          "+3\n"

      {:ok, files} = DiffParser.parse(diff)
      stats = DiffParser.summary(files)

      assert stats.files_count == 2
      assert stats.additions == 3
      assert stats.deletions == 3
      assert stats.hunks_count == 2
    end
  end

  describe "HunkOps operations in Git repository" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      # Initialize git repo in tmp_dir
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)

      # Create sample file with 30 lines
      lines = for i <- 1..30, do: "line #{i}"
      sample_file = Path.join(tmp_dir, "lib/sample.txt")
      File.mkdir_p!(Path.dirname(sample_file))
      File.write!(sample_file, Enum.join(lines, "\n") <> "\n")

      System.cmd("git", ["add", "lib/sample.txt"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "initial commit"], cd: tmp_dir)

      {:ok, %{tmp_dir: tmp_dir, sample_file: sample_file, lines: lines}}
    end

    test "accept_hunk stages an individual hunk into the index", %{tmp_dir: tmp_dir, lines: lines} do
      # Modify line 3 and line 28 (creating 2 separate hunks)
      lines2 =
        List.replace_at(lines, 2, "line 3 MODIFIED") |> List.replace_at(27, "line 28 MODIFIED")

      File.write!(Path.join(tmp_dir, "lib/sample.txt"), Enum.join(lines2, "\n") <> "\n")

      # Initially both hunks are unstaged
      assert {:ok, diff} = Git.diff(tmp_dir)
      assert diff =~ "line 3 MODIFIED"
      assert diff =~ "line 28 MODIFIED"

      # Accept (stage) hunk 1
      assert {:ok, updated_unstaged_diff} =
               HunkOps.accept_hunk(tmp_dir, "lib/sample.txt", "hunk-1")

      # Unstaged diff now only contains hunk 2 (line 28)
      refute updated_unstaged_diff =~ "line 3 MODIFIED"
      assert updated_unstaged_diff =~ "line 28 MODIFIED"

      # Staged diff contains hunk 1 (line 3)
      assert {:ok, staged_diff} = Git.diff(tmp_dir, staged: true)
      assert staged_diff =~ "line 3 MODIFIED"
      refute staged_diff =~ "line 28 MODIFIED"
    end

    test "reject_hunk discards an individual hunk from the working tree", %{
      tmp_dir: tmp_dir,
      lines: lines
    } do
      # Modify line 3 and line 28 (2 hunks)
      lines2 =
        List.replace_at(lines, 2, "line 3 MODIFIED") |> List.replace_at(27, "line 28 MODIFIED")

      File.write!(Path.join(tmp_dir, "lib/sample.txt"), Enum.join(lines2, "\n") <> "\n")

      # Reject hunk 1 (discards change to line 3)
      assert {:ok, updated_diff} = HunkOps.reject_hunk(tmp_dir, "lib/sample.txt", "hunk-1")

      # Diff now only contains line 28
      refute updated_diff =~ "line 3 MODIFIED"
      assert updated_diff =~ "line 28 MODIFIED"

      # File content has line 3 restored to original and line 28 still modified
      content = File.read!(Path.join(tmp_dir, "lib/sample.txt"))
      assert content =~ "line 3\n"
      assert content =~ "line 28 MODIFIED\n"
    end

    test "revert_file restores the HEAD version of a modified file", %{
      tmp_dir: tmp_dir,
      lines: lines
    } do
      # Modify file
      File.write!(Path.join(tmp_dir, "lib/sample.txt"), "completely changed\n")

      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, "lib/sample.txt")

      # File is restored to original 30 lines
      content = File.read!(Path.join(tmp_dir, "lib/sample.txt"))
      assert content == Enum.join(lines, "\n") <> "\n"

      assert {:ok, status} = Git.status(tmp_dir)
      assert status.clean? == true
    end

    test "revert_file deletes an untracked newly created file", %{tmp_dir: tmp_dir} do
      new_file = Path.join(tmp_dir, "lib/untracked.txt")
      File.write!(new_file, "temporary content\n")
      assert File.exists?(new_file)

      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, "lib/untracked.txt")
      refute File.exists?(new_file)
    end

    test "revert_file scope preserves the untouched index or worktree layer", %{
      tmp_dir: tmp_dir
    } do
      file = Path.join(tmp_dir, "lib/sample.txt")
      staged_content = "staged layer\n"
      worktree_content = "worktree layer\n"
      File.write!(file, staged_content)
      assert :ok = Git.stage("lib/sample.txt", tmp_dir)
      File.write!(file, worktree_content)

      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, "lib/sample.txt", :unstaged)
      assert File.read!(file) == staged_content
      assert {:ok, status} = Git.status(tmp_dir)
      assert Enum.map(status.staged, & &1.path) == ["lib/sample.txt"]

      File.write!(file, worktree_content)
      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, "lib/sample.txt", :staged)
      assert File.read!(file) == worktree_content
      assert {:ok, status} = Git.status(tmp_dir)
      assert status.staged == []
      assert Enum.map(status.unstaged, & &1.path) == ["lib/sample.txt"]
    end

    test "revert_file expected identity rejects a same-path replacement", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "lib/sample.txt")
      File.write!(file, "value AAA\n")
      {:ok, canonical} = IexCode.WorkspacePath.resolve(tmp_dir, "lib/sample.txt")
      {:ok, stat} = File.lstat(file)

      identity = %{
        canonical: canonical,
        type: stat.type,
        size: stat.size,
        mtime: stat.mtime,
        inode: stat.inode,
        content_identity:
          {:regular,
           :sha256
           |> :crypto.hash(:erlang.term_to_binary("value AAA\n"))
           |> Base.encode16(case: :lower)}
      }

      File.write!(file, "value BBB\n")

      assert {:error, :stale_git_snapshot} =
               HunkOps.revert_file(tmp_dir, "lib/sample.txt", :unstaged,
                 expected_identity: identity
               )

      assert File.read!(file) == "value BBB\n"
    end

    test "accept_all_hunks stages the entire file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "lib/sample.txt"), "new content\n")

      assert {:ok, :accepted} = HunkOps.accept_all_hunks(tmp_dir, "lib/sample.txt")

      assert {:ok, status} = Git.status(tmp_dir)
      assert Enum.any?(status.staged, &(&1.path == "lib/sample.txt"))
    end

    test "returns error when hunk is not found", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "lib/sample.txt"), "modified\n")

      assert {:error, {:hunk_not_found, "nonexistent-hunk"}} =
               HunkOps.accept_hunk(tmp_dir, "lib/sample.txt", "nonexistent-hunk")
    end

    test "revert_hunk and reject_all_hunks aliases work identically", %{
      tmp_dir: tmp_dir,
      lines: lines
    } do
      lines2 = List.replace_at(lines, 2, "line 3 MODIFIED")
      File.write!(Path.join(tmp_dir, "lib/sample.txt"), Enum.join(lines2, "\n") <> "\n")

      # Test revert_hunk alias
      assert {:ok, _} = HunkOps.revert_hunk(tmp_dir, "lib/sample.txt", "hunk-1")
      content = File.read!(Path.join(tmp_dir, "lib/sample.txt"))
      assert content == Enum.join(lines, "\n") <> "\n"

      # Test reject_all_hunks alias
      File.write!(Path.join(tmp_dir, "lib/sample.txt"), "changed all\n")
      assert {:ok, :reverted} = HunkOps.reject_all_hunks(tmp_dir, "lib/sample.txt")
      content2 = File.read!(Path.join(tmp_dir, "lib/sample.txt"))
      assert content2 == Enum.join(lines, "\n") <> "\n"
    end

    test "accept_hunk with mode: :apply_to_file applies patch to working copy", %{
      tmp_dir: tmp_dir
    } do
      target_file = Path.join(tmp_dir, "lib/external.txt")
      File.write!(target_file, "original first line\noriginal second line\n")

      diff =
        "diff --git a/lib/external.txt b/lib/external.txt\n" <>
          "--- a/lib/external.txt\n" <>
          "+++ b/lib/external.txt\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          " original first line\n" <>
          "-original second line\n" <>
          "+updated second line\n"

      assert {:ok, _} =
               HunkOps.accept_hunk(tmp_dir, "lib/external.txt", "hunk-1",
                 diff: diff,
                 mode: :apply_to_file
               )

      content = File.read!(target_file)
      assert content =~ "updated second line"
    end
  end

  describe "DiffParser edge cases" do
    test "parses diffs with whitespace-only line additions" do
      diff =
        "--- a/lib/code.ex\n" <>
          "+++ b/lib/code.ex\n" <>
          "@@ -1,2 +1,3 @@\n" <>
          " def test do\n" <>
          "+\n" <>
          "   :ok\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.additions == 1
      assert [hunk] = file_diff.hunks
      assert Enum.any?(hunk.lines, fn l -> l.type == :addition and l.content == "" end)
    end

    test "parses diff with no context lines (pure replacement)" do
      diff =
        "--- a/file.txt\n" <>
          "+++ b/file.txt\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          "-line 1\n" <>
          "-line 2\n" <>
          "+new 1\n" <>
          "+new 2\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.additions == 2
      assert file_diff.deletions == 2
      [hunk] = file_diff.hunks
      assert length(hunk.lines) == 4
    end

    test "handles malformed or empty hunk header gracefully" do
      diff =
        "--- a/file.txt\n" <>
          "+++ b/file.txt\n" <>
          "@@ not a valid header @@\n" <>
          "-foo\n" <>
          "+bar\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.hunks == []
    end
  end
end
