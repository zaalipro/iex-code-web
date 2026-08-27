defmodule IexCode.Tools.MultiPatch.Snapshot do
  @moduledoc """
  Snapshot store for tracking multi-file patch transactions and supporting rollback.
  Rollback manifests are stored only in SQLite so file bodies are not duplicated
  in long-lived BEAM memory. SQLite is the authoritative source for every read,
  list, ownership claim, and delete.

  The legacy ETS table is retained as an empty compatibility boundary for callers
  that use `table_name/0` or `ensure_table/0`. It is normally owned by
  `IexCode.Tools.MultiPatch.Snapshot.Owner`; `ensure_table/0` creates it lazily
  (idempotently) when the owner is not running (for example in tests or scripts).
  """

  @table_name :iex_code_multipatch_snapshots
  import Ecto.Query, warn: false
  alias IexCode.Repo
  alias IexCode.Tools.MultiPatch.MutationSnapshot

  @default_reference_batch_size 64
  @max_reference_batch_size 256

  @doc """
  Returns the name of the underlying ETS table.
  """
  def table_name, do: @table_name

  @doc """
  Ensures ETS table is created. Idempotent and race-safe: concurrent callers
  that lose the creation race simply reuse the existing table.
  """
  def ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        rescue
          # Another process created the named table concurrently.
          ArgumentError -> @table_name
        end

      _table ->
        @table_name
    end
  end

  @doc """
  Removes payloads left in the compatibility table by an older application
  version. Durable SQLite rows are not affected.
  """
  def purge_legacy_cache do
    ensure_table()
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Saves a snapshot transaction record.
  """
  @spec save_snapshot(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save_snapshot(tx_id, patches, opts \\ []) do
    ensure_table()
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    session_id = Keyword.get(opts, :session_id)
    run_id = Keyword.get(opts, :run_id)
    # A durable rollback record without an explicit workspace capability would
    # make later path authorization ambiguous. Callers must always scope it.
    project_root = canonical_root(Keyword.get(opts, :project_root))

    durable_attrs = %{
      transaction_id: tx_id,
      session_id: session_id,
      run_id: run_id,
      project_root: project_root,
      patches: Enum.map(patches, &serialize_patch/1),
      created_at: DateTime.truncate(timestamp, :second)
    }

    case Repo.retry_on_busy(fn ->
           %MutationSnapshot{}
           |> MutationSnapshot.changeset(durable_attrs)
           |> Repo.insert(
             on_conflict:
               {:replace, [:session_id, :run_id, :project_root, :patches, :created_at]},
             conflict_target: :transaction_id
           )
         end) do
      {:ok, _snapshot} ->
        # Purge entries created by pre-upgrade code, but never mirror rollback
        # payloads back into ETS. SQLite is the sole source of truth.
        purge_legacy_cache()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Retrieves a snapshot transaction record by ID.
  """
  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_snapshot(tx_id) do
    purge_legacy_cache()
    get_durable_snapshot(tx_id)
  end

  @doc """
  Lists recorded snapshot transactions, optionally filtered by `session_id`.
  Pass `nil` (or omit the argument) to list all snapshots.

  This compatibility API is eager and hydrates all matching rollback bodies.
  Memory-sensitive callers should use `stream_session_snapshot_refs/2` and
  retrieve each referenced manifest only when it is ready to be processed.
  """
  @spec list_snapshots(String.t() | nil) :: [map()]
  def list_snapshots(session_id \\ nil) do
    purge_legacy_cache()
    list_durable_snapshots(session_id)
  end

  @doc """
  Lists rollback manifests owned by one durable run.

  This compatibility API is eager. Memory-sensitive callers should use
  `stream_run_snapshot_refs/2`.
  """
  @spec list_run_snapshots(String.t()) :: [map()]
  def list_run_snapshots(run_id) when is_binary(run_id) and run_id != "" do
    purge_legacy_cache()
    list_durable_run_snapshots(run_id)
  end

  def list_run_snapshots(_run_id) do
    purge_legacy_cache()
    []
  end

  @doc """
  Lazily streams lightweight rollback references for an interactive session.

  References never include the `patches` payload. SQLite is queried in bounded,
  keyset-paginated batches, newest first, so a caller can fetch and apply one
  full manifest at a time without retaining every file body in BEAM memory.

  `:batch_size` defaults to #{@default_reference_batch_size} and is capped at
  #{@max_reference_batch_size}.

  `list_snapshots/1` remains an eager compatibility API and hydrates every
  matching manifest. New rollback paths should use this stream instead.
  """
  @spec stream_session_snapshot_refs(String.t(), keyword()) :: Enumerable.t()
  def stream_session_snapshot_refs(session_id, opts \\ [])

  def stream_session_snapshot_refs(session_id, opts)
      when is_binary(session_id) and session_id != "" do
    snapshot_ref_stream({:session, session_id}, opts)
  end

  def stream_session_snapshot_refs(_session_id, _opts), do: []

  @doc """
  Lazily streams lightweight rollback references for a durable run.

  Ordering and batching have the same guarantees as
  `stream_session_snapshot_refs/2`. `list_run_snapshots/1` remains available as
  an eager compatibility API.
  """
  @spec stream_run_snapshot_refs(String.t(), keyword()) :: Enumerable.t()
  def stream_run_snapshot_refs(run_id, opts \\ [])

  def stream_run_snapshot_refs(run_id, opts)
      when is_binary(run_id) and run_id != "" do
    snapshot_ref_stream({:run, run_id}, opts)
  end

  def stream_run_snapshot_refs(_run_id, _opts), do: []

  @doc """
  Deletes a snapshot record.
  """
  def delete_snapshot(tx_id) do
    purge_legacy_cache()

    _ =
      Repo.retry_on_busy(fn ->
        Repo.delete_all(
          from(snapshot in MutationSnapshot, where: snapshot.transaction_id == ^tx_id)
        )
      end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Deletes all rollback manifests owned by one durable run."
  @spec delete_run_snapshots(String.t()) :: :ok
  def delete_run_snapshots(run_id) when is_binary(run_id) and run_id != "" do
    purge_legacy_cache()

    _ =
      Repo.retry_on_busy(fn ->
        from(snapshot in MutationSnapshot, where: snapshot.run_id == ^run_id)
        |> Repo.delete_all()
      end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def delete_run_snapshots(_run_id), do: purge_legacy_cache()

  @doc """
  Deletes legacy interactive manifests for one session.

  Durable run-owned rows are deliberately excluded even when they share the
  same session id.
  """
  @spec delete_session_snapshots(String.t()) :: :ok
  def delete_session_snapshots(session_id)
      when is_binary(session_id) and session_id != "" do
    purge_legacy_cache()

    _ =
      Repo.retry_on_busy(fn ->
        from(snapshot in MutationSnapshot,
          where: snapshot.session_id == ^session_id and is_nil(snapshot.run_id)
        )
        |> Repo.delete_all()
      end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def delete_session_snapshots(_session_id), do: purge_legacy_cache()

  @doc """
  Adopts legacy unscoped manifests for one canonical workspace into a session.

  New agent tool calls always provide a session id. This compatibility bridge
  is invoked synchronously when a swarm starts so cancellation never needs a
  dangerous global rollback.
  """
  def claim_unscoped(project_root, session_id)
      when is_binary(project_root) and is_binary(session_id) and session_id != "" do
    canonical_project_root = Path.expand(project_root)
    purge_legacy_cache()

    transaction_ids =
      Repo.retry_on_busy(fn ->
        from(snapshot in MutationSnapshot,
          where: is_nil(snapshot.session_id),
          select: {snapshot.transaction_id, snapshot.project_root}
        )
        |> Repo.all()
      end)
      |> Enum.filter(fn {_transaction_id, stored_root} ->
        canonical_root(stored_root) == canonical_project_root
      end)
      |> Enum.map(fn {transaction_id, _stored_root} -> transaction_id end)

    _ =
      Repo.retry_on_busy(fn ->
        from(snapshot in MutationSnapshot,
          where: snapshot.transaction_id in ^transaction_ids
        )
        |> Repo.update_all(set: [session_id: session_id])
      end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp get_durable_snapshot(tx_id) do
    case Repo.retry_on_busy(fn -> Repo.get(MutationSnapshot, tx_id) end) do
      nil -> {:error, :not_found}
      record -> {:ok, hydrate_record(record)}
    end
  rescue
    _ -> {:error, :not_found}
  catch
    _, _ -> {:error, :not_found}
  end

  defp list_durable_snapshots(session_id) do
    query =
      from(snapshot in MutationSnapshot,
        order_by: [asc: snapshot.created_at, asc: snapshot.transaction_id]
      )

    query =
      if is_nil(session_id) do
        query
      else
        from(snapshot in query,
          where: snapshot.session_id == ^session_id and is_nil(snapshot.run_id)
        )
      end

    query
    |> then(&Repo.retry_on_busy(fn -> Repo.all(&1) end))
    |> Enum.map(&hydrate_record/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp hydrate_record(record) do
    %{
      transaction_id: record.transaction_id,
      timestamp: record.created_at,
      session_id: record.session_id,
      run_id: record.run_id,
      project_root: record.project_root,
      patches: Enum.map(record.patches || [], &deserialize_patch/1)
    }
  end

  defp list_durable_run_snapshots(run_id) do
    query =
      from(snapshot in MutationSnapshot,
        where: snapshot.run_id == ^run_id,
        order_by: [asc: snapshot.created_at, asc: snapshot.transaction_id]
      )

    Repo.retry_on_busy(fn -> Repo.all(query) end)
    |> Enum.map(&hydrate_record/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp snapshot_ref_stream(scope, opts) do
    batch_size = reference_batch_size(opts)

    Stream.resource(
      fn ->
        purge_legacy_cache()
        :first_page
      end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          refs = list_snapshot_ref_page(scope, cursor, batch_size)

          case refs do
            [] ->
              {:halt, :done}

            refs ->
              last_ref = List.last(refs)

              public_refs =
                Enum.map(refs, &Map.delete(&1, :storage_sequence))

              {public_refs, {last_ref.timestamp, last_ref.storage_sequence}}
          end
      end,
      fn _cursor -> :ok end
    )
  end

  defp list_snapshot_ref_page(scope, cursor, batch_size) do
    query =
      from(snapshot in MutationSnapshot,
        order_by: [desc: snapshot.created_at, desc: fragment("rowid")],
        limit: ^batch_size,
        select: %{
          transaction_id: snapshot.transaction_id,
          timestamp: snapshot.created_at,
          session_id: snapshot.session_id,
          run_id: snapshot.run_id,
          project_root: snapshot.project_root,
          storage_sequence: fragment("rowid")
        }
      )
      |> scope_snapshot_refs(scope)
      |> cursor_snapshot_refs(cursor)

    Repo.retry_on_busy(fn -> Repo.all(query) end)
  end

  defp scope_snapshot_refs(query, {:session, session_id}) do
    from(snapshot in query,
      where: snapshot.session_id == ^session_id and is_nil(snapshot.run_id)
    )
  end

  defp scope_snapshot_refs(query, {:run, run_id}) do
    from(snapshot in query, where: snapshot.run_id == ^run_id)
  end

  defp cursor_snapshot_refs(query, :first_page), do: query

  defp cursor_snapshot_refs(query, {timestamp, storage_sequence}) do
    from(snapshot in query,
      where:
        snapshot.created_at < ^timestamp or
          (snapshot.created_at == ^timestamp and fragment("rowid") < ^storage_sequence)
    )
  end

  defp reference_batch_size(opts) do
    case Keyword.get(opts, :batch_size, @default_reference_batch_size) do
      batch_size when is_integer(batch_size) and batch_size > 0 ->
        min(batch_size, @max_reference_batch_size)

      _invalid ->
        @default_reference_batch_size
    end
  end

  defp serialize_patch(patch) do
    %{
      "path" => patch.path,
      "full_path" => patch.full_path,
      "file_existed" => patch.file_existed?,
      "original_content" => patch.original_content,
      "new_content" => patch.new_content
    }
  end

  defp deserialize_patch(patch) do
    %{
      path: patch["path"],
      full_path: patch["full_path"],
      file_existed?: patch["file_existed"],
      original_content: patch["original_content"],
      new_content: patch["new_content"]
    }
  end

  defp canonical_root(root) when is_binary(root) and root != "", do: Path.expand(root)
  defp canonical_root(root), do: root
end
