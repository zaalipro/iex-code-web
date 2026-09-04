defmodule IexCode.Workflows.WorkflowRun do
  @moduledoc """
  Materialized execution instance of a Workflow.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Projects.Project
  alias IexCode.Runs.Run
  alias IexCode.Sessions.Session
  alias IexCode.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running paused completed failed cancelled)

  schema "workflow_runs" do
    field :status, :string, default: "pending"
    field :progress, :integer, default: 0
    field :inputs, :map, default: %{}
    field :resolved_steps, {:array, :map}, default: []
    field :step_states, :map, default: %{}
    field :current_step_key, :string
    field :error_message, :string
    field :error_details, :map
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :duration_ms, :integer, default: 0
    field :started_at, :utc_datetime
    field :paused_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :workflow, Workflow
    belongs_to :project, Project
    belongs_to :session, Session
    belongs_to :run, Run

    timestamps(type: :utc_datetime)
  end

  @doc "Returns allowed workflow run statuses."
  def statuses, do: @statuses

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workflow_id,
      :project_id,
      :session_id,
      :run_id,
      :status,
      :progress,
      :inputs,
      :resolved_steps,
      :step_states,
      :current_step_key,
      :error_message,
      :error_details,
      :input_tokens,
      :output_tokens,
      :cost_cents,
      :duration_ms,
      :started_at,
      :paused_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([:workflow_id, :project_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:run_id)
  end
end
