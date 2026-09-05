defmodule IexCode.CancelledLLMStub do
  def chat(_messages, _system_prompt, _session, _on_chunk, _opts), do: {:error, :cancelled}
end
