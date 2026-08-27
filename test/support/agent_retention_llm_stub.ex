defmodule IexCode.AgentRetentionLLMStub do
  @moduledoc false

  def chat(_messages, _system_prompt, _session, _on_chunk, _opts) do
    {:ok,
     %{
       text: String.duplicate("bounded-result-", 2_000),
       tool_calls: [],
       usage: %{input_tokens: 1, output_tokens: 1, cost_cents: 0}
     }}
  end
end
