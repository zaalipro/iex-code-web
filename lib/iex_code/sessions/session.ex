defmodule IexCode.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Execution.Limits

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :title, :string
    field :swarm_mode, :boolean, default: false
    field :model_provider, :string, default: "openai"
    field :model_name, :string, default: "deepseek-v4-pro"
    field :temperature, :float, default: 0.2
    field :status, :string, default: "idle"

    belongs_to :project, IexCode.Projects.Project
    has_many :messages, IexCode.Sessions.Message
    has_many :operations, IexCode.Sessions.Operation

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(idle running paused stopped failed completed)
  @model_providers ~w(openai anthropic)
  @mutable_fields [:title, :swarm_mode, :model_provider, :model_name, :temperature, :status]

  def changeset(%__MODULE__{id: nil} = session, attrs) do
    session
    |> cast(attrs, [:project_id | @mutable_fields])
    |> validate_changeset()
  end

  def changeset(%__MODULE__{} = session, attrs) do
    session
    |> cast(attrs, @mutable_fields)
    |> reject_project_change(session, attrs)
    |> validate_changeset()
  end

  defp validate_changeset(changeset) do
    changeset
    |> validate_required([
      :project_id,
      :title,
      :swarm_mode,
      :model_provider,
      :model_name,
      :temperature,
      :status
    ])
    |> validate_length(:title, min: 1, max: 500)
    |> validate_length(:model_name,
      min: 1,
      max: Limits.max_model_name_bytes(),
      count: :bytes
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:model_provider, @model_providers)
    |> validate_number(:temperature,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 2.0
    )
    |> foreign_key_constraint(:project_id)
  end

  def statuses, do: @statuses

  defp reject_project_change(changeset, session, attrs) when is_map(attrs) do
    requested = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")

    if is_nil(requested) or requested == session.project_id do
      changeset
    else
      add_error(changeset, :project_id, "cannot be changed after creation")
    end
  end

  defp reject_project_change(changeset, _session, _attrs), do: changeset
end
