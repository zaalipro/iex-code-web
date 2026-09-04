defmodule IexCode.SemanticIndex.CodeEmbedding do
  @moduledoc """
  Ecto schema for storing code chunks and their IEEE-754 packed float32 vector embeddings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "code_embeddings" do
    belongs_to :project, IexCode.Projects.Project
    field :file_path, :string
    field :file_hash, :string
    field :chunk_index, :integer
    field :chunk_type, :string
    field :symbol_name, :string
    field :symbol_type, :string
    field :start_line, :integer
    field :end_line, :integer
    field :content, :string
    field :embedding, :binary
    field :dimensions, :integer
    field :model, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(code_embedding, attrs) do
    code_embedding
    |> cast(attrs, [
      :project_id,
      :file_path,
      :file_hash,
      :chunk_index,
      :chunk_type,
      :symbol_name,
      :symbol_type,
      :start_line,
      :end_line,
      :content,
      :embedding,
      :dimensions,
      :model
    ])
    |> validate_required([
      :project_id,
      :file_path,
      :file_hash,
      :chunk_index,
      :chunk_type,
      :start_line,
      :end_line,
      :content,
      :embedding,
      :dimensions,
      :model
    ])
  end
end
