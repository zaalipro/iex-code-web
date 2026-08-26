defmodule IexCodeWeb.RunComponentsLockTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest

  alias IexCode.Runs.Run
  alias IexCodeWeb.RunComponents

  test "renders held and waiting workspace ownership in the overview and run ledger" do
    held_run = run("run-held-1234567", "Apply authentication patch", "running")
    waiting_run = run("run-waiting-7654321", "Refresh generated clients", "queued")
    expires_at = DateTime.add(DateTime.utc_now(), 60, :second)

    locks = [
      %{
        id: "lock-held",
        run_id: held_run.id,
        session_id: "session-held",
        resource_type: "project",
        resource_key: "/workspace/iex-code",
        mode: "exclusive",
        status: "held",
        lease_expires_at: expires_at
      },
      %{
        id: "lock-waiting",
        run_id: waiting_run.id,
        session_id: "session-waiting",
        resource_type: "file",
        resource_key: "lib/iex_code/accounts.ex",
        mode: "write",
        status: "waiting",
        wait_reason: "queue_predecessor"
      },
      %{
        id: "lock-released",
        run_id: waiting_run.id,
        resource_type: "git",
        resource_key: "repository",
        mode: "exclusive",
        status: "released"
      }
    ]

    document =
      [held_run, waiting_run]
      |> render_control_plane(held_run, locks)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "#workspace-lock-overview[data-lock-state='held']")

    assert LazyHTML.query(document, "#workspace-lock-summary") |> LazyHTML.text() =~
             "Reserved by this run"

    assert document |> compact_text("#workspace-lock-held-count") =~ "1 held resources"

    assert document |> compact_text("#workspace-lock-waiting-count") =~ "1 waiting resources"

    assert LazyHTML.query(document, "#workspace-lock-details")
    assert LazyHTML.query(document, "#workspace-lock-lock-held[data-lock-status='held']")
    assert LazyHTML.query(document, "#workspace-lock-lock-waiting[data-lock-status='waiting']")
    assert document |> LazyHTML.filter("#workspace-lock-lock-released") |> Enum.empty?()

    assert LazyHTML.query(
             document,
             "#async-run-#{held_run.id}[data-workspace-lock-state='held']"
           )

    assert LazyHTML.query(
             document,
             "#async-run-#{waiting_run.id}[data-workspace-lock-state='waiting']"
           )

    assert LazyHTML.query(document, "#async-run-#{held_run.id}") |> LazyHTML.text() =~
             "owns workspace"

    assert LazyHTML.query(document, "#async-run-#{waiting_run.id}") |> LazyHTML.text() =~
             "waiting for workspace"
  end

  test "prioritizes the selected run's wait state and renders an honest empty state" do
    waiting_run = run("run-waiting-1234567", "Wait for workspace access", "queued")

    waiting_lock = %{
      id: "lock-selected-wait",
      run_id: waiting_run.id,
      resource_type: "project",
      resource_key: "/workspace/iex-code",
      mode: "exclusive",
      status: "waiting",
      wait_reason: "external_conflict"
    }

    waiting_document =
      [waiting_run]
      |> render_control_plane(waiting_run, [waiting_lock])
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(waiting_document, "#workspace-lock-overview[data-lock-state='waiting']")

    assert LazyHTML.query(waiting_document, "#workspace-lock-summary") |> LazyHTML.text() =~
             "This run is waiting"

    free_document =
      []
      |> render_control_plane(nil, [])
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(free_document, "#workspace-lock-overview[data-lock-state='free']")

    assert LazyHTML.query(free_document, "#workspace-lock-summary") |> LazyHTML.text() =~
             "Available"

    assert free_document |> LazyHTML.filter("#workspace-lock-details") |> Enum.empty?()
    assert LazyHTML.text(free_document) =~ "No active IexCode workspace reservations"
    refute LazyHTML.text(free_document) =~ "can begin immediately"
  end

  test "selected-run context uses that run's resource rather than the first global lock" do
    other_run = run("run-other-1234567", "Other mutation", "running")
    selected_run = run("run-selected-7654321", "Selected mutation", "running")

    locks = [
      %{
        id: "lock-other",
        run_id: other_run.id,
        resource_type: "file",
        resource_key: "/private/workspace/lib/other_secret.ex",
        mode: "write",
        status: "held"
      },
      %{
        id: "lock-selected",
        run_id: selected_run.id,
        resource_type: "file",
        resource_key: "/private/workspace/lib/selected.ex",
        mode: "exclusive",
        status: "held"
      }
    ]

    document =
      [other_run, selected_run]
      |> render_control_plane(selected_run, locks)
      |> LazyHTML.from_fragment()

    context = document |> LazyHTML.query("#workspace-lock-context") |> LazyHTML.text()
    assert context =~ "selected.ex"
    refute context =~ "other_secret.ex"
    refute LazyHTML.text(document) =~ "/private/workspace"
  end

  defp render_control_plane(runs, selected_run, locks) do
    render_component(&RunComponents.run_control_plane/1,
      runs: runs,
      run_count: length(runs),
      run_counts: %{active: 0, queued: length(runs), attention: 0, approvals: 0},
      selected_run: selected_run,
      steps: [],
      approvals: [],
      artifacts: [],
      controls: [],
      events: [],
      stats: %{online: true, capacity: 2},
      workspace_locks: locks
    )
  end

  defp compact_text(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp run(id, objective, status) do
    %Run{
      id: id,
      objective: objective,
      kind: "coding_swarm",
      status: status,
      mode: "swarm",
      priority: "normal",
      progress: 0,
      event_sequence: 0,
      attempt: 0,
      max_attempts: 3,
      input_tokens: 0,
      output_tokens: 0,
      cost_cents: 0
    }
  end
end
