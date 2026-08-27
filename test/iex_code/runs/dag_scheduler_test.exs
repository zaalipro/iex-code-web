defmodule IexCode.Runs.DagSchedulerTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Runs.{DagManifest, DagRunner, DagScheduler, DagStepRegistry, Run, RunStep}

  @owner "dag-dispatcher-owner"

  setup do
    root = Path.join(System.tmp_dir!(), "iex-dag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "durable dag\n")

    {:ok, project} = Projects.create_project(%{name: "DAG Test", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "DAG"})
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session, root: root}
  end

  test "claims independent roots once, promotes fan-in, and completes durably", context do
    {run, _steps} = dag_fixture(context)

    assert {:ok, first} = DagScheduler.claim_ready(run, @owner, 1)
    assert {:ok, second} = DagScheduler.claim_ready(run, @owner, 1)
    refute first.step.id == second.step.id
    assert :none = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, _} =
             DagScheduler.complete(first.attempt, @owner, 1, first.attempt.lease_generation, %{
               "value" => first.step.key
             })

    assert :none = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, _} =
             DagScheduler.complete(second.attempt, @owner, 1, second.attempt.lease_generation, %{
               "value" => second.step.key
             })

    assert {:ok, join} = DagScheduler.claim_ready(run, @owner, 1)
    assert join.step.key == "join"
    assert Map.keys(join.dependency_results) |> Enum.sort() == ["inventory", "read"]

    assert {:ok, _} =
             DagScheduler.complete(join.attempt, @owner, 1, join.attempt.lease_generation, %{
               "joined" => true
             })

    assert Repo.get!(Run, run.id).status == "completed"
    assert {:error, {:run_not_running, "completed"}} = DagScheduler.claim_ready(run, @owner, 1)
  end

  test "lazy claims retain no dependency payload until fenced hydration", context do
    {run, _steps} = dag_fixture(context)

    assert {:ok, first} =
             DagScheduler.claim_ready(run, @owner, 1, load_dependencies?: false)

    assert {:ok, second} =
             DagScheduler.claim_ready(run, @owner, 1, load_dependencies?: false)

    assert first.dependency_results_loaded?
    assert second.dependency_results_loaded?
    assert first.dependency_results == %{}
    assert second.dependency_results == %{}

    for claim <- [first, second] do
      assert {:ok, _attempt} =
               DagScheduler.complete(
                 claim.attempt,
                 @owner,
                 1,
                 claim.attempt.lease_generation,
                 %{"content" => String.duplicate("x", 100_000)}
               )
    end

    assert {:ok, join} =
             DagScheduler.claim_ready(run, @owner, 1, load_dependencies?: false)

    assert join.dependency_results == %{}
    refute join.dependency_results_loaded?

    assert {:ok, dependencies} =
             DagScheduler.load_dependency_results(
               join.attempt,
               @owner,
               1,
               join.attempt.lease_generation
             )

    assert Map.keys(dependencies) |> Enum.sort() == ["inventory", "read"]

    assert Enum.sum(
             Enum.map(dependencies, fn {_key, payload} ->
               {:ok, encoded} = IexCode.Runs.DagPayload.canonical_json(payload)
               byte_size(encoded)
             end)
           ) <= 32 * 256_000
  end

  test "closed registry makes the maximum direct fan-in envelope explicit" do
    descriptors = DagStepRegistry.descriptors()

    assert Enum.all?(descriptors, &(&1.max_output_bytes <= 256_000))
    assert Enum.max(Enum.map(descriptors, & &1.max_output_bytes)) == 256_000
    # DagManifest admits at most 32 direct dependencies, so even adversarial
    # fan-in is capped at 8,192,000 canonical bytes and is hydrated only after
    # governor admission by DagRunner.
    assert 32 * Enum.max(Enum.map(descriptors, & &1.max_output_bytes)) == 8_192_000
  end

  test "fences foreign owners, stale parent generations and stale step generations", context do
    {run, _steps} = dag_fixture(context)
    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, "foreign", 1)
    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, @owner, 2)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:error, :run_lease_lost} =
             DagScheduler.heartbeat(claim.attempt, "foreign", 1, claim.attempt.lease_generation)

    assert {:error, :run_lease_lost} =
             DagScheduler.heartbeat(claim.attempt, @owner, 2, claim.attempt.lease_generation)

    assert {:error, :step_lease_lost} =
             DagScheduler.complete(claim.attempt, @owner, 1, 999, %{"value" => "late"})
  end

  test "failure retries after durable backoff then skips descendants on exhaustion", context do
    {run, _steps} = dag_fixture(context, max_attempts: 2)
    assert {:ok, first} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, failed} =
             DagScheduler.fail(first.attempt, @owner, 1, first.attempt.lease_generation, :timeout)

    assert failed.status == "failed"
    assert failed.retry_not_before

    assert {:ok, other_root} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, _} =
             DagScheduler.complete(
               other_root.attempt,
               @owner,
               1,
               other_root.attempt.lease_generation,
               %{"value" => "other"}
             )

    assert :none = DagScheduler.claim_ready(run, @owner, 1)

    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(attempt in IexCode.Runs.RunStepAttempt, where: attempt.id == ^failed.id),
      set: [retry_not_before: past]
    )

    assert {:ok, retry} = DagScheduler.claim_ready(run, @owner, 1)
    assert retry.step.id == first.step.id
    assert retry.attempt.attempt == 2

    assert {:ok, _} =
             DagScheduler.fail(retry.attempt, @owner, 1, retry.attempt.lease_generation, :timeout)

    assert Repo.get!(RunStep, first.step.id).status == "failed"
    assert Enum.find(DagScheduler.projection(run), &(&1.key == "join")).status == "skipped"
  end

  test "manifest and handler drift fail closed before claim", context do
    {run, steps} = dag_fixture(context)
    inventory = Enum.find(steps, &(&1.key == "inventory"))

    Repo.update_all(from(step in RunStep, where: step.id == ^inventory.id),
      set: [resource_spec: %{"contract" => "forged"}]
    )

    assert {:error, :handler_descriptor_drift} = DagScheduler.claim_ready(run, @owner, 1)
  end

  test "handler-sized results above checkpoint limit persist within the registry ceiling",
       context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)
    result = %{"content" => String.duplicate("x", 70_000)}

    assert {:ok, completed} =
             DagScheduler.complete(
               claim.attempt,
               @owner,
               1,
               claim.attempt.lease_generation,
               result
             )

    assert completed.result == result
  end

  test "fenced pause and resume preserve attempt lease and checkpoint", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, checkpointed} =
             DagScheduler.checkpoint(
               claim.attempt,
               @owner,
               1,
               claim.attempt.lease_generation,
               %{"cursor" => 1},
               25
             )

    lease_expiry = checkpointed.lease_expires_at
    assert {:ok, paused_run} = transition_parent(run, "paused")

    assert {:error, :run_lease_lost} =
             DagScheduler.set_paused(paused_run, "foreign", 1, true)

    assert {:error, :run_lease_lost} =
             DagScheduler.set_paused(paused_run, @owner, 2, true)

    assert {:ok, %{paused: true, attempts: 1}} =
             DagScheduler.set_paused(paused_run, @owner, 1, true)

    paused_attempt = Repo.get!(IexCode.Runs.RunStepAttempt, claim.attempt.id)
    paused_step = Repo.get!(RunStep, claim.step.id)
    assert paused_attempt.status == "paused"
    assert paused_step.status == "paused"
    assert paused_attempt.checkpoint == %{"cursor" => 1}
    assert paused_attempt.progress == 25
    assert paused_attempt.lease_expires_at == lease_expiry

    assert {:error, {:run_not_running, "paused"}} =
             DagScheduler.claim_ready(paused_run, @owner, 1)

    assert {:ok, running_run} = transition_parent(paused_run, "running")

    assert {:ok, %{paused: false, attempts: 1}} =
             DagScheduler.set_paused(running_run, @owner, 1, false)

    resumed_attempt = Repo.get!(IexCode.Runs.RunStepAttempt, claim.attempt.id)
    resumed_step = Repo.get!(RunStep, claim.step.id)
    assert resumed_attempt.status == "running"
    assert resumed_step.status == "running"
    assert resumed_attempt.checkpoint == %{"cursor" => 1}
    assert resumed_attempt.lease_expires_at == lease_expiry

    pause_events =
      running_run
      |> Runs.list_events()
      |> Enum.filter(&(&1.type == "run.dag_pause_changed"))

    assert Enum.map(pause_events, & &1.payload["paused"]) == [true, false]
  end

  test "system reconciliation closes current attempts after parent interruption once", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, first} = DagScheduler.claim_ready(run, @owner, 1)
    assert {:ok, second} = DagScheduler.claim_ready(run, @owner, 1)

    # Model a legacy/external terminal write that predates the atomic parent +
    # graph finalizer. The system reconciler must repair it exactly once.
    {1, _} =
      from(current in Run, where: current.id == ^run.id)
      |> Repo.update_all(set: [status: "interrupted"])

    interrupted_run = Runs.get_run!(run.id)

    assert {:ok, %{status: "interrupted", attempts: 2, steps: 3}} =
             DagScheduler.reconcile_terminal_run(interrupted_run)

    attempts = DagScheduler.list_attempts(run)
    assert Enum.all?(attempts, &(&1.status == "interrupted"))
    assert Enum.all?(attempts, &(is_nil(&1.lease_owner) and is_nil(&1.lease_expires_at)))

    steps = Runs.list_steps(run)
    assert Enum.find(steps, &(&1.id == first.step.id)).status == "interrupted"
    assert Enum.find(steps, &(&1.id == second.step.id)).status == "interrupted"
    assert Enum.find(steps, &(&1.key == "join")).status == "skipped"

    event_count =
      run
      |> Runs.list_events()
      |> Enum.count(&(&1.type == "run.dag_terminal_reconciled"))

    assert event_count == 1

    assert {:ok, %{attempts: 0, steps: 0}} =
             DagScheduler.reconcile_terminal_run(interrupted_run)

    assert event_count ==
             run
             |> Runs.list_events()
             |> Enum.count(&(&1.type == "run.dag_terminal_reconciled"))
  end

  test "system terminal reconciliation rejects active parent and manifest drift", context do
    {run, steps} = dag_fixture(context)
    assert {:error, {:run_not_terminal, "running"}} = DagScheduler.reconcile_terminal_run(run)
    assert {:ok, interrupted} = transition_parent(run, "interrupted")
    [step | _rest] = steps

    Repo.update_all(from(current in RunStep, where: current.id == ^step.id),
      set: [title: "drift"]
    )

    assert {:error, :manifest_drift} = DagScheduler.reconcile_terminal_run(interrupted)
  end

  test "public DAG retry retains attempts and resets the logical graph for a new generation",
       context do
    {run, original_steps} = dag_fixture(context)
    assert {:ok, failed_root} = DagScheduler.claim_ready(run, @owner, 1)
    assert {:ok, sibling} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, _} =
             DagScheduler.fail(
               failed_root.attempt,
               @owner,
               1,
               failed_root.attempt.lease_generation,
               :timeout
             )

    assert {:ok, _} =
             DagScheduler.complete(
               sibling.attempt,
               @owner,
               1,
               sibling.attempt.lease_generation,
               %{"value" => sibling.step.key}
             )

    failed_run = Repo.get!(Run, run.id)
    assert failed_run.status == "failed"
    old_attempt_ids = DagScheduler.list_attempts(run) |> Enum.map(& &1.id) |> MapSet.new()

    assert {:ok, queued} = Runs.retry_run(failed_run)
    assert queued.status == "queued"
    assert Enum.map(Runs.list_steps(run), & &1.id) == Enum.map(original_steps, & &1.id)

    reset_steps = Runs.list_steps(run)
    assert Enum.all?(reset_steps, &(&1.attempt == 0 and &1.progress == 0 and is_nil(&1.result)))
    assert Enum.all?(Enum.filter(reset_steps, &(&1.depends_on == [])), &(&1.status == "ready"))
    assert Enum.all?(Enum.filter(reset_steps, &(&1.depends_on != [])), &(&1.status == "pending"))

    assert {:ok, claimed} = Runs.claim_next_run(@owner, execution_engines: ["dag_v1"])
    assert claimed.attempt == 2
    assert claimed.lease_generation == 2

    assert {:ok, completed} =
             DagRunner.run(claimed,
               lease_owner: @owner,
               lease_generation: 2,
               project_root: context.root,
               poll_ms: 5,
               heartbeat_ms: 10
             )

    assert completed.status == "completed"
    attempts = DagScheduler.list_attempts(run)
    assert MapSet.subset?(old_attempt_ids, MapSet.new(Enum.map(attempts, & &1.id)))
    assert Enum.count(attempts, &(&1.run_attempt == 2 and &1.status == "completed")) == 3
    assert length(Runs.list_steps(run)) == 3
  end

  defp dag_fixture(context, opts \\ []) do
    specs = [
      %{
        key: "inventory",
        kind: "project_inventory",
        title: "Inventory",
        max_attempts: opts[:max_attempts] || 1
      },
      %{key: "read", kind: "read_file", title: "Read", params: %{"path" => "README.md"}},
      %{key: "join", kind: "aggregate", title: "Join", depends_on: ["inventory", "read"]}
    ]

    {:ok, normalized} = DagManifest.normalize(specs)
    {:ok, manifest_hash} = DagManifest.hash(specs)
    expiry = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

    {:ok, run} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "Execute a durable DAG",
        kind: "analysis",
        mode: "workflow",
        execution_engine: "dag_v1",
        manifest_hash: manifest_hash,
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: @owner,
        lease_expires_at: expiry,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    steps =
      Enum.map(normalized, fn spec ->
        descriptor = DagStepRegistry.descriptor!(spec.kind)

        %RunStep{run_id: run.id}
        |> RunStep.create_changeset(%{
          key: spec.key,
          kind: spec.kind,
          title: spec.title,
          position: spec.position,
          status: spec.status,
          max_attempts: spec.max_attempts,
          depends_on: spec.depends_on,
          params: spec.params,
          handler_version: descriptor.version,
          effect_class: Atom.to_string(descriptor.effect_class),
          replay_policy: Atom.to_string(descriptor.replay_policy),
          resource_spec: %{"contract" => descriptor.resource_contract},
          timeout_ms: descriptor.default_timeout_ms
        })
        |> Repo.insert!()
      end)

    {run, steps}
  end

  defp transition_parent(run, status, attrs \\ %{}) do
    Runs.transition_run_worker(run, status, attrs,
      lease_owner: @owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    )
  end
end
