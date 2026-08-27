defmodule IexCode.Outputs.OutputArtifact do
  @moduledoc "Metadata for a bounded, file-backed command or tool output."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @statuses ~w(writing ready limit_exceeded failed deleting)
  @max_metadata_bytes 64_000

  schema "output_artifacts" do
    field :kind, :string
    field :name, :string
    field :relative_path, :string
    field :status, :string, default: "writing"
    field :byte_size, :integer, default: 0
    field :reserved_bytes, :integer, default: 0
    field :limit_bytes, :integer
    field :checksum, :string
    field :preview_head, :string, default: ""
    field :preview_tail, :string, default: ""
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run
    belongs_to :session, IexCode.Sessions.Session
    belongs_to :operation, IexCode.Sessions.Operation

    timestamps(type: :utc_datetime)
  end

  def create_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :id,
      :run_id,
      :session_id,
      :operation_id,
      :kind,
      :name,
      :relative_path,
      :status,
      :byte_size,
      :reserved_bytes,
      :limit_bytes,
      :checksum,
      :preview_head,
      :preview_tail,
      :metadata,
      :expires_at
    ])
    |> validate_common()
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:operation_id)
  end

  def finish_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :status,
      :byte_size,
      :reserved_bytes,
      :checksum,
      :preview_head,
      :preview_tail,
      :metadata,
      :expires_at
    ])
    |> validate_common()
  end

  def statuses, do: @statuses

  defp validate_common(changeset) do
    changeset
    |> validate_required([:id, :kind, :name, :relative_path, :status, :limit_bytes])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:kind, min: 1, max: 120)
    |> validate_length(:name, min: 1, max: 500)
    |> validate_length(:relative_path, min: 1, max: 1_024)
    |> validate_format(
      :relative_path,
      ~r/\A\d{4}\/\d{2}\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.log\z/
    )
    |> validate_length(:checksum, is: 64)
    |> validate_format(:checksum, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:limit_bytes, greater_than: 0)
    |> validate_size_within_limit()
    |> validate_metadata()
  end

  defp validate_size_within_limit(changeset) do
    size = get_field(changeset, :byte_size)
    limit = get_field(changeset, :limit_bytes)

    if is_integer(size) and is_integer(limit) and size > limit,
      do: add_error(changeset, :byte_size, "must not exceed the output limit"),
      else: changeset
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      case IexCode.Runs.DagPayload.validate(metadata, max_bytes: @max_metadata_bytes) do
        {:ok, value} when is_map(value) -> []
        _invalid -> [metadata: "must be a bounded JSON object without secrets"]
      end
    end)
  end
end
