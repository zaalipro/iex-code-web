defmodule IexCode.Research.DagFanout do
  @moduledoc """
  Bounded asynchronous subagent fanout under one research-step lead.

  Results preserve input order for deterministic durable settlement. Task exits
  collapse to a stable code and cancellation fails closed.
  """

  alias IexCode.Research.{DagContracts, LevelPolicy}

  @spec map([term()], map(), (term() -> term())) :: {:ok, [term()]} | {:error, :cancelled}
  def map(items, context, callback)
      when is_list(items) and is_map(context) and is_function(callback, 1) do
    with false <- DagContracts.cancelled?(context),
         {:ok, policy} <- policy(context) do
      results =
        items
        |> Task.async_stream(
          fn item ->
            if DagContracts.cancelled?(context),
              do: {:error, :cancelled},
              else: callback.(item)
          end,
          max_concurrency: policy.async_subagents,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _reason} -> {:error, :research_subagent_exit}
        end)

      if DagContracts.cancelled?(context), do: {:error, :cancelled}, else: {:ok, results}
    else
      true -> {:error, :cancelled}
      {:error, _reason} -> {:error, :cancelled}
    end
  end

  defp policy(context) do
    durable =
      case Map.get(context, :step) do
        %{params: %{"level_policy" => value}} -> value
        _step -> Map.get(context, :level_policy)
      end

    case durable do
      %{"level" => level} -> LevelPolicy.fetch(level)
      _durable -> {:error, :invalid_research_level_policy}
    end
  end
end
