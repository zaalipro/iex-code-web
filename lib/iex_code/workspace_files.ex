defmodule IexCode.WorkspaceFiles do
  @moduledoc """
  Bounded, deterministic workspace file discovery for interactive views.

  Discovery never follows directory symlinks and stops as soon as the requested
  page plus one look-ahead entry has been found. This avoids `Path.wildcard/1`
  materialising very large workspaces in every LiveView process.
  """

  @default_limit 500
  @max_limit 2_000
  @excluded_directories MapSet.new([
                          "_build",
                          "deps",
                          ".git",
                          ".elixir_ls",
                          ".agents",
                          "node_modules",
                          "tmp"
                        ])

  @type page :: %{files: [String.t()], offset: non_neg_integer(), more?: boolean()}

  @spec page(Path.t(), keyword()) :: page()
  def page(root_path, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    offset = opts |> Keyword.get(:offset, 0) |> normalize_offset()

    files = walk(root_path, offset + limit + 1)
    page_files = Enum.slice(files, offset, limit)

    %{files: page_files, offset: offset, more?: length(files) > offset + limit}
  end

  defp walk(root_path, take) when is_binary(root_path) and take > 0 do
    root = Path.expand(root_path)

    if File.dir?(root) do
      do_walk(root, [""], [], take)
      |> Enum.reverse()
    else
      []
    end
  end

  defp walk(_root_path, _take), do: []

  defp do_walk(_root, _directories, files, take) when length(files) >= take,
    do: Enum.take(files, take)

  defp do_walk(_root, [], files, _take), do: files

  defp do_walk(root, [relative_dir | rest], files, take) do
    absolute_dir = if relative_dir == "", do: root, else: Path.join(root, relative_dir)

    case File.ls(absolute_dir) do
      {:ok, names} ->
        {new_directories, new_files} =
          names
          |> Enum.sort()
          |> Enum.reduce({[], files}, fn name, {directories, found_files} = acc ->
            if length(found_files) >= take do
              acc
            else
              relative_path =
                if relative_dir == "", do: name, else: Path.join(relative_dir, name)

              cond do
                excluded?(relative_path) ->
                  acc

                regular_file?(Path.join(root, relative_path)) ->
                  {directories, [relative_path | found_files]}

                real_directory?(Path.join(root, relative_path)) ->
                  {[relative_path | directories], found_files}

                true ->
                  acc
              end
            end
          end)

        do_walk(root, rest ++ Enum.reverse(new_directories), new_files, take)

      {:error, _reason} ->
        do_walk(root, rest, files, take)
    end
  end

  defp excluded?(relative_path) do
    basename = Path.basename(relative_path)

    Enum.any?(Path.split(relative_path), &MapSet.member?(@excluded_directories, &1)) or
      basename == "erl_crash.dump" or
      Regex.match?(~r/\.(?:db|sqlite|sqlite3)(?:-(?:wal|shm))?\z/i, basename)
  end

  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  defp real_directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp normalize_limit(_invalid), do: @default_limit
  defp normalize_offset(offset) when is_integer(offset), do: max(offset, 0)
  defp normalize_offset(_invalid), do: 0
end
