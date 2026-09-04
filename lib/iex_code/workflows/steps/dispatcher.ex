defmodule IexCode.Workflows.Steps.Dispatcher do
  @moduledoc """
  Routes workflow steps to their corresponding typed execution handlers.
  """

  alias IexCode.Workflows.Steps.{
    DeepResearch,
    GitCommit,
    SecurityAudit,
    SwarmCodeGen,
    TestVerification
  }

  @handlers %{
    "deep_research" => DeepResearch,
    "swarm_code_gen" => SwarmCodeGen,
    "test_verification" => TestVerification,
    "security_audit" => SecurityAudit,
    "git_commit" => GitCommit
  }

  @doc "Returns the handler module for a given step kind."
  @spec handler_for(String.t() | atom()) :: module() | nil
  def handler_for(kind) do
    kind_str = to_string(kind)
    Map.get(@handlers, kind_str)
  end

  @doc """
  Dispatches a step execution to its registered handler.
  Returns `{:ok, output_map}` or `{:error, reason}`.
  """
  @spec dispatch(map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(step, context) when is_map(step) and is_map(context) do
    params = Map.get(step, "params") || Map.get(step, :params) || %{}
    delay_ms = Map.get(params, "delay_ms") || Map.get(params, :delay_ms) || 0
    if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

    kind = Map.get(step, "kind") || Map.get(step, :kind)

    case handler_for(kind) do
      nil ->
        {:error, {:unknown_step_kind, kind}}

      handler ->
        try do
          handler.execute(step, context)
        rescue
          e ->
            {:error, {:step_exception, Exception.message(e), __STACKTRACE__}}
        end
    end
  end
end
