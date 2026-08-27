defmodule IexCode.Tools.WorkspacePathCapabilityTest do
  use IexCode.DataCase, async: false

  alias IexCode.Tools
  alias IexCode.Tools.Git.HunkOps
  alias IexCode.Tools.MultiPatch

  @tag :tmp_dir
  test "Tools refuses reads and writes through outward symlinks", %{tmp_dir: tmp_dir} do
    {root, outside, link} = escaped_workspace(tmp_dir)
    secret = Path.join(outside, "secret.txt")

    assert {:error, message} = Tools.execute("read_file", %{"path" => "escape/secret.txt"}, root)
    assert message =~ "Path escapes the workspace"

    assert {:error, message} =
             Tools.execute(
               "write_file",
               %{"path" => "escape/secret.txt", "content" => "overwritten"},
               root
             )

    assert message =~ "Path escapes the workspace"
    assert File.read!(secret) == "outside"
    assert File.read_link!(link) == outside
  end

  @tag :tmp_dir
  test "Tools preserves absolute paths only when inside the workspace", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    inside = Path.join(root, "inside.txt")
    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(inside, "inside")
    File.write!(outside, "outside")

    assert {:ok, output} = Tools.execute("read_file", %{"path" => inside}, root)
    assert output =~ "inside"

    assert {:error, _} = Tools.execute("read_file", %{"path" => outside}, root)
  end

  @tag :tmp_dir
  test "MultiPatch cannot mutate absolute or symlinked files outside the workspace", %{
    tmp_dir: tmp_dir
  } do
    {root, outside, _link} = escaped_workspace(tmp_dir)
    secret = Path.join(outside, "secret.txt")

    for path <- [secret, "../outside/secret.txt", "escape/secret.txt"] do
      assert {:error, {:invalid_path, ^path, :outside_workspace}} =
               MultiPatch.apply_patches(root, [
                 %{path: path, target: "outside", replacement: "changed"}
               ])
    end

    assert File.read!(secret) == "outside"
  end

  @tag :tmp_dir
  test "MultiPatch preserves an absolute target canonically inside the workspace", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    inside = Path.join(root, "inside.txt")
    File.write!(inside, "before")

    assert {:ok, %{applied: 1}} =
             MultiPatch.apply_patches(root, [
               %{path: inside, target: "before", replacement: "after"}
             ])

    assert File.read!(inside) == "after"
  end

  @tag :tmp_dir
  test "HunkOps cannot revert absolute, traversal, or symlinked files outside the workspace", %{
    tmp_dir: tmp_dir
  } do
    {root, outside, _link} = escaped_workspace(tmp_dir)
    secret = Path.join(outside, "secret.txt")

    for path <- [secret, "../outside/secret.txt", "escape/secret.txt"] do
      assert {:error, {:invalid_path, ^path, :outside_workspace}} =
               HunkOps.revert_file(root, path)
    end

    assert File.read!(secret) == "outside"
    refute File.exists?(secret <> ".bak")
  end

  @tag :tmp_dir
  test "HunkOps preserves an absolute target canonically inside the workspace", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    inside = Path.join(root, "inside.txt")
    File.write!(inside, "inside")

    assert {:ok, :reverted} = HunkOps.revert_file(root, inside)
    refute File.exists?(inside)
    assert File.read!(inside <> ".bak") == "inside"
  end

  @tag :tmp_dir
  test "HunkOps does not inherit a parent repository for a non-git workspace", %{
    tmp_dir: tmp_dir
  } do
    outer = Path.join(tmp_dir, "outer-repository")
    root = Path.join(outer, "nested-workspace")
    File.mkdir_p!(root)
    {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: outer)

    inside = Path.join(root, "inside.txt")
    File.write!(inside, "inside")

    assert {:ok, :reverted} = HunkOps.revert_file(root, inside)
    refute File.exists?(inside)
    assert File.read!(inside <> ".bak") == "inside"
  end

  defp escaped_workspace(tmp_dir) do
    root = Path.join(tmp_dir, "workspace")
    outside = Path.join(tmp_dir, "outside")
    link = Path.join(root, "escape")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "outside")
    File.ln_s!(outside, link)
    {root, outside, link}
  end
end
