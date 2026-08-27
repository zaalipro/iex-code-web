defmodule IexCode.Research.DagEndToEndTest do
  use IexCode.DataCase, async: false

  alias IexCode.Research.{DagAdapter, Results}
  alias IexCode.Runs.{DagRunner, DagScheduler, DagStepRegistry, Run, RunCommand}
  alias IexCode.Repo
  alias IexCode.{Projects, Runs, Sessions}

  @owner "research-dag-e2e-owner"

  setup do
    workspace = temporary_directory("workspace")
    app_dir = temporary_directory("app")
    File.mkdir_p!(workspace)
    File.mkdir_p!(app_dir)

    previous_app_dir = Application.get_env(:iex_code, :app_dir)
    Application.put_env(:iex_code, :app_dir, app_dir)

    on_exit(fn ->
      if previous_app_dir do
        Application.put_env(:iex_code, :app_dir, previous_app_dir)
      else
        Application.delete_env(:iex_code, :app_dir)
      end

      File.rm_rf(workspace)
      File.rm_rf(app_dir)
    end)

    {:ok, project} = Projects.create_project(%{name: "Research DAG", root_path: workspace})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Research DAG"})
    %{project: project, session: session, workspace: workspace, app_dir: app_dir}
  end

  test "executes registered finite research fanout through verification and public result commit",
       context do
    assert {:ok, manifest} =
             DagAdapter.build("Prove durable research recovery",
               ranked_providers: ["duckduckgo"],
               level: "low",
               max_sources: 4
             )

    assert Enum.find(manifest, &(&1.kind == "research_plan")).params["max_queries"] == 2

    assert Enum.find(manifest, &(&1.kind == "research_ranked_search")).params[
             "max_search_calls"
           ] == 2

    plan_module = IexCode.Research.DagStepHandlers.Plan
    plan_node = Enum.find(manifest, &(&1.kind == "research_plan"))

    assert {:ok, %{"data" => %{"queries" => [_first, _second]}}} =
             plan_module.execute(plan_node.params, %{
               dependency_results: %{},
               cancelled?: fn -> false end
             })

    assert {:ok, queued} =
             Runs.create_run_with_steps(
               %{
                 project_id: context.project.id,
                 session_id: context.session.id,
                 objective: "Prove durable research recovery",
                 kind: "deep_research",
                 mode: "research",
                 execution_engine: "dag_v1",
                 token_budget: 100_000,
                 cost_budget_cents: 10_000,
                 metadata: %{"research" => %{"level" => "low"}}
               },
               manifest
             )

    public_id = Results.get_by_run(queued).id
    assert {:ok, claimed} = Runs.claim_next_run(@owner, execution_engines: ["dag_v1"])

    assert {:ok, %Run{status: "completed"}} =
             DagRunner.run(claimed,
               lease_owner: @owner,
               lease_generation: claimed.lease_generation,
               project_root: context.workspace,
               internal_step_executor: &execute_research_step/2,
               heartbeat_ms: 50,
               lease_ms: 5_000,
               poll_ms: 5,
               max_concurrency: 4
             )

    completed = Runs.get_run(queued.id)
    assert completed.status == "completed"
    assert completed.progress == 100
    assert Enum.all?(Runs.list_steps(completed), &(&1.status == "completed"))
    assert length(DagScheduler.list_attempts(completed, limit: 100)) == length(manifest)

    ready = Results.get(public_id)
    assert ready.status == "ready"
    assert ready.level == "low"
    assert ready.metadata["dag_manifest_hash"] == completed.manifest_hash

    audit_step = Enum.find(Runs.list_steps(completed), &(&1.kind == "research_evidence_audit"))
    assert audit_step.result["data"]["conflict_audit"]["required"]
    assert audit_step.result["data"]["conflict_audit"]["checked"]

    assert {:ok, markdown} = Results.read_markdown(ready)
    assert markdown =~ "Durable research preserves evidence before synthesis [1]"
    assert markdown =~ "## Verified source index"

    assert {:ok, html} = Results.read_html(ready)
    assert html =~ "<!doctype html>"
    assert File.exists?(Path.join(context.app_dir, "research/#{ready.id}/result.md"))
    assert File.exists?(Path.join(context.app_dir, "research/#{ready.id}/report.html"))

    projection = DagScheduler.projection(completed)
    assert length(projection) == length(manifest)
    assert Enum.any?(projection, &(&1.kind == "research_report_verify"))
  end

  test "runner-bound provider effects reserve, settle, and account before a real handler graph",
       context do
    {:ok, manifest} =
      DagAdapter.build("Audit provider effect recovery",
        ranked_providers: ["duckduckgo"],
        level: "low",
        max_sources: 3,
        require_conflict_audit: false
      )

    {:ok, queued} =
      Runs.create_run_with_steps(
        %{
          project_id: context.project.id,
          session_id: context.session.id,
          objective: "Audit provider effect recovery",
          kind: "deep_research",
          mode: "research",
          execution_engine: "dag_v1",
          token_budget: 100_000,
          cost_budget_cents: 10_000,
          metadata: %{"research" => %{"level" => "low"}}
        },
        manifest
      )

    {:ok, claimed} = Runs.claim_next_run(@owner, execution_engines: ["dag_v1"])
    parent = self()

    executor = fn claim, step_context ->
      execute_effectful_research_step(claim, step_context, parent)
    end

    assert {:ok, %Run{status: "completed"}} =
             DagRunner.run(claimed,
               lease_owner: @owner,
               lease_generation: claimed.lease_generation,
               project_root: context.workspace,
               internal_step_executor: executor,
               heartbeat_ms: 50,
               lease_ms: 5_000,
               poll_ms: 5,
               max_concurrency: 4
             )

    assert_receive {:ranked_provider_call, _query, ["duckduckgo"]}
    assert_receive {:ranked_provider_call, _query, ["duckduckgo"]}
    assert_receive {:synthesis_provider_call, 12_000}

    commands = Repo.all(RunCommand)
    assert length(commands) == 4
    assert Enum.all?(commands, &(&1.status == "completed"))
    assert Enum.all?(commands, &String.starts_with?(&1.idempotency_key, "research-budget:"))

    completed = Runs.get_run(queued.id)
    assert completed.input_tokens > 0
    assert completed.output_tokens > 0
    assert completed.cost_cents > 0
    assert completed.cost_cents <= completed.cost_budget_cents
    assert Results.get_by_run(completed).status == "ready"
  end

  defp execute_research_step(claim, step_context) do
    {:ok, module} = DagStepRegistry.fetch(claim.step.kind)

    if function_exported?(module, :execute, 3) do
      module.execute(claim.step.params, step_context,
        runtime_module: IexCode.TestResearchDagRuntimeStub
      )
    else
      module.execute(claim.step.params, step_context)
    end
  end

  defp execute_effectful_research_step(claim, step_context, parent) do
    {:ok, module} = DagStepRegistry.fetch(claim.step.kind)

    if function_exported?(module, :execute, 3) do
      module.execute(claim.step.params, step_context,
        runtime_module: IexCode.Research.DagRuntime,
        settings_resolver: fn ->
          %{
            "search" => %{
              "providers" => %{
                "duckduckgo" => %{
                  "enabled" => true,
                  "base_url" => "https://html.duckduckgo.com"
                }
              }
            },
            "synthesis_providers" => %{
              "openai" => %{
                "api_key" => "test-key",
                "base_url" => "https://models.example.test"
              }
            },
            "grounded_providers" => %{}
          }
        end,
        search_module: fn query, opts ->
          send(parent, {:ranked_provider_call, query, opts[:providers]})

          {:ok,
           %{
             results: [
               %{
                 provider: "duckduckgo",
                 title: "Official recovery evidence",
                 url: "https://evidence.example.test/recovery",
                 snippet: "Durable receipts prevent duplicate provider calls."
               }
             ],
             errors: %{},
             providers: ["duckduckgo"]
           }}
        end,
        fetcher_module: fn url, _opts ->
          {:ok,
           %{
             url: url,
             content_type: "text/plain",
             text: "Durable receipts prevent duplicate provider calls.",
             bytes: 50,
             status: 200,
             redirects: []
           }}
        end,
        llm_module: fn _messages, _system, _session, _on_chunk, opts ->
          send(parent, {:synthesis_provider_call, opts[:max_tokens]})

          {:ok,
           %{
             text: "# Findings\n\nDurable receipts prevent duplicate provider calls [1].",
             usage: %{input_tokens: 40, output_tokens: 15}
           }}
        end,
        session_resolver: fn _session_id ->
          %{
            id: "research-session",
            model_provider: "openai",
            model_name: "gpt-test"
          }
        end
      )
    else
      module.execute(claim.step.params, step_context)
    end
  end

  defp temporary_directory(label) do
    Path.join(
      System.tmp_dir!(),
      "iex-code-research-dag-e2e-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
