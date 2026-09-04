defmodule IexCode.Tools.MultiPatch.MutationSnapshot do
  @moduledoc "Durable rollback metadata for one native-workspace mutation transaction."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:transaction_id, :string, autogenerate: false}

  schema "mutation_snapshots" do
    field :session_id, :string
    field :run_id, :binary_id
    field :project_root, :string
    field :patches, {:array, :map}, default: []
    field :created_at, :utc_datetime
    field :seq, :integer, default: 1
    field :status, :string, default: "active"
    field :label, :string
    field :diff_summary, :string
    field :id, :string, virtual: true
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :transaction_id,
      :session_id,
      :run_id,
      :project_root,
      :patches,
      :created_at,
      :seq,
      :status,
      :label,
      :diff_summary
    ])
    |> validate_required([:transaction_id, :project_root, :patches, :created_at])
    |> validate_length(:transaction_id, min: 1, max: 200)
    |> validate_length(:project_root, min: 1, max: 8_000)
    |> set_virtual_id()
  end

  defp set_virtual_id(changeset) do
    case get_field(changeset, :transaction_id) do
      nil -> changeset
      tid -> put_change(changeset, :id, tid)
    end
  end
end
