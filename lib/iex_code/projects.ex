defmodule IexCode.Projects do
  @moduledoc """
  Context for managing workspace projects.
  """
  import Ecto.Query, warn: false
  require Logger
  alias IexCode.Repo
  alias IexCode.Projects.Project
  alias IexCode.Runs.WorkspaceLock
  alias IexCode.WorkspacePath

  def list_projects do
    Project
    |> order_by([p], desc: coalesce(p.last_opened_at, p.inserted_at))
    |> Repo.all()
    |> Enum.filter(&project_allowed?/1)
  end

  def get_project!(id) do
    project = Repo.get!(Project, id)

    if project_allowed?(project) do
      project
    else
      raise Ecto.NoResultsError, queryable: Project
    end
  end

  def get_project_by_path(path) do
    if configured_workspace_root?() do
      case authorize_workspace(path) do
        {:ok, canonical_path} -> Repo.get_by(Project, root_path: canonical_path)
        {:error, _reason} -> nil
      end
    else
      Repo.get_by(Project, root_path: Path.expand(path))
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Returns the configured default workspace without falling back to a release directory."
  def default_workspace_path do
    Application.get_env(:iex_code, :default_workspace_path) ||
      Application.get_env(:iex_code, :workspace_root) || File.cwd!()
  end

  @doc "Checks that a persisted project still resolves inside the configured workspace root."
  def project_allowed?(%Project{root_path: path}) do
    not configured_workspace_root?() or match?({:ok, ^path}, authorize_workspace(path))
  end

  def project_allowed?(_project), do: false

  @doc """
  Returns the project for the given workspace path, creating it if needed.
  On DB failure returns `{:error, reason}` — never an unsaved struct.
  """
  def get_or_create_project(path, name \\ nil) do
    with {:ok, canonical_path} <- authorize_workspace(path),
         {:ok, project_name} <- normalize_project_name(name, canonical_path) do
      case Repo.get_by(Project, root_path: canonical_path) do
        %Project{} = project ->
          touch_project(project)
          {:ok, project}

        nil ->
          case create_project(%{
                 name: project_name,
                 root_path: canonical_path,
                 last_opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
               }) do
            {:ok, p} ->
              {:ok, p}

            # Lost an insert race (unique root_path): another process won it.
            {:error, %Ecto.Changeset{} = changeset} ->
              case Repo.get_by(Project, root_path: canonical_path) do
                %Project{} = p ->
                  {:ok, p}

                nil ->
                  Logger.error(
                    "Projects.get_or_create_project failed for #{canonical_path}: #{inspect(changeset.errors)}"
                  )

                  {:error, changeset}
              end

            {:error, reason} ->
              Logger.error(
                "Projects.get_or_create_project failed for #{canonical_path}: #{inspect(reason)}"
              )

              {:error, reason}
          end
      end
    end
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError, ArgumentError] ->
      Logger.error("Projects.get_or_create_project failed: #{Exception.message(e)}")

      if match?(%ArgumentError{}, e),
        do: {:error, :invalid_project_path},
        else: {:error, {:db_error, Exception.message(e)}}
  end

  def create_project(attrs \\ %{}) do
    with {:ok, attrs} <- authorize_project_attrs(attrs) do
      Repo.retry_on_busy(fn ->
        %Project{}
        |> Project.changeset(attrs)
        |> Repo.insert()
      end)
    end
  end

  def update_project(%Project{} = project, attrs) do
    with {:ok, attrs} <- authorize_project_attrs(attrs) do
      Repo.retry_on_busy(fn ->
        project
        |> Project.changeset(attrs)
        |> Repo.update()
      end)
    end
  end

  def touch_project(%Project{} = project) do
    update_project(project, %{
      last_opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def delete_project(%Project{} = project) do
    Repo.retry_on_busy(fn ->
      Repo.transaction(
        fn ->
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

          active? =
            WorkspaceLock
            |> where(
              [lock],
              lock.project_id == ^project.id and lock.status in ["waiting", "held"] and
                lock.lease_expires_at > ^now
            )
            |> Repo.exists?()

          if active? do
            Repo.rollback(:project_has_active_workspace_locks)
          else
            Repo.delete!(project)
          end
        end,
        mode: :immediate
      )
    end)
  end

  defp authorize_project_attrs(attrs) when is_map(attrs) do
    root_path = Map.get(attrs, :root_path, Map.get(attrs, "root_path"))

    if configured_workspace_root?() and not is_nil(root_path) do
      case authorize_workspace(root_path) do
        {:ok, canonical_path} -> {:ok, put_root_path(attrs, canonical_path)}
        {:error, _reason} = error -> error
      end
    else
      {:ok, attrs}
    end
  end

  defp authorize_project_attrs(_attrs), do: {:error, :invalid_project_attributes}

  defp put_root_path(attrs, path) do
    cond do
      Map.has_key?(attrs, :root_path) -> Map.put(attrs, :root_path, path)
      Map.has_key?(attrs, "root_path") -> Map.put(attrs, "root_path", path)
      true -> attrs
    end
  end

  defp authorize_workspace(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" or not String.valid?(path) or String.contains?(path, <<0>>) or
          byte_size(path) > 4_096 ->
        {:error, :invalid_project_path}

      true ->
        expanded = expand_project_path(trimmed)

        if File.dir?(expanded) do
          authorize_existing_directory(expanded)
        else
          {:error, :project_path_not_found}
        end
    end
  rescue
    ArgumentError -> {:error, :invalid_project_path}
  end

  defp authorize_workspace(_path), do: {:error, :invalid_project_path}

  defp expand_project_path(path) do
    case Application.get_env(:iex_code, :workspace_root) do
      root when is_binary(root) and root != "" ->
        if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, root)

      _unset ->
        Path.expand(path)
    end
  end

  defp authorize_existing_directory(expanded) do
    case Application.get_env(:iex_code, :workspace_root) do
      root when is_binary(root) and root != "" ->
        with {:ok, canonical_root} <- WorkspacePath.resolve(root, ""),
             {:ok, canonical_path} <- WorkspacePath.resolve(canonical_root, expanded),
             true <- File.dir?(canonical_path) do
          {:ok, canonical_path}
        else
          false -> {:error, :project_path_not_found}
          {:error, :outside_workspace} -> {:error, :outside_workspace_root}
          {:error, reason} -> {:error, {:workspace_error, reason}}
        end

      _unset ->
        # Development/test compatibility: without a configured boundary, still store
        # the canonical existing directory rather than a symlink alias.
        WorkspacePath.resolve(expanded, "")
    end
  end

  defp normalize_project_name(nil, canonical_path), do: {:ok, Path.basename(canonical_path)}

  defp normalize_project_name(name, canonical_path) when is_binary(name) do
    cond do
      not String.valid?(name) or String.contains?(name, <<0>>) ->
        {:error, :invalid_project_name}

      String.trim(name) == "" ->
        {:ok, Path.basename(canonical_path)}

      true ->
        {:ok, String.trim(name)}
    end
  end

  defp normalize_project_name(_name, _canonical_path), do: {:error, :invalid_project_name}

  defp configured_workspace_root? do
    Application.get_env(:iex_code, :workspace_root) not in [nil, ""]
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end
end
