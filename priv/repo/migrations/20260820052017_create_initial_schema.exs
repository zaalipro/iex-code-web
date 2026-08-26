defmodule IexCode.Repo.Migrations.CreateInitialSchema do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :root_path, :string, null: false
      add :description, :string
      add :last_opened_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:root_path])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :title, :string, null: false
      add :swarm_mode, :boolean, default: false, null: false
      add :model_provider, :string, default: "anthropic", null: false
      add :model_name, :string, default: "claude-3-7-sonnet", null: false
      add :temperature, :float, default: 0.2
      add :status, :string, default: "idle", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:project_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, on_delete: :delete_all, type: :binary_id),
        null: false

      add :role, :string, null: false
      add :agent_name, :string, default: "assistant"
      add :content, :text, null: false
      add :tool_calls, :map
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:session_id])

    create table(:operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, on_delete: :delete_all, type: :binary_id),
        null: false

      add :parent_op_id, :binary_id
      add :agent_name, :string, null: false
      add :op_type, :string, null: false
      add :title, :string, null: false
      add :status, :string, default: "pending", null: false
      add :progress, :integer, default: 0, null: false
      add :pid_str, :string
      add :params, :map
      add :result, :text
      add :error_message, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:operations, [:session_id])
    create index(:operations, [:parent_op_id])

    create table(:app_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :anthropic_api_key, :string
      add :anthropic_base_url, :string, default: "https://api.anthropic.com"
      add :openai_api_key, :string
      add :openai_base_url, :string, default: "https://api.openai.com/v1"
      add :default_model_provider, :string, default: "anthropic"
      add :default_model, :string, default: "claude-3-7-sonnet"
      add :swarm_agent_count, :integer, default: 4
      add :auto_save, :boolean, default: true

      timestamps(type: :utc_datetime)
    end
  end
end
