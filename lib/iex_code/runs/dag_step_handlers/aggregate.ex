defmodule IexCode.Runs.DagStepHandlers.Aggregate do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  @impl true
  def descriptor do
    %{
      kind: "aggregate",
      version: 1,
      effect_class: :pure,
      replay_policy: :safe,
      resource_contract: "project_read_v1",
      checkpoint_version: 1,
      max_output_bytes: 256_000,
      default_timeout_ms: 30_000
    }
  end

  @impl true
  def validate_params(params, dependencies) do
    cond do
      dependencies == [] -> {:error, :aggregate_requires_dependencies}
      map_size(params) != 0 -> {:error, :aggregate_params_must_be_empty}
      true -> :ok
    end
  end

  @impl true
  def execute(_params, context) do
    if context.cancelled?.() do
      {:error, :cancelled}
    else
      {:ok, %{"dependencies" => context.dependency_results}}
    end
  end
end
