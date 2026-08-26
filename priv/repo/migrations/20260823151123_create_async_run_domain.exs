defmodule IexCode.Repo.Migrations.CreateAsyncRunDomain do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :objective, :text, null: false
      add :kind, :string, null: false, default: "coding_swarm"
      add :status, :string, null: false, default: "queued"
      add :mode, :string, null: false, default: "swarm"
      add :priority, :string, null: false, default: "normal"
      add :progress, :integer, null: false, default: 0
      add :event_sequence, :integer, null: false, default: 0
      add :token_budget, :integer
      add :cost_budget_cents, :integer
      add :time_budget_ms, :integer
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}
      add :error_message, :text
      add :error_details, :map
      add :started_at, :utc_datetime
      add :heartbeat_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime
      add :cancellation_requested_at, :utc_datetime
      add :not_before, :utc_datetime
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3

      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:project_id, :inserted_at])
    create index(:runs, [:session_id, :inserted_at])
    create index(:runs, [:status, :priority, :inserted_at])
    create index(:runs, [:status, :lease_expires_at, :not_before])

    create table(:run_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_step_id, references(:run_steps, type: :binary_id, on_delete: :nilify_all)
      add :key, :string, null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :position, :integer, null: false, default: 0
      add :progress, :integer, null: false, default: 0
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 1
      add :depends_on, {:array, :string}, null: false, default: []
      add :params, :map, null: false, default: %{}
      add :result, :map
      add :error_message, :text
      add :error_details, :map
      add :started_at, :utc_datetime
      add :heartbeat_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_steps, [:run_id, :key])
    create index(:run_steps, [:run_id, :status, :position])
    create index(:run_steps, [:parent_step_id])

    create table(:run_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :type, :string, null: false
      add :source, :string, null: false, default: "system"
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:run_events, [:run_id, :sequence])
    create index(:run_events, [:run_id, :type, :sequence])

    create table(:run_commands, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :run_step_id, references(:run_steps, type: :binary_id, on_delete: :nilify_all)
      add :idempotency_key, :string, null: false
      add :tool_name, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :arguments, :map, null: false, default: %{}
      add :output, :text
      add :error_message, :text
      add :error_details, :map
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 1
      add :not_before, :utc_datetime
      add :claimed_at, :utc_datetime
      add :heartbeat_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_commands, [:run_id, :idempotency_key])
    create index(:run_commands, [:run_id, :status, :not_before])
    create index(:run_commands, [:run_step_id])

    create table(:run_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :run_command_id, references(:run_commands, type: :binary_id, on_delete: :nilify_all)
      add :key, :string, null: false
      add :action, :string, null: false
      add :resource, :string
      add :reason, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_by, :string, null: false, default: "system"
      add :decided_by, :string
      add :decision_note, :text
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime
      add :decided_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_approvals, [:run_id, :key])
    create index(:run_approvals, [:run_id, :status, :inserted_at])
    create index(:run_approvals, [:run_command_id])

    create table(:run_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :run_step_id, references(:run_steps, type: :binary_id, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :name, :string, null: false
      add :uri, :text, null: false
      add :media_type, :string
      add :byte_size, :integer
      add :checksum, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:run_artifacts, [:run_id, :kind, :inserted_at])
    create index(:run_artifacts, [:run_step_id])
  end
end
