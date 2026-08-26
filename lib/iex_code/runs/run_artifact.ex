defmodule IexCode.Runs.RunArtifact do
  @moduledoc "Metadata for an immutable artifact produced by a run."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_artifacts" do
    field :kind, :string
    field :name, :string
    field :uri, :string
    field :media_type, :string
    field :byte_size, :integer
    field :checksum, :string
    field :metadata, :map, default: %{}

    belongs_to :run, IexCode.Runs.Run
    belongs_to :run_step, IexCode.Runs.RunStep

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :run_step_id,
      :kind,
      :name,
      :uri,
      :media_type,
      :byte_size,
      :checksum,
      :metadata
    ])
    |> validate_required([:run_id, :kind, :name, :uri])
    |> validate_length(:kind, min: 1, max: 120)
    |> validate_length(:name, min: 1, max: 500)
    |> validate_length(:uri, min: 1, max: 8_000)
    |> validate_length(:media_type, max: 200)
    |> validate_length(:checksum, max: 200)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_step_id)
  end
end
