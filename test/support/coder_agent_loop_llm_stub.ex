defmodule IexCode.CoderAgentLoopLLMStub do
  @moduledoc false

  use Agent

  def start_link(responses) do
    Agent.start_link(fn -> %{calls: 0, responses: responses, requests: []} end, name: __MODULE__)
  end

  def calls, do: Agent.get(__MODULE__, & &1.calls)
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def chat(messages, _system_prompt, _session, _on_chunk, _opts) do
    Agent.get_and_update(__MODULE__, fn
      %{responses: [response | rest]} = state ->
        {response,
         %{state | calls: state.calls + 1, responses: rest, requests: [messages | state.requests]}}

      state ->
        {{:error, :no_stubbed_response}, %{state | calls: state.calls + 1}}
    end)
  end
end
