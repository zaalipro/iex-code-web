defmodule IexCode.Research.DagStepHandlers.EvidenceMerge do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Research.DagContracts

  @fields ~w(round max_sources preserve_provider_rank grounded_answers_are_not_ranked_rows canonicalize_urls artifact_kind level_policy)
  @max_durable_sources 40
  @max_snippet_bytes 1_000

  @impl true
  def descriptor do
    %{
      kind: "research_evidence_merge",
      version: 1,
      effect_class: :pure,
      replay_policy: :safe,
      resource_contract: "research_evidence_read_v1",
      checkpoint_version: 1,
      max_output_bytes: 240_000,
      default_timeout_ms: 30_000
    }
  end

  @impl true
  def validate_params(params, dependencies) do
    with true <- dependencies != [] or {:error, :merge_requires_dependencies},
         :ok <- DagContracts.exact_fields(params, @fields),
         :ok <- DagContracts.integer(params["round"], 1..6, :round),
         :ok <-
           DagContracts.integer(params["max_sources"], 1..@max_durable_sources, :max_sources),
         :ok <- DagContracts.boolean(params["preserve_provider_rank"], :rank),
         :ok <- DagContracts.boolean(params["grounded_answers_are_not_ranked_rows"], :grounded),
         :ok <- DagContracts.boolean(params["canonicalize_urls"], :canonicalize),
         :ok <- DagContracts.level_policy(params["level_policy"]),
         true <- params["artifact_kind"] == "research_evidence" or {:error, {:params, :artifact}} do
      :ok
    else
      false -> {:error, {:params, :invalid}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def execute(params, context) do
    if DagContracts.cancelled?(context) do
      {:error, :cancelled}
    else
      prior = prior_evidence(context)
      ranked = context |> DagContracts.dependencies("research.ranked_batch") |> ranked_sources()

      grounded =
        context |> DagContracts.dependencies("research.grounded_batch") |> grounded_sources()

      requested = params["max_sources"]
      sources = deduplicate(prior ++ ranked ++ grounded) |> Enum.take(requested)

      if sources == [] do
        {:error, :no_research_evidence}
      else
        DagContracts.wrap("research.evidence", "research_evidence", %{
          "round" => params["round"],
          "sources" => sources,
          "source_count" => length(sources),
          "requested_max_sources" => params["max_sources"],
          "truncated" => false,
          "ranked_and_grounded_planes_preserved" => true
        })
      end
    end
  end

  defp ranked_sources(results) do
    Enum.flat_map(results, fn result ->
      data = DagContracts.data(result)
      provider = data["provider"] || "unknown"

      data
      |> Map.get("entries", [])
      |> Enum.flat_map(fn entry ->
        if entry["status"] == "completed" do
          entry
          |> Map.get("results", [])
          |> Enum.flat_map(&ranked_source(&1, provider, entry["query"]))
        else
          []
        end
      end)
    end)
  end

  defp ranked_source(row, provider, query) when is_map(row) do
    url = DagContracts.value(row, :url)
    title = DagContracts.value(row, :title)

    if valid_url?(url) and is_binary(title) and String.trim(title) != "" do
      [
        source(
          url,
          title,
          DagContracts.value(row, :snippet),
          provider,
          "ranked_result",
          query
        )
      ]
    else
      []
    end
  end

  defp ranked_source(_row, _provider, _query), do: []

  defp grounded_sources(results) do
    Enum.flat_map(results, fn result ->
      data = DagContracts.data(result)
      provider = data["provider"] || "unknown"

      data
      |> Map.get("entries", [])
      |> Enum.flat_map(fn entry ->
        answer = Map.get(entry, "answer", "")

        entry
        |> Map.get("citations", [])
        |> Enum.flat_map(&grounded_source(&1, answer, provider, entry["query"]))
      end)
    end)
  end

  defp grounded_source(citation, answer, provider, query) when is_map(citation) do
    url = DagContracts.value(citation, :url)
    title = DagContracts.value(citation, :title) || url
    cited = DagContracts.value(citation, :cited_text) || answer

    if valid_url?(url),
      do: [source(url, title, cited, provider, "grounded_citation", query)],
      else: []
  end

  defp grounded_source(_citation, _answer, _provider, _query), do: []

  defp prior_evidence(context) do
    context
    |> DagContracts.dependencies("research.audit")
    |> Enum.flat_map(fn result -> result |> DagContracts.data() |> Map.get("sources", []) end)
  end

  defp source(url, title, snippet, provider, plane, query) do
    canonical = canonical_url(url) |> bound(2_000)

    %{
      "id" => digest(canonical),
      "url" => canonical,
      "title" => bound(title, 500),
      "snippet" => bound(snippet || "", @max_snippet_bytes),
      "provider" => bound(provider, 80),
      "plane" => plane,
      "query" => bound(query || "", 500),
      "provenance" => [%{"provider" => bound(provider, 80), "plane" => plane}]
    }
  end

  defp deduplicate(sources) do
    sources
    |> Enum.reduce({[], %{}}, fn source, {order, indexed} ->
      case Map.fetch(indexed, source["url"]) do
        {:ok, primary} ->
          provenance = Enum.uniq(primary["provenance"] ++ source["provenance"])
          {order, Map.put(indexed, source["url"], Map.put(primary, "provenance", provenance))}

        :error ->
          {order ++ [source["url"]], Map.put(indexed, source["url"], source)}
      end
    end)
    |> then(fn {order, indexed} -> Enum.map(order, &Map.fetch!(indexed, &1)) end)
  end

  defp canonical_url(url) do
    uri = URI.parse(url)

    %URI{
      uri
      | scheme: String.downcase(uri.scheme),
        host: String.downcase(uri.host),
        fragment: nil
    }
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp valid_url?(url) when is_binary(url) do
    match?(
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host != nil,
      URI.parse(url)
    )
  end

  defp valid_url?(_url), do: false
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp bound(value, max) do
    value = if is_binary(value), do: value, else: to_string(value)
    value = String.replace_invalid(value)

    if byte_size(value) <= max,
      do: value,
      else: value |> binary_part(0, max) |> String.replace_invalid()
  end
end
