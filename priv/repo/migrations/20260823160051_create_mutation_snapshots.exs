defmodule IexCode.Repo.Migrations.CreateMutationSnapshots do
  use Ecto.Migration

  def change do
    create table(:mutation_snapshots, primary_key: false) do
      add :transaction_id, :string, primary_key: true
      add :session_id, :string
      add :project_root, :text, null: false
      add :patches, {:array, :map}, null: false, default: []
      add :created_at, :utc_datetime, null: false
    end

    create index(:mutation_snapshots, [:session_id, :created_at])
  end
end
