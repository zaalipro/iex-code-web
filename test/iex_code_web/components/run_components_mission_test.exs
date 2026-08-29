defmodule IexCodeWeb.RunComponentsMissionTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents

  alias IexCode.Runs.Run
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
        <:primary_action><button id="new-goal-button">New mission</button></:primary_action>
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

    assert LazyHTML.query(doc, "#new-goal-button")
    assert LazyHTML.query(doc, "#async-run-control")
    assert LazyHTML.query(doc, "#mission-control-signal-panel")
    assert LazyHTML.query(doc, "#async-run-control")
    assert LazyHTML.query(doc, "#run-agent-fleet")
    assert LazyHTML.query(doc, "#run-agent-fleet-list[phx-update='stream']")
    assert LazyHTML.query(doc, "#interactive-coach-sentinel")
    assert LazyHTML.query(doc, "#mission-control-panel-execution #interactive-coach-sentinel")

    for mode <- ~w(overview topology execution journal) do
      assert LazyHTML.query(doc, "#mission-control-mode-#{mode}[role='tab']")
      assert LazyHTML.query(doc, "#mission-control-panel-#{mode}[role='tabpanel']")
    end

    assert LazyHTML.query(doc, "#mission-control-mode-overview[aria-selected='true']")
    assert LazyHTML.query(doc, "#mission-control-mode-overview[aria-selected='true']")
    assert LazyHTML.query(doc, "#mission-control-waveform[aria-hidden='true']")
    assert LazyHTML.query(doc, "#mission-control-panel-overview:not([hidden])")
    assert LazyHTML.query(doc, "#mission-control-panel-topology[hidden]")
    assert LazyHTML.query(doc, "#mission-control-panel-execution[hidden]")
    assert LazyHTML.query(doc, "#mission-control-panel-journal[hidden]")
    refute LazyHTML.text(LazyHTML.query(doc, "#mission-control-hero")) =~ run.objective
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
    hero_text = LazyHTML.text(LazyHTML.query(doc, "#mission-control-hero"))
    refute hero_text =~ "objective-secret"
    refute hero_text =~ "run-sensitive-id"
    refute hero_text =~ "lease-secret"
    refute hero_text =~ "error-secret"
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

  defp compact_text(document) do
    document
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
