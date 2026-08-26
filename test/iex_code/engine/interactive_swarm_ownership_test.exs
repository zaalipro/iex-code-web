defmodule IexCode.Engine.InteractiveSwarmOwnershipTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Engine.{AgentRegistry, SessionServer, SwarmCoordinator}
  alias IexCode.Runs.{Run, RunDispatcher}
  alias IexCode.Tools.MultiPatch.Snapshot

  setup do
    root = Path.join(System.tmp_dir!(), "interactive-swarm-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Interactive swarm ownership",
        root_path: root
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Interactive swarm ownership",
        swarm_mode: true,
        status: "paused"
      })

    :ok = Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, session: session}
  end

  test "concurrent starts return one registered coordinator and ownership clears on exit",
       context do
    parent = self()

    callers =
      for index <- 1..2 do
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               send(parent, {:start_ready, index, self()})
               receive do: (:go -> :ok)

               result =
                 SwarmCoordinator.run_swarm(
                   context.session.id,
                   "Only one coordinator may own this session",
                   context.root
                 )

               send(parent, {:start_result, index, result})
             end},
            id: {:interactive_swarm_starter, index}
          )
        )
      end

    for {caller, index} <- Enum.with_index(callers, 1) do
      assert_receive {:start_ready, ^index, ^caller}, 2_000
    end

    Enum.each(callers, &send(&1, :go))

    assert_receive {:start_result, first_index, {:ok, first_owner}}, 2_000
    assert first_index in 1..2
    assert_receive {:start_result, second_index, {:ok, second_owner}}, 2_000
    assert second_index in 1..2
    refute second_index == first_index
    assert first_owner == second_owner
    assert AgentRegistry.swarm_owner(context.session.id) == first_owner

    assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000

    owner_ref = Process.monitor(first_owner)
    SwarmCoordinator.cancel(context.session.id)
    assert_receive {:DOWN, ^owner_ref, :process, ^first_owner, :normal}, 5_000
    assert AgentRegistry.swarm_owner(context.session.id) == nil

    {:ok, _paused} =
      context.session.id
      |> Sessions.get_session!()
      |> Sessions.update_session(%{status: "paused"})

    {:ok, restarted_owner} =
      SwarmCoordinator.run_swarm(
        context.session.id,
        "Ownership can be acquired after cleanup",
        context.root
      )

    refute restarted_owner == first_owner
    assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000
    restarted_ref = Process.monitor(restarted_owner)
    SwarmCoordinator.cancel(context.session.id)
    assert_receive {:DOWN, ^restarted_ref, :process, ^restarted_owner, :normal}, 5_000
  end

  test "a prompt while paused steers the existing task without spawning another", context do
    {:ok, owner} =
      SwarmCoordinator.run_swarm(
        context.session.id,
        "Paused coordinator",
        context.root
      )

    assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000
    {:ok, _server} = SessionServer.ensure_started(context.session.id)
    assert %{status: :paused, current_task: ^owner} = SessionServer.get_state(context.session.id)

    :ok = SessionServer.send_prompt(context.session.id, "Keep the same coordinator")
    assert %{status: :paused, current_task: ^owner} = SessionServer.get_state(context.session.id)

    assert_receive {:swarm_steered, %{steering: "Keep the same coordinator"}}, 2_000
    assert AgentRegistry.swarm_owner(context.session.id) == owner

    owner_ref = Process.monitor(owner)

    assert {:ok, %{status: :stopped}} =
             SessionServer.cancel_session(context.session.id, project_root: context.root)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000

    assert Enum.count(
             Sessions.list_messages(context.session.id),
             &String.contains?(&1.content, "Session Stopped")
           ) == 1
  end

  test "interactive steering logs size but never guidance content", context do
    secret = "interactive-secret-steer-#{Ecto.UUID.generate()}"
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        {:ok, owner} =
          SwarmCoordinator.run_swarm(
            context.session.id,
            "Capture steering log safety",
            context.root
          )

        assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000
        {:ok, _server} = SessionServer.ensure_started(context.session.id)
        assert {:ok, ^secret} = SessionServer.send_steering(context.session.id, secret)
        assert_receive {:swarm_steered, %{steering: ^secret}}, 2_000

        owner_ref = Process.monitor(owner)

        assert {:ok, %{status: :stopped}} =
                 SessionServer.cancel_session(context.session.id, project_root: context.root)

        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
      end)

    refute log =~ secret
    assert log =~ "bytes=#{byte_size(secret)}"
  end

  test "SessionServer restart adopts the registered coordinator", context do
    {:ok, owner} =
      SwarmCoordinator.run_swarm(context.session.id, "Survive server restart", context.root)

    assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000
    {:ok, server} = SessionServer.ensure_started(context.session.id)
    assert %{status: :paused, current_task: ^owner} = SessionServer.get_state(context.session.id)

    server_ref = Process.monitor(server)
    owner_ref = Process.monitor(owner)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :killed}, 2_000
    assert AgentRegistry.swarm_owner(context.session.id) == owner

    {:ok, replacement} = SessionServer.ensure_started(context.session.id)
    refute replacement == server
    assert %{status: :paused, current_task: ^owner} = SessionServer.get_state(context.session.id)

    assert {:ok, %{status: :stopped}} =
             SessionServer.cancel_session(context.session.id, project_root: context.root)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
  end

  test "SessionServer upgrades delayed durable metadata for the same owner PID", context do
    parent = self()
    run = claimed_run(context, "delayed durable metadata")
    {:ok, paused} = Runs.transition_run_worker(run, "paused", %{}, authority(run))
    run_id = paused.id
    identity = durable_identity(paused)

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             assert {:ok, _} = AgentRegistry.register_swarm_owner(context.session.id, %{})
             send(parent, {:metadata_owner_ready, self()})

             try do
               receive do
                 {:publish_metadata, metadata} ->
                   Registry.update_value(
                     AgentRegistry,
                     {:session_swarm, context.session.id},
                     fn _old -> metadata end
                   )

                   send(parent, {:metadata_published, self()})
               end

               receive do: (:stop -> :ok)
             after
               AgentRegistry.unregister_swarm_owner(context.session.id)
             end
           end},
          id: :delayed_durable_metadata_owner
        )
      )

    assert_receive {:metadata_owner_ready, ^owner}, 2_000
    {:ok, _server} = SessionServer.ensure_started(context.session.id)

    assert %{current_task: ^owner, run_mode: :swarm} =
             SessionServer.get_state(context.session.id)

    send(owner, {:publish_metadata, identity})
    assert_receive {:metadata_published, ^owner}, 2_000

    assert %{current_task: ^owner, run_mode: {:durable_swarm, ^run_id}} =
             SessionServer.get_state(context.session.id)
  end

  test "goal descriptions become prompts and startup failures keep the server usable", context do
    {:ok, _idle} =
      context.session.id
      |> Sessions.get_session!()
      |> Sessions.update_session(%{status: "idle"})

    {:ok, goal} =
      SessionServer.create_goal(
        context.session.id,
        %{title: "Mapped title", description: "Description used as execution prompt"},
        auto_start: false
      )

    assert goal.prompt == "Description used as execution prompt"
    messages_before_failed_start = Sessions.list_messages(context.session.id)

    assert {:error, {:swarm_start_failed, _reason}} =
             SessionServer.create_goal(
               context.session.id,
               %{title: "Cannot start", description: "Must return an error"},
               task_supervisor: IexCode.MissingTaskSupervisor
             )

    assert Sessions.list_messages(context.session.id) == messages_before_failed_start
    refute_receive {:goal_created, %{title: "Cannot start"}}, 100

    assert %{status: :idle, active_goal: %{status: :failed}} =
             SessionServer.get_state(context.session.id)
  end

  test "create_goal persists nothing when a durable owner wins its acquisition race", context do
    {:ok, _idle} =
      context.session.id
      |> Sessions.get_session!()
      |> Sessions.update_session(%{status: "idle"})

    {:ok, server} = SessionServer.ensure_started(context.session.id)
    parent = self()
    resource = {SwarmCoordinator, :session_swarm, context.session.id}
    run_id = Ecto.UUID.generate()

    lock_holder =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             lock = {resource, self()}
             true = :global.set_lock(lock)
             send(parent, {:ownership_lock_held, self()})

             try do
               receive do: (:register_durable_owner -> :ok)

               assert {:ok, _} =
                        AgentRegistry.register_swarm_owner(
                          context.session.id,
                          durable_identity(run_id, 1, 1, "dispatcher:race-winner")
                        )

               send(parent, {:race_owner_registered, self()})
               receive do: (:release_ownership_lock -> :ok)
               :global.del_lock(lock)
               receive do: (:stop_race_owner -> :ok)
             after
               :global.del_lock(lock)
               AgentRegistry.unregister_swarm_owner(context.session.id)
             end
           end},
          id: :ownership_race_lock_holder
        )
      )

    assert_receive {:ownership_lock_held, ^lock_holder}, 2_000

    caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:goal_call_started, self()})

             result =
               SessionServer.create_goal(
                 context.session.id,
                 %{title: "Losing goal", description: "Must never become observable"},
                 project_root: context.root
               )

             send(parent, {:goal_race_result, result})
           end},
          id: :ownership_race_goal_caller
        )
      )

    assert_receive {:goal_call_started, ^caller}, 2_000
    refute_receive {:goal_race_result, _result}, 100
    assert Sessions.list_messages(context.session.id) == []

    send(lock_holder, :register_durable_owner)
    assert_receive {:race_owner_registered, ^lock_holder}, 2_000
    send(lock_holder, :release_ownership_lock)

    assert_receive {:goal_race_result,
                    {:error, {:swarm_start_failed, {:session_swarm_owned, ^run_id}}}},
                   2_000

    assert Sessions.list_messages(context.session.id) == []
    refute_receive {:goal_created, %{title: "Losing goal"}}, 100
    assert AgentRegistry.swarm_owner(context.session.id) == lock_holder
    assert Process.alive?(server)
  end

  test "durable ownership publishes complete lineage and is released on exit", context do
    run = claimed_run(context, "durable owner identity")
    {:ok, paused} = Runs.transition_run_worker(run, "paused", %{}, authority(run))
    parent = self()

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:durable_owner_ready, self()})
             receive do: (:run -> :ok)

             SwarmCoordinator.run(paused.session_id, paused.objective,
               project_root: context.root,
               run_id: paused.id,
               run_lease_owner: paused.lease_owner,
               run_attempt: paused.attempt,
               run_lease_generation: paused.lease_generation,
               run_lease_ms: 30_000
             )
           end},
          id: :durable_swarm_owner
        )
      )

    assert_receive {:durable_owner_ready, ^owner}, 2_000
    send(owner, :run)

    assert {:ok, ^owner, metadata} = await_swarm_owner(context.session.id)
    assert metadata.run_id == paused.id
    assert metadata.run_attempt == paused.attempt
    assert metadata.lease_generation == paused.lease_generation
    assert metadata.lease_owner == paused.lease_owner

    owner_ref = Process.monitor(owner)
    send(owner, {:run_control, paused.id, :cancel, %{}})
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 2_000
    assert :none = await_no_swarm_owner(context.session.id)
  end

  test "a retry lineage cannot reuse its prior coordinator and blocks interactive starts",
       context do
    run_id = Ecto.UUID.generate()
    old_identity = durable_identity(run_id, 1, 1, "dispatcher:old")
    old_owner = start_owner(context.session.id, old_identity)

    assert {:error, {:session_swarm_owned, ^run_id}} =
             SwarmCoordinator.run_swarm(
               context.session.id,
               "Interactive work must not bypass a durable owner",
               context.root
             )

    assert {:error, :session_swarm_owned} =
             SwarmCoordinator.run(
               context.session.id,
               "A synchronous interactive run is blocked too",
               project_root: context.root
             )

    assert {:error, :session_swarm_owned} =
             SwarmCoordinator.run(
               context.session.id,
               "Retry attempt two",
               project_root: context.root,
               run_id: run_id,
               run_lease_owner: "dispatcher:new",
               run_attempt: 2,
               run_lease_generation: 2,
               run_lease_ms: 30_000
             )

    assert {:ok, ^old_owner, ^old_identity} =
             AgentRegistry.swarm_owner_registration(context.session.id)
  end

  test "a coordinator aborts and unregisters when its durable generation is fenced", context do
    run = claimed_run(context, "fence stale coordinator")
    {:ok, paused} = Runs.transition_run_worker(run, "paused", %{}, authority(run))
    parent = self()

    coordinator =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               SwarmCoordinator.run(paused.session_id, paused.objective,
                 project_root: context.root,
                 run_id: paused.id,
                 run_lease_owner: paused.lease_owner,
                 run_attempt: paused.attempt,
                 run_lease_generation: paused.lease_generation,
                 run_lease_ms: 30_000
               )

             send(parent, {:fenced_coordinator_result, result})
           end},
          id: :fenced_durable_swarm
        )
      )

    assert {:ok, ^coordinator, _metadata} = await_swarm_owner(context.session.id)
    assert_receive {:swarm_stage_changed, %{stage: :init}}, 2_000

    Repo.update_all(from(candidate in Run, where: candidate.id == ^paused.id),
      inc: [lease_generation: 1],
      set: [status: "running"]
    )

    assert_receive {:fenced_coordinator_result,
                    {:error, {:durable_run_fenced, :lease_not_owned}}},
                   2_000

    assert :none = await_no_swarm_owner(context.session.id)
    refute_receive {:swarm_stage_changed, %{stage: :planning}}, 100
  end

  test "an expired exact durable identity is fenced before fleet attachment", context do
    run = claimed_run(context, "expired owner preflight")
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(candidate in Run, where: candidate.id == ^run.id),
      set: [lease_expires_at: expired_at]
    )

    assert {:error, {:durable_run_fenced, :lease_expired}} =
             SwarmCoordinator.run(run.session_id, run.objective,
               project_root: context.root,
               run_id: run.id,
               run_lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               run_lease_generation: run.lease_generation,
               run_lease_ms: 30_000
             )

    assert AgentRegistry.whereis_fleet(run.id, :supervisor) == nil
    assert AgentRegistry.list_run_agents(run.id) == []
    assert :none = AgentRegistry.swarm_owner_registration(run.session_id)
    refute_receive {:swarm_stage_changed, _stage}, 100
  end

  test "a paused stale coordinator cannot consume a replacement generation control", context do
    run = claimed_run(context, "paused stale control fence")
    on_exit(fn -> IexCode.Engine.FleetSupervisor.stop(run.id) end)
    {:ok, paused} = Runs.transition_run_worker(run, "paused", %{}, authority(run))
    parent = self()
    barrier_ref = make_ref()

    coordinator =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               SwarmCoordinator.run(paused.session_id, paused.objective,
                 project_root: context.root,
                 run_id: paused.id,
                 run_lease_owner: paused.lease_owner,
                 run_attempt: paused.attempt,
                 run_lease_generation: paused.lease_generation,
                 run_lease_ms: 30_000,
                 control_barrier: {parent, barrier_ref}
               )

             send(parent, {:stale_control_result, result})
           end},
          id: :paused_stale_control_coordinator
        )
      )

    assert {:ok, ^coordinator, _metadata} = await_swarm_owner(context.session.id)
    assert_receive {:swarm_stage_changed, %{stage: :init}}, 2_000
    assert_receive {:swarm_control_barrier, ^coordinator, ^barrier_ref}, 2_000

    replacement_owner = "dispatcher:replacement"

    Repo.update_all(from(candidate in Run, where: candidate.id == ^paused.id),
      inc: [lease_generation: 1],
      set: [status: "paused", lease_owner: replacement_owner]
    )

    replacement = Runs.get_run!(paused.id)

    assert {:ok, pending} =
             Runs.enqueue_control(replacement, "replacement-resume", %{
               kind: "resume",
               payload: %{},
               requested_by: "test"
             })

    assert {:ok, claimed} = Runs.claim_control(pending, replacement_owner)
    send(coordinator, {:run_control, replacement.id, claimed.id, :resume, %{}})
    send(coordinator, {:release_swarm_control_barrier, barrier_ref})

    assert_receive {:stale_control_result, {:error, {:durable_run_fenced, :lease_not_owned}}},
                   2_000

    assert Runs.get_control(claimed.id).status == "claimed"
    assert :none = await_no_swarm_owner(context.session.id)
  end

  test "a stale terminal notification cannot stop or roll back a replacement lineage", context do
    run = claimed_run(context, "stale terminal cleanup fence")
    on_exit(fn -> IexCode.Engine.FleetSupervisor.stop(run.id) end)
    {:ok, paused} = Runs.transition_run_worker(run, "paused", %{}, authority(run))
    parent = self()
    barrier_ref = make_ref()

    # Persist the replacement lineage's snapshot before starting the stale
    # coordinator. The explicit control barrier below pauses only after init
    # persistence returns, so no process can be frozen while holding the shared
    # SQL Sandbox connection.
    path = Path.join(context.root, "replacement.txt")
    File.write!(path, "replacement")
    transaction_id = "replacement-#{System.unique_integer([:positive])}"

    assert :ok =
             Snapshot.save_snapshot(
               transaction_id,
               [
                 %{
                   path: "replacement.txt",
                   full_path: path,
                   file_existed?: true,
                   original_content: "prior",
                   new_content: "replacement"
                 }
               ],
               project_root: context.root,
               session_id: context.session.id,
               run_id: paused.id
             )

    coordinator =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               SwarmCoordinator.run(paused.session_id, paused.objective,
                 project_root: context.root,
                 run_id: paused.id,
                 run_lease_owner: paused.lease_owner,
                 run_attempt: paused.attempt,
                 run_lease_generation: paused.lease_generation,
                 run_lease_ms: 30_000,
                 control_barrier: {parent, barrier_ref}
               )

             send(parent, {:stale_terminal_result, result})
           end},
          id: :stale_terminal_coordinator
        )
      )

    assert {:ok, ^coordinator, _metadata} = await_swarm_owner(context.session.id)
    assert_receive {:swarm_stage_changed, %{stage: :init}}, 2_000
    assert_receive {:swarm_control_barrier, ^coordinator, ^barrier_ref}, 2_000

    Repo.update_all(from(candidate in Run, where: candidate.id == ^paused.id),
      inc: [lease_generation: 1],
      set: [status: "paused", lease_owner: "dispatcher:replacement"]
    )

    replacement = Runs.get_run!(paused.id)

    assert {:ok, _failed} =
             Runs.finalize_run_worker(replacement, "failed", %{},
               lease_owner: replacement.lease_owner,
               run_attempt: replacement.attempt,
               lease_generation: replacement.lease_generation,
               preserve_lease: true,
               terminal_lease_ms: 30_000
             )

    send(coordinator, {:run_control, paused.id, :cancel, %{}})
    send(coordinator, {:release_swarm_control_barrier, barrier_ref})

    assert_receive {:stale_terminal_result, {:error, {:durable_run_fenced, :lease_not_owned}}},
                   2_000

    assert File.read!(path) == "replacement"
    assert {:ok, _snapshot} = Snapshot.get_snapshot(transaction_id)
    Snapshot.delete_snapshot(transaction_id)
  end

  test "missing owner metadata fails closed and remote dispatcher routing is bounded", context do
    parent = self()

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             assert {:ok, _} = AgentRegistry.register_swarm_owner(context.session.id, %{})
             Registry.unregister(AgentRegistry, {:session_swarm, context.session.id})
             send(parent, {:metadata_removed, self()})

             try do
               receive do: (:stop -> :ok)
             after
               AgentRegistry.unregister_swarm_owner(context.session.id)
             end
           end},
          id: :metadata_unavailable_owner
        )
      )

    assert_receive {:metadata_removed, ^owner}, 2_000

    assert {:error, {:swarm_owner_metadata_unavailable, ^owner, :metadata_not_registered}} =
             AgentRegistry.swarm_owner_registration(context.session.id)

    assert AgentRegistry.swarm_owner(context.session.id) == owner
    {:ok, _server} = SessionServer.ensure_started(context.session.id)

    assert %{current_task: ^owner, run_mode: {:swarm_owner_metadata_unavailable, _reason}} =
             SessionServer.get_state(context.session.id)

    session_status = Sessions.get_session!(context.session.id).status

    assert {:error, :swarm_owner_metadata_unavailable} =
             SessionServer.pause_session(context.session.id)

    assert Sessions.get_session!(context.session.id).status == session_status

    remote_node = :controller@simulation

    rpc = fn called_node, module, operation, args, timeout ->
      send(parent, {:remote_dispatch, called_node, module, operation, args, timeout})
      {:ok, :remote_result}
    end

    assert {:ok, :remote_result} =
             SessionServer.dispatch_run_control(remote_node, :pause, ["run-id"], rpc: rpc)

    assert_receive {:remote_dispatch, ^remote_node, RunDispatcher, :pause, ["run-id"], 5_000}
    send(owner, :stop)
  end

  test "durable session controls discover a late owner and use RunDispatcher", context do
    {:ok, _idle} =
      context.session.id
      |> Sessions.get_session!()
      |> Sessions.update_session(%{status: "idle"})

    {:ok, server} = SessionServer.ensure_started(context.session.id)
    assert %{run_mode: nil} = SessionServer.get_state(context.session.id)

    Process.register(self(), IexCode.RunDispatcherTestReceiver)

    on_exit(fn ->
      if Process.whereis(IexCode.RunDispatcherTestReceiver),
        do: Process.unregister(IexCode.RunDispatcherTestReceiver)
    end)

    start_supervised!(
      {RunDispatcher,
       name: RunDispatcher,
       executor: IexCode.RunDispatcherTestExecutor,
       max_concurrency: 1,
       poll_interval: 60_000,
       heartbeat_interval: 60_000,
       lease_ms: 120_000}
    )

    assert {:ok, queued} =
             RunDispatcher.enqueue(%{
               project_id: context.session.project_id,
               session_id: context.session.id,
               objective: "route durable controls",
               kind: "coding_swarm",
               mode: "swarm",
               execution_engine: "legacy_v1"
             })

    assert_receive {:test_run_started, run_id, _worker}, 2_000
    assert run_id == queued.id
    running = Runs.get_run!(queued.id)
    owner = start_owner(context.session.id, durable_identity(running))
    assert Process.alive?(server)

    assert {:ok, :paused} = SessionServer.pause_session(context.session.id)
    assert_receive {:test_run_paused, ^run_id}, 2_000
    assert Runs.get_run!(run_id).status == "paused"
    refute_receive {:pause, _session_id}, 100

    assert {:ok, :running} = SessionServer.resume_session(context.session.id)
    assert_receive {:test_run_resumed, ^run_id}, 2_000
    assert Runs.get_run!(run_id).status == "running"
    refute_receive {:resume, _session_id}, 100

    guidance = "Durable steering is persisted only by its execution coordinator"
    assert {:ok, ^guidance} = SessionServer.send_steering(context.session.id, guidance)
    assert_receive {:test_run_steered, ^run_id, ^guidance}, 2_000

    # This executor acknowledges the durable control but intentionally does not
    # journal a steering message. SessionServer must not create a second,
    # non-idempotent message or announce application before the real coordinator.
    assert Sessions.list_messages(context.session.id) == []
    refute_receive {:swarm_steered, %{steering: ^guidance}}, 100

    assert {:error, :durable_cancel_action_unsupported} =
             SessionServer.cancel_session(context.session.id, action: :commit)

    assert Runs.get_run!(run_id).status == "running"
    refute_receive {:test_run_cancelled, ^run_id}, 100

    assert {:ok, %{status: :stopped, action: :rollback}} =
             SessionServer.cancel_session(context.session.id)

    assert Runs.get_run!(run_id).status == "cancelled"
    refute_receive {:cancel, _session_id, _opts}, 100
    assert AgentRegistry.swarm_owner(context.session.id) == owner
  end

  defp claimed_run(context, objective) do
    assert {:ok, _queued} =
             Runs.create_run(%{
               project_id: context.session.project_id,
               session_id: context.session.id,
               objective: objective,
               kind: "coding_swarm",
               mode: "swarm",
               execution_engine: "legacy_v1"
             })

    assert {:ok, claimed} = Runs.claim_next_run("dispatcher:identity", lease_ms: 30_000)
    claimed
  end

  defp authority(run) do
    [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    ]
  end

  defp durable_identity(run) do
    durable_identity(run.id, run.attempt, run.lease_generation, run.lease_owner)
  end

  defp durable_identity(run_id, attempt, generation, owner) do
    %{
      run_id: run_id,
      run_attempt: attempt,
      lease_generation: generation,
      lease_owner: owner,
      ownership_token: nil
    }
  end

  defp start_owner(session_id, identity) do
    parent = self()

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             assert {:ok, _} = AgentRegistry.register_swarm_owner(session_id, identity)
             send(parent, {:owner_registered, self()})

             try do
               receive do: (:stop -> :ok)
             after
               AgentRegistry.unregister_swarm_owner(session_id)
             end
           end},
          id: {:durable_owner, System.unique_integer([:positive])}
        )
      )

    assert_receive {:owner_registered, ^owner}, 2_000
    owner
  end

  defp await_swarm_owner(session_id, attempts \\ 100)

  defp await_swarm_owner(_session_id, 0), do: flunk("swarm owner was not registered")

  defp await_swarm_owner(session_id, attempts) do
    case AgentRegistry.swarm_owner_registration(session_id) do
      {:ok, _owner, _metadata} = registration ->
        registration

      :none ->
        receive do
        after
          10 -> await_swarm_owner(session_id, attempts - 1)
        end
    end
  end

  defp await_no_swarm_owner(session_id, attempts \\ 100)

  defp await_no_swarm_owner(_session_id, 0), do: flunk("swarm owner was not released")

  defp await_no_swarm_owner(session_id, attempts) do
    case AgentRegistry.swarm_owner_registration(session_id) do
      :none ->
        :none

      {:ok, _owner, _metadata} ->
        receive do
        after
          10 -> await_no_swarm_owner(session_id, attempts - 1)
        end
    end
  end
end
