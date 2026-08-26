defmodule IexCode.Runs.RunAgentControl do
  @moduledoc "A durable ordered control targeted at one leased run-agent generation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(pause resume cancel steer restart)
  @statuses ~w(pending claimed applied rejected superseded)
  @terminal_statuses ~w(applied rejected superseded)
  @max_map_bytes 256_000

  schema "run_agent_controls" do
    field :target_generation, :integer
    field :sequence, :integer
    field :idempotency_key, :string
    field :kind, :string
    field :status, :string, default: "pending"
    field :payload, :map, default: %{}
    field :result, :map
    field :requested_by, :string, default: "local-user"
    field :claim_owner, :string, redact: true
    field :claim_generation, :integer
    field :claimed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :run, IexCode.Runs.Run
    belongs_to :run_agent, IexCode.Runs.RunAgent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(control, attrs) do
    control
    |> cast(attrs, [
      :target_generation,
      :sequence,
      :idempotency_key,
      :kind,
      :status,
      :payload,
      :result,
      :requested_by,
      :claim_owner,
      :claim_generation,
      :claimed_at,
      :resolved_at
    ])
    |> validate_required([
      :run_id,
      :run_agent_id,
      :target_generation,
      :sequence,
      :idempotency_key,
      :kind,
      :status,
      :payload,
      :requested_by
    ])
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> validate_format(:idempotency_key, ~r/^[^\s]+$/)
    |> validate_length(:requested_by, min: 1, max: 160)
    |> validate_length(:claim_owner, is: 64)
    |> validate_format(:claim_owner, ~r/^[0-9a-f]{64}$/)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:target_generation, greater_than_or_equal_to: 0)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:claim_generation, greater_than_or_equal_to: 0)
    |> validate_map_size(:payload)
    |> validate_map_size(:result)
    |> validate_lifecycle()
    |> unique_constraint([:run_agent_id, :idempotency_key])
    |> unique_constraint([:run_agent_id, :sequence])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_agent_id)
    |> check_constraint(:kind, name: :run_agent_controls_kind_check)
    |> check_constraint(:status, name: :run_agent_controls_status_check)
    |> check_constraint(:status, name: :run_agent_controls_lifecycle_check)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses

  defp validate_lifecycle(changeset) do
    status = get_field(changeset, :status)
    owner = get_field(changeset, :claim_owner)
    generation = get_field(changeset, :claim_generation)
    claimed_at = get_field(changeset, :claimed_at)
    resolved_at = get_field(changeset, :resolved_at)
    result = get_field(changeset, :result)

    valid? =
      case status do
        "pending" ->
          is_nil(owner) and is_nil(generation) and is_nil(claimed_at) and is_nil(resolved_at) and
            is_nil(result)

        "claimed" ->
          ((present?(owner) and is_integer(generation) and claimed_at) && is_nil(resolved_at)) and
            is_nil(result)

        terminal when terminal in ~w(applied rejected) ->
          (present?(owner) and is_integer(generation) and claimed_at) && resolved_at &&
            is_map(result)

        "superseded" ->
          resolved_at && is_map(result)

        _ ->
          true
      end

    if valid?,
      do: changeset,
      else: add_error(changeset, :status, "has inconsistent lifecycle fields")
  end

  defp validate_map_size(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_map(value) -> [{field, "must be a map"}]
        encoded_size(value) > @max_map_bytes -> [{field, "is too large"}]
        true -> []
      end
    end)
  end

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> @max_map_bytes + 1
    end
  end

  defp present?(value), do: value not in [nil, ""]
end
