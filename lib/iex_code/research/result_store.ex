defmodule IexCode.Research.ResultStore do
  @moduledoc "Content-addressed, symlink-safe storage for durable research reports."

  alias IexCode.WorkspacePath

  @max_body_bytes 4_000_000
  @digest_format ~r/^[0-9a-f]{64}$/

  @type object :: %{
          digest: String.t(),
          byte_size: non_neg_integer(),
          object_path: Path.t()
        }

  @spec put(Path.t(), binary()) :: {:ok, object()} | {:error, term()}
  def put(root, body) when is_binary(root) and is_binary(body) do
    with :ok <- validate_body(body),
         {:ok, root} <- ensure_root(root),
         digest <- digest(body),
         {:ok, path} <- authorize_destination(root, object_relative_path(digest)),
         :ok <- ensure_parent(root, path),
         :ok <- write_once(path, body, digest) do
      {:ok, %{digest: digest, byte_size: byte_size(body), object_path: path}}
    end
  end

  def put(_root, _body), do: {:error, :invalid_research_body}

  @spec materialize(Path.t(), object(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def materialize(root, %{digest: digest, object_path: object_path}, relative_path)
      when is_binary(root) and is_binary(digest) and is_binary(object_path) and
             is_binary(relative_path) do
    with true <- Regex.match?(@digest_format, digest) or {:error, :invalid_object_digest},
         :ok <- validate_result_path(relative_path),
         {:ok, root} <- ensure_root(root),
         {:ok, object} <- authorize_existing(root, object_path),
         :ok <- verify_file(object, digest),
         {:ok, destination} <- authorize_destination(root, relative_path),
         :ok <- ensure_parent(root, destination),
         :ok <- copy_once(root, object, destination, digest) do
      {:ok, destination}
    else
      false -> {:error, :invalid_research_object}
      {:error, _reason} = error -> error
    end
  end

  def materialize(_root, _object, _relative_path), do: {:error, :invalid_materialization}

  @doc "Materializes a previously stored object by its accepted digest."
  def materialize_digest(root, digest, relative_path)
      when is_binary(root) and is_binary(digest) and is_binary(relative_path) do
    with true <- Regex.match?(@digest_format, digest) or {:error, :invalid_object_digest},
         {:ok, root} <- ensure_root(root),
         {:ok, object_path} <- authorize_destination(root, object_relative_path(digest)) do
      materialize(root, %{digest: digest, object_path: object_path}, relative_path)
    else
      false -> {:error, :invalid_object_digest}
      {:error, _reason} = error -> error
    end
  end

  def materialize_digest(_root, _digest, _relative_path),
    do: {:error, :invalid_materialization}

  @spec read(Path.t(), Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(root, relative_path, expected_digest)
      when is_binary(root) and is_binary(relative_path) and is_binary(expected_digest) do
    with true <- Regex.match?(@digest_format, expected_digest) or {:error, :invalid_digest},
         :ok <- validate_result_path(relative_path),
         {:ok, root} <- ensure_root(root),
         {:ok, path} <- authorize_destination(root, relative_path),
         :ok <- reject_symlink(path),
         {:ok, body} <- read_bounded_regular(path),
         true <- digest(body) == expected_digest or {:error, :research_result_integrity_error} do
      {:ok, body}
    else
      false -> {:error, :invalid_research_result}
      {:error, _reason} = error -> error
    end
  end

  def read(_root, _relative_path, _expected_digest), do: {:error, :invalid_research_read}

  defp validate_body(body) do
    cond do
      byte_size(body) > @max_body_bytes -> {:error, {:research_body_too_large, @max_body_bytes}}
      not String.valid?(body) -> {:error, :invalid_utf8}
      true -> :ok
    end
  end

  defp validate_result_path(path) do
    cond do
      path == "" -> {:error, :invalid_research_path}
      Path.type(path) != :relative -> {:error, :invalid_research_path}
      ".." in Path.split(path) -> {:error, :outside_research_root}
      byte_size(path) > 1_024 -> {:error, :invalid_research_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_research_path}
      Path.extname(path) not in [".md", ".html"] -> {:error, :invalid_research_extension}
      true -> :ok
    end
  end

  defp ensure_root(root) do
    expanded = Path.expand(root)

    with :ok <- File.mkdir_p(expanded),
         {:ok, %{type: :directory}} <- File.lstat(expanded),
         :ok <- File.chmod(expanded, 0o700),
         {:ok, canonical} <- WorkspacePath.resolve(expanded, ".") do
      {:ok, canonical}
    else
      {:ok, _stat} -> {:error, :invalid_research_root}
      {:error, _reason} = error -> error
    end
  end

  defp object_relative_path(digest),
    do: Path.join([".objects", "sha256", String.slice(digest, 0, 2), digest])

  defp authorize_destination(root, relative) do
    with {:ok, path} <- WorkspacePath.resolve(root, relative),
         :ok <- reject_symlink(path) do
      {:ok, path}
    end
  end

  defp authorize_existing(root, path) do
    relative = Path.relative_to(path, root)

    with {:ok, authorized} <- WorkspacePath.resolve(root, relative),
         true <- authorized == path or {:error, :object_path_changed},
         :ok <- reject_symlink(authorized) do
      {:ok, authorized}
    else
      false -> {:error, :invalid_object_path}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_parent(root, path) do
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent),
         {:ok, canonical} <- WorkspacePath.resolve(root, Path.relative_to(parent, root)),
         true <- canonical == parent or {:error, :research_parent_changed},
         {:ok, %{type: :directory}} <- File.lstat(parent),
         :ok <- File.chmod(parent, 0o700) do
      :ok
    else
      false -> {:error, :invalid_research_parent}
      {:ok, _stat} -> {:error, :invalid_research_parent}
      {:error, _reason} = error -> error
    end
  end

  defp write_once(path, body, expected_digest) do
    temporary = temporary_path(path)

    result =
      with :ok <- write_exclusive(temporary, body),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- publish_exclusive(temporary, path, expected_digest) do
        sync_directory(Path.dirname(path))
      end

    _ = File.rm(temporary)
    result
  end

  defp copy_once(root, source, destination, expected_digest) do
    case File.lstat(destination) do
      {:ok, %{type: :regular}} ->
        verify_file(destination, expected_digest)

      {:ok, _stat} ->
        {:error, :invalid_research_destination}

      {:error, :enoent} ->
        temporary = temporary_path(destination)

        result =
          with {:ok, body} <- read_bounded_regular(source),
               true <- digest(body) == expected_digest or {:error, :research_object_collision},
               :ok <- write_exclusive(temporary, body),
               :ok <- File.chmod(temporary, 0o600),
               {:ok, authorized} <-
                 WorkspacePath.resolve(root, Path.relative_to(destination, root)),
               true <- authorized == destination or {:error, :research_destination_changed},
               :ok <- publish_exclusive(temporary, destination, expected_digest) do
            sync_directory(Path.dirname(destination))
          else
            false -> {:error, :research_destination_changed}
            {:error, _reason} = error -> error
          end

        _ = File.rm(temporary)
        result

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  defp write_exclusive(path, body) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = write_synced(io, body)
        _ = File.close(io)
        if result != :ok, do: File.rm(path)
        result

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  # A hard-link publish is an atomic create-if-absent operation on the same
  # filesystem. Unlike rename, it can never replace an already materialized
  # immutable result. The temporary inode is fully written and synced first.
  defp publish_exclusive(temporary, destination, expected_digest) do
    case File.ln(temporary, destination) do
      :ok ->
        verify_file(destination, expected_digest)

      {:error, :eexist} ->
        verify_file(destination, expected_digest)

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  defp write_synced(io, body) do
    with :ok <- IO.binwrite(io, body),
         :ok <- :file.sync(io) do
      :ok
    end
  end

  # Directory fsync support varies by platform/filesystem. Do it where the
  # runtime permits and treat documented unsupported-directory errors as the
  # best-effort boundary; file contents themselves are always fsynced above.
  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw]) do
      {:ok, io} ->
        result = :file.sync(io)
        _ = :file.close(io)

        case result do
          :ok -> :ok
          {:error, reason} when reason in [:einval, :enotsup, :eisdir, :eperm] -> :ok
          {:error, reason} -> {:error, {:filesystem_error, reason}}
        end

      {:error, reason} when reason in [:einval, :enotsup, :eisdir, :eperm] ->
        :ok

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  defp verify_file(path, expected_digest) do
    with :ok <- reject_symlink(path),
         {:ok, body} <- read_bounded_regular(path),
         true <- digest(body) == expected_digest or {:error, :research_object_collision} do
      :ok
    else
      false -> {:error, :invalid_research_object}
      {:error, _reason} = error -> error
    end
  end

  defp read_bounded_regular(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular or {:error, :not_a_regular_file},
         true <- stat.size <= @max_body_bytes or {:error, :research_body_too_large},
         {:ok, body} <- File.read(path) do
      {:ok, body}
    else
      false -> {:error, :invalid_research_file}
      {:error, _reason} = error -> error
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :research_symlink_forbidden}
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :invalid_research_path}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:filesystem_error, reason}}
    end
  end

  defp temporary_path(destination) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    destination <> ".tmp-" <> suffix
  end

  defp digest(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
