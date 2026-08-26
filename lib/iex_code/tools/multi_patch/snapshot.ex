defmodule IexCode.Tools.MultiPatch.Snapshot do
  @moduledoc """
  Snapshot store for tracking multi-file patch transactions and supporting rollback.
  Persists rollback manifests in SQLite and mirrors hot entries in ETS for
  low-latency access. SQLite remains authoritative after application restarts.

  The table is normally owned by `IexCode.Tools.MultiPatch.Snapshot.Owner` in the
  supervision tree; `ensure_table/0` creates it lazily (idempotently) when the
  owner is not running (e.g. in tests or standalone scripts).
  """

  @table_name :iex_code_multipatch_snapshots
  import Ecto.Query, warn: false
  alias IexCode.Repo
  alias IexCode.Tools.MultiPatch.MutationSnapshot

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
    project_root = Keyword.get(opts, :project_root)

    entry = %{
      transaction_id: tx_id,
      timestamp: timestamp,
      session_id: session_id,
      run_id: run_id,
      project_root: project_root,
      patches: patches
    }

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
        # SQLite is authoritative. Populate the hot cache only after the
        # rollback manifest is durably committed.
        :ets.insert(@table_name, {tx_id, entry})
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
    ensure_table()

    case :ets.lookup(@table_name, tx_id) do
      [{^tx_id, %{project_root: root} = entry}] when is_binary(root) and root != "" ->
        {:ok, entry}

      [{^tx_id, _legacy_entry}] ->
        get_durable_snapshot(tx_id)

      [] ->
        get_durable_snapshot(tx_id)
    end
  end

  @doc """
  Lists recorded snapshot transactions, optionally filtered by `session_id`.
  Pass `nil` (or omit the argument) to list all snapshots.
  """
  @spec list_snapshots(String.t() | nil) :: [map()]
  def list_snapshots(session_id \\ nil) do
    ensure_table()

    durable = list_durable_snapshots(session_id)

    if durable == [] do
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(fn entry ->
        session_id == nil or
          (Map.get(entry, :session_id) == session_id and is_nil(Map.get(entry, :run_id)))
      end)
    else
      durable
    end
  end

  @doc "Lists rollback manifests owned by one durable run."
  @spec list_run_snapshots(String.t()) :: [map()]
  def list_run_snapshots(run_id) when is_binary(run_id) and run_id != "" do
    ensure_table()
    durable = list_durable_run_snapshots(run_id)

    if durable == [] do
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(&(Map.get(&1, :run_id) == run_id))
    else
      durable
    end
  end

  def list_run_snapshots(_run_id), do: []

  @doc """
  Deletes a snapshot record.
  """
  def delete_snapshot(tx_id) do
    ensure_table()
    :ets.delete(@table_name, tx_id)

    _ =
      Repo.delete_all(
        from(snapshot in MutationSnapshot, where: snapshot.transaction_id == ^tx_id)
      )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Adopts legacy unscoped manifests for one canonical workspace into a session.

  New agent tool calls always provide a session id. This compatibility bridge
  is invoked synchronously when a swarm starts so cancellation never needs a
  dangerous global rollback.
  """
  def claim_unscoped(project_root, session_id)
      when is_binary(project_root) and is_binary(session_id) and session_id != "" do
    canonical_root = Path.expand(project_root)
    ensure_table()

    :ets.tab2list(@table_name)
    |> Enum.each(fn {tx_id, entry} ->
      if is_nil(entry.session_id) and
           Path.expand(Map.get(entry, :project_root, "")) == canonical_root do
        :ets.insert(@table_name, {tx_id, %{entry | session_id: session_id}})
      end
    end)

    _ =
      from(snapshot in MutationSnapshot,
        where: is_nil(snapshot.session_id) and snapshot.project_root == ^canonical_root
      )
      |> Repo.update_all(set: [session_id: session_id])

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp get_durable_snapshot(tx_id) do
    case Repo.get(MutationSnapshot, tx_id) do
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

    query |> Repo.all() |> Enum.map(&hydrate_record/1)
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
    from(snapshot in MutationSnapshot,
      where: snapshot.run_id == ^run_id,
      order_by: [asc: snapshot.created_at, asc: snapshot.transaction_id]
    )
    |> Repo.all()
    |> Enum.map(&hydrate_record/1)
  rescue
    _ -> []
  catch
    _, _ -> []
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
end
