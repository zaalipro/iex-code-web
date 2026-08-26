defmodule IexCode.TestResearchLlmStub do
  @moduledoc false

  def chat(messages, system_prompt, _session, _on_chunk, opts) do
    send(self(), {:research_synthesis, messages, system_prompt, opts})

    {:ok,
     %{
       text:
         "# Findings\n\nDurable orchestration persists checkpoints [1]. Provenance supports trustworthy synthesis [2]."
     }}
  end
end
