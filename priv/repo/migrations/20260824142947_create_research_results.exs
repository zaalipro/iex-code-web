defmodule IexCode.Repo.Migrations.CreateResearchResults do
  use Ecto.Migration

  def change do
    create table(:research_results) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :objective, :text, null: false

      add :level, :string,
        null: false,
        check: %{
          name: "research_results_level_check",
          expr: "level IN ('low', 'medium', 'high', 'ultra')"
        }

      add :status, :string,
        null: false,
        default: "queued",
        check: %{
          name: "research_results_status_check",
          expr: "status IN ('queued', 'running', 'ready', 'failed', 'cancelled')"
        }

      add :result_path, :text
      add :html_path, :text
      add :markdown_sha256, :string
      add :html_sha256, :string

      add :source_count, :integer,
        null: false,
        default: 0,
        check: %{name: "research_results_source_count_check", expr: "source_count >= 0"}

      add :metadata, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:research_results, [:run_id])
    create index(:research_results, [:session_id, :status, :id])
    create index(:research_results, [:project_id, :status, :id])

    execute(
      """
      INSERT INTO research_results (
        run_id, project_id, session_id, objective, level, status, source_count,
        metadata, completed_at, inserted_at, updated_at
      )
      SELECT
        runs.id,
        runs.project_id,
        runs.session_id,
        runs.objective,
        CASE COALESCE(
          json_extract(runs.metadata, '$.research.level'),
          json_extract(runs.metadata, '$.research.depth')
        )
          WHEN 'low' THEN 'low'
          WHEN 'medium' THEN 'medium'
          WHEN 'high' THEN 'high'
          WHEN 'ultra' THEN 'ultra'
          WHEN 'quick' THEN 'low'
          WHEN 'standard' THEN 'medium'
          WHEN 'deep' THEN 'high'
          ELSE 'medium'
        END,
        CASE runs.status
          WHEN 'running' THEN 'running'
          WHEN 'failed' THEN 'failed'
          WHEN 'completed' THEN 'failed'
          WHEN 'interrupted' THEN 'failed'
          WHEN 'cancelled' THEN 'cancelled'
          ELSE 'queued'
        END,
        0,
        '{}',
        CASE runs.status
          WHEN 'failed' THEN COALESCE(runs.completed_at, runs.updated_at)
          WHEN 'completed' THEN COALESCE(runs.completed_at, runs.updated_at)
          WHEN 'interrupted' THEN COALESCE(runs.completed_at, runs.updated_at)
          WHEN 'cancelled' THEN COALESCE(runs.completed_at, runs.updated_at)
          ELSE NULL
        END,
        runs.inserted_at,
        runs.updated_at
      FROM runs
      WHERE runs.kind = 'deep_research'
      ORDER BY runs.inserted_at ASC, runs.id ASC
      """,
      "DELETE FROM research_results"
    )

    execute(
      """
      CREATE TRIGGER research_results_scope_insert
      BEFORE INSERT ON research_results
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1 FROM runs
        WHERE runs.id = NEW.run_id
          AND runs.project_id = NEW.project_id
          AND runs.session_id = NEW.session_id
          AND runs.kind = 'deep_research'
      )
      BEGIN
        SELECT RAISE(ABORT, 'research_result_scope_mismatch');
      END
      """,
      "DROP TRIGGER IF EXISTS research_results_scope_insert"
    )

    execute(
      """
      CREATE TRIGGER research_results_allocate_after_run_insert
      AFTER INSERT ON runs
      FOR EACH ROW
      WHEN NEW.kind = 'deep_research'
      BEGIN
        INSERT INTO research_results (
          run_id, project_id, session_id, objective, level, status, source_count,
          metadata, completed_at, inserted_at, updated_at
        ) VALUES (
          NEW.id,
          NEW.project_id,
          NEW.session_id,
          NEW.objective,
          CASE COALESCE(
            json_extract(NEW.metadata, '$.research.level'),
            json_extract(NEW.metadata, '$.research.depth')
          )
            WHEN 'low' THEN 'low'
            WHEN 'medium' THEN 'medium'
            WHEN 'high' THEN 'high'
            WHEN 'ultra' THEN 'ultra'
            WHEN 'quick' THEN 'low'
            WHEN 'standard' THEN 'medium'
            WHEN 'deep' THEN 'high'
            ELSE 'medium'
          END,
          CASE NEW.status
            WHEN 'running' THEN 'running'
            WHEN 'paused' THEN 'running'
            WHEN 'failed' THEN 'failed'
            WHEN 'completed' THEN 'running'
            WHEN 'interrupted' THEN 'failed'
            WHEN 'cancelled' THEN 'cancelled'
            ELSE 'queued'
          END,
          0,
          '{}',
          CASE NEW.status
            WHEN 'failed' THEN COALESCE(NEW.completed_at, NEW.updated_at)
            WHEN 'completed' THEN NULL
            WHEN 'interrupted' THEN COALESCE(NEW.completed_at, NEW.updated_at)
            WHEN 'cancelled' THEN COALESCE(NEW.completed_at, NEW.updated_at)
            ELSE NULL
          END,
          NEW.inserted_at,
          NEW.updated_at
        );
      END
      """,
      "DROP TRIGGER IF EXISTS research_results_allocate_after_run_insert"
    )

    execute(
      """
      CREATE TRIGGER research_results_sync_after_run_status
      AFTER UPDATE OF status ON runs
      FOR EACH ROW
      WHEN NEW.kind = 'deep_research'
      BEGIN
        UPDATE research_results
        SET status = CASE NEW.status
              WHEN 'running' THEN 'running'
              WHEN 'paused' THEN 'running'
              WHEN 'queued' THEN 'queued'
              WHEN 'failed' THEN 'failed'
              WHEN 'completed' THEN 'running'
              WHEN 'interrupted' THEN 'failed'
              WHEN 'cancelled' THEN 'cancelled'
              ELSE status
            END,
            completed_at = CASE NEW.status
              WHEN 'failed' THEN COALESCE(NEW.completed_at, NEW.updated_at)
              WHEN 'completed' THEN NULL
              WHEN 'interrupted' THEN COALESCE(NEW.completed_at, NEW.updated_at)
              WHEN 'cancelled' THEN COALESCE(NEW.completed_at, NEW.updated_at)
              ELSE NULL
            END,
            updated_at = NEW.updated_at
        WHERE run_id = NEW.id AND status != 'ready';
      END
      """,
      "DROP TRIGGER IF EXISTS research_results_sync_after_run_status"
    )

    execute(
      """
      CREATE TRIGGER research_results_scope_immutable
      BEFORE UPDATE OF run_id, project_id, session_id, objective, level ON research_results
      FOR EACH ROW
      WHEN NEW.run_id IS NOT OLD.run_id
        OR NEW.project_id IS NOT OLD.project_id
        OR NEW.session_id IS NOT OLD.session_id
        OR NEW.objective IS NOT OLD.objective
        OR NEW.level IS NOT OLD.level
      BEGIN
        SELECT RAISE(ABORT, 'research_result_identity_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS research_results_scope_immutable"
    )

    execute(
      lifecycle_trigger("research_results_ready_lifecycle_insert", "INSERT", nil),
      "DROP TRIGGER IF EXISTS research_results_ready_lifecycle_insert"
    )

    execute(
      lifecycle_trigger(
        "research_results_ready_lifecycle_update",
        "UPDATE",
        "OF status, result_path, html_path, markdown_sha256, html_sha256, completed_at"
      ),
      "DROP TRIGGER IF EXISTS research_results_ready_lifecycle_update"
    )
  end

  defp lifecycle_trigger(name, operation, fields) do
    operation = if fields, do: "#{operation} #{fields}", else: operation

    """
    CREATE TRIGGER #{name}
    BEFORE #{operation} ON research_results
    FOR EACH ROW
    WHEN (NEW.status = 'ready' AND (
            NEW.result_path IS NULL OR NEW.html_path IS NULL
            OR NEW.markdown_sha256 IS NULL OR NEW.html_sha256 IS NULL
            OR length(NEW.markdown_sha256) != 64
            OR NEW.markdown_sha256 GLOB '*[^0-9a-f]*'
            OR length(NEW.html_sha256) != 64
            OR NEW.html_sha256 GLOB '*[^0-9a-f]*'
            OR NEW.completed_at IS NULL
          ))
      OR (NEW.status != 'ready' AND (
            NEW.result_path IS NOT NULL OR NEW.html_path IS NOT NULL
            OR NEW.markdown_sha256 IS NOT NULL OR NEW.html_sha256 IS NOT NULL
          ))
    BEGIN
      SELECT RAISE(ABORT, 'research_result_lifecycle_invalid');
    END
    """
  end
end
