defmodule IexCode.TestResearchCostBudgetLlmStub do
  @moduledoc false

  def chat(_messages, _system_prompt, _session, _on_chunk, _opts) do
    {:ok,
     %{
       text: "# Budgeted findings\n\nEvidence-backed synthesis [1].",
       usage: %{cost_cents: 3}
     }}
  end
end
