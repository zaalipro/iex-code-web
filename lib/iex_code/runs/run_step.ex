defmodule IexCode.Runs.RunStep do
  @moduledoc "A durable node in a run execution graph."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending ready running paused waiting_approval blocked completed failed cancelled skipped interrupted)
  @effect_classes ~w(legacy pure read workspace_write git native provider)
  @replay_policies ~w(safe checkpointed never)

  @manifest_fields [
    :parent_step_id,
    :key,
    :kind,
    :title,
    :position,
    :max_attempts,
    :depends_on,
    :params,
    :handler_version,
    :effect_class,
    :replay_policy,
    :resource_spec,
    :timeout_ms
  ]

  @lifecycle_fields [
    :status,
    :progress,
    :attempt,
    :result,
    :error_message,
    :error_details,
    :started_at,
    :heartbeat_at,
    :completed_at
  ]

  schema "run_steps" do
    field :key, :string
    field :kind, :string
    field :title, :string
    field :status, :string, default: "pending"
    field :position, :integer, default: 0
    field :progress, :integer, default: 0
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 1
    field :depends_on, {:array, :string}, default: []
    field :params, :map, default: %{}
    field :handler_version, :integer, default: 1
    field :effect_class, :string, default: "legacy"
    field :replay_policy, :string, default: "never"
    field :resource_spec, :map, default: %{}
    field :timeout_ms, :integer
    field :result, :map
    field :error_message, :string
    field :error_details, :map
    field :started_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :run, IexCode.Runs.Run
    belongs_to :parent_step, __MODULE__
    has_many :child_steps, __MODULE__, foreign_key: :parent_step_id
    has_many :commands, IexCode.Runs.RunCommand
    has_many :artifacts, IexCode.Runs.RunArtifact
    has_many :attempts, IexCode.Runs.RunStepAttempt

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{id: nil} = step, attrs) do
    step
    |> cast(attrs, @manifest_fields ++ @lifecycle_fields)
    |> validate_changeset()
  end

  def create_changeset(%__MODULE__{} = step, attrs), do: changeset(step, attrs)

  def changeset(%__MODULE__{id: nil} = step, attrs), do: create_changeset(step, attrs)

  def changeset(step, attrs) do
    step
    |> cast(attrs, @lifecycle_fields)
    |> reject_manifest_changes(step, attrs)
    |> validate_changeset()
  end

  defp validate_changeset(changeset) do
    changeset
    |> validate_required([:run_id, :key, :kind, :title, :status])
    |> validate_length(:key, min: 1, max: 160)
    |> validate_format(:key, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/)
    |> validate_length(:kind, min: 1, max: 80)
    |> validate_length(:title, min: 1, max: 500)
    |> validate_length(:error_message, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:handler_version, greater_than_or_equal_to: 1)
    |> validate_inclusion(:effect_class, @effect_classes)
    |> validate_inclusion(:replay_policy, @replay_policies)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 86_400_000
    )
    |> validate_attempts()
    |> unique_constraint([:run_id, :key])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:parent_step_id)
    |> check_constraint(:handler_version, name: :run_steps_dag_handler_shape)
  end

  def statuses, do: @statuses

  defp reject_manifest_changes(changeset, %__MODULE__{id: id} = step, attrs)
       when not is_nil(id) and is_map(attrs) do
    Enum.reduce(@manifest_fields, changeset, fn field, current ->
      requested = Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))

      if is_nil(requested) or requested == Map.get(step, field) do
        current
      else
        add_error(current, field, "cannot be changed after creation")
      end
    end)
  end

  defp reject_manifest_changes(changeset, _step, _attrs), do: changeset

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
