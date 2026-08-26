defmodule IexCode.WorkspacePathTest do
  use ExUnit.Case, async: true

  alias IexCode.WorkspacePath

  @tag :tmp_dir
  test "allows relative and absolute paths canonically inside the workspace", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    nested = Path.join(root, "lib")
    File.mkdir_p!(nested)
    file = Path.join(nested, "inside.ex")
    File.write!(file, ":ok")

    assert {:ok, ^file} = WorkspacePath.resolve(root, "lib/inside.ex")
    assert {:ok, ^file} = WorkspacePath.resolve(root, file)

    missing = Path.join(nested, "new.ex")
    assert {:ok, ^missing} = WorkspacePath.resolve(root, "lib/new.ex")
  end

  @tag :tmp_dir
  test "rejects traversal and absolute paths outside the workspace", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(outside, "outside")

    assert {:error, :outside_workspace} = WorkspacePath.resolve(root, "../outside.txt")
    assert {:error, :outside_workspace} = WorkspacePath.resolve(root, "sub/../inside.txt")
    assert {:error, :outside_workspace} = WorkspacePath.resolve(root, outside)
  end

  @tag :tmp_dir
  test "rejects existing and missing descendants through an outward symlink", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:error, :outside_workspace} = WorkspacePath.resolve(root, "escape/secret.txt")
    assert {:error, :outside_workspace} = WorkspacePath.resolve(root, "escape/new.txt")
  end

  @tag :tmp_dir
  test "allows inward symlinks but returns the canonical target", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    target = Path.join(root, "real")
    File.mkdir_p!(target)
    File.ln_s!("real", Path.join(root, "alias"))

    expected = Path.join(target, "new.txt")
    assert {:ok, ^expected} = WorkspacePath.resolve(root, "alias/new.txt")
  end

  @tag :tmp_dir
  test "canonicalizes a workspace root which is itself a symlink", %{tmp_dir: tmp_dir} do
    real_root = Path.join(tmp_dir, "real-workspace")
    linked_root = Path.join(tmp_dir, "linked-workspace")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, linked_root)
    file = Path.join(real_root, "inside.txt")
    File.write!(file, "inside")

    assert {:ok, ^file} = WorkspacePath.resolve(linked_root, "inside.txt")
  end

  @tag :tmp_dir
  test "rejects invalid roots, NUL bytes, and symlink loops", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    File.ln_s!("loop-b", Path.join(root, "loop-a"))
    File.ln_s!("loop-a", Path.join(root, "loop-b"))

    assert {:error, :invalid_workspace} =
             WorkspacePath.resolve(Path.join(tmp_dir, "missing"), "file")

    assert {:error, :invalid_path} = WorkspacePath.resolve(root, "bad\0path")
    assert {:error, :too_many_symlinks} = WorkspacePath.resolve(root, "loop-a/file")
  end
end
