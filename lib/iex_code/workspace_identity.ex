defmodule IexCode.WorkspaceIdentity do
  @moduledoc "Bounded, no-follow workspace path identity capture."

  alias IexCode.WorkspacePath

  @default_max_bytes 2 * 1_024 * 1_024

  @spec capture(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, atom() | term()}
  def capture(root, path, opts \\ []) when is_binary(root) and is_binary(path) do
    max_bytes = normalize_max_bytes(Keyword.get(opts, :max_bytes, @default_max_bytes))
    allow_final_symlink? = Keyword.get(opts, :allow_final_symlink, false)

    with {:ok, canonical} <- WorkspacePath.resolve(root, path),
         :ok <- validate_ancestors(root, path),
         {:ok, stat} <- lexical_stat(root, path),
         :ok <- validate_final_type(stat, allow_final_symlink?),
         {:ok, identity} <- capture_content(root, path, stat, canonical, max_bytes, opts) do
      {:ok, Map.put(identity, :ancestors, ancestor_identities(root, path))}
    else
      {:error, :enoent} ->
        with {:ok, canonical} <- WorkspacePath.resolve(root, path),
             :ok <- validate_ancestors(root, path) do
          {:ok,
           %{
             lexical: path,
             canonical: canonical,
             missing?: true,
             ancestors: ancestor_identities(root, path)
           }}
        end

      error ->
        error
    end
  end

  defp lexical_stat(root, path), do: File.lstat(Path.join(root, path))

  defp normalize_max_bytes(value) when is_integer(value) and value > 0,
    do: min(value, 256 * 1_024 * 1_024)

  defp normalize_max_bytes(_value), do: @default_max_bytes

  defp validate_final_type(%{type: :symlink}, true), do: :ok
  defp validate_final_type(%{type: :symlink}, false), do: {:error, :symlink_not_allowed}
  defp validate_final_type(_stat, _allow), do: :ok

  defp validate_ancestors(root, path) do
    components = Path.split(path) |> Enum.drop(-1)

    components
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_ancestor}}
        {:ok, _stat} -> {:cont, next}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp ancestor_identities(root, path) do
    components = Path.split(path) |> Enum.drop(-1)

    components
    |> Enum.with_index(1)
    |> Enum.map(fn {_component, count} ->
      ancestor = Path.join([root | Enum.take(components, count)])

      case File.lstat(ancestor) do
        {:ok, stat} ->
          {Path.relative_to(ancestor, root), stat.type, stat.mode, stat.size, stat.mtime,
           stat.ctime, stat.inode}

        _ ->
          {Path.relative_to(ancestor, root), :missing}
      end
    end)
  end

  defp capture_content(root, path, %{type: :symlink} = stat, canonical, _max, _opts) do
    with {:ok, target} <- File.read_link(Path.join(root, path)) do
      {:ok, stat_identity(stat, path, canonical) |> Map.put(:link_target, target)}
    end
  end

  defp capture_content(root, path, %{type: :regular} = stat, canonical, max_bytes, opts) do
    full = Path.join(root, path)
    observe(opts, :before_open)

    File.open(full, [:read, :binary], fn io ->
      with {:ok, opened_stat} <- descriptor_stat(io),
           true <- same_object_stat?(stat, opened_stat),
           :ok <- observe(opts, :before_read),
           {:ok, bytes} <- read_capped(io, max_bytes),
           {:ok, final_descriptor_stat} <- descriptor_stat(io),
           true <- same_object_stat?(opened_stat, final_descriptor_stat),
           {:ok, final_path_stat} <- File.lstat(full),
           true <- same_stat?(stat, final_path_stat) do
        {:ok,
         stat_identity(final_path_stat, path, canonical)
         |> Map.put(:content_digest, digest(bytes))}
      else
        {:error, :identity_too_large} -> {:error, :identity_too_large}
        _ -> {:error, :identity_changed}
      end
    end)
    |> case do
      {:ok, result} -> result
      _ -> {:error, :identity_changed}
    end
  end

  defp capture_content(_root, path, stat, canonical, _max, _opts),
    do: {:ok, stat_identity(stat, path, canonical)}

  defp observe(opts, stage) do
    case Keyword.get(opts, :observer) do
      fun when is_function(fun, 1) ->
        case fun.(stage) do
          :ok -> :ok
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp descriptor_stat(io) do
    case :file.read_file_info(io) do
      {:ok, record} -> {:ok, File.Stat.from_record(record)}
      error -> error
    end
  end

  defp read_capped(io, max_bytes) do
    case IO.binread(io, max_bytes + 1) do
      :eof -> {:ok, <<>>}
      {:error, reason} -> {:error, reason}
      bytes when byte_size(bytes) > max_bytes -> {:error, :identity_too_large}
      bytes -> {:ok, bytes}
    end
  end

  defp same_stat?(a, b) do
    Enum.all?(
      [:type, :mode, :size, :mtime, :ctime, :inode, :major_device, :minor_device],
      fn key ->
        Map.get(a, key) == Map.get(b, key)
      end
    )
  end

  defp same_object_stat?(a, b) do
    Enum.all?([:type, :mode, :size, :inode, :major_device, :minor_device], fn key ->
      Map.get(a, key) == Map.get(b, key)
    end)
  end

  defp stat_identity(stat, path, canonical) do
    %{
      lexical: path,
      canonical: canonical,
      type: stat.type,
      mode: stat.mode,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime,
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device
    }
  end

  defp digest(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end
end
