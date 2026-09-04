defmodule IexCode.Research.M3ChallengerGraphConflictTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{ConflictResolver, SourceGraph}
  alias IexCode.Workflows.Steps.SwarmCodeGen
  alias IexCode.Workflows.VariableInterpolator

  # ============================================================================
  # SCENARIO 1: BOUNDARY INPUTS
  # ============================================================================

  describe "Scenario 1: Boundary inputs" do
    test "handles empty lists, nil, and empty maps gracefully without crashing" do
      # Test SourceGraph.build with diverse empty variations
      empty_variants = [
        [],
        nil,
        %{},
        %{"citations" => []},
        %{citations: []},
        %{"citations" => nil},
        %{citations: nil},
        "invalid_type",
        123
      ]

      for variant <- empty_variants do
        graph = SourceGraph.build(variant)

        assert is_map(graph), "Expected map from SourceGraph.build for #{inspect(variant)}"
        assert graph.nodes == []
        assert graph.edges == []
        assert graph.citations == []
        assert is_map(graph.trust_ratings)
        assert graph.metrics.total_nodes == 0
        assert graph.metrics.total_edges == 0
        assert graph.metrics.average_trust == 0.0
        assert graph.metrics.edge_density == 0.0
        assert graph.metrics.authority_distribution == %{}
      end

      # Test ConflictResolver.resolve with diverse empty variations
      for variant <- empty_variants do
        resolution = ConflictResolver.resolve(variant)

        assert is_map(resolution),
               "Expected map from ConflictResolver.resolve for #{inspect(variant)}"

        assert resolution.conflicts == []
        assert resolution.claims == []
        assert resolution.summary.total_claims == 0
        assert resolution.summary.total_conflicts == 0
        assert resolution.summary.verified_count == 0
        assert resolution.summary.consensus_count == 0
        assert resolution.summary.disputed_count == 0
        assert is_binary(resolution.recommended_action)
        assert resolution.recommended_action != ""
      end
    end

    test "handles single source without division-by-zero, negative density, or self-contradictions" do
      single_source = %{
        "id" => "hex-kernel",
        "url" => "https://hexdocs.pm/elixir/Kernel.html",
        "title" => "Kernel — Elixir HexDocs",
        "snippet" =>
          "Core standard library functions, macros, and operators for Elixir. Fully supported and recommended.",
        "trust_score" => 0.98,
        "relevance_score" => 0.95
      }

      graph = SourceGraph.build([single_source], query: "Elixir Kernel")

      # Single node verification
      assert length(graph.nodes) == 1
      node = List.first(graph.nodes)
      assert node.id == "hex-kernel"
      assert node.authority_category == :official_docs
      assert node.degree == 0
      assert node.corroboration_count == 0

      # Edge metrics (ensure no divide-by-zero on n*(n-1))
      assert graph.edges == []
      assert graph.metrics.total_nodes == 1
      assert graph.metrics.total_edges == 0
      assert graph.metrics.edge_density == 0.0
      assert graph.metrics.average_trust == node.trust_score

      # Citations output
      assert length(graph.citations) == 1
      citation = List.first(graph.citations)
      assert citation["domain"] == "hexdocs.pm"
      assert citation["degree"] == 0

      # Conflict audit: a single source cannot contradict itself
      resolution = ConflictResolver.resolve([single_source], query: "Elixir Kernel")
      assert resolution.conflicts == []
      assert resolution.summary.total_conflicts == 0
      assert resolution.summary.total_claims >= 1
      assert String.contains?(resolution.recommended_action, "consistent alignment")
    end

    test "handles 60+ sources with dense cross-links, cyclic references, and high connectivity" do
      # Construct 60 diverse sources spanning all authority categories
      categories_data = [
        # 15 Official docs
        for i <- 1..15 do
          %{
            "id" => "official-#{i}",
            "url" => "https://hexdocs.pm/elixir/Module_#{i}.html",
            "title" => "Official Module #{i} Documentation",
            "snippet" =>
              "Official supervision and concurrency guidelines for Module #{i}. Cites https://elixir-lang.org/docs and github.com/elixir-lang/elixir for verification.",
            "published_at" => "2026-01-15"
          }
        end,
        # 10 Academic papers
        for i <- 1..10 do
          %{
            "id" => "academic-#{i}",
            "url" => "https://arxiv.org/abs/260#{i}.12345",
            "title" => "Formal Verification of Actor Supervision Systems #{i}",
            "snippet" =>
              "Academic analysis of fault tolerance, actor supervision trees, and memory bounds in distributed runtimes.",
            "published_at" => "2025-11-20"
          }
        end,
        # 10 Tech registries
        for i <- 1..10 do
          %{
            "id" => "registry-#{i}",
            "url" => "https://github.com/org/repo-#{i}",
            "title" => "Production Supervision Implementation #{i}",
            "snippet" =>
              "Open-source repository implementing OTP supervision, worker pools, and telemetry metrics.",
            "published_at" => "2026-03-01"
          }
        end,
        # 15 Community articles
        for i <- 1..15 do
          %{
            "id" => "community-#{i}",
            "url" => "https://medium.com/elixir-posts/post-#{i}",
            "title" => "Community Guide to Supervision #{i}",
            "snippet" =>
              "Hands-on tutorial discussing GenServer patterns, DynamicSupervisor restart policies, and hexdocs.pm references.",
            "published_at" => "2026-02-10"
          }
        end,
        # 5 General domains
        for i <- 1..5 do
          %{
            "id" => "general-#{i}",
            "url" => "https://techblog-#{i}.com/architecture",
            "title" => "Software Architecture Notes #{i}",
            "snippet" => "General notes on distributed systems, supervision, and resilience."
          }
        end,
        # 5 Insecure / Suspicious domains
        for i <- 1..5 do
          %{
            "id" => "suspicious-#{i}",
            "url" => "http://quick-hacks-#{i}.xyz/concurrency",
            "title" => "Suspicious Hacks #{i}",
            "snippet" => "Fast concurrency shortcuts without supervision."
          }
        end
      ]

      sources = List.flatten(categories_data)
      assert length(sources) == 60

      start_time = System.monotonic_time(:millisecond)
      graph = SourceGraph.build(sources, query: "OTP supervision architecture")
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Must finish within reasonable time (well under 2000ms)
      assert elapsed_ms < 2000, "Graph construction took too long: #{elapsed_ms}ms"

      # Verify all 60 nodes preserved
      assert length(graph.nodes) == 60
      assert graph.metrics.total_nodes == 60

      # Verify edge connectivity
      assert length(graph.edges) > 50
      assert graph.metrics.total_edges == length(graph.edges)
      assert graph.metrics.edge_density > 0.0
      assert graph.metrics.edge_density <= 1.0

      # Verify average trust within bounds
      assert graph.metrics.average_trust >= 0.05
      assert graph.metrics.average_trust <= 0.99

      # Verify authority distribution sums to exactly 60
      distribution_sum =
        graph.metrics.authority_distribution
        |> Map.values()
        |> Enum.sum()

      assert distribution_sum == 60

      # Verify all nodes have non-negative degrees and corroboration counts
      assert Enum.all?(graph.nodes, fn node ->
               node.degree >= 0 and node.corroboration_count >= 0
             end)

      # Verify edge relationships are valid
      valid_relationships = [:corroborates, :contradicts, :co_domain, :cross_reference]

      assert Enum.all?(graph.edges, fn edge ->
               edge.relationship in valid_relationships and
                 edge.weight >= 0.0 and edge.weight <= 1.0 and
                 is_binary(edge.source) and is_binary(edge.target)
             end)

      # Verify ConflictResolver can handle 60 sources cleanly
      resolution = ConflictResolver.resolve(sources, query: "OTP supervision architecture")
      assert resolution.summary.total_claims > 0
      assert is_binary(resolution.recommended_action)
    end
  end

  # ============================================================================
  # SCENARIO 2: TRUST SCORE CLAMPING
  # ============================================================================

  describe "Scenario 2: Trust score clamping" do
    test "strictly clamps trust scores within 0.05 <= trust <= 0.99 under any input, missing URL, or bizarre scheme" do
      adversarial_urls = [
        # Empty and nullish
        "",
        "   ",
        nil,
        # Bizarre / unsupported URI schemes
        "ftp://hexdocs.pm/elixir/Kernel.html",
        "sftp://secure-transfer.org/file.tar.gz",
        "file:///etc/passwd",
        "file:///c:/windows/system32/cmd.exe",
        "gopher://gopher.floodgap.com/1/",
        "javascript:alert(document.domain)",
        "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
        "ws://echo.websocket.org",
        "wss://secure.websocket.org",
        "mailto:security@elixir-lang.org",
        "custom-protocol://isolated-sandbox/entry",
        # Malformed URLs
        "://malformed-url.com",
        "https://",
        "http://",
        "http:///",
        "https://?only_query=1",
        "http://#only_fragment",
        "   https://hexdocs.pm/padded   ",
        # Suspicious TLDs with insecure HTTP
        "http://malicious-tracker.xyz",
        "http://phishing-bank.top",
        "http://scam-giveaway.buzz",
        "http://free-crypto.click",
        "http://dark-web.loan",
        "http://fake-registry.work",
        # Suspicious TLDs with HTTPS
        "https://malicious-tracker.xyz",
        "https://phishing-bank.top",
        # Academic and gov with insecure HTTP
        "http://stanford.edu/paper",
        "http://nist.gov/guideline",
        # Highly reputable domains with HTTPS
        "https://arxiv.org/abs/2301.00000",
        "https://nist.gov/publications",
        "https://hexdocs.pm/elixir/Kernel.html",
        "https://elixir-lang.org/docs",
        "https://github.com/elixir-lang/elixir",
        # Long strings and exotic characters
        "https://example.com/" <> String.duplicate("long_path/", 50),
        "https://xn--e1afmkfd.xn--p1ai/unicode"
      ]

      for url <- adversarial_urls do
        # Test standard trust calculation
        score = SourceGraph.calculate_trust(url)

        assert is_float(score),
               "Expected float score for #{inspect(url)}, got #{inspect(score)}"

        assert score >= 0.05,
               "Trust score #{score} fell below lower bound 0.05 for #{inspect(url)}"

        assert score <= 0.99,
               "Trust score #{score} exceeded upper bound 0.99 for #{inspect(url)}"

        # Test with excessive provider corroboration bonus (potential overflow)
        over_boosted = SourceGraph.calculate_trust(url, providers_count: 50)
        assert is_float(over_boosted)

        assert over_boosted >= 0.05 and over_boosted <= 0.99,
               "Boosted score #{over_boosted} violated [0.05, 0.99] bounds for #{inspect(url)}"
      end
    end

    test "strictly enforces 0.05 <= trust <= 0.99 in SourceGraph.build even with explicit adversarial trust scores" do
      adversarial_nodes = [
        # Explicit out-of-bounds scores
        %{"url" => "https://example.com/1", "trust_score" => -999.0},
        %{"url" => "https://example.com/2", "trust_score" => -0.5},
        %{"url" => "https://example.com/3", "trust_score" => 0.0},
        %{"url" => "https://example.com/4", "trust_score" => 0.01},
        %{"url" => "https://example.com/5", "trust_score" => 1.0},
        %{"url" => "https://example.com/6", "trust_score" => 1.05},
        %{"url" => "https://example.com/7", "trust_score" => 999.99},
        # Non-numeric explicit scores
        %{"url" => "https://example.com/8", "trust_score" => "not_a_number"},
        %{"url" => "https://example.com/9", "trust_score" => nil},
        # Atom keys
        %{url: "https://example.com/10", trust_score: -10.0},
        %{url: "https://example.com/11", trust_score: 500.0}
      ]

      graph = SourceGraph.build(adversarial_nodes)

      for node <- graph.nodes do
        assert is_float(node.trust_score)

        assert node.trust_score >= 0.05,
               "Node #{node.id} trust score #{node.trust_score} is < 0.05"

        assert node.trust_score <= 0.99,
               "Node #{node.id} trust score #{node.trust_score} is > 0.99"

        assert node.trust_tier in [:high, :medium, :low]
      end

      for {_domain, rating} <- graph.trust_ratings do
        assert is_float(rating.average_trust)
        assert rating.average_trust >= 0.05
        assert rating.average_trust <= 0.99
      end
    end
  end

  # ============================================================================
  # SCENARIO 3: CONTRADICTION IDENTIFICATION
  # ============================================================================

  describe "Scenario 3: Contradiction identification" do
    test "reliably identifies true polar opposite claims on identical topics" do
      # Case A: OTP Task.Supervisor (recommended vs avoid/deprecated)
      sources_a = [
        %{
          "id" => "doc-a1",
          "url" => "https://hexdocs.pm/elixir/Task.Supervisor.html",
          "title" => "Task.Supervisor Guide",
          "snippet" =>
            "Task.Supervisor is the recommended, essential, and safe standard idiom for concurrent tasks.",
          "trust_score" => 0.98
        },
        %{
          "id" => "doc-a2",
          "url" => "https://unverified-blog.xyz/post",
          "title" => "Task Pitfalls",
          "snippet" =>
            "Task.Supervisor is deprecated, unsafe, and prohibited in production; avoid Task.Supervisor.",
          "trust_score" => 0.50
        }
      ]

      result_a = ConflictResolver.resolve(sources_a, query: "Task.Supervisor")
      assert result_a.summary.total_conflicts >= 1
      conflict_a = List.first(result_a.conflicts)
      assert conflict_a.claim_a.polarity != conflict_a.claim_b.polarity

      # Case B: DynamicSupervisor vs Task.async (explicit architectural divergence)
      sources_b = [
        %{
          "id" => "arch-b1",
          "url" => "https://hexdocs.pm/elixir/DynamicSupervisor.html",
          "title" => "DynamicSupervisor Specification",
          "snippet" =>
            "DynamicSupervisor is the optimal, supported, and resilient architecture for worker lifecycles.",
          "trust_score" => 0.95
        },
        %{
          "id" => "arch-b2",
          "url" => "https://community-blog.com/tasks",
          "title" => "Async Everything",
          "snippet" =>
            "Avoid DynamicSupervisor; Task.async is simpler and optimal without supervision overhead.",
          "trust_score" => 0.65
        }
      ]

      result_b = ConflictResolver.resolve(sources_b, query: "DynamicSupervisor worker lifecycles")
      assert result_b.summary.total_conflicts >= 1
      conflict_b = List.first(result_b.conflicts)
      assert conflict_b != nil

      # Case C: Elixir version compatibility
      sources_c = [
        %{
          "id" => "ver-c1",
          "url" => "https://hexdocs.pm/elixir/v1.18",
          "title" => "Elixir v1.18 Features",
          "snippet" => "Type inference is supported and standard in Elixir v1.18 releases.",
          "trust_score" => 0.98
        },
        %{
          "id" => "ver-c2",
          "url" => "https://outdated-forum.com/v1.18",
          "title" => "v1.18 Rumors",
          "snippet" =>
            "Type checking is unsupported, broken, and deprecated in Elixir v1.18 releases.",
          "trust_score" => 0.55
        }
      ]

      result_c = ConflictResolver.resolve(sources_c, query: "Elixir v1.18 type system")
      assert result_c.summary.total_conflicts >= 1
      conflict_c = List.first(result_c.conflicts)

      assert conflict_c.claim_a.statement_type == :version or
               conflict_c.claim_b.statement_type == :version
    end

    test "strictly rejects false positives for non-contradictory, complementary claims on identical topics" do
      # Case A: Complementary GenServer callbacks (both positive/neutral, no contradiction)
      complementary_sources = [
        %{
          "id" => "gen-1",
          "url" => "https://hexdocs.pm/elixir/GenServer.html#handle_call/3",
          "title" => "GenServer handle_call",
          "snippet" =>
            "GenServer handle_call is the standard callback for synchronous request-response messages.",
          "trust_score" => 0.98
        },
        %{
          "id" => "gen-2",
          "url" => "https://hexdocs.pm/elixir/GenServer.html#handle_cast/2",
          "title" => "GenServer handle_cast",
          "snippet" =>
            "GenServer handle_cast is the standard callback for asynchronous fire-and-forget message processing.",
          "trust_score" => 0.98
        }
      ]

      result_gen =
        ConflictResolver.resolve(complementary_sources, query: "GenServer callback idioms")

      assert result_gen.summary.total_conflicts == 0,
             "Falsely identified conflict between complementary GenServer callbacks: #{inspect(result_gen.conflicts)}"

      assert result_gen.conflicts == []

      # Case B: Ecto changesets and queries (both valid architectural components)
      ecto_sources = [
        %{
          "id" => "ecto-1",
          "url" => "https://hexdocs.pm/ecto/Ecto.Changeset.html",
          "title" => "Ecto.Changeset Documentation",
          "snippet" =>
            "Changesets provide validation and data casting before database insertion.",
          "trust_score" => 0.96
        },
        %{
          "id" => "ecto-2",
          "url" => "https://hexdocs.pm/ecto/Ecto.Query.html",
          "title" => "Ecto.Query Documentation",
          "snippet" =>
            "Queries compose composable database statements with compile-time type safety.",
          "trust_score" => 0.96
        }
      ]

      result_ecto = ConflictResolver.resolve(ecto_sources, query: "Ecto architecture")

      assert result_ecto.summary.total_conflicts == 0,
             "Falsely identified conflict between complementary Ecto features: #{inspect(result_ecto.conflicts)}"
    end

    test "strictly rejects false positives for polar opposite statements on completely unrelated topics" do
      # One source has positive words on LiveView; the other has strong negative words on SQL injection
      unrelated_sources = [
        %{
          "id" => "liveview-doc",
          "url" => "https://hexdocs.pm/phoenix_liveview/Phoenix.LiveView.html",
          "title" => "Phoenix LiveView Documentation",
          "snippet" =>
            "Phoenix LiveView is recommended, optimal, performant, and supported for interactive web applications.",
          "trust_score" => 0.98
        },
        %{
          "id" => "security-advisory",
          "url" => "https://cisa.gov/resources/sql-injection",
          "title" => "SQL Injection Prevention",
          "snippet" =>
            "Unsanitized database queries are unsafe, broken, prohibited, and vulnerable to catastrophic exploits.",
          "trust_score" => 0.95
        }
      ]

      result_unrelated =
        ConflictResolver.resolve(unrelated_sources, query: "Elixir Fullstack Architecture")

      assert result_unrelated.summary.total_conflicts == 0,
             "Falsely flagged unrelated statements as contradictory: #{inspect(result_unrelated.conflicts)}"

      assert result_unrelated.conflicts == []
    end
  end

  # ============================================================================
  # SCENARIO 4: ARBITRATION CONFIDENCE
  # ============================================================================

  describe "Scenario 4: Arbitration confidence" do
    test "guarantees official documentation (.hexdocs.pm) defeats unverified forum claims, producing :verified badge" do
      sources = [
        %{
          "id" => "src-official-registry",
          "url" => "https://hexdocs.pm/elixir/Registry.html",
          "domain" => "hexdocs.pm",
          "title" => "Registry — Elixir HexDocs",
          "snippet" =>
            "Registry is the official, recommended, and verified mechanism for decentralized local process registration in Elixir clusters.",
          "trust_score" => 0.98,
          "relevance_score" => 0.95
        },
        %{
          "id" => "src-forum-rumor",
          "url" => "http://unverified-hack-forum.xyz/thread/884",
          "domain" => "unverified-hack-forum.xyz",
          "title" => "Avoid Registry Hacks",
          "snippet" =>
            "Registry is deprecated, unsupported, and broken; avoid Registry and rely on global named processes instead.",
          "trust_score" => 0.40,
          "relevance_score" => 0.80
        }
      ]

      result = ConflictResolver.resolve(sources, query: "Registry process registration")

      # Must detect conflict and award :verified status
      assert result.summary.total_conflicts >= 1
      assert result.summary.verified_count >= 1

      verified_conflict = Enum.find(result.conflicts, &(&1.status == :verified))
      assert verified_conflict != nil, "Expected at least one :verified conflict in results"

      # Verify badge attributes
      assert verified_conflict.badge_label == "VERIFIED"
      assert verified_conflict.badge_color == "emerald"

      # Winning claim must be the hexdocs source
      assert verified_conflict.winning_claim != nil
      assert verified_conflict.winning_claim.domain == "hexdocs.pm"
      assert verified_conflict.winning_claim.trust_score >= 0.88
      assert verified_conflict.winning_claim.polarity == :positive

      # Confidence ratio must show overwhelming advantage
      assert verified_conflict.confidence_ratio >= 0.75

      # Rationale must cite authoritative domain
      assert String.contains?(verified_conflict.rationale, "hexdocs.pm")
      assert String.contains?(verified_conflict.rationale, "authoritative source")

      # Recommended action must enforce mandatory constraint
      assert String.contains?(result.recommended_action, "Mandatory Constraint")
      assert String.contains?(result.recommended_action, "Adopt verified specification")
    end

    test "assigns :disputed badge with winning_claim: nil when two high-authority sources diverge" do
      sources = [
        %{
          "id" => "src-broadway-auth",
          "url" => "https://hexdocs.pm/broadway/Broadway.html",
          "domain" => "hexdocs.pm",
          "title" => "Broadway Documentation",
          "snippet" =>
            "Broadway is recommended and optimal for multi-stage streaming ingestion pipelines.",
          "trust_score" => 0.96,
          "relevance_score" => 0.92
        },
        %{
          "id" => "src-genstage-auth",
          "url" => "https://elixir-lang.org/blog/genstage-patterns",
          "domain" => "elixir-lang.org",
          "title" => "GenStage Specification",
          "snippet" =>
            "Avoid Broadway for lightweight events due to batching overhead; GenStage is the optimal lower-level foundation.",
          "trust_score" => 0.95,
          "relevance_score" => 0.90
        }
      ]

      result = ConflictResolver.resolve(sources, query: "Broadway vs GenStage pipeline")

      assert result.summary.total_conflicts >= 1
      assert result.summary.disputed_count >= 1

      disputed_conflict = Enum.find(result.conflicts, &(&1.status == :disputed))
      assert disputed_conflict != nil
      assert disputed_conflict.badge_label == "DISPUTED"
      assert disputed_conflict.badge_color == "amber"
      assert disputed_conflict.winning_claim == nil
      assert String.contains?(disputed_conflict.rationale, "Disputed architectural trade-off")
      assert String.contains?(result.recommended_action, "Caution")
    end
  end

  # ============================================================================
  # SCENARIO 5: CHAINING ROBUSTNESS
  # ============================================================================

  describe "Scenario 5: Chaining robustness" do
    test "safely injects research outputs with special characters, multiline markdown, and quotes into SwarmCodeGen" do
      # Adversarial research output payload containing quotes, emojis, backticks, liquid syntax, and html tags
      adversarial_research = %{
        "query" =>
          "Phoenix LiveView & \"Deep Security\" / 'Sandbox' {{variable_injection}} --flag=true <script>alert('xss')</script>",
        "report" => """
        # Deep Research Report: Phoenix LiveView & "Deep Security"

        **Special Chars**: !@#$%^&*()_+=-`~[]\\{}|;':",./<>?
        **Emojis**: 🚀 🛡️ ⚡ ⚠️ 🔒

        ```elixir
        defmodule SecureSandbox do
          @doc \"\"\"
          Runs command safely with quotes: \"echo 'hello world'\"
          \"\"\"
          def execute(cmd, args) do
            System.cmd(cmd, args, env: %{"SAFE" => "true"})
          end
        end
        ```

        | Feature | Status | Notes |
        |---------|--------|-------|
        | Sandbox | Active | Enforces `System.cmd/3` |
        """,
        "verified_claims" => [
          %{
            "recommendation" =>
              "Adopt verified specification: Enforce `System.cmd/3` with sanitized arg lists [\"-c\", \"echo \\\"test\\\"\"]; never raw `eval`."
          },
          %{
            "recommendation" =>
              "Adopt verified specification: Sanitize all {{template_tags}} & <script> tags before HTML rendering."
          }
        ],
        "disputed_claims" => [
          %{
            "rationale" =>
              "Disputed trade-off: Using `Port.open/2` vs `System.cmd/3`; caution with `{\"escaped\": \"quotes\"}` and #{} variable interpolation."
          }
        ],
        "recommended_action" => """
        - Mandatory Constraint: Enforce `System.cmd/3` with [\"-c\", \"echo \\\"test\\\"\"]
        - Mandatory Constraint: Sanitize {{template_tags}}
        - Caution (Architectural Trade-Off): Port.open/2 vs System.cmd/3
        """
      }

      # Build context simulating completed upstream deep_research step
      context = %{
        "steps" => %{
          "step_deep_research" => %{
            "id" => "step-research-1",
            "kind" => "deep_research",
            "state" => "completed",
            "output" => adversarial_research
          }
        }
      }

      # Downstream swarm_code_gen step definition
      code_step = %{
        "id" => "step-swarm-1",
        "title" => "Synthesize Secure Sandbox Module",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" =>
            "Implement secure sandbox module for \"Production\" environment with {{custom_var}}.",
          "target_files" => ["lib/iex_code/secure_sandbox.ex"]
        }
      }

      assert {:ok, code_output} = SwarmCodeGen.execute(code_step, context)

      # Verify chaining state
      assert code_output["research_chained"] == true
      assert code_output["chained_research_query"] == adversarial_research["query"]

      augmented_prompt = code_output["augmented_prompt"]

      # Verify string integrity: valid UTF-8, no crashed formatting
      assert is_binary(augmented_prompt)
      assert String.valid?(augmented_prompt)

      # Verify original prompt is preserved
      assert String.contains?(
               augmented_prompt,
               "Implement secure sandbox module for \"Production\" environment with {{custom_var}}."
             )

      # Verify research directives header was added
      assert String.contains?(
               augmented_prompt,
               "[RESEARCH ARCHITECTURE DIRECTIVES & VERIFIED CONSTRAINTS]"
             )

      # Verify quotes and special characters were preserved intact without escaping breakage
      assert String.contains?(
               augmented_prompt,
               "Phoenix LiveView & \"Deep Security\" / 'Sandbox' {{variable_injection}}"
             )

      assert String.contains?(
               augmented_prompt,
               "Enforce `System.cmd/3` with sanitized arg lists [\"-c\", \"echo \\\"test\\\"\"]"
             )

      assert String.contains?(
               augmented_prompt,
               "Sanitize all {{template_tags}} & <script> tags"
             )

      assert String.contains?(
               augmented_prompt,
               "Using `Port.open/2` vs `System.cmd/3`; caution with `{\"escaped\": \"quotes\"}` and #{} variable interpolation"
             )

      # Verify patches were generated cleanly
      assert length(code_output["patches"]) == 1
      patch = List.first(code_output["patches"])
      assert patch["file"] == "lib/iex_code/secure_sandbox.ex"
    end

    test "safely handles variable interpolation chaining without template delimiter breakage" do
      research_output = %{
        "query" => "Fault-Tolerant DynamicSupervisor Architecture",
        "report" => """
        # Architecture Report
        Use DynamicSupervisor with `max_restarts: 3`.
        Caution with `{{not_a_variable}}` literal brackets.
        """,
        "verified_claims" => [
          %{"recommendation" => "Adopt verified specification: Use DynamicSupervisor."}
        ],
        "disputed_claims" => []
      }

      context = %{
        "steps" => %{
          "research_step" => %{
            "kind" => "deep_research",
            "state" => "completed",
            "output" => research_output
          }
        }
      }

      raw_step = %{
        "id" => "code-step",
        "kind" => "swarm_code_gen",
        "params" => %{
          "prompt" => "Synthesize code based on {{steps.research_step.output.query}}",
          "context_summary" => "{{steps.research_step.output.report}}"
        }
      }

      assert {:ok, interpolated_step} = VariableInterpolator.interpolate(raw_step, context)

      assert interpolated_step["params"]["prompt"] ==
               "Synthesize code based on Fault-Tolerant DynamicSupervisor Architecture"

      assert String.contains?(
               interpolated_step["params"]["context_summary"],
               "Caution with `{{not_a_variable}}` literal brackets."
             )

      assert {:ok, code_output} = SwarmCodeGen.execute(interpolated_step, context)
      assert code_output["research_chained"] == true
      assert is_binary(code_output["augmented_prompt"])
      assert String.valid?(code_output["augmented_prompt"])
    end
  end
end
