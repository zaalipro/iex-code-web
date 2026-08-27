defmodule IexCode.Engine.SessionServerPassivationTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{AgentRegistry, SessionServer}

  setup do
    root = Path.join(System.tmp_dir!(), "session-passivation-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create_project(%{name: "Passivation", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Passivation"})

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, session: session}
  end

  test "an idle server passivates and rehydrates on the next API call", %{session: session} do
    {:ok, pid} = SessionServer.ensure_started(session.id)
    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)

    send(pid, {:session_idle_timeout, state.idle_timer})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert %{session_id: session_id, status: :idle} = SessionServer.get_state(session.id)
    assert session_id == session.id
  end

  test "draft goal checkpoint survives passivation without retaining its server", %{
    session: session,
    root: root
  } do
    assert {:ok, goal} =
             SessionServer.create_goal(
               session.id,
               %{title: "Durable draft", prompt: "Keep every acceptance criterion"},
               project_root: root,
               auto_start: false
             )

    {:ok, pid} = SessionServer.ensure_started(session.id)
    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)
    send(pid, {:session_idle_timeout, state.idle_timer})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    restored = SessionServer.get_state(session.id).active_goal
    assert restored.id == goal.id
    assert restored.title == "Durable draft"
    assert restored.prompt == "Keep every acceptance criterion"
    assert restored.status == :idle
  end

  test "paused owner survives server passivation and is adopted after rehydration", %{
    session: session
  } do
    parent = self()
    assert {:ok, _paused_session} = Sessions.update_session(session, %{status: "paused"})

    assert {:ok, _goal_checkpoint} =
             Sessions.create_message(%{
               session_id: session.id,
               role: "user",
               agent_name: "User (Goal)",
               content: "🎯 **Goal**: Running goal\n\nPreserve live owner state",
               metadata: %{
                 "goal_id" => Ecto.UUID.generate(),
                 "goal_title" => "Running goal",
                 "goal_status" => "running"
               }
             })

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             assert {:ok, _pid} = AgentRegistry.register_swarm_owner(session.id, %{})
             send(parent, {:owner_ready, self()})

             receive do
               :stop -> :ok
             end
           end},
          restart: :temporary
        )
      )

    assert_receive {:owner_ready, ^owner}
    {:ok, pid} = SessionServer.ensure_started(session.id)

    assert %{current_task: ^owner, active_goal: %{status: :paused}} =
             SessionServer.get_state(session.id)

    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)
    send(pid, {:session_idle_timeout, state.idle_timer})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert Process.alive?(owner)
    {:ok, replacement} = SessionServer.ensure_started(session.id)
    assert replacement != pid

    assert %{current_task: ^owner, status: :paused, active_goal: restored_goal} =
             SessionServer.get_state(session.id)

    assert restored_goal.title == "Running goal"
    assert restored_goal.prompt == "Preserve live owner state"
    assert restored_goal.status == :paused

    send(owner, :stop)
  end

  test "normally completed auto-start goal derives completion across passivation", %{
    session: session
  } do
    goal_id = Ecto.UUID.generate()

    assert {:ok, _idle_session} = Sessions.update_session(session, %{status: "idle"})

    assert {:ok, _goal_checkpoint} =
             Sessions.create_message(%{
               session_id: session.id,
               role: "user",
               agent_name: "User (Goal)",
               content: "🎯 **Goal**: Completed goal\n\nKeep the terminal checkpoint",
               metadata: %{
                 "goal_id" => goal_id,
                 "goal_title" => "Completed goal",
                 # Auto-start checkpoints remain `running`; a normal swarm exit
                 # returns the session to idle and supplies the terminal signal.
                 "goal_status" => "running"
               }
             })

    {:ok, pid} = SessionServer.ensure_started(session.id)

    assert %{active_goal: %{id: ^goal_id, status: :completed}} =
             SessionServer.get_state(session.id)

    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)
    send(pid, {:session_idle_timeout, state.idle_timer})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert %{active_goal: %{id: ^goal_id, status: :completed}} =
             SessionServer.get_state(session.id)
  end

  test "orphaned running checkpoint rehydrates as failed rather than completed", %{
    session: session
  } do
    goal_id = Ecto.UUID.generate()
    assert {:ok, _running_session} = Sessions.update_session(session, %{status: "running"})

    assert {:ok, _goal_checkpoint} =
             Sessions.create_message(%{
               session_id: session.id,
               role: "user",
               agent_name: "User (Goal)",
               content: "🎯 **Goal**: Interrupted goal\n\nDo not report phantom success",
               metadata: %{
                 "goal_id" => goal_id,
                 "goal_title" => "Interrupted goal",
                 "goal_status" => "running"
               }
             })

    assert %{status: :idle, active_goal: %{id: ^goal_id, status: :failed}} =
             SessionServer.get_state(session.id)
  end
end
