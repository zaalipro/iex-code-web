defmodule IexCodeWeb.WorkspaceLiveAsyncRunsTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Runs
  alias IexCode.Engine.FleetSupervisor

  setup %{conn: conn} do
    {:ok, conn: %{conn | host: "localhost"}}
  end

  test "queues a durable background run and renders its replayable control plane", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#tab-btn-swarm") |> render_click()

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

    assert has_element?(view, "#async-run-#{run.id}")
    assert has_element?(view, "#async-run-dag-projection")
    assert has_element?(view, "#dag-execution-projection[data-engine='dag_v1']")
    assert has_element?(view, "#async-run-graph-and-controls[data-graph-mode='dag']")
    assert has_element?(view, "#async-run-control-timeline")
    refute has_element?(view, "#async-run-steps")

    {:ok, reconnected, _html} = live(conn, ~p"/sessions/#{session.id}")
    reconnected |> element("#tab-btn-swarm") |> render_click()

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
        "providers" => %{"duckduckgo" => "true"}
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
    assert "duckduckgo" in run.metadata["research"]["ranked_providers"]

    steps = Runs.list_steps(run)
    step_keys = Enum.map(steps, & &1.key)
    assert length(step_keys) == 20
    assert "research.plan.1" in step_keys
    assert "research.report.verify" in step_keys

    assert Enum.all?(
             Enum.filter(steps, &(&1.kind == "research_source_fetch")),
             &(&1.params["max_parallel_fetches"] == 4)
           )

    assert has_element?(view, "#async-run-research-manifest")
    assert has_element?(view, "#async-run-token-budget[data-budget-limit='100000']")
    assert has_element?(view, "#async-run-cost-budget", "Cost · reported or reserved")
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
    view |> element("#tab-btn-swarm") |> render_click()

    view |> element("#async-run-#{newest_run.id}") |> render_click()

    assert has_element?(view, "#async-run-#{newest_run.id}")
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='1']")
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
    view |> element("#tab-btn-swarm") |> render_click()

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
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> render_hook("toggle_settings_modal", %{})

    assert has_element?(view, "#settings-search-provider-count", "12 ranked adapters")

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

    assert has_element?(view, "#settings-provider-lifecycle-note-google", "sunsets 2027-01-01")

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
    view |> element("#tab-btn-swarm") |> render_click()
    view |> element("#async-run-#{waiting_run.id}") |> render_click()

    assert has_element?(view, "#workspace-lock-overview[data-lock-state='waiting']")
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
    view |> element("#tab-btn-swarm") |> render_click()

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
    view |> element("#tab-btn-swarm") |> render_click()

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
    view |> element("#tab-btn-swarm") |> render_click()

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
    view |> element("#tab-btn-swarm") |> render_click()

    assert has_element?(view, "#restart-run-agent-#{interrupted.agent_id}")
    view |> element("#restart-run-agent-#{interrupted.agent_id}") |> render_click()

    assert {:ok, replacement} =
             IexCode.Engine.FleetManager.current_agent(run.id, interrupted.agent_id)

    assert replacement.generation == old_generation + 1
    refute replacement.pid == old_pid
    refute_receive {:DOWN, ^sibling_ref, :process, _, _}, 50
    Process.demonitor(sibling_ref, [:flush])
  end
end
