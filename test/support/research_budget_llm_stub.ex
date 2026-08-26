defmodule IexCode.TestResearchTokenBudgetLlmStub do
  @moduledoc false

  def chat(_messages, _system_prompt, _session, _on_chunk, _opts) do
    {:ok,
     %{
       text: "# Budgeted findings\n\nEvidence-backed synthesis [1].",
       usage: %{input_tokens: 3}
     }}
  end
end
