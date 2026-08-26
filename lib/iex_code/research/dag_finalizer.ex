defmodule IexCode.Research.DagFinalizer do
  @moduledoc """
  Idempotently materializes a completed research DAG's verified terminal result.

  Intermediate DAG envelopes remain append-only step-attempt results. Only the
  final verified Markdown becomes an integer-addressed, content-addressed public
  research result. A reconciler may safely call this again after process loss.
  """

  alias IexCode.Research.{ResearchResult, Results}
  alias IexCode.Runs
  alias IexCode.Runs.{DagPayload, Run}

  @final_step_key "research.report.verify"
  @max_sources 40

  @spec finalize(Run.t(), keyword()) :: {:ok, ResearchResult.t()} | {:error, term()}
  def finalize(run, opts \\ [])

  def finalize(
        %Run{kind: "deep_research", execution_engine: "dag_v1", status: "completed"} = run,
        opts
      )
      when is_list(opts) do
    results_module = Keyword.get(opts, :results_module, Results)
    step_resolver = Keyword.get(opts, :step_resolver, &Runs.list_steps/1)

    with {:ok, public_result} <- active_result(results_module, run),
         {:ok, step} <- final_step(step_resolver, run),
         {:ok, verified} <- verified_payload(step),
         {:ok, ready} <-
           results_module.commit(
             public_result,
             verified.markdown,
             commit_options(run, step, verified, opts)
           ) do
      {:ok, ready}
    end
  end

  def finalize(%Run{kind: "deep_research", execution_engine: "dag_v1", status: status}, _opts),
    do: {:error, {:research_dag_not_completed, status}}

  def finalize(%Run{}, _opts), do: {:error, :not_a_research_dag}
  def finalize(_run, _opts), do: {:error, :invalid_research_dag}

  @doc "Reconciles completed research DAGs whose public result is not ready."
  def reconcile(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 1_000) |> bounded_limit()
    results_module = Keyword.get(opts, :results_module, Results)

    reconcile_pages(results_module, opts, limit, 0, [])
  end

  @doc false
  def verified_payload(step) when is_map(step) do
    result = map_value(step, :result)

    with true <- map_value(step, :key) == @final_step_key or {:error, :wrong_terminal_step},
         true <- map_value(step, :status) == "completed" or {:error, :terminal_step_incomplete},
         {:ok, envelope} <- DagPayload.validate(result, max_bytes: 240_000),
         %{
           "contract" => "research.verified_report",
           "version" => 1,
           "artifact" => %{
             "kind" => "research_verified_report",
             "checksum" => "sha256:" <> artifact_digest
           },
           "data" => %{"verified" => true, "markdown" => markdown, "sources" => sources} = data
         } <- envelope,
         true <- is_binary(markdown) and byte_size(markdown) in 1..200_000,
         true <- is_list(sources) and length(sources) <= @max_sources,
         {:ok, verified_data_digest} <- DagPayload.digest(data),
         true <- verified_data_digest == artifact_digest,
         {:ok, envelope_digest} <- DagPayload.digest(envelope) do
      {:ok,
       %{
         markdown: markdown,
         source_count: length(sources),
         envelope_digest: envelope_digest
       }}
    else
      false -> {:error, :invalid_verified_research_payload}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_verified_research_payload}
    end
  end

  def verified_payload(_step), do: {:error, :invalid_terminal_step}

  defp reconcile_pages(results_module, opts, limit, after_id, acc) do
    page = results_module.list_unmaterialized_completed_page(limit: limit, after_id: after_id)

    case page do
      [] ->
        Enum.reverse(acc)

      rows ->
        page_results = Enum.map(rows, fn row -> {row.run.id, finalize(row.run, opts)} end)
        next_id = rows |> List.last() |> Map.fetch!(:result_id)
        reconcile_pages(results_module, opts, limit, next_id, Enum.reverse(page_results, acc))
    end
  end

  defp active_result(module, run) do
    case module.get_by_run(run) do
      %ResearchResult{status: status} = result when status in ["running", "ready"] ->
        {:ok, result}

      %ResearchResult{status: "queued"} = result ->
        module.mark_running(result)

      %ResearchResult{status: status} ->
        {:error, {:research_result_terminal, status}}

      nil ->
        module.prepare_run(run)
    end
  end

  defp final_step(resolver, run) when is_function(resolver, 1) do
    case Enum.find(resolver.(run), &(map_value(&1, :key) == @final_step_key)) do
      nil -> {:error, :verified_research_step_missing}
      step -> {:ok, step}
    end
  rescue
    _error -> {:error, :research_steps_unavailable}
  end

  defp final_step(_resolver, _run), do: {:error, :invalid_step_resolver}

  defp commit_options(run, step, verified, opts) do
    base = [
      source_count: verified.source_count,
      metadata: %{
        "dag_manifest_hash" => run.manifest_hash,
        "dag_step_id" => map_value(step, :id),
        "dag_step_key" => @final_step_key,
        "verified_envelope_sha256" => verified.envelope_digest
      }
    ]

    case opts[:root] do
      root when is_binary(root) and root != "" -> Keyword.put(base, :root, root)
      _root -> base
    end
  end

  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp bounded_limit(value) when is_integer(value), do: value |> max(1) |> min(1_000)
  defp bounded_limit(_value), do: 1_000
end
