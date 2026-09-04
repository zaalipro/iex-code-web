defmodule IexCode.Repo.Migrations.EnrichMutationSnapshots do
  use Ecto.Migration

  def change do
    alter table(:mutation_snapshots) do
      add :seq, :integer, default: 1
      add :status, :string, default: "active"
      add :label, :string
      add :diff_summary, :string
    end

    create index(:mutation_snapshots, [:session_id, :seq])
  end
end
