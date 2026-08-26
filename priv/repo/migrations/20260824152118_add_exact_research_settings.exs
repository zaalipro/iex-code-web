defmodule IexCode.Repo.Migrations.AddExactResearchSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :research_level, :string,
        null: false,
        default: "medium",
        check: %{
          name: "app_settings_research_level_check",
          expr: "research_level IN ('low', 'medium', 'high', 'ultra')"
        }

      add :research_require_conflict_audit, :boolean, null: false, default: true
      add :research_max_cost_cents, :integer
      add :research_max_tokens, :integer
      add :research_time_budget_minutes, :integer
    end
  end
end
