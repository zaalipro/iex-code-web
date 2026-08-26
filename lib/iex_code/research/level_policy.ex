defmodule IexCode.Research.LevelPolicy do
  @moduledoc """
  Exact finite research-level contract used by DAG manifests and handlers.

  Every step has one lead. `async_subagents` is the maximum bounded fanout the
  research handler may supervise inside that step; it does not alter DAG
  scheduler concurrency or authorize arbitrary child processes.
  """

  @policies %{
    "low" => %{level: "low", multistep_rounds: 1, async_subagents: 2, lead_per_step: 1},
    "medium" => %{level: "medium", multistep_rounds: 2, async_subagents: 3, lead_per_step: 1},
    "high" => %{level: "high", multistep_rounds: 3, async_subagents: 4, lead_per_step: 1},
    "ultra" => %{level: "ultra", multistep_rounds: 4, async_subagents: 10, lead_per_step: 1}
  }

  @type t :: %{
          level: String.t(),
          multistep_rounds: 1..4,
          async_subagents: 2..10,
          lead_per_step: 1
        }

  @spec fetch(atom() | String.t()) :: {:ok, t()} | {:error, :invalid_research_level}
  def fetch(level) when is_atom(level), do: fetch(Atom.to_string(level))
  def fetch(level) when is_binary(level), do: Map.fetch(@policies, level) |> normalize_error()
  def fetch(_level), do: {:error, :invalid_research_level}

  @spec names() :: [String.t()]
  def names, do: ~w(low medium high ultra)

  @spec durable(t()) :: map()
  def durable(policy) do
    %{
      "level" => policy.level,
      "multistep_rounds" => policy.multistep_rounds,
      "lead_per_step" => policy.lead_per_step,
      "async_subagents" => policy.async_subagents
    }
  end

  @spec validate_durable(term()) :: :ok | {:error, term()}
  def validate_durable(value) when is_map(value) do
    with {:ok, expected} <- fetch(Map.get(value, "level")),
         true <- value == durable(expected) do
      :ok
    else
      false -> {:error, :research_level_policy_drift}
      {:error, _reason} = error -> error
    end
  end

  def validate_durable(_value), do: {:error, :invalid_research_level_policy}

  defp normalize_error({:ok, policy}), do: {:ok, policy}
  defp normalize_error(:error), do: {:error, :invalid_research_level}
end
