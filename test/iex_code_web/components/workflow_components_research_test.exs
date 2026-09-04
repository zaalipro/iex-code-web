defmodule IexCodeWeb.Components.WorkflowComponentsResearchTest do
  @moduledoc """
  Component tests for Milestone 3 Deep Research UI upgrades in WorkflowComponents:
  - Visual Source Cards with trust meters and relevance pills
  - Dispute & Contradiction Badges with verified, consensus, and disputed chips
  - 1-Click Research Chaining buttons
  """

  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkflowComponents
  alias IexCode.Workflows.WorkflowRun

  describe "research artifacts rendering in live_step_inspector" do
    test "renders Visual Source Cards, trust meter bars, relevance pills, and external links" do
      step = %{
        "key" => "research_node",
        "title" => "Deep Research",
        "kind" => "deep_research"
      }

      citations = [
        %{
          "title" => "Elixir Kernel Standards",
          "url" => "https://hexdocs.pm/elixir/Kernel.html",
          "domain" => "hexdocs.pm",
          "trust_score" => 0.98,
          "relevance_score" => 0.92,
          "authority_category" => "official_docs",
          "ssl" => true,
          "corroboration_count" => 3,
          "snippet" => "Core idioms and OTP supervision patterns for high-availability systems."
        },
        %{
          "title" => "Community Performance Trade-offs",
          "url" => "https://medium.com/elixir-tips/memory",
          "domain" => "medium.com",
          "trust_score" => 0.72,
          "relevance_score" => 0.78,
          "authority_category" => "community",
          "ssl" => true,
          "corroboration_count" => 1,
          "snippet" => "Memory leak considerations when using unlinked Task processes."
        }
      ]

      output = %{
        "query" => "Elixir Concurrency",
        "report" => "# Deep Research Report\nExecutive summary...",
        "citations" => citations
      }

      run = %WorkflowRun{
        id: "run-m3-research",
        status: "completed",
        step_states: %{
          "research_node" => %{
            "status" => "completed",
            "output" => output
          }
        }
      }

      html =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :artifacts
        )

      # 1. Section headers
      assert html =~ "Visual Citations &amp; Source Graph" or
               html =~ "Visual Citations & Source Graph"

      assert html =~ "2 sources evaluated"

      # 2. Domain category and SSL
      assert html =~ "hexdocs.pm"
      assert html =~ "official_docs"
      assert html =~ "medium.com"
      assert html =~ "community"
      assert html =~ "HTTPS"

      # 3. Trust meter percentages and relevance pills
      assert html =~ "98% Trust"
      assert html =~ "72% Trust"
      assert html =~ "92% Rel"
      assert html =~ "78% Rel"
      assert html =~ "3 edges"

      # 4. Outbound link attributes
      assert html =~ ~s(href="https://hexdocs.pm/elixir/Kernel.html")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "renders Dispute & Contradiction Badges panel with verified, consensus, and disputed chips" do
      step = %{
        "key" => "audit_step",
        "title" => "Evidence Audit",
        "kind" => "deep_research"
      }

      conflicts = [
        %{
          id: "conf-1",
          topic: "Task.Supervisor vs Task.async",
          status: :verified,
          rationale: "Official documentation requires Task.Supervisor to avoid process leaks.",
          claim_a: %{domain: "hexdocs.pm", text: "Always spawn supervised tasks."},
          claim_b: %{domain: "randomblog.com", text: "Task.async without supervision is fine."}
        },
        %{
          id: "conf-2",
          topic: "PartitionSupervisor scaling",
          status: :consensus,
          rationale: "Widespread convention adopts PartitionSupervisor for heavy traffic.",
          claim_a: %{domain: "github.com", text: "Use PartitionSupervisor for scale."},
          claim_b: %{domain: "dev.to", text: "Simple Registry is adequate."}
        },
        %{
          id: "conf-3",
          topic: "Broadway vs GenStage",
          status: :disputed,
          rationale: "Legitimate architectural trade-off between batching and low latency.",
          claim_a: %{domain: "hexdocs.pm", text: "Broadway is optimal for batching."},
          claim_b: %{domain: "elixir-lang.org", text: "GenStage is optimal for low latency."}
        }
      ]

      output = %{
        "query" => "Architecture Audit",
        "report" => "# Audit Report",
        "citations" => [
          %{"title" => "HexDocs", "url" => "https://hexdocs.pm", "trust_score" => 0.98}
        ],
        "conflicts" => conflicts
      }

      run = %WorkflowRun{
        id: "run-m3-conflicts",
        status: "completed",
        step_states: %{
          "audit_step" => %{
            "status" => "completed",
            "output" => output
          }
        }
      }

      html =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :artifacts
        )

      # Header and summary count chips
      assert html =~ "Evidence Audit &amp; Conflict Resolution" or
               html =~ "Evidence Audit & Conflict Resolution"

      assert html =~ "1 VERIFIED"
      assert html =~ "1 CONSENSUS"
      assert html =~ "1 DISPUTED"

      # Conflict details and side-by-side claim comparison
      assert html =~ "Task.Supervisor vs Task.async"
      assert html =~ "PartitionSupervisor scaling"
      assert html =~ "Broadway vs GenStage"
      assert html =~ "Always spawn supervised tasks."
      assert html =~ "Broadway is optimal for batching."
      assert html =~ "GenStage is optimal for low latency."
      assert html =~ "Resolution:"
    end

    test "renders 1-click Chaining buttons for workflow creation and swarm code gen" do
      step = %{
        "key" => "research_chain",
        "title" => "Research Step",
        "kind" => "deep_research"
      }

      output = %{
        "query" => "ETS Cache Layer",
        "report" => "# Research on ETS Cache",
        "citations" => [
          %{
            "title" => "ETS HexDocs",
            "url" => "https://hexdocs.pm/elixir/ets.html",
            "trust_score" => 0.98
          }
        ]
      }

      run = %WorkflowRun{
        id: "run-m3-chain",
        status: "completed",
        step_states: %{
          "research_chain" => %{
            "status" => "completed",
            "output" => output
          }
        }
      }

      html =
        render_component(&WorkflowComponents.step_inspector/1,
          step: step,
          run: run,
          active_tab: :artifacts
        )

      # 1-Click Chaining buttons
      assert html =~ "Create Workflow from Research"

      assert html =~ "create-workflow?research_query=ETS+Cache+Layer" or
               html =~ "create-workflow?research_query=ETS%20Cache%20Layer"

      assert html =~ "Chain to Swarm Code Gen"
      assert html =~ "phx-click=\"chain_to_swarm\""
      assert html =~ "phx-value-query=\"ETS Cache Layer\""
    end
  end
end
