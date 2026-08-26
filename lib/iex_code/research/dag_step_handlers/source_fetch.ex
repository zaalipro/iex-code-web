defmodule IexCode.Research.DagStepHandlers.SourceFetch do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.{DagContracts, DagRuntime}

  @fields ~w(round max_sources max_requests max_cost_cents max_parallel_fetches max_body_bytes max_text_chars require_public_destination artifact_kind level_policy)
  @max_sources 40

  @impl true
  def descriptor do
    %{
      kind: "research_source_fetch",
      version: 1,
      effect_class: :provider,
      replay_policy: :safe,
      resource_contract: "research_public_fetch_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 180_000
    }
  end

  @impl true
  def validate_params(params, [_evidence]) do
    with :ok <- DagContracts.exact_fields(params, @fields),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <- DagContracts.integer(params["max_sources"], 1..@max_sources, :max_sources),
         true <-
           params["max_requests"] == params["max_sources"] or
             {:error, {:params, :max_requests}},
         :ok <- DagContracts.integer(params["max_cost_cents"], 0..100_000, :cost),
         :ok <- DagContracts.integer(params["max_parallel_fetches"], 1..16, :parallel),
         :ok <- DagContracts.integer(params["max_body_bytes"], 1_000..5_000_000, :body),
         :ok <- DagContracts.integer(params["max_text_chars"], 1_000..200_000, :text),
         true <- params["require_public_destination"] or {:error, {:params, :public_destination}},
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <-
           params["artifact_kind"] == "research_fetched_evidence" or
             {:error, {:params, :artifact_kind}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  def validate_params(_params, _dependencies), do: {:error, :fetch_requires_evidence}

  @impl true
  def execute(params, context), do: execute(params, context, [])

  @doc false
  def execute(params, context, opts) when is_list(opts) do
    runtime = Keyword.get(opts, :runtime_module, DagRuntime)

    with {:ok, evidence} <- DagContracts.dependency(context, "research.evidence"),
         sources <- evidence |> DagContracts.data() |> Map.get("sources", []),
         false <- sources == [],
         selected <- Enum.take(sources, params["max_sources"]),
         per_source_text <-
           min(params["max_text_chars"], max(div(100_000, length(selected)), 1_000)),
         {:ok, fetched} <-
           runtime.fetch_sources(
             %{
               "sources" => selected,
               "round" => params["round"],
               "max_requests" => params["max_requests"],
               "max_cost_cents" => params["max_cost_cents"],
               "max_parallel_fetches" => params["max_parallel_fetches"],
               "max_body_bytes" => params["max_body_bytes"],
               "max_text_chars" => per_source_text
             },
             context,
             opts
           ) do
      DagContracts.wrap(
        "research.fetched_evidence",
        "research_fetched_evidence",
        %{
          "round" => params["round"],
          "sources" => Map.get(fetched, "sources", []),
          "source_count" => length(Map.get(fetched, "sources", [])),
          "per_source_text_limit" => per_source_text
        },
        Map.get(fetched, "usage", %{})
      )
    else
      true -> {:error, :no_research_evidence}
      {:error, _reason} = error -> error
    end
  end
end
