defmodule IexCode.Repo.Migrations.HardenRunControlClaimRecovery do
  use Ecto.Migration

  def up do
    alter table(:run_controls) do
      add :target_attempt, :integer, null: false, default: 0
      add :target_generation, :integer, null: false, default: 0
      add :claim_generation, :integer
      add :claim_expires_at, :utc_datetime
    end

    # The old schema did not persist the attempt/generation a control targeted.
    # Never guess that lineage from the run's current row: doing so could make a
    # stale pre-upgrade pause/cancel/steer authoritative for a newer attempt.
    # Close every open legacy receipt first and retain zero as an explicit
    # unknown-lineage sentinel for all historical controls.
    execute("""
    UPDATE run_controls
    SET status = 'superseded',
        applied_at = COALESCE(applied_at, CURRENT_TIMESTAMP),
        result = '{"reason":"pre_migration_control_superseded","lineage":"unknown"}',
        target_attempt = 0,
        target_generation = 0
    WHERE status IN ('pending', 'claimed')
    """)

    execute("""
    UPDATE run_controls
    SET target_attempt = 0,
        target_generation = 0
    WHERE status NOT IN ('pending', 'claimed')
    """)

    execute("""
    UPDATE run_controls
    SET claim_generation = target_generation,
        claim_expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', claimed_at, '+30 seconds')
    WHERE worker_id IS NOT NULL AND claimed_at IS NOT NULL
    """)

    create index(:run_controls, [:status, :claim_expires_at],
             name: :run_controls_claim_recovery_index
           )

    create index(:run_controls, [:run_id, :target_attempt, :target_generation, :status],
             name: :run_controls_target_index
           )

    create index(:run_agent_controls, [:status], name: :run_agent_controls_status_index)
    create index(:run_approvals, [:status, :expires_at], name: :run_approvals_status_expiry_index)

    create index(:workspace_locks, [:status, :lease_expires_at],
             name: :workspace_locks_status_expiry_index
           )

    execute(
      """
      CREATE TRIGGER run_controls_current_target_insert
      BEFORE INSERT ON run_controls
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1 FROM runs
        WHERE runs.id = NEW.run_id
          AND runs.attempt = NEW.target_attempt
          AND runs.lease_generation = NEW.target_generation
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_control_target_mismatch');
      END
      """,
      "DROP TRIGGER IF EXISTS run_controls_current_target_insert"
    )

    execute(
      """
      CREATE TRIGGER run_controls_pending_target_update
      BEFORE UPDATE OF status ON run_controls
      FOR EACH ROW
      WHEN NEW.status = 'pending' AND OLD.status != 'pending' AND NOT EXISTS (
        SELECT 1 FROM runs
        WHERE runs.id = NEW.run_id
          AND runs.attempt = NEW.target_attempt
          AND runs.lease_generation = NEW.target_generation
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_control_target_mismatch');
      END
      """,
      "DROP TRIGGER IF EXISTS run_controls_pending_target_update"
    )

    execute(
      control_authority_trigger("run_controls_authority_insert", "INSERT"),
      "DROP TRIGGER IF EXISTS run_controls_authority_insert"
    )

    execute(
      control_authority_trigger("run_controls_authority_update", "UPDATE"),
      "DROP TRIGGER IF EXISTS run_controls_authority_update"
    )

    execute(
      """
      CREATE TRIGGER run_controls_target_immutable
      BEFORE UPDATE OF run_id, target_attempt, target_generation ON run_controls
      FOR EACH ROW
      WHEN NEW.run_id IS NOT OLD.run_id
        OR NEW.target_attempt IS NOT OLD.target_attempt
        OR NEW.target_generation IS NOT OLD.target_generation
      BEGIN
        SELECT RAISE(ABORT, 'run_control_target_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS run_controls_target_immutable"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS run_controls_target_immutable")
    execute("DROP TRIGGER IF EXISTS run_controls_pending_target_update")
    execute("DROP TRIGGER IF EXISTS run_controls_current_target_insert")
    execute("DROP TRIGGER IF EXISTS run_controls_authority_update")
    execute("DROP TRIGGER IF EXISTS run_controls_authority_insert")

    drop_if_exists index(:run_controls, [:run_id, :target_attempt, :target_generation, :status],
                     name: :run_controls_target_index
                   )

    drop_if_exists index(:run_controls, [:status, :claim_expires_at],
                     name: :run_controls_claim_recovery_index
                   )

    drop_if_exists index(:workspace_locks, [:status, :lease_expires_at],
                     name: :workspace_locks_status_expiry_index
                   )

    drop_if_exists index(:run_approvals, [:status, :expires_at],
                     name: :run_approvals_status_expiry_index
                   )

    drop_if_exists index(:run_agent_controls, [:status], name: :run_agent_controls_status_index)

    alter table(:run_controls) do
      remove :claim_expires_at
      remove :claim_generation
      remove :target_generation
      remove :target_attempt
    end
  end

  defp control_authority_trigger(name, operation) do
    """
    CREATE TRIGGER #{name}
    BEFORE #{operation} ON run_controls
    FOR EACH ROW
    WHEN NEW.target_attempt < 0 OR NEW.target_generation < 0
      OR (NEW.status = 'pending' AND (
        NEW.worker_id IS NOT NULL OR NEW.claim_generation IS NOT NULL
        OR NEW.claimed_at IS NOT NULL OR NEW.claim_expires_at IS NOT NULL
      ))
      OR (NEW.status IN ('claimed', 'applied', 'rejected') AND (
        NEW.worker_id IS NULL OR NEW.claim_generation IS NULL OR NEW.claim_generation < 0
        OR NEW.claim_generation != NEW.target_generation
        OR NEW.claimed_at IS NULL OR NEW.claim_expires_at IS NULL
        OR julianday(NEW.claim_expires_at) <= julianday(NEW.claimed_at)
      ))
      OR (NEW.status = 'superseded' AND (
        (NEW.worker_id IS NULL AND (
          NEW.claim_generation IS NOT NULL OR NEW.claimed_at IS NOT NULL
          OR NEW.claim_expires_at IS NOT NULL
        ))
        OR (NEW.worker_id IS NOT NULL AND (
          NEW.claim_generation IS NULL OR NEW.claim_generation < 0
          OR NEW.claim_generation != NEW.target_generation
          OR NEW.claimed_at IS NULL OR NEW.claim_expires_at IS NULL
          OR julianday(NEW.claim_expires_at) <= julianday(NEW.claimed_at)
        ))
      ))
    BEGIN
      SELECT RAISE(ABORT, 'run_control_authority_invalid');
    END
    """
  end
end
