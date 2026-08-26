defmodule IexCode.Repo.Migrations.AddRunRequestKey do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add :request_key, :string
    end

    create unique_index(:runs, [:session_id, :request_key],
             name: :runs_session_id_request_key_index
           )

    create index(:runs, [:status, :updated_at], name: :runs_status_updated_at_index)

    create index(:run_agents, [:status, :updated_at], name: :run_agents_status_updated_at_index)

    execute(
      """
      CREATE TRIGGER runs_request_key_immutable
      BEFORE UPDATE OF request_key ON runs
      FOR EACH ROW
      WHEN NEW.request_key IS NOT OLD.request_key
      BEGIN
        SELECT RAISE(ABORT, 'run_request_key_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS runs_request_key_immutable"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS runs_request_key_immutable")

    drop_if_exists index(:run_agents, [:status, :updated_at],
                     name: :run_agents_status_updated_at_index
                   )

    drop_if_exists index(:runs, [:status, :updated_at], name: :runs_status_updated_at_index)

    drop_if_exists unique_index(:runs, [:session_id, :request_key],
                     name: :runs_session_id_request_key_index
                   )

    alter table(:runs) do
      remove :request_key
    end
  end
end
