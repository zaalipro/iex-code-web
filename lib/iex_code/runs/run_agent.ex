defmodule IexCode.Runs.RunAgent do
  @moduledoc "A durable logical member of a run-scoped agent fleet."

  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Execution.Limits

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending starting idle running paused stopping completed failed cancelled interrupted)
  @desired_states ~w(active paused stopped)
  @leased_statuses ~w(starting idle running paused stopping)
  @terminal_statuses ~w(completed failed cancelled)
  @max_map_bytes 256_000

  schema "run_agents" do
    field :run_attempt, :integer
    field :parent_agent_id, :binary_id
    field :key, :string
    field :role, :string
    field :adapter, :string
    field :display_name, :string
    field :position, :integer, default: 0
    field :required, :boolean, default: true
    field :status, :string, default: "pending"
    field :desired_state, :string, default: "active"
    field :progress, :integer, default: 0
    field :current_task, :string
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :lease_owner, :string, redact: true
    field :lease_generation, :integer, default: 0
    field :lease_expires_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :control_sequence, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :latency_ms, :integer, default: 0
    field :request_count, :integer, default: 0
    field :last_latency_ms, :integer, default: 0
    field :average_latency_ms, :integer, default: 0
    field :restart_count, :integer, default: 0
    field :model_provider, :string
    field :model_name, :string
    field :capabilities, {:array, :string}, default: []
    field :config, :map, default: %{}
    field :metadata, :map, default: %{}
    field :result, :map
    field :error_message, :string
    field :error_details, :map
    field :started_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :run, IexCode.Runs.Run
    belongs_to :parent_agent, __MODULE__, define_field: false
    has_many :child_agents, __MODULE__, foreign_key: :parent_agent_id
    has_many :controls, IexCode.Runs.RunAgentControl

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :run_attempt,
      :parent_agent_id,
      :key,
      :role,
      :adapter,
      :display_name,
      :position,
      :required,
      :status,
      :desired_state,
      :progress,
      :current_task,
      :attempt,
      :max_attempts,
      :lease_owner,
      :lease_generation,
      :lease_expires_at,
      :heartbeat_at,
      :control_sequence,
      :input_tokens,
      :output_tokens,
      :cost_cents,
      :latency_ms,
      :request_count,
      :last_latency_ms,
      :average_latency_ms,
      :restart_count,
      :model_provider,
      :model_name,
      :capabilities,
      :config,
      :metadata,
      :result,
      :error_message,
      :error_details,
      :started_at,
      :last_active_at,
      :completed_at
    ])
    |> validate_required([
      :run_id,
      :run_attempt,
      :key,
      :role,
      :adapter,
      :display_name,
      :status,
      :desired_state
    ])
    |> validate_length(:key, min: 1, max: 160)
    |> validate_format(:key, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/)
    |> validate_length(:role, min: 1, max: 120)
    |> validate_format(:role, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/)
    |> validate_length(:adapter, min: 1, max: 160)
    |> validate_format(:adapter, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/)
    |> validate_length(:display_name, min: 1, max: 240)
    |> validate_length(:current_task, max: 20_000)
    |> validate_length(:lease_owner, is: 64)
    |> validate_format(:lease_owner, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:model_provider, max: 160)
    |> validate_length(:model_name, max: Limits.max_model_name_bytes(), count: :bytes)
    |> validate_length(:error_message, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:desired_state, @desired_states)
    |> validate_number(:run_attempt, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:lease_generation, greater_than_or_equal_to: 0)
    |> validate_number(:control_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:request_count, greater_than_or_equal_to: 0)
    |> validate_number(:last_latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:average_latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:restart_count, greater_than_or_equal_to: 0)
    |> validate_capabilities()
    |> validate_attempts()
    |> validate_lifecycle()
    |> validate_map_size(:config)
    |> validate_map_size(:metadata)
    |> validate_map_size(:result)
    |> validate_map_size(:error_details)
    |> unique_constraint([:run_id, :run_attempt, :key], name: :run_agents_run_attempt_key_index)
    |> unique_constraint([:run_id, :key], name: :run_agents_live_key_index)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:parent_agent_id)
    |> check_constraint(:status, name: :run_agents_status_check)
    |> check_constraint(:desired_state, name: :run_agents_desired_state_check)
    |> check_constraint(:status, name: :run_agents_lifecycle_check)
  end

  def statuses, do: @statuses
  def desired_states, do: @desired_states
  def leased_statuses, do: @leased_statuses
  def terminal_statuses, do: @terminal_statuses

  defp validate_attempts(changeset) do
    if comparable_attempts?(changeset) do
      add_error(changeset, :attempt, "cannot exceed max_attempts")
    else
      changeset
    end
  end

  defp comparable_attempts?(changeset) do
    attempt = get_field(changeset, :attempt)
    maximum = get_field(changeset, :max_attempts)
    is_integer(attempt) and is_integer(maximum) and attempt > maximum
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, values ->
      cond do
        not is_list(values) ->
          [capabilities: "must be a list"]

        length(values) > 128 ->
          [capabilities: "may contain at most 128 entries"]

        Enum.any?(values, &(not is_binary(&1) or byte_size(&1) not in 1..160)) ->
          [capabilities: "must contain non-empty strings of at most 160 bytes"]

        true ->
          []
      end
    end)
  end

  defp validate_lifecycle(changeset) do
    status = get_field(changeset, :status)
    owner = get_field(changeset, :lease_owner)
    generation = get_field(changeset, :lease_generation)
    expiry = get_field(changeset, :lease_expires_at)
    heartbeat = get_field(changeset, :heartbeat_at)
    completed = get_field(changeset, :completed_at)

    cond do
      status == "pending" and (owner || expiry || heartbeat || completed) ->
        add_error(changeset, :status, "pending agents cannot hold a lease or be completed")

      status in @leased_statuses and
          (owner in [nil, ""] or not is_integer(generation) or generation < 1 or is_nil(expiry) or
             is_nil(heartbeat) or not is_nil(completed)) ->
        add_error(changeset, :status, "active agents require a complete live lease")

      status == "interrupted" and (owner || expiry || completed) ->
        add_error(changeset, :status, "interrupted agents must have a cleared lease")

      status in @terminal_statuses and (owner || expiry || is_nil(completed)) ->
        add_error(changeset, :status, "terminal agents require completion and a cleared lease")

      true ->
        changeset
    end
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
end
