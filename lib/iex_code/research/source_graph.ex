defmodule IexCode.Research.SourceGraph do
  @moduledoc """
  Constructs and analyzes real-time citation and source graphs for Deep Research.

  Features:
  - Multi-tier domain trust classification (Academic, Official Docs, Gov, Tech Registries, Community, General)
  - Modifiers for HTTPS security, TLD trust, and cross-source corroboration
  - Composite source relevance calculation (semantic query overlap, publication recency, content depth)
  - Relational edge detection (:corroborates, :contradicts, :co_domain, :cross_reference)
  - Topology metrics (average trust, edge density, authority distribution)
  """

  @type authority_category ::
          :academic
          | :official_docs
          | :gov
          | :tech_registry
          | :community
          | :general

  @type trust_tier :: :high | :medium | :low

  @type node_item :: %{
          id: String.t(),
          index: pos_integer(),
          url: String.t(),
          domain: String.t(),
          title: String.t(),
          snippet: String.t(),
          trust_score: float(),
          trust_tier: trust_tier(),
          relevance_score: float(),
          authority_category: authority_category(),
          ssl: boolean(),
          published_at: String.t() | nil,
          corroboration_count: non_neg_integer(),
          degree: non_neg_integer()
        }

  @type edge_item :: %{
          source: String.t(),
          target: String.t(),
          relationship: :corroborates | :contradicts | :co_domain | :cross_reference,
          weight: float(),
          shared_terms: list(String.t()),
          rationale: String.t()
        }

  @type graph_result :: %{
          nodes: list(node_item()),
          edges: list(edge_item()),
          trust_ratings: %{String.t() => map()},
          citations: list(map()),
          metrics: map()
        }

  @stop_words ~w(
    the a an is are was were be been being in on at by for with about against
    between into through during before after above below to from up down in out
    over under again further then once here there when where why how all any
    both each few more most other some such no nor not only own same so than
    too very s t can will just don should now and or but if as of
  )

  @academic_domains ~w(
    arxiv.org acm.org ieee.org biorxiv.org semanticscholar.org
    nature.com springer.com jstor.org sciencedirect.com nih.gov
  )

  @official_docs_domains ~w(
    hexdocs.pm elixir-lang.org erlang.org ietf.org w3.org iso.org
    rfc-editor.org developer.mozilla.org python.org rust-lang.org
    go.dev docs.rs rubyonrails.org kernel.org postgresql.org
  )

  @gov_domains ~w(
    nist.gov europa.eu cisa.gov nasa.gov w3c.org
  )

  @tech_registry_domains ~w(
    github.com gitlab.com hex.pm crates.io npmjs.com pypi.org
    stackoverflow.com stackexchange.com pkg.go.dev
  )

  @community_domains ~w(
    medium.com dev.to substack.com hackernoon.com reddit.com
    news.ycombinator.com hashnode.dev infoq.com dzone.com
  )

  @suspicious_tlds ~w(.xyz .top .tk .ml .ga .cf .gq .buzz .click .work .loan)

  @negation_terms ~w(
    not never cannot cant cant doesn't does not shouldn't should not
    deprecated incompatible prohibited avoid unsupported antipattern anti-pattern
    unsafe fails broken obsolete unrecommended
  )

  @positive_terms ~w(
    recommended supports supported compatible standard idiom idiomatic
    optimal verified essential canonical safe best-practice best practice
  )

  @doc """
  Returns the list of stopwords used in text tokenization.
  """
  @spec stop_words() :: list(String.t())
  def stop_words, do: @stop_words

  @doc """
  Builds a complete source graph from a collection of raw sources, citations, or findings.
  Accepts query options to evaluate semantic relevance.
  """
  @spec build(list() | map(), keyword()) :: graph_result()
  def build(sources_or_result, opts \\ [])

  def build(%{citations: citations} = result, opts) when is_list(citations) do
    query = opts[:query] || Map.get(result, :query) || Map.get(result, "query") || ""
    build(citations, Keyword.put(opts, :query, query))
  end

  def build(%{"citations" => citations} = result, opts) when is_list(citations) do
    query = opts[:query] || Map.get(result, "query") || ""
    build(citations, Keyword.put(opts, :query, query))
  end

  def build(sources, opts) when is_list(sources) do
    query = to_string(opts[:query] || "")

    # 1. Normalize and enrich nodes with domain classification, trust, and relevance
    raw_nodes =
      sources
      |> Enum.with_index(1)
      |> Enum.map(fn {source, index} ->
        normalize_node(source, index, query, opts)
      end)

    # 2. Build relational edges between nodes
    edges = detect_edges(raw_nodes)

    # 3. Calculate degrees and corroboration counts for each node
    nodes =
      Enum.map(raw_nodes, fn node ->
        node_edges = Enum.filter(edges, fn e -> e.source == node.id or e.target == node.id end)

        corroborations =
          Enum.count(node_edges, fn e -> e.relationship == :corroborates end)

        # Multi-provider / multi-edge corroboration bonus on trust score
        trust_bonus = if corroborations > 0, do: min(0.05, corroborations * 0.02), else: 0.0
        final_trust = Float.round(min(0.99, max(0.05, node.trust_score + trust_bonus)), 3)
        final_tier = classify_tier(final_trust)

        %{
          node
          | trust_score: final_trust,
            trust_tier: final_tier,
            degree: length(node_edges),
            corroboration_count: corroborations
        }
      end)

    # 4. Generate domain-level trust ratings index
    trust_ratings =
      nodes
      |> Enum.group_by(& &1.domain)
      |> Map.new(fn {domain, domain_nodes} ->
        avg_trust =
          domain_nodes
          |> Enum.map(& &1.trust_score)
          |> average()

        category = List.first(domain_nodes).authority_category

        {domain,
         %{
           domain: domain,
           authority_category: category,
           average_trust: avg_trust,
           source_count: length(domain_nodes),
           trust_tier: classify_tier(avg_trust)
         }}
      end)

    # 5. Format citations list with rich metadata
    citations =
      Enum.map(nodes, fn node ->
        %{
          "id" => node.id,
          "index" => node.index,
          "title" => node.title,
          "url" => node.url,
          "domain" => node.domain,
          "snippet" => node.snippet,
          "trust_score" => node.trust_score,
          "trust_tier" => to_string(node.trust_tier),
          "relevance_score" => node.relevance_score,
          "authority_category" => to_string(node.authority_category),
          "ssl" => node.ssl,
          "corroboration_count" => node.corroboration_count,
          "degree" => node.degree
        }
      end)

    # 6. Aggregate graph topology metrics
    metrics = calculate_metrics(nodes, edges)

    %{
      nodes: nodes,
      edges: edges,
      trust_ratings: trust_ratings,
      citations: citations,
      metrics: metrics
    }
  end

  def build(_, _opts) do
    %{
      nodes: [],
      edges: [],
      trust_ratings: %{},
      citations: [],
      metrics: %{
        average_trust: 0.0,
        edge_density: 0.0,
        authority_distribution: %{},
        total_nodes: 0,
        total_edges: 0
      }
    }
  end

  # ============================================================================
  # DOMAIN CLASSIFICATION & TRUST SCORING
  # ============================================================================

  @doc """
  Classifies domain authority into one of:
  `:academic`, `:official_docs`, `:gov`, `:tech_registry`, `:community`, `:general`.
  """
  @spec classify_domain(String.t()) :: authority_category()
  def classify_domain(url_or_domain) when is_binary(url_or_domain) do
    domain = extract_domain(url_or_domain)

    cond do
      is_academic?(domain) -> :academic
      is_gov?(domain) -> :gov
      is_official_docs?(domain) -> :official_docs
      is_tech_registry?(domain) -> :tech_registry
      is_community?(domain) -> :community
      true -> :general
    end
  end

  def classify_domain(_), do: :general

  @doc """
  Calculates domain trust score (0.05..0.99) factoring category base, SSL, TLDs, and providers.
  """
  @spec calculate_trust(String.t(), keyword()) :: float()
  def calculate_trust(url_or_domain, opts \\ []) do
    url = to_string(url_or_domain)
    domain = extract_domain(url)
    category = classify_domain(domain)

    base =
      case category do
        :academic -> 0.96
        :gov -> 0.95
        :official_docs -> 0.94
        :tech_registry -> 0.88
        :community -> 0.70
        :general -> 0.55
      end

    # SSL Protocol Modifier
    ssl_mod =
      cond do
        String.starts_with?(String.downcase(url), "https://") -> 0.05
        String.starts_with?(String.downcase(url), "http://") -> -0.15
        true -> 0.0
      end

    # TLD Modifier
    tld_mod =
      cond do
        String.ends_with?(domain, ".gov") or String.ends_with?(domain, ".mil") -> 0.04
        String.ends_with?(domain, ".edu") or String.ends_with?(domain, ".ac.uk") -> 0.04
        String.ends_with?(domain, ".org") -> 0.02
        Enum.any?(@suspicious_tlds, &String.ends_with?(domain, &1)) -> -0.15
        true -> 0.0
      end

    # Provider corroboration
    provider_mod =
      case opts[:providers_count] do
        count when is_integer(count) and count > 1 -> 0.05
        _ -> 0.0
      end

    score = base + ssl_mod + tld_mod + provider_mod
    Float.round(min(0.99, max(0.05, score)), 3)
  end

  # ============================================================================
  # COMPOSITE RELEVANCE CALCULATION
  # ============================================================================

  @doc """
  Calculates composite relevance score (0.0..1.0):
  50% semantic keyword overlap + 25% publication recency + 25% content depth.
  """
  @spec calculate_relevance(String.t(), String.t(), String.t(), keyword()) :: float()
  def calculate_relevance(query, title, snippet, opts \\ []) do
    semantic_score = calculate_semantic_overlap(query, title, snippet)
    recency_score = calculate_recency(opts[:published_at], opts[:category])
    depth_score = calculate_content_depth(snippet)

    composite = 0.50 * semantic_score + 0.25 * recency_score + 0.25 * depth_score
    Float.round(min(1.0, max(0.0, composite)), 3)
  end

  defp calculate_semantic_overlap(query, title, snippet) do
    query_tokens = tokenize(query)

    if query_tokens == [] do
      0.80
    else
      q_set = MapSet.new(query_tokens)
      t_tokens = tokenize(title)
      s_tokens = tokenize(snippet)

      t_set = MapSet.new(t_tokens)
      s_set = MapSet.new(s_tokens)

      t_matches = MapSet.size(MapSet.intersection(q_set, t_set))
      s_matches = MapSet.size(MapSet.intersection(q_set, s_set))

      t_ratio = if MapSet.size(q_set) > 0, do: t_matches / MapSet.size(q_set), else: 0.0
      s_ratio = if MapSet.size(q_set) > 0, do: s_matches / MapSet.size(q_set), else: 0.0

      # Title matches weighted 2x
      weighted = (2.0 * t_ratio + 1.0 * s_ratio) / 2.0

      # Bonus if exact query phrase appears in title or snippet
      phrase_bonus =
        if query != "" and
             (String.contains?(String.downcase(title || ""), String.downcase(query)) or
                String.contains?(String.downcase(snippet || ""), String.downcase(query))) do
          0.15
        else
          0.0
        end

      min(1.0, weighted + phrase_bonus)
    end
  end

  defp calculate_recency(nil, category) do
    if category in [:official_docs, :academic], do: 0.85, else: 0.70
  end

  defp calculate_recency(published_at, category) when is_binary(published_at) do
    case parse_date(published_at) do
      {:ok, date} ->
        days_old = max(0, Date.diff(Date.utc_today(), date))

        cond do
          days_old < 180 -> 1.0
          days_old < 365 -> 0.90
          days_old < 730 -> 0.75
          days_old < 1825 -> 0.60
          category in [:official_docs, :academic] -> 0.85
          true -> 0.40
        end

      _ ->
        if category in [:official_docs, :academic], do: 0.85, else: 0.70
    end
  end

  defp calculate_recency(_, category) do
    if category in [:official_docs, :academic], do: 0.85, else: 0.70
  end

  defp calculate_content_depth(snippet) do
    text = to_string(snippet || "")
    len = String.length(text)

    base =
      cond do
        len < 60 -> 0.35
        len <= 250 -> 0.70
        true -> 0.90
      end

    code_bonus =
      if String.contains?(text, "`") or
           String.contains?(text, "def ") or
           String.contains?(text, "fn ") or
           String.contains?(text, "|>") or
           String.contains?(text, "struct ") or
           String.contains?(text, "class ") do
        0.10
      else
        0.0
      end

    min(1.0, base + code_bonus)
  end

  # ============================================================================
  # EDGE DETECTION & GRAPH TOPOLOGY
  # ============================================================================

  defp detect_edges(nodes) do
    node_pairs = for a <- nodes, b <- nodes, a.index < b.index, do: {a, b}

    Enum.flat_map(node_pairs, fn {a, b} ->
      eval_edge_pair(a, b)
    end)
  end

  defp eval_edge_pair(a, b) do
    cond do
      # 1. Co-domain relationship
      a.domain == b.domain and a.domain != "" ->
        [
          %{
            source: a.id,
            target: b.id,
            relationship: :co_domain,
            weight: 0.60,
            shared_terms: [a.domain],
            rationale: "Both sources originate from domain #{a.domain}"
          }
        ]

      # 2. Cross-reference citation
      cross_references?(a, b) ->
        [
          %{
            source: a.id,
            target: b.id,
            relationship: :cross_reference,
            weight: 0.85,
            shared_terms: [b.domain],
            rationale: "Source mentions or cites #{b.domain}"
          }
        ]

      true ->
        # 3. Semantic term overlap & contradiction detection
        terms_a = MapSet.new(tokenize(a.title <> " " <> a.snippet))
        terms_b = MapSet.new(tokenize(b.title <> " " <> b.snippet))
        shared = MapSet.to_list(MapSet.intersection(terms_a, terms_b))

        cond do
          # Check for contradiction on shared subject
          has_contradiction?(a, b, shared) ->
            [
              %{
                source: a.id,
                target: b.id,
                relationship: :contradicts,
                weight: 0.75,
                shared_terms: Enum.take(shared, 5),
                rationale:
                  "Conflicting claims identified regarding #{Enum.join(Enum.take(shared, 3), ", ")}"
              }
            ]

          length(shared) >= 3 ->
            weight = Float.round(min(0.95, 0.70 + length(shared) * 0.04), 3)

            [
              %{
                source: a.id,
                target: b.id,
                relationship: :corroborates,
                weight: weight,
                shared_terms: Enum.take(shared, 5),
                rationale:
                  "Corroborating evidence across #{Enum.join(Enum.take(shared, 3), ", ")}"
              }
            ]

          true ->
            []
        end
    end
  end

  defp cross_references?(a, b) do
    url_a = String.downcase(a.url || "")
    url_b = String.downcase(b.url || "")
    dom_a = String.downcase(a.domain || "")
    dom_b = String.downcase(b.domain || "")

    text_a = String.downcase((a.snippet || "") <> " " <> (a.title || ""))
    text_b = String.downcase((b.snippet || "") <> " " <> (b.title || ""))

    (dom_b != "" and String.contains?(text_a, dom_b)) or
      (url_b != "" and String.contains?(text_a, url_b)) or
      (dom_a != "" and String.contains?(text_b, dom_a)) or
      (url_a != "" and String.contains?(text_b, url_a))
  end

  defp has_contradiction?(a, b, shared_terms) do
    if length(shared_terms) < 2 do
      false
    else
      text_a = String.downcase((a.snippet || "") <> " " <> (a.title || ""))
      text_b = String.downcase((b.snippet || "") <> " " <> (b.title || ""))

      neg_a = Enum.any?(@negation_terms, &String.contains?(text_a, &1))
      neg_b = Enum.any?(@negation_terms, &String.contains?(text_b, &1))

      pos_a = Enum.any?(@positive_terms, &String.contains?(text_a, &1))
      pos_b = Enum.any?(@positive_terms, &String.contains?(text_b, &1))

      (neg_a and pos_b and not neg_b) or (neg_b and pos_a and not neg_a)
    end
  end

  # ============================================================================
  # HELPERS & NORMALIZATION
  # ============================================================================

  defp normalize_node(source, index, query, opts) when is_map(source) do
    url =
      get_val(source, :url) || get_val(source, "url") ||
        "https://hexdocs.pm/elixir/Kernel.html"

    domain = extract_domain(url)
    category = classify_domain(domain)
    ssl = String.starts_with?(String.downcase(url), "https://")

    title =
      get_val(source, :title) || get_val(source, "title") ||
        "Reference #{index}: #{domain}"

    snippet =
      get_val(source, :snippet) || get_val(source, "snippet") ||
        get_val(source, :claim) || get_val(source, "claim") ||
        "Evidence from #{domain}"

    published_at =
      get_val(source, :published_at) || get_val(source, "published_at") ||
        get_val(source, :date) || get_val(source, "date")

    trust_score =
      case get_val(source, :trust_score) || get_val(source, "trust_score") do
        score when is_number(score) ->
          Float.round(min(0.99, max(0.05, score * 1.0)), 3)

        _ ->
          calculate_trust(url, opts)
      end

    relevance_score =
      case get_val(source, :relevance_score) || get_val(source, "relevance_score") do
        score when is_number(score) ->
          Float.round(min(1.0, max(0.0, score * 1.0)), 3)

        _ ->
          calculate_relevance(query, title, snippet,
            published_at: published_at,
            category: category
          )
      end

    id = get_val(source, :id) || get_val(source, "id") || url

    %{
      id: to_string(id),
      index: index,
      url: url,
      domain: domain,
      title: title,
      snippet: snippet,
      trust_score: trust_score,
      trust_tier: classify_tier(trust_score),
      relevance_score: relevance_score,
      authority_category: category,
      ssl: ssl,
      published_at: published_at,
      corroboration_count: 0,
      degree: 0
    }
  end

  defp classify_tier(score) when score >= 0.85, do: :high
  defp classify_tier(score) when score >= 0.70, do: :medium
  defp classify_tier(_), do: :low

  defp extract_domain(url_or_domain) do
    str = String.trim(to_string(url_or_domain))

    case URI.parse(str) do
      %URI{host: host} when is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        str
        |> String.split("/", trim: true)
        |> List.first()
        |> to_string()
        |> String.downcase()
    end
  end

  defp is_academic?(domain) do
    String.ends_with?(domain, ".edu") or
      String.ends_with?(domain, ".ac.uk") or
      String.ends_with?(domain, ".edu.au") or
      Enum.any?(@academic_domains, fn d -> domain == d or String.ends_with?(domain, "." <> d) end)
  end

  defp is_gov?(domain) do
    String.ends_with?(domain, ".gov") or
      String.ends_with?(domain, ".mil") or
      String.ends_with?(domain, ".europa.eu") or
      Enum.any?(@gov_domains, fn d -> domain == d or String.ends_with?(domain, "." <> d) end)
  end

  defp is_official_docs?(domain) do
    String.starts_with?(domain, "docs.") or
      String.ends_with?(domain, ".hexdocs.pm") or
      Enum.any?(@official_docs_domains, fn d ->
        domain == d or String.ends_with?(domain, "." <> d)
      end)
  end

  defp is_tech_registry?(domain) do
    String.ends_with?(domain, ".github.io") or
      Enum.any?(@tech_registry_domains, fn d ->
        domain == d or String.ends_with?(domain, "." <> d)
      end)
  end

  defp is_community?(domain) do
    String.ends_with?(domain, ".medium.com") or
      String.ends_with?(domain, ".substack.com") or
      Enum.any?(@community_domains, fn d -> domain == d or String.ends_with?(domain, "." <> d) end)
  end

  defp tokenize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\s-]/u, " ")
    |> String.split(~r/[\s_]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn token ->
      String.length(token) < 2 or token in @stop_words
    end)
  end

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(String.slice(date_str, 0, 10)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp calculate_metrics([], _edges) do
    %{
      average_trust: 0.0,
      edge_density: 0.0,
      authority_distribution: %{},
      total_nodes: 0,
      total_edges: 0
    }
  end

  defp calculate_metrics(nodes, edges) do
    n = length(nodes)
    e = length(edges)

    avg_trust =
      nodes
      |> Enum.map(& &1.trust_score)
      |> average()

    density =
      if n > 1 do
        Float.round(2.0 * e / (n * (n - 1)), 3)
      else
        0.0
      end

    dist =
      nodes
      |> Enum.group_by(& &1.authority_category)
      |> Map.new(fn {cat, list} -> {cat, length(list)} end)

    %{
      average_trust: avg_trust,
      edge_density: density,
      authority_distribution: dist,
      total_nodes: n,
      total_edges: e
    }
  end

  defp average([]), do: 0.0

  defp average(numbers) do
    Float.round(Enum.sum(numbers) / length(numbers), 3)
  end

  defp get_val(map, key) when is_map(map) do
    Map.get(map, key)
  end

  defp get_val(_, _), do: nil
end
