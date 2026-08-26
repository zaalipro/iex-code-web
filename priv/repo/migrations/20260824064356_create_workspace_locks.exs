defmodule IexCode.Repo.Migrations.CreateWorkspaceLocks do
  use Ecto.Migration

  def change do
    create table(:workspace_locks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The Projects context rejects deletion while active leases exist; once
      # inactive, project-local lock history follows the project lifecycle.
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :workspace_key, :text, null: false

      add :resource_type, :string,
        null: false,
        check: %{
          name: "workspace_locks_resource_type_check",
          expr: "resource_type IN ('project', 'file', 'git')"
        }

      add :resource_key, :text, null: false
      add :batch_id, :binary_id, null: false

      add :mode, :string,
        null: false,
        check: %{
          name: "workspace_locks_mode_check",
          expr: "mode IN ('read', 'write', 'exclusive')"
        }

      add :status, :string,
        null: false,
        default: "waiting",
        check: %{
          name: "workspace_locks_status_check",
          expr: "status IN ('waiting', 'held', 'released', 'expired', 'cancelled')"
        }

      add :owner_id, :string, null: false

      add :capability_token_hash, :string,
        null: false,
        check: %{
          name: "workspace_locks_capability_hash_check",
          expr:
            "length(capability_token_hash) = 64 AND capability_token_hash NOT GLOB '*[^0-9a-f]*'"
        }

      add :fencing_token, :integer
      add :requested_at, :utc_datetime_usec, null: false
      add :acquired_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
      add :lease_expires_at, :utc_datetime_usec

      add :released_at, :utc_datetime_usec,
        check: %{
          name: "workspace_locks_lifecycle_check",
          expr: """
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
          """
        }

      add :conflict_lock_id,
          references(:workspace_locks, type: :binary_id, on_delete: :nilify_all)

      add :conflict_owner_id, :string
      add :wait_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :workspace_locks,
             [:owner_id, :workspace_key, :resource_type, :resource_key, :mode],
             where: "status IN ('waiting', 'held')",
             name: :workspace_locks_active_identity_index
           )

    create index(:workspace_locks, [:project_id, :status, :lease_expires_at])
    create index(:workspace_locks, [:workspace_key, :status, :requested_at])
    create index(:workspace_locks, [:batch_id, :status])
    create index(:workspace_locks, [:run_id, :status])
    create index(:workspace_locks, [:session_id, :status])
    create index(:workspace_locks, [:conflict_lock_id])
    create unique_index(:workspace_locks, [:workspace_key, :fencing_token])
  end
end
