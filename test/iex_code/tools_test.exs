defmodule IexCode.ToolsTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools

  @tag :tmp_dir
  test "reads and writes files correctly", %{tmp_dir: tmp_dir} do
    test_file = "test_module.ex"
    content = "defmodule TestMod do\n  def hello, do: :world\nend\n"

    assert {:ok, _msg} =
             Tools.execute("write_file", %{"path" => test_file, "content" => content}, tmp_dir)

    assert {:ok, read_content} = Tools.execute("read_file", %{"path" => test_file}, tmp_dir)
    assert String.contains?(read_content, "defmodule TestMod")

    # Test patch_file
    patch_args = %{
      "path" => test_file,
      "target_content" => ":world",
      "replacement_content" => ":universe"
    }

    assert {:ok, _} = Tools.execute("patch_file", patch_args, tmp_dir)
    assert {:ok, patched} = Tools.execute("read_file", %{"path" => test_file}, tmp_dir)
    assert String.contains?(patched, ":universe")
  end

  @tag :tmp_dir
  test "lists directory and grep search", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "app.ex"), "defmodule App do\n  def run, do: :ok\nend")

    assert {:ok, list_out} = Tools.execute("list_dir", %{"path" => ""}, tmp_dir)
    assert String.contains?(list_out, "app.ex")

    assert {:ok, grep_out} = Tools.execute("grep_search", %{"query" => "def run"}, tmp_dir)
    assert String.contains?(grep_out, "app.ex")
  end

  @tag :tmp_dir
  test "runs shell commands safely", %{tmp_dir: tmp_dir} do
    assert {:ok, output} =
             Tools.execute("run_command", %{"command" => "echo 'hello from elixir'"}, tmp_dir)

    assert String.contains?(output, "hello from elixir")
  end

  test "tool definitions enforce an explicit execution manifest" do
    all_names = Tools.tool_definitions() |> Enum.map(& &1.name)
    assert "web_search" in all_names
    assert "fetch_url" in all_names

    assert [%{name: "web_search"}] = Tools.tool_definitions(["web_search"])
    assert [] = Tools.tool_definitions([])
    assert [%{name: "fetch_url"}] = Tools.tool_definitions(MapSet.new(["fetch_url"]))
  end

  @tag :tmp_dir
  test "AST search confines absolute and symlinked scopes to the workspace", %{tmp_dir: root} do
    inside = Path.join(root, "inside")
    outside = root <> "-outside"
    File.mkdir_p!(inside)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    File.write!(Path.join(inside, "visible.ex"), "defmodule VisibleInside do\nend\n")
    File.write!(Path.join(outside, "secret.ex"), "defmodule OutsideSecret do\nend\n")

    assert {:ok, output} =
             Tools.execute(
               "ast_search",
               %{"query" => "VisibleInside", "path" => "inside"},
               root
             )

    assert output =~ "VisibleInside"

    assert {:ok, absolute_inside_output} =
             Tools.execute(
               "ast_search",
               %{"query" => "VisibleInside", "path" => inside},
               root
             )

    assert absolute_inside_output =~ "VisibleInside"

    assert {:error, absolute_error} =
             Tools.execute(
               "ast_search",
               %{"query" => "OutsideSecret", "path" => outside},
               root
             )

    assert absolute_error =~ "Path escapes the workspace"

    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:error, symlink_error} =
             Tools.execute(
               "ast_search",
               %{"query" => "OutsideSecret", "path" => "escape"},
               root
             )

    assert symlink_error =~ "Path escapes the workspace"
  end
end
