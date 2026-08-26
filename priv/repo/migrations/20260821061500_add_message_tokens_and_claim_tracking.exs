defmodule IexCode.Repo.Migrations.AddMessageTokensAndClaimTracking do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cost_cents, :integer, default: 0
    end

    alter table(:kanban_tasks) do
      add :claimed_at, :utc_datetime
    end

    create index(:kanban_tasks, [:session_id])

    # Enforce a single app_settings row: every row evaluates to 1, so a second
    # row violates the unique index (NULLs are exempt, but id is never NULL).
    create unique_index(:app_settings, ["(CASE WHEN id IS NOT NULL THEN 1 ELSE NULL END)"],
             name: :app_settings_singleton_index
           )
  end
end
