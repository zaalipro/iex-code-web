defmodule IexCode.Repo.Migrations.EnforceKanbanTaskSessionScope do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE kanban_tasks
    SET session_id = NULL
    WHERE session_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM sessions
        WHERE sessions.id = kanban_tasks.session_id
          AND sessions.project_id = kanban_tasks.project_id
      )
    """)

    execute("""
    CREATE TRIGGER kanban_tasks_session_scope_insert
    BEFORE INSERT ON kanban_tasks
    FOR EACH ROW
    WHEN NEW.session_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM sessions
        WHERE sessions.id = NEW.session_id
          AND sessions.project_id = NEW.project_id
      )
    BEGIN
      SELECT RAISE(ABORT, 'kanban_task_session_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER kanban_tasks_session_scope_update
    BEFORE UPDATE OF project_id, session_id ON kanban_tasks
    FOR EACH ROW
    WHEN NEW.session_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM sessions
        WHERE sessions.id = NEW.session_id
          AND sessions.project_id = NEW.project_id
      )
    BEGIN
      SELECT RAISE(ABORT, 'kanban_task_session_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER kanban_tasks_scope_immutable
    BEFORE UPDATE OF project_id ON kanban_tasks
    FOR EACH ROW
    WHEN NEW.project_id IS NOT OLD.project_id
    BEGIN
      SELECT RAISE(ABORT, 'kanban_task_scope_immutable');
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS kanban_tasks_scope_immutable")
    execute("DROP TRIGGER IF EXISTS kanban_tasks_session_scope_update")
    execute("DROP TRIGGER IF EXISTS kanban_tasks_session_scope_insert")
  end
end
