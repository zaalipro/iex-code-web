defmodule IexCode.Repo.Migrations.AddRunToMutationSnapshots do
  use Ecto.Migration

  def change do
    alter table(:mutation_snapshots) do
      # A durable-run snapshot must never silently become a legacy
      # session-scoped snapshot when its owning run is removed. Cascading the
      # manifest keeps rollback ownership fail-closed instead of broadening it.
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all)
    end

    create index(:mutation_snapshots, [:run_id, :created_at])
  end
end
