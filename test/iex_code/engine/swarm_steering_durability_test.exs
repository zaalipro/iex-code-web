defmodule IexCode.Engine.SwarmSteeringDurabilityTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.SwarmCoordinator
  alias IexCode.Engine.SwarmCoordinator.State
  alias IexCode.{Projects, Runs, Sessions}

  setup do
    root = Path.join(System.tmp_dir!(), "swarm-steering-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)

    {:ok, project} = Projects.create_project(%{name: "Swarm steering", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Steering"})

    {:ok, _queued} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Durable steering objective",
        kind: "coding_swarm",
        mode: "swarm"
      })

    owner = "swarm-steering:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    :ok = Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    on_exit(fn -> File.rm_rf(root) end)

    %{run: run, session: session, root: root}
  end

  test "applies the persisted payload before acknowledgement and is idempotent", context do
    state = coordinator_state(context)
    claimed = claimed_steering(context.run, "Persisted guidance")

    updated =
      SwarmCoordinator.reconcile_durable_steering(
        state,
        claimed.id,
        "durable control test"
      )

    assert updated.steer_directives == ["Persisted guidance"]
    assert updated.user_prompt =~ "[Real-time User Guidance]: Persisted guidance"
    assert %{status: "applied"} = Runs.get_control(claimed.id)

    assert [message] = steering_messages(context.session.id, claimed.id)
    assert message.content == "Steering guidance: Persisted guidance"

    assert_receive {:swarm_steered, %{steering: "Persisted guidance"}}

    assert updated ==
             SwarmCoordinator.reconcile_durable_steering(
               updated,
               claimed.id,
               "duplicate durable delivery"
             )

    refute_receive {:swarm_steered, %{steering: "Persisted guidance"}}, 100
    assert [_same_message] = steering_messages(context.session.id, claimed.id)
  end

  test "rehydrates applied steering after coordinator state is lost", context do
    state = coordinator_state(context)
    claimed = claimed_steering(context.run, "Survive coordinator crash")

    _discarded_runtime_state =
      SwarmCoordinator.reconcile_durable_steering(state, claimed.id, "before simulated crash")

    assert %{status: "applied"} = Runs.get_control(claimed.id)

    restored = SwarmCoordinator.restore_durable_steering(coordinator_state(context))
    assert restored.steer_directives == ["Survive coordinator crash"]
    assert restored.user_prompt =~ "[Real-time User Guidance]: Survive coordinator crash"
  end

  test "a crash after durable persistence replays the claimed control exactly once", context do
    state = coordinator_state(context)
    claimed = claimed_steering(context.run, "Replay claimed guidance")

    attrs = %{
      session_id: context.session.id,
      role: "user",
      agent_name: "User (Steer)",
      content: "Steering guidance: Replay claimed guidance",
      metadata: %{
        "run_id" => context.run.id,
        "control_id" => claimed.id,
        "intent" => "steer"
      }
    }

    assert {:ok, first_message, :created} =
             Sessions.create_message_once(attrs, "swarm-steer:#{claimed.id}")

    # Simulate a coordinator dying after the durable write but before applying
    # state or resolving the claimed control.
    assert Runs.get_control(claimed.id).status == "claimed"

    replayed =
      SwarmCoordinator.reconcile_durable_steering(
        state,
        claimed.id,
        "replayed after crash"
      )

    assert replayed.steer_directives == ["Replay claimed guidance"]
    assert Runs.get_control(claimed.id).status == "applied"
    assert [%{id: message_id}] = steering_messages(context.session.id, claimed.id)
    assert message_id == first_message.id
  end

  test "paused durable controls use the same ingest-before-acknowledge boundary", context do
    authority = authority(context.run)
    {:ok, paused} = Runs.transition_run_worker(context.run, "paused", %{}, authority)
    claimed = claimed_steering(paused, "Guidance while paused")

    restored =
      context
      |> Map.put(:run, paused)
      |> coordinator_state()
      |> SwarmCoordinator.reconcile_durable_steering(claimed.id, "paused durable control")

    assert restored.status == :paused
    assert restored.steer_directives == ["Guidance while paused"]
    assert %{status: "applied"} = Runs.get_control(claimed.id)
  end

  test "durable steering logs identifiers and size without guidance content", context do
    state = coordinator_state(context)
    secret = "secret-steer-#{Ecto.UUID.generate()}"
    claimed = claimed_steering(context.run, secret)
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        updated =
          SwarmCoordinator.reconcile_durable_steering(
            state,
            claimed.id,
            "durable capture-log test"
          )

        assert updated.steer_directives == [secret]
      end)

    refute log =~ secret
    assert log =~ "run=#{context.run.id}"
    assert log =~ "bytes=#{byte_size(secret)}"
  end

  defp coordinator_state(%{run: run, session: session, root: root}) do
    %State{
      session_id: session.id,
      run_id: run.id,
      session: session,
      project_root: root,
      user_prompt: run.objective,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_lease_ms: 30_000,
      stage: :planning,
      status: if(run.status == "paused", do: :paused, else: :running)
    }
  end

  defp claimed_steering(run, guidance) do
    key = "steering-test:#{System.unique_integer([:positive])}"

    {:ok, pending} =
      Runs.enqueue_control(run, key, %{
        kind: "steer",
        payload: %{"guidance" => guidance},
        requested_by: "test"
      })

    {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)
    claimed
  end

  defp authority(run) do
    [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    ]
  end

  defp steering_messages(session_id, control_id) do
    session_id
    |> Sessions.list_messages()
    |> Enum.filter(fn message ->
      message.metadata && message.metadata["control_id"] == control_id
    end)
  end
end
