defmodule IexCode.Execution.CommandError do
  @moduledoc "A typed error returned by the pure execution command parser."

  @enforce_keys [:code, :message, :supported_commands]
  defstruct [:code, :message, :command, supported_commands: []]

  @type code ::
          :invalid_input
          | :invalid_encoding
          | :input_too_large
          | :empty_input
          | :missing_objective
          | :unknown_command
          | :unexpected_arguments
          | :invalid_option
          | :invalid_level
          | :invalid_attachment_id

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          command: String.t() | nil,
          supported_commands: [String.t()]
        }
end
