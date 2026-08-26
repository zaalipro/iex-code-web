defmodule IexCode.Repo.Migrations.CreateDurableRunAgentFleet do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :execution_engine, :string,
        null: false,
        default: "legacy_v1",
        check: %{
          name: "runs_execution_engine_check",
          expr: "execution_engine IN ('legacy_v1', 'dag_v1')"
        }
    end

    create table(:run_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_agent_id, references(:run_agents, type: :binary_id, on_delete: :nilify_all)
      add :run_attempt, :integer, null: false
      add :key, :string, null: false
      add :role, :string, null: false
      add :adapter, :string, null: false
      add :display_name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :required, :boolean, null: false, default: true

      add :status, :string,
        null: false,
        default: "pending",
        check: %{
          name: "run_agents_status_check",
          expr:
            "status IN ('pending', 'starting', 'idle', 'running', 'paused', 'stopping', 'completed', 'failed', 'cancelled', 'interrupted')"
        }

      add :desired_state, :string,
        null: false,
        default: "active",
        check: %{
          name: "run_agents_desired_state_check",
          expr: "desired_state IN ('active', 'paused', 'stopped')"
        }

      add :progress, :integer, null: false, default: 0
      add :current_task, :text
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :lease_owner, :string
      add :lease_generation, :integer, null: false, default: 0
      add :lease_expires_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
      add :control_sequence, :integer, null: false, default: 0
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :latency_ms, :integer, null: false, default: 0
      add :request_count, :integer, null: false, default: 0
      add :last_latency_ms, :integer, null: false, default: 0
      add :average_latency_ms, :integer, null: false, default: 0
      add :restart_count, :integer, null: false, default: 0
      add :model_provider, :string
      add :model_name, :string
      add :capabilities, {:array, :string}, null: false, default: []
      add :config, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :result, :map
      add :error_message, :text
      add :error_details, :map
      add :started_at, :utc_datetime_usec
      add :last_active_at, :utc_datetime_usec

      add :completed_at, :utc_datetime_usec,
        check: %{
          name: "run_agents_lifecycle_check",
          expr: """
          ((status = 'pending' AND lease_owner IS NULL AND lease_expires_at IS NULL
            AND heartbeat_at IS NULL AND completed_at IS NULL)
          OR
          (status IN ('starting', 'idle', 'running', 'paused', 'stopping')
            AND lease_owner IS NOT NULL AND length(lease_owner) = 64
            AND lease_owner NOT GLOB '*[^0-9a-f]*'
            AND lease_generation > 0 AND lease_expires_at IS NOT NULL
            AND heartbeat_at IS NOT NULL AND completed_at IS NULL)
          OR
          (status = 'interrupted' AND lease_owner IS NULL AND lease_expires_at IS NULL
            AND completed_at IS NULL)
          OR
          (status IN ('completed', 'failed', 'cancelled') AND lease_owner IS NULL
            AND lease_expires_at IS NULL AND completed_at IS NOT NULL))
          AND run_attempt >= 0 AND position >= 0 AND progress BETWEEN 0 AND 100
          AND attempt >= 0 AND max_attempts BETWEEN 1 AND 100 AND attempt <= max_attempts
          AND lease_generation >= 0 AND control_sequence >= 0
          AND input_tokens >= 0 AND output_tokens >= 0 AND cost_cents >= 0 AND latency_ms >= 0
          AND request_count >= 0 AND last_latency_ms >= 0 AND average_latency_ms >= 0
          AND restart_count >= 0
          """
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_agents, [:run_id, :run_attempt, :key],
             name: :run_agents_run_attempt_key_index
           )

    create unique_index(:run_agents, [:run_id, :key],
             where: "status IN ('pending', 'starting', 'idle', 'running', 'paused', 'stopping')",
             name: :run_agents_live_key_index
           )

    create index(:run_agents, [:run_id, :run_attempt, :position, :inserted_at])
    create index(:run_agents, [:run_id, :status, :position])
    create index(:run_agents, [:status, :lease_expires_at])
    create index(:run_agents, [:lease_owner, :status])
    create index(:run_agents, [:parent_agent_id])

    create table(:run_agent_controls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      add :run_agent_id, references(:run_agents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_generation, :integer, null: false
      add :sequence, :integer, null: false
      add :idempotency_key, :string, null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "run_agent_controls_kind_check",
          expr: "kind IN ('pause', 'resume', 'cancel', 'steer', 'restart')"
        }

      add :status, :string,
        null: false,
        default: "pending",
        check: %{
          name: "run_agent_controls_status_check",
          expr: "status IN ('pending', 'claimed', 'applied', 'rejected', 'superseded')"
        }

      add :payload, :map, null: false, default: %{}
      add :result, :map
      add :requested_by, :string, null: false, default: "local-user"
      add :claim_owner, :string
      add :claim_generation, :integer
      add :claimed_at, :utc_datetime_usec

      add :resolved_at, :utc_datetime_usec,
        check: %{
          name: "run_agent_controls_lifecycle_check",
          expr: """
          ((status = 'pending' AND claim_owner IS NULL AND claim_generation IS NULL
            AND claimed_at IS NULL AND resolved_at IS NULL AND result IS NULL)
          OR
          (status = 'claimed' AND claim_owner IS NOT NULL AND length(claim_owner) > 0
            AND length(claim_owner) = 64 AND claim_owner NOT GLOB '*[^0-9a-f]*'
            AND claim_generation IS NOT NULL AND claimed_at IS NOT NULL
            AND resolved_at IS NULL AND result IS NULL)
          OR
          (status IN ('applied', 'rejected') AND claim_owner IS NOT NULL
            AND length(claim_owner) = 64 AND claim_owner NOT GLOB '*[^0-9a-f]*'
            AND claim_generation IS NOT NULL
            AND claimed_at IS NOT NULL AND resolved_at IS NOT NULL AND result IS NOT NULL)
          OR
          (status = 'superseded' AND resolved_at IS NOT NULL AND result IS NOT NULL))
          AND target_generation >= 0 AND sequence > 0
          AND (claim_generation IS NULL OR claim_generation >= 0)
          """
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_agent_controls, [:run_agent_id, :idempotency_key])
    create unique_index(:run_agent_controls, [:run_agent_id, :sequence])
    create index(:run_agent_controls, [:run_agent_id, :status, :sequence])
    create index(:run_agent_controls, [:run_id, :status, :inserted_at])
  end
end
