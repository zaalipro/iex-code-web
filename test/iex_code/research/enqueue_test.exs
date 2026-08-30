defmodule IexCode.Research.EnqueueTest do
  use IexCode.DataCase, async: false

  alias IexCode.Research.{Launch, Results}
  alias IexCode.Runs.RunDispatcher
  alias IexCode.{Projects, Runs, Sessions, Settings}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-research-enqueue-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, project} = Projects.create_project(%{name: "Research enqueue", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Research"})
    %{project: project, session: session}
  end

  test "queues an exact immutable level policy with conservative budgets", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Compare asynchronous research schedulers",
      metadata: %{"source" => "test"}
    }

    assert {:ok, run} =
             RunDispatcher.enqueue_research(
               attrs,
               strict_research(context, %{
                 level: "medium",
                 ranked_providers: ["duckduckgo"],
                 max_sources: 6
               })
             )

    assert run.kind == "deep_research"
    assert run.mode == "research"
    assert run.execution_engine == "dag_v1"
    assert run.max_attempts == 1
    assert run.token_budget > 0
    assert run.cost_budget_cents > 0
    assert run.time_budget_ms == 20 * 60_000
    assert run.metadata["source"] == "test"
    assert run.metadata["projection"] == "dag_v1"

    assert run.metadata["research"]["level_policy"] == %{
             "level" => "medium",
             "multistep_rounds" => 2,
             "lead_per_step" => 1,
             "async_subagents" => 3
           }

    steps = Runs.list_steps(run)
    assert Enum.count(steps, &(&1.kind == "research_plan")) == 2
    assert Enum.all?(steps, &(&1.effect_class in ~w(pure provider)))

    assert Enum.all?(Enum.filter(steps, &(&1.kind == "research_plan")), fn step ->
             step.params["max_queries"] == 3
           end)

    assert Enum.all?(Enum.filter(steps, &(&1.kind == "research_ranked_search")), fn step ->
             step.params["max_search_calls"] == 3
           end)

    result = Results.get_by_run(run)
    assert is_integer(result.id)
    assert result.level == "medium"
    assert result.status == "queued"
  end

  test "canonical producer overwrites projection while preserving metadata and idempotency",
       context do
    request_key = Ecto.UUID.generate()

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Trusted Research projection",
      request_key: request_key,
      metadata: %{
        "source" => "direct_dispatcher",
        "projection" => "legacy_v1",
        "audit" => %{"origin" => "trusted"}
      }
    }

    research =
      strict_research(context, %{level: "low", ranked_providers: ["duckduckgo"], max_sources: 5})

    assert {:ok, first} = RunDispatcher.enqueue_research(attrs, research)
    assert {:ok, duplicate} = RunDispatcher.enqueue_research(attrs, research)
    assert duplicate.id == first.id
    assert first.metadata["projection"] == "dag_v1"
    assert first.metadata["source"] == "direct_dispatcher"
    assert first.metadata["audit"] == %{"origin" => "trusted"}
    assert first.metadata["research"]["level"] == "low"
    assert Results.get_by_run(first).id == Results.get_by_run(duplicate).id
  end

  test "canonical producer removes atom and mixed projection aliases before stamping marker",
       context do
    request_key = Ecto.UUID.generate()

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Canonical mixed marker",
      request_key: request_key,
      metadata: %{
        :projection => "legacy_v1",
        :research => %{:projection => "legacy_v1", "level" => "low"},
        "projection" => "legacy_v1",
        "source" => "trusted"
      }
    }

    research =
      strict_research(context, %{level: "low", ranked_providers: ["duckduckgo"], max_sources: 5})

    assert {:ok, first} = RunDispatcher.enqueue_research(attrs, research)
    assert {:ok, duplicate} = RunDispatcher.enqueue_research(attrs, research)
    assert duplicate.id == first.id
    assert first.metadata["projection"] == "dag_v1"
    refute Map.has_key?(first.metadata, :projection)
    refute Map.has_key?(first.metadata, :research)
    assert first.metadata["research"]["projection"] == nil
    assert first.metadata["research"]["level"] == "low"
  end

  test "invalid level and unavailable providers fail before inserting anything", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Must fail"
    }

    assert {:error, :invalid_research_level} =
             RunDispatcher.enqueue_research(
               attrs,
               strict_research(context, %{
                 level: "extreme",
                 ranked_providers: ["duckduckgo"],
                 max_sources: 4
               })
             )

    assert {:error, :unsupported_research_provider} =
             RunDispatcher.enqueue_research(
               attrs,
               strict_research(context, %{
                 level: "low",
                 ranked_providers: ["bing"],
                 max_sources: 4
               })
             )

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "omitted launcher limits default but out-of-range source counts fail closed", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Normalize exact research limits"
    }

    assert {:ok, defaulted} =
             RunDispatcher.enqueue_research(
               attrs,
               strict_research(context, %{
                 level: "low",
                 ranked_providers: ["duckduckgo"]
               })
             )

    assert defaulted.metadata["research"]["max_sources"] == 40
    assert defaulted.metadata["research"]["fetch_parallelism"] == 6

    default_fetch =
      defaulted
      |> Runs.list_steps()
      |> Enum.find(&(&1.kind == "research_source_fetch"))

    assert default_fetch.params["max_sources"] == 40
    assert default_fetch.params["max_parallel_fetches"] == 6

    attrs = Map.put(attrs, :objective, "Normalize invalid exact research limits")

    assert {:error, {:research_max_sources_out_of_range, %{minimum: 1, maximum: 40, value: 0}}} =
             RunDispatcher.enqueue_research(
               attrs,
               strict_research(context, %{
                 level: "low",
                 ranked_providers: ["duckduckgo"],
                 max_sources: 0,
                 fetch_parallelism: 99
               })
             )

    assert length(Runs.list_runs(session_id: context.session.id)) == 1
  end

  test "request keys are preserved and provide semantic idempotency", context do
    request_key = Ecto.UUID.generate()

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Idempotent exact research",
      request_key: request_key
    }

    research =
      strict_research(context, %{
        level: "low",
        ranked_providers: ["duckduckgo"],
        max_sources: 5
      })

    assert {:ok, first} = RunDispatcher.enqueue_research(attrs, research)
    assert {:ok, duplicate} = RunDispatcher.enqueue_research(attrs, research)
    assert duplicate.id == first.id
    assert duplicate.request_key == request_key
    assert length(Runs.list_runs(session_id: context.session.id)) == 1

    assert {:error, :request_key_conflict} =
             RunDispatcher.enqueue_research(
               %{attrs | objective: "Conflicting exact research"},
               research
             )
  end

  test "explicit impossible budgets fail before run and result allocation", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Impossible reservation",
      token_budget: 75_999,
      cost_budget_cents: 10_000
    }

    research =
      strict_research(context, %{
        level: "low",
        ranked_providers: ["duckduckgo"],
        max_sources: 5
      })

    assert {:error,
            {:research_budget_below_manifest_requirement,
             %{dimension: :tokens, provided: 75_999, required: 76_000}}} =
             RunDispatcher.enqueue_research(attrs, research)

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "accepts a bounded string-keyed launch map without mixed Ecto params", context do
    assert {:ok, run} =
             RunDispatcher.enqueue_research(
               %{
                 "project_id" => context.project.id,
                 "session_id" => context.session.id,
                 "objective" => "String-keyed research launch",
                 "metadata" => %{"source" => "external_api"}
               },
               strict_research(context, %{
                 "level" => "low",
                 "ranked_providers" => ["duckduckgo"],
                 "max_sources" => 5
               })
             )

    assert run.objective == "String-keyed research launch"
    assert run.metadata["source"] == "external_api"
    assert run.metadata["research"]["max_sources"] == 5
  end

  test "new dispatcher launches reject omitted, current, and v1 routing references", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Reject legacy routing for new work"
    }

    base = %{level: "low", ranked_providers: ["duckduckgo"], max_sources: 5}

    for research <- [
          base,
          Map.put(base, :provider_snapshot_ref, "settings://search-providers/current"),
          Map.put(
            base,
            :provider_snapshot_ref,
            "settings://research-routing/v1/" <> String.duplicate("0", 64)
          )
        ] do
      assert {:error, :trusted_provider_snapshot_required} =
               RunDispatcher.enqueue_research(attrs, research)
    end

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  defp strict_research(context, research) do
    settings = Settings.get_settings()
    ranked = Map.get(research, :ranked_providers, Map.get(research, "ranked_providers", []))
    grounded = Map.get(research, :grounded_providers, Map.get(research, "grounded_providers", []))

    reference =
      Launch.settings_snapshot_ref(settings, context.session, ranked, grounded)

    if Enum.all?(Map.keys(research), &is_binary/1),
      do: Map.put(research, "provider_snapshot_ref", reference),
      else: Map.put(research, :provider_snapshot_ref, reference)
  end
end
