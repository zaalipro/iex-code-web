defmodule IexCode.Repo.Migrations.AddResearchAndRunControlPlane do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :search_providers, :map,
        null: false,
        default: %{
          "duckduckgo" => %{"enabled" => true},
          "tavily" => %{"enabled" => false},
          "brave" => %{"enabled" => false},
          "exa" => %{"enabled" => false},
          "serper" => %{"enabled" => false},
          "searxng" => %{"enabled" => false},
          "google" => %{"enabled" => false},
          "bing" => %{"enabled" => false}
        }

      add :search_provider_order, {:array, :string},
        null: false,
        default: ~w(tavily brave exa serper google bing searxng duckduckgo)

      add :research_depth, :string, null: false, default: "standard"
      add :research_max_sources, :integer, null: false, default: 12
      add :research_parallelism, :integer, null: false, default: 4
    end

    alter table(:runs) do
      add :control_sequence, :integer, null: false, default: 0
    end

    create table(:run_controls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :sequence, :integer, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map, null: false, default: %{}
      add :result, :map
      add :requested_by, :string, null: false, default: "local-user"
      add :worker_id, :string
      add :claimed_at, :utc_datetime
      add :applied_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_controls, [:run_id, :idempotency_key])
    create unique_index(:run_controls, [:run_id, :sequence])
    create index(:run_controls, [:run_id, :status, :sequence])
  end
end
