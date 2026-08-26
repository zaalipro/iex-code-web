defmodule IexCode.Repo.Migrations.CreateKanbanTasks do
  use Ecto.Migration

  def change do
    create table(:kanban_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, default: "triage", null: false
      add :priority, :string, default: "medium", null: false
      add :assignee, :string, default: "default"
      add :worker_pid, :string
      add :estimate, :string
      add :latest_summary, :text
      add :tags, {:array, :string}, default: []
      add :steps_completed, :integer, default: 0
      add :steps_total, :integer, default: 0
      add :scheduled_at, :utc_datetime
      add :cron_expression, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:kanban_tasks, [:project_id])
    create index(:kanban_tasks, [:status])
    create index(:kanban_tasks, [:scheduled_at])
  end
end
