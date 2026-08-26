defmodule IexCode.ConcurrentAgentLLMStub do
  @moduledoc false

  def chat(_messages, system_prompt, _session, _on_chunk, _opts) do
    text =
      if String.contains?(system_prompt, "Master Planner") do
        "deterministic concurrent plan"
      else
        "deterministic concurrent implementation"
      end

    {:ok,
     %{
       text: text,
       tool_calls: [],
       usage: %{input_tokens: 1, output_tokens: 1, cost_cents: 0}
     }}
  end
end
