defmodule IexCode.Runs.Run do
  @moduledoc "A durable asynchronous coding run."

  use Ecto.Schema
  import Ecto.Changeset

  alias IexCode.Runs.DagPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft queued running paused completed failed cancelled interrupted)
  @modes ~w(single swarm workflow research)
  @kinds ~w(coding_agent coding_swarm analysis deep_research)
  @priorities ~w(low normal high critical)
  @execution_engines ~w(legacy_v1 dag_v1)

  @manifest_fields [
    :objective,
    :kind,
    :mode,
    :execution_engine,
    :manifest_hash,
    :request_key,
    :request_fingerprint
  ]

  @mutable_fields [
    :status,
    :priority,
    :progress,
    :token_budget,
    :cost_budget_cents,
    :time_budget_ms,
    :input_tokens,
    :output_tokens,
    :cost_cents,
    :metadata,
    :error_message,
    :error_details,
    :started_at,
    :heartbeat_at,
    :completed_at,
    :lease_owner,
    :lease_expires_at,
    :cancellation_requested_at,
    :not_before,
    :attempt,
    :max_attempts,
    :lease_generation
  ]

  schema "runs" do
    field :objective, :string
    field :kind, :string, default: "coding_swarm"
    field :status, :string, default: "queued"
    field :mode, :string, default: "swarm"
    field :priority, :string, default: "normal"
    field :execution_engine, :string, default: "legacy_v1"
    field :manifest_hash, :string
    field :request_key, :string
    field :request_fingerprint, :string
    field :lease_generation, :integer, default: 0
    field :progress, :integer, default: 0
    field :event_sequence, :integer, default: 0
    field :control_sequence, :integer, default: 0
    field :token_budget, :integer
    field :cost_budget_cents, :integer
    field :time_budget_ms, :integer
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :metadata, :map, default: %{}
    field :error_message, :string
    field :error_details, :map
    field :started_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :cancellation_requested_at, :utc_datetime
    field :not_before, :utc_datetime
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 3

    belongs_to :project, IexCode.Projects.Project
    belongs_to :session, IexCode.Sessions.Session
    has_many :steps, IexCode.Runs.RunStep
    has_many :events, IexCode.Runs.RunEvent
    has_many :commands, IexCode.Runs.RunCommand
    has_many :approvals, IexCode.Runs.RunApproval
    has_many :artifacts, IexCode.Runs.RunArtifact
    has_many :controls, IexCode.Runs.RunControl
    has_many :agents, IexCode.Runs.RunAgent
    has_many :agent_controls, IexCode.Runs.RunAgentControl
    has_many :step_attempts, IexCode.Runs.RunStepAttempt

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(%__MODULE__{id: nil} = run, attrs) do
    run
    |> cast(attrs, @manifest_fields ++ @mutable_fields)
    |> validate_changeset()
  end

  def create_changeset(%__MODULE__{} = run, attrs), do: changeset(run, attrs)

  def changeset(%__MODULE__{id: nil} = run, attrs), do: create_changeset(run, attrs)

  def changeset(run, attrs) do
    run
    |> cast(attrs, @mutable_fields)
    |> reject_manifest_changes(run, attrs)
    |> reject_execution_policy_change(run, attrs)
    |> validate_changeset()
  end

  defp validate_changeset(changeset) do
    changeset
    |> validate_required([
      :project_id,
      :session_id,
      :objective,
      :kind,
      :status,
      :mode,
      :priority,
      :execution_engine
    ])
    |> validate_length(:objective, min: 1, max: 100_000)
    |> validate_length(:request_key, min: 1, max: 200)
    |> validate_length(:request_fingerprint, is: 64)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_request_identity()
    |> validate_length(:error_message, max: 20_000)
    |> validate_length(:lease_owner, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:execution_engine, @execution_engines)
    |> require_dag_manifest_hash()
    |> validate_length(:manifest_hash, is: 64)
    |> validate_format(:manifest_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_nonnegative_optional(:token_budget)
    |> validate_nonnegative_optional(:cost_budget_cents)
    |> validate_nonnegative_optional(:time_budget_ms)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents, greater_than_or_equal_to: 0)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:lease_generation, greater_than_or_equal_to: 0)
    |> validate_attempts()
    |> validate_execution_policy()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :request_key], name: :runs_session_id_request_key_index)
    |> check_constraint(:execution_engine, name: :runs_execution_engine_check)
    |> check_constraint(:manifest_hash, name: :runs_manifest_hash_shape)
    |> check_constraint(:lease_generation, name: :runs_lease_generation_nonnegative)
  end

  def statuses, do: @statuses
  def modes, do: @modes
  def kinds, do: @kinds
  def priorities, do: @priorities
  def execution_engines, do: @execution_engines

  defp reject_manifest_changes(changeset, %__MODULE__{id: id} = run, attrs)
       when not is_nil(id) and is_map(attrs) do
    Enum.reduce(@manifest_fields, changeset, fn field, current ->
      case manifest_attr(attrs, field) do
        :absent ->
          current

        {:present, requested} ->
          if requested == Map.get(run, field) do
            current
          else
            add_error(current, field, "cannot be changed after creation")
          end
      end
    end)
  end

  defp reject_manifest_changes(changeset, _run, _attrs), do: changeset

  defp reject_execution_policy_change(changeset, %__MODULE__{id: id} = run, attrs)
       when not is_nil(id) and is_map(attrs) do
    case manifest_attr(attrs, :metadata) do
      :absent ->
        changeset

      {:present, requested_metadata} when is_map(requested_metadata) ->
        stored_policy = execution_policy(run.metadata)
        requested_policy = execution_policy(requested_metadata)

        if stored_policy == requested_policy,
          do: changeset,
          else:
            add_error(changeset, :metadata, "execution policy cannot be changed after creation")

      {:present, _invalid} ->
        changeset
    end
  end

  defp reject_execution_policy_change(changeset, _run, _attrs), do: changeset

  defp manifest_attr(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> {:present, Map.get(attrs, field)}
      Map.has_key?(attrs, string_field) -> {:present, Map.get(attrs, string_field)}
      true -> :absent
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

  defp validate_request_identity(changeset) do
    case {get_field(changeset, :request_key), get_field(changeset, :request_fingerprint)} do
      {nil, nil} -> changeset
      {key, fingerprint} when is_binary(key) and is_binary(fingerprint) -> changeset
      {nil, _fingerprint} -> add_error(changeset, :request_key, "is required with a fingerprint")
      {_key, nil} -> add_error(changeset, :request_fingerprint, "is required with a request key")
    end
  end

  defp require_dag_manifest_hash(changeset) do
    if get_field(changeset, :execution_engine) == "dag_v1" and
         is_nil(get_field(changeset, :manifest_hash)) do
      add_error(changeset, :manifest_hash, "is required for dag_v1")
    else
      changeset
    end
  end

  defp validate_execution_policy(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      case execution_policy(metadata) do
        nil ->
          []

        policy when is_map(policy) and not is_struct(policy) ->
          case DagPayload.validate(policy, max_bytes: 32_000) do
            {:ok, _policy} ->
              []

            {:error, reason} ->
              [metadata: "contains an invalid execution policy: #{inspect(reason)}"]
          end

        _invalid ->
          [metadata: "execution policy must be a map"]
      end
    end)
  end

  defp execution_policy(metadata) when is_map(metadata) do
    cond do
      Map.has_key?(metadata, "execution_policy") -> Map.get(metadata, "execution_policy")
      Map.has_key?(metadata, :execution_policy) -> Map.get(metadata, :execution_policy)
      true -> nil
    end
  end

  defp execution_policy(_metadata), do: nil

  defp validate_nonnegative_optional(changeset, field) do
    validate_number(changeset, field, greater_than_or_equal_to: 0)
  end
end
