defmodule IexCode.WorkspaceFilesTest do
  use ExUnit.Case, async: true

  alias IexCode.WorkspaceFiles

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.mkdir_p!(Path.join(root, "deps/ignored"))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "discovers deterministic bounded pages without generated trees", %{root: root} do
    for name <- ~w(a b c d e) do
      File.write!(Path.join(root, "lib/nested/#{name}.ex"), name)
    end

    File.write!(Path.join(root, "deps/ignored/huge.ex"), "ignored")

    first = WorkspaceFiles.page(root, limit: 3)
    second = WorkspaceFiles.page(root, offset: 3, limit: 3)

    assert first.more?
    assert length(first.files) == 3
    refute second.more?

    assert Enum.sort(first.files ++ second.files) ==
             Enum.map(~w(a b c d e), &"lib/nested/#{&1}.ex")

    refute Enum.any?(first.files ++ second.files, &String.starts_with?(&1, "deps/"))
  end

  test "does not follow directory symlinks", %{root: root} do
    outside =
      Path.join(
        System.tmp_dir!(),
        "workspace-files-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(root, "linked"))

    on_exit(fn -> File.rm_rf(outside) end)

    refute "linked/secret.txt" in WorkspaceFiles.page(root).files
  end
end
