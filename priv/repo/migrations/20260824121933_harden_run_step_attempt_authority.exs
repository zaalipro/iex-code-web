defmodule IexCode.Repo.Migrations.HardenRunStepAttemptAuthority do
  use Ecto.Migration

  def change do
    alter table(:run_step_attempts) do
      add :run_lease_generation, :integer
      add :run_owner, :string
      add :claim_owner, :string
    end

    execute(
      """
      UPDATE run_step_attempts
      SET run_lease_generation = MAX(
            COALESCE(
              (SELECT runs.lease_generation FROM runs WHERE runs.id = run_step_attempts.run_id),
              1
            ),
            1
          ),
          run_owner = COALESCE(lease_owner, '#{String.duplicate("0", 64)}'),
          claim_owner = COALESCE(lease_owner, '#{String.duplicate("0", 64)}')
      WHERE run_lease_generation IS NULL OR run_owner IS NULL OR claim_owner IS NULL
      """,
      "SELECT 1"
    )

    execute(
      """
      CREATE TRIGGER run_step_attempts_authority_insert
      BEFORE INSERT ON run_step_attempts
      FOR EACH ROW
      WHEN NEW.run_lease_generation IS NULL OR NEW.run_lease_generation < 1
        OR NEW.run_owner IS NULL OR length(NEW.run_owner) != 64
        OR NEW.run_owner GLOB '*[^0-9a-f]*'
        OR NEW.claim_owner IS NULL OR length(NEW.claim_owner) != 64
        OR NEW.claim_owner GLOB '*[^0-9a-f]*'
      BEGIN
        SELECT RAISE(ABORT, 'run_step_attempt_authority_invalid');
      END
      """,
      "DROP TRIGGER IF EXISTS run_step_attempts_authority_insert"
    )

    execute(
      """
      CREATE TRIGGER run_step_attempts_authority_immutable
      BEFORE UPDATE OF run_lease_generation, run_owner, claim_owner ON run_step_attempts
      FOR EACH ROW
      WHEN NEW.run_lease_generation IS NOT OLD.run_lease_generation
        OR NEW.run_owner IS NOT OLD.run_owner
        OR NEW.claim_owner IS NOT OLD.claim_owner
      BEGIN
        SELECT RAISE(ABORT, 'run_step_attempt_authority_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS run_step_attempts_authority_immutable"
    )
  end
end
