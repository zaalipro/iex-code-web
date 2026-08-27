defmodule IexCode.Outputs do
  @moduledoc """
  Bounded, file-backed output artifacts for verbose commands and tools.

  A writer reserves its complete allowance in SQLite before opening a file, so
  concurrent producers cannot overcommit the configured quota. Only fixed-size
  head and tail previews remain in the caller heap.
  """

  import Ecto.Query, warn: false

  alias IexCode.Outputs.{OutputArtifact, Writer}
  alias IexCode.Repo

  @default_artifact_limit 256 * 1_048_576
  @default_preview_bytes 64 * 1_024
  @default_global_quota 2 * 1_073_741_824
  @default_min_free_bytes 5 * 1_073_741_824
  @default_retention_seconds 7 * 24 * 60 * 60
  @stale_writer_seconds 60 * 60
  @max_read_bytes 64 * 1_024

  @doc "Reserves quota and opens a private partial output artifact."
  @spec open_writer(map(), keyword()) :: {:ok, Writer.t()} | {:error, term()}
  def open_writer(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    configured_limit = configured(:artifact_limit_bytes)
    limit = bounded_positive(opts[:limit_bytes], configured_limit)
    preview_bytes = bounded_positive(opts[:preview_bytes], configured(:preview_bytes))
    quota = bounded_positive(opts[:global_quota_bytes], configured(:global_quota_bytes))
    root = storage_root(opts)

    with :ok <- ensure_storage_root(root),
         :ok <- ensure_free_space(root, opts),
         {:ok, artifact} <- reserve_artifact(attrs, root, limit, quota, opts) do
      open_reserved_writer(artifact, root, limit, preview_bytes)
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Appends bytes and signals the exact point at which the artifact is full."
  @spec append(Writer.t(), iodata()) ::
          {:ok, Writer.t()} | {:limit_exceeded, Writer.t()} | {:error, term()}
  def append(%Writer{closed?: false} = writer, data) do
    data = IO.iodata_to_binary(data)
    remaining = max(writer.limit_bytes - writer.bytes, 0)
    accepted_bytes = min(byte_size(data), remaining)
    accepted = binary_part(data, 0, accepted_bytes)

    with :ok <- IO.binwrite(writer.io, accepted) do
      writer = account(writer, accepted)

      if accepted_bytes == byte_size(data),
        do: {:ok, writer},
        else: {:limit_exceeded, writer}
    end
  rescue
    error -> {:error, error}
  end

  def append(%Writer{}, _data), do: {:error, :writer_closed}

  @doc "Closes and publishes a ready, failed, or limit-exceeded artifact."
  @spec finish(Writer.t(), :ready | :failed | :limit_exceeded, map()) ::
          {:ok, OutputArtifact.t()} | {:error, term()}
  def finish(writer, status \\ :ready, metadata \\ %{})

  def finish(%Writer{closed?: false} = writer, status, metadata)
      when status in [:ready, :failed, :limit_exceeded] and is_map(metadata) do
    result =
      try do
        Repo.retry_on_busy(fn ->
          Repo.transaction(
            fn -> publish_writer(writer, status, metadata) end,
            mode: :immediate
          )
        end)
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, %OutputArtifact{}} = published ->
        published

      {:error, :writer_closed} = already_published ->
        # This also covers a stale writer concurrently claimed for cleanup.
        # Closing is idempotent and never removes an already-published file.
        _ = close_writer(writer)
        already_published

      {:error, _reason} = error ->
        # A filesystem rename must happen before publication so readers never
        # observe a partial file. If the following database update fails, the
        # durable row is still `writing`; discard both possible filenames and
        # the reservation. If the update actually committed before an
        # ambiguous connection error, `discard/1` sees the published row and
        # deliberately preserves it.
        _ = discard(writer)
        error
    end
  end

  def finish(%Writer{}, _status, _metadata), do: {:error, :writer_closed}

  @doc "Abandons a writer and releases its durable quota reservation."
  @spec discard(Writer.t()) :: :ok
  def discard(%Writer{} = writer) do
    case Repo.get(OutputArtifact, writer.artifact_id) do
      %OutputArtifact{status: "writing"} = artifact ->
        close_writer(writer)

        with {:ok, partial_path, final_path} <- writer_paths(writer, artifact),
             :ok <- remove_writer_files(partial_path, final_path) do
          _ = Repo.retry_on_busy(fn -> Repo.delete(artifact) end)
        end

      %OutputArtifact{} ->
        close_writer(writer)

      nil ->
        close_writer(writer)

        with {:ok, partial_path, final_path} <- writer_paths(writer) do
          _ = remove_writer_files(partial_path, final_path)
        end
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Claims expired artifacts, removes their files, then deletes their metadata."
  @spec cleanup_expired(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired(opts \\ []) when is_list(opts) do
    root = storage_root(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    claimed =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn -> claim_expired_in_transaction(now) end, mode: :immediate)
      end)

    case claimed do
      {:ok, artifacts} ->
        finalize_claimed_artifacts(artifacts, root)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def get(id) when is_binary(id), do: Repo.get(OutputArtifact, id)
  def get(_id), do: nil

  @doc """
  Fetches published artifact metadata within a trusted durable scope.

  At least one of `:session_id`, `:run_id`, or `:operation_id` is required. If
  several are supplied, every supplied identifier must match. The returned map
  deliberately excludes the server-side relative path and all associations.
  Missing, expired, unpublished, and out-of-scope artifacts are indistinguishable.
  """
  @spec fetch(Ecto.UUID.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(id, trusted_scope) when is_binary(id) do
    with {:ok, scope} <- normalize_scope(trusted_scope),
         %OutputArtifact{} = artifact <- fetch_scoped_artifact(id, scope) do
      {:ok, public_metadata(artifact)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def fetch(_id, _trusted_scope), do: {:error, :not_found}

  @doc false
  def fetch(_id), do: {:error, :scope_required}

  @doc "Builds an overlap-safe bounded head/tail preview for a published artifact."
  @spec preview(OutputArtifact.t()) :: String.t()
  def preview(%OutputArtifact{} = artifact) do
    head = artifact.preview_head || ""
    tail = artifact.preview_tail || ""

    cond do
      artifact.byte_size <= byte_size(head) ->
        head

      artifact.byte_size <= byte_size(head) + byte_size(tail) ->
        overlap = byte_size(head) + byte_size(tail) - artifact.byte_size
        head <> binary_part(tail, overlap, byte_size(tail) - overlap)

      true ->
        head <>
          "\n\n[output truncated; retrieve artifact #{artifact.id}]\n\n" <>
          tail
    end
  end

  @doc "Returns true when a preview omits bytes from the middle of an artifact."
  @spec truncated?(OutputArtifact.t()) :: boolean()
  def truncated?(%OutputArtifact{} = artifact) do
    artifact.byte_size >
      byte_size(artifact.preview_head || "") + byte_size(artifact.preview_tail || "")
  end

  @doc "Fetches an in-scope artifact and reads one bounded chunk (at most 64 KiB)."
  @spec fetch_chunk(
          Ecto.UUID.t(),
          map() | keyword(),
          non_neg_integer(),
          1..65_536,
          keyword()
        ) ::
          {:ok,
           %{
             artifact: map(),
             data: binary(),
             next_offset: non_neg_integer(),
             eof: boolean()
           }}
          | {:error, term()}
  def fetch_chunk(id, trusted_scope, offset \\ 0, length \\ @max_read_bytes, opts \\ [])

  def fetch_chunk(id, trusted_scope, offset, length, opts)
      when is_binary(id) and is_integer(offset) and offset >= 0 and is_integer(length) and
             length > 0 and length <= @max_read_bytes and is_list(opts) do
    with {:ok, scope} <- normalize_scope(trusted_scope),
         %OutputArtifact{} = artifact <- fetch_scoped_artifact(id, scope),
         {:ok, data} <- read_chunk(artifact, offset, length, opts) do
      next_offset = offset + byte_size(data)

      {:ok,
       %{
         artifact: public_metadata(artifact),
         data: data,
         next_offset: next_offset,
         eof: next_offset >= artifact.byte_size
       }}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def fetch_chunk(_id, _trusted_scope, _offset, _length, _opts),
    do: {:error, :invalid_range}

  @doc "Reads at most 64 KiB without materializing the complete artifact."
  def read_chunk(artifact, offset \\ 0, length \\ @max_read_bytes, opts \\ [])

  def read_chunk(%OutputArtifact{} = artifact, offset, length, opts)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 and
             is_list(opts) do
    root = storage_root(opts)
    length = min(length, @max_read_bytes)

    with :ok <- validate_relative_path(root, artifact.relative_path),
         {:ok, io} <- File.open(final_path(root, artifact.relative_path), [:read, :binary]) do
      result =
        case :file.pread(io, offset, length) do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end

      File.close(io)
      result
    end
  end

  def read_chunk(_artifact, _offset, _length, _opts), do: {:error, :invalid_range}

  def storage_root(opts \\ []) do
    Keyword.get_lazy(opts, :root, fn ->
      Application.get_env(:iex_code, :output_artifact_root) ||
        Path.join(database_directory(), "outputs")
    end)
  end

  defp open_reserved_writer(artifact, root, limit, preview_bytes) do
    partial = partial_path(root, artifact.relative_path)
    final = final_path(root, artifact.relative_path)

    result =
      with :ok <- File.mkdir_p(Path.dirname(partial)),
           {:ok, io} <- File.open(partial, [:write, :binary, :exclusive]) do
        case File.chmod(partial, 0o600) do
          :ok ->
            {:ok,
             %Writer{
               artifact_id: artifact.id,
               root: root,
               relative_path: artifact.relative_path,
               io: io,
               partial_path: partial,
               final_path: final,
               limit_bytes: limit,
               preview_bytes: preview_bytes,
               hash: :crypto.hash_init(:sha256)
             }}

          {:error, reason} ->
            File.close(io)
            File.rm(partial)
            {:error, reason}
        end
      end

    case result do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        _ = Repo.retry_on_busy(fn -> Repo.delete(artifact) end)
        {:error, reason}
    end
  end

  defp publish_writer(writer, status, metadata) do
    case Repo.get(OutputArtifact, writer.artifact_id) do
      %OutputArtifact{status: "writing"} = artifact ->
        with {:ok, partial_path, final_path} <- writer_paths(writer, artifact),
             checksum <- writer.hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
             :ok <- :file.sync(writer.io),
             :ok <- File.close(writer.io),
             :ok <- File.rename(partial_path, final_path),
             {:ok, artifact} <-
               artifact
               |> OutputArtifact.finish_changeset(%{
                 status: Atom.to_string(status),
                 byte_size: writer.bytes,
                 reserved_bytes: 0,
                 checksum: checksum,
                 preview_head: safe_preview(writer.head),
                 preview_tail: safe_preview(writer.tail),
                 metadata: Map.merge(artifact.metadata || %{}, metadata)
               })
               |> Repo.update() do
          artifact
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      %OutputArtifact{} ->
        Repo.rollback(:writer_closed)

      nil ->
        Repo.rollback(:artifact_not_found)
    end
  end

  defp reserve_artifact(attrs, root, limit, quota, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    id = Ecto.UUID.generate()

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(
          fn ->
            claimed = claim_expired_in_transaction(now)

            used =
              Repo.one(
                from(a in OutputArtifact,
                  select: fragment("COALESCE(SUM(? + ?), 0)", a.byte_size, a.reserved_bytes)
                )
              )

            if used + limit > quota, do: Repo.rollback(:output_quota_exceeded)

            create_attrs = %{
              id: id,
              run_id: map_value(attrs, :run_id),
              session_id: map_value(attrs, :session_id),
              operation_id: map_value(attrs, :operation_id),
              kind: map_value(attrs, :kind) || "command_output",
              name: map_value(attrs, :name) || "output.log",
              relative_path: relative_path(id, now),
              status: "writing",
              byte_size: 0,
              reserved_bytes: limit,
              limit_bytes: limit,
              metadata: map_value(attrs, :metadata) || %{},
              expires_at:
                DateTime.add(
                  now,
                  bounded_positive(opts[:retention_seconds], configured(:retention_seconds)),
                  :second
                )
            }

            case %OutputArtifact{}
                 |> OutputArtifact.create_changeset(create_attrs)
                 |> Repo.insert() do
              {:ok, artifact} -> {artifact, claimed}
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, {artifact, claimed}} ->
        # Claiming and reservation insertion committed together. Files are
        # removed only after that boundary, and rows remain in `deleting` until
        # both filenames have been removed successfully. A crash or I/O error
        # therefore leaves durable retry state rather than an orphan file.
        _ = finalize_claimed_artifacts(claimed, root)
        {:ok, artifact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_expired_in_transaction(now) do
    stale_before = DateTime.add(now, -@stale_writer_seconds, :second)

    artifacts =
      Repo.all(
        from(a in OutputArtifact,
          left_join: run in assoc(a, :run),
          where:
            a.status == "deleting" or
              ((is_nil(a.run_id) or
                  run.status in ["completed", "failed", "cancelled", "interrupted"]) and
                 ((a.status != "writing" and not is_nil(a.expires_at) and a.expires_at < ^now) or
                    (a.status == "writing" and a.inserted_at < ^stale_before))),
          order_by: [asc: a.inserted_at],
          limit: 500
        )
      )

    claim_ids =
      artifacts
      |> Enum.reject(&(&1.status == "deleting"))
      |> Enum.map(& &1.id)

    if claim_ids != [] do
      Repo.update_all(
        from(a in OutputArtifact, where: a.id in ^claim_ids and a.status != "deleting"),
        set: [status: "deleting", updated_at: now]
      )
    end

    Enum.map(artifacts, &%{&1 | status: "deleting", updated_at: now})
  end

  defp finalize_claimed_artifacts([], _root), do: {:ok, 0}

  defp finalize_claimed_artifacts(artifacts, root) do
    {removed, failed} =
      Enum.split_with(artifacts, fn artifact ->
        remove_artifact_files(artifact, root) == :ok
      end)

    ids = Enum.map(removed, & &1.id)

    delete_result =
      if ids == [] do
        {:ok, 0}
      else
        Repo.retry_on_busy(fn ->
          Repo.transaction(
            fn ->
              {count, _rows} =
                Repo.delete_all(
                  from(a in OutputArtifact, where: a.id in ^ids and a.status == "deleting")
                )

              count
            end,
            mode: :immediate
          )
        end)
      end

    case {delete_result, failed} do
      {{:ok, count}, []} ->
        {:ok, count}

      {{:ok, count}, failed} ->
        {:error, {:artifact_file_cleanup_incomplete, count, length(failed)}}

      {{:error, reason}, _failed} ->
        {:error, {:artifact_metadata_cleanup_failed, reason}}
    end
  end

  defp remove_artifact_files(artifact, root) do
    with :ok <- validate_relative_path(root, artifact.relative_path),
         :ok <- remove_file(final_path(root, artifact.relative_path)),
         :ok <- remove_file(partial_path(root, artifact.relative_path)) do
      :ok
    end
  end

  defp close_writer(%Writer{closed?: true}), do: :ok

  defp close_writer(%Writer{io: io}) do
    case File.close(io) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp writer_paths(%Writer{} = writer, %OutputArtifact{} = artifact) do
    if writer.relative_path == artifact.relative_path,
      do: writer_paths(writer),
      else: {:error, :invalid_writer_path}
  end

  defp writer_paths(%Writer{} = writer) do
    with :ok <- validate_relative_path(writer.root, writer.relative_path) do
      partial_path = partial_path(writer.root, writer.relative_path)
      final_path = final_path(writer.root, writer.relative_path)

      if writer.partial_path == partial_path and writer.final_path == final_path,
        do: {:ok, partial_path, final_path},
        else: {:error, :invalid_writer_path}
    end
  end

  defp remove_writer_files(partial_path, final_path) do
    with :ok <- remove_file(partial_path),
         :ok <- remove_file(final_path) do
      :ok
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp account(writer, accepted) do
    %{
      writer
      | bytes: writer.bytes + byte_size(accepted),
        head: append_head(writer.head, accepted, writer.preview_bytes),
        tail: append_tail(writer.tail, accepted, writer.preview_bytes),
        hash: :crypto.hash_update(writer.hash, accepted)
    }
  end

  defp append_head(head, _data, limit) when byte_size(head) >= limit, do: head

  defp append_head(head, data, limit) do
    needed = limit - byte_size(head)
    head <> binary_part(data, 0, min(byte_size(data), needed))
  end

  defp append_tail(tail, data, limit) do
    cond do
      byte_size(data) >= limit ->
        binary_part(data, byte_size(data) - limit, limit)

      byte_size(tail) + byte_size(data) <= limit ->
        tail <> data

      true ->
        keep = limit - byte_size(data)
        binary_part(tail, byte_size(tail) - keep, keep) <> data
    end
  end

  defp safe_preview(binary), do: String.replace_invalid(binary)

  defp ensure_storage_root(root) do
    with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)
  end

  defp ensure_free_space(root, opts) do
    checker = opts[:free_bytes] || (&filesystem_free_bytes/1)

    # A custom checker is an explicit trusted test/integration seam. Ordinary
    # callers may raise the free-space requirement but cannot lower the global
    # safety floor through stray or model-supplied options.
    minimum =
      if is_function(opts[:free_bytes], 1) do
        positive_or_default(opts[:min_free_bytes], configured(:min_free_bytes))
      else
        max(positive_or_default(opts[:min_free_bytes], 0), configured(:min_free_bytes))
      end

    case checker.(root) do
      bytes when is_integer(bytes) and bytes >= minimum -> :ok
      bytes when is_integer(bytes) and bytes >= 0 -> {:error, :insufficient_disk_space}
      _unknown -> {:error, :disk_space_unavailable}
    end
  end

  defp filesystem_free_bytes(root) do
    case System.cmd("df", ["-Pk", root], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.split(~r/\s+/, trim: true)
        |> Enum.at(3)
        |> parse_kib()

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  defp parse_kib(nil), do: nil

  defp parse_kib(value) do
    case Integer.parse(value) do
      {kib, ""} when kib >= 0 -> kib * 1_024
      _invalid -> nil
    end
  end

  defp relative_path(id, now),
    do: Path.join([Integer.to_string(now.year), pad(now.month), "#{id}.log"])

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
  defp partial_path(root, relative), do: final_path(root, relative) <> ".partial"
  defp final_path(root, relative), do: Path.join(root, relative)

  defp validate_relative_path(root, relative) when is_binary(relative) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(relative, expanded_root)

    if expanded_path != expanded_root and
         String.starts_with?(expanded_path, expanded_root <> "/") do
      :ok
    else
      {:error, :invalid_artifact_path}
    end
  end

  defp validate_relative_path(_root, _relative), do: {:error, :invalid_artifact_path}

  defp normalize_scope(scope) when is_list(scope) do
    if Keyword.keyword?(scope),
      do: normalize_scope(Map.new(scope)),
      else: {:error, :invalid_scope}
  end

  defp normalize_scope(scope) when is_map(scope) do
    result =
      [:session_id, :run_id, :operation_id]
      |> Enum.reduce_while(%{}, fn key, acc ->
        case map_value(scope, key) do
          value when is_binary(value) and value != "" -> {:cont, Map.put(acc, key, value)}
          value when value in [nil, ""] -> {:cont, acc}
          _invalid -> {:halt, :invalid}
        end
      end)

    case result do
      :invalid -> {:error, :invalid_scope}
      normalized when map_size(normalized) > 0 -> {:ok, normalized}
      _empty -> {:error, :scope_required}
    end
  end

  defp normalize_scope(_scope), do: {:error, :invalid_scope}

  defp fetch_scoped_artifact(id, scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(a in OutputArtifact,
        left_join: run in assoc(a, :run),
        where:
          a.id == ^id and a.status in ["ready", "failed", "limit_exceeded"] and
            (is_nil(a.expires_at) or a.expires_at > ^now or
               run.status in ["queued", "running", "paused"])
      )

    scope
    |> Enum.reduce(query, fn
      {:session_id, value}, query -> from(a in query, where: a.session_id == ^value)
      {:run_id, value}, query -> from(a in query, where: a.run_id == ^value)
      {:operation_id, value}, query -> from(a in query, where: a.operation_id == ^value)
    end)
    |> Repo.one()
  rescue
    _error -> nil
  end

  defp public_metadata(%OutputArtifact{} = artifact) do
    %{
      id: artifact.id,
      kind: artifact.kind,
      name: artifact.name,
      status: artifact.status,
      byte_size: artifact.byte_size,
      limit_bytes: artifact.limit_bytes,
      checksum: artifact.checksum,
      expires_at: artifact.expires_at,
      inserted_at: artifact.inserted_at
    }
  end

  defp database_directory do
    case Repo.config()[:database] do
      path when is_binary(path) and path not in ["", ":memory:"] -> Path.dirname(path)
      _other -> System.tmp_dir!()
    end
  end

  defp configured(:artifact_limit_bytes),
    do: configured_positive(:artifact_limit_bytes, @default_artifact_limit)

  defp configured(:preview_bytes),
    do: min(configured_positive(:preview_bytes, @default_preview_bytes), @default_preview_bytes)

  defp configured(:global_quota_bytes),
    do: configured_positive(:global_quota_bytes, @default_global_quota)

  defp configured(:min_free_bytes),
    do: configured_positive(:min_free_bytes, @default_min_free_bytes)

  defp configured(:retention_seconds),
    do: configured_positive(:retention_seconds, @default_retention_seconds)

  defp output_config, do: Application.get_env(:iex_code, :output_artifacts, [])

  defp configured_positive(key, fallback) do
    case output_config()[key] do
      value when is_integer(value) and value > 0 -> value
      _invalid -> fallback
    end
  end

  defp bounded_positive(value, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded_positive(_value, maximum), do: maximum
  defp positive_or_default(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_or_default(_value, default), do: default
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
