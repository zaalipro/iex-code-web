defmodule IexCode.Engine.SwarmOrchestrator do
  @moduledoc """
  Coordinates multi-agent swarm workflows. Delegates to `IexCode.Engine.SwarmCoordinator`
  which manages isolated OTP subagents (Planner, Explorer, Coder, Verifier) under AgentSupervisor
  with an autonomous self-healing feedback loop.
  """
  alias IexCode.Engine.SwarmCoordinator

  @doc """
  Runs the full swarm lifecycle asynchronously for a session and prompt.
  """
  def run_swarm(session_id, user_prompt, project_root, opts \\ []) do
    SwarmCoordinator.run_swarm(session_id, user_prompt, project_root, opts)
  end

  @doc """
  Runs the swarm coordination state machine synchronously.
  """
  def run(session_id, user_prompt, opts \\ []) do
    SwarmCoordinator.run(session_id, user_prompt, opts)
  end
end
