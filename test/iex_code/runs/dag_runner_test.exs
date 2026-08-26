defmodule IexCode.Runs.DagRunnerTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Runs, Sessions}

  alias IexCode.Runs.{
    DagManifest,
    DagRunner,
    DagStepRegistry,
    Run,
    RunStep
  }

  @owner "dag-runner-test-owner"

  setup do
    root = Path.join(System.tmp_dir!(), "dag-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "one.txt"), "one")
    File.write!(Path.join(root, "two.txt"), "two")

    {:ok, project} =
      Projects.create_project(%{
        name: "dag-runner-#{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "DAG runner"})
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session, root: root}
  end

  test "bounds fanout and releases dependent work only after fan-in", context do
    manifest = [
      step("one", "read_file", %{"path" => "one.txt"}),
      step("two", "read_file", %{"path" => "two.txt"}),
      step("inventory", "project_inventory", %{}),
      step("join", "aggregate", %{}, ["one", "two", "inventory"])
    ]

    run = dag_run(context, manifest)
    receiver = self()
    executor = blocking_executor(receiver)
    runner = start_runner(run, context.root, executor, max_concurrency: 2)

    first = assert_started()
    second = assert_started()
    refute first.key == second.key
    refute_receive {:step_started, _, _}, 50

    send(first.pid, :release)
    third = assert_started()
    refute third.key == "join"

    send(second.pid, :release)
    send(third.pid, :release)
    join = assert_started()
    assert join.key == "join"
    send(join.pid, :release)

    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000
    assert Enum.all?(Runs.list_steps(run), &(&1.status == "completed"))
  end

  test "executes the closed typed handler registry without an injected executor", context do
    manifest = [
      step("one", "read_file", %{"path" => "one.txt"}),
      step("inventory", "project_inventory", %{}),
      step("join", "aggregate", %{}, ["one", "inventory"])
    ]

    run = dag_run(context, manifest)
    runner = start_runner(run, context.root, nil, max_concurrency: 2)

    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000

    results = Map.new(Runs.list_steps(run), &{&1.key, &1.result})
    assert results["one"]["content"] == "one"
    assert results["inventory"]["entries"] == ["one.txt", "two.txt"]
    assert results["join"]["dependencies"]["one"]["content"] == "one"
  end

  test "execution context exposes a bound provider effect without raw authority", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})])
    receiver = self()

    executor = fn claim, step_context ->
      send(receiver, {
        :provider_effect_context,
        is_function(step_context.provider_effect, 5),
        Map.keys(step_context),
        Map.take(step_context, [
          :owner,
          :lease_owner,
          :run_generation,
          :step_generation,
          :lease_generation
        ])
      })

      {:ok, %{"key" => claim.step.key}}
    end

    runner = start_runner(run, context.root, executor, poll_ms: 10)

    assert_receive {:provider_effect_context, true, keys, %{}}, 2_000
    assert :provider_effect in keys
    assert :cancelled? in keys
    assert :checkpoint_callback in keys
    refute :owner in keys
    refute :lease_owner in keys
    refute :run_generation in keys
    refute :step_generation in keys
    refute :lease_generation in keys

    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000
  end

  test "heartbeats an active attempt while its handler is blocked", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})])
    receiver = self()

    runner =
      start_runner(run, context.root, blocking_executor(receiver),
        heartbeat_ms: 10,
        internal_observer: receiver
      )

    started = assert_started()
    [attempt] = IexCode.Runs.DagScheduler.list_attempts(run)
    first_heartbeat = attempt.heartbeat_at

    assert_receive {:dag_runner, {:heartbeat, 1}}, 500
    [renewed] = IexCode.Runs.DagScheduler.list_attempts(run)
    assert DateTime.compare(renewed.heartbeat_at, first_heartbeat) == :gt
    assert renewed.status == "running"

    send(started.pid, :release)
    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000
  end

  test "rejects a stale parent generation before claiming any step", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})])
    receiver = self()

    runner =
      start_runner(run, context.root, blocking_executor(receiver),
        lease_generation: run.lease_generation + 1
      )

    assert_receive {:dag_runner_result, ^runner, {:error, :run_lease_lost}}, 2_000
    refute_receive {:step_started, _, _}, 50
    assert [%RunStep{status: "ready", attempt: 0}] = Runs.list_steps(run)
  end

  test "paused parent claims no work until a fenced resume", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})], status: "paused")
    receiver = self()
    runner = start_runner(run, context.root, blocking_executor(receiver), poll_ms: 10)

    refute_receive {:step_started, _, _}, 50
    assert {:ok, _running} = transition_parent(run, "running")
    started = assert_started()
    send(started.pid, :release)

    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000
  end

  test "an active checkpoint blocks while the parent is paused and resumes safely", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})])
    receiver = self()

    executor = fn claim, step_context ->
      send(receiver, {:step_started, claim.step.key, self()})

      receive do
        :checkpoint ->
          send(receiver, :checkpoint_entered)
          result = step_context.checkpoint_callback.(%{"cursor" => 1}, 50)
          send(receiver, {:checkpoint_result, result})
          {:ok, %{"key" => claim.step.key}}
      end
    end

    runner =
      start_runner(run, context.root, executor,
        poll_ms: 10,
        internal_observer: receiver
      )

    started = assert_started()
    assert {:ok, paused} = transition_parent(run, "paused")
    assert_receive {:dag_runner, {:control, :paused, 1}}, 500
    send(started.pid, :checkpoint)
    assert_receive :checkpoint_entered, 500
    refute_receive {:checkpoint_result, _result}, 50

    assert {:ok, _running} = transition_parent(paused, "running")
    assert_receive {:checkpoint_result, {:ok, _attempt}}, 1_000
    assert_receive {:dag_runner_result, ^runner, {:ok, %Run{status: "completed"}}}, 2_000
  end

  test "step timeout fails and terminalizes a single-attempt graph", context do
    manifest = [step("inventory", "project_inventory", %{}, [], 1)]
    run = dag_run(context, manifest)
    receiver = self()

    runner =
      start_runner(run, context.root, blocking_executor(receiver),
        poll_ms: 10,
        internal_step_timeout_ms: 25
      )

    started = assert_started()
    ref = Process.monitor(started.pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    assert_receive {:dag_runner_result, ^runner,
                    {:error, {:dag_run_terminal, %Run{status: "failed"}}}},
                   2_000

    assert [%RunStep{status: "failed", error_message: "timeout"}] = Runs.list_steps(run)
  end

  test "invalid handler output fails the step instead of aborting the runner", context do
    for {label, output} <- [
          {"secret", %{"api_key" => "must-not-persist"}},
          {"oversized", %{"content" => String.duplicate("x", 300_000)}}
        ] do
      run =
        dag_run(context, [step("inventory-#{label}", "project_inventory", %{}, [], 1)])

      executor = fn _claim, _step_context -> {:ok, output} end
      runner = start_runner(run, context.root, executor, poll_ms: 10)

      assert_receive {:dag_runner_result, ^runner,
                      {:error, {:dag_run_terminal, %Run{status: "failed"}}}},
                     2_000

      assert [%RunStep{status: "failed", error_message: "invalid_step_output"}] =
               Runs.list_steps(run)

      [attempt] = IexCode.Runs.DagScheduler.list_attempts(run)
      assert attempt.status == "failed"
      assert attempt.error_message == "invalid_step_output"
      refute inspect(attempt) =~ "must-not-persist"
    end
  end

  test "cancellation intent stops all active tasks without claiming more work", context do
    manifest = [
      step("one", "read_file", %{"path" => "one.txt"}),
      step("two", "read_file", %{"path" => "two.txt"}),
      step("inventory", "project_inventory", %{})
    ]

    run = dag_run(context, manifest)
    receiver = self()
    runner = start_runner(run, context.root, blocking_executor(receiver), max_concurrency: 2)
    first = assert_started()
    second = assert_started()
    first_ref = Process.monitor(first.pid)
    second_ref = Process.monitor(second.pid)

    assert {:ok, _requested} = Runs.request_cancellation(run)
    assert_receive {:DOWN, ^first_ref, :process, _, _}, 2_000
    assert_receive {:DOWN, ^second_ref, :process, _, _}, 2_000
    refute_receive {:step_started, _, _}, 50

    assert_receive {:dag_runner_result, ^runner, {:error, {:run_cancellation_requested, %Run{}}}},
                   2_000

    assert Enum.all?(Runs.list_steps(run), &(&1.status == "cancelled"))
  end

  test "an externally terminalized parent leaves no live task or attempt", context do
    run = dag_run(context, [step("inventory", "project_inventory", %{})])
    receiver = self()
    runner = start_runner(run, context.root, blocking_executor(receiver), poll_ms: 10)
    started = assert_started()
    task_ref = Process.monitor(started.pid)

    assert {:ok, failed} =
             transition_parent(run, "failed", %{
               error_message: "external terminalization",
               error_details: %{"reason" => "external_terminalization"}
             })

    assert_receive {:DOWN, ^task_ref, :process, _, _}, 2_000

    assert_receive {:dag_runner_result, ^runner,
                    {:error, {:dag_run_terminal, %Run{id: failed_id, status: "failed"}}}},
                   2_000

    assert failed_id == failed.id

    refute Enum.any?(
             IexCode.Runs.DagScheduler.list_attempts(run),
             &(&1.status in ["running", "paused"])
           )

    refute Enum.any?(Runs.list_steps(run), &(&1.status in ["running", "paused"]))
  end

  defp start_runner(run, root, executor, opts) do
    receiver = self()

    task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               DagRunner.run(
                 run,
                 Keyword.merge(
                   [
                     lease_owner: @owner,
                     lease_generation: run.lease_generation,
                     project_root: root,
                     internal_step_executor: executor,
                     heartbeat_ms: 10,
                     lease_ms: 250,
                     poll_ms: 10
                   ],
                   opts
                 )
               )

             send(receiver, {:dag_runner_result, self(), result})
           end},
          id: {:dag_runner_test, System.unique_integer([:positive])}
        )
      )

    task
  end

  defp transition_parent(run, status, attrs \\ %{}) do
    Runs.transition_run_worker(run, status, attrs,
      lease_owner: @owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    )
  end

  defp blocking_executor(receiver) do
    fn claim, _context ->
      send(receiver, {:step_started, claim.step.key, self()})
      receive do: (:release -> {:ok, %{"key" => claim.step.key}})
    end
  end

  defp assert_started do
    assert_receive {:step_started, key, pid}, 2_000
    %{key: key, pid: pid}
  end

  defp dag_run(context, manifest, opts \\ []) do
    {:ok, normalized} = DagManifest.normalize(manifest)
    {:ok, manifest_hash} = DagManifest.hash(manifest)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, run} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "Execute deterministic DAG",
        kind: "analysis",
        mode: "workflow",
        execution_engine: "dag_v1",
        manifest_hash: manifest_hash,
        status: Keyword.get(opts, :status, "running"),
        attempt: 1,
        lease_generation: 1,
        lease_owner: @owner,
        lease_expires_at: DateTime.add(timestamp, 60, :second),
        heartbeat_at: timestamp,
        started_at: timestamp
      })
      |> Repo.insert()

    Enum.each(normalized, fn spec ->
      descriptor = DagStepRegistry.descriptor!(spec.kind)

      attrs = %{
        key: spec.key,
        kind: spec.kind,
        title: spec.title,
        status: spec.status,
        position: spec.position,
        max_attempts: spec.max_attempts,
        depends_on: spec.depends_on,
        params: spec.params,
        handler_version: descriptor.version,
        effect_class: Atom.to_string(descriptor.effect_class),
        replay_policy: Atom.to_string(descriptor.replay_policy),
        resource_spec: %{"contract" => descriptor.resource_contract},
        timeout_ms: Keyword.get(opts, :timeout_ms, descriptor.default_timeout_ms)
      }

      %RunStep{run_id: run.id}
      |> RunStep.create_changeset(attrs)
      |> Repo.insert!()
    end)

    run
  end

  defp step(key, kind, params, depends_on \\ [], max_attempts \\ 1) do
    %{
      key: key,
      kind: kind,
      title: "Step #{key}",
      params: params,
      depends_on: depends_on,
      max_attempts: max_attempts
    }
  end
end
