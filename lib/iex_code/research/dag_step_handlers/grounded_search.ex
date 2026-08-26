defmodule IexCode.Research.DagStepHandlers.GroundedSearch do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.{DagContracts, DagFanout, DagRuntime}

  @fields ~w(plane provider round provider_snapshot_ref max_search_calls max_input_tokens max_output_tokens max_cost_cents artifact_kind level_policy)

  @impl true
  def descriptor do
    %{
      kind: "research_grounded_search",
      version: 1,
      effect_class: :provider,
      replay_policy: :safe,
      resource_contract: "research_provider_request_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 180_000
    }
  end

  @impl true
  def validate_params(params, [_plan]) do
    with :ok <- DagContracts.exact_fields(params, @fields),
         true <- params["plane"] == "grounded_answer" or {:error, {:params, :plane}},
         :ok <- DagContracts.bounded_string(params["provider"], 80, :provider),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <- DagContracts.bounded_string(params["provider_snapshot_ref"], 500, :snapshot),
         :ok <- DagContracts.integer(params["max_search_calls"], 1..16, :search_calls),
         :ok <- DagContracts.integer(params["max_input_tokens"], 256..100_000, :input_tokens),
         :ok <- DagContracts.integer(params["max_output_tokens"], 256..100_000, :output_tokens),
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_grounded_answer" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies), do: {:error, :grounded_search_requires_plan}

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
        "research.grounded_batch",
        "research_grounded_answer",
        %{
          "provider" => params["provider"],
          "round" => params["round"],
          "entries" => entries,
          "ranked_results" => false
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
              runtime.grounded_search(
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
      "max_input_tokens" => allocated(params["max_input_tokens"], count, index),
      "max_output_tokens" => allocated(params["max_output_tokens"], count, index),
      "max_cost_cents" => allocated(params["max_cost_cents"], count, index),
      "max_search_calls" => 1,
      "provider_snapshot_ref" => params["provider_snapshot_ref"]
    }
  end

  defp reduce_outcome(_query, {:ok, result}, entries, usage) when is_map(result) do
    entry = %{
      "provider" => bounded(result["provider"], 80),
      "query" => bounded(result["query"], 2_000),
      "answer" => bounded(result["answer"], 5_000),
      "citations" => compact_citations(result["citations"]),
      "search_calls" => compact_calls(result["search_calls"]),
      "status" => "completed"
    }

    {:cont, {:ok, entries ++ [entry], add_usage(usage, result["usage"] || %{})}}
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
    entry = %{"query" => query, "status" => "failed", "error" => DagContracts.error_code(reason)}
    usage = usage |> increment("search_calls") |> increment("request_count")
    {:cont, {:ok, entries ++ [entry], usage}}
  end

  defp reduce_outcome(_query, _other, _entries, _usage),
    do: {:halt, {:error, :invalid_grounded_runtime_result}}

  defp reject_all_failed({:ok, entries, usage}) do
    if entries == [] or Enum.all?(entries, &(&1["status"] == "failed")),
      do: {:error, :all_grounded_queries_failed},
      else: {:ok, entries, usage}
  end

  defp reject_all_failed(other), do: other

  defp add_usage(usage, provider_usage) do
    usage = Map.update!(usage, "search_calls", &(&1 + 1))
    usage = Map.update!(usage, "request_count", &(&1 + 1))

    Enum.reduce(~w(input_tokens output_tokens cost_cents latency_ms), usage, fn key, acc ->
      value = Map.get(provider_usage, key, 0)
      if is_integer(value) and value >= 0, do: Map.update!(acc, key, &(&1 + value)), else: acc
    end)
  end

  defp fanout_context(context, params),
    do: Map.put(context, :level_policy, params["level_policy"])

  defp allocated(total, count, index) do
    base = div(total, count)
    if index <= rem(total, count), do: base + 1, else: base
  end

  defp compact_citations(values) when is_list(values) do
    values
    |> Enum.take(8)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn citation ->
      %{
        "url" => bounded(citation["url"], 2_000),
        "title" => bounded(citation["title"], 300),
        "cited_text" => bounded(citation["cited_text"], 700),
        "start_index" => counter(citation["start_index"]),
        "end_index" => counter(citation["end_index"])
      }
    end)
  end

  defp compact_citations(_values), do: []

  defp compact_calls(values) when is_list(values) do
    values
    |> Enum.take(4)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn call ->
      %{
        "id" => bounded(call["id"], 200),
        "status" => bounded(call["status"], 80),
        "queries" =>
          call
          |> Map.get("queries", [])
          |> Enum.filter(&is_binary/1)
          |> Enum.take(4)
          |> Enum.map(&bounded(&1, 500))
      }
    end)
  end

  defp compact_calls(_values), do: []
  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded(_value, _limit), do: nil
  defp counter(value) when is_integer(value) and value >= 0, do: value
  defp counter(_value), do: nil

  defp increment(usage, key), do: Map.update!(usage, key, &(&1 + 1))

  defp empty_usage do
    Map.new(
      ~w(input_tokens output_tokens cost_cents request_count latency_ms search_calls),
      &{&1, 0}
    )
  end
end
