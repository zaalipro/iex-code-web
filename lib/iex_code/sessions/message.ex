defmodule IexCode.Sessions.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    # "user", "assistant", "system", "tool"
    field :role, :string
    field :agent_name, :string, default: "assistant"
    field :content, :string
    field :tool_calls, {:array, :map}
    field :metadata, :map
    field :idempotency_key, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0

    belongs_to :session, IexCode.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  @roles ~w(user assistant system tool)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :session_id,
      :role,
      :agent_name,
      :content,
      :tool_calls,
      :metadata,
      :idempotency_key,
      :input_tokens,
      :output_tokens,
      :cost_cents
    ])
    |> validate_required([:session_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> validate_format(:idempotency_key, ~r/^[^\s]+$/u)
    |> unique_constraint(:idempotency_key, name: :messages_idempotency_key_index)
    |> foreign_key_constraint(:session_id)
  end

  def roles, do: @roles
end
