defmodule IexCode.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :root_path, :string
    field :description, :string
    field :last_opened_at, :utc_datetime

    has_many :sessions, IexCode.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :root_path, :description, :last_opened_at])
    |> validate_required([:name, :root_path])
    |> validate_change(:root_path, fn :root_path, path ->
      cond do
        not is_binary(path) -> [root_path: "is invalid"]
        not String.valid?(path) -> [root_path: "must be valid UTF-8"]
        String.contains?(path, <<0>>) -> [root_path: "must not contain a NUL byte"]
        byte_size(path) > 4_096 -> [root_path: "is too long"]
        true -> []
      end
    end)
    |> unique_constraint(:root_path)
  end
end
