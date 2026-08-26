defmodule IexCode.Research.ResearchResult do
  @moduledoc "A durable, integer-addressable deep-research result."

  use Ecto.Schema
  import Ecto.Changeset

  @levels ~w(low medium high ultra)
  @statuses ~w(queued running ready failed cancelled)
  @max_metadata_bytes 64_000

  schema "research_results" do
    field :objective, :string
    field :level, :string
    field :status, :string, default: "queued"
    field :result_path, :string
    field :html_path, :string
    field :markdown_sha256, :string
    field :html_sha256, :string
    field :source_count, :integer, default: 0
    field :metadata, :map, default: %{}
    field :completed_at, :utc_datetime_usec

    belongs_to :run, IexCode.Runs.Run, type: :binary_id
    belongs_to :project, IexCode.Projects.Project, type: :binary_id
    belongs_to :session, IexCode.Sessions.Session, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(result, attrs) do
    result
    |> cast(attrs, [
      :run_id,
      :project_id,
      :session_id,
      :objective,
      :level,
      :status,
      :metadata
    ])
    |> validate_common()
    |> unique_constraint(:run_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
    |> database_constraints()
  end

  def transition_changeset(result, attrs) do
    result
    |> cast(attrs, [
      :status,
      :result_path,
      :html_path,
      :markdown_sha256,
      :html_sha256,
      :source_count,
      :metadata,
      :completed_at
    ])
    |> validate_common()
    |> validate_lifecycle()
    |> database_constraints()
  end

  def levels, do: @levels
  def statuses, do: @statuses

  defp validate_common(changeset) do
    changeset
    |> validate_required([
      :run_id,
      :project_id,
      :session_id,
      :objective,
      :level,
      :status
    ])
    |> validate_length(:objective, min: 1, max: 100_000)
    |> validate_inclusion(:level, @levels)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:source_count, greater_than_or_equal_to: 0)
    |> validate_length(:result_path, max: 1_024)
    |> validate_length(:html_path, max: 1_024)
    |> validate_digest(:markdown_sha256)
    |> validate_digest(:html_sha256)
    |> validate_metadata()
  end

  defp validate_lifecycle(changeset) do
    status = get_field(changeset, :status)
    paths = [get_field(changeset, :result_path), get_field(changeset, :html_path)]
    digests = [get_field(changeset, :markdown_sha256), get_field(changeset, :html_sha256)]
    completed_at = get_field(changeset, :completed_at)

    cond do
      status == "ready" and
          (Enum.any?(paths, &is_nil/1) or Enum.any?(digests, &is_nil/1) or
             is_nil(completed_at)) ->
        add_error(changeset, :status, "ready results require both immutable files and digests")

      status != "ready" and Enum.any?(paths ++ digests, &(not is_nil(&1))) ->
        add_error(changeset, :status, "only ready results may expose files")

      status in ["failed", "cancelled"] and is_nil(completed_at) ->
        add_error(changeset, :completed_at, "is required for terminal results")

      status in ["queued", "running"] and not is_nil(completed_at) ->
        add_error(changeset, :completed_at, "must be empty while research is active")

      true ->
        changeset
    end
  end

  defp validate_digest(changeset, field) do
    changeset
    |> validate_length(field, is: 64)
    |> validate_format(field, ~r/^[0-9a-f]{64}$/)
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      case IexCode.Runs.DagPayload.validate(value, max_bytes: @max_metadata_bytes) do
        {:ok, validated} when is_map(validated) -> []
        {:ok, _validated} -> [metadata: "must be a JSON object"]
        {:error, _reason} -> [metadata: "violates the bounded secret-safe payload policy"]
      end
    end)
  end

  defp database_constraints(changeset) do
    changeset
    |> check_constraint(:level, name: :research_results_level_check)
    |> check_constraint(:status, name: :research_results_status_check)
    |> check_constraint(:source_count, name: :research_results_source_count_check)
  end
end
