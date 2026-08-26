defmodule IexCode.Repo.Migrations.EnforceRunChildScopeIntegrity do
  use Ecto.Migration

  def up do
    # A mismatched project/session pair has ambiguous workspace authority and
    # cannot be repaired without guessing which owner was intended. Preserve
    # the graph and fail the deploy for manual repair rather than silently
    # reassigning or deleting durable run history.
    execute("DROP TABLE IF EXISTS temp.run_owner_scope_migration_guard")

    execute("""
    CREATE TEMP TABLE run_owner_scope_migration_guard (
      violation_count INTEGER NOT NULL CHECK (violation_count = 0)
    )
    """)

    execute("""
    INSERT INTO run_owner_scope_migration_guard (violation_count)
    SELECT COUNT(*)
    FROM runs
    WHERE NOT EXISTS (
      SELECT 1 FROM sessions
      WHERE sessions.id = runs.session_id AND sessions.project_id = runs.project_id
    )
    """)

    execute("DROP TABLE run_owner_scope_migration_guard")

    execute("""
    CREATE TRIGGER sessions_project_immutable
    BEFORE UPDATE OF project_id ON sessions
    FOR EACH ROW
    WHEN NEW.project_id IS NOT OLD.project_id
    BEGIN
      SELECT RAISE(ABORT, 'session_project_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER runs_session_project_scope_insert
    BEFORE INSERT ON runs
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1 FROM sessions
      WHERE sessions.id = NEW.session_id AND sessions.project_id = NEW.project_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_session_project_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER runs_owner_immutable
    BEFORE UPDATE OF project_id, session_id ON runs
    FOR EACH ROW
    WHEN NEW.project_id IS NOT OLD.project_id OR NEW.session_id IS NOT OLD.session_id
    BEGIN
      SELECT RAISE(ABORT, 'run_owner_immutable');
    END
    """)

    alter table(:run_approvals) do
      add :target_attempt, :integer, null: false, default: 0
      add :target_generation, :integer, null: false, default: 0
    end

    # Historical rows predate lineage capture, so zero remains an explicit
    # unknown sentinel. Never assign the run's current lineage retroactively:
    # doing that could falsely legitimize an approval from an older attempt.
    execute("""
    UPDATE run_approvals
    SET status = 'cancelled',
        decided_by = COALESCE(decided_by, 'migration'),
        decision_note = COALESCE(decision_note, 'Cancelled during approval lineage upgrade'),
        decided_at = COALESCE(decided_at, CURRENT_TIMESTAMP)
    WHERE status = 'pending'
    """)

    create index(
             :run_approvals,
             [:run_id, :status, :target_attempt, :target_generation],
             name: :run_approvals_pending_lineage_index,
             where: "status = 'pending'"
           )

    # Optional child references are repaired conservatively. The enclosing run
    # remains authoritative, so an invalid optional parent is removed rather
    # than silently moving the child to another run.
    execute("""
    UPDATE run_steps
    SET parent_step_id = NULL
    WHERE parent_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps AS parent
      WHERE parent.id = run_steps.parent_step_id AND parent.run_id = run_steps.run_id
    )
    """)

    execute("""
    UPDATE run_commands
    SET run_step_id = NULL
    WHERE run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = run_commands.run_step_id AND run_steps.run_id = run_commands.run_id
    )
    """)

    execute("""
    UPDATE run_approvals
    SET run_command_id = NULL
    WHERE run_command_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_commands
      WHERE run_commands.id = run_approvals.run_command_id
        AND run_commands.run_id = run_approvals.run_id
    )
    """)

    execute("""
    UPDATE run_artifacts
    SET run_step_id = NULL
    WHERE run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = run_artifacts.run_step_id AND run_steps.run_id = run_artifacts.run_id
    )
    """)

    execute("""
    UPDATE run_agents
    SET parent_agent_id = NULL
    WHERE parent_agent_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_agents AS parent
      WHERE parent.id = run_agents.parent_agent_id
        AND parent.run_id = run_agents.run_id
        AND parent.run_attempt = run_agents.run_attempt
    )
    """)

    # A control's durable target agent is authoritative. Preserve its audit
    # receipt while repairing any historically inconsistent duplicate run id.
    execute("""
    UPDATE run_agent_controls
    SET run_id = (
      SELECT run_agents.run_id FROM run_agents
      WHERE run_agents.id = run_agent_controls.run_agent_id
    )
    WHERE EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = run_agent_controls.run_agent_id
        AND run_agents.run_id != run_agent_controls.run_id
    )
    """)

    execute("""
    DELETE FROM run_agent_controls
    WHERE NOT EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = run_agent_controls.run_agent_id
    )
    """)

    # Attempts have required ownership and cannot be safely reassigned. Earlier
    # migrations already install matching insert/update triggers; this cleanup
    # also makes an upgraded database fail closed if historical rows predate
    # that enforcement.
    execute("""
    DELETE FROM run_step_attempts
    WHERE NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = run_step_attempts.run_step_id
        AND run_steps.run_id = run_step_attempts.run_id
    )
    """)

    execute("""
    CREATE TRIGGER run_approvals_current_lineage_insert
    BEFORE INSERT ON run_approvals
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1 FROM runs
      WHERE runs.id = NEW.run_id
        AND runs.attempt = NEW.target_attempt
        AND runs.lease_generation = NEW.target_generation
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_approval_lineage_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_approvals_pending_lineage_update
    BEFORE UPDATE OF status ON run_approvals
    FOR EACH ROW
    WHEN NEW.status = 'pending' AND OLD.status != 'pending' AND NOT EXISTS (
      SELECT 1 FROM runs
      WHERE runs.id = NEW.run_id
        AND runs.attempt = NEW.target_attempt
        AND runs.lease_generation = NEW.target_generation
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_approval_lineage_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_approvals_lineage_immutable
    BEFORE UPDATE OF run_id, target_attempt, target_generation ON run_approvals
    FOR EACH ROW
    WHEN NEW.run_id != OLD.run_id
      OR NEW.target_attempt != OLD.target_attempt
      OR NEW.target_generation != OLD.target_generation
    BEGIN
      SELECT RAISE(ABORT, 'run_approval_lineage_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_steps_same_run_parent_insert
    BEFORE INSERT ON run_steps
    FOR EACH ROW
    WHEN NEW.parent_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.parent_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_step_parent_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_events_owner_immutable
    BEFORE UPDATE OF run_id ON run_events
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id
    BEGIN
      SELECT RAISE(ABORT, 'run_event_owner_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_steps_same_run_parent_update
    BEFORE UPDATE OF run_id, parent_step_id ON run_steps
    FOR EACH ROW
    WHEN NEW.parent_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.parent_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_step_parent_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_steps_owner_immutable
    BEFORE UPDATE OF run_id ON run_steps
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id
    BEGIN
      SELECT RAISE(ABORT, 'run_step_owner_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_commands_same_run_step_insert
    BEFORE INSERT ON run_commands
    FOR EACH ROW
    WHEN NEW.run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_command_step_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_commands_same_run_step_update
    BEFORE UPDATE OF run_id, run_step_id ON run_commands
    FOR EACH ROW
    WHEN NEW.run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_command_step_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_commands_owner_immutable
    BEFORE UPDATE OF run_id ON run_commands
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id
    BEGIN
      SELECT RAISE(ABORT, 'run_command_owner_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_approvals_same_run_command_insert
    BEFORE INSERT ON run_approvals
    FOR EACH ROW
    WHEN NEW.run_command_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_commands
      WHERE run_commands.id = NEW.run_command_id AND run_commands.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_approval_command_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_approvals_same_run_command_update
    BEFORE UPDATE OF run_id, run_command_id ON run_approvals
    FOR EACH ROW
    WHEN NEW.run_command_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_commands
      WHERE run_commands.id = NEW.run_command_id AND run_commands.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_approval_command_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_artifacts_same_run_step_insert
    BEFORE INSERT ON run_artifacts
    FOR EACH ROW
    WHEN NEW.run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_artifact_step_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_artifacts_same_run_step_update
    BEFORE UPDATE OF run_id, run_step_id ON run_artifacts
    FOR EACH ROW
    WHEN NEW.run_step_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_steps
      WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_artifact_step_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_artifacts_owner_immutable
    BEFORE UPDATE OF run_id ON run_artifacts
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id
    BEGIN
      SELECT RAISE(ABORT, 'run_artifact_owner_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_step_attempts_target_immutable
    BEFORE UPDATE OF run_id, run_step_id ON run_step_attempts
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id OR NEW.run_step_id IS NOT OLD.run_step_id
    BEGIN
      SELECT RAISE(ABORT, 'run_step_attempt_target_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_agents_same_run_parent_insert
    BEFORE INSERT ON run_agents
    FOR EACH ROW
    WHEN NEW.parent_agent_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = NEW.parent_agent_id
        AND run_agents.run_id = NEW.run_id
        AND run_agents.run_attempt = NEW.run_attempt
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_parent_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_agents_same_run_parent_update
    BEFORE UPDATE OF run_id, run_attempt, parent_agent_id ON run_agents
    FOR EACH ROW
    WHEN NEW.parent_agent_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = NEW.parent_agent_id
        AND run_agents.run_id = NEW.run_id
        AND run_agents.run_attempt = NEW.run_attempt
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_parent_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_agents_owner_lineage_immutable
    BEFORE UPDATE OF run_id, run_attempt ON run_agents
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id OR NEW.run_attempt IS NOT OLD.run_attempt
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_owner_lineage_immutable');
    END
    """)

    execute("""
    CREATE TRIGGER run_agent_controls_same_run_agent_insert
    BEFORE INSERT ON run_agent_controls
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = NEW.run_agent_id AND run_agents.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_control_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_agent_controls_same_run_agent_update
    BEFORE UPDATE OF run_id, run_agent_id ON run_agent_controls
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1 FROM run_agents
      WHERE run_agents.id = NEW.run_agent_id AND run_agents.run_id = NEW.run_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_control_scope_mismatch');
    END
    """)

    execute("""
    CREATE TRIGGER run_agent_controls_target_immutable
    BEFORE UPDATE OF run_id, run_agent_id ON run_agent_controls
    FOR EACH ROW
    WHEN NEW.run_id IS NOT OLD.run_id OR NEW.run_agent_id IS NOT OLD.run_agent_id
    BEGIN
      SELECT RAISE(ABORT, 'run_agent_control_target_immutable');
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS run_step_attempts_target_immutable")
    execute("DROP TRIGGER IF EXISTS run_artifacts_owner_immutable")
    execute("DROP TRIGGER IF EXISTS run_events_owner_immutable")
    execute("DROP TRIGGER IF EXISTS runs_owner_immutable")
    execute("DROP TRIGGER IF EXISTS runs_session_project_scope_insert")
    execute("DROP TRIGGER IF EXISTS sessions_project_immutable")
    execute("DROP TRIGGER IF EXISTS run_agent_controls_target_immutable")
    execute("DROP TRIGGER IF EXISTS run_agents_owner_lineage_immutable")
    execute("DROP TRIGGER IF EXISTS run_commands_owner_immutable")
    execute("DROP TRIGGER IF EXISTS run_steps_owner_immutable")
    execute("DROP TRIGGER IF EXISTS run_approvals_lineage_immutable")
    execute("DROP TRIGGER IF EXISTS run_approvals_pending_lineage_update")
    execute("DROP TRIGGER IF EXISTS run_approvals_current_lineage_insert")
    execute("DROP TRIGGER IF EXISTS run_agent_controls_same_run_agent_update")
    execute("DROP TRIGGER IF EXISTS run_agent_controls_same_run_agent_insert")
    execute("DROP TRIGGER IF EXISTS run_agents_same_run_parent_update")
    execute("DROP TRIGGER IF EXISTS run_agents_same_run_parent_insert")
    execute("DROP TRIGGER IF EXISTS run_artifacts_same_run_step_update")
    execute("DROP TRIGGER IF EXISTS run_artifacts_same_run_step_insert")
    execute("DROP TRIGGER IF EXISTS run_approvals_same_run_command_update")
    execute("DROP TRIGGER IF EXISTS run_approvals_same_run_command_insert")
    execute("DROP TRIGGER IF EXISTS run_commands_same_run_step_update")
    execute("DROP TRIGGER IF EXISTS run_commands_same_run_step_insert")
    execute("DROP TRIGGER IF EXISTS run_steps_same_run_parent_update")
    execute("DROP TRIGGER IF EXISTS run_steps_same_run_parent_insert")

    drop_if_exists index(:run_approvals, [], name: :run_approvals_pending_lineage_index)

    alter table(:run_approvals) do
      remove :target_generation
      remove :target_attempt
    end
  end
end
