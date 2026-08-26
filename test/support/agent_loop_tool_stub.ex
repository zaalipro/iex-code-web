defmodule IexCode.AgentLoopToolStub do
  def execute(name, arguments, project_root, progress) do
    receiver = Process.get(:agent_loop_receiver, self())
    send(receiver, {:agent_loop_tool_call, name, arguments, project_root})
    progress.(50, "stub tool running")

    case Process.get(:agent_loop_tool_result, {:ok, "stub output"}) do
      fun when is_function(fun, 3) -> fun.(name, arguments, project_root)
      result -> result
    end
  end
end
