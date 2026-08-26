defmodule IexCode.Runs.RunStepAttempt do
  @moduledoc "Append-only durable execution attempt for one logical DAG step."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running paused completed failed cancelled interrupted)
  @active_statuses ~w(running paused)
  @terminal_statuses ~w(completed failed cancelled interrupted)
  @effect_classes ~w(pure read workspace_write git native provider)
  @replay_policies ~w(safe checkpointed never)
  @max_json_bytes 64_000
  @max_result_bytes 256_000

  schema "run_step_attempts" do
    field :run_attempt, :integer
    field :run_lease_generation, :integer
    field :attempt, :integer
    field :execution_key, :string
    field :manifest_hash, :string
    field :handler_kind, :string
    field :handler_version, :integer
    field :effect_class, :string
    field :replay_policy, :string
    field :status, :string
    field :progress, :integer, default: 0
    field :run_owner, :string, redact: true
    field :claim_owner, :string, redact: true
    field :lease_owner, :string, redact: true
    field :lease_generation, :integer
    field :lease_expires_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :retry_not_before, :utc_datetime_usec
    field :checkpoint, :map
    field :checkpoint_version, :integer
    field :checkpointed_at, :utc_datetime_usec
    field :result, :map
    field :result_digest, :string
    field :error_message, :string
    field :error_details, :map
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :run, IexCode.Runs.Run
    belongs_to :run_step, IexCode.Runs.RunStep

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :run_attempt,
      :run_lease_generation,
      :attempt,
      :execution_key,
      :manifest_hash,
      :handler_kind,
      :handler_version,
      :effect_class,
      :replay_policy,
      :status,
      :progress,
      :run_owner,
      :claim_owner,
      :lease_owner,
      :lease_generation,
      :lease_expires_at,
      :heartbeat_at,
      :retry_not_before,
      :checkpoint,
      :checkpoint_version,
      :checkpointed_at,
      :result,
      :result_digest,
      :error_message,
      :error_details,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :run_id,
      :run_step_id,
      :run_attempt,
      :run_lease_generation,
      :attempt,
      :execution_key,
      :manifest_hash,
      :handler_kind,
      :handler_version,
      :effect_class,
      :replay_policy,
      :status,
      :run_owner,
      :claim_owner,
      :lease_generation,
      :started_at
    ])
    |> validate_length(:execution_key, min: 1, max: 500)
    |> validate_length(:manifest_hash, is: 64)
    |> validate_format(:manifest_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:handler_kind, min: 1, max: 80)
    |> validate_inclusion(:effect_class, @effect_classes)
    |> validate_inclusion(:replay_policy, @replay_policies)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:run_attempt, greater_than_or_equal_to: 1)
    |> validate_number(:run_lease_generation, greater_than_or_equal_to: 1)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
    |> validate_number(:handler_version, greater_than_or_equal_to: 1)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:lease_generation, greater_than_or_equal_to: 1)
    |> validate_length(:run_owner, is: 64)
    |> validate_format(:run_owner, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:claim_owner, is: 64)
    |> validate_format(:claim_owner, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:lease_owner, is: 64)
    |> validate_format(:lease_owner, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:result_digest, is: 64)
    |> validate_format(:result_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:error_message, max: 20_000)
    |> validate_json_size(:checkpoint, @max_json_bytes)
    |> validate_json_size(:result, @max_result_bytes)
    |> validate_json_size(:error_details, @max_json_bytes)
    |> validate_lifecycle()
    |> unique_constraint([:run_step_id, :run_attempt, :attempt],
      name: :run_step_attempts_identity_index
    )
    |> unique_constraint([:run_id, :execution_key])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_step_id)
    |> check_constraint(:status, name: :run_step_attempts_status_check)
    |> check_constraint(:status, name: :run_step_attempts_lifecycle_check)
  end

  def statuses, do: @statuses
  def active_statuses, do: @active_statuses
  def terminal_statuses, do: @terminal_statuses

  defp validate_json_size(changeset, field, maximum) do
    validate_change(changeset, field, fn ^field, value ->
      case IexCode.Runs.DagPayload.validate(value, max_bytes: maximum) do
        {:ok, _validated} -> []
        {:error, reason} -> [{field, "violates DAG payload policy: #{inspect(reason)}"}]
      end
    end)
  end

  defp validate_lifecycle(changeset) do
    status = get_field(changeset, :status)
    owner = get_field(changeset, :lease_owner)
    expiry = get_field(changeset, :lease_expires_at)
    heartbeat = get_field(changeset, :heartbeat_at)
    completed = get_field(changeset, :completed_at)
    result = get_field(changeset, :result)
    digest = get_field(changeset, :result_digest)

    cond do
      status in @active_statuses and
          (is_nil(owner) or is_nil(expiry) or is_nil(heartbeat) or not is_nil(completed)) ->
        add_error(changeset, :status, "active attempts require a complete lease")

      status in @terminal_statuses and
          (not is_nil(owner) or not is_nil(expiry) or is_nil(completed)) ->
        add_error(changeset, :status, "terminal attempts require completion and a cleared lease")

      status == "completed" and (is_nil(result) or is_nil(digest)) ->
        add_error(changeset, :result, "completed attempts require a digested result")

      true ->
        changeset
    end
  end
end
