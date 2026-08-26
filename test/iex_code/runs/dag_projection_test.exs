defmodule IexCode.Runs.DagProjectionTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.DagProjection

  test "builds deterministic layers, readiness, retry and redacted attempt receipts" do
    now = ~U[2026-08-24 12:00:00Z]

    run = %{
      id: "run-dag",
      execution_engine: "dag_v1",
      attempt: 2,
      event_sequence: 41
    }

    steps = [
      step("verify", "Verify", "pending", ["code", "research"], 3),
      step("plan", "Plan", "completed", [], 0),
      step("research", "Research", "ready", ["plan"], 2),
      step("code", "Code", "running", ["plan"], 1)
    ]

    attempts = [
      attempt("code", 1, "completed", %{run_attempt: 1, completed_at: now}),
      attempt("code", 2, "running", %{
        heartbeat_at: DateTime.add(now, -2, :second),
        lease_expires_at: DateTime.add(now, 30, :second),
        checkpoint: %{"private" => "must-not-project"},
        checkpoint_version: 7,
        checkpointed_at: DateTime.add(now, -5, :second),
        result: %{"private" => "must-not-project"},
        execution_key: "must-not-project",
        lease_owner: "must-not-project"
      }),
      attempt("research", 1, "interrupted", %{
        retry_not_before: DateTime.add(now, 60, :second),
        completed_at: DateTime.add(now, -1, :second)
      })
    ]

    assert {:ok, projection} =
             DagProjection.build(run, steps, attempts, now: now, stale_after_ms: 10_000)

    assert projection.engine == "dag_v1"
    assert projection.revision == 41

    assert Enum.map(projection.layers, &Enum.map(&1, fn node -> node.key end)) == [
             ["plan"],
             ["code", "research"],
             ["verify"]
           ]

    nodes = projection.layers |> List.flatten() |> Map.new(&{&1.key, &1})
    assert nodes["code"].readiness == "leased"
    assert nodes["code"].lease_health == "healthy"
    assert nodes["code"].latest_attempt.checkpoint_version == 7
    assert nodes["research"].readiness == "retry_backoff"
    assert nodes["verify"].readiness == "waiting_dependencies"
    assert nodes["verify"].blocked_by == ["code", "research"]
    assert projection.summary.running == 1
    assert projection.summary.retrying == 1

    projected = inspect(projection, limit: :infinity)
    refute projected =~ "must-not-project"
    refute projected =~ "checkpoint:"
    refute projected =~ "result:"
    refute projected =~ "lease_owner"
    refute projected =~ "execution_key"
  end

  test "derives dependency failure and stale or expired lease health" do
    now = ~U[2026-08-24 12:00:00Z]
    run = %{id: "run-dag", execution_engine: "dag_v1", attempt: 1, event_sequence: 2}

    steps = [
      step("root", "Root", "failed", [], 0),
      step("child", "Child", "blocked", ["root"], 1),
      step("worker", "Worker", "running", [], 2)
    ]

    attempts = [
      attempt("worker", 1, "running", %{
        run_attempt: 1,
        heartbeat_at: DateTime.add(now, -90, :second),
        lease_expires_at: DateTime.add(now, -1, :second)
      })
    ]

    assert {:ok, projection} = DagProjection.build(run, steps, attempts, now: now)
    nodes = projection.layers |> List.flatten() |> Map.new(&{&1.key, &1})
    assert nodes["child"].readiness == "dependency_failed"
    assert nodes["child"].blocked_by == ["root"]
    assert nodes["worker"].readiness == "lease_expired"
    assert nodes["worker"].lease_health == "expired"
  end

  test "fails closed for cycles, missing dependencies and corrupt scope" do
    run = %{id: "run-dag", execution_engine: "dag_v1", attempt: 1, event_sequence: 0}

    assert {:error, :cyclic_dag_projection} =
             DagProjection.build(
               run,
               [step("a", "A", "pending", ["b"], 0), step("b", "B", "pending", ["a"], 1)],
               []
             )

    assert {:error, {:missing_dependencies, "a", ["missing"]}} =
             DagProjection.build(run, [step("a", "A", "pending", ["missing"], 0)], [])

    assert {:error, {:dag_step_scope_mismatch, "step-a"}} =
             DagProjection.build(run, [%{step("a", "A", "ready", [], 0) | run_id: "other"}], [])

    assert {:error, {:dag_attempt_scope_mismatch, "attempt-a-1"}} =
             DagProjection.build(run, [step("a", "A", "running", [], 0)], [
               %{attempt("a", 1, "running", %{}) | run_id: "other"}
             ])
  end

  test "rejects legacy runs rather than interpreting descriptive dependencies" do
    assert {:error, {:not_dag_run, "legacy_v1"}} =
             DagProjection.build(
               %{id: "legacy", execution_engine: "legacy_v1", attempt: 1, event_sequence: 0},
               [step("a", "A", "ready", [], 0)],
               []
             )
  end

  defp step(key, title, status, dependencies, position) do
    %{
      id: "step-#{key}",
      run_id: "run-dag",
      key: key,
      title: title,
      kind: "read_file",
      status: status,
      position: position,
      progress: if(status == "completed", do: 100, else: 0),
      attempt: 0,
      max_attempts: 3,
      depends_on: dependencies,
      params: %{"private" => "must-not-project"},
      result: %{"private" => "must-not-project"}
    }
  end

  defp attempt(step_key, number, status, overrides) do
    defaults = %{
      id: "attempt-#{step_key}-#{number}",
      run_id: "run-dag",
      run_step_id: "step-#{step_key}",
      run_attempt: 2,
      attempt: number,
      status: status,
      progress: 35,
      started_at: ~U[2026-08-24 11:59:00Z],
      checkpoint: nil,
      result: nil,
      error_details: %{}
    }

    Map.merge(defaults, overrides)
  end
end
