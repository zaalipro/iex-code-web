defmodule IexCode.Engine.DurableFleetTest do
  use IexCode.DataCase, async: false

  alias IexCode.Execution.Router
  alias IexCode.{Projects, Repo, Runs, Sessions, Settings}
  alias IexCode.Runs.{Executor, Run, RunAgent}

  alias IexCode.Engine.{
    AgentRegistry,
    AgentSupervisor,
    FleetManager,
    FleetRuntime,
    FleetControlToken,
    FleetSupervisor,
    FleetTopology,
    OperationManager,
    RunFleetSupervisor
  }

  setup do
    root = Path.join(System.tmp_dir!(), "iex-fleet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "fleet-#{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Fleet runtime"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session, root: root}
  end

  test "legacy topology is deterministic and bounded" do
    for requested <- 1..4 do
      specs = FleetTopology.manifest(requested)
      assert Enum.map(specs, & &1.role) == ["planner", "explorer", "coder", "verifier"]
      assert Enum.map(specs, & &1.position) == [0, 1, 2, 3]
    end

    assert length(FleetTopology.manifest(32)) == 32
    assert length(FleetTopology.manifest(33)) == 32
    assert Enum.count(FleetTopology.manifest(32), &(&1.role == "explorer")) == 29
  end

  test "snapshotted fleet size and model policy override later runtime defaults", ctx do
    {:ok, _queued} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "snapshotted fleet",
        kind: "coding_swarm",
        mode: "swarm",
        metadata: %{
          "execution_policy" => %{
            "swarm_agent_count" => 6,
            "model_provider" => "anthropic",
            "model_name" => "snapshotted-swarm-model",
            "temperature" => 0.7
          }
        }
      })

    owner = "fleet-policy:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4)
    assert length(agents) == 6
    assert Enum.count(agents, &(&1.role == :explorer)) == 3

    planner = Enum.find(agents, &(&1.role == :planner))
    planner_state = IexCode.Engine.Agents.PlannerAgent.get_state(planner.pid)
    assert planner_state.session.model_provider == "anthropic"
    assert planner_state.session.model_name == "snapshotted-swarm-model"
    assert planner_state.session.temperature == 0.7
  end

  test "router-enqueued 240-byte model reaches the durable fleet", ctx do
    model = String.duplicate("m", 240)

    assert {:ok, %{run: queued}} =
             Router.route("/swarm execute the bounded fleet model", %{
               project_id: ctx.project.id,
               session_id: ctx.session.id,
               settings: Settings.get_settings(),
               overrides: %{model_name: model, swarm_agent_count: 4},
               request_key: "fleet-model-boundary-#{Ecto.UUID.generate()}"
             })

    assert queued.metadata["execution_policy"]["model_name"] == model

    owner = "fleet-router:#{System.unique_integer([:positive])}"
    assert {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    assert run.id == queued.id
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, agents} = FleetSupervisor.attach(run, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))
    planner_state = IexCode.Engine.Agents.PlannerAgent.get_state(planner.pid)
    assert planner_state.session.model_name == model
  end

  test "two runs in one session have isolated registry identities and stopping one is scoped",
       ctx do
    run_a = running_run(ctx, "A")

    root_b = Path.join(System.tmp_dir!(), "iex-fleet-b-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root_b)
    on_exit(fn -> File.rm_rf(root_b) end)

    {:ok, project_b} =
      Projects.create_project(%{
        name: "fleet-b-#{System.unique_integer([:positive])}",
        root_path: root_b
      })

    {:ok, session_b} =
      Sessions.create_session(%{project_id: project_b.id, title: "Fleet runtime B"})

    run_b =
      running_run(%{project: project_b, session: session_b, root: root_b}, "B")

    on_exit(fn ->
      FleetSupervisor.stop(run_a.id)
      FleetSupervisor.stop(run_b.id)
    end)

    assert {:ok, agents_a} = FleetSupervisor.attach(run_a, agent_count: 4, project_root: ctx.root)
    assert {:ok, agents_b} = FleetSupervisor.attach(run_b, agent_count: 4, project_root: root_b)

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(agents_a, & &1.pid)),
             MapSet.new(Enum.map(agents_b, & &1.pid))
           )

    assert length(AgentRegistry.list_run_agents(run_a.id)) == 4
    assert length(AgentRegistry.list_run_agents(run_b.id)) == 4

    b_pids = Enum.map(agents_b, & &1.pid)

    assert :ok =
             FleetManager.stop(run_a.id, "cancelled",
               lease_owner: run_a.lease_owner,
               run_attempt: run_a.attempt,
               lease_generation: run_a.lease_generation
             )

    assert Enum.all?(b_pids, &Process.alive?/1)
    assert length(AgentRegistry.list_run_agents(run_b.id)) == 4
  end

  test "targeted controls are durable, ordered, fenced, and isolated", ctx do
    run = running_run(ctx, "controls")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))
    explorer = Enum.find(agents, &(&1.role == :explorer))
    explorer_pid = explorer.pid

    assert {:ok, :paused} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :pause, %{
               idempotency_key: "pause-1"
             })

    assert Runs.get_run_agent(planner.agent_id).status == "paused"
    assert Process.alive?(explorer_pid)

    assert {:ok, :steered} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :steer, %{
               idempotency_key: "steer-1",
               guidance: "Inspect only public APIs"
             })

    assert FleetManager.drain_steering(run.id, planner.agent_id) == ["Inspect only public APIs"]
    assert FleetManager.drain_steering(run.id, planner.agent_id) == []

    assert {:ok, :resumed} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :resume, %{
               idempotency_key: "resume-1"
             })

    before = Runs.get_run_agent(planner.agent_id)
    old_planner_pid = planner.pid
    old_planner_ref = Process.monitor(old_planner_pid)

    assert {:ok, restarted} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :restart, %{
               idempotency_key: "restart-1"
             })

    assert restarted.generation == before.lease_generation + 1
    refute restarted.pid == old_planner_pid
    assert_receive {:DOWN, ^old_planner_ref, :process, ^old_planner_pid, _reason}, 2_000
    assert {:ok, %{pid: replacement_pid}} = FleetManager.current_agent(run.id, planner.agent_id)
    assert replacement_pid == restarted.pid
    assert Process.alive?(explorer_pid)

    stale =
      Runs.transition_run_agent(Runs.get_run_agent(planner.agent_id), "paused", %{},
        lease_owner: before.lease_owner,
        lease_generation: before.lease_generation
      )

    assert {:error, :lease_lost} = stale

    assert {:ok, :cancelled} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :cancel, %{
               idempotency_key: "cancel-1"
             })

    assert Runs.get_run_agent(planner.agent_id).status == "cancelled"
    assert Process.alive?(explorer_pid)

    assert Enum.map(Runs.list_run_agent_controls(planner.agent_id), & &1.kind) ==
             ~w(pause steer resume restart cancel)

    serialized =
      planner.agent_id
      |> Runs.list_run_agent_controls()
      |> Enum.map_join("\n", &Jason.encode!(&1.result || %{}))

    refute serialized =~ "#PID"
    refute serialized =~ (before.lease_owner || "never-present")
  end

  test "manager crash tears down children and rehydrates with higher generations", ctx do
    run = running_run(ctx, "recovery")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    generations = Map.new(agents, &{&1.agent_id, &1.generation})
    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    old_pids = Enum.map(agents, & &1.pid)
    ref = Process.monitor(manager)

    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 2_000
    supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    _ = :sys.get_state(supervisor)

    new_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    assert is_pid(new_manager)
    refute new_manager == manager
    _ = :sys.get_state(new_manager)

    recovered = FleetManager.list_agents(run.id)
    assert length(recovered) == 4
    assert Enum.all?(old_pids, &(not Process.alive?(&1)))
    assert Enum.all?(recovered, &(&1.generation > Map.fetch!(generations, &1.agent_id)))
  end

  test "transient rehydration failures are observable and retry to success within the cap", ctx do
    run = running_run(ctx, "observable recovery failure")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    selected = Enum.find(agents, &(&1.role == :explorer))
    original = Runs.get_run_agent(selected.agent_id)
    handler_id = "fleet-rehydrate-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:iex_code, :fleet, :rehydrate_error],
        fn event, measurements, metadata, receiver ->
          send(receiver, {:fleet_rehydrate_error, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {1, _} =
      from(agent in RunAgent, where: agent.id == ^selected.agent_id)
      |> Repo.update_all(set: [lease_owner: String.duplicate("f", 64)])

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 2_000

    supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    _ = :sys.get_state(supervisor)
    recovered_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(recovered_manager)

    assert_receive {:fleet_rehydrate_error, [:iex_code, :fleet, :rehydrate_error], %{count: 1},
                    %{run_id: run_id, agent_id: agent_id, reason: reason}},
                   2_000

    assert run_id == run.id
    assert agent_id == selected.agent_id
    assert reason in [:lease_lost, :lease_expired]
    assert [{agent_id, reason}] = FleetManager.rehydration_errors(run.id)
    assert agent_id == selected.agent_id
    assert reason in [:lease_lost, :lease_expired]
    refute Enum.any?(FleetManager.list_agents(run.id), &(&1.agent_id == selected.agent_id))

    :ok = Runs.subscribe(run)

    {1, _} =
      from(agent in RunAgent, where: agent.id == ^selected.agent_id)
      |> Repo.update_all(set: [lease_owner: original.lease_owner])

    assert_receive {:run_agent_updated, %{id: ^agent_id, status: "idle"}}, 2_000
    assert FleetManager.rehydration_errors(run.id) == []
    assert :sys.get_state(recovered_manager).rehydrate_attempt < 5

    assert {:ok, recovered} = FleetManager.current_agent(run.id, selected.agent_id)
    assert Process.alive?(recovered.pid)
    assert recovered.generation == selected.generation + 1
  end

  test "whole fleet restart reclaims an expired agent lease and its claimed restart control",
       ctx do
    run = running_run(ctx, "whole supervisor claimed restart recovery")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    selected = Enum.find(agents, &(&1.role == :planner))
    old_supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    agent_supervisor = AgentRegistry.via_fleet(run.id, :agent_supervisor)
    old_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    old_agent_ref = Process.monitor(selected.pid)

    assert :ok = AgentSupervisor.stop_run_agent(agent_supervisor, run.id, selected.agent_id)
    assert_receive {:DOWN, ^old_agent_ref, :process, _, _}, 2_000
    _ = :sys.get_state(old_manager)

    interrupted = Runs.get_run_agent(selected.agent_id)
    assert interrupted.status == "interrupted"

    assert {:ok, restart} =
             Runs.enqueue_run_agent_control(
               interrupted,
               "claimed-restart-before-fleet-restart",
               %{
                 kind: "restart",
                 payload: %{},
                 target_generation: interrupted.lease_generation,
                 requested_by: "test"
               }
             )

    assert {:ok, {claimed_agent, claimed_restart}} =
             Runs.claim_restart_run_agent_control(interrupted, "departed-fleet-owner", 100)

    assert claimed_restart.id == restart.id
    assert claimed_restart.status == "claimed"
    assert claimed_agent.status == "starting"

    expires_at = DateTime.utc_now() |> DateTime.add(100, :millisecond)

    {4, _} =
      from(agent in RunAgent,
        where: agent.run_id == ^run.id and agent.status in ^RunAgent.leased_statuses()
      )
      |> Repo.update_all(set: [lease_expires_at: expires_at])

    :ok = Runs.subscribe(run)

    # Replacing the whole tree changes the in-memory fleet credential while the
    # durable rows and claimed restart receipt still belong to the departed one.
    supervisor_ref = Process.monitor(old_supervisor)
    manager_ref = Process.monitor(old_manager)
    Process.exit(old_supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^old_supervisor, :killed}, 2_000
    assert_receive {:DOWN, ^manager_ref, :process, ^old_manager, :killed}, 2_000

    _ = :sys.get_state(FleetSupervisor)

    assert {:ok, new_supervisor} =
             FleetSupervisor.ensure_started(run,
               session: ctx.session,
               project_root: ctx.root
             )

    assert is_pid(new_supervisor)
    refute new_supervisor == old_supervisor
    new_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(new_manager)

    errors = FleetManager.rehydration_errors(run.id)

    assert Enum.any?(errors, fn {agent_id, reason} ->
             agent_id == selected.agent_id and reason in [:lease_lost, :lease_expired]
           end)

    assert_receive {:run_agent_control_updated, %{id: control_id, status: "pending"}}, 3_000
    assert control_id == restart.id

    assert_receive {:run_agent_control_updated, %{id: ^control_id, status: "applied"}}, 3_000

    assert %{status: "applied", result: %{"status" => "restarted"}} =
             Runs.get_run_agent_control(restart.id)

    assert {:ok, recovered} = FleetManager.current_agent(run.id, selected.agent_id)
    assert Process.alive?(recovered.pid)
    assert recovered.generation == claimed_agent.lease_generation + 1
    assert FleetManager.rehydration_errors(run.id) == []
    assert length(FleetManager.list_agents(run.id)) == 4
  end

  test "paused state and queued steering recover without duplicate consumption", ctx do
    run = running_run(ctx, "paused recovery")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))

    assert {:ok, :paused} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :pause, %{
               idempotency_key: "recovery-pause"
             })

    assert {:ok, :steered} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :steer, %{
               idempotency_key: "recovery-steer",
               guidance: "Preserve this guidance"
             })

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 2_000

    supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    _ = :sys.get_state(supervisor)
    recovered_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(recovered_manager)

    [recovered] = Enum.filter(FleetManager.list_agents(run.id), &(&1.role == :planner))
    assert Runs.get_run_agent(recovered.agent_id).status == "paused"

    planner_state = IexCode.Engine.Agents.PlannerAgent.get_state(recovered.pid)
    assert FleetControlToken.paused?(planner_state.control_token)

    assert FleetManager.drain_steering(run.id, recovered.agent_id) == [
             "Preserve this guidance"
           ]

    assert FleetManager.drain_steering(run.id, recovered.agent_id) == []
  end

  test "control replay yields fairly and immediately continues beyond one batch", ctx do
    run = running_run(ctx, "large control backlog")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))
    explorer = Enum.find(agents, &(&1.role == :explorer))

    :ok = Runs.subscribe(run)

    last_planner_control =
      Enum.reduce(1..70, nil, fn index, _previous ->
        assert {:ok, control} =
                 Runs.enqueue_run_agent_control(planner.agent_id, "planner-backlog-#{index}", %{
                   kind: "steer",
                   payload: %{"guidance" => "planner guidance #{index}"},
                   target_generation: planner.generation,
                   requested_by: "test"
                 })

        control
      end)

    assert {:ok, explorer_control} =
             Runs.enqueue_run_agent_control(explorer.agent_id, "explorer-fairness", %{
               kind: "steer",
               payload: %{"guidance" => "explorer must not starve"},
               target_generation: explorer.generation,
               requested_by: "test"
             })

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    send(manager, :replay_controls)

    # This persisted receipt proves the later-position explorer is serviced
    # without using manager mailbox ordering as a proxy for control completion.
    assert {:ok, %{id: explorer_control_id, status: "applied"}} =
             FleetManager.await_control(run.id, explorer_control.id, 10_000)

    assert explorer_control_id == explorer_control.id

    last_control_id = last_planner_control.id

    # A small replay chunk must yield and immediately schedule the remaining
    # chunks until the full backlog has a durable terminal receipt.
    assert {:ok, %{id: ^last_control_id, status: "applied"}} =
             FleetManager.await_control(run.id, last_control_id, 30_000)

    assert length(Runs.list_run_agent_controls(planner.agent_id, status: "applied")) == 70
    assert Runs.list_run_agent_controls(planner.agent_id, status: "pending") == []
  end

  test "durable control receipt has a strict timeout without a fleet process", ctx do
    run = running_run(ctx, "bounded control receipt")

    assert {:ok, [agent]} =
             Runs.create_run_agents(run, [
               %{key: "receipt-planner", role: "planner", adapter: "otp.planner"}
             ])

    assert {:ok, control} =
             Runs.enqueue_run_agent_control(agent.id, "unprocessed-receipt", %{
               kind: "steer",
               payload: %{"guidance" => "remain pending"},
               target_generation: agent.lease_generation,
               requested_by: "test"
             })

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :control_receipt_timeout} =
             FleetManager.await_control(run.id, control.id, 25)

    assert System.monotonic_time(:millisecond) - started_at < 500
    assert Runs.get_run_agent_control(control.id).status == "pending"

    assert {:error, :control_not_found} =
             FleetManager.await_control(Ecto.UUID.generate(), control.id, 100)

    assert {:error, :control_not_found} =
             FleetManager.await_control(run.id, Ecto.UUID.generate(), 100)
  end

  test "durable control receipt bounds transient sandbox ownership loss" do
    original_repo = Repo.get_dynamic_repo()
    repo = start_supervised!({IexCode.ControlReceiptOwnershipRepo, name: nil})
    :ok = Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
    Repo.put_dynamic_repo(repo)
    started_at = System.monotonic_time(:millisecond)

    try do
      assert {:error, :control_receipt_timeout} =
               FleetManager.await_control(Ecto.UUID.generate(), Ecto.UUID.generate(), 25)

      assert System.monotonic_time(:millisecond) - started_at < 500
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  test "stopping a maximum-size fleet terminalizes and tears down every child", ctx do
    run = running_run(ctx, "maximum fleet shutdown")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 32, project_root: ctx.root)
    refs = Map.new(agents, &{Process.monitor(&1.pid), &1.pid})

    assert :ok =
             FleetManager.stop(run.id, "cancelled",
               lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert_all_down(refs, 5_000)

    assert AgentRegistry.whereis_fleet(run.id, :supervisor) == nil
    assert AgentRegistry.list_run_agents(run.id) == []
    assert Enum.all?(Runs.list_run_agents(run.id), &(&1.status == "cancelled"))
  end

  test "heartbeat skips terminal and dead fleet entries", ctx do
    run = running_run(ctx, "heartbeat eligibility")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    cancelled = Enum.find(agents, &(&1.role == :planner))
    dead = Enum.find(agents, &(&1.role == :explorer))

    assert {:ok, :cancelled} =
             RunFleetSupervisor.control_agent(run, cancelled.agent_id, :cancel, %{
               idempotency_key: "heartbeat-terminal"
             })

    dead_ref = Process.monitor(dead.pid)
    Process.exit(dead.pid, :kill)
    assert_receive {:DOWN, ^dead_ref, :process, _, :killed}, 2_000

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    before_heartbeat = :sys.get_state(manager)

    assert Runs.get_run_agent(cancelled.agent_id).status == "cancelled"
    assert Runs.get_run_agent(dead.agent_id).status == "interrupted"
    assert before_heartbeat.agents[cancelled.agent_id].error == nil
    assert before_heartbeat.agents[dead.agent_id].error == ":killed"

    old_heartbeat =
      DateTime.utc_now()
      |> DateTime.add(-3_600, :second)
      |> DateTime.truncate(:microsecond)

    {2, _} =
      from(agent in RunAgent, where: agent.id in ^[cancelled.agent_id, dead.agent_id])
      |> Repo.update_all(set: [heartbeat_at: old_heartbeat])

    send(manager, :heartbeat)
    after_heartbeat = :sys.get_state(manager)

    assert Runs.get_run_agent(cancelled.agent_id).heartbeat_at == old_heartbeat
    assert Runs.get_run_agent(dead.agent_id).heartbeat_at == old_heartbeat
    assert after_heartbeat.agents[cancelled.agent_id].error == nil
    assert after_heartbeat.agents[dead.agent_id].error == ":killed"
  end

  test "forced run-agent shutdown is bounded and awaits every stubborn child" do
    receiver = self()

    pids =
      for index <- 1..4 do
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               Process.flag(:trap_exit, true)
               send(receiver, {:stubborn_agent_ready, self()})
               stubborn_agent_loop()
             end},
            id: {:stubborn_run_agent, index}
          )
        )
      end

    Enum.each(pids, fn pid ->
      assert_receive {:stubborn_agent_ready, ^pid}, 2_000
    end)

    refs = Map.new(pids, &{Process.monitor(&1), &1})
    started_at = System.monotonic_time(:millisecond)

    assert :ok = AgentSupervisor.stop_run_pids(pids, 25)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_all_down(refs, 1_000)
    assert Enum.all?(pids, &(not Process.alive?(&1)))
  end

  test "interrupted agent restart advances generation and later invocation resolves replacement",
       ctx do
    run = running_run(ctx, "agent crash")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    explorer = Enum.find(agents, &(&1.role == :explorer))
    sibling = Enum.find(agents, &(&1.role == :planner))
    sibling_ref = Process.monitor(sibling.pid)
    explorer_pid = explorer.pid
    ref = Process.monitor(explorer_pid)

    Process.exit(explorer_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^explorer_pid, :killed}, 2_000
    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(manager)

    assert AgentRegistry.whereis_agent(run.id, explorer.agent_id) == nil
    interrupted = Runs.get_run_agent(explorer.agent_id)
    assert interrupted.status == "interrupted"

    assert {:ok, restarted} =
             RunFleetSupervisor.control_agent(run, explorer.agent_id, :restart, %{
               idempotency_key: "restart-interrupted-agent"
             })

    assert restarted.agent_id == explorer.agent_id
    assert restarted.generation == interrupted.lease_generation + 1
    refute restarted.pid == explorer_pid
    refute_receive {:DOWN, ^sibling_ref, :process, _, _}, 50
    Process.demonitor(sibling_ref, [:flush])

    assert {:ok, current} = FleetManager.current_agent(run.id, explorer.agent_id)
    assert current.pid == restarted.pid
    assert current.generation == restarted.generation

    assert %IexCode.Engine.Agents.ExplorerAgent.State{session_id: session_id} =
             FleetRuntime.invoke_agent(run.id, explorer.agent_id, fn replacement ->
               IexCode.Engine.Agents.ExplorerAgent.get_state(replacement.pid)
             end)

    assert session_id == ctx.session.id

    assert {:error, :agent_invocation_interrupted} =
             FleetRuntime.invoke_agent(run.id, explorer.agent_id, fn _replacement ->
               exit(:simulated_agent_call_exit)
             end)
  end

  test "strict allowlist fails closed on a spoofed registry occupant", ctx do
    run = running_run(ctx, "spoof")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, _agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    supervisor = AgentRegistry.via_fleet(run.id, :agent_supervisor)
    spoof_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Registry.register(AgentRegistry, {:run_agent, run.id, spoof_id}, %{role: :planner})

    assert {:error, :registration_conflict} =
             AgentSupervisor.start_run_agent(supervisor, run.id, spoof_id, :planner,
               session_id: ctx.session.id,
               project_root: ctx.root
             )

    assert_raise ArgumentError, fn ->
      AgentSupervisor.start_run_agent(supervisor, run.id, Ecto.UUID.generate(), :unknown,
        session_id: ctx.session.id
      )
    end
  end

  test "fleet-owned operation task is linked and dies with its owner", ctx do
    receiver = self()

    {:ok, owner} =
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        Process.put(:iex_code_fleet_owner, %{run_id: "run", agent_id: "agent"})

        OperationManager.run_sync_operation(
          ctx.session.id,
          nil,
          "TestAgent",
          "test",
          "blocked fleet operation",
          %{},
          fn _progress ->
            send(receiver, {:operation_child, self()})
            receive do: (:finish -> {:ok, :done})
          end,
          :infinity
        )
      end)

    assert_receive {:operation_child, child}, 2_000
    child_ref = Process.monitor(child)
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
  end

  test "direct dag_v1 ledger rows never fall through to legacy-only executor or fleet", ctx do
    {:ok, run} =
      %Run{project_id: ctx.project.id, session_id: ctx.session.id}
      |> Run.create_changeset(%{
        objective: "direct dag ledger row",
        kind: "coding_swarm",
        mode: "swarm",
        execution_engine: "dag_v1",
        manifest_hash: String.duplicate("0", 64)
      })
      |> Repo.insert()

    assert {:error, {:execution_engine_unavailable, "dag_v1"}} =
             Executor.execute(run, fn _, _ -> :ok end)

    assert {:error, {:execution_engine_unavailable, "dag_v1"}} =
             FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)

    assert {:error, {:execution_engine_unavailable, "dag_v1"}} =
             FleetSupervisor.ensure_started(run, project_root: ctx.root)

    assert AgentRegistry.whereis_fleet(run.id, :manager) == nil
  end

  test "durable attach rejects a crafted session or project scope", ctx do
    run = running_run(ctx, "scope")
    forged = %{run | session_id: Ecto.UUID.generate()}

    assert {:error, :run_scope_mismatch} =
             FleetSupervisor.attach(forged, agent_count: 4, project_root: ctx.root)

    assert AgentRegistry.whereis_fleet(run.id, :manager) == nil
  end

  test "a retry replaces the old fleet tree and stale lineage cannot stop the new fleet", ctx do
    run = running_run(ctx, "fleet lineage replacement")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, old_agents} =
             FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)

    old_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    old_manager_ref = Process.monitor(old_manager)

    assert {:ok, _interrupted} =
             Runs.terminalize_run_agents(run, "interrupted", %{},
               lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    {1, _} =
      Repo.update_all(
        from(parent in Run, where: parent.id == ^run.id),
        inc: [attempt: 1, lease_generation: 1]
      )

    retry = Runs.get_run!(run.id)

    old_agent = hd(old_agents)

    assert {:error, :parent_lease_lost} =
             FleetManager.current_agent(run.id, old_agent.agent_id)

    assert {:error, :parent_lease_lost} =
             FleetRuntime.begin_work(
               %{
                 run_id: run.id,
                 agent_id: old_agent.agent_id,
                 generation: old_agent.generation
               },
               "must not cross parent attempts"
             )

    assert {:ok, new_agents} =
             FleetSupervisor.attach(retry, agent_count: 4, project_root: ctx.root)

    assert_receive {:DOWN, ^old_manager_ref, :process, ^old_manager, _reason}, 2_000
    refute AgentRegistry.whereis_fleet(run.id, :manager) == old_manager

    refute MapSet.new(Enum.map(old_agents, & &1.agent_id)) ==
             MapSet.new(Enum.map(new_agents, & &1.agent_id))

    assert {:error, :parent_lease_lost} =
             FleetManager.stop(run.id, "cancelled",
               lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert Enum.all?(Runs.list_run_agents(retry), &(&1.status in RunAgent.leased_statuses()))
    assert Enum.all?(new_agents, &(is_pid(&1.pid) and Process.alive?(&1.pid)))
  end

  test "fenced work lifecycle updates only the selected durable agent", ctx do
    run = running_run(ctx, "lifecycle")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    selected = Enum.find(agents, &(&1.role == :explorer))
    sibling = Enum.find(agents, &(&1.role == :planner))
    row = Runs.get_run_agent(selected.agent_id)
    receiver = self()

    owner = %{
      run_id: run.id,
      agent_id: row.id,
      generation: row.lease_generation
    }

    task =
      start_supervised!(
        {Task,
         fn ->
           send(receiver, {:fleet_task_ready, self()})
           receive do: (:go -> :ok)

           FleetRuntime.run(owner, "controlled exploration", fn ->
             :ok = FleetRuntime.progress(owner, 42, "reading symbols")
             send(receiver, :fleet_work_started)
             receive do: (:finish -> {:ok, :done})
           end)
         end}
      )

    assert_receive {:fleet_task_ready, ^task}, 2_000
    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), task)
    send(task, :go)

    assert_receive :fleet_work_started, 2_000
    running = Runs.get_run_agent(selected.agent_id)
    assert running.status == "running"
    assert running.progress == 42
    assert running.current_task == "reading symbols"
    assert Runs.get_run_agent(sibling.agent_id).status == "idle"

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    send(manager, :heartbeat)
    _ = :sys.get_state(manager)
    assert Runs.get_run_agent(selected.agent_id).progress == 42
    assert Runs.get_run_agent(selected.agent_id).current_task == "reading symbols"

    ref = Process.monitor(task)
    send(task, :finish)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 2_000
    assert Runs.get_run_agent(selected.agent_id).status == "idle"
  end

  test "one agent exhausting the run budget promptly gates and terminalizes its siblings", ctx do
    run = running_run(ctx, "budget exhaustion")
    {:ok, paused} = transition_parent(run, "paused")
    {:ok, run} = transition_parent(paused, "running", %{token_budget: 3})
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    exhausting = Enum.find(agents, &(&1.role == :planner))
    sibling = Enum.find(agents, &(&1.role == :explorer))

    exhausting_owner = %{
      run_id: run.id,
      agent_id: exhausting.agent_id,
      generation: exhausting.generation
    }

    sibling_owner = %{
      run_id: run.id,
      agent_id: sibling.agent_id,
      generation: sibling.generation
    }

    assert :ok = FleetRuntime.begin_work(exhausting_owner, "budgeted provider call")
    assert :ok = FleetRuntime.begin_work(sibling_owner, "concurrent sibling call")

    exhausting_state = IexCode.Engine.Agents.PlannerAgent.get_state(exhausting.pid)
    sibling_state = IexCode.Engine.Agents.ExplorerAgent.get_state(sibling.pid)
    exhausting_ref = Process.monitor(exhausting.pid)
    sibling_ref = Process.monitor(sibling.pid)
    receiver = self()

    exhaust_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(receiver, {:budget_caller_ready, self()})
             receive do: (:go -> :ok)

             result =
               FleetRuntime.record_usage(exhausting_owner, %{input_tokens: 5}, "planner.llm")

             send(receiver, {:budget_result, result})
           end},
          id: :budget_exhaustion_caller
        )
      )

    sibling_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(receiver, {:budget_caller_ready, self()})
             receive do: (:go -> :ok)

             result =
               FleetRuntime.record_usage(sibling_owner, %{input_tokens: 1}, "explorer.llm")

             send(receiver, {:sibling_usage_result, result})
           end},
          id: :budget_sibling_caller
        )
      )

    assert_receive {:budget_caller_ready, ^exhaust_task}, 2_000
    assert_receive {:budget_caller_ready, ^sibling_task}, 2_000
    send(exhaust_task, :go)

    assert_receive {:budget_result, {:error, :token_budget_exhausted}}, 2_000
    send(sibling_task, :go)

    assert_receive {:sibling_usage_result, {:error, {:run_not_active, "failed"}}}, 2_000

    assert FleetControlToken.cancelled?(exhausting_state.control_token)
    assert FleetControlToken.cancelled?(sibling_state.control_token)
    assert_receive {:DOWN, ^exhausting_ref, :process, _, _}, 2_000
    assert_receive {:DOWN, ^sibling_ref, :process, _, _}, 2_000

    failed_run = Runs.get_run!(run.id)
    assert failed_run.status == "failed"
    assert failed_run.error_details["reason"] == "budget_exhausted"
    assert failed_run.error_details["budget"] == "tokens"

    assert Enum.all?(Runs.list_run_agents(run.id), &(&1.status == "failed"))

    assert {:error, {:run_not_active, "failed"}} =
             FleetRuntime.begin_work(sibling_owner, "must remain gated")

    assert {:error, {:run_not_active, "failed"}} =
             FleetRuntime.progress(sibling_owner, 99, "must not advance")

    assert {:error, {:run_not_active, "failed"}} =
             FleetRuntime.finish_work(sibling_owner, {:ok, :too_late})

    assert {:error, {:run_not_active, "failed"}} =
             FleetRuntime.record_usage(sibling_owner, %{input_tokens: 1}, "explorer.llm")
  end

  test "cost exhaustion returns a structured fleet error and terminalizes the fleet", ctx do
    run = running_run(ctx, "cost exhaustion")
    {:ok, paused} = transition_parent(run, "paused")
    {:ok, run} = transition_parent(paused, "running", %{cost_budget_cents: 2})
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    selected = Enum.find(agents, &(&1.role == :planner))

    original_expiry =
      DateTime.utc_now()
      |> DateTime.add(2, :second)
      |> DateTime.truncate(:second)

    assert {:ok, _near_expiry} =
             run
             |> Ecto.Changeset.change(lease_expires_at: original_expiry)
             |> Repo.update()

    owner = %{
      run_id: run.id,
      agent_id: selected.agent_id,
      generation: selected.generation
    }

    assert {:error, :cost_budget_exhausted} =
             FleetRuntime.record_usage(owner, %{cost_cents: 3}, "planner.llm")

    assert %{
             status: "failed",
             lease_owner: lease_owner,
             lease_expires_at: terminal_expiry,
             error_details: %{"budget" => "cost_cents"}
           } = Runs.get_run!(run.id)

    assert is_binary(lease_owner)
    assert DateTime.compare(terminal_expiry, original_expiry) == :gt

    assert Enum.all?(Runs.list_run_agents(run.id), &(&1.status == "failed"))
  end

  test "agent-owned usage caller observes budget error before its owner is terminated", ctx do
    run = running_run(ctx, "agent owned budget caller")
    {:ok, paused} = transition_parent(run, "paused")
    {:ok, run} = transition_parent(paused, "running", %{token_budget: 3})
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    assert {:ok, agents} =
             FleetSupervisor.attach(run,
               agent_count: 4,
               project_root: ctx.root,
               allowed_tools: []
             )

    coder = Enum.find(agents, &(&1.role == :coder))
    sibling = Enum.find(agents, &(&1.role == :explorer))
    coder_ref = Process.monitor(coder.pid)
    sibling_ref = Process.monitor(sibling.pid)
    receiver = self()

    owner = %{
      run_id: run.id,
      agent_id: coder.agent_id,
      generation: coder.generation
    }

    usage_caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             Process.link(coder.pid)
             send(receiver, {:agent_usage_caller_ready, self()})
             receive do: (:record_usage -> :ok)

             result = FleetRuntime.record_usage(owner, %{input_tokens: 5}, "coder.llm")
             send(receiver, {:agent_usage_result, result})
           end},
          id: :agent_owned_budget_usage_caller
        )
      )

    assert_receive {:agent_usage_caller_ready, ^usage_caller}, 2_000
    send(usage_caller, :record_usage)

    assert_receive {:agent_usage_result, {:error, :token_budget_exhausted}}, 2_000

    assert_receive {:DOWN, ^coder_ref, :process, _, _}, 2_000
    assert_receive {:DOWN, ^sibling_ref, :process, _, _}, 2_000
    assert Runs.get_run!(run.id).status == "failed"
    assert Enum.all?(Runs.list_run_agents(run.id), &(&1.status == "failed"))
  end

  test "control token gates new work until resume and cancels without invoking it" do
    token = FleetControlToken.new()
    :ok = FleetControlToken.pause(token)
    receiver = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           send(receiver, {:checkpoint_ready, self()})

           FleetRuntime.run(nil, token, "paused task", fn ->
             send(receiver, :work_invoked)
             {:ok, :done}
           end)
         end}
      )

    assert_receive {:checkpoint_ready, ^task}, 2_000
    refute_receive :work_invoked, 50
    :ok = FleetControlToken.resume(token)
    assert_receive :work_invoked, 2_000

    cancelled = FleetControlToken.new()
    :ok = FleetControlToken.cancel(cancelled)

    assert {:error, :cancelled} =
             FleetRuntime.run(nil, cancelled, "cancelled task", fn ->
               flunk("cancelled task must not execute")
             end)
  end

  test "operation manager checkpoints the fleet token before invoking an effect", ctx do
    token = FleetControlToken.new()
    :ok = FleetControlToken.pause(token)
    receiver = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           Process.put(:iex_code_fleet_owner, %{run_id: "isolated-run", agent_id: "agent"})
           Process.put(:iex_code_fleet_control_token, token)
           send(receiver, {:operation_owner_ready, self()})
           receive do: (:go -> :ok)

           OperationManager.run_sync_operation(
             ctx.session.id,
             nil,
             "FleetAgent",
             "checkpoint",
             "checkpoint operation",
             %{},
             fn _progress ->
               send(receiver, :operation_effect_invoked)
               {:ok, :done}
             end
           )
         end}
      )

    assert_receive {:operation_owner_ready, ^owner}, 2_000
    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), owner)
    send(owner, :go)
    refute_receive :operation_effect_invoked, 50
    :ok = FleetControlToken.resume(token)
    assert_receive :operation_effect_invoked, 2_000
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
  end

  defp running_run(ctx, suffix) do
    {:ok, _queued} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "fleet #{suffix}",
        kind: "coding_swarm",
        mode: "swarm",
        execution_engine: "legacy_v1"
      })

    owner = "fleet-test:#{suffix}:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp transition_parent(run, status, attrs \\ %{}) do
    Runs.transition_run_worker(run, status, attrs,
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    )
  end

  defp assert_all_down(refs, _timeout) when map_size(refs) == 0, do: :ok

  defp assert_all_down(refs, timeout) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(refs, ref) ->
        assert_all_down(Map.delete(refs, ref), timeout)
    after
      timeout -> flunk("fleet still had #{map_size(refs)} live monitored children")
    end
  end

  defp stubborn_agent_loop do
    receive do
      {:EXIT, _from, :shutdown} -> stubborn_agent_loop()
      _message -> stubborn_agent_loop()
    end
  end
end
