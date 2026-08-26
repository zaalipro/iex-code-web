defmodule IexCode.SwarmTest do
  use IexCode.E2E.Case, async: false
  alias IexCode.Sessions
  alias IexCode.Engine.{SwarmOrchestrator, SessionServer}

  @tag :tmp_dir
  @tag :mock_llm
  test "runs multi-agent swarm workflow and generates hierarchical operation tree", %{
    tmp_dir: tmp_dir
  } do
    # Create sample project and session
    File.write!(
      Path.join(tmp_dir, "lib_sample.ex"),
      "defmodule LibSample do\n  def run, do: :ok\nend"
    )

    project = create_project_fixture(%{name: "Tmp Project", root_path: tmp_dir})
    session = create_session_fixture(project, %{title: "Swarm Test", swarm_mode: true})

    # Subscribe to session PubSub
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    # Run Swarm Orchestrator
    {:ok, pid} = SwarmOrchestrator.run_swarm(session.id, "Analyze project structure", tmp_dir)
    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

    # Wait for the completion message
    assert_receive {:session_status_changed, "idle"}, 20_000

    # Verify operations were recorded in database
    operations = Sessions.list_operations(session.id)
    assert length(operations) >= 4

    # Verify each agent type registered operations with progress
    agent_names = Enum.map(operations, & &1.agent_name) |> Enum.uniq()
    assert "SwarmOrchestrator" in agent_names
    assert "PlannerAgent" in agent_names
    assert "ExplorerAgent" in agent_names
    assert "CoderAgent" in agent_names
    assert "VerifierAgent" in agent_names

    # Verify final assistant message was created
    messages = Sessions.list_messages(session.id)

    assert Enum.any?(messages, fn m ->
             m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
           end)
  end

  test "SessionServer handles prompt and toggles swarm mode" do
    project = create_project_fixture(%{name: "Server Project", root_path: "/tmp"})
    session = create_session_fixture(project, %{title: "Server Session", swarm_mode: false})

    assert {:ok, _pid} = SessionServer.ensure_started(session.id)

    # Toggle swarm
    assert {:ok, true} = SessionServer.toggle_swarm(session.id)
    state = SessionServer.get_state(session.id)
    assert state.session.swarm_mode == true

    # Clear operations
    assert :ok = SessionServer.clear_operations(session.id)
  end
end
