defmodule IexCode.Repo.Migrations.RepairWorkspaceLockSchema do
  use Ecto.Migration

  @desired_columns ~w(
    id project_id run_id session_id workspace_key resource_type resource_key batch_id mode status
    owner_id capability_token_hash fencing_token requested_at acquired_at heartbeat_at
    lease_expires_at released_at conflict_lock_id conflict_owner_id wait_reason inserted_at updated_at
  )

  @desired_indexes [
    "workspace_locks_active_identity_index",
    "workspace_locks_project_id_status_lease_expires_at_index",
    "workspace_locks_workspace_key_status_requested_at_index",
    "workspace_locks_batch_id_status_index",
    "workspace_locks_run_id_status_index",
    "workspace_locks_session_id_status_index",
    "workspace_locks_conflict_lock_id_index",
    "workspace_locks_workspace_key_fencing_token_index"
  ]

  # The first development version of CreateWorkspaceLocks was applied before
  # workspace_key and the cross-project indexes/check constraints were added.
  # SQLite cannot make an existing column NOT NULL or add these table checks in
  # place, so repair only legacy shapes with a transactional table rebuild.
  def up do
    execute(&repair_legacy_workspace_locks/0)
  end

  # This migration repairs an already-created table without changing the
  # application-level model. Reintroducing the legacy, weaker shape on rollback
  # would discard an invariant and is deliberately a no-op.
  def down do
    :ok
  end

  defp repair_legacy_workspace_locks do
    if table_exists?() and not desired_schema?() do
      rebuild_workspace_locks!()
    end
  end

  defp table_exists? do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_locks'",
        [],
        log: false
      )

    rows != []
  end

  defp desired_schema? do
    columns = table_columns()
    column_names = Enum.map(columns, &Enum.at(&1, 1))

    workspace_key_not_null? =
      Enum.any?(columns, fn row -> Enum.at(row, 1) == "workspace_key" and Enum.at(row, 3) == 1 end)

    %{rows: [[table_sql]]} =
      repo().query!(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'workspace_locks'",
        [],
        log: false
      )

    index_names =
      repo().query!("PRAGMA index_list('workspace_locks')", [], log: false).rows
      |> Enum.map(&Enum.at(&1, 1))

    Enum.all?(@desired_columns, &(&1 in column_names)) and workspace_key_not_null? and
      Enum.all?(@desired_indexes, &(&1 in index_names)) and
      String.contains?(table_sql, "workspace_locks_resource_type_check") and
      String.contains?(table_sql, "workspace_locks_mode_check") and
      String.contains?(table_sql, "workspace_locks_status_check") and
      String.contains?(table_sql, "workspace_locks_capability_hash_check") and
      String.contains?(table_sql, "workspace_locks_lifecycle_check") and
      String.contains?(table_sql, "NOT GLOB '*[^0-9a-f]*'") and
      String.contains?(table_sql, "fencing_token > 0") and
      String.contains?(table_sql, "conflict_lock_id IS NOT NULL")
  end

  defp rebuild_workspace_locks! do
    existing = MapSet.new(Enum.map(table_columns(), &Enum.at(&1, 1)))

    query!("PRAGMA defer_foreign_keys = ON")
    query!("ALTER TABLE workspace_locks RENAME TO workspace_locks_legacy")
    query!(create_table_sql())
    query!(copy_rows_sql(existing))
    canonicalize_workspace_keys!()
    retire_legacy_active_locks!()
    normalize_fencing_tokens!()
    query!("DROP TABLE workspace_locks_legacy")

    Enum.each(index_sql(), &query!/1)
  end

  defp table_columns do
    repo().query!("PRAGMA table_info('workspace_locks')", [], log: false).rows
  end

  defp query!(sql), do: repo().query!(sql, [], log: false)

  defp canonicalize_workspace_keys! do
    %{rows: projects} =
      repo().query!(
        """
        SELECT DISTINCT projects.id, projects.root_path
        FROM projects
        JOIN workspace_locks ON workspace_locks.project_id = projects.id
        """,
        [],
        log: false
      )

    Enum.each(projects, fn [project_id, root_path] ->
      workspace_key =
        case IexCode.WorkspacePath.resolve(root_path, "") do
          {:ok, canonical_root} -> canonical_root
          {:error, _reason} -> Path.expand(root_path)
        end

      repo().query!(
        "UPDATE workspace_locks SET workspace_key = ? WHERE project_id = ?",
        [workspace_key, project_id],
        log: false
      )
    end)
  end

  # Capabilities intentionally are not persisted in plaintext. After an app
  # restart no process can legitimately renew a pre-migration active row, so
  # carrying it forward as held/waiting would create a phantom owner until its
  # old deadline. Retain the complete row as terminal audit history instead.
  defp retire_legacy_active_locks! do
    query!("""
    UPDATE workspace_locks
    SET status = CASE status WHEN 'held' THEN 'expired' ELSE 'cancelled' END,
        released_at = COALESCE(released_at, updated_at, requested_at),
        conflict_lock_id = NULL,
        conflict_owner_id = NULL,
        wait_reason = NULL
    WHERE status IN ('held', 'waiting')
    """)
  end

  # The legacy uniqueness scope was project_id, so two project records that
  # resolve to the same canonical checkout could both have fence 1. Preserve
  # their relative order while assigning a workspace-wide sequence.
  defp normalize_fencing_tokens! do
    query!("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY workspace_key
               ORDER BY fencing_token, requested_at, id
             ) AS workspace_fence
      FROM workspace_locks
      WHERE fencing_token IS NOT NULL
    )
    UPDATE workspace_locks
    SET fencing_token = (
      SELECT workspace_fence FROM ranked WHERE ranked.id = workspace_locks.id
    )
    WHERE id IN (SELECT id FROM ranked)
    """)
  end

  defp create_table_sql do
    """
    CREATE TABLE workspace_locks (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL CONSTRAINT workspace_locks_project_id_fkey
        REFERENCES projects(id) ON DELETE CASCADE,
      run_id TEXT CONSTRAINT workspace_locks_run_id_fkey
        REFERENCES runs(id) ON DELETE SET NULL,
      session_id TEXT CONSTRAINT workspace_locks_session_id_fkey
        REFERENCES sessions(id) ON DELETE SET NULL,
      workspace_key TEXT NOT NULL,
      resource_type TEXT NOT NULL CONSTRAINT workspace_locks_resource_type_check
        CHECK (resource_type IN ('project', 'file', 'git')),
      resource_key TEXT NOT NULL,
      batch_id TEXT NOT NULL,
      mode TEXT NOT NULL CONSTRAINT workspace_locks_mode_check
        CHECK (mode IN ('read', 'write', 'exclusive')),
      status TEXT DEFAULT 'waiting' NOT NULL CONSTRAINT workspace_locks_status_check
        CHECK (status IN ('waiting', 'held', 'released', 'expired', 'cancelled')),
      owner_id TEXT NOT NULL,
      capability_token_hash TEXT NOT NULL CONSTRAINT workspace_locks_capability_hash_check
        CHECK (length(capability_token_hash) = 64
          AND capability_token_hash NOT GLOB '*[^0-9a-f]*'),
      fencing_token INTEGER,
      requested_at TEXT NOT NULL,
      acquired_at TEXT,
      heartbeat_at TEXT,
      lease_expires_at TEXT,
      released_at TEXT,
      conflict_lock_id TEXT CONSTRAINT workspace_locks_conflict_lock_id_fkey
        REFERENCES workspace_locks(id) ON DELETE SET NULL,
      conflict_owner_id TEXT,
      wait_reason TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT workspace_locks_lifecycle_check CHECK (
        (status = 'waiting' AND acquired_at IS NULL AND heartbeat_at IS NULL
          AND lease_expires_at IS NOT NULL AND released_at IS NULL
          AND fencing_token IS NULL AND conflict_lock_id IS NOT NULL
          AND conflict_owner_id IS NOT NULL AND wait_reason IS NOT NULL)
        OR
        (status = 'held' AND acquired_at IS NOT NULL AND heartbeat_at IS NOT NULL
          AND lease_expires_at IS NOT NULL AND released_at IS NULL
          AND fencing_token IS NOT NULL AND fencing_token > 0 AND conflict_lock_id IS NULL
          AND conflict_owner_id IS NULL AND wait_reason IS NULL)
        OR
        (status IN ('released', 'expired', 'cancelled') AND released_at IS NOT NULL
          AND conflict_lock_id IS NULL AND conflict_owner_id IS NULL
          AND wait_reason IS NULL)
      )
    )
    """
  end

  defp copy_rows_sql(existing) do
    select_expressions =
      Enum.map_join(@desired_columns, ", ", fn column -> copy_expression(column, existing) end)

    """
    INSERT INTO workspace_locks (#{Enum.join(@desired_columns, ", ")})
    SELECT #{select_expressions}
    FROM workspace_locks_legacy AS legacy
    JOIN projects ON projects.id = legacy.project_id
    """
  end

  defp copy_expression("workspace_key", existing) do
    if MapSet.member?(existing, "workspace_key") do
      "COALESCE(NULLIF(legacy.workspace_key, ''), projects.root_path)"
    else
      "projects.root_path"
    end
  end

  defp copy_expression("status", _existing) do
    "CASE legacy.status WHEN 'held' THEN 'expired' WHEN 'waiting' THEN 'cancelled' ELSE legacy.status END"
  end

  defp copy_expression("released_at", existing) do
    if MapSet.member?(existing, "released_at") do
      "CASE WHEN legacy.status IN ('held', 'waiting', 'released', 'expired', 'cancelled') " <>
        "THEN COALESCE(legacy.released_at, legacy.updated_at, legacy.requested_at) " <>
        "ELSE legacy.released_at END"
    else
      "CASE WHEN legacy.status IN ('held', 'waiting', 'released', 'expired', 'cancelled') " <>
        "THEN COALESCE(legacy.updated_at, legacy.requested_at) ELSE NULL END"
    end
  end

  defp copy_expression(column, existing)
       when column in ["conflict_lock_id", "conflict_owner_id", "wait_reason"] do
    if MapSet.member?(existing, column) do
      "CASE WHEN legacy.status IN ('held', 'waiting') THEN NULL ELSE legacy.#{column} END"
    else
      "NULL"
    end
  end

  defp copy_expression(column, existing) do
    if MapSet.member?(existing, column) do
      "legacy.#{column}"
    else
      missing_column_expression(column)
    end
  end

  defp missing_column_expression(column) when column in ["run_id", "session_id"], do: "NULL"

  defp missing_column_expression(column)
       when column in [
              "fencing_token",
              "acquired_at",
              "heartbeat_at",
              "released_at",
              "conflict_lock_id",
              "conflict_owner_id",
              "wait_reason"
            ],
       do: "NULL"

  defp missing_column_expression(column) do
    raise "cannot repair workspace_locks: legacy table is missing required column #{column}"
  end

  defp index_sql do
    [
      """
      CREATE UNIQUE INDEX workspace_locks_active_identity_index
      ON workspace_locks (owner_id, workspace_key, resource_type, resource_key, mode)
      WHERE status IN ('waiting', 'held')
      """,
      "CREATE INDEX workspace_locks_project_id_status_lease_expires_at_index ON workspace_locks (project_id, status, lease_expires_at)",
      "CREATE INDEX workspace_locks_workspace_key_status_requested_at_index ON workspace_locks (workspace_key, status, requested_at)",
      "CREATE INDEX workspace_locks_batch_id_status_index ON workspace_locks (batch_id, status)",
      "CREATE INDEX workspace_locks_run_id_status_index ON workspace_locks (run_id, status)",
      "CREATE INDEX workspace_locks_session_id_status_index ON workspace_locks (session_id, status)",
      "CREATE INDEX workspace_locks_conflict_lock_id_index ON workspace_locks (conflict_lock_id)",
      "CREATE UNIQUE INDEX workspace_locks_workspace_key_fencing_token_index ON workspace_locks (workspace_key, fencing_token)"
    ]
  end
end
