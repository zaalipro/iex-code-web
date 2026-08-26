defmodule IexCode.Runs.WorkspaceLock do
  @moduledoc """
  A durable workspace resource lock or wait request.

  Active identity is scoped to an owner, canonical workspace, resource and mode. Released,
  expired and cancelled rows are retained as an audit trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @resource_types ~w(project file git)
  @modes ~w(read write exclusive)
  @statuses ~w(waiting held released expired cancelled)
  @active_statuses ~w(waiting held)
  @terminal_statuses ~w(released expired cancelled)

  schema "workspace_locks" do
    field :resource_type, :string
    field :resource_key, :string
    field :workspace_key, :string
    field :batch_id, Ecto.UUID
    field :mode, :string
    field :status, :string, default: "waiting"
    field :owner_id, :string
    field :capability_token_hash, :string, redact: true
    field :capability_token, :string, virtual: true, redact: true
    field :fencing_token, :integer
    field :requested_at, :utc_datetime_usec
    field :acquired_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :conflict_owner_id, :string
    field :wait_reason, :string

    belongs_to :project, IexCode.Projects.Project
    belongs_to :run, IexCode.Runs.Run
    belongs_to :session, IexCode.Sessions.Session
    belongs_to :conflict_lock, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(lock, attrs) do
    lock
    |> cast(attrs, [
      :resource_type,
      :resource_key,
      :workspace_key,
      :batch_id,
      :mode,
      :status,
      :owner_id,
      :capability_token_hash,
      :fencing_token,
      :requested_at,
      :acquired_at,
      :heartbeat_at,
      :lease_expires_at,
      :released_at,
      :conflict_lock_id,
      :conflict_owner_id,
      :wait_reason
    ])
    |> validate_required([
      :project_id,
      :resource_type,
      :resource_key,
      :workspace_key,
      :batch_id,
      :mode,
      :status,
      :owner_id,
      :capability_token_hash,
      :requested_at
    ])
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:resource_key, min: 1, max: 4_096)
    |> validate_length(:workspace_key, min: 1, max: 4_096)
    |> validate_length(:owner_id, min: 1, max: 200)
    |> validate_format(:capability_token_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:fencing_token, greater_than: 0)
    |> validate_length(:conflict_owner_id, min: 1, max: 200)
    |> validate_inclusion(:wait_reason, ~w(external_conflict queue_predecessor batch_blocked))
    |> validate_lifecycle()
    |> check_constraint(:resource_type, name: :workspace_locks_resource_type_check)
    |> check_constraint(:mode, name: :workspace_locks_mode_check)
    |> check_constraint(:status, name: :workspace_locks_status_check)
    |> check_constraint(:capability_token_hash,
      name: :workspace_locks_capability_hash_check
    )
    |> check_constraint(:status, name: :workspace_locks_lifecycle_check)
    |> unique_constraint([:owner_id, :workspace_key, :resource_type, :resource_key, :mode],
      name: :workspace_locks_active_identity_index
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:conflict_lock_id)
    |> unique_constraint([:workspace_key, :fencing_token])
  end

  def resource_types, do: @resource_types
  def modes, do: @modes
  def statuses, do: @statuses
  def active_statuses, do: @active_statuses
  def terminal_statuses, do: @terminal_statuses

  defp validate_lifecycle(changeset) do
    case get_field(changeset, :status) do
      "waiting" ->
        changeset
        |> require_absent(:acquired_at)
        |> require_absent(:heartbeat_at)
        |> require_present(:lease_expires_at)
        |> require_absent(:released_at)
        |> require_absent(:fencing_token)
        |> require_present(:conflict_lock_id)
        |> require_present(:conflict_owner_id)
        |> require_present(:wait_reason)
        |> validate_conflict_pair()
        |> validate_wait_expiry()

      "held" ->
        changeset
        |> require_present(:acquired_at)
        |> require_present(:heartbeat_at)
        |> require_present(:lease_expires_at)
        |> require_present(:fencing_token)
        |> require_absent(:released_at)
        |> require_absent(:conflict_lock_id)
        |> require_absent(:conflict_owner_id)
        |> require_absent(:wait_reason)
        |> validate_lease_order()

      status when status in @terminal_statuses ->
        changeset
        |> require_present(:released_at)
        |> require_absent(:conflict_lock_id)
        |> require_absent(:conflict_owner_id)
        |> require_absent(:wait_reason)

      _status ->
        changeset
    end
  end

  defp validate_conflict_pair(changeset) do
    lock_id = get_field(changeset, :conflict_lock_id)
    owner_id = get_field(changeset, :conflict_owner_id)

    cond do
      is_nil(lock_id) and is_nil(owner_id) ->
        changeset

      present?(lock_id) and present?(owner_id) ->
        changeset

      is_nil(lock_id) ->
        add_error(changeset, :conflict_lock_id, "is required with conflict_owner_id")

      true ->
        add_error(changeset, :conflict_owner_id, "is required with conflict_lock_id")
    end
  end

  defp validate_lease_order(changeset) do
    acquired_at = get_field(changeset, :acquired_at)
    heartbeat_at = get_field(changeset, :heartbeat_at)
    expires_at = get_field(changeset, :lease_expires_at)

    changeset
    |> compare_timestamp(heartbeat_at, acquired_at, :heartbeat_at, "cannot be before acquired_at")
    |> compare_timestamp(
      expires_at,
      heartbeat_at,
      :lease_expires_at,
      "must be after heartbeat_at",
      :gt
    )
  end

  defp validate_wait_expiry(changeset) do
    compare_timestamp(
      changeset,
      get_field(changeset, :lease_expires_at),
      get_field(changeset, :requested_at),
      :lease_expires_at,
      "must be after requested_at",
      :gt
    )
  end

  defp compare_timestamp(
         changeset,
         left,
         right,
         field,
         message,
         order \\ :gte
       )

  defp compare_timestamp(
         changeset,
         %DateTime{} = left,
         %DateTime{} = right,
         field,
         message,
         order
       ) do
    comparison = DateTime.compare(left, right)
    valid? = if order == :gt, do: comparison == :gt, else: comparison != :lt
    if valid?, do: changeset, else: add_error(changeset, field, message)
  end

  defp compare_timestamp(changeset, _left, _right, _field, _message, _order), do: changeset

  defp require_present(changeset, field) do
    if present?(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, "is required")
  end

  defp require_absent(changeset, field) do
    if present?(get_field(changeset, field)),
      do: add_error(changeset, field, "must be empty"),
      else: changeset
  end

  defp present?(value), do: value not in [nil, ""]
end
