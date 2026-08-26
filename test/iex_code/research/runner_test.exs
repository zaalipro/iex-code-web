defmodule IexCode.Research.RunnerTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.Research.Runner
  alias IexCode.Repo
  alias IexCode.Runs.Run
  alias IexCode.{Projects, Runs, Sessions}

  setup do
    root = Path.join(System.tmp_dir!(), "iex-code-research-#{System.unique_integer([:positive])}")
    {:ok, project} = Projects.create_project(%{name: "Research test", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Research"})

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Research durable agent orchestration",
        kind: "analysis",
        metadata: %{
          "research" => %{
            "providers" => ["tavily", "brave"],
            "depth" => "deep",
            "max_sources" => 2
          }
        }
      })

    %{run: run, project: project, session: session}
  end

  test "persists attempt-scoped stages, evidence, cited report and progress events", %{run: run} do
    progress = fn percent, message -> send(self(), {:progress, percent, message}) end

    assert {:ok, result} =
             Runner.execute(run, progress,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert result.depth == "deep"
    assert length(result.sources) == 2
    assert result.report =~ "checkpoints [1]"
    assert result.report =~ "## Verified source index"
    assert result.report =~ "https://example.test/durable"

    assert_receive {:research_search, "Research durable agent orchestration", search_opts}
    assert search_opts[:providers] == ["tavily", "brave"]
    assert search_opts[:limit] == 2
    assert_receive {:research_synthesis, messages, system_prompt, llm_opts}
    assert inspect(messages) =~ "https://example.test/agents"
    assert system_prompt =~ "Never invent"
    assert llm_opts[:temperature] == 0.1
    assert_receive {:progress, 100, "Research report ready"}

    assert [plan_step, search_step, synthesis_step] =
             run
             |> Runs.list_steps()
             |> Enum.filter(&String.starts_with?(&1.key, "research."))

    assert plan_step.key == "research.plan"
    assert plan_step.status == "completed"
    assert search_step.key == "research.search"
    assert search_step.status == "completed"
    assert synthesis_step.key == "research.synthesize"
    assert synthesis_step.status == "completed"

    artifacts = Runs.list_artifacts(run)
    evidence = Enum.find(artifacts, &(&1.kind == "research_evidence"))
    report = Enum.find(artifacts, &(&1.kind == "research_report"))
    assert evidence.uri == "research://runs/#{run.id}/attempts/0/evidence.json"
    assert evidence.metadata["content"] =~ "Durable workers"
    assert report.uri == "research://runs/#{run.id}/attempts/0/report.md"
    assert report.metadata["content"] =~ "Verified source index"
    assert report.checksum =~ "sha256:"

    event_types = Enum.map(Runs.list_events(run), & &1.type)
    assert "research.progress" in event_types
    refute "research.failed" in event_types
  end

  test "leased execution uses worker authority and stale authority cannot create graph state", %{
    run: run
  } do
    assert {:ok, claimed} = Runs.claim_next_run("research-worker", lease_ms: 30_000)
    assert claimed.id == run.id

    authority = [
      run_lease_owner: "research-worker",
      run_attempt: claimed.attempt,
      run_lease_generation: claimed.lease_generation
    ]

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(current in Run, where: current.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lease_not_owned} =
             Runner.execute(claimed, fn _, _ -> :ok end,
               run_authority: authority,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert Runs.list_steps(claimed) == []
    assert Runs.list_artifacts(claimed) == []
    assert Enum.map(Runs.list_events(claimed), & &1.type) == ["run.created", "run.claimed"]
  end

  test "leased execution persists stages and artifacts through scoped worker APIs", %{run: run} do
    assert {:ok, claimed} = Runs.claim_next_run("research-worker", lease_ms: 30_000)
    assert claimed.id == run.id

    assert {:ok, result} =
             Runner.execute(claimed, fn _, _ -> :ok end,
               run_authority: [
                 run_lease_owner: "research-worker",
                 run_attempt: claimed.attempt,
                 run_lease_generation: claimed.lease_generation
               ],
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert result.report =~ "Verified source index"
    assert Enum.all?(Runs.list_steps(claimed), &(&1.status == "completed"))
    assert length(Runs.list_artifacts(claimed)) == 2
  end

  for {budget_name, budget_field, budget, llm_module, expected_error} <- [
        {"token", :token_budget, 2, IexCode.TestResearchTokenBudgetLlmStub,
         :token_budget_exhausted},
        {"cost", :cost_budget_cents, 2, IexCode.TestResearchCostBudgetLlmStub,
         :cost_budget_exhausted}
      ] do
    test "#{budget_name} exhaustion terminalizes the public research result under preserved lineage",
         context do
      assert {:ok, _cancelled} = Runs.cancel_unleased_run(context.run)

      attrs = %{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Budgeted deep research",
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => "medium"}}
      }

      assert {:ok, _queued} =
               Runs.create_run(Map.put(attrs, unquote(budget_field), unquote(budget)))

      assert {:ok, claimed} = Runs.claim_next_run("budget-result-worker", lease_ms: 30_000)

      result_root =
        Path.join(
          System.tmp_dir!(),
          "research-budget-result-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(result_root) end)

      assert {:error, unquote(expected_error)} =
               Runner.execute(claimed, fn _, _ -> :ok end,
                 run_authority: [
                   run_lease_owner: "budget-result-worker",
                   run_attempt: claimed.attempt,
                   run_lease_generation: claimed.lease_generation
                 ],
                 root: result_root,
                 search_module: IexCode.TestResearchSearchStub,
                 llm_module: unquote(llm_module)
               )

      assert %{status: "failed", lease_owner: "budget-result-worker"} =
               Runs.get_run!(claimed.id)

      assert %{status: "failed", completed_at: %DateTime{}} =
               IexCode.Research.Results.get_by_run(claimed)
    end
  end

  test "research result cannot become ready after parent authority expires", context do
    {:ok, _queued} =
      Runs.create_run(%{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Fence public result publication",
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => "medium"}}
      })

    # The setup analysis run is older; cancel it so the deep-research row is
    # the next claim candidate for this project.
    assert {:ok, _cancelled} = Runs.cancel_unleased_run(context.run)
    assert {:ok, claimed} = Runs.claim_next_run("result-worker", lease_ms: 30_000)

    authority = [
      lease_owner: "result-worker",
      run_attempt: claimed.attempt,
      lease_generation: claimed.lease_generation
    ]

    assert {:ok, running_result} =
             IexCode.Research.Results.prepare_run_worker(claimed, authority)

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(current in Run, where: current.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    result_root =
      Path.join(System.tmp_dir!(), "stale-result-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(result_root) end)

    assert {:error, :lease_not_owned} =
             IexCode.Research.Results.commit_worker(
               running_result,
               "# Stale report\n\nMust not become public.",
               [root: result_root, source_count: 0],
               authority
             )

    refute IexCode.Research.Results.get_by_run(claimed).status == "ready"
  end

  test "retains evidence and fails synthesis without fabricating a report when no key exists", %{
    run: run
  } do
    assert {:ok, fetch_step} =
             Runs.create_step(run, %{
               key: "research.fetch",
               kind: "research_fetch",
               title: "Fetch sources",
               position: 22,
               status: "pending"
             })

    assert {:error, :no_api_key} =
             Runner.execute(run, fn _, _ -> :ok end,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchNoKeyLlmStub
             )

    assert [evidence] = Runs.list_artifacts(run)
    assert evidence.kind == "research_evidence"
    refute evidence.metadata["content"] =~ "synthetic"

    assert [
             %{status: "completed"},
             %{status: "completed"},
             %{status: "skipped"},
             %{status: "failed", error_message: error}
           ] =
             run
             |> Runs.list_steps()
             |> Enum.filter(&String.starts_with?(&1.key, "research."))

    assert error =~ "no_api_key"
    assert Runs.get_step!(fetch_step.id).result == %{"reason" => "source_fetch_disabled"}
    assert Enum.any?(Runs.list_events(run), &(&1.type == "research.failed"))
  end

  test "reuses dispatcher-created research stages without disturbing unrelated graph nodes", %{
    run: run
  } do
    {:ok, prepare} =
      Runs.create_step(run, %{key: "prepare-0", kind: "prepare", title: "Prepare"})

    for {key, title, position} <- [
          {"research.plan", "Plan", 20},
          {"research.search", "Search", 21},
          {"research.synthesize", "Synthesize", 22}
        ] do
      assert {:ok, _step} =
               Runs.create_step(run, %{
                 key: key,
                 kind: "dispatcher_research",
                 title: title,
                 position: position,
                 status: "ready"
               })
    end

    assert {:ok, _result} =
             Runner.execute(run, fn _, _ -> :ok end,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    steps = Runs.list_steps(run)
    assert length(Enum.filter(steps, &String.starts_with?(&1.key, "research."))) == 3

    assert Enum.all?(Enum.filter(steps, &String.starts_with?(&1.key, "research.")), fn step ->
             step.status == "completed"
           end)

    assert Runs.get_step!(prepare.id).status == "pending"
  end

  test "quick depth skips a dispatcher-created fetch stage without calling the fetcher", %{
    run: run
  } do
    assert {:ok, fetch_step} =
             Runs.create_step(run, %{
               key: "research.fetch",
               kind: "research_fetch",
               title: "Fetch sources",
               position: 22,
               status: "pending"
             })

    assert {:ok, result} =
             Runner.execute(run, fn _, _ -> :ok end,
               depth: "quick",
               fetch_sources: true,
               fetcher_module: IexCode.TestResearchFetchMustNotRun,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert result.depth == "quick"
    skipped = Runs.get_step!(fetch_step.id)
    assert skipped.status == "skipped"
    assert skipped.result == %{"reason" => "quick_depth"}
  end

  test "applies claimed steering before synthesis and includes it as operator guidance", %{
    run: run
  } do
    {:ok, running} = Runs.transition_run(run, "running")

    {:ok, pending} =
      Runs.enqueue_control(running, "runner-test-steer", %{
        kind: "steer",
        requested_by: "test",
        payload: %{"guidance" => "Prioritize primary sources"}
      })

    {:ok, claimed} = Runs.claim_control(pending, "runner-test")

    assert {:ok, _result} =
             Runner.execute(running, fn _, _ -> :ok end,
               depth: "quick",
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert Runs.get_control(claimed.id).status == "applied"
    assert_receive {:research_synthesis, messages, _system_prompt, _opts}
    assert inspect(messages) =~ "Prioritize primary sources"
  end

  test "durably resolves a pause superseded by resume before the next checkpoint", %{run: run} do
    {:ok, running} = Runs.transition_run(run, "running")

    {:ok, pause_pending} =
      Runs.enqueue_control(running, "runner-test-pause", %{
        kind: "pause",
        requested_by: "test",
        payload: %{}
      })

    {:ok, pause_claimed} = Runs.claim_control(pause_pending, "runner-test")
    {:ok, paused} = Runs.transition_run(running, "paused")

    {:ok, resume_pending} =
      Runs.enqueue_control(paused, "runner-test-resume", %{
        kind: "resume",
        requested_by: "test",
        payload: %{}
      })

    {:ok, resume_claimed} = Runs.claim_control(resume_pending, "runner-test")
    {:ok, resumed} = Runs.transition_run(paused, "running")

    assert {:ok, _result} =
             Runner.execute(resumed, fn _, _ -> :ok end,
               depth: "quick",
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub
             )

    assert Runs.get_control(pause_claimed.id).status == "superseded"
    assert Runs.get_control(resume_claimed.id).status == "applied"
  end
end
