defmodule IexCode.Runs.RunCommand do
  @moduledoc "A durable idempotent tool command belonging to a run."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued claimed running waiting_approval completed failed cancelled interrupted uncertain)

  schema "run_commands" do
    field :idempotency_key, :string
    field :tool_name, :string
    field :status, :string, default: "queued"
    field :arguments, :map, default: %{}
    field :output, :string
    field :error_message, :string
    field :error_details, :map
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 1
    field :not_before, :utc_datetime
    field :claimed_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run
    belongs_to :run_step, IexCode.Runs.RunStep
    has_many :approvals, IexCode.Runs.RunApproval

    timestamps(type: :utc_datetime)
  end

  def changeset(command, attrs) do
    command
    |> cast(attrs, [
      :run_step_id,
      :idempotency_key,
      :tool_name,
      :status,
      :arguments,
      :output,
      :error_message,
      :error_details,
      :attempt,
      :max_attempts,
      :not_before,
      :claimed_at,
      :heartbeat_at,
      :completed_at
    ])
    |> validate_required([:run_id, :idempotency_key, :tool_name, :status])
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> validate_format(:idempotency_key, ~r/^[^\s]+$/)
    |> validate_length(:tool_name, min: 1, max: 120)
    |> validate_length(:output, max: 1_000_000)
    |> validate_length(:error_message, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_uncertain_is_terminal()
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_attempts()
    |> unique_constraint([:run_id, :idempotency_key])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_step_id)
  end

  def statuses, do: @statuses

  defp validate_uncertain_is_terminal(changeset) do
    if changeset.data.status == "uncertain" and get_field(changeset, :status) != "uncertain" do
      add_error(changeset, :status, "cannot transition from uncertain")
    else
      changeset
    end
  end

  defp validate_attempts(changeset) do
    attempt = get_field(changeset, :attempt)
    max_attempts = get_field(changeset, :max_attempts)

    if is_integer(attempt) and is_integer(max_attempts) and attempt > max_attempts do
      add_error(changeset, :attempt, "cannot exceed max_attempts")
    else
      changeset
    end
  end
end
