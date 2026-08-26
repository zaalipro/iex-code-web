defmodule IexCode.Research.DagStepHandlers.RankedSearch do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.{DagContracts, DagFanout, DagRuntime}

  @fields ~w(plane provider round provider_snapshot_ref max_search_calls max_results max_cost_cents artifact_kind level_policy)

  @impl true
  def descriptor do
    %{
      kind: "research_ranked_search",
      version: 1,
      effect_class: :provider,
      replay_policy: :safe,
      resource_contract: "research_provider_request_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 120_000
    }
  end

  @impl true
  def validate_params(params, [_plan]) do
    with :ok <- DagContracts.exact_fields(params, @fields),
         true <- params["plane"] == "ranked_results" or {:error, {:params, :plane}},
         :ok <- DagContracts.bounded_string(params["provider"], 80, :provider),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <- DagContracts.bounded_string(params["provider_snapshot_ref"], 500, :snapshot),
         :ok <- DagContracts.integer(params["max_search_calls"], 1..32, :search_calls),
         :ok <- DagContracts.integer(params["max_results"], 1..50, :results),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_query_ledger" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies), do: {:error, :ranked_search_requires_plan}

  @impl true
  def execute(params, context), do: execute(params, context, [])

  @doc false
  def execute(params, context, opts) when is_list(opts) do
    runtime = Keyword.get(opts, :runtime_module, DagRuntime)

    with {:ok, plan} <- DagContracts.dependency(context, "research.plan"),
         queries <- plan |> DagContracts.data() |> Map.get("queries", []),
         false <- queries == [],
         {:ok, entries, usage} <- run_queries(runtime, queries, params, context, opts) do
      DagContracts.wrap(
        "research.ranked_batch",
        "research_query_ledger",
        %{
          "provider" => params["provider"],
          "round" => params["round"],
          "entries" => entries
        },
        usage
      )
    else
      true -> {:error, :empty_research_plan}
      {:error, _reason} = error -> error
    end
  end

  defp run_queries(runtime, queries, params, context, opts) do
    selected = Enum.take(queries, params["max_search_calls"])

    with {:ok, outcomes} <-
           DagFanout.map(Enum.with_index(selected, 1), fanout_context(context, params), fn {query,
                                                                                            index} ->
             {query,
              runtime.ranked_search(
                runtime_params(query, index, length(selected), params),
                context,
                opts
              )}
           end) do
      outcomes
      |> Enum.reduce_while({:ok, [], empty_usage()}, fn {query, outcome}, {:ok, entries, usage} ->
        reduce_outcome(query, outcome, entries, usage)
      end)
      |> reject_all_failed()
    end
  end

  defp runtime_params(query, index, count, params) do
    %{
      "provider" => params["provider"],
      "query" => query,
      "round" => params["round"],
      "call_index" => index,
      "call_count" => count,
      "max_results" => params["max_results"],
      "max_cost_cents" => allocated(params["max_cost_cents"], count, index),
      "provider_snapshot_ref" => params["provider_snapshot_ref"]
    }
  end

  defp reduce_outcome(query, {:ok, result}, entries, usage) when is_map(result) do
    entry = %{
      "query" => query,
      "status" => "completed",
      "results" => compact_results(Map.get(result, "results", [])),
      "errors" => Map.get(result, "errors", %{})
    }

    {:cont, {:ok, entries ++ [entry], add_usage(usage, Map.get(result, "usage", %{}))}}
  end

  defp reduce_outcome(_query, {:error, :cancelled}, _entries, _usage),
    do: {:halt, {:error, :cancelled}}

  defp reduce_outcome(_query, {:error, reason}, _entries, _usage)
       when reason in [
              :provider_effect_unavailable,
              :provider_effect_replay_without_response,
              :invalid_provider_effect_receipt,
              :invalid_provider_effect_result,
              :provider_effect_failed,
              :external_effect_uncertain,
              :external_effect_unsettled,
              :external_effect_ambiguous,
              :external_effect_release_failed,
              :provider_configuration_changed,
              :invalid_provider_snapshot_ref
            ],
       do: {:halt, {:error, reason}}

  defp reduce_outcome(query, {:error, reason}, entries, usage) do
    entry = %{
      "query" => query,
      "status" => "failed",
      "error" => DagContracts.error_code(reason),
      "results" => []
    }

    usage = usage |> increment("search_calls") |> increment("request_count")
    {:cont, {:ok, entries ++ [entry], usage}}
  end

  defp reduce_outcome(_query, _other, _entries, _usage),
    do: {:halt, {:error, :invalid_ranked_runtime_result}}

  defp reject_all_failed({:ok, entries, usage})
       when entries != [] and is_list(entries) do
    if Enum.all?(entries, &(&1["status"] == "failed")),
      do: {:error, :all_ranked_queries_failed},
      else: {:ok, entries, usage}
  end

  defp reject_all_failed(other), do: other

  defp add_usage(usage, provider_usage) do
    Enum.reduce(
      ~w(input_tokens output_tokens cost_cents request_count latency_ms search_calls),
      usage,
      fn key, acc ->
        value = Map.get(provider_usage, key, 0)
        if is_integer(value) and value >= 0, do: Map.update!(acc, key, &(&1 + value)), else: acc
      end
    )
  end

  defp fanout_context(context, params),
    do: Map.put(context, :level_policy, params["level_policy"])

  defp allocated(total, count, index) do
    base = div(total, count)
    if index <= rem(total, count), do: base + 1, else: base
  end

  defp compact_results(results) when is_list(results) do
    results
    |> Enum.take(6)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn result ->
      %{
        "provider" => bounded(result["provider"], 80),
        "title" => bounded(result["title"], 300),
        "url" => bounded(result["url"], 2_000),
        "snippet" => bounded(result["snippet"], 700),
        "published_at" => bounded(result["published_at"], 200),
        "score" => if(is_number(result["score"]), do: result["score"], else: nil)
      }
    end)
  end

  defp compact_results(_results), do: []
  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded(_value, _limit), do: nil

  defp increment(usage, key), do: Map.update!(usage, key, &(&1 + 1))

  defp empty_usage do
    Map.new(
      ~w(input_tokens output_tokens cost_cents request_count latency_ms search_calls),
      &{&1, 0}
    )
  end
end
