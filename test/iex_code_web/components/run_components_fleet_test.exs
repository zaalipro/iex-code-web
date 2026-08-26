defmodule IexCodeWeb.RunComponentsFleetTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest

  alias IexCode.Runs.{Run, RunAgent, RunAgentControl}
  alias IexCodeWeb.RunComponents

  test "renders an arbitrary persisted fleet with truthful metrics and stable controls" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    coder = %RunAgent{
      id: "agent-coder-01",
      run_id: "run-fleet-01",
      key: "coder:01",
      role: "coder",
      display_name: "Implementation worker",
      status: "running",
      desired_state: "active",
      lease_expires_at: DateTime.add(now, 30, :second),
      progress: 47,
      current_task: "Applying the durable fleet projection",
      heartbeat_at: now,
      input_tokens: 1_250,
      output_tokens: 750,
      request_count: 4,
      last_latency_ms: 820,
      average_latency_ms: 640,
      model_provider: "openai",
      model_name: "gpt-next",
      attempt: 1,
      max_attempts: 3,
      config: %{"api_key" => "must-not-render"},
      lease_owner: "private-executor-identity"
    }

    reviewer = %RunAgent{
      id: "agent-review-02",
      run_id: "run-fleet-01",
      key: "reviewer:02",
      role: "security_reviewer",
      display_name: "Security reviewer",
      status: "paused",
      desired_state: "paused",
      progress: 15,
      current_task: "Reviewing authorization boundaries",
      input_tokens: 120,
      output_tokens: 30,
      request_count: 1,
      attempt: 1,
      max_attempts: 2
    }

    html =
      render_component(&RunComponents.agent_fleet/1,
        run: %Run{id: "run-fleet-01", status: "running"},
        agents: [{"run-agent-agent-coder-01", coder}, {"run-agent-agent-review-02", reviewer}],
        agent_count: 2,
        summary: %{active: 1, paused: 1, attention: 0, recovering: 0, tokens: 2_150},
        loading: false,
        guidance: %{}
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#run-agent-fleet[data-fleet-state='active']")
    assert LazyHTML.query(document, "#run-agent-fleet-list[phx-update='stream']")

    assert LazyHTML.query(
             document,
             "#run-agent-agent-coder-01[data-agent-status='running'][data-agent-health='healthy']"
           )

    assert LazyHTML.query(document, "#pause-run-agent-agent-coder-01")
    assert LazyHTML.query(document, "#cancel-run-agent-agent-coder-01[data-confirm]")
    assert LazyHTML.query(document, "#run-agent-steering-form-agent-coder-01")
    assert LazyHTML.query(document, "#resume-run-agent-agent-review-02")
    assert LazyHTML.query(document, "#run-agent-steering-input-agent-review-02")

    text = LazyHTML.text(document)
    assert text =~ "Applying the durable fleet projection"
    assert text =~ "2.0k"
    assert text =~ "640ms"
    assert text =~ "Security reviewer"
    refute text =~ "must-not-render"
    refute text =~ "private-executor-identity"
  end

  test "renders honest queued, loading, and archived empty states" do
    queued = %Run{id: "run-queued", status: "queued"}

    queued_html =
      render_component(&RunComponents.agent_fleet/1,
        run: queued,
        agents: [],
        agent_count: 0,
        summary: %{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0},
        loading: false,
        guidance: %{}
      )

    queued_document = LazyHTML.from_fragment(queued_html)
    assert LazyHTML.query(queued_document, "#run-agent-fleet[data-fleet-state='empty']")
    assert LazyHTML.query(queued_document, "#run-agent-fleet-empty")
    assert LazyHTML.text(queued_document) =~ "Fleet awaits dispatcher claim"

    loading_html =
      render_component(&RunComponents.agent_fleet/1,
        run: queued,
        agents: [],
        agent_count: 0,
        summary: %{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0},
        loading: true,
        guidance: %{}
      )

    loading_document = LazyHTML.from_fragment(loading_html)
    assert LazyHTML.query(loading_document, "#run-agent-fleet[aria-busy='true']")
    assert LazyHTML.query(loading_document, "#run-agent-fleet-loading[role='status']")
    refute loading_html =~ ~s(id="run-agent-fleet-list")
  end

  test "renders recovery and retry without inventing a live heartbeat" do
    recovering = %RunAgent{
      id: "agent-recover-01",
      run_id: "run-recover",
      key: "explorer:01",
      role: "explorer",
      display_name: "Recovery explorer",
      status: "starting",
      desired_state: "active",
      attempt: 2,
      max_attempts: 3
    }

    failed = %RunAgent{
      id: "agent-failed-02",
      run_id: "run-recover",
      key: "reviewer:01",
      role: "reviewer",
      display_name: "Failed reviewer",
      status: "interrupted",
      desired_state: "active",
      error_message: "Provider lease expired",
      attempt: 1,
      max_attempts: 3
    }

    html =
      render_component(&RunComponents.agent_fleet/1,
        run: %Run{id: "run-recover", status: "running"},
        agents: [
          {"run-agent-agent-recover-01", recovering},
          {"run-agent-agent-failed-02", failed}
        ],
        agent_count: 2,
        summary: %{active: 1, paused: 0, attention: 1, recovering: 1, tokens: 0},
        loading: false,
        guidance: %{}
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#run-agent-fleet[data-fleet-state='recovering']")
    assert LazyHTML.query(document, "#run-agent-fleet-recovering[role='status']")
    assert LazyHTML.query(document, "#run-agent-agent-recover-01[data-agent-health='recovering']")
    assert LazyHTML.query(document, "#restart-run-agent-agent-failed-02")
    assert LazyHTML.query(document, "#run-agent-error-agent-failed-02[role='alert']")
    assert LazyHTML.text(document) =~ "Heartbeat · not reported"
  end

  test "renders safe durable command receipts and disables only duplicate open actions" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    pausing = %RunAgent{
      id: "agent-pausing",
      run_id: "run-receipts",
      key: "coder:01",
      role: "coder",
      display_name: "Pausing coder",
      status: "running",
      desired_state: "paused",
      attempt: 1,
      max_attempts: 3
    }

    steered = %RunAgent{
      id: "agent-steered",
      run_id: "run-receipts",
      key: "explorer:01",
      role: "explorer",
      display_name: "Steered explorer",
      status: "running",
      desired_state: "active",
      attempt: 1,
      max_attempts: 3
    }

    rejected = %RunAgent{
      id: "agent-rejected",
      run_id: "run-receipts",
      key: "planner:01",
      role: "planner",
      display_name: "Rejected planner",
      status: "running",
      desired_state: "active",
      attempt: 1,
      max_attempts: 3
    }

    receipts = %{
      pausing.id => [
        %RunAgentControl{
          id: "control-pause",
          run_id: "run-receipts",
          run_agent_id: pausing.id,
          sequence: 4,
          kind: "pause",
          status: "pending",
          payload: %{},
          inserted_at: now
        }
      ],
      steered.id => [
        %RunAgentControl{
          id: "control-steer",
          run_id: "run-receipts",
          run_agent_id: steered.id,
          sequence: 8,
          kind: "steer",
          status: "applied",
          payload: %{"guidance" => "private operator instruction"},
          result: %{"status" => "consumed", "private_trace" => "must-not-render"},
          inserted_at: now,
          resolved_at: now
        }
      ],
      rejected.id => [
        %RunAgentControl{
          id: "control-rejected",
          run_id: "run-receipts",
          run_agent_id: rejected.id,
          sequence: 2,
          kind: "restart",
          status: "rejected",
          payload: %{},
          result: %{"error" => "lease_lost", "token" => "must-not-render"},
          inserted_at: now,
          resolved_at: now
        }
      ]
    }

    html =
      render_component(&RunComponents.agent_fleet/1,
        run: %Run{id: "run-receipts", status: "running"},
        agents: [
          {"run-agent-agent-pausing", pausing},
          {"run-agent-agent-steered", steered},
          {"run-agent-agent-rejected", rejected}
        ],
        agent_count: 3,
        summary: %{active: 3, paused: 0, attention: 0, recovering: 0, tokens: 0},
        loading: false,
        guidance: %{},
        receipts: receipts
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#run-agent-control-receipt-agent-pausing[data-control-status='pending']"
           )

    assert LazyHTML.query(document, "#pause-run-agent-agent-pausing[disabled]")
    assert LazyHTML.query(document, "#cancel-run-agent-agent-pausing:not([disabled])")

    assert LazyHTML.query(
             document,
             "#run-agent-control-receipt-agent-steered[data-control-result-status='consumed']"
           )

    assert LazyHTML.query(
             document,
             "#run-agent-control-receipt-agent-rejected[data-control-status='rejected']"
           )

    text = LazyHTML.text(document)
    assert text =~ "#8 · steer"
    assert text =~ "Guidance was consumed by the worker"
    assert text =~ "Rejected · lease_lost"
    refute text =~ "private operator instruction"
    refute text =~ "must-not-render"

    for {status, result, expected_lifecycle} <- [
          {"claimed", nil, "claimed"},
          {"applied", %{"status" => "queued"}, "queued"},
          {"applied", %{"status" => "applied"}, "applied"},
          {"superseded", %{"reason" => "new_generation"}, "superseded"}
        ] do
      receipt = %RunAgentControl{
        id: "control-#{status}-#{expected_lifecycle}",
        run_id: "run-receipts",
        run_agent_id: steered.id,
        sequence: 9,
        kind: "steer",
        status: status,
        payload: %{},
        result: result,
        inserted_at: now,
        claimed_at: if(status == "claimed", do: now),
        resolved_at: if(status in ["applied", "superseded"], do: now)
      }

      lifecycle_html =
        render_component(&RunComponents.agent_fleet/1,
          run: %Run{id: "run-receipts", status: "running"},
          agents: [{"run-agent-agent-steered", steered}],
          agent_count: 1,
          summary: %{active: 1, paused: 0, attention: 0, recovering: 0, tokens: 0},
          loading: false,
          guidance: %{},
          receipts: %{steered.id => [receipt]}
        )

      lifecycle_document = LazyHTML.from_fragment(lifecycle_html)

      assert LazyHTML.query(
               lifecycle_document,
               "#run-agent-control-receipt-agent-steered[data-control-status='#{status}']"
             )

      assert LazyHTML.text(lifecycle_document) =~ expected_lifecycle
    end
  end
end
