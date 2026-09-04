defmodule IexCode.Repo.Migrations.CreateCodeEmbeddings do
  use Ecto.Migration

  def change do
    create table(:code_embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :file_path, :string, null: false
      add :file_hash, :string, null: false
      add :chunk_index, :integer, null: false
      add :chunk_type, :string, null: false
      add :symbol_name, :string
      add :symbol_type, :string
      add :start_line, :integer, null: false
      add :end_line, :integer, null: false
      add :content, :text, null: false
      add :embedding, :binary, null: false
      add :dimensions, :integer, null: false
      add :model, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:code_embeddings, [:project_id, :file_path])
    create index(:code_embeddings, [:project_id, :file_hash])
    create index(:code_embeddings, [:project_id, :symbol_name])
  end
end
