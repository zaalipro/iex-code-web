defmodule IexCode.Repo.Migrations.AddReasoningAndProviderSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :default_reasoning_effort, :string, null: false, default: "medium"
      add :default_thinking_budget, :integer, null: false, default: 4096
      add :model_overrides, :map, null: false, default: %{}
    end
  end
end
