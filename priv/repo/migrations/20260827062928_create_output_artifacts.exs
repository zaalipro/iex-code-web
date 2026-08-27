defmodule IexCode.Repo.Migrations.CreateOutputArtifacts do
  use Ecto.Migration

  def change do
    create table(:output_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Keep the metadata row until retention cleanup has removed its file.
      # Cascading this row would leave an untracked file in the spool forever.
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :operation_id, references(:operations, type: :binary_id, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :name, :string, null: false
      add :relative_path, :text, null: false
      add :status, :string, null: false, default: "writing"
      add :byte_size, :integer, null: false, default: 0
      add :reserved_bytes, :integer, null: false, default: 0
      add :limit_bytes, :integer, null: false
      add :checksum, :string
      add :preview_head, :text, null: false, default: ""
      add :preview_tail, :text, null: false, default: ""
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:output_artifacts, [:run_id, :inserted_at])
    create index(:output_artifacts, [:session_id, :inserted_at])
    create index(:output_artifacts, [:operation_id])
    create index(:output_artifacts, [:status, :expires_at])

    # SQLite cannot add constraints with `ALTER TABLE ... ADD CONSTRAINT`.
    # These invariants are enforced by OutputArtifact changesets; keeping the
    # migration portable is more important than duplicating them in DDL.
  end
end
