defmodule IexCode.Repo.Migrations.CreateRunStepAttempts do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :manifest_hash, :string,
        check: %{
          name: "runs_manifest_hash_shape",
          expr:
            "manifest_hash IS NULL OR (length(manifest_hash) = 64 AND manifest_hash NOT GLOB '*[^0-9a-f]*')"
        }

      add :lease_generation, :integer,
        null: false,
        default: 0,
        check: %{name: "runs_lease_generation_nonnegative", expr: "lease_generation >= 0"}
    end

    create index(:runs, [:execution_engine, :status, :priority, :inserted_at])

    alter table(:run_steps) do
      add :handler_version, :integer, null: false, default: 1
      add :effect_class, :string, null: false, default: "legacy"
      add :replay_policy, :string, null: false, default: "never"
      add :resource_spec, :map, null: false, default: %{}

      add :timeout_ms, :integer,
        check: %{
          name: "run_steps_dag_handler_shape",
          expr:
            "handler_version >= 1 AND effect_class IN ('legacy', 'pure', 'read', 'workspace_write', 'git', 'native', 'provider') AND replay_policy IN ('safe', 'checkpointed', 'never') AND (timeout_ms IS NULL OR timeout_ms BETWEEN 1 AND 86400000)"
        }
    end

    create table(:run_step_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      add :run_step_id, references(:run_steps, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_attempt, :integer, null: false
      add :attempt, :integer, null: false
      add :execution_key, :string, null: false
      add :manifest_hash, :string, null: false
      add :handler_kind, :string, null: false
      add :handler_version, :integer, null: false
      add :effect_class, :string, null: false
      add :replay_policy, :string, null: false

      add :status, :string,
        null: false,
        check: %{
          name: "run_step_attempts_status_check",
          expr:
            "status IN ('running', 'paused', 'completed', 'failed', 'cancelled', 'interrupted')"
        }

      add :progress, :integer, null: false, default: 0
      add :lease_owner, :string
      add :lease_generation, :integer, null: false
      add :lease_expires_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
      add :retry_not_before, :utc_datetime_usec
      add :checkpoint, :map
      add :checkpoint_version, :integer
      add :checkpointed_at, :utc_datetime_usec
      add :result, :map
      add :result_digest, :string
      add :error_message, :text
      add :error_details, :map
      add :started_at, :utc_datetime_usec, null: false

      add :completed_at, :utc_datetime_usec,
        check: %{
          name: "run_step_attempts_lifecycle_check",
          expr: """
          run_attempt >= 1 AND attempt >= 1 AND handler_version >= 1
          AND lease_generation >= 1 AND progress BETWEEN 0 AND 100
          AND length(manifest_hash) = 64 AND manifest_hash NOT GLOB '*[^0-9a-f]*'
          AND ((status IN ('running', 'paused')
                AND lease_owner IS NOT NULL AND length(lease_owner) = 64
                AND lease_owner NOT GLOB '*[^0-9a-f]*'
                AND lease_expires_at IS NOT NULL AND heartbeat_at IS NOT NULL
                AND completed_at IS NULL)
            OR (status IN ('completed', 'failed', 'cancelled', 'interrupted')
                AND lease_owner IS NULL AND lease_expires_at IS NULL
                AND completed_at IS NOT NULL))
          AND ((checkpoint IS NULL AND checkpoint_version IS NULL AND checkpointed_at IS NULL)
            OR (checkpoint IS NOT NULL AND checkpoint_version >= 1 AND checkpointed_at IS NOT NULL))
          AND ((status = 'completed' AND result IS NOT NULL AND length(result_digest) = 64
                AND result_digest NOT GLOB '*[^0-9a-f]*')
            OR (status != 'completed' AND (result_digest IS NULL OR (length(result_digest) = 64
                AND result_digest NOT GLOB '*[^0-9a-f]*'))))
          """
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_step_attempts, [:run_step_id, :run_attempt, :attempt],
             name: :run_step_attempts_identity_index
           )

    create unique_index(:run_step_attempts, [:run_id, :execution_key])
    create index(:run_step_attempts, [:run_id, :run_attempt, :status])
    create index(:run_step_attempts, [:run_step_id, :status, :attempt])
    create index(:run_step_attempts, [:status, :lease_expires_at])

    create unique_index(:run_steps, [:id, :run_id], name: :run_steps_id_run_id_index)

    execute(
      """
      CREATE TRIGGER run_step_attempts_same_run_insert
      BEFORE INSERT ON run_step_attempts
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1 FROM run_steps
        WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_step_attempt_scope_mismatch');
      END
      """,
      "DROP TRIGGER IF EXISTS run_step_attempts_same_run_insert"
    )

    execute(
      """
      CREATE TRIGGER run_step_attempts_same_run_update
      BEFORE UPDATE OF run_id, run_step_id ON run_step_attempts
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1 FROM run_steps
        WHERE run_steps.id = NEW.run_step_id AND run_steps.run_id = NEW.run_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_step_attempt_scope_mismatch');
      END
      """,
      "DROP TRIGGER IF EXISTS run_step_attempts_same_run_update"
    )
  end
end
