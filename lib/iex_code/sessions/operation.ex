defmodule IexCode.Sessions.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "operations" do
    field :parent_op_id, :binary_id
    field :agent_name, :string

    # "read_file", "write_file", "patch_file", "grep_search", "list_dir", "run_command", "web_search", "subagent_plan", "llm_stream"
    field :op_type, :string
    field :title, :string
    # "pending", "running", "completed", "failed"
    field :status, :string, default: "pending"
    field :progress, :integer, default: 0
    field :pid_str, :string
    field :params, :map
    field :result, :string
    field :error_message, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :duration_ms, :integer

    belongs_to :session, IexCode.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(pending running completed failed)

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :session_id,
      :parent_op_id,
      :agent_name,
      :op_type,
      :title,
      :status,
      :progress,
      :pid_str,
      :params,
      :result,
      :error_message,
      :started_at,
      :completed_at,
      :duration_ms
    ])
    |> validate_required([:session_id, :agent_name, :op_type, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:session_id)
  end

  def statuses, do: @statuses
end
