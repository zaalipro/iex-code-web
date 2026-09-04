defmodule IexCode.Research.ConflictResolverTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.ConflictResolver

  describe "claim extraction" do
    test "extracts claims, detects polarity, and identifies statement types" do
      sources = [
        %{
          "url" => "https://hexdocs.pm/elixir/Kernel.html",
          "domain" => "hexdocs.pm",
          "title" => "Kernel Documentation",
          "snippet" =>
            "Kernel functions are essential, recommended, and fully supported in Elixir.",
          "trust_score" => 0.98,
          "relevance_score" => 0.90
        },
        %{
          "url" => "https://medium.com/blog/bad-advice",
          "domain" => "medium.com",
          "title" => "Outdated Patterns",
          "snippet" => "Kernel macro usage is deprecated, unsupported, and should be avoided.",
          "trust_score" => 0.60,
          "relevance_score" => 0.85
        }
      ]

      claims = ConflictResolver.extract_claims(sources, "Kernel macros")
      assert length(claims) >= 2

      [pos_claim, neg_claim] = Enum.take(claims, 2)
      assert pos_claim.polarity == :positive
      assert neg_claim.polarity == :negative
      assert pos_claim.composite_weight > neg_claim.composite_weight
    end
  end

  describe "conflict arbitration and badges" do
    test "assigns :verified badge when authoritative domain strongly outweighs dissenting claim" do
      sources = [
        %{
          "id" => "src-hexdocs",
          "url" => "https://hexdocs.pm/elixir/Task.Supervisor.html",
          "domain" => "hexdocs.pm",
          "title" => "Task.Supervisor — Elixir HexDocs",
          "snippet" =>
            "Task.Supervisor is the official, recommended, and safe way to spawn supervised concurrent tasks without memory leaks.",
          "trust_score" => 0.98,
          "relevance_score" => 0.95
        },
        %{
          "id" => "src-blog",
          "url" => "https://randomblog.xyz/elixir-tips",
          "domain" => "randomblog.xyz",
          "title" => "Quick Elixir Hacks",
          "snippet" =>
            "Task.Supervisor is unnecessary overhead; avoid Task.Supervisor and use unlinked Task.async directly everywhere.",
          "trust_score" => 0.45,
          "relevance_score" => 0.80
        }
      ]

      result = ConflictResolver.resolve(sources, query: "Task.Supervisor concurrency")

      assert result.summary.total_conflicts >= 1
      assert result.summary.verified_count >= 1

      verified_conflict = Enum.find(result.conflicts, &(&1.status == :verified))
      assert verified_conflict != nil
      assert verified_conflict.badge_label == "VERIFIED"
      assert verified_conflict.badge_color == "emerald"
      assert verified_conflict.winning_claim != nil
      assert verified_conflict.winning_claim.domain == "hexdocs.pm"
      assert verified_conflict.confidence_ratio >= 0.65
      assert String.contains?(verified_conflict.rationale, "hexdocs.pm")
      assert String.contains?(result.recommended_action, "Mandatory Constraint")
    end

    test "assigns :consensus badge when majority convention exists with acknowledged trade-offs" do
      sources = [
        %{
          "id" => "src-github",
          "url" => "https://github.com/elixir-lang/elixir",
          "domain" => "github.com",
          "title" => "Elixir OTP Supervision Conventions",
          "snippet" =>
            "PartitionSupervisor is the recommended standard convention to avoid GenServer registration bottlenecks.",
          "trust_score" => 0.88,
          "relevance_score" => 0.85
        },
        %{
          "id" => "src-community",
          "url" => "https://dev.to/elixir-dev/registry-vs-partition",
          "domain" => "dev.to",
          "title" => "Registry vs PartitionSupervisor",
          "snippet" =>
            "PartitionSupervisor is not always necessary for small clusters; Registry is simpler and avoids extra process layers.",
          "trust_score" => 0.72,
          "relevance_score" => 0.80
        }
      ]

      result = ConflictResolver.resolve(sources, query: "PartitionSupervisor scaling")

      assert result.summary.total_conflicts >= 1
      conflict = List.first(result.conflicts)
      assert conflict.status in [:consensus, :verified]
      assert conflict.winning_claim != nil

      assert String.contains?(result.recommended_action, "Convention") or
               String.contains?(result.recommended_action, "Constraint")
    end

    test "assigns :disputed badge when competing authoritative sources offer conflicting guidance" do
      sources = [
        %{
          "id" => "src-broadway",
          "url" => "https://hexdocs.pm/broadway/Broadway.html",
          "domain" => "hexdocs.pm",
          "title" => "Broadway Data Ingestion",
          "snippet" =>
            "Broadway is recommended and optimal for stream data ingestion pipelines with automated batching and acking.",
          "trust_score" => 0.95,
          "relevance_score" => 0.90
        },
        %{
          "id" => "src-genstage",
          "url" => "https://elixir-lang.org/blog/genstage",
          "domain" => "elixir-lang.org",
          "title" => "GenStage Specification",
          "snippet" =>
            "Avoid Broadway for lightweight messaging where batching overhead is prohibitive; GenStage is the optimal lower-level foundation.",
          "trust_score" => 0.95,
          "relevance_score" => 0.90
        }
      ]

      result = ConflictResolver.resolve(sources, query: "Broadway vs GenStage ingestion")

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

    test "produces clean empty resolution when no conflicts exist" do
      sources = [
        %{
          "url" => "https://hexdocs.pm/elixir/Enum.html",
          "title" => "Enum — Elixir HexDocs",
          "snippet" => "Enum provides set of algorithms for working with enumerables.",
          "trust_score" => 0.98
        }
      ]

      result = ConflictResolver.resolve(sources, query: "Enum")
      assert result.summary.total_conflicts == 0
      assert result.conflicts == []
      assert String.contains?(result.recommended_action, "consistent alignment")
    end

    test "handles nil or empty sources gracefully" do
      assert ConflictResolver.resolve(nil).summary.total_claims == 0
      assert ConflictResolver.resolve([]).summary.total_claims == 0
      assert ConflictResolver.resolve(%{"citations" => []}).summary.total_claims == 0
    end

    test "resolves contradictions on version requirements" do
      sources = [
        %{
          "url" => "https://hexdocs.pm/elixir/v1.17",
          "title" => "Elixir 1.17 Release Notes",
          "snippet" => "Type system features are supported in v1.17 and later releases.",
          "trust_score" => 0.98,
          "relevance_score" => 0.95
        },
        %{
          "url" => "https://blog.example.com/elixir-types",
          "title" => "Old Elixir types",
          "snippet" => "Type checking is unsupported in v1.17 and fails compilation.",
          "trust_score" => 0.50,
          "relevance_score" => 0.85
        }
      ]

      result = ConflictResolver.resolve(sources, query: "v1.17 type system")
      assert result.summary.total_conflicts >= 1
      assert result.summary.verified_count >= 1
    end
  end
end
