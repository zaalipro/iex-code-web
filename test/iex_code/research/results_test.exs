defmodule IexCode.Research.ResultsTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.Research.{DagAdapter, DagFinalizer, ResearchResult, Results, ResultStore, Runner}
  alias IexCode.{Projects, Repo, Runs, Sessions}

  setup do
    workspace = temporary_directory("workspace")
    app_dir = temporary_directory("app")
    File.mkdir_p!(workspace)
    File.mkdir_p!(app_dir)

    {:ok, project} = Projects.create_project(%{name: "Research results", root_path: workspace})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Research"})

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(app_dir)
    end)

    %{project: project, session: session, app_dir: app_dir}
  end

  test "allocates monotonic integer IDs with the deep-research run transaction", context do
    first = create_research_run(context, "First result", "low")
    second = create_research_run(context, "Second result", "ultra")

    first_result = Results.get_by_run(first)
    second_result = Results.get_by_run(second)

    assert is_integer(first_result.id)
    assert second_result.id > first_result.id
    assert first_result.level == "low"
    assert second_result.level == "ultra"
    assert first_result.status == "queued"
    assert first_result.objective == "First result"

    assert {:ok, ^first_result} = Results.register(first, "low")
    assert {:error, :research_result_identity_conflict} = Results.register(first, "high")
  end

  test "commits exact result.md and HTML paths through content-addressed storage", context do
    run = create_research_run(context, "Durable orchestration evidence", "medium")
    result = Results.get_by_run(run)
    root = Path.join(context.app_dir, "research")
    markdown = "# Durable orchestration\n\nVerified checkpoints [1]."

    assert {:ok, running} = Results.mark_running(result)

    assert {:ok, ready} =
             Results.commit(running, markdown,
               root: root,
               source_count: 3,
               metadata: %{"provider_ids" => ["tavily"]}
             )

    assert ready.status == "ready"
    assert ready.result_path == "#{ready.id}/result.md"
    assert ready.html_path == "#{ready.id}/report.html"
    assert ready.source_count == 3
    assert File.read!(Path.join(root, ready.result_path)) == markdown
    assert File.read!(Path.join(root, ready.html_path)) =~ "<!doctype html>"
    assert File.stat!(Path.join(root, ready.result_path)).mode |> Bitwise.band(0o777) == 0o600
    assert Path.wildcard(Path.join(root, ".objects/sha256/*/#{ready.markdown_sha256}")) != []

    assert {:ok, attachment} =
             Results.context_attachment(ready.id, context.session.id, root: root)

    assert attachment["id"] == ready.id
    assert attachment["content"] == markdown
    assert attachment["sha256"] == ready.markdown_sha256

    {:ok, other_session} =
      Sessions.create_session(%{project_id: context.project.id, title: "Other session"})

    assert {:error, :research_result_not_found} =
             Results.context_attachment(ready.id, other_session.id, root: root)

    assert {:ok, [%{"id" => id, "sha256" => digest} = reference]} =
             Results.attachment_refs([ready.id], context.session.id, root: root)

    assert id == ready.id
    assert digest == ready.markdown_sha256

    assert {:ok, [%{"content" => ^markdown}]} =
             Results.resolve_attachment_refs([reference], context.session.id, root: root)

    assert {:error, :research_result_not_found} =
             Results.resolve_attachment_refs([reference], other_session.id, root: root)

    assert {:error, :research_attachment_integrity_error} =
             Results.resolve_attachment_refs(
               [%{reference | "sha256" => String.duplicate("0", 64)}],
               context.session.id,
               root: root
             )

    assert {:ok, idempotent} =
             Results.commit(ready, markdown, root: root, source_count: 3)

    assert idempotent.id == ready.id

    assert {:error, :research_object_collision} =
             Results.commit(ready, markdown <> " changed", root: root)
  end

  test "broadcasts committed and repairable materialization lifecycle after durable state",
       context do
    assert :ok = Results.subscribe_session(context.session.id)
    run = create_research_run(context, "Observable publication", "low")
    result = Results.get_by_run(run)
    root = Path.join(context.app_dir, "research-observable")

    assert {:ok, running} = Results.mark_running(result)

    assert_receive {:research_result_updated,
                    %{result: %{id: result_id, status: "running"}, lifecycle: :running}}

    assert result_id == result.id
    assert {:ok, ready} = Results.commit(running, "# Observable\n\nEvidence.", root: root)

    assert_receive {:research_result_updated,
                    %{
                      result: %{id: ready_id, status: "ready"},
                      lifecycle: :ready,
                      details: %{publication: :complete}
                    }}

    assert ready_id == ready.id

    second = create_research_run(context, "Repairable publication", "low")
    {:ok, second} = Results.get_by_run(second) |> Results.mark_running()
    second_path = Path.join(root, "#{second.id}/result.md")
    File.mkdir_p!(Path.dirname(second_path))
    File.write!(second_path, "collision", [:exclusive])

    assert {:ok, accepted} = Results.commit(second, "# Accepted", root: root)

    assert_receive {:research_result_updated,
                    %{
                      result: %{id: accepted_id, status: "ready"},
                      lifecycle: :materialization_failed,
                      details: %{
                        publication: :repairable_failure,
                        failures: failures
                      }
                    }}

    assert accepted_id == accepted.id
    assert Enum.any?(failures, &(&1.reason == "research_object_collision"))
    assert Results.get(accepted.id).status == "ready"
  end

  test "authority loss after object writes cannot poison public paths for a retry", context do
    run = create_research_run(context, "Recover fenced publication", "medium")
    root = Path.join(context.app_dir, "research-fenced-publish")

    assert {:ok, claimed} = Runs.claim_next_run("stale-result-worker", lease_ms: 30_000)
    assert claimed.id == run.id

    stale_authority = [
      lease_owner: "stale-result-worker",
      run_attempt: claimed.attempt,
      lease_generation: claimed.lease_generation
    ]

    assert {:ok, running_result} = Results.prepare_run_worker(claimed, stale_authority)

    expire_authority = fn ->
      expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(current in Runs.Run, where: current.id == ^claimed.id),
        set: [lease_expires_at: expired]
      )

      :ok
    end

    assert {:error, :lease_not_owned} =
             Results.commit_worker(
               running_result,
               "# Stale report\n\nThis must never claim the public path.",
               [root: root, before_ready: expire_authority],
               stale_authority
             )

    refute File.exists?(Path.join(root, "#{running_result.id}/result.md"))
    refute File.exists?(Path.join(root, "#{running_result.id}/report.html"))
    assert Path.wildcard(Path.join(root, ".objects/sha256/*/*")) != []

    assert [%{id: run_id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert run_id == claimed.id
    assert {:ok, retried} = Runs.retry_run(claimed)
    assert {:ok, reclaimed} = Runs.claim_next_run("retry-result-worker", lease_ms: 30_000)
    assert reclaimed.id == retried.id

    retry_authority = [
      lease_owner: "retry-result-worker",
      run_attempt: reclaimed.attempt,
      lease_generation: reclaimed.lease_generation
    ]

    assert {:ok, retry_result} = Results.prepare_run_worker(reclaimed, retry_authority)
    replacement = "# Replacement report\n\nPublished by the current worker."

    assert {:ok, ready} =
             Results.commit_worker(retry_result, replacement, [root: root], retry_authority)

    assert ready.status == "ready"
    assert File.read!(Path.join(root, ready.result_path)) == replacement
    assert File.read!(Path.join(root, ready.html_path)) =~ "Replacement report"

    File.rm!(Path.join(root, ready.result_path))
    refute File.exists?(Path.join(root, ready.result_path))
    assert {:ok, ^replacement} = Results.read_markdown(ready, root: root)
    assert File.read!(Path.join(root, ready.result_path)) == replacement
  end

  test "fixed-path publication failure cannot undo an accepted object", context do
    run = create_research_run(context, "Recover accepted object publication", "low")
    result = Results.get_by_run(run)
    {:ok, running} = Results.mark_running(result)
    root = Path.join(context.app_dir, "research-accepted-object")
    result_path = Path.join(root, "#{result.id}/result.md")

    File.mkdir_p!(Path.dirname(result_path))
    File.write!(result_path, "stale fixed-path content", [:exclusive])

    markdown = "# Accepted report\n\nThe digest is authoritative."
    assert {:ok, ready} = Results.commit(running, markdown, root: root)
    assert ready.status == "ready"
    assert File.read!(result_path) == "stale fixed-path content"

    assert {:error, :research_result_integrity_error} =
             Results.read_markdown(ready, root: root)

    assert {:ok, html} = Results.read_html(ready, root: root)
    assert html =~ "Accepted report"
  end

  test "verifies checksums on every read and bounds chat attachments", context do
    run = create_research_run(context, "Integrity", "high")
    result = Results.get_by_run(run)
    root = Path.join(context.app_dir, "research")

    {:ok, running} = Results.mark_running(result)
    {:ok, ready} = Results.commit(running, "# Integrity\n\nEvidence.", root: root)

    File.write!(Path.join(root, ready.result_path), "tampered")

    assert {:error, :research_result_integrity_error} = Results.read_markdown(ready, root: root)

    assert {:error, :research_result_integrity_error} =
             Results.context_attachment(ready.id, context.session.id, root: root)
  end

  test "bounds aggregate same-session attachment context at 90 KB", context do
    first = create_research_run(context, "First aggregate attachment", "low")
    second = create_research_run(context, "Second aggregate attachment", "low")
    root = Path.join(context.app_dir, "research")

    {:ok, first_result} = Results.get_by_run(first) |> Results.mark_running()
    {:ok, second_result} = Results.get_by_run(second) |> Results.mark_running()
    {:ok, first_ready} = Results.commit(first_result, String.duplicate("a", 46_000), root: root)
    {:ok, second_ready} = Results.commit(second_result, String.duplicate("b", 46_000), root: root)

    assert {:error, {:research_context_too_large, 90_000}} =
             Results.attachment_refs(
               [first_ready.id, second_ready.id],
               context.session.id,
               root: root
             )
  end

  test "legacy asynchronous research commits result.md and HTML before returning", context do
    run = create_research_run(context, "End-to-end durable report", "high")
    root = Path.join(context.app_dir, "research")

    assert {:ok, execution} =
             Runner.execute(run, fn _percent, _message -> :ok end,
               search_module: IexCode.TestResearchSearchStub,
               llm_module: IexCode.TestResearchLlmStub,
               research_root: root,
               depth: "quick"
             )

    ready = Results.get_by_run(run)
    assert execution.research_result_id == ready.id
    assert ready.status == "ready"
    assert File.read!(Path.join(root, "#{ready.id}/result.md")) == execution.report
    assert File.read!(Path.join(root, "#{ready.id}/report.html")) =~ "End-to-end durable report"

    kinds = run |> Runs.list_artifacts() |> Enum.map(& &1.kind)
    assert "research_report" in kinds
    assert "research_report_html" in kinds
  end

  test "run status synchronizes queued result lifecycle until a report is ready", context do
    run = create_research_run(context, "Lifecycle", "medium")
    result = Results.get_by_run(run)
    assert result.status == "queued"

    {:ok, running_run} = Runs.transition_run(run, "running")
    assert Results.get(result.id).status == "running"

    {:ok, cancelled_run} = Runs.transition_run(running_run, "cancelled")
    cancelled = Results.get(result.id)
    assert cancelled.status == "cancelled"
    assert cancelled.completed_at

    assert {:ok, _retried} = Runs.retry_run(cancelled_run)
    retried = Results.get(result.id)
    assert retried.status == "queued"
    refute retried.completed_at
  end

  test "rejects traversal, symlink materialization, oversized bodies, and secret metadata",
       context do
    root = Path.join(context.app_dir, "research")
    outside = temporary_directory("outside")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:research_body_too_large, 4_000_000}} =
             ResultStore.put(root, String.duplicate("x", 4_000_001))

    assert {:ok, object} = ResultStore.put(root, "safe")

    assert {:error, :outside_research_root} =
             ResultStore.materialize(root, object, "../result.md")

    File.mkdir_p!(root)
    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:error, :outside_workspace} =
             ResultStore.materialize(root, object, "escape/result.md")

    run = create_research_run(context, "Secret safe", "low")
    result = Results.get_by_run(run)
    {:ok, running} = Results.mark_running(result)

    assert {:error, {:invalid_research_metadata, _reason}} =
             Results.commit(running, "# Safe",
               root: root,
               metadata: %{"api_key" => "must-not-persist"}
             )

    refute File.exists?(Path.join(root, "#{result.id}/result.md"))
    assert Results.get(result.id).status == "running"
  end

  test "database authority prevents cross-run identity rewrites", context do
    run = create_research_run(context, "Immutable", "medium")
    result = Results.get_by_run(run)

    assert_raise Exqlite.Error, ~r/research_result_identity_immutable/, fn ->
      Repo.query!("UPDATE research_results SET objective = 'rewritten' WHERE id = ?", [result.id])
    end

    assert Results.get(result.id).objective == "Immutable"
    assert [] = Results.list_ready(session_id: context.session.id)
    assert %ResearchResult{id: id} = Results.get(result.id)
    assert id == result.id
  end

  test "concurrent materialization cannot replace an immutable destination", context do
    root = Path.join(context.app_dir, "research-race")
    {:ok, first} = ResultStore.put(root, "first body")
    {:ok, second} = ResultStore.put(root, "second body")

    replies =
      [first, second]
      |> Task.async_stream(&ResultStore.materialize(root, &1, "42/result.md"),
        max_concurrency: 2,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, reply} -> reply end)

    assert Enum.count(replies, &match?({:ok, _path}, &1)) == 1
    assert Enum.count(replies, &match?({:error, :research_object_collision}, &1)) == 1
    assert File.read!(Path.join(root, "42/result.md")) in ["first body", "second body"]
  end

  test "unfinished completed DAG results are selected before reconciliation limits", context do
    older = create_research_run(context, "Needs reconciliation", "low", "dag_v1")
    {:ok, older} = Runs.transition_run(older, "running")
    {:ok, older} = Runs.transition_run(older, "completed")

    {:ok, newer} =
      Runs.create_run(%{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Unrelated newer completed work",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, newer} = Runs.transition_run(newer, "running")
    {:ok, _newer} = Runs.transition_run(newer, "completed")

    assert [candidate] = Results.list_unmaterialized_completed(limit: 1)
    assert candidate.id == older.id
  end

  test "reconciliation pages through every unfinished candidate", context do
    runs =
      Enum.map(1..3, fn index ->
        run = create_research_run(context, "Unmaterialized #{index}", "low", "dag_v1")
        {:ok, run} = Runs.transition_run(run, "running")
        {:ok, run} = Runs.transition_run(run, "completed")
        run
      end)

    outcomes = DagFinalizer.reconcile(limit: 1)

    assert Enum.map(outcomes, &elem(&1, 0)) == Enum.map(runs, & &1.id)

    assert Enum.all?(outcomes, fn {_id, outcome} ->
             outcome == {:error, :terminal_step_incomplete}
           end)
  end

  defp create_research_run(context, objective, level, execution_engine \\ nil) do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: objective,
      kind: "deep_research",
      mode: "research",
      metadata: %{"research" => %{"level" => level}}
    }

    attrs =
      if execution_engine, do: Map.put(attrs, :execution_engine, execution_engine), else: attrs

    {:ok, run} =
      if execution_engine == "dag_v1" do
        {:ok, steps} =
          DagAdapter.build(objective,
            level: level,
            ranked_providers: ["duckduckgo"],
            require_conflict_audit: false
          )

        Runs.create_run_with_steps(attrs, steps)
      else
        Runs.create_run(attrs)
      end

    run
  end

  defp temporary_directory(label) do
    Path.join(
      System.tmp_dir!(),
      "iex-code-research-results-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
