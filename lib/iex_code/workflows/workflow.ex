defmodule IexCode.Workflows.Workflow do
  @moduledoc """
  Durable template blueprint for multi-step DAG workflows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Projects.Project
  alias IexCode.Workflows.{WorkflowDag, WorkflowRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflows" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :tags, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :is_active, :boolean, default: true
    field :variables, {:array, :map}, default: []
    field :steps, {:array, :map}
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    has_many :runs, WorkflowRun, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :project_id,
      :name,
      :slug,
      :description,
      :tags,
      :version,
      :is_active,
      :variables,
      :steps,
      :metadata
    ])
    |> maybe_generate_slug()
    |> validate_required([:project_id, :name, :slug, :steps])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:slug, min: 1, max: 100)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_steps_dag()
    |> unique_constraint(:slug, name: :workflows_project_id_slug_index)
    |> foreign_key_constraint(:project_id)
  end

  defp maybe_generate_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) and name != "" ->
        put_change(changeset, :slug, slugify(name))

      {"", name} when is_binary(name) and name != "" ->
        put_change(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/i, "-")
    |> String.trim("-")
  end

  defp validate_steps_dag(changeset) do
    case get_field(changeset, :steps) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :steps, "cannot be empty")

      steps when is_list(steps) ->
        variables = get_field(changeset, :variables, [])

        case WorkflowDag.validate(steps, variables) do
          :ok ->
            changeset

          {:error, reason} ->
            add_error(changeset, :steps, "invalid DAG configuration: #{inspect(reason)}")
        end

      _ ->
        add_error(changeset, :steps, "must be a list of step maps")
    end
  end
end
