defmodule IexCode.Kanban.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(triage todo scheduled ready running blocked review done)
  @priorities ~w(low medium high critical)

  schema "kanban_tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "triage"
    field :priority, :string, default: "medium"
    field :assignee, :string, default: "default"
    field :worker_pid, :string
    field :estimate, :string
    field :latest_summary, :string
    field :tags, {:array, :string}, default: []
    field :subtasks, {:array, :map}, default: []
    field :steps_completed, :integer, default: 0
    field :steps_total, :integer, default: 0
    field :claimed_at, :utc_datetime
    field :scheduled_at, :utc_datetime
    field :cron_expression, :string
    field :metadata, :map, default: %{}

    belongs_to :project, IexCode.Projects.Project
    belongs_to :session, IexCode.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :project_id,
      :session_id,
      :title,
      :description,
      :status,
      :priority,
      :assignee,
      :worker_pid,
      :estimate,
      :latest_summary,
      :tags,
      :subtasks,
      :steps_completed,
      :steps_total,
      :scheduled_at,
      :cron_expression,
      :metadata
    ])
    |> compute_subtask_steps()
    |> validate_required([:title, :project_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_number(:steps_completed, greater_than_or_equal_to: 0)
    |> validate_number(:steps_total, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
  end

  defp compute_subtask_steps(changeset) do
    case get_change(changeset, :subtasks) do
      nil ->
        changeset

      subtasks when is_list(subtasks) ->
        total = length(subtasks)

        completed =
          Enum.count(subtasks, fn
            %{"completed" => true} -> true
            %{completed: true} -> true
            _ -> false
          end)

        changeset
        |> put_change(:steps_total, total)
        |> put_change(:steps_completed, completed)

      _ ->
        changeset
    end
  end

  def statuses, do: @statuses
  def priorities, do: @priorities
end
