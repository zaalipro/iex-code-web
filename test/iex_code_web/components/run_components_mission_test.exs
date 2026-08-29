defmodule IexCodeWeb.RunComponentsMissionTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents

  alias IexCode.Runs.{Run, RunAgent, RunArtifact, RunApproval, RunEvent, RunStep}
  alias IexCodeWeb.RunComponents

  test "renders a single Mission Control chassis with four local modes and one visible panel" do
    run = run_fixture("mission-1", "Sensitive objective", "running", 43)
    assigns = %{run: run}

    html =
      rendered_to_string(~H"""
      <.workbench_chassis
        id="instrument-workbench-swarm"
        surface="swarm"
        index="01"
        title="Active Mission"
        status="Running"
        return_to="/sessions/session-1?view=deck"
        return_instrument_id="instrument-card-swarm"
      >
        <:primary_action>
          <button id="new-goal-button" phx-click="open_goal_modal">New mission</button>
        </:primary_action>
        <:local_modes><RunComponents.mission_control_tabs mode="overview" /></:local_modes>
        <:primary_field>
          <RunComponents.run_control_plane
            runs={[@run]}
            run_count={1}
            run_counts={%{active: 1, queued: 0, attention: 0, approvals: 0}}
            selected_run={@run}
            steps={[]}
            events={[]}
            approvals={[]}
            artifacts={[]}
            controls={[]}
            stats={%{online: true, capacity: 1}}
            workspace_locks={[]}
            agents={[]}
            agent_count={0}
            fleet_summary={%{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0}}
            fleet_loading={false}
            agent_guidance={%{}}
            agent_receipts={%{}}
            dag_projection={nil}
          >
            <:interactive_execution>
              <div id="interactive-coach-sentinel">Interactive coach</div>
            </:interactive_execution>
          </RunComponents.run_control_plane>
        </:primary_field>
        <:signal_panel>
          <div id="mission-control-signal-panel">No operator decision required</div>
        </:signal_panel>
      </.workbench_chassis>
      """)

    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.filter("#instrument-workbench-swarm") |> LazyHTML.to_tree() |> length() ==
             1

    assert node_count(doc, "#new-goal-button[phx-click='open_goal_modal']") == 1
    assert node_count(doc, "#mission-control-signal-panel") == 1
    assert node_count(doc, "#interactive-coach-sentinel") == 1
    assert node_count(doc, "#mission-control-panel-execution #interactive-coach-sentinel") == 1
    assert node_count(doc, "#instrument-workbench-swarm [phx-click='switch_tab']") == 0

    for mode <- ~w(overview topology execution journal) do
      assert node_count(
               doc,
               "#mission-control-mode-#{mode}[type='button'][role='tab'][tabindex='0'][phx-click='switch_mission_control_mode'][phx-value-mode='#{mode}'][aria-controls='mission-control-panel-#{mode}']"
             ) == 1

      assert node_count(
               doc,
               "#mission-control-panel-#{mode}[role='tabpanel'][aria-labelledby='mission-control-mode-#{mode}']"
             ) == 1
    end

    assert LazyHTML.query(doc, "#mission-control-mode-overview[aria-selected='true']")
    assert selected_tab_count(doc) == 1
    assert node_count(doc, "[role='tabpanel']:not([hidden])") == 1
    assert node_count(doc, "#async-run-control") == 1
    assert node_count(doc, "#run-agent-fleet") == 1
    assert node_count(doc, "#run-agent-fleet-list[phx-update='stream']") == 1
    assert node_count(doc, "#async-run-list") == 1
    assert node_count(doc, "#async-run-detail") == 1
    assert node_count(doc, "#async-run-actions") == 1
    assert node_count(doc, "#async-run-steering-form") == 1
    assert node_count(doc, "#async-run-budget-meters") == 1
    assert node_count(doc, "#async-run-graph-and-controls") == 1
    assert node_count(doc, "#async-run-control-timeline") == 1
    assert node_count(doc, "#async-run-events") == 1

    assert LazyHTML.query(
             doc,
             "#return-to-instrument-deck-swarm[data-phx-link='patch'][data-phx-link-state='replace'][data-return-instrument-id='instrument-card-swarm']"
           )

    assert LazyHTML.query(doc, "#mission-control-waveform[aria-hidden='true']")
    assert LazyHTML.query(doc, "#mission-control-panel-overview:not([hidden])")
    assert LazyHTML.query(doc, "#mission-control-panel-topology[hidden]")
    assert LazyHTML.query(doc, "#mission-control-panel-execution[hidden]")
    assert LazyHTML.query(doc, "#mission-control-panel-journal[hidden]")
    refute LazyHTML.text(LazyHTML.query(doc, "#mission-control-hero")) =~ run.objective
  end

  test "legacy projection renders each populated durable group once under a labelled disclosure" do
    run =
      "legacy-run"
      |> run_fixture("Legacy projection objective", "running", 42)
      |> Map.put(:kind, "deep_research")
      |> Map.put(:token_budget, 1_000)
      |> Map.put(:cost_budget_cents, 500)
      |> Map.put(:time_budget_ms, 60_000)

    step = %RunStep{
      id: "step-legacy",
      run_id: run.id,
      key: "verify",
      kind: "analysis",
      title: "Verify persisted state",
      status: "running",
      progress: 42,
      depends_on: ["prepare"]
    }

    lock = %{
      id: "lock-legacy",
      run_id: run.id,
      status: "held",
      resource_type: "project",
      resource_key: ".",
      owner_id: "durable-owner",
      mode: "exclusive"
    }

    agent = %RunAgent{
      id: "agent-legacy",
      run_id: run.id,
      key: "verifier:01",
      role: "verifier",
      display_name: "Verifier",
      status: "running",
      progress: 42,
      current_task: "Verify persisted state",
      error_message: String.duplicate("unbroken-error-token", 8)
    }

    approval = %RunApproval{
      id: "approval-legacy",
      run_id: run.id,
      key: "approve-write",
      action: "workspace_write",
      reason: "Review the persisted patch",
      status: "pending"
    }

    artifact = %RunArtifact{
      id: "artifact-legacy",
      run_id: run.id,
      kind: "report",
      name: "Verification report",
      uri: "artifact://verification",
      metadata: %{
        "preview" => "Persisted preview",
        "content" => "Persisted full artifact",
        "sources" => [%{"title" => "Evidence", "url" => "https://example.test/evidence"}]
      }
    }

    event = %RunEvent{
      id: "event-legacy",
      run_id: run.id,
      sequence: 7,
      type: "run.progressed",
      source: "worker",
      payload: %{"message" => "Persisted event"},
      occurred_at: ~U[2026-08-28 12:00:00Z]
    }

    html =
      render_component(&RunComponents.run_control_plane/1,
        runs: [run],
        run_count: 1,
        run_counts: %{active: 1, queued: 0, attention: 0, approvals: 1},
        selected_run: run,
        steps: [step],
        events: [event],
        approvals: [approval],
        artifacts: [artifact],
        controls: [%{id: "control-legacy", kind: "steer", status: "applied"}],
        run_manifest: %{mode: "research", providers: ["tavily"], depth: "high"},
        stats: %{online: true, capacity: 1},
        workspace_locks: [lock],
        agents: [{"run-agent-agent-legacy", agent}],
        agent_count: 1,
        fleet_summary: %{active: 1, paused: 0, attention: 1, recovering: 0, tokens: 0},
        fleet_loading: false,
        mode: "overview",
        phase: "Verify persisted state",
        dag_projection: nil,
        interactive_execution: [
          %{
            inner_block: fn _changed, _assigns ->
              Phoenix.HTML.raw("<div id=\"interactive-execution-sentinel\">Interactive</div>")
            end
          }
        ]
      )

    doc = LazyHTML.from_fragment(html)

    for selector <- [
          "#async-run-control",
          "#async-run-heading",
          "#async-dispatcher-status",
          "#workspace-lock-overview",
          "#workspace-lock-details",
          "#workspace-lock-lock-legacy",
          "#async-run-metrics",
          "#async-run-list",
          "#async-run-legacy-run",
          "#async-run-detail",
          "#async-run-actions",
          "#async-run-steering-form",
          "#async-run-research-manifest",
          "#async-run-budget-meters",
          "#run-agent-fleet",
          "#run-agent-fleet-list[phx-update='stream']",
          "#run-agent-agent-legacy",
          "#run-agent-error-agent-legacy",
          "#async-run-graph-and-controls[data-graph-mode='legacy']",
          "#async-run-steps",
          "#async-run-step-step-legacy",
          "#async-run-control-timeline",
          "#async-run-control-entry-control-legacy",
          "#async-run-approval-approval-legacy",
          "#approve-run-action-approval-legacy",
          "#deny-run-action-approval-legacy",
          "#mission-control-interactive-slot",
          "#async-run-events[role='log']",
          "#run-event-event-legacy",
          "#async-run-artifacts",
          "#async-run-artifact-artifact-legacy",
          "#async-run-artifact-preview-artifact-legacy",
          "#async-run-artifact-detail-artifact-legacy",
          "#async-run-artifact-sources-artifact-legacy",
          "#async-run-artifact-source-artifact-legacy-0"
        ] do
      assert node_count(doc, selector) == 1, "expected one durable node matching #{selector}"
    end

    refute node_count(doc, "#async-run-dag-projection") > 0

    for selector <- [
          "#workspace-lock-overview",
          "#async-run-metrics",
          "#async-run-list",
          "#async-run-detail",
          "#run-agent-fleet",
          "#async-run-graph-and-controls",
          "#async-run-actions",
          "#async-run-steering-form",
          "#async-run-budget-meters",
          "#async-run-control-timeline",
          "#async-run-approval-approval-legacy",
          "#mission-control-interactive-slot",
          "#async-run-events",
          "#async-run-artifacts"
        ] do
      details_selector =
        if selector == "#async-run-artifacts",
          do: "details#async-run-artifacts:has(> summary)",
          else: "details:has(> summary) #{selector}"

      assert node_count(doc, details_selector) == 1,
             "expected #{selector} beneath a labelled native disclosure"
    end
  end

  test "DAG projection renders authorized persisted layers once and fails closed without one" do
    run =
      "dag-run"
      |> run_fixture("DAG objective", "running", 34)
      |> Map.put(:execution_engine, "dag_v1")

    projection = %{
      engine: "dag_v1",
      available?: true,
      summary: %{
        ready: 1,
        running: 1,
        blocked: 0,
        approval: 0,
        retrying: 0,
        completed: 1,
        failed: 0
      },
      layers: [
        [
          %{
            id: "step-plan",
            key: "plan",
            title: "Plan",
            kind: "planner",
            status: "completed",
            readiness: :terminal,
            progress: 100,
            attempt: 1,
            max_attempts: 1,
            depends_on: []
          }
        ],
        [
          %{
            id: "step-code",
            key: "code",
            title: "Code",
            kind: "coder",
            status: "running",
            readiness: :leased,
            progress: 34,
            attempt: 1,
            max_attempts: 3,
            depends_on: ["plan"]
          }
        ]
      ]
    }

    doc = run_control_document(run, projection)
    assert node_count(doc, "#async-run-dag-projection") == 1
    assert node_count(doc, "#dag-execution-projection[data-engine='dag_v1']") == 1
    assert node_count(doc, "#dag-layer-0") == 1
    assert node_count(doc, "#dag-layer-1") == 1
    assert node_count(doc, "#dag-node-step-code-desktop[data-node-key='code']") == 1
    assert compact_text(LazyHTML.query(doc, "#dag-node-step-code-desktop")) =~ "After plan"
    assert node_count(doc, "#async-run-steps") == 0
    assert node_count(doc, "#async-run-dag-unavailable") == 0

    unavailable = run_control_document(run, nil)
    assert node_count(unavailable, "#async-run-dag-unavailable[role='status']") == 1
    assert node_count(unavailable, "#async-run-dag-projection") == 0
    assert node_count(unavailable, "#dag-execution-projection") == 0
    assert node_count(unavailable, "#async-run-steps") == 0

    assert compact_text(LazyHTML.query(unavailable, "#async-run-dag-unavailable")) ==
             "Execution topology unavailable"
  end

  test "signal panel uses truthful precedence and exact no-action fallback" do
    run = run_fixture("mission-2", "Objective sentinel", "failed", 101)

    html =
      render_component(&RunComponents.mission_control_signal_panel/1,
        selected_run: run,
        run_counts: %{approvals: 2},
        workspace_locks: [],
        stats: %{online: false}
      )

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "#mission-control-signal-panel")
    assert LazyHTML.text(doc) =~ "Session has 2 pending approvals"
    refute LazyHTML.text(doc) =~ run.objective

    quiet =
      render_component(&RunComponents.mission_control_signal_panel/1,
        selected_run: nil,
        run_counts: %{approvals: 0},
        workspace_locks: [],
        stats: %{online: true}
      )

    assert LazyHTML.text(LazyHTML.from_fragment(quiet)) =~ "No operator decision required"
  end

  test "hero exposes clamped persisted progress without sensitive fields" do
    run = %Run{
      id: "run-sensitive-id",
      objective: "objective-secret",
      status: "running",
      progress: 140,
      lease_owner: "lease-secret",
      error_message: "error-secret"
    }

    html =
      render_component(&RunComponents.mission_control_hero/1, selected_run: run, phase: "Execute")

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "#mission-control-hero")

    assert LazyHTML.query(
             doc,
             "#mission-control-waveform[aria-hidden='true'][data-progress='100']"
           )

    assert LazyHTML.query(doc, "[role='progressbar'][aria-valuenow='100']")
    assert compact_text(LazyHTML.query(doc, "#mission-control-progress-text")) == "100%"
    hero_text = LazyHTML.text(LazyHTML.query(doc, "#mission-control-hero"))
    refute hero_text =~ "objective-secret"
    refute hero_text =~ "run-sensitive-id"
    refute hero_text =~ "lease-secret"
    refute hero_text =~ "error-secret"
    refute hero_text =~ "prompt-secret"
    refute hero_text =~ "#PID<0.99.0>"
    refute hero_text =~ "/private/workspace/path"
  end

  test "signal precedence stays scoped to session approvals and the selected run" do
    run = run_fixture("selected-run", "Sensitive objective", "failed", 30)

    held = %{
      id: "sensitive-lock-id",
      run_id: run.id,
      status: "held",
      resource_key: "/private/path"
    }

    waiting = %{id: "waiting-lock-id", run_id: run.id, status: "waiting"}
    unrelated = %{id: "other-lock-id", run_id: "other-run", status: "held"}

    cases = [
      {%{approvals: 1}, [held], %{online: false}, "Session has 1 pending approval"},
      {%{approvals: 0}, [waiting, held], %{online: false},
       "Selected run holds the workspace lock"},
      {%{approvals: 0}, [waiting], %{online: false},
       "Selected run is waiting for workspace access"},
      {%{approvals: 0}, [unrelated], %{online: false}, "Selected run failed"}
    ]

    for {run_counts, locks, stats, expected} <- cases do
      html =
        render_component(&RunComponents.mission_control_signal_panel/1,
          selected_run: run,
          run_counts: run_counts,
          workspace_locks: locks,
          stats: stats
        )

      signal = html |> LazyHTML.from_fragment() |> LazyHTML.query("#mission-control-signal")
      assert compact_text(signal) == expected
      refute LazyHTML.text(signal) =~ "sensitive-lock-id"
      refute LazyHTML.text(signal) =~ "/private/path"
      refute LazyHTML.text(signal) =~ run.objective
    end

    interrupted = %{run | status: "interrupted"}

    html =
      render_component(&RunComponents.mission_control_signal_panel/1,
        selected_run: interrupted,
        run_counts: %{approvals: 0},
        workspace_locks: [],
        stats: %{online: false}
      )

    assert compact_text(
             html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#mission-control-signal")
           ) ==
             "Selected run was interrupted"

    offline =
      render_component(&RunComponents.mission_control_signal_panel/1,
        selected_run: nil,
        run_counts: %{approvals: 0},
        workspace_locks: [],
        stats: %{online: false, capacity: 10}
      )

    assert compact_text(
             offline
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#mission-control-signal")
           ) ==
             "Dispatcher offline"
  end

  test "no-run hero renders no fabricated waveform or progress" do
    html = render_component(&RunComponents.mission_control_hero/1, selected_run: nil, phase: nil)
    doc = LazyHTML.from_fragment(html)
    assert compact_text(LazyHTML.query(doc, "#mission-control-phase")) == "No active run"
    refute LazyHTML.query(doc, "#mission-control-waveform") |> LazyHTML.to_tree() |> Enum.any?()
    refute LazyHTML.query(doc, "[role='progressbar']") |> LazyHTML.to_tree() |> Enum.any?()
  end

  defp run_fixture(id, objective, status, progress) do
    %Run{
      id: id,
      objective: objective,
      status: status,
      progress: progress,
      kind: "coding_swarm",
      mode: "swarm",
      priority: "normal",
      execution_engine: "legacy_v1",
      attempt: 0,
      max_attempts: 3,
      input_tokens: 0,
      output_tokens: 0,
      cost_cents: 0,
      event_sequence: 0
    }
  end

  defp run_control_document(run, dag_projection) do
    html =
      render_component(&RunComponents.run_control_plane/1,
        runs: [run],
        run_count: 1,
        run_counts: %{active: 1, queued: 0, attention: 0, approvals: 0},
        selected_run: run,
        steps: [],
        events: [],
        approvals: [],
        artifacts: [],
        controls: [],
        stats: %{online: true, capacity: 1},
        workspace_locks: [],
        agents: [],
        agent_count: 0,
        fleet_summary: %{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0},
        fleet_loading: false,
        dag_projection: dag_projection
      )

    LazyHTML.from_fragment(html)
  end

  defp compact_text(document) do
    document
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp selected_tab_count(document) do
    ~w(overview topology execution journal)
    |> Enum.count(fn mode ->
      document
      |> LazyHTML.query("#mission-control-mode-#{mode}[aria-selected='true']")
      |> LazyHTML.to_tree()
      |> Kernel.!=([])
    end)
  end

  defp node_count(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
    |> count_tree_nodes()
  end

  defp count_tree_nodes(nodes) when is_list(nodes), do: Enum.reduce(nodes, 0, &count_tree_nodes/2)
  defp count_tree_nodes(_node, total), do: total + 1
end
