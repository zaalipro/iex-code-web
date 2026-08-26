defmodule IexCode.Runs.RunEvent do
  @moduledoc "An immutable, monotonically ordered run event."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_events" do
    field :sequence, :integer
    field :type, :string
    field :source, :string, default: "system"
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:sequence, :type, :source, :payload, :occurred_at])
    |> validate_required([:run_id, :sequence, :type, :source, :occurred_at])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:type, min: 1, max: 120)
    |> validate_format(:type, ~r/^[a-z][a-z0-9_.:-]*$/)
    |> validate_length(:source, min: 1, max: 160)
    |> unique_constraint([:run_id, :sequence])
    |> foreign_key_constraint(:run_id)
  end
end
