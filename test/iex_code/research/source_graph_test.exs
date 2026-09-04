defmodule IexCode.Research.SourceGraphTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.SourceGraph

  describe "domain classification" do
    test "classifies academic domains" do
      assert SourceGraph.classify_domain("arxiv.org") == :academic
      assert SourceGraph.classify_domain("https://arxiv.org/abs/2301.00000") == :academic
      assert SourceGraph.classify_domain("https://cs.stanford.edu/papers") == :academic
      assert SourceGraph.classify_domain("https://ox.ac.uk/research") == :academic
      assert SourceGraph.classify_domain("https://www.nature.com/articles/s41586") == :academic
    end

    test "classifies official documentation and standards" do
      assert SourceGraph.classify_domain("https://hexdocs.pm/elixir/Kernel.html") ==
               :official_docs

      assert SourceGraph.classify_domain("https://elixir-lang.org/getting-started") ==
               :official_docs

      assert SourceGraph.classify_domain("https://erlang.org/doc/reference_manual") ==
               :official_docs

      assert SourceGraph.classify_domain("https://ietf.org/rfc/rfc9110.txt") == :official_docs
      assert SourceGraph.classify_domain("https://docs.rs/tokio/latest/tokio") == :official_docs
    end

    test "classifies government and defense domains" do
      assert SourceGraph.classify_domain("https://nist.gov/publications") == :gov
      assert SourceGraph.classify_domain("https://cisa.gov/resources") == :gov
      assert SourceGraph.classify_domain("https://europa.eu/legislation") == :gov
    end

    test "classifies tech registries and developer platforms" do
      assert SourceGraph.classify_domain("https://github.com/elixir-lang/elixir") ==
               :tech_registry

      assert SourceGraph.classify_domain("https://hex.pm/packages/phoenix") == :tech_registry
      assert SourceGraph.classify_domain("https://crates.io/crates/serde") == :tech_registry

      assert SourceGraph.classify_domain("https://stackoverflow.com/questions/12345") ==
               :tech_registry
    end

    test "classifies community and tech media" do
      assert SourceGraph.classify_domain("https://medium.com/@dev/elixir-concurrency") ==
               :community

      assert SourceGraph.classify_domain("https://dev.to/author/phoenix-liveview") == :community
      assert SourceGraph.classify_domain("https://reddit.com/r/elixir") == :community
      assert SourceGraph.classify_domain("https://news.ycombinator.com/item?id=123") == :community
    end

    test "classifies general or unknown domains" do
      assert SourceGraph.classify_domain("https://myrandomblog123.com/post") == :general
      assert SourceGraph.classify_domain("https://example.com") == :general
    end
  end

  describe "trust score calculation" do
    test "applies base score and HTTPS modifier" do
      # Academic base: 0.96 + HTTPS (+0.05) = 1.01 -> clamped to 0.99
      academic_https = SourceGraph.calculate_trust("https://arxiv.org/abs/123")
      assert academic_https == 0.99

      # Official docs base: 0.94 + HTTPS (+0.05) = 0.99
      docs_https = SourceGraph.calculate_trust("https://hexdocs.pm/elixir")
      assert docs_https == 0.99

      # Tech registry base: 0.88 + HTTPS (+0.05) = 0.93
      tech_https = SourceGraph.calculate_trust("https://github.com/elixir-lang/elixir")
      assert tech_https == 0.93

      # Community base: 0.70 + HTTPS (+0.05) = 0.75
      community_https = SourceGraph.calculate_trust("https://medium.com/post")
      assert community_https == 0.75

      # General base: 0.55 + HTTPS (+0.05) = 0.60
      general_https = SourceGraph.calculate_trust("https://randomsite.net/page")
      assert general_https == 0.60
    end

    test "penalizes unencrypted HTTP" do
      # General base: 0.55 + HTTP (-0.15) = 0.40
      general_http = SourceGraph.calculate_trust("http://randomsite.net/page")
      assert general_http == 0.40

      # Community base: 0.70 + HTTP (-0.15) = 0.55
      community_http = SourceGraph.calculate_trust("http://dev.to/article")
      assert community_http == 0.55
    end

    test "rewards .gov and .edu TLDs and penalizes suspicious TLDs" do
      # General base: 0.55 + HTTPS (+0.05) + .edu (+0.04) = 0.64
      edu_site = SourceGraph.calculate_trust("https://somestate.edu/lab")
      assert edu_site >= 0.64

      # General base: 0.55 + HTTPS (+0.05) + suspicious .xyz (-0.15) = 0.45
      spam_site = SourceGraph.calculate_trust("https://cryptotips.xyz/hack")
      assert spam_site == 0.45
    end

    test "rewards multi-provider corroboration" do
      single_prov = SourceGraph.calculate_trust("https://medium.com/post", providers_count: 1)
      multi_prov = SourceGraph.calculate_trust("https://medium.com/post", providers_count: 3)
      assert multi_prov > single_prov
      assert Float.round(multi_prov - single_prov, 2) == 0.05
    end
  end

  describe "composite relevance calculation" do
    test "evaluates semantic overlap with 2x title weighting" do
      query = "phoenix liveview streams memory optimization"
      matching_title = "Phoenix LiveView Streams In-Depth Guide"

      matching_snippet =
        "Strategies for bounded memory optimization and DOM patching with streams."

      score = SourceGraph.calculate_relevance(query, matching_title, matching_snippet)
      assert score > 0.65

      unrelated_title = "Cooking Pasta with Garlic"
      unrelated_snippet = "Boil water in a large pot and add salt."
      low_score = SourceGraph.calculate_relevance(query, unrelated_title, unrelated_snippet)
      assert low_score < score
    end

    test "gives recency bonus for recent publications" do
      query = "Elixir OTP Supervision"
      title = "Supervision trees"
      snippet = "Supervisors restart child processes when they fail."

      today_iso = Date.to_iso8601(Date.utc_today())

      recent_score =
        SourceGraph.calculate_relevance(query, title, snippet, published_at: today_iso)

      # 6 years ago
      old_date = Date.to_iso8601(Date.add(Date.utc_today(), -2200))

      old_score =
        SourceGraph.calculate_relevance(query, title, snippet,
          published_at: old_date,
          category: :general
        )

      assert recent_score > old_score
    end

    test "rewards content depth and code snippets" do
      query = "GenServer state pattern"
      title = "GenServer guide"

      short_snippet = "Use GenServer."
      short_score = SourceGraph.calculate_relevance(query, title, short_snippet)

      deep_code_snippet = """
      defmodule MyServer do
        use GenServer
        def init(state), do: {:ok, state}
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      deep_score = SourceGraph.calculate_relevance(query, title, deep_code_snippet)

      assert deep_score > short_score
    end
  end

  describe "graph building and topology" do
    test "builds nodes, detects edges, and computes metrics" do
      sources = [
        %{
          "url" => "https://hexdocs.pm/elixir/Kernel.html",
          "title" => "Kernel — Elixir HexDocs",
          "snippet" => "Core standard library functions, macros, and operators for Elixir.",
          "trust_score" => 0.98
        },
        %{
          "url" => "https://hexdocs.pm/elixir/GenServer.html",
          "title" => "GenServer — Elixir HexDocs",
          "snippet" =>
            "A behaviour module for implementing client-server relations in Elixir standard library.",
          "trust_score" => 0.98
        },
        %{
          "url" => "https://elixir-lang.org/docs",
          "title" => "Official Documentation & Guides",
          "snippet" => "Learn Elixir Kernel macros, GenServer behaviours, and OTP supervision.",
          "trust_score" => 0.95
        },
        %{
          "url" => "https://medium.com/elixir-tips/genserver-pitfalls",
          "title" => "GenServer Pitfalls to Avoid",
          "snippet" =>
            "Avoid blocking calls in GenServer callbacks to prevent process mailbox saturation.",
          "trust_score" => 0.70
        }
      ]

      graph = SourceGraph.build(sources, query: "Elixir GenServer")

      # Nodes
      assert length(graph.nodes) == 4
      [n1, n2, n3, n4] = graph.nodes
      assert n1.authority_category == :official_docs
      assert n2.authority_category == :official_docs
      assert n3.authority_category == :official_docs
      assert n4.authority_category == :community

      # Co-domain edge detected between hexdocs nodes
      co_domain_edge =
        Enum.find(graph.edges, fn e ->
          e.relationship == :co_domain and
            ((e.source == n1.id and e.target == n2.id) or
               (e.source == n2.id and e.target == n1.id))
        end)

      assert co_domain_edge != nil

      # Corroboration edge detected
      corroborates_edge =
        Enum.find(graph.edges, fn e -> e.relationship == :corroborates end)

      assert corroborates_edge != nil

      # Degree and corroboration counts
      assert Enum.all?(graph.nodes, fn node -> is_integer(node.degree) end)

      # Metrics
      assert graph.metrics.total_nodes == 4
      assert graph.metrics.total_edges == length(graph.edges)
      assert graph.metrics.average_trust > 0.80
      assert graph.metrics.edge_density >= 0.0

      # Citations list
      assert length(graph.citations) == 4
      first_cit = List.first(graph.citations)
      assert Map.has_key?(first_cit, "trust_score")
      assert Map.has_key?(first_cit, "relevance_score")
      assert Map.has_key?(first_cit, "authority_category")
    end
  end
end
