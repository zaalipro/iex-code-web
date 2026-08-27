defmodule IexCode.Outputs.Writer do
  @moduledoc false

  @enforce_keys [
    :artifact_id,
    :root,
    :relative_path,
    :io,
    :partial_path,
    :final_path,
    :limit_bytes,
    :preview_bytes,
    :hash
  ]
  defstruct [
    :artifact_id,
    :root,
    :relative_path,
    :io,
    :partial_path,
    :final_path,
    :limit_bytes,
    :preview_bytes,
    :hash,
    bytes: 0,
    head: "",
    tail: "",
    closed?: false
  ]

  @type t :: %__MODULE__{}
end
