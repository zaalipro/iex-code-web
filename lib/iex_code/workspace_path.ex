defmodule IexCode.WorkspacePath do
  @moduledoc """
  Resolves a path as a capability scoped to a workspace root.

  Resolution is canonical rather than merely lexical: existing symbolic links
  are followed before containment is checked. Non-existing final components
  are allowed for create/write operations, but their nearest existing ancestor
  must still resolve inside the workspace.
  """

  @max_symlinks 40

  @type error_reason ::
          :invalid_path
          | :invalid_workspace
          | :outside_workspace
          | :too_many_symlinks
          | {:filesystem_error, File.posix()}

  @spec resolve(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, error_reason()}
  def resolve(root_path, path) when is_binary(root_path) and is_binary(path) do
    with :ok <- validate_path(path),
         true <- File.dir?(root_path) || {:error, :invalid_workspace},
         {:ok, canonical_root} <- canonicalize(Path.expand(root_path)),
         candidate <- candidate_path(root_path, path),
         {:ok, canonical_candidate} <- canonicalize(candidate),
         true <- contained?(canonical_root, canonical_candidate) || {:error, :outside_workspace} do
      {:ok, canonical_candidate}
    end
  end

  def resolve(_root_path, _path), do: {:error, :invalid_path}

  defp validate_path(path) do
    cond do
      path == "" ->
        :ok

      String.contains?(path, <<0>>) ->
        {:error, :invalid_path}

      ".." in Path.split(path) ->
        {:error, :outside_workspace}

      true ->
        :ok
    end
  end

  defp candidate_path(root_path, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, Path.expand(root_path))
    end
  end

  # Resolve symlinks component-by-component so paths whose final component does
  # not exist can still be authorized from their canonical existing ancestor.
  defp canonicalize(path), do: canonicalize(Path.expand(path), 0)

  defp canonicalize(_path, count) when count > @max_symlinks,
    do: {:error, :too_many_symlinks}

  defp canonicalize(path, count) do
    {prefix, components} = split_absolute(path)
    walk_components(prefix, components, count)
  end

  defp walk_components(current, [], _count), do: {:ok, Path.expand(current)}

  defp walk_components(current, [component | rest], count) do
    next = Path.join(current, component)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
          target_path =
            if Path.type(target) == :absolute do
              target
            else
              Path.join(Path.dirname(next), target)
            end

          target_path
          |> append_components(rest)
          |> canonicalize(count + 1)
        else
          {:error, reason} -> {:error, {:filesystem_error, reason}}
        end

      {:ok, _stat} ->
        walk_components(next, rest, count)

      {:error, :enoent} ->
        # No later component can already exist below a missing ancestor. Append
        # the remainder lexically; containment is checked on the result.
        {:ok, append_components(next, rest) |> Path.expand()}

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  defp append_components(path, []), do: path
  defp append_components(path, components), do: Path.join([path | components])

  defp split_absolute(path) do
    case Path.split(path) do
      [root | components] -> {root, components}
      [] -> {Path.expand("/"), []}
    end
  end

  defp contained?(root, candidate) do
    relative = Path.relative_to(candidate, root)

    candidate == root or
      (Path.type(relative) == :relative and relative != candidate and
         ".." not in Path.split(relative))
  end
end
