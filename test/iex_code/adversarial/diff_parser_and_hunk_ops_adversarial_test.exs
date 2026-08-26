defmodule IexCode.Adversarial.DiffParserAndHunkOpsAdversarialTest do
  @moduledoc """
  Adversarial Stress Test & Edge Case Harness for DiffParser and HunkOps.
  Evaluates resilience against malformed diffs, missing EOF newlines, multi-hunk conflicts,
  out-of-order hunk application, unicode/emoji filenames, CRLF line endings, and concurrent operations.
  """
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.Git.HunkOps

  describe "Adversarial DiffParser: Malformed Diffs & Fuzz Ingestion" do
    test "gracefully handles malformed hunk headers without crashing" do
      malformed_headers = [
        "@@ not a header @@\n-old\n+new\n",
        "@@ - + @@\n-old\n+new\n",
        "@@ --1,2 ++3,4 @@\n-old\n+new\n",
        "@@ -1,abc +1,def @@\n-old\n+new\n",
        "@@ -0,0 +0,0 @@\n",
        "@@ -99999999999999999,99999999999999999 +99999999999999999,99999999999999999 @@\n-a\n+b\n",
        "@@ @@\n-old\n+new\n",
        "@@ -1 + @@\n-a\n+b\n",
        "@@ -1,2 @@\n-a\n+b\n"
      ]

      for header <- malformed_headers do
        diff = "diff --git a/test.ex b/test.ex\n--- a/test.ex\n+++ b/test.ex\n" <> header
        assert {:ok, file_diffs} = DiffParser.parse(diff)
        assert is_list(file_diffs)
        # Never raises or crashes
      end
    end

    test "fuzzes DiffParser with random binary and corrupted text mutations" do
      base_diff = """
      diff --git a/lib/core.ex b/lib/core.ex
      index 1234567..89abcde 100644
      --- a/lib/core.ex
      +++ b/lib/core.ex
      @@ -10,6 +10,7 @@ defmodule Core do
         def run do
       -    :old_val
       +    :new_val
       +    :extra_val
           :ok
         end
       end
      """

      # Generate 100 mutated variations
      :rand.seed(:exsss, {1234, 5678, 9012})

      for i <- 1..100 do
        corrupted =
          case rem(i, 8) do
            0 -> String.slice(base_diff, 0, rem(i * 7, byte_size(base_diff)))
            1 -> base_diff <> <<0, 255, 128, 0, 1, 2>>
            2 -> String.replace(base_diff, "@@", "@@ corrupted @@")
            3 -> String.replace(base_diff, "--- a/", "--- ??? /")
            4 -> "\r\n\r\n" <> base_diff <> "\r\n\r\n"
            5 -> String.replace(base_diff, "\n", "\r\n")
            6 -> String.replace(base_diff, "+", "+++ ")
            7 -> String.replace(base_diff, "-", "--- ")
          end

        # Must always return {:ok, list} without throwing or raising
        assert {:ok, result} = DiffParser.parse(corrupted)
        assert is_list(result)
      end
    end

    test "parses mixed CRLF / LF line endings consistently" do
      diff_crlf =
        "diff --git a/lib/crlf.ex b/lib/crlf.ex\r\n" <>
          "--- a/lib/crlf.ex\r\n" <>
          "+++ b/lib/crlf.ex\r\n" <>
          "@@ -1,3 +1,3 @@\r\n" <>
          " line 1\r\n" <>
          "-line 2 old\r\n" <>
          "+line 2 new\r\n" <>
          " line 3\r\n"

      assert {:ok, [file_diff]} = DiffParser.parse(diff_crlf)
      assert file_diff.path == "lib/crlf.ex"
      assert file_diff.additions == 1
      assert file_diff.deletions == 1
      assert [hunk] = file_diff.hunks
      assert length(hunk.lines) == 4

      # Verify contents do not contain trailing \r
      for line <- hunk.lines do
        refute String.ends_with?(line.content, "\r")
      end
    end

    test "handles complex multi-file diffs with blank lines and binary files interleaved" do
      diff = """
      diff --git a/lib/first.ex b/lib/first.ex
      --- a/lib/first.ex
      +++ b/lib/first.ex
      @@ -1,2 +1,2 @@
      -a
      +b


      diff --git a/assets/image.png b/assets/image.png
      Binary files a/assets/image.png and b/assets/image.png differ

      diff --git a/lib/second.ex b/lib/second.ex
      new file mode 100644
      --- /dev/null
      +++ b/lib/second.ex
      @@ -0,0 +1,2 @@
      +defmodule Second do
      +end
      """

      assert {:ok, file_diffs} = DiffParser.parse(diff)
      assert length(file_diffs) == 3

      [f1, f2, f3] = file_diffs
      assert f1.path == "lib/first.ex"
      assert f1.status == :modified
      assert f2.path == "assets/image.png"
      assert f2.status == :binary
      assert f2.binary? == true
      assert f3.path == "lib/second.ex"
      assert f3.status == :added
    end
  end

  describe "Adversarial DiffParser: EOF Newline & Boundary Conditions" do
    test "correctly parses EOF newline markers on additions and deletions" do
      diff = """
      diff --git a/file.txt b/file.txt
      --- a/file.txt
      +++ b/file.txt
      @@ -1,2 +1,2 @@
       header
      -old eof line
      \\ No newline at end of file
      +new eof line
      \\ No newline at end of file
      """

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert [hunk] = file_diff.hunks

      eof_lines = Enum.filter(hunk.lines, &(&1.type == :eof_newline))
      assert length(eof_lines) == 2

      # format_hunk_patch should preserve EOF newline markers
      patch = DiffParser.format_hunk_patch(file_diff, hunk)
      assert patch =~ "\\ No newline at end of file"
    end

    test "handles single-line replacement without preceding or succeeding context" do
      diff = """
      --- a/single.txt
      +++ b/single.txt
      @@ -1 +1 @@
      -only line
      +replacement line
      """

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert [hunk] = file_diff.hunks
      assert hunk.old_start == 1
      assert hunk.old_lines == 1
      assert hunk.new_start == 1
      assert hunk.new_lines == 1
      assert length(hunk.lines) == 2
    end
  end

  describe "Adversarial DiffParser: Unicode, Emojis, and Quoted Filepaths" do
    test "parses UTF-8 filenames, emojis, and unicode content" do
      diff = """
      diff --git "a/lib/\xF0\x9F\x9A\x80_rocket/\xE2\x9C\xA8_sparkle.ex" "b/lib/\xF0\x9F\x9A\x80_rocket/\xE2\x9C\xA8_sparkle.ex"
      --- "a/lib/\xF0\x9F\x9A\x80_rocket/\xE2\x9C\xA8_sparkle.ex"
      +++ "b/lib/\xF0\x9F\x9A\x80_rocket/\xE2\x9C\xA8_sparkle.ex"
      @@ -1,3 +1,3 @@
       defmodule Rocket.Sparkle do
      -  @greeting "Hello World"
      +  @greeting "\xD7\xA9\xD7\x9C\xD7\x95\xD7\x9D \xD8\xB9\xD9\x84\xD9\x8A\xD9\x83\xD9\x85 \xE4\xBD\xA0\xE5\xA5\xBD \xF0\x9F\x8C\x8D"
       end
      """

      assert {:ok, [file_diff]} = DiffParser.parse(diff)
      assert file_diff.path == "lib/🚀_rocket/✨_sparkle.ex"
      assert [hunk] = file_diff.hunks
      assert Enum.any?(hunk.lines, fn l -> l.content =~ "שלום" and l.content =~ "🌍" end)
    end
  end

  describe "Adversarial HunkOps: Multi-Hunk Out-of-Order Operations & Git Stress" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      # Initialize git repo in tmp_dir
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Adversarial Tester"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "adv@iexcode.test"], cd: tmp_dir)

      # Create a 60-line structured file with 5 distinct sections
      lines =
        for i <- 1..60 do
          case i do
            5 -> "SECTION_1_ORIGINAL"
            18 -> "SECTION_2_ORIGINAL"
            32 -> "SECTION_3_ORIGINAL"
            45 -> "SECTION_4_ORIGINAL"
            58 -> "SECTION_5_ORIGINAL"
            _ -> "line_#{i}: stable_content_value_#{i}"
          end
        end

      file_rel = "lib/multi_section.txt"
      file_abs = Path.join(tmp_dir, file_rel)
      File.mkdir_p!(Path.dirname(file_abs))
      File.write!(file_abs, Enum.join(lines, "\n") <> "\n")

      {_, 0} = System.cmd("git", ["add", file_rel], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial 5 section commit"], cd: tmp_dir)

      %{tmp_dir: tmp_dir, file_rel: file_rel, file_abs: file_abs, original_lines: lines}
    end

    test "executes non-sequential hunk acceptance and rejection across 5 distinct hunks", %{
      tmp_dir: tmp_dir,
      file_rel: file_rel,
      file_abs: file_abs
    } do
      # Mutate all 5 sections to create 5 distinct hunks
      content = File.read!(file_abs)

      mutated =
        content
        |> String.replace("SECTION_1_ORIGINAL", "SECTION_1_MODIFIED")
        |> String.replace("SECTION_2_ORIGINAL", "SECTION_2_MODIFIED")
        |> String.replace("SECTION_3_ORIGINAL", "SECTION_3_MODIFIED")
        |> String.replace("SECTION_4_ORIGINAL", "SECTION_4_MODIFIED")
        |> String.replace("SECTION_5_ORIGINAL", "SECTION_5_MODIFIED")

      File.write!(file_abs, mutated)

      # Verify 5 hunks generated by Git.diff
      assert {:ok, initial_diff} = Git.diff(tmp_dir, paths: [file_rel])
      assert {:ok, [file_diff]} = DiffParser.parse(initial_diff)
      assert length(file_diff.hunks) == 5

      # Step 1: Accept Hunk 3 (middle hunk) -> Stages section 3
      assert {:ok, diff_after_step1} = HunkOps.accept_hunk(tmp_dir, file_rel, "hunk-3")

      # Unstaged diff should no longer contain section 3
      refute diff_after_step1 =~ "SECTION_3_MODIFIED"
      assert diff_after_step1 =~ "SECTION_1_MODIFIED"
      assert diff_after_step1 =~ "SECTION_5_MODIFIED"

      # Staged diff must contain section 3
      assert {:ok, staged_1} = Git.diff(tmp_dir, paths: [file_rel], staged: true)
      assert staged_1 =~ "SECTION_3_MODIFIED"
      refute staged_1 =~ "SECTION_1_MODIFIED"

      # Step 2: Reject Hunk 1 (discards section 1 change from working copy)
      assert {:ok, diff_after_step2} = HunkOps.reject_hunk(tmp_dir, file_rel, "hunk-1")
      refute diff_after_step2 =~ "SECTION_1_MODIFIED"

      # Check working copy: section 1 should be restored to original!
      current_content = File.read!(file_abs)
      assert current_content =~ "SECTION_1_ORIGINAL"
      refute current_content =~ "SECTION_1_MODIFIED"
      assert current_content =~ "SECTION_2_MODIFIED"
      assert current_content =~ "SECTION_3_MODIFIED"
      assert current_content =~ "SECTION_4_MODIFIED"
      assert current_content =~ "SECTION_5_MODIFIED"

      # Step 3: Accept Hunk 5 (the last hunk)
      # Note: with hunk 1 rejected and hunk 3 staged, unstaged hunks are now section 2, section 4, section 5
      # 3rd unstaged hunk is section 5
      assert {:ok, _} = HunkOps.accept_hunk(tmp_dir, file_rel, "hunk-3")

      # Step 4: Revert entire file (discard all remaining unstaged & staged)
      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, file_rel)

      # Working tree must be 100% clean and match original initial commit
      assert {:ok, status} = Git.status(tmp_dir)
      assert status.clean? == true
      assert File.read!(file_abs) =~ "SECTION_1_ORIGINAL"
      assert File.read!(file_abs) =~ "SECTION_2_ORIGINAL"
      assert File.read!(file_abs) =~ "SECTION_3_ORIGINAL"
      assert File.read!(file_abs) =~ "SECTION_4_ORIGINAL"
      assert File.read!(file_abs) =~ "SECTION_5_ORIGINAL"
    end

    test "handles fallback revert in-memory when git apply reverse fails due to line drift", %{
      tmp_dir: tmp_dir,
      file_rel: file_rel,
      file_abs: file_abs
    } do
      # Modify section 1
      content = File.read!(file_abs)
      mutated = String.replace(content, "SECTION_1_ORIGINAL", "SECTION_1_TARGET_MUTATION")
      File.write!(file_abs, mutated)

      assert {:ok, diff} = Git.diff(tmp_dir, paths: [file_rel])

      # Insert lines at the top of the file to cause line numbers and git apply index to drift
      shifted_content = "# Line drift addition\n# Another drift line\n" <> File.read!(file_abs)
      File.write!(file_abs, shifted_content)

      # Rejection using the previously computed diff causes fallback to in-memory MultiPatch replacement
      assert {:ok, _updated_diff} = HunkOps.reject_hunk(tmp_dir, file_rel, "hunk-1", diff: diff)

      # File should have SECTION_1_ORIGINAL restored while preserving the top drift lines
      final_content = File.read!(file_abs)
      assert final_content =~ "SECTION_1_ORIGINAL"
      assert final_content =~ "# Line drift addition"
      refute final_content =~ "SECTION_1_TARGET_MUTATION"
    end

    test "revert_file handles deeply nested untracked files and directories", %{tmp_dir: tmp_dir} do
      deep_untracked = Path.join(tmp_dir, "lib/nested/deep/structure/untracked_mod.ex")
      File.mkdir_p!(Path.dirname(deep_untracked))
      File.write!(deep_untracked, "defmodule UntrackedMod do\nend")
      assert File.exists?(deep_untracked)

      assert {:ok, :reverted} =
               HunkOps.revert_file(tmp_dir, "lib/nested/deep/structure/untracked_mod.ex")

      refute File.exists?(deep_untracked)
    end

    test "revert_file handles deleted tracked files (restores from HEAD)", %{
      tmp_dir: tmp_dir,
      file_rel: file_rel,
      file_abs: file_abs
    } do
      File.rm!(file_abs)
      refute File.exists?(file_abs)

      assert {:ok, :reverted} = HunkOps.revert_file(tmp_dir, file_rel)
      assert File.exists?(file_abs)
      assert File.read!(file_abs) =~ "SECTION_1_ORIGINAL"
    end

    test "races 20 concurrent HunkOps and DiffParser read/query operations without crash", %{
      tmp_dir: tmp_dir,
      file_rel: file_rel
    } do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                Git.diff(tmp_dir, paths: [file_rel])

              1 ->
                Git.status(tmp_dir)

              2 ->
                {:ok, diff} = Git.diff(tmp_dir)
                DiffParser.parse(diff)
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 20

      for res <- results do
        assert {:ok, _} = res
      end
    end
  end
end
