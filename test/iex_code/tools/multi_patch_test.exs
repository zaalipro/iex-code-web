defmodule IexCode.Tools.MultiPatchTest do
  use IexCode.DataCase, async: false
  alias IexCode.Tools.MultiPatch

  @tag :tmp_dir
  test "Tier 2: exact match replacement", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.ex")
    File.write!(path, "def hello, do: :world\n")

    patches = [
      %{path: "test.ex", target: ":world", replacement: ":universe"}
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert summary.applied == 1
    assert summary.tiers_used.exact == 1
    assert File.read!(path) == "def hello, do: :universe\n"
    assert summary.diff =~ "-def hello, do: :world"
    assert summary.diff =~ "+def hello, do: :universe"
  end

  @tag :tmp_dir
  test "Tier 3: fuzzy match with indentation and spacing differences", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "indent.ex")
    # File has 4 spaces
    File.write!(path, "defmodule Foo do\n    def run do\n        :ok\n    end\nend\n")

    # Patch has 2 spaces
    patches = [
      %{
        path: "indent.ex",
        target: "  def run do\n    :ok\n  end",
        replacement: "  def run do\n    :modified\n  end"
      }
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert summary.applied == 1
    assert summary.tiers_used.fuzzy == 1
    content = File.read!(path)
    assert content =~ ":modified"
    assert content =~ "    def run do"
  end

  @tag :tmp_dir
  test "Atomic Rollback: reverts all changes if any patch in batch fails", %{tmp_dir: tmp_dir} do
    f1 = Path.join(tmp_dir, "f1.ex")
    f2 = Path.join(tmp_dir, "f2.ex")
    File.write!(f1, "defmodule F1 do\n  def orig1, do: 1\nend\n")
    File.write!(f2, "defmodule F2 do\n  def orig2, do: 2\nend\n")

    patches = [
      %{path: "f1.ex", target: "orig1", replacement: "new1"},
      %{path: "f2.ex", target: "non_existent_target_symbol", replacement: "new2"}
    ]

    assert {:error, {:target_not_found, "f2.ex", _}} = MultiPatch.apply_patches(tmp_dir, patches)

    # f1 MUST NOT be modified
    assert File.read!(f1) == "defmodule F1 do\n  def orig1, do: 1\nend\n"
    assert File.read!(f2) == "defmodule F2 do\n  def orig2, do: 2\nend\n"
  end

  @tag :tmp_dir
  test "Syntax Error check prevents broken code from applying", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "syntax.ex")
    File.write!(path, "defmodule Syntax do\n  def ok, do: :ok\nend\n")

    patches = [
      %{path: "syntax.ex", target: "def ok, do: :ok", replacement: "def ok, do: ((("}
    ]

    assert {:error, {:syntax_error, "syntax.ex", _}} = MultiPatch.apply_patches(tmp_dir, patches)
    assert File.read!(path) =~ "def ok, do: :ok"
  end

  @tag :tmp_dir
  test "preview_patches/3 generates diff without writing to disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "preview.ex")
    File.write!(path, "def value, do: 100\n")

    patches = [
      %{path: "preview.ex", target: "100", replacement: "200"}
    ]

    assert {:ok, %{diff: diff, patches: planned}} = MultiPatch.preview_patches(tmp_dir, patches)
    assert length(planned) == 1
    assert diff =~ "-def value, do: 100"
    assert diff =~ "+def value, do: 200"

    # Disk remains unchanged
    assert File.read!(path) == "def value, do: 100\n"
  end

  @tag :tmp_dir
  test "rollback/1 restores previous state from snapshot", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "rollback.ex")
    File.write!(path, "defmodule Rollback do\n  def state, do: :v1\nend\n")

    patches = [
      %{path: "rollback.ex", target: ":v1", replacement: ":v2"}
    ]

    assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
    assert File.read!(path) =~ ":v2"

    assert {:ok, %{restored_files: ["rollback.ex"]}} = MultiPatch.rollback(summary.transaction_id)
    assert File.read!(path) =~ ":v1"
  end
end
