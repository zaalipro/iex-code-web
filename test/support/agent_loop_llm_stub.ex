defmodule IexCode.AgentLoopLLMStub do
  def chat(messages, system_prompt, session, _on_chunk, opts) do
    receiver = Process.get(:agent_loop_receiver, self())

    send(receiver, {
      :agent_loop_llm_call,
      messages,
      system_prompt,
      %{
        provider: session.model_provider,
        model: session.model_name,
        temperature: session.temperature,
        allowed_tools: opts[:allowed_tools]
      }
    })

    case Process.get(:agent_loop_before_chat) do
      callback when is_function(callback, 0) -> callback.()
      _missing -> :ok
    end

    if Process.get(:agent_loop_probe_cancelled?, false) do
      send(receiver, {:agent_loop_cancelled_probe, opts[:cancelled?].()})
    end

    case Process.get(:agent_loop_responses, []) do
      [response | rest] ->
        Process.put(:agent_loop_responses, rest)
        response

      [] ->
        {:error, :no_stubbed_response}
    end
  end
end
