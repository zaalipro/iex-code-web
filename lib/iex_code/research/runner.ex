defmodule IexCode.Research.Runner do
  @moduledoc """
  Durable orchestration for a federated research run.

  Search evidence is committed before synthesis starts, so a missing LLM key or a
  provider failure never causes evidence to disappear. Stage keys include the run
  attempt and can safely coexist with dispatcher-created graph nodes and prior retries.
  """

  alias IexCode.Research.{Fetcher, Report, Results, Search}
  alias IexCode.Runs
  alias IexCode.Runs.{Run, RunStep}
  alias IexCode.{Sessions, Settings}

  @default_depth "standard"
  @default_max_sources 12
  @max_sources 100

  def execute(run, progress_fun, opts \\ [])

  def execute(%Run{} = run, progress_fun, opts) when is_function(progress_fun, 2) do
    search_module = Keyword.get(opts, :search_module, Search)
    llm_module = Keyword.get(opts, :llm_module, IexCode.LLM)
    config = research_config(run, opts)

    with :ok <- assert_run_authority(run, opts),
         {:ok, durable_result} <- prepare_result(run, opts),
         :ok <- control_checkpoint(run, opts),
         {:ok, plan_step} <- stage(run, "plan", "Research plan", 20, opts),
         :ok <- begin_stage(plan_step, opts),
         :ok <- announce(run, progress_fun, 5, "Planning durable research strategy", opts),
         {:ok, _step} <- finish_plan(plan_step, run, config, opts),
         {:ok, search_step} <- stage(run, "search", "Federated evidence search", 21, opts),
         :ok <- begin_stage(search_step, opts),
         :ok <-
           announce(
             run,
             progress_fun,
             10,
             "Searching #{provider_label(config.providers)}",
             opts
           ),
         :ok <- control_checkpoint(run, opts),
         {:ok, search_result} <-
           perform_search(search_module, config.queries, config, opts, fn ->
             control_checkpoint(run, opts)
           end),
         {:ok, sources} <- normalize_sources(search_result.results, config.max_sources),
         {:ok, _step} <- finish_stage(search_step, sources, search_result, opts),
         :ok <-
           announce(
             run,
             progress_fun,
             55,
             "Collected #{length(sources)} research sources",
             opts
           ),
         {:ok, sources, evidence_step} <-
           maybe_fetch_sources(run, sources, progress_fun, config, opts),
         {:ok, sources} <- bound_source_evidence(sources, config.depth),
         {:ok, evidence_artifact} <-
           persist_evidence(run, evidence_step || search_step, sources, search_result, opts),
         :ok <- control_checkpoint(run, opts),
         {:ok, synthesis_step} <-
           stage(run, "synthesize", "Evidence-grounded synthesis", 23, opts),
         :ok <- begin_stage(synthesis_step, opts),
         :ok <- announce(run, progress_fun, 65, "Synthesizing cited research report", opts),
         :ok <- control_checkpoint(run, opts),
         {:ok, markdown} <- synthesize(llm_module, run, sources, config, opts),
         :ok <- control_checkpoint(run, opts, false),
         {:ok, report_artifact} <-
           persist_report(run, synthesis_step, markdown, sources, config, durable_result, opts),
         {:ok, _step} <- finish_synthesis(synthesis_step, markdown, sources, opts),
         :ok <- announce(run, progress_fun, 100, "Research report ready", opts) do
      {:ok,
       %{
         report: markdown,
         sources: sources,
         providers: search_result.providers,
         provider_errors: search_result.errors,
         depth: config.depth,
         research_result_id: durable_result && durable_result.id,
         artifacts: %{evidence: evidence_artifact, report: report_artifact}
       }}
    else
      {:error, reason} = error ->
        record_failure(run, reason, opts)
        terminalize_result(run, reason, opts)
        error
    end
  rescue
    error ->
      reason = {error, __STACKTRACE__}
      record_failure(run, reason, opts)
      terminalize_result(run, reason, opts)
      {:error, reason}
  catch
    kind, reason ->
      caught = {kind, reason}
      record_failure(run, caught, opts)
      terminalize_result(run, caught, opts)
      {:error, caught}
  end

  def execute(_run, _progress_fun, _opts), do: {:error, :invalid_research_run}

  defp research_config(run, opts) do
    metadata = stringify_keys(run.metadata || %{})
    nested = stringify_keys(Map.get(metadata, "research", %{}))
    settings = Settings.search_config()

    providers =
      Keyword.get(opts, :providers) || nested["providers"] || metadata["providers"] ||
        metadata["research_providers"] || settings.providers

    provider_config =
      Keyword.get(opts, :provider_config) || Keyword.get(opts, :config) || nested["config"] ||
        metadata["provider_config"] || settings.providers

    depth =
      Keyword.get(opts, :depth) || nested["depth"] || metadata["depth"] ||
        metadata["research_depth"] || settings.depth || @default_depth

    max_sources =
      Keyword.get(opts, :max_sources) || nested["max_sources"] || metadata["max_sources"] ||
        metadata["research_max_sources"] || settings.max_sources || @default_max_sources

    normalized_depth = normalize_depth(depth)

    %{
      providers: normalize_providers(providers),
      provider_config: provider_config,
      depth: normalized_depth,
      max_sources: normalize_max_sources(max_sources),
      max_concurrency: Keyword.get(opts, :max_concurrency) || settings.parallelism,
      queries: research_queries(run.objective, normalized_depth)
    }
  end

  defp perform_search(module, queries, config, opts, checkpoint) do
    search_opts =
      [providers: config.providers, limit: config.max_sources]
      |> maybe_put(:config, config.provider_config)
      |> maybe_put(:request, Keyword.get(opts, :request))
      |> maybe_put(:timeout, Keyword.get(opts, :timeout))
      |> maybe_put(:max_concurrency, config.max_concurrency)

    outcomes_result =
      Enum.reduce_while(queries, {:ok, []}, fn query, {:ok, outcomes} ->
        with :ok <- checkpoint.() do
          outcome = normalize_search_outcome(query, module.search(query, search_opts))

          case checkpoint.() do
            :ok -> {:cont, {:ok, [outcome | outcomes]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, reversed_outcomes} <- outcomes_result do
      finish_search_outcomes(Enum.reverse(reversed_outcomes), queries)
    end
  end

  defp finish_search_outcomes(outcomes, queries) do
    successes =
      Enum.flat_map(outcomes, fn
        {_query, {:ok, result}} -> [result]
        _failure -> []
      end)

    if successes == [] do
      {:error,
       {:all_research_queries_failed,
        Map.new(outcomes, fn {query, outcome} -> {query, safe_term(outcome)} end)}}
    else
      {:ok,
       %{
         results:
           successes
           |> Enum.flat_map(& &1.results)
           |> Enum.uniq_by(&(value(&1, :url) || inspect(&1))),
         errors:
           successes
           |> Enum.map(& &1.errors)
           |> Enum.reduce(%{}, &Map.merge/2),
         providers: successes |> Enum.flat_map(& &1.providers) |> Enum.uniq(),
         queries: queries
       }}
    end
  end

  defp normalize_search_outcome(query, {:ok, %{results: results} = result})
       when is_list(results) do
    {query,
     {:ok,
      %{
        results: results,
        errors: Map.get(result, :errors, Map.get(result, "errors", %{})),
        providers: Map.get(result, :providers, Map.get(result, "providers", []))
      }}}
  end

  defp normalize_search_outcome(query, {:ok, %{"results" => results} = result})
       when is_list(results) do
    {query,
     {:ok,
      %{
        results: results,
        errors: Map.get(result, "errors", %{}),
        providers: Map.get(result, "providers", [])
      }}}
  end

  defp normalize_search_outcome(query, {:error, reason}), do: {query, {:error, reason}}

  defp normalize_search_outcome(query, other),
    do: {query, {:error, {:invalid_search_response, other}}}

  defp normalize_sources(results, max_sources) do
    sources =
      results
      |> Enum.map(&normalize_source/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.url)
      |> Enum.take(max_sources)

    if sources == [], do: {:error, :no_research_evidence}, else: {:ok, sources}
  end

  defp normalize_source(result) when is_map(result) do
    title = value(result, :title)
    url = value(result, :url)
    snippet = value(result, :snippet) || value(result, :content)

    if present?(title) and valid_source_url?(url) and present?(snippet) do
      %{
        provider: stringify(value(result, :provider) || "unknown"),
        title: stringify(title),
        url: stringify(url),
        snippet: stringify(snippet),
        published_at: stringify_optional(value(result, :published_at)),
        score: json_scalar(value(result, :score)),
        metadata: json_map(value(result, :metadata))
      }
    end
  end

  defp normalize_source(_result), do: nil

  defp bound_source_evidence(sources, depth) do
    budget = if depth == "deep", do: 240_000, else: 120_000

    {bounded, _remaining} =
      Enum.map_reduce(sources, budget, fn source, remaining ->
        allowed = min(max(remaining, 0), 12_000)
        snippet = if allowed > 0, do: String.slice(source.snippet, 0, allowed), else: ""

        {%{source | snippet: snippet, metadata: bounded_metadata(source.metadata)},
         remaining - String.length(snippet)}
      end)

    bounded = Enum.reject(bounded, &(&1.snippet == ""))
    if bounded == [], do: {:error, :research_evidence_budget_empty}, else: {:ok, bounded}
  end

  defp bounded_metadata(metadata) when is_map(metadata) do
    safe = safe_term(metadata)

    case Jason.encode(safe) do
      {:ok, encoded} when byte_size(encoded) <= 8_000 -> safe
      _ -> %{"truncated" => true}
    end
  end

  defp bounded_metadata(_metadata), do: %{}

  defp maybe_fetch_sources(run, sources, progress_fun, config, opts) do
    fetch? = Keyword.get(opts, :fetch_sources, false) and config.depth != "quick"

    if fetch? do
      fetcher = Keyword.get(opts, :fetcher_module, Fetcher)
      parallelism = opts |> Keyword.get(:fetch_parallelism, 4) |> min(8) |> max(1)

      with {:ok, fetch_step} <- stage(run, "fetch", "Bounded public source fetch", 22, opts),
           :ok <- begin_stage(fetch_step, opts),
           :ok <- announce(run, progress_fun, 58, "Fetching public source content", opts) do
        with {:ok, enriched} <-
               fetch_source_batches(run, sources, fetcher, parallelism, opts) do
          fetched_count = Enum.count(enriched, &Map.get(&1.metadata, "fetched", false))

          case transition_step(
                 fetch_step,
                 "completed",
                 %{
                   result: %{
                     "source_count" => length(enriched),
                     "fetched_count" => fetched_count
                   }
                 },
                 opts
               ) do
            {:ok, completed} ->
              _ =
                announce(
                  run,
                  progress_fun,
                  62,
                  "Fetched #{fetched_count}/#{length(enriched)} sources",
                  opts
                )

              {:ok, enriched, completed}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end
    else
      reason = if config.depth == "quick", do: "quick_depth", else: "source_fetch_disabled"

      with {:ok, _skipped_step} <- terminalize_unneeded_fetch(run, reason, opts) do
        {:ok, sources, nil}
      end
    end
  end

  defp fetch_source_batches(run, sources, fetcher, parallelism, opts) do
    sources
    |> Enum.chunk_every(parallelism)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, enriched} ->
      with :ok <- control_checkpoint(run, opts) do
        fetched =
          batch
          |> Task.async_stream(
            fn source -> enrich_source(source, fetcher, opts) end,
            max_concurrency: parallelism,
            timeout: Keyword.get(opts, :fetch_timeout, 15_000),
            on_timeout: :kill_task,
            ordered: true
          )
          |> Enum.zip(batch)
          |> Enum.map(fn
            {{:ok, source}, _original} -> source
            {{:exit, reason}, original} -> put_fetch_error(original, {:task_exit, reason})
          end)

        case control_checkpoint(run, opts) do
          :ok -> {:cont, {:ok, enriched ++ fetched}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp terminalize_unneeded_fetch(run, reason, opts) do
    case Enum.find(Runs.list_steps(run), &(&1.key == stage_key(run, "fetch"))) do
      %RunStep{status: status} = step
      when status in ["pending", "ready", "blocked", "interrupted"] ->
        transition_step(step, "skipped", %{result: %{"reason" => reason}}, opts)

      %RunStep{status: status} = step when status in ["running", "paused", "waiting_approval"] ->
        transition_step(step, "cancelled", %{result: %{"reason" => reason}}, opts)

      %RunStep{status: status} = step when status in ["completed", "skipped"] ->
        {:ok, step}

      %RunStep{status: status} ->
        {:error, {:research_stage_terminal, "fetch", status}}

      nil ->
        {:ok, nil}
    end
  end

  defp enrich_source(source, fetcher, opts) do
    fetch_opts =
      opts
      |> Keyword.take([:resolver, :request])
      |> Keyword.put(:timeout, Keyword.get(opts, :source_timeout, 10_000))
      |> Keyword.put(:max_body_bytes, Keyword.get(opts, :source_max_body_bytes, 750_000))
      |> Keyword.put(:max_text_chars, Keyword.get(opts, :source_max_text_chars, 20_000))

    case fetcher.fetch(source.url, fetch_opts) do
      {:ok, fetched} ->
        metadata =
          source.metadata
          |> Map.put("fetched", true)
          |> Map.put("fetched_url", fetched.url)
          |> Map.put("content_type", fetched.content_type)
          |> Map.put("fetched_bytes", fetched.bytes)

        %{source | snippet: String.slice(fetched.text, 0, 20_000), metadata: metadata}

      {:error, reason} ->
        put_fetch_error(source, reason)
    end
  end

  defp put_fetch_error(source, reason) do
    %{source | metadata: Map.put(source.metadata, "fetch_error", inspect(reason, limit: 20))}
  end

  defp synthesize(llm_module, run, sources, config, opts) do
    session = Sessions.get_session(run.session_id)

    {messages, system_prompt} =
      Report.synthesis_request(research_objective(run), sources, config.depth)

    llm_opts =
      opts
      |> Keyword.take([:cancelled?, :max_tokens, :receive_timeout])
      |> Keyword.put_new(:temperature, 0.1)
      |> Keyword.put(:allowed_tools, [])

    with {:ok, response} <-
           llm_module.chat(messages, system_prompt, session, fn _ -> :ok end, llm_opts),
         :ok <- persist_usage(run, response, opts),
         {:ok, text} <- Report.extract_text(response),
         {:ok, report} <- Report.ensure_citations(text, sources) do
      {:ok, report}
    end
  end

  defp persist_usage(run, response, opts) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    if is_map(usage) do
      authority = Keyword.get(opts, :run_authority, [])

      result =
        with owner when is_binary(owner) <- authority[:run_lease_owner],
             attempt when is_integer(attempt) <- authority[:run_attempt],
             generation when is_integer(generation) <- authority[:run_lease_generation] do
          terminal_lease_ms =
            case authority[:run_terminal_lease_ms] do
              lease_ms when is_integer(lease_ms) and lease_ms > 0 -> min(lease_ms, 300_000)
              _invalid -> 30_000
            end

          Runs.record_usage(run, usage, "research.synthesis",
            lease_owner: owner,
            run_attempt: attempt,
            lease_generation: generation,
            terminal_lease_ms: terminal_lease_ms
          )
        else
          _invalid_authority ->
            Runs.record_usage(run, usage, "research.synthesis")
        end

      case result do
        {:ok, _run} -> :ok
        {:error, {:token_budget_exhausted, _run}} -> {:error, :token_budget_exhausted}
        {:error, {:cost_budget_exhausted, _run}} -> {:error, :cost_budget_exhausted}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp create_step(run, attrs, opts) do
    case run_worker_authority(opts) do
      {:ok, authority} -> Runs.create_step_worker(run, attrs, authority)
      :none -> Runs.create_step(run, attrs)
    end
  end

  defp transition_step(step, status, attrs, opts) do
    case run_worker_authority(opts) do
      {:ok, authority} -> Runs.transition_step_worker(step, status, attrs, authority)
      :none -> Runs.transition_step(step, status, attrs)
    end
  end

  defp run_worker_authority(opts) do
    authority = Keyword.get(opts, :run_authority, [])

    with owner when is_binary(owner) <- authority[:run_lease_owner],
         attempt when is_integer(attempt) <- authority[:run_attempt],
         generation when is_integer(generation) <- authority[:run_lease_generation] do
      {:ok,
       [
         lease_owner: owner,
         run_attempt: attempt,
         lease_generation: generation
       ]}
    else
      _invalid_authority -> :none
    end
  end

  defp assert_run_authority(run, opts) do
    case run_worker_authority(opts) do
      {:ok, authority} ->
        case Runs.assert_run_worker(run, authority) do
          {:ok, _current} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :none ->
        case Runs.get_run(run.id) do
          %Run{lease_owner: nil} -> :ok
          %Run{} -> {:error, :worker_authority_required}
          nil -> {:error, :not_found}
        end
    end
  end

  defp prepare_result(run, opts) do
    case run_worker_authority(opts) do
      {:ok, authority} -> Results.prepare_run_worker(run, authority)
      :none -> Results.prepare_run(run)
    end
  end

  defp stage(run, name, title, position, opts) do
    key = stage_key(run, name)

    case Enum.find(Runs.list_steps(run), &(&1.key == key)) do
      nil ->
        step_attrs = %{
          key: key,
          kind: "research_#{name}",
          title: title,
          position: position,
          status: "pending",
          params: %{"run_attempt" => run.attempt, "stage" => name}
        }

        case create_step(run, step_attrs, opts) do
          {:error, _reason} ->
            case Enum.find(Runs.list_steps(run), &(&1.key == key)) do
              nil -> {:error, {:research_stage_unavailable, key}}
              step -> {:ok, step}
            end

          result ->
            result
        end

      step ->
        {:ok, step}
    end
  end

  defp begin_stage(%RunStep{status: "running"}, _opts), do: :ok

  defp begin_stage(%RunStep{status: status} = step, opts)
       when status in ~w(pending ready paused waiting_approval blocked interrupted) do
    case transition_step(step, "running", %{}, opts) do
      {:ok, _step} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp begin_stage(%RunStep{status: "completed"}, _opts), do: :ok

  defp begin_stage(%RunStep{status: status}, _opts),
    do: {:error, {:research_stage_terminal, status}}

  defp finish_stage(%RunStep{status: "completed"} = step, _sources, _result, _opts),
    do: {:ok, step}

  defp finish_stage(step, sources, result, opts) do
    transition_step(
      step,
      "completed",
      %{
        result: %{
          "source_count" => length(sources),
          "providers" => result.providers,
          "provider_errors" => safe_term(result.errors)
        }
      },
      opts
    )
  end

  defp finish_plan(%RunStep{status: "completed"} = step, _run, _config, _opts),
    do: {:ok, step}

  defp finish_plan(step, run, config, opts) do
    transition_step(
      step,
      "completed",
      %{
        result: %{
          "query" => run.objective,
          "queries" => config.queries,
          "depth" => config.depth,
          "max_sources" => config.max_sources,
          "providers" => safe_term(config.providers)
        }
      },
      opts
    )
  end

  defp finish_synthesis(%RunStep{status: "completed"} = step, _markdown, _sources, _opts),
    do: {:ok, step}

  defp finish_synthesis(step, markdown, sources, opts) do
    transition_step(
      step,
      "completed",
      %{
        result: %{
          "source_count" => length(sources),
          "report_bytes" => byte_size(markdown)
        }
      },
      opts
    )
  end

  defp persist_evidence(run, step, sources, result, opts) do
    content =
      Jason.encode!(%{
        "objective" => run.objective,
        "sources" => sources,
        "providers" => result.providers,
        "provider_errors" => safe_term(result.errors)
      })

    persist_artifact(
      run,
      step,
      "research_evidence",
      "Research evidence",
      "evidence.json",
      content,
      "application/json",
      %{"source_count" => length(sources), "sources" => sources, "content" => content},
      opts
    )
  end

  defp persist_report(run, step, markdown, sources, config, nil, opts) do
    persist_markdown_artifact(run, step, markdown, sources, config, nil, opts)
  end

  defp persist_report(run, step, markdown, sources, config, durable_result, opts) do
    result_opts =
      [
        source_count: length(sources),
        metadata: %{
          "providers" => sources |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.sort()
        }
      ]
      |> maybe_put(:root, Keyword.get(opts, :research_root))

    commit =
      case run_worker_authority(opts) do
        {:ok, authority} ->
          Results.commit_worker(durable_result, markdown, result_opts, authority)

        :none ->
          Results.commit(durable_result, markdown, result_opts)
      end

    with {:ok, ready} <- commit,
         {:ok, markdown_artifact} <-
           persist_markdown_artifact(run, step, markdown, sources, config, ready, opts),
         {:ok, html} <- Results.read_html(ready, result_opts),
         {:ok, _html_artifact} <-
           persist_artifact(
             run,
             step,
             "research_report_html",
             "Research report · HTML",
             "result-#{ready.id}.html",
             html,
             "text/html",
             %{
               "research_result_id" => ready.id,
               "source_count" => ready.source_count,
               "sha256" => ready.html_sha256,
               "open_path" => "/research/#{ready.id}/report",
               "download_path" => "/research/#{ready.id}/report/download"
             },
             opts
           ) do
      {:ok, markdown_artifact}
    end
  end

  defp persist_markdown_artifact(run, step, markdown, sources, config, durable_result, opts) do
    filename = if durable_result, do: "result-#{durable_result.id}.md", else: "report.md"

    metadata = %{
      "source_count" => length(sources),
      "sources" => sources,
      "depth" => config.depth,
      "content" => markdown
    }

    metadata =
      if durable_result do
        metadata
        |> Map.put("research_result_id", durable_result.id)
        |> Map.put("open_path", "/research/#{durable_result.id}/report")
        |> Map.put("download_path", "/research/#{durable_result.id}/result/download")
      else
        metadata
      end

    persist_artifact(
      run,
      step,
      "research_report",
      "Research report",
      filename,
      markdown,
      "text/markdown",
      metadata,
      opts
    )
  end

  defp persist_artifact(run, step, kind, name, filename, content, media_type, metadata, opts) do
    uri = "research://runs/#{run.id}/attempts/#{run.attempt}/#{filename}"

    case Enum.find(Runs.list_artifacts(run), &(&1.uri == uri)) do
      nil ->
        artifact_attrs = %{
          run_step_id: step.id,
          kind: kind,
          name: name,
          uri: uri,
          media_type: media_type,
          byte_size: byte_size(content),
          checksum: "sha256:" <> sha256(content),
          metadata: metadata
        }

        case run_worker_authority(opts) do
          {:ok, authority} -> Runs.create_artifact_worker(run, artifact_attrs, authority)
          :none -> Runs.create_artifact(run, artifact_attrs)
        end

      artifact ->
        {:ok, artifact}
    end
  end

  defp announce(run, progress_fun, percent, message, opts) do
    _ = progress_fun.(percent, message)

    payload = %{"percent" => percent, "message" => message}

    result =
      case run_worker_authority(opts) do
        {:ok, authority} ->
          Runs.append_event_worker(
            run,
            "research.progress",
            payload,
            "research.runner",
            authority
          )

        :none ->
          Runs.append_event(run, "research.progress", payload, "research.runner")
      end

    case result do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_failure(run, reason, opts) do
    if assert_run_authority(run, opts) == :ok do
      do_record_failure(run, reason, opts)
    else
      :ok
    end
  end

  defp do_record_failure(run, reason, opts) do
    latest_active =
      run
      |> Runs.list_steps()
      |> Enum.reverse()
      |> Enum.find(&(String.starts_with?(&1.key, "research.") and &1.status == "running"))

    if latest_active do
      _ =
        transition_step(
          latest_active,
          "failed",
          %{error_message: format_reason(reason)},
          opts
        )
    end

    run
    |> Runs.list_steps()
    |> Enum.filter(
      &(String.starts_with?(&1.key, "research.") and
          &1.status in ~w(pending ready paused waiting_approval blocked interrupted))
    )
    |> Enum.each(fn step ->
      terminal_status =
        if step.status in ["paused", "waiting_approval"], do: "cancelled", else: "skipped"

      _ =
        transition_step(
          step,
          terminal_status,
          %{error_message: "Upstream research stage failed"},
          opts
        )
    end)

    payload = %{"reason" => format_reason(reason)}

    _ =
      case run_worker_authority(opts) do
        {:ok, authority} ->
          Runs.append_event_worker(run, "research.failed", payload, "research.runner", authority)

        :none ->
          Runs.append_event(run, "research.failed", payload, "research.runner")
      end

    :ok
  rescue
    _ -> :ok
  end

  defp terminalize_result(%Run{kind: "deep_research"} = run, reason, opts) do
    if assert_run_authority(run, opts) == :ok do
      case Results.get_by_run(run) do
        %{status: status} = result when status in ["queued", "running"] ->
          action = if reason == :cancelled, do: :cancelled, else: :failed

          case {action, run_worker_authority(opts)} do
            {:cancelled, {:ok, worker_authority}} ->
              Results.mark_cancelled_worker(result, worker_authority)

            {:failed, {:ok, worker_authority}} ->
              Results.mark_failed_worker(result, failure_code(reason), worker_authority)

            {:cancelled, :none} ->
              Results.mark_cancelled(result)

            {:failed, :none} ->
              Results.mark_failed(result, failure_code(reason))
          end

        _result ->
          :ok
      end
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp terminalize_result(_run, _reason, _opts), do: :ok

  defp failure_code(reason) do
    reason
    |> safe_term()
    |> inspect(limit: 10, printable_limit: 200)
    |> String.replace(~r/[^A-Za-z0-9_.:-]/, "_")
    |> String.slice(0, 160)
    |> case do
      "" -> "research_failed"
      code -> code
    end
  end

  defp not_cancelled(opts) do
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)
    if cancelled?.(), do: {:error, :cancelled}, else: :ok
  end

  defp control_checkpoint(run, opts, acknowledge_steer? \\ true) do
    with :ok <- not_cancelled(opts),
         :ok <- assert_run_authority(run, opts) do
      current = Runs.get_run(run.id)
      acknowledge_research_controls(run, current, acknowledge_steer?)
      sync_research_step_status(run, current, opts)

      case current do
        %Run{status: "paused"} ->
          receive do
          after
            200 -> control_checkpoint(run, opts, acknowledge_steer?)
          end

        %Run{status: status} when status in ["cancelled", "failed", "interrupted"] ->
          {:error, :cancelled}

        _ ->
          :ok
      end
    end
  end

  defp acknowledge_research_controls(run, current, acknowledge_steer?) do
    controls = Runs.list_controls(run)

    controls
    |> Enum.filter(&(&1.status == "claimed"))
    |> Enum.each(fn control ->
      resolution =
        control_resolution(control, current && current.status, controls, acknowledge_steer?)

      if resolution do
        _ =
          Runs.resolve_control(
            control,
            resolution,
            %{
              "action" => control.kind,
              "observed_run_status" => current.status,
              "acknowledged_by" => "research_runner"
            },
            run_id: run.id,
            worker_id: control.worker_id,
            kind: control.kind
          )
      end
    end)
  end

  defp control_resolution(%{kind: "pause"}, "paused", _controls, _acknowledge_steer?),
    do: "applied"

  defp control_resolution(%{kind: "pause"} = control, "running", controls, _acknowledge_steer?) do
    if later_control?(controls, control, "resume"), do: "superseded"
  end

  defp control_resolution(%{kind: "resume"}, "running", _controls, _acknowledge_steer?),
    do: "applied"

  defp control_resolution(%{kind: "resume"} = control, "paused", controls, _acknowledge_steer?) do
    if later_control?(controls, control, "pause"), do: "superseded"
  end

  defp control_resolution(%{kind: "steer"}, status, _controls, true)
       when status in ["running", "paused"],
       do: "applied"

  defp control_resolution(_control, _status, _controls, _acknowledge_steer?), do: nil

  defp later_control?(controls, current, expected_kind) do
    Enum.any?(controls, fn control ->
      control.sequence > current.sequence and control.kind == expected_kind and
        control.status in ["claimed", "applied"]
    end)
  end

  defp sync_research_step_status(run, %Run{status: "paused"}, opts) do
    run
    |> Runs.list_steps()
    |> Enum.find(&(String.starts_with?(&1.key, "research.") and &1.status == "running"))
    |> case do
      nil -> :ok
      step -> transition_step(step, "paused", %{}, opts)
    end
  end

  defp sync_research_step_status(run, %Run{status: "running"}, opts) do
    run
    |> Runs.list_steps()
    |> Enum.find(&(String.starts_with?(&1.key, "research.") and &1.status == "paused"))
    |> case do
      nil -> :ok
      step -> transition_step(step, "running", %{}, opts)
    end
  end

  defp sync_research_step_status(_run, _current, _opts), do: :ok

  defp research_objective(run) do
    guidance =
      run
      |> Runs.list_controls(kind: "steer")
      |> Enum.filter(&(&1.status == "applied"))
      |> Enum.map(&value(&1.payload, :guidance))
      |> Enum.filter(&present?/1)
      |> Enum.take(-20)

    case guidance do
      [] ->
        run.objective

      directives ->
        run.objective <> "\n\nOperator guidance:\n" <> Enum.map_join(directives, "\n", &"- #{&1}")
    end
  end

  defp stage_key(%Run{attempt: attempt}, name) when is_integer(attempt) and attempt > 1,
    do: "research.#{name}.#{attempt}"

  defp stage_key(_run, name), do: "research.#{name}"

  defp provider_label(nil), do: "configured providers"
  defp provider_label([]), do: "configured providers"

  defp provider_label(providers) when is_map(providers),
    do: providers |> Map.keys() |> provider_label()

  defp provider_label(providers), do: Enum.map_join(providers, ", ", &stringify/1)

  defp normalize_providers(providers) when is_list(providers), do: providers
  defp normalize_providers(provider) when is_binary(provider) or is_atom(provider), do: [provider]
  defp normalize_providers(providers) when is_map(providers), do: providers
  defp normalize_providers(nil), do: nil
  defp normalize_providers(_providers), do: []

  defp normalize_depth(depth) when depth in [:quick, :standard, :deep], do: Atom.to_string(depth)
  defp normalize_depth(depth) when depth in ["quick", "standard", "deep"], do: depth
  defp normalize_depth(_depth), do: @default_depth

  defp research_queries(objective, "quick"), do: [objective]

  defp research_queries(objective, "standard") do
    [
      objective,
      "#{objective} primary sources official documentation",
      "#{objective} limitations tradeoffs"
    ]
  end

  defp research_queries(objective, "deep") do
    [
      objective,
      "#{objective} primary sources standards official documentation",
      "#{objective} recent developments empirical evidence",
      "#{objective} limitations risks criticism",
      "#{objective} alternatives comparison case studies"
    ]
  end

  defp normalize_max_sources(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_max_sources(parsed)
      _ -> @default_max_sources
    end
  end

  defp normalize_max_sources(value) when is_integer(value), do: min(max(value, 1), @max_sources)
  defp normalize_max_sources(_value), do: @default_max_sources

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_map), do: %{}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_source_url?(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_source_url?(_value), do: false

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
  defp stringify_optional(nil), do: nil
  defp stringify_optional(value), do: stringify(value)

  defp json_scalar(value) when is_number(value) or is_binary(value) or is_boolean(value),
    do: value

  defp json_scalar(_value), do: nil
  defp json_map(value) when is_map(value), do: safe_term(value)
  defp json_map(_value), do: %{}

  defp safe_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {stringify(key), safe_term(nested)} end)
  end

  defp safe_term(value) when is_list(value), do: Enum.map(value, &safe_term/1)

  defp safe_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp safe_term(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_term(value), do: inspect(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_reason(reason) do
    reason
    |> inspect(limit: 50, printable_limit: 8_000)
    |> String.slice(0, 10_000)
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
