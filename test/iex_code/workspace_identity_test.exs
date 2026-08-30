defmodule IexCode.WorkspaceIdentityTest do
  use ExUnit.Case, async: true

  alias IexCode.WorkspaceIdentity

  @moduletag :tmp_dir

  test "captures a bounded regular file and rejects oversized content", %{tmp_dir: root} do
    File.write!(Path.join(root, "small.txt"), "small")

    assert {:ok, %{type: :regular, size: 5, content_digest: digest}} =
             WorkspaceIdentity.capture(root, "small.txt", max_bytes: 5)

    assert is_binary(digest)
    File.write!(Path.join(root, "large.txt"), "123456")

    assert {:error, :identity_too_large} =
             WorkspaceIdentity.capture(root, "large.txt", max_bytes: 5)
  end

  test "identifies a final symlink without reading its oversized target", %{tmp_dir: root} do
    target = Path.join(root, "target")
    File.write!(target, String.duplicate("x", 64))
    File.ln_s!(target, Path.join(root, "link"))

    assert {:ok, %{type: :symlink, link_target: ^target}} =
             WorkspaceIdentity.capture(root, "link", max_bytes: 4, allow_final_symlink: true)
  end

  test "rejects an intermediate symlink and changes missing canonical ancestry", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "dir"))
    assert {:ok, before} = WorkspaceIdentity.capture(root, "dir/deleted.txt")
    target = Path.join(root, "target")
    File.mkdir_p!(target)
    File.rmdir!(Path.join(root, "dir"))
    File.ln_s!(target, Path.join(root, "dir"))

    assert {:error, :symlink_ancestor} = WorkspaceIdentity.capture(root, "dir/deleted.txt")
    refute before.canonical == Path.join(target, "deleted.txt")
  end

  test "captures mode and device identity", %{tmp_dir: root} do
    file = Path.join(root, "mode.txt")
    File.write!(file, "mode")
    assert {:ok, identity} = WorkspaceIdentity.capture(root, "mode.txt")
    {:ok, stat} = File.lstat(file)
    assert identity.mode == stat.mode
    assert identity.major_device == stat.major_device
    assert identity.minor_device == stat.minor_device
  end

  test "rejects a regular-file to symlink swap before reading the replacement", %{
    tmp_dir: root
  } do
    file = Path.join(root, "swap.txt")
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
    File.write!(file, "small")
    File.write!(outside, String.duplicate("x", 64))
    on_exit(fn -> File.rm(outside) end)
    owner = self()

    observer = fn
      :before_open ->
        File.rm!(file)
        File.ln_s!(outside, file)

      :before_read ->
        send(owner, :replacement_was_read)

      _ ->
        :ok
    end

    assert {:error, :identity_changed} =
             WorkspaceIdentity.capture(root, "swap.txt", max_bytes: 4, observer: observer)

    refute_received :replacement_was_read
    assert File.read!(outside) == String.duplicate("x", 64)
  end

  test "caps a file that grows after its descriptor identity is checked", %{tmp_dir: root} do
    file = Path.join(root, "grow.txt")
    File.write!(file, "1234")

    observer = fn
      :before_read -> File.write!(file, String.duplicate("z", 64), [:append])
      _ -> :ok
    end

    assert {:error, :identity_too_large} =
             WorkspaceIdentity.capture(root, "grow.txt", max_bytes: 4, observer: observer)
  end
end
