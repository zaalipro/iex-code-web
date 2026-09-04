defmodule IexCode.Repo.Migrations.CreateWorkflowsAndWorkflowRuns do
  use Ecto.Migration

  def change do
    # --------------------------------------------------------------------------
    # Workflows Table (Reusable Workflow Blueprint / Template)
    # --------------------------------------------------------------------------
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :tags, {:array, :string}, null: false, default: []
      add :version, :integer, null: false, default: 1
      add :is_active, :boolean, null: false, default: true

      # Variable definitions:
      # [%{"name" => "feature_name", "type" => "string", "default" => "", "description" => "...", "required" => true}]
      add :variables, {:array, :map}, null: false, default: []

      # DAG Step specifications:
      # [%{"key" => "step_1", "kind" => "deep_research", "title" => "...", "depends_on" => [], ...}]
      add :steps, {:array, :map}, null: false, default: []

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflows, [:project_id, :slug])
    create index(:workflows, [:project_id, :is_active])
    create index(:workflows, [:project_id, :inserted_at])

    # --------------------------------------------------------------------------
    # Workflow Runs Table (Materialized Execution Instance)
    # --------------------------------------------------------------------------
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :progress, :integer, null: false, default: 0

      # Resolved inputs provided at launch: %{"feature_name" => "Authentication"}
      add :inputs, :map, null: false, default: %{}

      # Materialized steps snapshot with variables interpolated
      add :resolved_steps, {:array, :map}, null: false, default: []

      # Live status map for each step:
      # %{"step_1" => %{"status" => "completed", "output" => %{...}, "duration_ms" => 1420}}
      add :step_states, :map, null: false, default: %{}

      add :current_step_key, :string
      add :error_message, :text
      add :error_details, :map

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :duration_ms, :integer, null: false, default: 0

      add :started_at, :utc_datetime
      add :paused_at, :utc_datetime
      add :completed_at, :utc_datetime

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_runs, [:workflow_id, :inserted_at])
    create index(:workflow_runs, [:project_id, :status, :inserted_at])
    create index(:workflow_runs, [:session_id, :inserted_at])
    create index(:workflow_runs, [:run_id])
  end
end
