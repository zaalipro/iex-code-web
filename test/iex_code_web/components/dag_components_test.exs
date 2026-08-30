defmodule IexCodeWeb.DagComponentsTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest

  alias IexCodeWeb.DagComponents

  test "renders a responsive layered DAG with truthful readiness and safe attempt receipts" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    projection = %{
      engine: "dag_v1",
      available?: true,
      summary: %{
        ready: 1,
        running: 1,
        blocked: 1,
        approval: 0,
        retrying: 1,
        completed: 1,
        failed: 0
      },
      layers: [
        [
          %{
            id: "step-plan",
            key: "plan",
            title: "Plan implementation",
            kind: "planner",
            status: "completed",
            readiness: :terminal,
            progress: 100,
            attempt: 1,
            max_attempts: 1,
            depends_on: [],
            critical_path?: true,
            latest_attempt: %{completed_at: now}
          }
        ],
        [
          %{
            id: "step-code",
            key: "code",
            title: "Implement durable scheduler",
            kind: "coder",
            status: "running",
            readiness: :leased,
            progress: 47,
            attempt: 2,
            max_attempts: 3,
            depends_on: ["plan"],
            critical_path?: true,
            latest_attempt: %{
              checkpoint: %{"private_state" => "must-not-render"},
              checkpoint_version: 4,
              checkpointed_at: now,
              heartbeat_at: now
            }
          },
          %{
            id: "step-research",
            key: "research",
            title: "Collect compatibility evidence",
            kind: "research",
            status: "ready",
            readiness: :ready,
            progress: 0,
            attempt: 0,
            max_attempts: 2,
            depends_on: ["plan"]
          }
        ],
        [
          %{
            id: "step-verify",
            key: "verify",
            title: "Verify scheduler invariants",
            kind: "verifier",
            status: "blocked",
            readiness: :waiting_dependencies,
            progress: 0,
            attempt: 0,
            max_attempts: 2,
            depends_on: ["code", "research"],
            blocked_by: ["code", "research"],
            error_code: "dependency_failed"
          },
          %{
            id: "step-retry",
            key: "retry",
            title: "Retry flaky provider",
            kind: "tool",
            status: "paused",
            readiness: :retry_backoff,
            progress: 28,
            attempt: 1,
            max_attempts: 4,
            depends_on: ["research"],
            latest_attempt: %{retry_not_before: DateTime.add(now, 30, :second)}
          }
        ]
      ]
    }

    html = render_component(&DagComponents.dag_projection/1, projection: projection)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#dag-execution-projection[data-engine='dag_v1'][data-scheduler-state='available']"
           )

    assert LazyHTML.query(document, "#dag-layer-1")
    assert LazyHTML.query(document, "#dag-mobile-layer-1")

    assert LazyHTML.query(
             document,
             "#dag-node-step-code-desktop[data-node-status='running'][data-node-readiness='leased'][data-critical-path='true']"
           )

    refute html =~ ~s(phx-click="control_dag_step")

    assert LazyHTML.query(
             document,
             "#dag-node-step-verify-mobile[data-node-readiness='waiting_dependencies']"
           )

    assert LazyHTML.query(document, "#dag-node-error-step-verify-desktop[role='alert']")

    text = LazyHTML.text(document)
    assert text =~ "Blocked by"
    assert text =~ "code"
    assert text =~ "research"
    assert text =~ "v4 ·"
    assert text =~ "Retry scheduled"
    refute text =~ "must-not-render"
  end

  test "uses shared Signal Foundry tokens and accessible disclosure targets" do
    projection = %{engine: "dag_v1", available?: true, summary: %{}, layers: []}
    html = render_component(&DagComponents.dag_projection/1, projection: projection)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#dag-execution-projection[data-surface='instrument']")

    assert LazyHTML.query(
             document,
             "#dag-execution-projection .dag-decorative-mark[aria-hidden='true']"
           )

    assert LazyHTML.query(document, "#dag-execution-projection summary.min-h-11")
    refute html =~ "bg-[#0b0f14]"
    refute html =~ "text-cyan-300"
  end

  test "reserves live tone for active or failed DAG states" do
    projection = %{
      engine: "dag_v1",
      available?: true,
      summary: %{},
      layers: [
        for status <- ~w(blocked paused retrying) do
          %{
            id: status,
            key: status,
            title: String.capitalize(status),
            kind: "task",
            status: status,
            progress: 25,
            attempt: 0,
            max_attempts: 1,
            depends_on: []
          }
        end
      ]
    }

    html = render_component(&DagComponents.dag_projection/1, projection: projection)
    document = LazyHTML.from_fragment(html)

    for status <- ~w(blocked paused retrying) do
      node = LazyHTML.query(document, "#dag-node-#{status}-desktop")

      for selector <- [".dag-status-dot", ".dag-status-badge", ".dag-progress-fill"] do
        classes =
          node |> LazyHTML.query(selector) |> LazyHTML.attribute("class")

        classes = if(is_binary(classes), do: classes, else: Enum.join(classes || [], " "))

        refute classes =~ "--sf-live", "#{status} #{selector} should remain neutral"
      end
    end
  end

  test "fails closed honestly and suppresses controls when scheduler is unavailable" do
    projection = %{
      engine: "dag_v1",
      available?: false,
      summary: %{ready: 1},
      layers: [
        [
          %{
            id: "reserved-node",
            key: "reserved",
            title: "Reserved DAG node",
            status: "ready",
            readiness_reason: :ready
          }
        ]
      ]
    }

    html = render_component(&DagComponents.dag_projection/1, projection: projection)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#dag-execution-projection[data-scheduler-state='unavailable']"
           )

    assert LazyHTML.query(document, "#dag-scheduler-unavailable[role='status']")
    refute html =~ "<button"
    assert LazyHTML.text(document) =~ "will not fall through to legacy execution"
  end

  test "renders a composed empty manifest state" do
    html =
      render_component(&DagComponents.dag_projection/1,
        projection: %{engine: "dag_v1", available?: false, summary: %{}, layers: []}
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#dag-execution-empty")
    assert LazyHTML.text(document) =~ "No DAG nodes persisted"
  end

  test "distinguishes a corrupt projection from an offline scheduler" do
    html =
      render_component(&DagComponents.dag_projection/1,
        projection: %{
          engine: "dag_v1",
          available?: false,
          error_code: "projection_dependency_missing",
          summary: %{},
          layers: []
        }
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#dag-projection-error[role='alert']")
    assert LazyHTML.text(document) =~ "projection_dependency_missing"
    refute html =~ ~s(id="dag-scheduler-unavailable")
    refute html =~ ~s(id="dag-execution-empty")
    refute LazyHTML.text(document) =~ "cannot execute until its fenced DAG scheduler is available"
    refute LazyHTML.text(document) =~ "No DAG nodes persisted"
  end
end
