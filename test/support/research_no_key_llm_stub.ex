defmodule IexCode.TestResearchNoKeyLlmStub do
  @moduledoc false

  def chat(_messages, _system_prompt, _session, _on_chunk, _opts),
    do: {:error, :no_api_key}
end
