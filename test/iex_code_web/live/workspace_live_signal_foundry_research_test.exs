defmodule IexCodeWeb.WorkspaceLiveSignalFoundryResearchTest do
  use IexCode.E2E.Case, async: false
  import Ecto.Query, only: [from: 2]

  alias IexCode.Runs
  alias IexCode.Runs.RunStep
  alias IexCode.Research.Results

  setup %{workspace_path: path} do
    app_dir = Path.join(path, ".iex-code-test")
    previous_app_dir = Application.get_env(:iex_code, :app_dir)
    Application.put_env(:iex_code, :app_dir, app_dir)

    on_exit(fn ->
      if previous_app_dir do
        Application.put_env(:iex_code, :app_dir, previous_app_dir)
      else
        Application.delete_env(:iex_code, :app_dir)
      end
    end)

    :ok
  end

  test "root and session research render one shared chassis and one ordered native form", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    contexts = [
      {~p"/research", "/", "/settings#providers"},
      {~p"/sessions/#{session.id}/research", "/sessions/#{session.id}",
       "/sessions/#{session.id}/settings#providers"}
    ]

    for {research_path, return_path, settings_path} <- contexts do
      {:ok, view, _html} = live(conn, research_path)
      document = view |> render() |> LazyHTML.from_fragment()

      assert node_count(
               document,
               "#instrument-workbench-research[data-workbench-surface='research']"
             ) == 1

      assert node_count(document, "#deep-research-page") == 1
      assert node_count(document, "#deep-research-form") == 1
      assert node_count(document, "#prompt-composer") == 1
      assert node_count(document, "#prompt-form") == 1

      assert has_element?(
               view,
               "#return-to-instrument-deck-research[href='#{return_path}'][data-return-instrument-id='instrument-card-research'][data-phx-link='patch'][data-phx-link-state='replace']"
             )

      assert has_element?(view, "#research-open-settings[href='#{settings_path}']")

      assert has_element?(view, "#research-run-contract")

      assert has_element?(
               view,
               "#deep-research-submit[type='submit'][phx-disable-with='Checking availability…']"
             )

      assert has_element?(view, "#deep-research-max-sources[type='number'][min='1'][max='40']")

      for level <- ~w(low medium high ultra) do
        assert has_element?(
                 view,
                 "#deep-research-level-#{level}[type='radio'][name='research[level]']"
               )
      end

      assert has_element?(view, "#deep-research-provider-duckduckgo[type='checkbox']")
      assert_stage_order(document)
    end
  end

  test "conflicting route queries replace to the same canonical research context", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    for {path_with_query, canonical} <- [
          {"/research?view=terminal", "/research"},
          {"/sessions/#{session.id}/research?view=terminal", "/sessions/#{session.id}/research"}
        ] do
      {:ok, view, _html} = live(conn, canonical)
      render_patch(view, path_with_query)
      assert_patch(view, canonical)
      assert has_element?(view, "#instrument-workbench-research")
    end
  end

  test "authorized marked and legacy research runs keep each canonical route", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    marked = marked_research_run(project, session, "Marked projection")
    legacy = legacy_research_run(project, session, "Legacy projection")

    {:ok, session_view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    session_view |> element("#deep-research-run-#{marked.id}") |> render_click()
    assert_patch(session_view, "/sessions/#{session.id}/research")

    assert has_element?(
             session_view,
             "#research-progress-dag #dag-execution-projection[data-engine='dag_v1']"
           )

    refute has_element?(session_view, "#research-progress-fallback")

    session_view |> element("#deep-research-run-#{legacy.id}") |> render_click()
    assert_patch(session_view, "/sessions/#{session.id}/research")
    assert has_element?(session_view, "#research-progress-fallback[data-run-status='queued']")
    refute has_element?(session_view, "#research-progress-dag")
    refute has_element?(session_view, "#dag-execution-projection")
  end

  test "root research keeps the root canonical path after an authorized open", %{
    conn: conn,
    workspace_path: path
  } do
    _project = create_project_fixture(%{root_path: path})
    {:ok, view, _html} = live(conn, ~p"/research")

    [session_id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#workspace-shell")
      |> LazyHTML.attribute("data-session-id")

    session = IexCode.Sessions.get_session(session_id)
    project = IexCode.Projects.get_project!(session.project_id)
    run = marked_research_run(project, session, "Root marked")

    render_click(view, "open_research_run", %{"id" => run.id})
    assert_patch(view, "/research")
    assert has_element?(view, "#research-progress-dag")
    assert has_element?(view, "#research-open-settings[href='/settings#providers']")
  end

  test "hostile open authorization preserves selected research and path", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Selected")
    foreign = marked_research_run(project, foreign_session, "Foreign")

    {:ok, non_research} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Not research",
        kind: "analysis",
        mode: "workflow"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    render_click(view, "open_research_run", %{"id" => selected.id})
    assert_patch(view, "/sessions/#{session.id}/research")

    for hostile_params <- [
          %{"id" => foreign.id},
          %{"id" => non_research.id},
          %{"id" => Ecto.UUID.generate()},
          %{"id" => "not-a-run"},
          %{}
        ] do
      render_click(view, "open_research_run", hostile_params)
      assert has_element?(view, "#flash-error", "Research run not found in this session")
      assert has_element?(view, "#deep-research-run-#{selected.id}[aria-pressed='true']")
      assert has_element?(view, "#research-progress-dag")
      refute_patched(view)
    end
  end

  test "markerless and unknown dag markers fail to factual bounded fallback", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    markerless =
      marked_research_run(project, session, "MARKERLESS_OBJECTIVE_SENTINEL")
      |> rewrite_metadata(%{
        "research" => %{"level" => "medium"},
        "provider_payload" => "PROVIDER_SENTINEL"
      })
      |> set_raw_progress(140)

    unknown =
      marked_research_run(project, session, "UNKNOWN_OBJECTIVE_SENTINEL")
      |> rewrite_metadata(%{
        "projection" => "DAG_V1",
        "research" => %{"level" => "high"},
        "lease" => "LEASE_SENTINEL"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    for {run, progress} <- [{markerless, 100}, {unknown, 0}] do
      view |> element("#deep-research-run-#{run.id}") |> render_click()
      assert_patch(view, "/sessions/#{session.id}/research")
      assert has_element?(view, "#research-progress-fallback[data-run-status='queued']")
      assert has_element?(view, "#research-progress-fallback", "Progress · #{progress}%")
      refute has_element?(view, "#research-progress-dag")
      refute has_element?(view, "#dag-execution-projection")

      fallback =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#research-progress-fallback")

      fallback_text = LazyHTML.text(fallback)

      for hostile <- ~w(OBJECTIVE_SENTINEL PROVIDER_SENTINEL LEASE_SENTINEL) do
        refute String.contains?(fallback_text, hostile)
      end

      if run.id == markerless.id do
        send(view.pid, {:run_updated, %{run | metadata: %{projection: "dag_v1"}}})
        _ = :sys.get_state(view.pid)
        assert has_element?(view, "#research-progress-fallback")
        refute has_element?(view, "#dag-execution-projection")
      end
    end
  end

  test "atom-keyed projection payload cannot opt a markerless run into the DAG", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    run = legacy_research_run(project, session, "Atom marker payload")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    view |> element("#deep-research-run-#{run.id}") |> render_click()
    assert has_element?(view, "#research-progress-fallback")
    refute has_element?(view, "#research-progress-dag")

    send(view.pid, {:run_updated, %{run | metadata: %{projection: "dag_v1"}}})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#research-progress-fallback")
    refute has_element?(view, "#research-progress-dag")
  end

  test "oversized authorized progress fails closed before a full projection is retained", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    run = marked_research_run(project, session, "Oversized projection")
    insert_corrupt_steps(run, 128)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    assert has_element?(view, "#deep-research-run-#{run.id}[aria-pressed='true']")
    assert has_element?(view, "#research-progress-fallback[data-projection-state='bounded-out']")
    refute has_element?(view, "#research-progress-dag")
    refute has_element?(view, "#dag-execution-projection")
    refute has_element?(view, "#research-progress-fallback", "overflow-128")
  end

  test "Research mount query-bounds every progress and summary step snapshot", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    run = marked_research_run(project, session, "Bounded summary path")
    insert_corrupt_steps(run, 128)

    {:ok, mission} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Running bounded mission",
        kind: "analysis",
        mode: "workflow",
        status: "running"
      })

    insert_corrupt_steps(mission, 128)

    queries =
      capture_repo_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
        _ = :sys.get_state(view.pid)
      end)

    step_queries =
      Enum.filter(queries, fn query ->
        String.contains?(query.query || "", ~s(FROM "run_steps")) and
          Enum.any?(query.params, &(&1 in [run.id, mission.id]))
      end)

    assert step_queries != []
    assert Enum.all?(step_queries, &(&1.query =~ "LIMIT"))

    assert step_queries
           |> Enum.flat_map(& &1.params)
           |> Enum.filter(&(&1 in [run.id, mission.id]))
           |> MapSet.new() == MapSet.new([run.id, mission.id])
  end

  test "research selection ignores newer coding runs and resets on session switch", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    first_session = create_session_fixture(project)
    second_session = create_session_fixture(project)
    first_research = marked_research_run(project, first_session, "First research")
    second_research = legacy_research_run(project, second_session, "Second research")

    {:ok, _coding} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: first_session.id,
        objective: "Newer coding run",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{first_session.id}/research")
    assert has_element?(view, "#deep-research-run-#{first_research.id}[aria-pressed='true']")
    assert has_element?(view, "#research-progress-dag")

    render_patch(view, ~p"/sessions/#{second_session.id}/research")
    assert has_element?(view, "#deep-research-run-#{second_research.id}[aria-pressed='true']")
    assert has_element?(view, "#research-progress-fallback")
    refute has_element?(view, "#deep-research-run-#{first_research.id}")
    refute has_element?(view, "#research-progress-dag")
  end

  test "ready results render only scoped persisted evidence facts and report actions", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)

    result =
      ready_result(project, session, "Evidence", "# Evidence", level: "high", source_count: 7)

    foreign = ready_result(project, foreign_session, "Foreign", "# Foreign")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    assert has_element?(
             view,
             "#research-evidence-#{result.id}[data-evidence-level='high'][data-evidence-source-count='7']"
           )

    assert has_element?(
             view,
             "#research-evidence-#{result.id}[data-artifacts-recorded='true'][data-digests-recorded='true']"
           )

    assert has_element?(
             view,
             "#research-evidence-#{result.id} #deep-research-result-#{result.id}"
           )

    assert has_element?(
             view,
             "#deep-research-result-open-#{result.id}[href='/research/#{result.id}/report'][target='_blank'][rel='noopener noreferrer'][aria-label='Open report for research result #{result.id}']"
           )

    assert has_element?(
             view,
             "#deep-research-result-html-#{result.id}[href='/research/#{result.id}/report/download'][aria-label='Download HTML report for research result #{result.id}']"
           )

    assert has_element?(
             view,
             "#deep-research-result-md-#{result.id}[href='/research/#{result.id}/result/download'][aria-label='Download Markdown report for research result #{result.id}']"
           )

    refute has_element?(view, "#research-evidence-#{foreign.id}")

    evidence =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#research-evidence-#{result.id}")

    evidence_text = LazyHTML.text(evidence)
    refute String.contains?(evidence_text, result.markdown_sha256)
    refute String.contains?(evidence_text, result.html_sha256)
    refute String.contains?(evidence_text, result.result_path)
    refute String.contains?(evidence_text, result.html_path)
  end

  test "selected progress refreshes only for the durably selected research run", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Selected refresh")
    [selected_step] = Runs.list_steps(selected)
    foreign = marked_research_run(project, foreign_session, "Foreign refresh")
    [foreign_step] = Runs.list_steps(foreign)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    assert has_element?(view, "[data-node-key='inventory'][data-node-status='ready']")

    IexCode.Repo.update_all(
      from(step in RunStep, where: step.id == ^selected_step.id),
      set: [status: "completed", progress: 100]
    )

    send(view.pid, {:run_step_updated, foreign_step})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "[data-node-key='inventory'][data-node-status='ready']")

    send(view.pid, {:run_step_updated, selected_step})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "[data-node-key='inventory'][data-node-status='completed']")
  end

  test "selected progress notifications read one bounded step and attempt snapshot", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    selected = marked_research_run(project, session, "One selected snapshot")
    [selected_step] = Runs.list_steps(selected)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    queries =
      capture_repo_queries(fn ->
        send(view.pid, {:run_step_updated, selected_step})
        _ = :sys.get_state(view.pid)
      end)

    assert source_count(queries, "runs") == 1
    assert source_count(queries, "research_results") == 1
    assert source_count_for_run(queries, "run_steps", selected.id) == 1
    assert source_count_for_run(queries, "run_step_attempts", selected.id) == 1
  end

  test "foreign progress notifications refresh no Research detail tables", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)
    _selected = marked_research_run(project, session, "Focused local")
    foreign = marked_research_run(project, foreign_session, "Focused foreign")
    [foreign_step] = Runs.list_steps(foreign)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    queries =
      capture_repo_queries(fn ->
        send(view.pid, {:run_step_updated, foreign_step})
        _ = :sys.get_state(view.pid)
      end)

    assert source_count(queries, "runs") == 1
    assert source_count(queries, "research_results") == 1
    assert source_count_for_run(queries, "run_steps", foreign.id) == 0
    assert source_count_for_run(queries, "run_step_attempts", foreign.id) == 0
  end

  test "same-session nonselected notifications refresh no progress details", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    nonselected = marked_research_run(project, session, "Older nonselected")

    IexCode.Repo.update_all(
      from(persisted in Runs.Run, where: persisted.id == ^nonselected.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    [nonselected_step] = Runs.list_steps(nonselected)
    selected = marked_research_run(project, session, "Newer selected")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    assert has_element?(view, "#deep-research-run-#{selected.id}[aria-pressed='true']")

    queries =
      capture_repo_queries(fn ->
        send(view.pid, {:run_step_updated, nonselected_step})
        _ = :sys.get_state(view.pid)
      end)

    assert source_count(queries, "runs") == 1
    assert source_count(queries, "research_results") == 1
    assert source_count_for_run(queries, "run_steps", nonselected.id) == 0
    assert source_count_for_run(queries, "run_step_attempts", nonselected.id) == 0
  end

  test "retained run cap cannot pair a replacement selection with stale DAG progress", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Evicted selected Research")
    replacement = legacy_research_run(project, session, "Retained replacement Research")

    fillers =
      for index <- 1..99 do
        {:ok, filler} =
          Runs.create_run(%{
            project_id: project.id,
            session_id: session.id,
            objective: "Snapshot filler #{index}",
            kind: "analysis",
            mode: "workflow",
            status: "queued"
          })

        filler
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    IexCode.Repo.update_all(
      from(run in Runs.Run, where: run.id == ^selected.id),
      set: [inserted_at: DateTime.add(now, 100, :second)]
    )

    newer_ids = [replacement.id | Enum.map(fillers, & &1.id)]

    IexCode.Repo.update_all(
      from(run in Runs.Run, where: run.id in ^newer_ids),
      set: [inserted_at: DateTime.add(now, -1, :second)]
    )

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    assert has_element?(view, "#deep-research-run-#{selected.id}[aria-pressed='true']")
    assert has_element?(view, "#research-progress-dag")

    IexCode.Repo.update_all(
      from(run in Runs.Run, where: run.id == ^selected.id),
      set: [inserted_at: DateTime.add(now, -200, :second)]
    )

    [filler | _] = Enum.reverse(fillers)
    send(view.pid, {:run_updated, filler})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#deep-research-run-#{replacement.id}[aria-pressed='true']")
    assert has_element?(view, "#research-progress-fallback")
    refute has_element?(view, "#research-progress-dag")
  end

  test "result refreshes update evidence without rebuilding selected progress", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Evidence-only refresh")
    [selected_step] = Runs.list_steps(selected)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    result = Results.get_by_run(selected)
    {:ok, running} = Results.mark_running(result)
    {:ok, ready} = Results.commit(running, "# Focused evidence", source_count: 2)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#research-evidence-#{ready.id}")
    assert has_element?(view, "[data-node-key='inventory'][data-node-status='ready']")

    IexCode.Repo.update_all(
      from(step in RunStep, where: step.id == ^selected_step.id),
      set: [status: "completed", progress: 100]
    )

    send(view.pid, {:research_result_updated, %{result: ready}})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#research-evidence-#{ready.id}")
    assert has_element?(view, "[data-node-key='inventory'][data-node-status='ready']")
  end

  test "result notifications read evidence snapshots without progress details", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Evidence query focus")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    result = Results.get_by_run(selected)
    {:ok, running} = Results.mark_running(result)
    {:ok, ready} = Results.commit(running, "# Focused query evidence", source_count: 2)
    _ = :sys.get_state(view.pid)

    queries =
      capture_repo_queries(fn ->
        send(view.pid, {:research_result_updated, %{result: ready}})
        _ = :sys.get_state(view.pid)
      end)

    assert source_count(queries, "runs") == 1
    assert source_count(queries, "research_results") == 1
    assert source_count_for_run(queries, "run_steps", selected.id) == 0
    assert source_count_for_run(queries, "run_step_attempts", selected.id) == 0
    assert source_count_for_run(queries, "run_approvals", selected.id) == 0
  end

  test "forged run-created hints are reauthorized from the scoped durable snapshot", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)
    selected = marked_research_run(project, session, "Selected durable")
    foreign = marked_research_run(project, foreign_session, "Foreign durable")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    forged = %{foreign | session_id: session.id, metadata: %{"projection" => "dag_v1"}}

    queries =
      capture_repo_queries(fn ->
        send(view.pid, {:run_created, forged})
        _ = :sys.get_state(view.pid)
      end)

    relevant_queries =
      Enum.filter(queries, &(&1.source in ["runs", "run_steps", "run_step_attempts"]))

    assert [%{source: "runs", params: run_params} | _rest] = relevant_queries
    assert session.id in run_params
    foreign_dump = Ecto.UUID.dump!(foreign.id)

    refute Enum.any?(relevant_queries, fn query ->
             foreign.id in query.params or foreign_dump in query.params
           end)

    refute_patched(view)
    assert has_element?(view, "#workspace-shell[data-active-view='research']")

    assert has_element?(
             view,
             "#return-to-instrument-deck-research[href='/sessions/#{session.id}']"
           )

    assert has_element?(view, "#deep-research-run-#{selected.id}[aria-pressed='true']")
    refute has_element?(view, "#deep-research-run-#{foreign.id}")
    assert has_element?(view, "#research-progress-dag")
  end

  test "active Research run updates synchronize linked Kanban task and Mission Control rows", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      IexCode.Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Linked durable task",
        status: "ready",
        worker_pid: "pending"
      })

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Linked Research",
        kind: "deep_research",
        mode: "research",
        status: "queued",
        metadata: %{"research" => %{"level" => "low"}, "kanban_task_id" => task.id}
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    IexCode.Repo.update_all(
      from(persisted in Runs.Run, where: persisted.id == ^run.id),
      set: [status: "running", progress: 42]
    )

    send(view.pid, {:run_updated, run})
    _ = :sys.get_state(view.pid)

    assert IexCode.Kanban.get_task(project.id, task.id).status == "running"

    view |> element("#return-to-instrument-deck-action") |> render_click()
    assert_patch(view, "/sessions/#{session.id}")
    render_patch(view, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#async-run-#{run.id}[data-run-status='running']")
  end

  test "invalid depth stays explicit and selected controls have non-color markers", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    run = legacy_research_run(project, session, "Selected marker")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    assert has_element?(
             view,
             "[data-level='medium'][data-selection-state='selected'] [data-selected-indicator]"
           )

    assert has_element?(
             view,
             "#deep-research-run-#{run.id}[aria-pressed='true'][data-selection-state='selected'] [data-selected-indicator]"
           )

    render_submit(view, "submit_deep_research", %{
      "research" => %{
        "objective" => "Reject false contract",
        "level" => "extreme",
        "max_sources" => "8",
        "providers" => %{"duckduckgo" => "true"},
        "request_id" => Ecto.UUID.generate()
      }
    })

    assert has_element?(view, "#research-run-contract[data-contract-state='invalid']")
    assert has_element?(view, "#research-invalid-level[data-invalid-level='extreme']")
    refute has_element?(view, "#research-run-contract[data-rounds='2'][data-query-fanout='3']")
  end

  test "Research controls reserve live color for sparse selected marks", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    result = ready_result(project, session, "Attachable", "# Attachable")
    run = marked_research_run(project, session, "Neutral selected run")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    for selector <- [
          "[data-level='medium'][data-selection-state='selected']",
          "#deep-research-run-#{run.id}[data-selection-state='selected']",
          "#deep-research-submit"
        ] do
      classes = element_classes(view, selector)
      refute classes =~ "border-[var(--sf-live-mark)]"
      refute classes =~ "ring-[var(--sf-live-mark)]"
    end

    view |> element("#deep-research-attachment-picker-toggle") |> render_click()
    view |> element("#deep-research-attachment-#{result.id}") |> render_click()

    assert has_element?(view, "#deep-research-attachment-#{result.id}", "Selected")

    for selector <- [
          "#deep-research-attachment-picker-toggle .research-attachment-icon",
          "[data-research-attachment-id='#{result.id}']",
          "#deep-research-attachment-#{result.id}"
        ] do
      refute element_classes(view, selector) =~ "--sf-live"
    end
  end

  test "Research facts are hairline rows and empty sentences use body copy", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    assert has_element?(view, "#research-level-facts > .research-fact-row")
    assert has_element?(view, "#research-semantics-facts > .research-fact-row")

    for selector <- [
          "#research-level-facts > .research-fact-row",
          "#research-semantics-facts > .research-fact-row"
        ] do
      classes = element_classes(view, selector)
      refute classes =~ "bg-[var(--sf-instrument-raised)]"
      refute classes =~ "border border-[var(--sf-hairline)]"
    end

    view |> element("#deep-research-attachment-picker-toggle") |> render_click()

    for selector <- [
          "#deep-research-attachment-picker > p",
          "#deep-research-run-list > .research-empty-state",
          "#deep-research-ready-results > .research-empty-state"
        ] do
      assert element_classes(view, selector) =~ "sf-body-copy"
    end
  end

  test "populated research owns singular progress evidence actions request and dock IDs", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    result = ready_result(project, session, "Singular evidence", "# Evidence")
    run = marked_research_run(project, session, "Singular progress")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    view |> element("#deep-research-run-#{run.id}") |> render_click()
    assert_patch(view, "/sessions/#{session.id}/research")
    document = view |> render() |> LazyHTML.from_fragment()

    selectors = [
      "#instrument-workbench-research",
      "#deep-research-page",
      "#deep-research-form",
      "#deep-research-request-id",
      "#research-stage-objective",
      "#research-stage-depth",
      "#research-stage-sources",
      "#research-stage-contract",
      "#research-run-contract",
      "#research-progress-dag",
      "#dag-execution-projection",
      "#research-evidence-#{result.id}",
      "#deep-research-result-#{result.id}",
      "#deep-research-result-open-#{result.id}",
      "#deep-research-result-html-#{result.id}",
      "#deep-research-result-md-#{result.id}",
      "#prompt-composer",
      "#prompt-form"
    ]

    for selector <- selectors, do: assert(node_count(document, selector) == 1, selector)
    refute has_element?(view, "#settings-modal")
    refute has_element?(view, "#instrument-workbench-research #settings-form")
    refute has_element?(view, "#async-run-dag-projection")
  end

  test "result and run notifications refresh focused evidence and marked progress", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    run = marked_research_run(project, session, "Refresh")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    assert has_element?(view, "#research-progress-dag")

    result = Results.get_by_run(run)
    {:ok, running} = Results.mark_running(result)
    {:ok, ready} = Results.commit(running, "# Ready later", source_count: 2)
    send(view.pid, {:research_result_updated, %{result: ready}})
    assert has_element?(view, "#research-evidence-#{ready.id}")

    {:ok, completed} = Runs.transition_run(run, "completed", %{progress: 100})
    send(view.pid, {:run_updated, completed})
    assert has_element?(view, "#instrument-workbench-research-status", "Completed")
    assert has_element?(view, "#research-progress-dag")
  end

  defp assert_stage_order(document) do
    assert node_count(
             document,
             "#deep-research-form > #research-stage-objective + #research-stage-depth + #research-stage-sources + #research-stage-contract"
           ) == 1
  end

  defp node_count(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.to_tree() |> length()
  end

  defp element_classes(view, selector) do
    value =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("class")

    if is_binary(value), do: value, else: Enum.join(value || [], " ")
  end

  defp capture_repo_queries(fun) do
    handler_id = "research-repo-query-#{System.unique_integer([:positive])}"
    test_pid = self()
    event = IexCode.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, target ->
          send(target, {:research_repo_query, metadata})
        end,
        test_pid
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_repo_queries([])
  end

  defp collect_repo_queries(acc) do
    receive do
      {:research_repo_query, metadata} -> collect_repo_queries([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp source_count(queries, table),
    do: Enum.count(queries, &String.contains?(&1.query || "", ~s(FROM "#{table}")))

  defp source_count_for_run(queries, table, run_id),
    do:
      Enum.count(queries, fn query ->
        String.contains?(query.query || "", ~s(FROM "#{table}")) and
          Enum.any?(query.params, &(&1 == run_id))
      end)

  defp marked_research_run(project, session, objective) do
    {:ok, run} =
      Runs.create_run_with_steps(
        %{
          project_id: project.id,
          session_id: session.id,
          objective: objective,
          kind: "deep_research",
          mode: "research",
          execution_engine: "dag_v1",
          metadata: %{
            "projection" => "dag_v1",
            "research" => %{"level" => "medium"}
          }
        },
        [dag_node("inventory", "project_inventory", [], %{"path" => "."})]
      )

    run
  end

  defp legacy_research_run(project, session, objective) do
    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: objective,
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => "low"}}
      })

    run
  end

  defp rewrite_metadata(run, metadata) do
    {:ok, updated} = Runs.heartbeat_run(run, %{metadata: metadata})
    updated
  end

  defp set_raw_progress(run, progress) do
    IexCode.Repo.update_all(
      from(persisted in IexCode.Runs.Run, where: persisted.id == ^run.id),
      set: [progress: progress]
    )

    Runs.get_run!(run.id)
  end

  defp insert_corrupt_steps(run, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for index <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          run_id: run.id,
          key: "overflow-#{index}",
          kind: "project_inventory",
          title: "Overflow #{index}",
          status: "pending",
          position: index,
          progress: 0,
          attempt: 0,
          max_attempts: 1,
          depends_on: [],
          params: %{},
          handler_version: 1,
          effect_class: "pure",
          replay_policy: "safe",
          resource_spec: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    {^count, nil} = IexCode.Repo.insert_all(RunStep, rows)
  end

  defp ready_result(project, session, objective, markdown, opts \\ []) do
    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: objective,
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => opts[:level] || "medium"}}
      })

    result = Results.get_by_run(run)
    {:ok, running} = Results.mark_running(result)
    {:ok, ready} = Results.commit(running, markdown, source_count: opts[:source_count] || 1)
    ready
  end

  defp dag_node(key, kind, dependencies, params) do
    %{
      "key" => key,
      "kind" => kind,
      "title" => String.capitalize(key),
      "depends_on" => dependencies,
      "params" => params,
      "max_attempts" => 1
    }
  end
end
