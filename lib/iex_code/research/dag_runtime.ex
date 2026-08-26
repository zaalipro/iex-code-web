defmodule IexCode.Research.DagRuntime do
  @moduledoc """
  Execution-only adapters for research DAG provider effects.

  Provider identifiers and non-secret limits come from the immutable step
  manifest. Credentials are looked up immediately before execution and remain
  inside the provider call closure. Every external effect crosses the DAG
  context's cancellation and checkpoint boundary, and every returned value is
  converted to a bounded, string-keyed JSON value.

  This module deliberately does not register handlers or settle attempts. The
  scheduler remains the only authority that can commit a handler result.
  """

  alias IexCode.Research.{Fetcher, GroundedSearch, Launch, Registry, Report, Result, Search}
  alias IexCode.Research.GroundedSearch.GroundedAnswer
  alias IexCode.Execution.Limits
  alias IexCode.Runs.DagPayload
  alias IexCode.Sessions
  alias IexCode.Settings

  @max_query_bytes 50_000
  @max_ranked_results 50
  @max_sources 40
  @max_result_bytes 240_000
  @max_answer_chars 100_000
  @max_source_text_chars 200_000
  @max_body_bytes 5_000_000
  @max_timeout_ms 60_000
  @max_effect_timeout_ms 150_000
  @max_string_bytes 20_000

  @type context :: IexCode.Runs.DagStepHandler.context()
  @type runtime_result :: {:ok, map()} | {:error, term()}

  @doc "Executes one query against exactly one ranked-search provider."
  @spec ranked_search(map(), context(), keyword()) :: runtime_result()
  def ranked_search(params, context, opts \\ [])

  def ranked_search(params, context, opts)
      when is_map(params) and is_map(context) and is_list(opts) do
    with :ok <- reject_secret_params(params),
         :ok <- cancellation_checkpoint(context),
         {:ok, provider} <- ranked_provider(value(params, "provider")),
         {:ok, query} <- query(value(params, "query")),
         {:ok, max_results} <- bounded_integer(value(params, "max_results"), 1, 50, 20),
         {:ok, settings} <- resolve_settings(opts),
         :ok <- validate_provider_snapshot(params, settings, context, opts),
         {:ok, provider_config} <- ranked_provider_config(settings, provider),
         {:ok, identity} <- call_identity(params),
         {:ok, estimate} <- ranked_estimate(params, identity),
         descriptor <- request_descriptor("ranked_search", provider, query, params, identity),
         callback <-
           effect_callback(
             fn ->
               invoke_search(
                 opts,
                 query,
                 ranked_options(provider, provider_config, max_results, opts)
               )
             end,
             fn raw -> ranked_response(raw, provider, query, max_results) end,
             estimate,
             secret_values(settings)
           ),
         {:ok, response, usage} <-
           trusted_effect(
             context,
             "research.ranked_search",
             descriptor,
             estimate,
             callback,
             opts
           ),
         response <- Map.put(response, "usage", public_usage(usage, true)),
         {:ok, response} <- validate_output(response) do
      {:ok, response}
    else
      {:error, reason} -> {:error, normalize_runtime_error(reason)}
    end
  end

  def ranked_search(_params, _context, _opts), do: {:error, :invalid_runtime_request}

  @doc "Executes one query against exactly one model-native grounded provider."
  @spec grounded_search(map(), context(), keyword()) :: runtime_result()
  def grounded_search(params, context, opts \\ [])

  def grounded_search(params, context, opts)
      when is_map(params) and is_map(context) and is_list(opts) do
    with :ok <- reject_secret_params(params),
         :ok <- cancellation_checkpoint(context),
         {:ok, provider} <- grounded_provider(value(params, "provider")),
         {:ok, query} <- query(value(params, "query")),
         {:ok, settings} <- resolve_settings(opts),
         :ok <- validate_provider_snapshot(params, settings, context, opts),
         {:ok, provider_config} <- grounded_provider_config(settings, provider),
         {:ok, provider_opts} <- grounded_options(params, provider_config, context, opts),
         {:ok, identity} <- call_identity(params),
         {:ok, estimate} <- grounded_estimate(params, identity),
         descriptor <- request_descriptor("grounded_search", provider, query, params, identity),
         callback <-
           effect_callback(
             fn -> invoke_grounded(opts, provider, query, provider_opts) end,
             fn raw -> grounded_response(raw, provider, query) end,
             estimate,
             secret_values(settings)
           ),
         {:ok, response, usage} <-
           trusted_effect(
             context,
             "research.grounded_search",
             descriptor,
             estimate,
             callback,
             opts
           ),
         response <- Map.put(response, "usage", public_usage(usage, true)),
         {:ok, response} <- validate_output(response) do
      {:ok, response}
    else
      {:error, reason} -> {:error, normalize_runtime_error(reason)}
    end
  end

  def grounded_search(_params, _context, _opts), do: {:error, :invalid_runtime_request}

  @doc "Fetches a bounded list of public evidence sources one effect at a time."
  @spec fetch_sources(map(), context(), keyword()) :: runtime_result()
  def fetch_sources(params, context, opts \\ [])

  def fetch_sources(params, context, opts)
      when is_map(params) and is_map(context) and is_list(opts) do
    with :ok <- reject_secret_params(params),
         :ok <- cancellation_checkpoint(context),
         {:ok, sources} <- sources(value(params, "sources")),
         {:ok, max_sources} <-
           bounded_integer(
             value(params, "max_sources"),
             1,
             @max_sources,
             min(length(sources), @max_sources)
           ),
         {:ok, max_requests} <-
           bounded_integer(value(params, "max_requests"), 1, @max_sources, max_sources),
         true <- max_requests >= min(length(sources), max_sources),
         {:ok, _max_cost} <-
           bounded_integer(value(params, "max_cost_cents"), 0, 100_000, 0),
         {:ok, max_parallel_fetches} <-
           bounded_integer(value(params, "max_parallel_fetches"), 1, 16, 6),
         {:ok, fetch_opts} <- fetch_options(params, opts),
         {:ok, fetched, fetch_usage} <-
           fetch_each(
             Enum.take(sources, max_sources),
             params,
             context,
             fetch_opts,
             max_parallel_fetches,
             opts
           ),
         result <- %{
           "sources" => fetched,
           "usage" => fetch_usage
         },
         {:ok, result} <- validate_output(result) do
      {:ok, result}
    else
      false -> {:error, :invalid_runtime_request}
      {:error, reason} -> {:error, normalize_runtime_error(reason)}
    end
  end

  def fetch_sources(_params, _context, _opts), do: {:error, :invalid_runtime_request}

  @doc "Synthesizes a bounded report draft without committing usage or artifacts."
  @spec synthesize_report(map(), context(), keyword()) :: runtime_result()
  def synthesize_report(params, context, opts \\ [])

  def synthesize_report(params, context, opts)
      when is_map(params) and is_map(context) and is_list(opts) do
    with :ok <- reject_secret_params(params),
         :ok <- cancellation_checkpoint(context),
         {:ok, objective} <- required_string(value(params, "objective"), @max_query_bytes),
         {:ok, depth} <- research_depth(value(params, "depth")),
         {:ok, max_input_tokens} <-
           bounded_integer(value(params, "max_input_tokens"), 256, 200_000, 64_000),
         {:ok, max_output_tokens} <-
           bounded_integer(value(params, "max_output_tokens"), 256, 100_000, 12_000),
         {:ok, attachment_context} <-
           synthesis_attachment_context(value(params, "attachment_context"), max_input_tokens),
         {:ok, evidence} <-
           synthesis_sources(
             value(params, "sources"),
             remaining_input_tokens(max_input_tokens, attachment_context)
           ),
         {:ok, settings} <- resolve_settings(opts),
         {:ok, session} <- resolve_session(context, opts),
         :ok <- validate_snapshot_against_session(params, settings, session, context),
         {:ok, synthesis_route} <- synthesis_route(settings, session),
         {messages, system_prompt} <-
           Report.synthesis_request(objective, evidence, depth, attachment_context),
         {:ok, estimate} <- synthesis_estimate(params),
         descriptor <- synthesis_descriptor(params, objective, evidence, attachment_context),
         callback <-
           effect_callback(
             fn ->
               invoke_llm(
                 opts,
                 messages,
                 system_prompt,
                 session,
                 fn _chunk -> :ok end,
                 allowed_tools: [],
                 cancelled?: Map.fetch!(context, :cancelled?),
                 max_tokens: max_output_tokens,
                 temperature: 0.1,
                 resolved_route: synthesis_route,
                 receive_timeout: timeout(value_from_opts(opts, :receive_timeout), 60_000)
               )
             end,
             &synthesis_response/1,
             estimate,
             secret_values(settings)
           ),
         {:ok, result, usage} <-
           trusted_effect(
             context,
             "research.report_synthesis",
             descriptor,
             estimate,
             callback,
             opts
           ),
         result <- Map.put(result, "usage", public_usage(usage, false)),
         {:ok, result} <- validate_output(result) do
      {:ok, result}
    else
      {:error, reason} -> {:error, normalize_runtime_error(reason)}
    end
  rescue
    KeyError -> {:error, :invalid_runtime_context}
  end

  def synthesize_report(_params, _context, _opts), do: {:error, :invalid_runtime_request}

  defp trusted_effect(context, operation, descriptor, estimate, callback, opts) do
    provider_effect = Map.get(context, :provider_effect)

    if is_function(provider_effect, 5) do
      effect_opts = [
        timeout_ms:
          effect_timeout(
            value_from_opts(opts, :effect_timeout),
            default_effect_timeout(operation)
          ),
        max_response_bytes: @max_result_bytes,
        progress: 40
      ]

      case provider_effect.(operation, descriptor, estimate, callback, effect_opts) do
        {:ok, %{replayed?: true, response: nil}} ->
          {:error, :provider_effect_replay_without_response}

        {:ok, %{response: response, usage: usage, replayed?: replayed?}}
        when is_map(response) and is_map(usage) and is_boolean(replayed?) ->
          {:ok, response, usage}

        {:ok, _invalid_receipt} ->
          {:error, :invalid_provider_effect_receipt}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        _other ->
          {:error, :invalid_provider_effect_result}
      end
    else
      {:error, :provider_effect_unavailable}
    end
  rescue
    _exception -> {:error, :provider_effect_failed}
  catch
    _kind, _reason -> {:error, :provider_effect_failed}
  end

  defp effect_callback(effect, normalizer, estimate, secrets) do
    fn ->
      case effect.() do
        {:ok, raw} ->
          with {:ok, response} <- normalizer.(raw),
               response <- redact_secrets(response, secrets),
               {:ok, response} <- validate_output(response) do
            {:ok, response, conservative_usage(value(raw, "usage"), estimate)}
          else
            _invalid -> :uncertain_provider_outcome
          end

        # Provider facades do not currently prove whether a request was sent or
        # report usage on errors. An invalid callback result intentionally tells
        # ProviderEffect to settle the full reservation as uncertain.
        {:error, _reason} ->
          :uncertain_provider_outcome

        _other ->
          :uncertain_provider_outcome
      end
    end
  end

  defp conservative_usage(reported, estimate) do
    reported = if is_map(reported), do: reported, else: %{}

    %{
      requests: estimate.requests,
      input_tokens: reported_counter(reported, "input_tokens", estimate.input_tokens),
      output_tokens: reported_counter(reported, "output_tokens", estimate.output_tokens),
      cost_cents: reported_counter(reported, "cost_cents", estimate.cost_cents)
    }
  end

  defp reported_counter(reported, key, fallback) do
    case value(reported, key) do
      number when is_integer(number) and number >= 0 -> number
      _missing_or_invalid -> fallback
    end
  end

  defp public_usage(usage, search?) do
    normalized = %{
      "request_count" => counter(usage, :requests),
      "input_tokens" => counter(usage, :input_tokens),
      "output_tokens" => counter(usage, :output_tokens),
      "cost_cents" => counter(usage, :cost_cents)
    }

    if search?, do: Map.put(normalized, "search_calls", 1), else: normalized
  end

  defp counter(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> 0
    end
  end

  defp allocated(total, count, index)
       when is_integer(total) and total >= 0 and is_integer(count) and count > 0 and
              is_integer(index) and index in 1..count//1 do
    base = div(total, count)
    if index <= rem(total, count), do: base + 1, else: base
  end

  defp allocated(_total, _count, _index), do: 0

  defp call_identity(params) do
    with {:ok, round} <- bounded_integer(value(params, "round"), 1, 6, 1),
         {:ok, index} <- bounded_integer(value(params, "call_index"), 1, 250, 1),
         {:ok, count} <- bounded_integer(value(params, "call_count"), 1, 250, 1),
         true <- index <= count do
      {:ok, %{round: round, index: index, count: count}}
    else
      _invalid -> {:error, :invalid_runtime_request}
    end
  end

  defp ranked_estimate(params, _identity) do
    with {:ok, cost} <- bounded_integer(value(params, "max_cost_cents"), 0, 100_000, 0) do
      {:ok, %{requests: 1, input_tokens: 0, output_tokens: 0, cost_cents: cost}}
    end
  end

  defp grounded_estimate(params, _identity) do
    with {:ok, input} <-
           bounded_integer(value(params, "max_input_tokens"), 0, 100_000, 0),
         {:ok, output} <-
           bounded_integer(value(params, "max_output_tokens"), 0, 100_000, 0),
         {:ok, cost} <- bounded_integer(value(params, "max_cost_cents"), 0, 100_000, 0) do
      {:ok, %{requests: 1, input_tokens: input, output_tokens: output, cost_cents: cost}}
    end
  end

  defp synthesis_estimate(params) do
    with {:ok, input} <-
           bounded_integer(value(params, "max_input_tokens"), 0, 200_000, 0),
         {:ok, output} <-
           bounded_integer(value(params, "max_output_tokens"), 0, 100_000, 0),
         {:ok, cost} <- bounded_integer(value(params, "max_cost_cents"), 0, 100_000, 0) do
      {:ok, %{requests: 1, input_tokens: input, output_tokens: output, cost_cents: cost}}
    end
  end

  defp request_descriptor(effect, provider, query, params, identity) do
    %{
      "version" => 1,
      "effect" => effect,
      "provider" => provider,
      "round" => identity.round,
      "call_index" => identity.index,
      "call_count" => identity.count,
      "query_sha256" => sha256(query),
      "provider_snapshot_ref" =>
        bounded_string(value(params, "provider_snapshot_ref"), 500) || "settings://current"
    }
  end

  defp synthesis_descriptor(params, objective, evidence, attachment_context) do
    %{
      "version" => 1,
      "effect" => "report_synthesis",
      "objective_sha256" => sha256(objective),
      "evidence_sha256" => sha256(Jason.encode!(evidence)),
      "attachment_context_sha256" => sha256(Jason.encode!(attachment_context)),
      "source_count" => length(evidence),
      "depth" => bounded_string(value(params, "depth"), 20),
      "provider_snapshot_ref" =>
        bounded_string(value(params, "provider_snapshot_ref"), 500) || "settings://current"
    }
  end

  defp synthesis_response(raw) do
    with {:ok, markdown} <- Report.extract_text(raw) do
      {:ok, %{"markdown" => String.slice(markdown, 0, @max_answer_chars)}}
    end
  end

  defp cancellation_checkpoint(context) do
    cancelled? = Map.get(context, :cancelled?)

    cond do
      not is_function(cancelled?, 0) -> {:error, :invalid_runtime_context}
      cancelled?.() -> {:error, :cancelled}
      true -> :ok
    end
  rescue
    _exception -> {:error, :invalid_runtime_context}
  catch
    _kind, _reason -> {:error, :invalid_runtime_context}
  end

  defp resolve_settings(opts) do
    resolver = Keyword.get(opts, :settings_resolver, &default_settings/0)

    if is_function(resolver, 0) do
      case resolver.() do
        {:ok, settings} when is_map(settings) -> {:ok, settings}
        settings when is_map(settings) -> {:ok, settings}
        _other -> {:error, :settings_unavailable}
      end
    else
      {:error, :settings_unavailable}
    end
  rescue
    _exception -> {:error, :settings_unavailable}
  catch
    _kind, _reason -> {:error, :settings_unavailable}
  end

  defp default_settings do
    settings = Settings.get_settings()

    {openai_key, openai_model} =
      if settings.default_model_provider == "openai",
        do: {settings.openai_api_key, settings.default_model},
        else: {"", ""}

    {anthropic_key, anthropic_model} =
      if settings.default_model_provider == "anthropic",
        do: {settings.anthropic_api_key, settings.default_model},
        else: {"", ""}

    %{
      "synthesis_providers" => %{
        "openai" => %{
          "api_key" => settings.openai_api_key,
          "base_url" => settings.openai_base_url
        },
        "anthropic" => %{
          "api_key" => settings.anthropic_api_key,
          "base_url" => settings.anthropic_base_url
        }
      },
      "search" => Settings.search_config(settings),
      "grounded_providers" => %{
        "openai_responses" => %{
          "api_key" => openai_key,
          "model" => openai_model
        },
        "anthropic_messages" => %{
          "api_key" => anthropic_key,
          "model" => anthropic_model
        },
        "gemini_interactions" => %{
          "api_key" => System.get_env("GEMINI_API_KEY") || "",
          "model" => System.get_env("GEMINI_GROUNDED_MODEL") || "gemini-2.5-flash"
        }
      }
    }
  end

  defp ranked_provider(provider) when is_binary(provider) do
    provider = String.trim(provider)

    case Registry.descriptor(provider) do
      {:ok, _descriptor} -> {:ok, provider}
      :error -> {:error, :unsupported_provider}
    end
  end

  defp ranked_provider(_provider), do: {:error, :unsupported_provider}

  defp grounded_provider(provider) when is_binary(provider) do
    provider = String.trim(provider)

    case GroundedSearch.descriptor(provider) do
      {:ok, %{status: :supported}} -> {:ok, provider}
      {:ok, _descriptor} -> {:error, :provider_unavailable}
      :error -> {:error, :unsupported_provider}
    end
  end

  defp grounded_provider(_provider), do: {:error, :unsupported_provider}

  defp ranked_provider_config(settings, provider) do
    config =
      settings
      |> value("search")
      |> then(&(&1 || settings))
      |> value("providers")
      |> then(&(&1 || %{}))
      |> provider_value(provider)

    if is_map(config) and enabled?(config) do
      {:ok, config}
    else
      {:error, :provider_unavailable}
    end
  end

  defp grounded_provider_config(settings, provider) do
    config =
      settings
      |> value("grounded_providers")
      |> then(&(&1 || %{}))
      |> provider_value(provider)

    with true <- is_map(config),
         {:ok, api_key} <- required_secret(value(config, "api_key")),
         {:ok, model} <- required_string(value(config, "model"), Limits.max_model_name_bytes()) do
      {:ok, %{api_key: api_key, model: model, raw: config}}
    else
      _other -> {:error, :provider_unavailable}
    end
  end

  defp synthesis_route(settings, session) do
    provider =
      IexCode.LLM.effective_provider(
        value(session, "model_provider"),
        value(session, "model_name")
      )

    config =
      settings
      |> value("synthesis_providers")
      |> then(&(&1 || %{}))
      |> provider_value(provider)

    with true <- provider in ["openai", "anthropic"],
         true <- is_map(config),
         {:ok, api_key} <- required_secret(value(config, "api_key")),
         {:ok, base_url} <- required_string(value(config, "base_url"), 2_048),
         {:ok, model} <-
           required_string(value(session, "model_name"), Limits.max_model_name_bytes()) do
      {:ok,
       %{
         "provider" => provider,
         "model" => model,
         "api_key" => api_key,
         "base_url" => base_url,
         "temperature" => 0.1
       }}
    else
      _reason -> {:error, :provider_unavailable}
    end
  end

  defp required_secret(value) when is_binary(value) and byte_size(value) in 1..4_096,
    do: {:ok, value}

  defp required_secret(_value), do: {:error, :provider_unavailable}

  defp required_string(value, max) when is_binary(value) and byte_size(value) in 1..max//1 do
    value = String.trim(value)
    if value == "", do: {:error, :invalid_runtime_request}, else: {:ok, value}
  end

  defp required_string(_value, _max), do: {:error, :invalid_runtime_request}

  defp enabled?(config), do: value(config, "enabled") == true

  defp provider_value(map, provider) when is_map(map) do
    Map.get(map, provider) ||
      Enum.find_value(map, fn
        {key, value} when is_atom(key) -> if Atom.to_string(key) == provider, do: value
        _entry -> nil
      end)
  end

  defp provider_value(_map, _provider), do: nil

  defp ranked_options(provider, config, max_results, opts) do
    [
      providers: [provider],
      config: %{provider => config},
      limit: max_results,
      max_concurrency: 1,
      timeout: timeout(value_from_opts(opts, :timeout), 15_000)
    ]
    |> maybe_put_option(:request, Keyword.get(opts, :request))
  end

  defp grounded_options(params, config, context, opts) do
    with {:ok, max_output_tokens} <-
           optional_bounded_integer(value(params, "max_output_tokens"), 1, 100_000),
         {:ok, max_search_calls} <-
           optional_bounded_integer(value(params, "max_search_calls"), 1, 20) do
      runtime_options =
        [
          api_key: config.api_key,
          model: config.model,
          cancelled?: Map.fetch!(context, :cancelled?),
          receive_timeout: timeout(value_from_opts(opts, :receive_timeout), 30_000)
        ]
        |> maybe_put_option(:max_output_tokens, max_output_tokens)
        |> maybe_put_option(:max_tokens, max_output_tokens)
        |> maybe_put_option(:max_uses, max_search_calls)
        |> maybe_put_option(:request, Keyword.get(opts, :request))

      configured =
        ~w(allowed_domains search_context_size external_web_access tool_version max_continuations)a
        |> Enum.reduce(runtime_options, fn key, acc ->
          maybe_put_option(acc, key, value(config.raw, Atom.to_string(key)))
        end)

      {:ok, configured}
    end
  rescue
    KeyError -> {:error, :invalid_runtime_context}
  end

  defp fetch_options(params, opts) do
    with {:ok, max_body_bytes} <-
           bounded_integer(value(params, "max_body_bytes"), 1_000, @max_body_bytes, 750_000),
         {:ok, max_text_chars} <-
           bounded_integer(
             value(params, "max_text_chars"),
             1_000,
             @max_source_text_chars,
             20_000
           ) do
      {:ok,
       [
         timeout: timeout(value_from_opts(opts, :timeout), 10_000),
         max_body_bytes: max_body_bytes,
         max_text_chars: max_text_chars
       ]
       |> maybe_put_option(:request, Keyword.get(opts, :request))
       |> maybe_put_option(:resolver, Keyword.get(opts, :resolver))}
    end
  end

  defp fetch_each(sources, params, context, fetch_opts, max_parallel_fetches, opts) do
    count = length(sources)

    sources
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {source, index} ->
        fetch_one(source, index, count, params, context, fetch_opts, opts)
      end,
      max_concurrency: min(max_parallel_fetches, max(count, 1)),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, [], %{"request_count" => 0, "cost_cents" => 0}}, fn
      {:ok, {:ok, fetched_source, settled_usage}}, {:ok, fetched, usage} ->
        {:cont, {:ok, [fetched_source | fetched], add_fetch_usage(usage, settled_usage)}}

      {:ok, {:recoverable_error, failed_source, estimated_usage}}, {:ok, fetched, usage} ->
        {:cont, {:ok, [failed_source | fetched], add_fetch_usage(usage, estimated_usage)}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, _reason}, _acc ->
        {:halt, {:error, :provider_effect_failed}}
    end)
    |> case do
      {:ok, fetched, usage} ->
        fetched = Enum.reverse(fetched)

        if Enum.any?(fetched, &(not Map.has_key?(&1, "fetch_error"))),
          do: {:ok, fetched, usage},
          else: {:error, :all_source_fetches_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_one(source, index, count, params, context, fetch_opts, opts) do
    cost = allocated(value(params, "max_cost_cents") || 0, count, index)
    estimate = %{requests: 1, input_tokens: 0, output_tokens: 0, cost_cents: cost}

    descriptor = %{
      "version" => 1,
      "effect" => "source_fetch",
      "round" => value(params, "round") || 1,
      "call_index" => index,
      "call_count" => count,
      "url_sha256" => sha256(source["url"]),
      "max_body_bytes" => Keyword.fetch!(fetch_opts, :max_body_bytes),
      "max_text_chars" => Keyword.fetch!(fetch_opts, :max_text_chars)
    }

    callback =
      effect_callback(
        fn -> invoke_fetcher(opts, source["url"], fetch_opts) end,
        fn response ->
          fetched_source(source, response, Keyword.fetch!(fetch_opts, :max_text_chars))
        end,
        estimate,
        []
      )

    case trusted_effect(
           context,
           "research.source_fetch.#{index}",
           descriptor,
           estimate,
           callback,
           opts
         ) do
      {:ok, normalized, settled_usage} ->
        {:ok, normalized, settled_usage}

      {:error, reason}
      when reason in [
             :cancelled,
             :provider_effect_unavailable,
             :provider_effect_replay_without_response,
             :invalid_provider_effect_receipt,
             :invalid_provider_effect_result,
             :provider_effect_failed,
             :external_effect_uncertain,
             :external_effect_unsettled,
             :external_effect_ambiguous,
             :external_effect_release_failed
           ] ->
        {:error, reason}

      {:error, _reason} ->
        failed = Map.put(source, "fetch_error", "source_fetch_failed")
        {:recoverable_error, failed, estimate}
    end
  end

  defp add_fetch_usage(total, settled) do
    total
    |> Map.update!("request_count", &(&1 + counter(settled, :requests)))
    |> Map.update!("cost_cents", &(&1 + counter(settled, :cost_cents)))
  end

  defp ranked_response(%{results: results} = response, provider, query, max_results)
       when is_list(results) do
    {:ok,
     %{
       "provider" => provider,
       "query" => query,
       "results" =>
         results |> Enum.take(min(max_results, @max_ranked_results)) |> Enum.map(&ranked_result/1),
       "errors" => safe_provider_errors(Map.get(response, :errors, %{})),
       "usage" => %{"request_count" => 1, "search_calls" => 1}
     }}
  end

  defp ranked_response(%{"results" => results} = response, provider, query, max_results)
       when is_list(results) do
    ranked_response(
      %{results: results, errors: Map.get(response, "errors", %{})},
      provider,
      query,
      max_results
    )
  end

  defp ranked_response(_response, _provider, _query, _max_results),
    do: {:error, :invalid_provider_response}

  defp ranked_result(%Result{} = result), do: ranked_result(Map.from_struct(result))

  defp ranked_result(result) when is_map(result) do
    %{
      "provider" => bounded_string(value(result, "provider"), 80),
      "title" => bounded_string(value(result, "title"), 300),
      "url" => bounded_string(value(result, "url"), 2_000),
      "snippet" => bounded_string(value(result, "snippet"), 1_500),
      "published_at" => bounded_string(value(result, "published_at"), 200),
      "score" => safe_number(value(result, "score")),
      "metadata" => %{}
    }
  end

  defp ranked_result(_result), do: %{"invalid" => true}

  defp grounded_response(%GroundedAnswer{} = answer, provider, query) do
    grounded_response(Map.from_struct(answer), provider, query)
  end

  defp grounded_response(answer, provider, query) when is_map(answer) do
    with answer_text when is_binary(answer_text) <- value(answer, "answer"),
         citations when is_list(citations) <- value(answer, "citations"),
         calls when is_list(calls) <- value(answer, "search_calls") do
      {:ok,
       %{
         "provider" => provider,
         "query" => query,
         "answer" => String.slice(answer_text, 0, @max_answer_chars),
         "citations" => citations |> Enum.take(32) |> Enum.map(&citation/1),
         "search_calls" => calls |> Enum.take(16) |> Enum.map(&search_call/1),
         "usage" => usage(value(answer, "usage"))
       }}
    else
      _other -> {:error, :invalid_provider_response}
    end
  end

  defp grounded_response(_answer, _provider, _query),
    do: {:error, :invalid_provider_response}

  defp citation(citation) when is_map(citation) do
    %{
      "url" => bounded_string(value(citation, "url"), 2_000),
      "title" => bounded_string(value(citation, "title"), 300),
      "start_index" => non_negative_integer(value(citation, "start_index")),
      "end_index" => non_negative_integer(value(citation, "end_index")),
      "cited_text" => bounded_string(value(citation, "cited_text"), 1_000)
    }
  end

  defp citation(_citation), do: %{"invalid" => true}

  defp search_call(call) when is_map(call) do
    %{
      "id" => bounded_string(value(call, "id"), 500),
      "queries" =>
        value(call, "queries")
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&bounded_string(&1, 500))
        |> Enum.take(4),
      "status" => bounded_string(value(call, "status"), 100)
    }
  end

  defp search_call(_call), do: %{"invalid" => true}

  defp fetched_source(source, response, max_text_chars) when is_map(response) do
    text = value(response, "text")

    if is_binary(text) do
      {:ok,
       source
       |> Map.put("snippet", String.slice(text, 0, max_text_chars))
       |> Map.put("fetched", true)
       |> Map.put(
         "fetched_url",
         bounded_string(value(response, "url") || source["url"], 4_096)
       )
       |> Map.put("content_type", bounded_string(value(response, "content_type"), 200))
       |> Map.put("fetched_bytes", non_negative_integer(value(response, "bytes")))
       |> Map.put("content_hash", sha256(text))}
    else
      {:error, :invalid_provider_response}
    end
  end

  defp fetched_source(_source, _response, _max_text_chars),
    do: {:error, :invalid_provider_response}

  defp sources(sources) when is_list(sources) and length(sources) <= @max_sources do
    normalized = Enum.map(sources, &source/1)

    if Enum.all?(normalized, &is_map/1),
      do: {:ok, normalized},
      else: {:error, :invalid_runtime_request}
  end

  defp sources(_sources), do: {:error, :invalid_runtime_request}

  defp source(source) when is_map(source) do
    case value(source, "url") do
      url when is_binary(url) and byte_size(url) in 1..4_096 ->
        ~w(id url title provider plane query snippet)
        |> Enum.reduce(%{}, fn field, acc ->
          case value(source, field) do
            nil -> acc
            item -> Map.put(acc, field, bounded_string(item, source_field_limit(field)))
          end
        end)
        |> Map.put("url", url)
        |> maybe_put_provenance(value(source, "provenance"))

      _other ->
        nil
    end
  end

  defp source(_source), do: nil

  defp maybe_put_provenance(source, provenance) when is_list(provenance) do
    Map.put(
      source,
      "provenance",
      provenance
      |> Enum.filter(&is_map/1)
      |> Enum.take(32)
      |> Enum.map(fn entry ->
        ~w(provider url title query plane)
        |> Enum.reduce(%{}, fn field, acc ->
          case value(entry, field) do
            item when is_binary(item) ->
              Map.put(acc, field, bounded_string(item, source_field_limit(field)))

            _other ->
              acc
          end
        end)
      end)
    )
  end

  defp maybe_put_provenance(source, _provenance), do: source

  defp source_field_limit("id"), do: 500
  defp source_field_limit("url"), do: 4_096
  defp source_field_limit("title"), do: 1_000
  defp source_field_limit("provider"), do: 80
  defp source_field_limit("plane"), do: 80
  defp source_field_limit("query"), do: @max_query_bytes
  defp source_field_limit("snippet"), do: @max_string_bytes

  defp synthesis_sources(sources, max_input_tokens) do
    with {:ok, normalized} <- sources(sources) do
      character_budget = min(max_input_tokens * 4, 800_000)

      {bounded, _remaining} =
        Enum.map_reduce(normalized, character_budget, fn source, remaining ->
          snippet = Map.get(source, "snippet", "")
          allowed = min(String.length(snippet), max(remaining, 0))
          {%{source | "snippet" => String.slice(snippet, 0, allowed)}, remaining - allowed}
        end)

      evidence =
        bounded
        |> Enum.reject(&(Map.get(&1, "snippet", "") == ""))
        |> Enum.map(fn source ->
          %{
            title: Map.get(source, "title") || "Untitled source",
            url: Map.fetch!(source, "url"),
            provider: Map.get(source, "provider") || "unknown",
            snippet: Map.fetch!(source, "snippet")
          }
        end)

      if evidence == [],
        do: {:error, :invalid_runtime_request},
        else: {:ok, evidence}
    end
  end

  defp synthesis_attachment_context(nil, _max_input_tokens), do: {:ok, []}

  defp synthesis_attachment_context(attachments, max_input_tokens)
       when is_list(attachments) and length(attachments) <= 12 do
    with {:ok, attachments} <- DagPayload.validate(attachments, max_bytes: 90_000),
         {:ok, encoded} <- DagPayload.canonical_json(attachments),
         true <- byte_size(encoded) <= max_input_tokens * 4 do
      {:ok, attachments}
    else
      false -> {:error, :invalid_runtime_request}
      {:error, _reason} -> {:error, :invalid_runtime_request}
    end
  end

  defp synthesis_attachment_context(_attachments, _max_input_tokens),
    do: {:error, :invalid_runtime_request}

  defp remaining_input_tokens(max_input_tokens, attachments) do
    {:ok, encoded} = DagPayload.canonical_json(attachments)
    max(div(max_input_tokens * 4 - byte_size(encoded), 4), 0)
  end

  defp research_depth(depth) when depth in ["quick", "standard", "deep"], do: {:ok, depth}
  defp research_depth("low"), do: {:ok, "quick"}
  defp research_depth("medium"), do: {:ok, "standard"}
  defp research_depth(depth) when depth in ["high", "ultra"], do: {:ok, "deep"}
  defp research_depth(_depth), do: {:error, :invalid_runtime_request}

  defp resolve_session(context, opts) do
    session_id = context |> Map.get(:run, %{}) |> Map.get(:session_id)
    resolver = Keyword.get(opts, :session_resolver, &Sessions.get_session/1)

    cond do
      not is_binary(session_id) ->
        {:error, :invalid_runtime_context}

      not is_function(resolver, 1) ->
        {:error, :invalid_runtime_context}

      true ->
        case resolver.(session_id) do
          nil -> {:error, :session_unavailable}
          session -> {:ok, session}
        end
    end
  rescue
    _exception -> {:error, :session_unavailable}
  catch
    _kind, _reason -> {:error, :session_unavailable}
  end

  defp validate_provider_snapshot(params, settings, context, opts) do
    reference = value(params, "provider_snapshot_ref")

    if strict_snapshot_ref?(reference) do
      with {:ok, session} <- resolve_session(context, opts) do
        validate_snapshot_against_session(params, settings, session, context)
      end
    else
      Launch.validate_snapshot_ref(reference, settings, nil)
    end
  end

  defp validate_snapshot_against_session(params, settings, session, context) do
    {ranked, grounded} = snapshot_provider_scope(context)

    Launch.validate_snapshot_ref(
      value(params, "provider_snapshot_ref"),
      settings,
      session,
      ranked,
      grounded
    )
  end

  defp strict_snapshot_ref?("settings://research-routing/v2/" <> _digest), do: true
  defp strict_snapshot_ref?(_reference), do: false

  defp snapshot_provider_scope(context) do
    research =
      context
      |> Map.get(:run, %{})
      |> Map.get(:metadata, %{})
      |> value("research")

    if is_map(research) do
      {value(research, "ranked_providers"), value(research, "grounded_providers")}
    else
      {nil, nil}
    end
  end

  defp query(value), do: required_string(value, @max_query_bytes)

  defp safe_provider_errors(errors) when is_map(errors) do
    errors
    |> Enum.take(32)
    |> Map.new(fn {provider, reason} ->
      {bounded_string(to_string(provider), 80), error_code(reason)}
    end)
  end

  defp safe_provider_errors(_errors), do: %{}

  defp usage(usage) when is_map(usage) do
    ~w(input_tokens output_tokens cost_cents request_count latency_ms search_calls)
    |> Enum.reduce(%{}, fn field, acc ->
      case value(usage, field) do
        number when is_integer(number) and number >= 0 -> Map.put(acc, field, number)
        _other -> acc
      end
    end)
  end

  defp usage(_usage), do: %{}

  defp reject_secret_params(params) do
    if contains_sensitive_key?(params),
      do: {:error, :secret_in_runtime_params},
      else: :ok
  end

  defp contains_sensitive_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      secret_key?(safe_key(key) |> String.downcase()) or contains_sensitive_key?(value)
    end)
  end

  defp contains_sensitive_key?(list) when is_list(list),
    do: Enum.any?(list, &contains_sensitive_key?/1)

  defp contains_sensitive_key?(_value), do: false

  defp secret_values(settings) do
    collect_secrets(settings, nil, [])
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp collect_secrets(map, _parent_key, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, current ->
      key = safe_key(key) |> String.downcase()

      cond do
        secret_key?(key) and is_binary(value) -> [value | current]
        is_map(value) or is_list(value) -> collect_secrets(value, key, current)
        true -> current
      end
    end)
  end

  defp collect_secrets(list, parent_key, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_secrets(&1, parent_key, &2))
  end

  defp collect_secrets(_value, _parent_key, acc), do: acc

  defp secret_key?(key) do
    String.contains?(key, ["api_key", "secret", "password", "authorization"]) or
      key == "token" or String.ends_with?(key, "_token")
  end

  defp redact_secrets(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp redact_secrets(value, secrets) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, redact_secrets(item, secrets)} end)
  end

  defp redact_secrets(value, secrets) when is_list(value),
    do: Enum.map(value, &redact_secrets(&1, secrets))

  defp redact_secrets(value, _secrets), do: value

  defp safe_key(key) when is_binary(key), do: bounded_string(key, 200)
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(_key), do: "unknown"

  defp validate_output(output),
    do: DagPayload.validate(output, max_bytes: @max_result_bytes)

  defp normalize_runtime_error(:cancelled), do: :cancelled
  defp normalize_runtime_error(:checkpoint_failed), do: :checkpoint_failed
  defp normalize_runtime_error(:invalid_runtime_context), do: :invalid_runtime_context
  defp normalize_runtime_error(:invalid_runtime_request), do: :invalid_runtime_request
  defp normalize_runtime_error(:settings_unavailable), do: :settings_unavailable

  defp normalize_runtime_error(:provider_configuration_changed),
    do: :provider_configuration_changed

  defp normalize_runtime_error(:invalid_provider_snapshot_ref), do: :invalid_provider_snapshot_ref
  defp normalize_runtime_error(:unsupported_provider), do: :unsupported_provider
  defp normalize_runtime_error(:provider_unavailable), do: :provider_unavailable
  defp normalize_runtime_error(:provider_response_too_large), do: :provider_response_too_large
  defp normalize_runtime_error(:invalid_provider_response), do: :invalid_provider_response
  defp normalize_runtime_error(:all_source_fetches_failed), do: :all_source_fetches_failed
  defp normalize_runtime_error(:session_unavailable), do: :session_unavailable
  defp normalize_runtime_error(:secret_in_runtime_params), do: :secret_in_runtime_params
  defp normalize_runtime_error(:provider_effect_unavailable), do: :provider_effect_unavailable

  defp normalize_runtime_error(:provider_effect_replay_without_response),
    do: :provider_effect_replay_without_response

  defp normalize_runtime_error(:invalid_provider_effect_receipt),
    do: :invalid_provider_effect_receipt

  defp normalize_runtime_error(:invalid_provider_effect_result),
    do: :invalid_provider_effect_result

  defp normalize_runtime_error(:provider_effect_failed), do: :provider_effect_failed
  defp normalize_runtime_error(:external_effect_uncertain), do: :external_effect_uncertain
  defp normalize_runtime_error(:external_effect_unsettled), do: :external_effect_unsettled
  defp normalize_runtime_error(:external_effect_ambiguous), do: :external_effect_ambiguous
  defp normalize_runtime_error(:external_effect_not_sent), do: :external_effect_not_sent

  defp normalize_runtime_error(:external_effect_release_failed),
    do: :external_effect_release_failed

  defp normalize_runtime_error(:provider_request_failed), do: :provider_request_failed
  defp normalize_runtime_error(:provider_request_too_large), do: :provider_request_too_large

  defp normalize_runtime_error(:provider_request_contains_secret),
    do: :provider_request_contains_secret

  defp normalize_runtime_error({:provider_error, reason}), do: error_atom(reason)
  defp normalize_runtime_error(_reason), do: :research_effect_failed

  defp error_atom(:cancelled), do: :cancelled
  defp error_atom(:timeout), do: :provider_timeout

  defp error_atom({:http_error, status, _detail}) when is_integer(status),
    do: {:provider_http_error, status}

  defp error_atom({:http_status, status}) when is_integer(status),
    do: {:provider_http_error, status}

  defp error_atom({:configuration, _detail}), do: :provider_configuration_error
  defp error_atom(:no_providers), do: :provider_unavailable
  defp error_atom({:all_providers_failed, _errors}), do: :provider_request_failed
  defp error_atom(_reason), do: :provider_request_failed

  defp error_code(reason) do
    case error_atom(reason) do
      atom when is_atom(atom) -> Atom.to_string(atom)
      {:provider_http_error, status} -> "provider_http_#{status}"
    end
  end

  defp bounded_integer(nil, _min, _max, default), do: {:ok, default}

  defp bounded_integer(value, min, max, _default)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_integer(_value, _min, _max, _default), do: {:error, :invalid_runtime_request}

  defp optional_bounded_integer(nil, _min, _max), do: {:ok, nil}

  defp optional_bounded_integer(value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp optional_bounded_integer(_value, _min, _max), do: {:error, :invalid_runtime_request}

  defp timeout(value, _default) when is_integer(value) and value in 1..@max_timeout_ms, do: value
  defp timeout(_value, default), do: default

  # ProviderEffect owns a total wall-clock deadline, unlike the request clients'
  # receive timeout, which is an idle-I/O bound. Keep short network operations
  # tight while allowing grounded search and long report generation to finish
  # beneath their handlers' 180-second step deadline.
  defp default_effect_timeout("research.ranked_search"), do: 60_000
  defp default_effect_timeout("research.grounded_search"), do: @max_effect_timeout_ms
  defp default_effect_timeout("research.report_synthesis"), do: @max_effect_timeout_ms
  defp default_effect_timeout("research.source_fetch." <> _index), do: 75_000
  defp default_effect_timeout(_operation), do: 60_000

  defp effect_timeout(value, _default)
       when is_integer(value) and value in 1..@max_effect_timeout_ms,
       do: value

  defp effect_timeout(_value, default), do: default

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom, item} when is_atom(atom) -> if Atom.to_string(atom) == key, do: item
        _entry -> nil
      end)
  end

  defp value(_map, _key), do: nil

  defp value_from_opts(opts, key), do: Keyword.get(opts, key)

  defp bounded_string(value, max) when is_binary(value),
    do: value |> String.replace_invalid() |> bounded_binary(max)

  defp bounded_string(_value, _max), do: nil

  defp bounded_binary(value, max) when byte_size(value) <= max, do: value
  defp bounded_binary(value, max), do: binary_part(value, 0, max) |> String.replace_invalid()

  defp safe_number(value) when is_number(value), do: value
  defp safe_number(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp sha256(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)

  defp invoke_search(opts, query, search_opts) do
    case Keyword.get(opts, :search_module, Search) do
      callback when is_function(callback, 2) -> callback.(query, search_opts)
      module when is_atom(module) -> module.search(query, search_opts)
    end
  end

  defp invoke_grounded(opts, provider, query, grounded_opts) do
    case Keyword.get(opts, :grounded_search_module, GroundedSearch) do
      callback when is_function(callback, 3) -> callback.(provider, query, grounded_opts)
      module when is_atom(module) -> module.answer(provider, query, grounded_opts)
    end
  end

  defp invoke_fetcher(opts, url, fetch_opts) do
    case Keyword.get(opts, :fetcher_module, Fetcher) do
      callback when is_function(callback, 2) -> callback.(url, fetch_opts)
      module when is_atom(module) -> module.fetch(url, fetch_opts)
    end
  end

  defp invoke_llm(opts, messages, system_prompt, session, on_chunk, llm_opts) do
    case Keyword.get(opts, :llm_module, IexCode.LLM) do
      callback when is_function(callback, 5) ->
        callback.(messages, system_prompt, session, on_chunk, llm_opts)

      module when is_atom(module) ->
        module.chat(messages, system_prompt, session, on_chunk, llm_opts)
    end
  end
end
