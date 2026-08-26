defmodule IexCode.Engine.FleetRuntime do
  @moduledoc false

  alias IexCode.Engine.FleetManager

  def owner(opts) do
    case {opts[:run_id], opts[:run_agent_id], opts[:lease_owner], opts[:generation]} do
      {run_id, agent_id, _lease_owner, generation}
      when is_binary(run_id) and is_binary(agent_id) and is_integer(generation) ->
        %{
          run_id: run_id,
          agent_id: agent_id,
          generation: generation
        }

      _ ->
        nil
    end
  end

  def run(owner, task, fun) when is_function(fun, 0) do
    run(owner, nil, task, fun)
  end

  def run(owner, token, task, fun) when is_function(fun, 0) do
    control = if token, do: IexCode.Engine.FleetControlToken.checkpoint(token), else: :ok

    if control == :cancelled do
      {:error, :cancelled}
    else
      case begin_work(owner, task) do
        :ok ->
          result = fun.()
          _ = finish_work(owner, result)
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def begin_work(nil, _task), do: :ok

  def begin_work(owner, task) do
    IexCode.Engine.FleetManager.runtime_begin(
      owner.run_id,
      owner.agent_id,
      owner.generation,
      task
    )
  end

  def progress(nil, _percent, _message), do: :ok

  def progress(owner, percent, message) do
    IexCode.Engine.FleetManager.runtime_progress(
      owner.run_id,
      owner.agent_id,
      owner.generation,
      percent,
      message
    )
  end

  def finish_work(nil, _result), do: :ok

  def finish_work(owner, result) do
    IexCode.Engine.FleetManager.runtime_finish(
      owner.run_id,
      owner.agent_id,
      owner.generation,
      result
    )
  end

  def record_usage(owner, usage, source) do
    IexCode.Engine.FleetManager.runtime_usage(
      owner.run_id,
      owner.agent_id,
      owner.generation,
      usage,
      source
    )
  end

  @doc false
  def invoke_agent(run_id, agent_id, fun)
      when is_binary(run_id) and is_binary(agent_id) and is_function(fun, 1) do
    try do
      with {:ok, entry} <- FleetManager.current_agent(run_id, agent_id) do
        fun.(entry)
      end
    catch
      :exit, _reason -> {:error, :agent_invocation_interrupted}
    end
  end
end
