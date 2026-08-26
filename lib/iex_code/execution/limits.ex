defmodule IexCode.Execution.Limits do
  @moduledoc "Shared size limits enforced from configuration intake through provider execution."

  @max_model_name_bytes 240

  @spec max_model_name_bytes() :: pos_integer()
  def max_model_name_bytes, do: @max_model_name_bytes

  @spec valid_model_name?(term()) :: boolean()
  def valid_model_name?(value) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and
      byte_size(value) <= @max_model_name_bytes
  end

  def valid_model_name?(_value), do: false
end
