defmodule IexCode.Research.Search do
  @moduledoc """
  Concurrent federated web search.

  Providers are isolated: one provider's crash, timeout, or HTTP failure never
  discards successful results from another. Successful provider result lists
  are deterministically interleaved so an early provider cannot consume the
  caller's result budget. Results are deduplicated by canonical URL while
  retaining duplicate-provider provenance.
  """

  alias IexCode.Research.{Registry, Result}

  @provider_option_keys ~w(api_key base_url enabled cx engine_id engine country language search_depth location safe include_domains exclude_domains start_date end_date search_after_date search_before_date recency)a

  @type response :: %{
          results: [IexCode.Research.Result.t()],
          errors: %{optional(String.t()) => term()},
          providers: [String.t()]
        }

  @spec search(String.t(), keyword()) ::
          {:ok, response()}
          | {:error, :invalid_query | :no_providers | {:all_providers_failed, map()}}
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) and is_list(opts) do
    query = String.trim(query)

    if query == "" do
      {:error, :invalid_query}
    else
      config = Keyword.get(opts, :config, %{})
      selected = select_providers(Keyword.get(opts, :providers), config)
      run(query, selected, opts)
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp run(_query, [], _opts), do: {:error, :no_providers}

  defp run(query, selected, opts) do
    timeout = positive_integer(Keyword.get(opts, :timeout), 15_000)
    concurrency = positive_integer(Keyword.get(opts, :max_concurrency), 4)

    outputs =
      Task.async_stream(
        selected,
        fn {name, module, config} -> invoke(name, module, query, provider_opts(config, opts)) end,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    {provider_results, errors, successful} =
      selected
      |> Enum.zip(outputs)
      |> Enum.reduce({[], %{}, []}, fn
        {{name, _module, _config}, {:ok, {:ok, provider_results}}}, {results, errors, ok} ->
          {results ++ [provider_results], errors, ok ++ [to_string(name)]}

        {{name, _module, _config}, {:ok, {:error, reason}}}, {results, errors, ok} ->
          {results, Map.put(errors, to_string(name), reason), ok}

        {{name, _module, _config}, {:exit, reason}}, {results, errors, ok} ->
          {results, Map.put(errors, to_string(name), normalize_exit(reason)), ok}
      end)

    if map_size(errors) == length(selected) do
      {:error, {:all_providers_failed, errors}}
    else
      results = provider_results |> interleave() |> deduplicate()
      {:ok, %{results: results, errors: errors, providers: successful}}
    end
  end

  defp invoke(name, module, query, opts) do
    case module.search(query, opts) do
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_provider_response, other}}
    end
  rescue
    exception -> {:error, {:provider_exception, to_string(name), Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:provider_failure, to_string(name), kind, reason}}
  end

  defp select_providers(providers, _config) when is_map(providers),
    do: Registry.configured(providers)

  defp select_providers(nil, config), do: Registry.configured(config)

  defp select_providers([], config), do: Registry.configured(config)

  defp select_providers(providers, config) when is_list(providers) do
    providers
    |> Enum.reduce([], fn provider, selected ->
      case Registry.fetch(provider) do
        {:ok, module} ->
          name = provider_name(provider, module)
          selected ++ [{name, module, Registry.provider_config(config, name)}]

        :error ->
          selected
      end
    end)
    |> Enum.uniq_by(fn {name, _, _} -> name end)
  end

  defp select_providers(_providers, _config), do: []

  defp provider_name(provider, module) when is_binary(provider), do: module.name()

  defp provider_name(provider, module) do
    if Map.has_key?(Registry.all(), provider), do: provider, else: module.name()
  end

  defp provider_opts(config, opts) do
    configured =
      Enum.reduce(@provider_option_keys, [], fn key, acc ->
        value = Map.get(config, key, Map.get(config, Atom.to_string(key)))
        if is_nil(value), do: acc, else: Keyword.put(acc, key, value)
      end)

    Enum.reduce(
      [
        :request,
        :limit,
        :receive_timeout,
        :country,
        :language,
        :search_depth,
        :location,
        :safe,
        :include_domains,
        :exclude_domains,
        :start_date,
        :end_date,
        :search_after_date,
        :search_before_date,
        :recency
      ],
      configured,
      fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> Keyword.put(acc, key, value)
          :error -> acc
        end
      end
    )
  end

  defp interleave(provider_results) do
    provider_results
    |> Enum.with_index()
    |> Enum.flat_map(fn {results, provider_index} ->
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, rank} -> {result, rank, provider_index} end)
    end)
    |> Enum.sort_by(fn {_result, rank, provider_index} -> {rank, provider_index} end)
    |> Enum.map(fn {result, _rank, _provider_index} -> result end)
  end

  defp deduplicate(results) do
    results
    |> Enum.reduce({[], %{}}, fn result, {order, indexed} ->
      key = canonical_url(result.url)

      case Map.fetch(indexed, key) do
        {:ok, primary} ->
          {order, Map.put(indexed, key, Result.merge_provenance(primary, result))}

        :error ->
          {[key | order], Map.put(indexed, key, result)}
      end
    end)
    |> then(fn {reversed_order, indexed} ->
      reversed_order
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(indexed, &1))
    end)
  end

  defp canonical_url(url) do
    uri = URI.parse(url)

    %URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host),
        fragment: nil
    }
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp normalize_exit(:timeout), do: :timeout
  defp normalize_exit({:timeout, _}), do: :timeout
  defp normalize_exit(reason), do: {:task_exit, reason}

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
