defmodule IexCodeWeb.WorkspaceLiveSignalFoundryResearchTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Runs
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

    for research_path <- [~p"/research", ~p"/sessions/#{session.id}/research"] do
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
               "#return-to-instrument-deck-research[data-return-instrument-id='instrument-card-research']"
             )

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
    assert_push_patch(session_view, "/sessions/#{session.id}/research")

    assert has_element?(
             session_view,
             "#research-progress-dag #dag-execution-projection[data-engine='dag_v1']"
           )

    refute has_element?(session_view, "#research-progress-fallback")

    session_view |> element("#deep-research-run-#{legacy.id}") |> render_click()
    assert_push_patch(session_view, "/sessions/#{session.id}/research")
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
    assert_push_patch(view, "/research")
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
    assert_push_patch(view, "/sessions/#{session.id}/research")

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
      refute_receive {_, {:patch, _, _}}, 50
    end
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
             "#deep-research-result-open-#{result.id}[href='/research/#{result.id}/report'][target='_blank'][rel='noopener noreferrer']"
           )

    assert has_element?(
             view,
             "#deep-research-result-html-#{result.id}[href='/research/#{result.id}/report/download']"
           )

    assert has_element?(
             view,
             "#deep-research-result-md-#{result.id}[href='/research/#{result.id}/result/download']"
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

  defp assert_push_patch(%{proxy: {ref, topic, _proxy_pid}}, to) do
    assert_receive {^ref, {:patch, ^topic, %{to: ^to, kind: :push}}}
  end

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
