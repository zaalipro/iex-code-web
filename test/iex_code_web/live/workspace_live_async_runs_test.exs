defmodule IexCodeWeb.WorkspaceLiveAsyncRunsTest do
  use IexCode.E2E.Case, async: false
  require Ecto.Query

  alias IexCode.{Repo, Runs}
  alias IexCode.Engine.FleetSupervisor

  setup %{conn: conn} do
    {:ok, conn: %{conn | host: "localhost"}}
  end

  test "Mission Control validates four presentation modes without changing the selected run", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Keep the selected mission stable",
        kind: "analysis",
        mode: "single",
        status: "running"
      })

    {:ok, [agent]} =
      Runs.create_run_agents(run, [
        %{key: "stable-agent", role: "worker", display_name: "Stable worker"}
      ])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    for mode <- ~w(overview topology execution journal) do
      view |> element("#mission-control-mode-#{mode}") |> render_click()

      assert has_element?(
               view,
               "#mission-control-mode-#{mode}[aria-selected='true'][aria-controls='mission-control-panel-#{mode}']"
             )

      assert has_element?(view, "#mission-control-panel-#{mode}:not([hidden])")
      assert :sys.get_state(view.pid).socket.assigns.selected_run.id == run.id
    end

    view |> element("#toggle-run-setup") |> render_click()
    state_before = :sys.get_state(view.pid).socket.assigns
    agent_count_before = state_before.run_agent_count
    route_before = state_before.workspace_route
    active_view_before = state_before.active_view
    assert has_element?(view, "#run-agent-#{agent.id}")

    render_click(view, "switch_mission_control_mode", %{"mode" => "__invalid_mode__"})
    render_click(view, "switch_mission_control_mode", %{})
    render_click(view, "switch_mission_control_mode", %{"mode" => %{"journal" => "true"}})
    render_click(view, "switch_mission_control_mode", %{"mode" => ["overview"]})
    assert has_element?(view, "#mission-control-mode-journal[aria-selected='true']")
    assert has_element?(view, "#mission-control-panel-journal:not([hidden])")
    state_after = :sys.get_state(view.pid).socket.assigns
    assert state_after.selected_run.id == run.id
    assert state_after.run_setup_open?
    assert state_after.run_agent_count == agent_count_before
    assert state_after.workspace_route == route_before
    assert state_after.active_view == active_view_before
    assert has_element?(view, "#run-agent-#{agent.id}")
  end

  test "Mission Control phase prefers running then paused persisted steps", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Phase precedence",
        kind: "analysis",
        mode: "single",
        status: "queued"
      })

    {:ok, _completed} =
      Runs.create_step(run, %{
        key: "completed",
        kind: "analysis",
        title: "Newest completed phase",
        status: "completed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _paused} =
      Runs.create_step(run, %{
        key: "paused",
        kind: "analysis",
        title: "Paused phase",
        status: "paused"
      })

    {:ok, _running} =
      Runs.create_step(run, %{
        key: "running",
        kind: "analysis",
        title: "Running phase",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#mission-control-phase", "Running phase")
  end

  test "Mission Control completed phase uses timestamp tuple and deterministic ID ties", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Completed phase ordering",
        kind: "analysis",
        mode: "single",
        status: "completed"
      })

    completed_at = ~U[2026-08-28 12:00:00Z]
    inserted_at = ~U[2026-08-28 10:00:00Z]

    {:ok, first} =
      Runs.create_step(run, %{
        key: "first",
        kind: "analysis",
        title: "First completed",
        status: "completed",
        completed_at: completed_at
      })

    {:ok, second} =
      Runs.create_step(run, %{
        key: "second",
        kind: "analysis",
        title: "Second completed",
        status: "completed",
        completed_at: completed_at
      })

    for step <- [first, second] do
      step
      |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
      |> Repo.update!()
    end

    expected = if first.id > second.id, do: first.title, else: second.title
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#mission-control-phase", expected)
  end

  test "Mission Control completed phase honors completed, updated, inserted, then ID tiers", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Completed phase timestamp tiers",
        kind: "analysis",
        mode: "single",
        status: "completed"
      })

    steps =
      for {key, title} <- [
            {"completed-tier", "Completed timestamp wins"},
            {"updated-tier", "Updated timestamp wins"},
            {"inserted-tier", "Inserted timestamp wins"},
            {"id-tier", "ID tie candidate"}
          ] do
        {:ok, step} =
          Runs.create_step(run, %{
            key: key,
            kind: "analysis",
            title: title,
            status: "completed"
          })

        step
      end

    shared = ~U[2026-08-28 10:00:00Z]

    steps =
      Enum.map(steps, fn step ->
        force_step_times(step,
          completed_at: nil,
          inserted_at: shared,
          updated_at: shared
        )
      end)

    [completed_tier, updated_tier, inserted_tier, id_tier] = steps

    completed_tier = force_step_times(completed_tier, completed_at: ~U[2026-08-28 14:00:00Z])

    updated_tier = force_step_times(updated_tier, updated_at: ~U[2026-08-28 16:00:00Z])

    inserted_tier = force_step_times(inserted_tier, inserted_at: ~U[2026-08-28 17:00:00Z])

    id_tier = force_step_times(id_tier, inserted_at: ~U[2026-08-28 09:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#mission-control-phase", completed_tier.title)

    completed_tier = force_step_times(completed_tier, completed_at: nil)

    send(view.pid, {:run_step_updated, completed_tier})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#mission-control-phase", updated_tier.title)

    updated_tier = force_step_times(updated_tier, updated_at: shared)

    send(view.pid, {:run_step_updated, updated_tier})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#mission-control-phase", inserted_tier.title)

    inserted_tier = force_step_times(inserted_tier, inserted_at: shared)

    id_tier = force_step_times(id_tier, inserted_at: shared)

    expected =
      [completed_tier, updated_tier, inserted_tier, id_tier]
      |> Enum.max_by(& &1.id)
      |> Map.fetch!(:title)

    send(view.pid, {:run_step_updated, inserted_tier})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#mission-control-phase", expected)
  end

  test "entering Mission Control selects the bounded active mission in status order", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    runs =
      for {status, index} <- Enum.with_index(~w(completed draft queued paused running)) do
        {:ok, run} =
          Runs.create_run(%{
            project_id: project.id,
            session_id: session.id,
            objective: "#{status} mission #{index}",
            kind: "analysis",
            mode: "single",
            status: status
          })

        {status, run}
      end
      |> Map.new()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#async-run-#{runs["running"].id}[aria-pressed='true']")

    view |> element("#async-run-#{runs["completed"].id}") |> render_click()
    view |> element("#mission-control-mode-journal") |> render_click()
    assert has_element?(view, "#async-run-#{runs["completed"].id}[aria-pressed='true']")

    view |> element("#return-to-instrument-deck-swarm") |> render_click()
    view |> element("#instrument-card-swarm") |> render_click()
    assert has_element?(view, "#async-run-#{runs["running"].id}[aria-pressed='true']")

    {:ok, direct, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(direct, "#async-run-#{runs["running"].id}[aria-pressed='true']")
  end

  test "newest terminal fallback is insertion ordered when no active status exists", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, older} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Older terminal mission",
        kind: "analysis",
        mode: "single",
        status: "failed"
      })

    {:ok, newer} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Newer terminal mission",
        kind: "analysis",
        mode: "single",
        status: "completed"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    older_time = DateTime.add(now, -60, :second)
    newer_time = DateTime.add(now, -30, :second)

    Ecto.Query.from(r in Runs.Run, where: r.id == ^older.id)
    |> Repo.update_all(set: [inserted_at: older_time])

    Ecto.Query.from(r in Runs.Run, where: r.id == ^newer.id)
    |> Repo.update_all(set: [inserted_at: newer_time])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#async-run-#{newer.id}[aria-pressed='true']")
    refute has_element?(view, "#async-run-#{older.id}[aria-pressed='true']")
  end

  test "Mission Control falls back through paused, queued, draft, and terminal missions", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})

    cases = [
      {~w(completed draft queued paused), "paused"},
      {~w(completed draft queued), "queued"},
      {~w(completed draft), "draft"},
      {~w(interrupted), "interrupted"}
    ]

    for {statuses, expected_status} <- cases do
      session = create_session_fixture(project)

      runs =
        for status <- statuses, into: %{} do
          {:ok, run} =
            Runs.create_run(%{
              project_id: project.id,
              session_id: session.id,
              objective: "#{status} fallback mission",
              kind: "analysis",
              mode: "single",
              status: status
            })

          {status, run}
        end

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
      expected = Map.fetch!(runs, expected_status)
      assert has_element?(view, "#async-run-#{expected.id}[aria-pressed='true']")
    end
  end

  test "Mission Control renders an exact no-run fallback", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    start_supervised!(
      {IexCode.Runs.RunDispatcher,
       name: IexCode.Runs.RunDispatcher,
       worker_id: "mission-no-run-#{System.unique_integer([:positive])}",
       executor: IexCode.RunDispatcherTestExecutor,
       max_concurrency: 1,
       poll_interval: 60_000,
       heartbeat_interval: 60_000,
       lease_ms: 120_000,
       workspace_lock_retry_interval: 60_000,
       workspace_lock_lease_seconds: 120}
    )

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")

    assert has_element?(view, "#mission-control-hero", "No active run")
    assert has_element?(view, "#mission-control-signal", "No operator decision required")
  end

  test "Mission Control LiveView reports an offline dispatcher without active runs", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert Process.whereis(IexCode.Runs.RunDispatcher) == nil
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    assert has_element?(view, "#mission-control-signal", "Dispatcher offline")
  end

  test "Mission Control LiveView signal follows selected failure and interruption outcomes", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, failed} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Failed selected mission",
        kind: "analysis",
        mode: "single",
        status: "failed",
        error_message: "Raw failure detail must stay out of the signal"
      })

    {:ok, interrupted} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Interrupted selected mission",
        kind: "analysis",
        mode: "single",
        status: "interrupted"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    view |> element("#async-run-#{interrupted.id}") |> render_click()
    assert has_element?(view, "#mission-control-signal", "Selected run was interrupted")

    view |> element("#async-run-#{failed.id}") |> render_click()
    assert has_element?(view, "#mission-control-signal", "Selected run failed")
    refute has_element?(view, "#mission-control-signal", "Raw failure detail")
  end

  test "interactive session steering draft survives operation updates with a stable root", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, operation} =
      IexCode.Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "analysis",
        title: "Retain the operator draft",
        status: "running",
        progress: 10
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    view |> element("#mission-control-mode-execution") |> render_click()

    view
    |> form("#steering-form", %{"steering" => "Keep this draft"})
    |> render_change()

    assert has_element?(view, "#mission-control-interactive-slot #session-steering-input")

    send(view.pid, {:operation_updated, %{operation | progress: 60, status: "running"}})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#mission-control-interactive-slot #session-steering-input")
    assert has_element?(view, "#session-steering-input[value='Keep this draft']")
  end

  test "Mission Control owns one composer setup and interactive session tree", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Pin single interactive owners",
        kind: "analysis",
        mode: "single",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    view |> element("#mission-control-mode-execution") |> render_click()
    view |> element("#toggle-run-setup") |> render_click()

    document = view |> render() |> LazyHTML.from_fragment()

    for selector <- [
          "#instrument-workbench-swarm",
          "#new-goal-button[phx-click='open_goal_modal']",
          "#async-run-control",
          "#prompt-composer",
          "#prompt-form",
          "#run-setup-tray",
          "#run-setup-panel",
          "#mission-control-interactive-slot",
          "#steering-form",
          "#interactive-operation-history-note",
          "#interactive-role-templates",
          "#subagent-cards-grid",
          "#operation-tree-root",
          "#async-run-#{run.id}"
        ] do
      assert live_node_count(document, selector) == 1,
             "expected exactly one LiveView owner matching #{selector}"
    end

    for selector <- [
          "#prompt-form form",
          "#run-setup-panel form",
          "#async-run-steering-form form",
          "#steering-form form",
          "#prompt-form #async-run-steering-form",
          "#prompt-form #steering-form"
        ] do
      assert live_node_count(document, selector) == 0,
             "expected no nested or duplicated form matching #{selector}"
    end
  end

  test "stale operations-cleared messages reconcile the current session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    first_session = create_session_fixture(project)
    current_session = create_session_fixture(project)

    {:ok, _first_operation} =
      IexCode.Sessions.create_operation(%{
        session_id: first_session.id,
        agent_name: "ExplorerAgent",
        op_type: "scan",
        title: "Old session operation",
        status: "completed",
        progress: 100
      })

    {:ok, _current_operation} =
      IexCode.Sessions.create_operation(%{
        session_id: current_session.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "Current session operation",
        status: "completed",
        progress: 100
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{first_session.id}?view=swarm")
    render_patch(view, ~p"/sessions/#{current_session.id}?view=swarm")
    assert has_element?(view, "#operation-tree-root", "Current session operation")

    send(view.pid, :operations_cleared)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#operation-tree-root", "Current session operation")
    refute has_element?(view, "#operation-tree-root", "Old session operation")
  end

  test "queues a durable background run and renders its replayable control plane", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#async-run-control")
    assert has_element?(view, "#async-run-control", "Mission Control")
    assert has_element?(view, "#async-runs-empty")
    assert has_element?(view, "#dispatch-mode-background")
    assert render(view) =~ "Durable mode"

    view
    |> form("#prompt-form", %{"prompt" => "Audit concurrency and produce a safe patch"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.status == "queued"
    assert run.kind == "coding_swarm"
    assert run.mode == "swarm"
    refute Map.has_key?(run.metadata, "research")
    assert run.event_sequence >= 3

    assert Enum.map(Runs.list_steps(run), &{&1.key, &1.status}) == [
             {"prepare", "ready"},
             {"execute", "pending"}
           ]

    assert has_element?(view, "#async-run-#{run.id}")
    assert has_element?(view, "#async-run-detail")
    assert has_element?(view, "#async-run-step-#{hd(Runs.list_steps(run)).id}")
    assert has_element?(view, "#run-event-#{Runs.latest_event(run).id}")
    refute has_element?(view, "#async-run-research-manifest")
  end

  test "interactive mode keeps the legacy live-session path explicit", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#dispatch-mode-interactive") |> render_click()

    assert has_element?(view, "#dispatch-mode-interactive")
    assert render(view) =~ "Interactive mode"
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "queues a validated typed DAG and reconnects to its strict projection", %{
    conn: conn,
    workspace_path: path
  } do
    File.write!(Path.join(path, "README.md"), "receipt-payload-must-not-render")
    File.write!(Path.join(path, "PROJECT.md"), "private-result-must-not-render")
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{"run_setup" => %{"mode" => "dag"}})
    |> render_change()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "dag",
        "dag_manifest_json" => Jason.encode!(typed_dag_manifest())
      }
    })
    |> render_change()

    assert has_element?(view, "#run-setup-dag-manifest-json")

    view
    |> form("#prompt-form", %{"prompt" => "Inspect this project through a typed DAG"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.execution_engine == "dag_v1"
    assert run.kind == "analysis"
    assert run.mode == "workflow"
    assert is_binary(run.manifest_hash)
    assert length(Runs.list_steps(run)) == 4

    render_click(view, "switch_tab", %{"tab" => "swarm"})

    assert has_element?(view, "#async-run-#{run.id}")
    assert has_element?(view, "#async-run-dag-projection")
    assert has_element?(view, "#dag-execution-projection[data-engine='dag_v1']")
    assert has_element?(view, "#async-run-graph-and-controls[data-graph-mode='dag']")
    assert has_element?(view, "#async-run-control-timeline")
    refute has_element?(view, "#async-run-steps")

    {:ok, reconnected, _html} = live(conn, ~p"/sessions/#{session.id}")
    reconnected |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(reconnected, "#async-run-dag-projection")
    assert has_element?(reconnected, "#dag-node-#{hd(Runs.list_steps(run)).id}-desktop")

    html = render(reconnected)
    refute html =~ "receipt-payload-must-not-render"
    refute html =~ "private-result-must-not-render"
  end

  test "rejects malformed cyclic and unsupported DAG manifests without inserting a run", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{"run_setup" => %{"mode" => "dag"}})
    |> render_change()

    invalid_manifests = [
      "{malformed",
      Jason.encode!([
        dag_node("a", "aggregate", ["b"], %{}),
        dag_node("b", "aggregate", ["a"], %{})
      ]),
      Jason.encode!([dag_node("shell", "run_command", [], %{})])
    ]

    for manifest <- invalid_manifests do
      view
      |> form("#run-setup-panel", %{
        "run_setup" => %{"mode" => "dag", "dag_manifest_json" => manifest}
      })
      |> render_change()

      html =
        view
        |> form("#prompt-form", %{"prompt" => "This invalid DAG must fail closed"})
        |> render_submit()

      assert html =~ "Could not queue DAG"
      assert has_element?(view, "#run-setup-dag-manifest-json")
      assert has_element?(view, "#run-setup-dag-manifest-json", manifest)
      assert Runs.list_runs(session_id: session.id) == []
    end
  end

  test "persists a configured deep-research mission and renders its manifest", %{
    conn: conn,
    workspace_path: path
  } do
    configure_research_providers!(["tavily", "duckduckgo"])

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()
    assert has_element?(view, "#run-setup-panel")

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "priority" => "high",
        "max_attempts" => "4",
        "token_budget" => "100000",
        "cost_budget_cents" => "5000",
        "time_budget_minutes" => "45",
        "research_level" => "high",
        "research_max_sources" => "18",
        "providers" => %{"tavily" => "true", "duckduckgo" => "true"}
      }
    })
    |> render_change()

    assert has_element?(view, "#run-setup-research-attempt-policy")
    refute has_element?(view, "#run-setup-max-attempts")

    view
    |> form("#prompt-form", %{"prompt" => "/research compare durable agent control planes"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.kind == "deep_research"
    assert run.mode == "research"
    assert run.execution_engine == "dag_v1"
    assert run.priority == "high"
    assert run.max_attempts == 1
    assert run.token_budget == 100_000
    assert run.cost_budget_cents == 5_000
    assert run.time_budget_ms == 2_700_000

    assert run.metadata["research"]["level"] == "high"

    assert run.metadata["research"]["level_policy"] == %{
             "level" => "high",
             "multistep_rounds" => 3,
             "lead_per_step" => 1,
             "async_subagents" => 4
           }

    assert run.metadata["research"]["max_sources"] == 18
    assert run.metadata["research"]["fetch_parallelism"] == 4
    assert run.metadata["research"]["ranked_providers"] == ["tavily", "duckduckgo"]

    steps = Runs.list_steps(run)
    step_keys = Enum.map(steps, & &1.key)
    assert step_keys == Enum.sort(high_research_step_keys(["tavily", "duckduckgo"]))

    assert Enum.all?(
             Enum.filter(steps, &(&1.kind == "research_source_fetch")),
             &(&1.params["max_parallel_fetches"] == 4)
           )

    render_click(view, "switch_tab", %{"tab" => "swarm"})

    assert has_element?(view, "#async-run-research-manifest")
    assert has_element?(view, "#async-run-token-budget[data-budget-limit='100000']")
    assert has_element?(view, "#async-run-cost-budget", "Cost · reported or reserved")
  end

  defp configure_research_providers!(enabled_providers) do
    settings = Settings.get_settings()

    providers =
      Map.new(settings.search_providers, fn {provider, config} ->
        {provider, Map.put(config, "enabled", provider in enabled_providers)}
      end)
      |> put_in(["tavily", "api_key"], "tavily-test-key")

    assert {:ok, _settings} =
             Settings.update_settings(%{
               search_providers: providers,
               search_provider_order: enabled_providers
             })
  end

  defp high_research_step_keys(providers) do
    Enum.flat_map(1..3, fn round ->
      ["research.plan.#{round}"] ++
        Enum.map(providers, &"research.search.ranked.#{round}.#{&1}") ++
        [
          "research.evidence.merge.#{round}",
          "research.source.fetch.#{round}",
          "research.evidence.audit.#{round}"
        ]
    end) ++ ["research.report.synthesize", "research.report.verify"]
  end

  defp typed_dag_manifest do
    [
      dag_node("inventory", "project_inventory", [], %{"path" => "."}),
      dag_node("read_readme", "read_file", ["inventory"], %{"path" => "README.md"}),
      dag_node("read_project", "read_file", ["inventory"], %{"path" => "PROJECT.md"}),
      dag_node("aggregate", "aggregate", ["read_readme", "read_project"], %{})
    ]
  end

  defp dag_node(key, kind, dependencies, params) do
    %{
      "key" => key,
      "kind" => kind,
      "title" => key |> String.replace("_", " ") |> String.capitalize(),
      "depends_on" => dependencies,
      "params" => params,
      "max_attempts" => 2
    }
  end

  defp force_step_times(step, attrs) do
    Ecto.Query.from(s in IexCode.Runs.RunStep, where: s.id == ^step.id)
    |> Repo.update_all(set: attrs)

    Repo.get!(IexCode.Runs.RunStep, step.id)
  end

  test "requires an explicit provider for a deep-research mission", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "providers" =>
          Map.new(~w(tavily brave exa serper google bing searxng duckduckgo), &{&1, "false"})
      }
    })
    |> render_change()

    refute has_element?(view, "#run-setup-provider-duckduckgo[checked]")

    view
    |> form("#prompt-form", %{"prompt" => "/research durable agent control planes"})
    |> render_submit()

    assert has_element?(view, "#run-setup-panel")
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "research setup mode always uses the exact DAG even from interactive dispatch", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#dispatch-mode-interactive") |> render_click()
    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "research_level" => "low",
        "providers" => %{"duckduckgo" => "true"}
      }
    })
    |> render_change()

    view
    |> form("#prompt-form", %{"prompt" => "Compare the current coordination choices"})
    |> render_submit()

    assert [run] = Runs.list_runs(session_id: session.id)
    assert run.execution_engine == "dag_v1"
    assert run.metadata["research"]["level"] == "low"
  end

  test "rejects selecting a durable run from another session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    other_session = create_session_fixture(project)

    {:ok, foreign_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: other_session.id,
        objective: "Foreign run",
        kind: "analysis",
        mode: "single"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    html = render_click(view, "select_async_run", %{"id" => foreign_run.id})

    assert html =~ "Run not found in this session"
    refute has_element?(view, "#async-run-#{foreign_run.id}")
  end

  test "counts pending approvals across the session while keeping detail selection scoped", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    foreign_session = create_session_fixture(project)

    {:ok, run_with_approval} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Older run awaiting review",
        kind: "analysis",
        mode: "single"
      })

    {:ok, approval} =
      Runs.request_approval(run_with_approval, %{
        key: "approve-older-run",
        action: "workspace_write",
        resource: "lib/example.ex",
        reason: "Review the generated change"
      })

    {:ok, foreign_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: foreign_session.id,
        objective: "Foreign session approval",
        kind: "analysis",
        mode: "single"
      })

    {:ok, _foreign_approval} =
      Runs.request_approval(foreign_run, %{
        key: "foreign-session-approval",
        action: "workspace_write",
        resource: "lib/foreign.ex",
        reason: "Must not count in the current session"
      })

    {:ok, newest_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Newest run without approvals",
        kind: "analysis",
        mode: "single"
      })

    assert Runs.count_pending_approvals(session.id) == 1

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    view |> element("#async-run-#{newest_run.id}") |> render_click()

    assert has_element?(view, "#async-run-#{newest_run.id}")
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='1']")
    assert has_element?(view, "#mission-control-signal", "Session has 1 pending approval")
    refute has_element?(view, "#async-run-approval-#{approval.id}")

    assert {:ok, _decided} =
             Runs.decide_approval(approval, "denied", %{
               decided_by: "test-user",
               decision_note: "Not approved"
             })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='0']")

    view |> element("#async-run-#{run_with_approval.id}") |> render_click()

    assert has_element?(view, "#async-run-approval-#{approval.id}")
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='0']")
    refute has_element?(view, "#mission-control-signal", "Session has 1 pending approval")
  end

  test "Execution approval controls persist approved and denied durable outcomes", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Exercise approval outcomes",
        kind: "analysis",
        mode: "single",
        status: "queued"
      })

    {:ok, approved} =
      Runs.request_approval(run, %{
        key: "approval-approved",
        action: "workspace_write",
        resource: "lib/approved.ex",
        reason: "Approve this durable action"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=swarm")
    view |> element("#mission-control-mode-execution") |> render_click()

    assert has_element?(
             view,
             "#approve-run-action-#{approved.id}[phx-click='decide_run_approval'][phx-value-decision='approved']"
           )

    view |> element("#approve-run-action-#{approved.id}") |> render_click()
    assert Runs.get_approval(approved.id).status == "approved"
    assert has_element?(view, "#flash-info", "Approval decision persisted")

    {:ok, denied} =
      Runs.request_approval(run, %{
        key: "approval-denied",
        action: "git_write",
        resource: "lib/denied.ex",
        reason: "Deny this durable action"
      })

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#deny-run-action-#{denied.id}[phx-click='decide_run_approval'][phx-value-decision='denied']"
           )

    view |> element("#deny-run-action-#{denied.id}") |> render_click()
    assert Runs.get_approval(denied.id).status == "denied"
    assert has_element?(view, "#flash-info", "Approval decision persisted")
  end

  test "durable run PubSub updates refresh mission summary without changing explicit selection",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, selected} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Keep this workbench selection",
        kind: "analysis",
        mode: "single",
        status: "queued"
      })

    {:ok, active} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Live mission summary",
        kind: "analysis",
        mode: "single",
        status: "queued"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()
    view |> element("#async-run-#{selected.id}") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.selected_run.id == selected.id

    view |> element("#mission-control-mode-execution") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.selected_run.id == selected.id

    selected_update =
      selected
      |> Ecto.Changeset.change(progress: 12)
      |> Repo.update!()

    send(view.pid, {:run_updated, selected_update})
    _ = :sys.get_state(view.pid)
    assert :sys.get_state(view.pid).socket.assigns.selected_run.id == selected_update.id
    assert has_element?(view, "#async-run-#{selected.id}[data-run-status='queued']")

    {:ok, _updated} = Runs.transition_run(active, "running", %{progress: 42})
    _ = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.selected_run.id == selected.id
    assert assigns.instrument_summaries["swarm"].primary == "Live mission summary"
    assert %{label: "Progress", value: "42%"} in assigns.instrument_summaries["swarm"].secondary

    view |> element("#return-to-instrument-deck-swarm") |> render_click()
    view |> element("#instrument-card-swarm") |> render_click()
    assert has_element?(view, "#async-run-#{active.id}[aria-pressed='true']")
  end

  test "renders honest dispatcher state and accessible asynchronous progress", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Accessible progress run",
        kind: "analysis",
        mode: "single",
        progress: 37
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#async-dispatcher-status[role='status']")
    assert has_element?(view, "#async-run-metrics[aria-live='polite']")
    assert has_element?(view, "#async-run-events[role='log'][aria-live='polite']")

    assert has_element?(
             view,
             "#async-run-#{run.id} [role='progressbar'][aria-valuenow='37'][aria-valuemin='0'][aria-valuemax='100']"
           )

    offline_html =
      render_component(&IexCodeWeb.RunComponents.run_control_plane/1,
        runs: [],
        run_count: 0,
        run_counts: %{active: 0, queued: 0, attention: 0, approvals: 0},
        selected_run: nil,
        steps: [],
        events: [],
        approvals: [],
        artifacts: [],
        stats: %{online: false, capacity: 0}
      )

    offline_document = LazyHTML.from_fragment(offline_html)

    assert LazyHTML.query(offline_document, "#async-dispatcher-status") |> LazyHTML.text() =~
             "Dispatcher offline"
  end

  test "renders the ranked search registry with honest lifecycle controls", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings#research")
    view |> element("#settings-provider-advanced-serpapi") |> render_click()

    assert has_element?(view, "#settings-search-provider-tavily")

    assert has_element?(
             view,
             "#settings-search-provider-perplexity[data-provider-lifecycle='active']"
           )

    assert has_element?(
             view,
             "#settings-search-provider-firecrawl[data-provider-lifecycle='active']"
           )

    assert has_element?(
             view,
             "#settings-search-provider-linkup[data-provider-lifecycle='active']"
           )

    assert has_element?(
             view,
             "#settings-search-provider-serpapi[data-provider-lifecycle='active']"
           )

    assert has_element?(view, "#settings-provider-engine-serpapi")

    assert has_element?(
             view,
             "#settings-search-provider-bing[data-provider-lifecycle='retired'] #settings-provider-enabled-bing[disabled]"
           )

    assert has_element?(
             view,
             "#settings-search-provider-google[data-provider-lifecycle='sunsetting']"
           )

    assert has_element?(
             view,
             "#settings-search-provider-duckduckgo[data-provider-lifecycle='unofficial']"
           )
  end

  test "renders durable workspace lock ownership and wait state in Mission Control", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, held_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Hold the project mutation boundary",
        kind: "coding_swarm",
        mode: "swarm",
        status: "running"
      })

    {:ok, waiting_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Wait for the project mutation boundary",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, held} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        session_id: session.id,
        run_id: held_run.id,
        owner_id: "mission-control-holder",
        resource_type: "project",
        resource_key: ".",
        mode: "exclusive"
      })

    {:ok, waiting} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        session_id: session.id,
        run_id: waiting_run.id,
        owner_id: "mission-control-waiter",
        resource_type: "project",
        resource_key: ".",
        mode: "exclusive"
      })

    held_lock = hd(held.locks)
    waiting_lock = hd(waiting.locks)
    assert held_lock.status == "held"
    assert waiting_lock.status == "waiting"

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()
    view |> element("#async-run-#{waiting_run.id}") |> render_click()

    assert has_element?(view, "#workspace-lock-overview[data-lock-state='waiting']")

    assert has_element?(
             view,
             "#mission-control-signal",
             "Selected run is waiting for workspace access"
           )

    assert has_element?(view, "#workspace-lock-details")
    assert has_element?(view, "#workspace-lock-#{held_lock.id}[data-lock-status='held']")
    assert has_element?(view, "#workspace-lock-#{waiting_lock.id}[data-lock-status='waiting']")

    assert has_element?(
             view,
             "#async-run-#{held_run.id}[data-workspace-lock-state='held']"
           )

    assert has_element?(
             view,
             "#async-run-#{waiting_run.id}[data-workspace-lock-state='waiting']"
           )

    view |> element("#async-run-#{held_run.id}") |> render_click()
    assert has_element?(view, "#mission-control-signal", "Selected run holds the workspace lock")
  end

  test "streams the selected run fleet and resets it when selection changes", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, first_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Materialize a dynamic fleet",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#run-agent-fleet[data-fleet-state='empty']")

    assert {:ok, [agent]} =
             Runs.create_run_agents(first_run, [
               %{
                 key: "security-reviewer:01",
                 role: "security-reviewer",
                 adapter: "durable-worker",
                 display_name: "Security reviewer"
               }
             ])

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#run-agent-#{agent.id}[data-agent-status='pending']")
    assert has_element?(view, "#run-agent-fleet-summary", "1")

    {:ok, second_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "A different selected run",
        kind: "analysis",
        mode: "single"
      })

    _ = :sys.get_state(view.pid)
    view |> element("#async-run-#{second_run.id}") |> render_click()
    assert has_element?(view, "#async-run-#{second_run.id}")
    assert has_element?(view, "#run-agent-fleet[data-fleet-state='empty']")
    refute has_element?(view, "#run-agent-#{agent.id}")

    html = render_click(view, "control_run_agent", %{"id" => agent.id, "action" => "cancel"})
    assert html =~ "Agent not found in the selected run"
  end

  test "targets pause and steering controls to exactly one selected-run agent", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Control one durable worker",
        kind: "coding_swarm",
        mode: "swarm",
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: "workspace-fleet-control",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, entries} =
             FleetSupervisor.attach(run,
               agent_count: 4,
               session: session,
               project_root: path,
               allowed_tools: []
             )

    [target, untouched | _rest] = entries
    target_id = target.agent_id
    untouched_id = untouched.agent_id

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#pause-run-agent-#{target_id}")
    view |> element("#pause-run-agent-#{target_id}") |> render_click()

    assert Runs.get_run_agent(target_id).status == "paused"
    assert Runs.get_run_agent(untouched_id).status == "idle"
    assert Enum.map(Runs.list_run_agent_controls(target_id), & &1.kind) == ["pause"]
    assert Runs.list_run_agent_controls(untouched_id) == []

    view
    |> form("#run-agent-steering-form-#{target_id}", %{
      "agent_id" => target_id,
      "agent_control" => %{"guidance" => "Audit only the authorization boundary"}
    })
    |> render_submit()

    assert_push_event(view, "reset_run_agent_guidance", %{agent_id: ^target_id})

    assert Enum.map(Runs.list_run_agent_controls(target_id), & &1.kind) == ["pause", "steer"]
    assert Runs.list_run_agent_controls(untouched_id) == []

    assert has_element?(
             view,
             "#run-agent-control-receipt-#{target_id}[data-control-status='applied'][data-control-result-status='queued']"
           )

    assert ["Audit only the authorization boundary"] =
             IexCode.Engine.FleetManager.drain_steering(run.id, target_id)

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#run-agent-control-receipt-#{target_id}[data-control-result-status='consumed']"
           )
  end

  test "preserves agent guidance and does not push a client reset when dispatch fails", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Preserve operator guidance on failure",
        kind: "coding_swarm",
        mode: "swarm",
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: "workspace-guidance-failure",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "coder", role: "coder"}])
    {:ok, agent} = Runs.claim_run_agent(agent, "fleet:unavailable-ui-test", 60_000)

    {:ok, agent} =
      Runs.transition_run_agent(agent, "idle", %{},
        lease_owner: "fleet:unavailable-ui-test",
        lease_generation: agent.lease_generation
      )

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    guidance = "Keep this exact guidance after the dispatcher error"

    form =
      form(view, "#run-agent-steering-form-#{agent.id}", %{
        "agent_id" => agent.id,
        "agent_control" => %{"guidance" => guidance}
      })

    render_change(form)
    html = render_submit(form)
    agent_id = agent.id

    assert html =~ "Agent steering failed"
    refute_push_event(view, "reset_run_agent_guidance", %{agent_id: ^agent_id})

    assert has_element?(
             view,
             "#run-agent-steering-input-#{agent.id}[value='#{guidance}']"
           )
  end

  test "restarts an interrupted durable worker from Mission Control without disturbing siblings",
       %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Recover one durable worker",
        kind: "coding_swarm",
        mode: "swarm",
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: "workspace-fleet-restart",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, entries} =
             FleetSupervisor.attach(run,
               agent_count: 4,
               session: session,
               project_root: path,
               allowed_tools: []
             )

    interrupted = Enum.find(entries, &(&1.role == :explorer))
    sibling = Enum.find(entries, &(&1.role == :planner))
    sibling_ref = Process.monitor(sibling.pid)
    old_pid = interrupted.pid
    old_generation = interrupted.generation
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 2_000

    manager = IexCode.Engine.AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(manager)
    assert Runs.get_run_agent(interrupted.agent_id).status == "interrupted"

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#instrument-card-swarm") |> render_click()

    assert has_element?(view, "#restart-run-agent-#{interrupted.agent_id}")
    view |> element("#restart-run-agent-#{interrupted.agent_id}") |> render_click()

    assert {:ok, replacement} =
             IexCode.Engine.FleetManager.current_agent(run.id, interrupted.agent_id)

    assert replacement.generation == old_generation + 1
    refute replacement.pid == old_pid
    refute_receive {:DOWN, ^sibling_ref, :process, _, _}, 50
    Process.demonitor(sibling_ref, [:flush])
  end

  defp live_node_count(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
    |> length()
  end
end
