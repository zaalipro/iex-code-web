defmodule IexCode.Execution.PolicyError do
  @moduledoc "A typed validation error for an explicit execution-policy override."

  @enforce_keys [:code, :field, :message]
  defstruct [:code, :field, :message, :value]

  @type t :: %__MODULE__{
          code: :unsupported_override | :invalid_override,
          field: String.t(),
          message: String.t(),
          value: term()
        }
end
