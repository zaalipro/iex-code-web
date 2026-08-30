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
           stat.ctime, stat.inode, stat.major_device, stat.minor_device}

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

    case open_no_follow_reader(root, path, max_bytes) do
      {:ok, port} ->
        try do
          with {:ok, opened} <- receive_reader_message(port, opts),
               true <- opened_stat_matches?(stat, opened),
               {:ok, initial_path_stat} <- File.lstat(full),
               true <- same_stat?(stat, initial_path_stat),
               :ok <- observe(opts, :before_read),
               true <- Port.command(port, Jason.encode!(%{continue: true})),
               {:ok, result} <- receive_reader_message(port, opts) do
            observe(opts, {:bytes_read, result["bytes_read"]})
            observe(opts, :after_close)

            with true <- result["closed"] == true,
                 {:ok, content_digest} <- decode_reader_result(result, max_bytes),
                 {:ok, final_path_stat} <- File.lstat(full),
                 true <- same_stat?(stat, final_path_stat) do
              {:ok,
               stat_identity(final_path_stat, path, canonical)
               |> Map.put(:content_digest, content_digest)}
            else
              {:error, :identity_too_large} -> {:error, :identity_too_large}
              _ -> {:error, :identity_changed}
            end
          else
            _ -> {:error, :identity_changed}
          end
        after
          close_reader(port)
        end

      _ ->
        {:error, :identity_changed}
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

  # The BEAM file API does not expose O_NOFOLLOW/O_NONBLOCK. A tiny isolated
  # standard-library helper provides that exact open boundary and returns only
  # a capped payload through a packet-framed port. Missing Python, unsupported
  # flags, malformed output, and timeouts all deny authority.
  defp open_no_follow_reader(root, path, max_bytes) do
    reader = Path.join(to_string(:code.priv_dir(:iex_code)), "workspace_identity_reader.py")

    with python when is_binary(python) <- System.find_executable("python3"),
         true <- File.regular?(reader) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 4},
          args: ["-I", reader, root, path, Integer.to_string(max_bytes)]
        ])

      Process.unlink(port)
      {:ok, port}
    else
      _ -> {:error, :no_safe_reader}
    end
  end

  defp close_reader(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp receive_reader_message(port, opts) do
    timeout = Keyword.get(opts, :reader_timeout_ms, 1_000)

    receive do
      {^port, {:data, data}} ->
        with {:ok, payload} <- Jason.decode(data) do
          case payload["event"] do
            "opened" ->
              observe(opts, :after_open)
              {:ok, payload}

            "result" ->
              {:ok, payload}

            _ ->
              {:error, :invalid_reader_response}
          end
        end

      {^port, {:exit_status, _status}} ->
        {:error, :reader_stopped}
    after
      timeout ->
        Port.close(port)
        {:error, :reader_timeout}
    end
  end

  defp opened_stat_matches?(stat, opened) do
    stat.type == :regular and stat.mode == opened["mode"] and stat.size == opened["size"] and
      stat.inode == opened["inode"] and stat.major_device == opened["device"]
  end

  defp decode_reader_result(
         %{"status" => "ok", "digest" => digest, "bytes_read" => count},
         max
       )
       when is_binary(digest) and byte_size(digest) == 64 and is_integer(count) and count <= max,
       do: {:ok, digest}

  defp decode_reader_result(%{"status" => "too_large", "bytes_read" => count}, max)
       when is_integer(count) and count == max + 1,
       do: {:error, :identity_too_large}

  defp decode_reader_result(_result, _max), do: {:error, :identity_changed}

  defp same_stat?(a, b) do
    Enum.all?(
      [:type, :mode, :size, :mtime, :ctime, :inode, :major_device, :minor_device],
      fn key ->
        Map.get(a, key) == Map.get(b, key)
      end
    )
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
end
