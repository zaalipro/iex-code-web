defmodule IexCode.Repo.Migrations.AddSubtasksAndSettingsFields do
  use Ecto.Migration

  def change do
    alter table(:kanban_tasks) do
      add :subtasks, {:array, :map}, default: []
    end

    alter table(:app_settings) do
      add :temperature, :float, default: 0.2
      add :max_tokens, :integer, default: 4096
    end
  end
end
