defmodule IexCode.ProjectsConfinementTest do
  use IexCode.DataCase, async: false

  alias IexCode.Projects
  alias IexCode.Projects.Project

  setup do
    previous_root = Application.get_env(:iex_code, :workspace_root)
    previous_default = Application.get_env(:iex_code, :default_workspace_path)

    base =
      Path.join(
        System.tmp_dir!(),
        "iex-code-project-boundary-#{System.unique_integer([:positive, :monotonic])}"
      )

    root = Path.join(base, "workspaces")
    child = Path.join(root, "project")
    outside = Path.join(base, "outside")
    File.mkdir_p!(child)
    File.mkdir_p!(outside)

    Application.put_env(:iex_code, :workspace_root, root)
    Application.put_env(:iex_code, :default_workspace_path, child)

    on_exit(fn ->
      restore_env(:workspace_root, previous_root)
      restore_env(:default_workspace_path, previous_default)
      File.rm_rf(base)
    end)

    %{root: root, child: child, outside: outside}
  end

  test "canonicalizes and registers an existing directory inside the workspace root", %{
    child: child
  } do
    alias_path = Path.join(Path.dirname(child), "project-alias")
    File.ln_s!(child, alias_path)

    assert {:ok, project} = Projects.get_or_create_project(alias_path, "Canonical")
    assert {:ok, canonical_child} = IexCode.WorkspacePath.resolve(child, "")
    assert project.root_path == canonical_child
    assert Projects.get_project_by_path(alias_path).id == project.id
    assert Projects.get_project_by_path("project").id == project.id
    assert Projects.project_allowed?(project)
  end

  test "rejects missing, malformed, and outside project paths", %{root: root, outside: outside} do
    assert {:error, :project_path_not_found} =
             Projects.get_or_create_project(Path.join(root, "missing"))

    assert {:error, :invalid_project_path} = Projects.get_or_create_project(<<255>>)
    assert {:error, :invalid_project_path} = Projects.get_or_create_project(root <> <<0>>)
    assert {:error, :invalid_project_path} = Projects.get_or_create_project("   ")
    assert {:error, :outside_workspace_root} = Projects.get_or_create_project(outside)

    assert {:error, :outside_workspace_root} =
             Projects.create_project(%{name: "Outside", root_path: outside})
  end

  test "rejects a symlink which escapes the configured root", %{root: root, outside: outside} do
    escape = Path.join(root, "escape")
    File.ln_s!(outside, escape)

    assert {:error, :outside_workspace_root} = Projects.get_or_create_project(escape)
  end

  test "filters legacy project rows which are no longer authorized", %{outside: outside} do
    {:ok, project} =
      %Project{name: "Legacy outside", root_path: outside}
      |> IexCode.Repo.insert()

    refute Projects.project_allowed?(project)
    refute Enum.any?(Projects.list_projects(), &(&1.id == project.id))
    assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(project.id) end
  end

  test "uses the configured default workspace rather than the VM working directory", %{
    child: child
  } do
    assert Projects.default_workspace_path() == child
  end

  test "preserves unrestricted desktop/test project inserts when no boundary is configured", %{
    outside: outside
  } do
    Application.delete_env(:iex_code, :workspace_root)

    nonexistent = Path.join(outside, "not-created")

    assert {:ok, project} =
             Projects.create_project(%{name: "Desktop compatibility", root_path: nonexistent})

    assert project.root_path == nonexistent
    assert Projects.project_allowed?(project)
  end

  test "project changeset rejects invalid path encodings and NUL bytes" do
    refute Project.changeset(%Project{}, %{name: "Bad", root_path: <<255>>}).valid?
    refute Project.changeset(%Project{}, %{name: "Bad", root_path: "/tmp/bad" <> <<0>>}).valid?
  end

  defp restore_env(key, nil), do: Application.delete_env(:iex_code, key)
  defp restore_env(key, value), do: Application.put_env(:iex_code, key, value)
end
