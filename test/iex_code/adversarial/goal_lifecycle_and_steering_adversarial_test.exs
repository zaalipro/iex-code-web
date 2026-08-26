defmodule IexCode.Adversarial.GoalLifecycleAndSteeringAdversarialTest do
  @moduledoc """
  Adversarial Stress Test Suite for Goal Lifecycle & Real-Time Steering Engine.
  Tests high-concurrency steering flooding, queued steering during pause,
  rapid pause/resume fuzzing, worker kill/process murder during cancellation,
  concurrent cancellation contention, and state machine corner cases.
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SessionServer, SwarmCoordinator, AgentSupervisor, AgentRegistry}
  alias IexCode.Tools.MultiPatch

  setup do
    test_root = Path.join(System.tmp_dir!(), "adv_goal_#{Ecto.UUID.generate()}")
    File.mkdir_p!(test_root)

    {:ok, project} =
      Projects.create_project(%{name: "Adversarial Goal Project", root_path: test_root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Adversarial Goal Session",
        swarm_mode: true,
        status: "idle"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}:steer")

    on_exit(fn ->
      AgentSupervisor.stop_all_agents(session.id)
      File.rm_rf(test_root)
    end)

    %{session: session, project: project, test_root: test_root}
  end

  describe "1. Real-Time Steering Under High Concurrency & Flooding" do
    test "ingests 30 concurrent steering directives into active swarm without message loss", %{
      session: session,
      test_root: test_root
    } do
      File.write!(
        Path.join(test_root, "app_worker.ex"),
        "defmodule AppWorker do\n  def work, do: :done\nend"
      )

      # Start active swarm
      {:ok, _task_pid} =
        SwarmCoordinator.run_swarm(
          session.id,
          "Coordinate high concurrency steering test",
          test_root
        )

      assert_receive {:session_status_changed, "running"}, 5000

      # Spawn 30 concurrent tasks firing steering directives simultaneously
      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            directive = "Steering Directive #{i}: Ensure robust error handling"
            SessionServer.send_steering(session.id, directive)
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 30

      for res <- results do
        assert {:ok, _text} = res
      end

      # Await swarm completion
      assert_receive {:session_status_changed, "idle"}, 30_000

      # Verify final message has preserved steering context
      messages = Sessions.list_messages(session.id)

      final_msg =
        Enum.find(messages, fn m ->
          m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
        end)

      assert final_msg != nil
      assert final_msg.metadata["steering_count"] >= 1
      assert String.contains?(final_msg.content, "User Steering Applied")
    end
  end

  describe "2. Steering Under Paused State & Multi-Queue Ingestion" do
    test "ingests and queues 10 distinct steering directives while paused, applying all on resume",
         %{
           session: session,
           test_root: test_root
         } do
      File.write!(
        Path.join(test_root, "paused_worker.ex"),
        "defmodule PausedWorker do\n  def compute, do: 42\nend"
      )

      {:ok, _goal} =
        SessionServer.create_goal(session.id, "Goal to pause and multi-steer",
          project_root: test_root,
          auto_start: true
        )

      assert_receive {:session_status_changed, "running"}, 5000

      # Pause the session
      assert {:ok, :paused} = SessionServer.pause_session(session.id)
      assert_receive {:session_status_changed, "paused"}, 5000

      # Queue 10 steering messages while paused
      for i <- 1..10 do
        directive = "Queued Directive #{i}: Add spec #{i}"
        {:ok, ^directive} = SessionServer.send_steering(session.id, directive)
        assert_receive {:swarm_steered, %{steering: ^directive}}, 5000
      end

      # Verify state remains paused
      state_paused = SessionServer.get_state(session.id)
      assert state_paused.status == :paused

      # Resume the session
      assert {:ok, :running} = SessionServer.resume_session(session.id)
      assert_receive {:session_status_changed, "running"}, 5000

      # Await completion
      assert_receive {:session_status_changed, "idle"}, 30_000

      messages = Sessions.list_messages(session.id)

      final_msg =
        Enum.find(messages, fn m ->
          m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
        end)

      assert final_msg != nil
      # All 10 directives should be registered
      assert final_msg.metadata["steering_count"] == 10

      for i <- 1..10 do
        assert String.contains?(final_msg.content, "Queued Directive #{i}")
      end
    end
  end

  describe "3. Rapid Pause / Resume Fuzzing & High-Frequency Cycling" do
    test "survives 20 rapid pause/resume cycles without deadlock or corrupted state", %{
      session: session,
      test_root: test_root
    } do
      File.write!(
        Path.join(test_root, "fuzz_worker.ex"),
        "defmodule FuzzWorker do\n  def process, do: :ok\nend"
      )

      {:ok, _pid} =
        SwarmCoordinator.run_swarm(session.id, "Goal for rapid pause/resume fuzzing", test_root)

      assert_receive {:session_status_changed, "running"}, 5000

      # Perform 20 rapid toggle cycles
      for _cycle <- 1..20 do
        SessionServer.pause_session(session.id)
        :timer.sleep(:rand.uniform(5))
        SessionServer.resume_session(session.id)
        :timer.sleep(:rand.uniform(5))
      end

      # Ensure session finishes cleanly
      assert_receive {:session_status_changed, "idle"}, 30_000

      final_state = SessionServer.get_state(session.id)
      assert final_state.status in [:idle, :completed]
    end
  end

  describe "4. Worker Crash & Process Murder During Cancellation" do
    test "safely cancels session and performs rollback when task process is killed externally", %{
      session: session,
      test_root: test_root
    } do
      sample_file = Path.join(test_root, "murder_target.ex")
      File.write!(sample_file, "defmodule MurderTarget do\n  def value, do: 1\nend")

      # Create subagents
      {:ok, _} = AgentSupervisor.start_agent(session.id, :planner, project_root: test_root)
      {:ok, _} = AgentSupervisor.start_agent(session.id, :coder, project_root: test_root)
      assert length(AgentRegistry.list_agents(session.id)) == 2

      # Create a snapshot change via MultiPatch
      {:ok, _} =
        MultiPatch.apply_patches(test_root, [
          %{
            path: "murder_target.ex",
            target: "def value, do: 1",
            replacement: "def value, do: 999"
          }
        ])

      assert File.read!(sample_file) =~ "999"

      # Keep the session control plane alive independently of the sandbox-backed
      # worker being murdered below. Killing that worker can recycle the shared
      # SQLite test connection, but cancellation must still reach this exact OTP
      # owner and complete its in-memory/file cleanup.
      assert {:ok, _server} = SessionServer.ensure_started(session.id)

      # Launch a swarm task and obtain PID
      {:ok, task_pid} = SwarmCoordinator.run_swarm(session.id, "Task to be murdered", test_root)

      # Kill the worker externally and confirm its DOWN before asking the
      # session coordinator to settle cancellation. This preserves the process
      # murder boundary without racing SQLite's single shared Sandbox
      # connection against a client that is still being torn down.
      task_ref = Process.monitor(task_pid)
      Process.exit(task_pid, :kill)
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}, 5_000

      {:ok, cancel_res} =
        SessionServer.cancel_session(session.id, project_root: test_root, action: :rollback)

      assert cancel_res.status == :stopped
      assert cancel_res.action == :rollback

      # Verify all subagents are terminated cleanly
      assert AgentRegistry.list_agents(session.id) == []

      # Verify rollback restored original file content
      assert File.read!(sample_file) =~ "def value, do: 1"
      refute File.read!(sample_file) =~ "999"

      # The synchronous coordinator state remains observable even when killing
      # a shared-Sandbox client forces SQLite to recycle its sole test
      # connection. Durable session persistence is asserted in the ordinary
      # cancellation tests that do not intentionally murder that DB client.
      assert SessionServer.get_state(session.id).status == :stopped
    end
  end

  describe "5. Concurrent Cancellation Contention" do
    test "races 15 concurrent cancel_session calls idempotently without crash", %{
      session: session,
      test_root: test_root
    } do
      # Start some subagents
      {:ok, _} = AgentSupervisor.start_agent(session.id, :planner, project_root: test_root)
      {:ok, _} = AgentSupervisor.start_agent(session.id, :explorer, project_root: test_root)

      # 15 concurrent tasks calling cancel_session
      tasks =
        for i <- 1..15 do
          Task.async(fn ->
            action = if rem(i, 2) == 0, do: :rollback, else: :commit
            SessionServer.cancel_session(session.id, project_root: test_root, action: action)
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert length(results) == 15

      for res <- results do
        assert {:ok, %{status: :stopped}} = res
      end

      assert AgentRegistry.list_agents(session.id) == []
      assert SessionServer.get_state(session.id).status == :stopped
    end
  end

  describe "6. Goal Lifecycle State Transition Corner Cases" do
    test "rejects creating a new goal while one is already in progress", %{
      session: session,
      test_root: test_root
    } do
      File.write!(Path.join(test_root, "goal_reenter.ex"), "defmodule GoalReenter, do: :ok")

      # First goal
      {:ok, goal1} =
        SessionServer.create_goal(session.id, "First Goal Workflow",
          project_root: test_root,
          auto_start: true
        )

      assert_receive {:session_status_changed, "running"}, 5000

      # Second goal immediately is rejected while the first is still running
      assert {:error, :already_running} =
               SessionServer.create_goal(session.id, "Second Goal Workflow Rejected",
                 project_root: test_root,
                 auto_start: true
               )

      # Original goal remains active
      state = SessionServer.get_state(session.id)
      assert state.active_goal.id == goal1.id
      assert state.status == :running

      # Await finish of original goal
      assert_receive {:session_status_changed, "idle"}, 35_000
    end

    test "rapid create -> cancel -> create -> cancel lifecycle loop", %{
      session: session,
      test_root: test_root
    } do
      for i <- 1..5 do
        {:ok, _goal} =
          SessionServer.create_goal(session.id, "Rapid Goal #{i}",
            project_root: test_root,
            auto_start: false
          )

        state = SessionServer.get_state(session.id)
        assert state.active_goal.title =~ "Rapid Goal #{i}"

        {:ok, cancel} = SessionServer.cancel_session(session.id, action: :rollback)
        assert cancel.status == :stopped
      end
    end

    test "pausing when already paused is idempotent and resuming without a run normalizes to idle",
         %{
           session: session
         } do
      {:ok, _} = SessionServer.ensure_started(session.id)

      # Pause twice
      assert {:ok, :paused} = SessionServer.pause_session(session.id)
      assert {:ok, :paused} = SessionServer.pause_session(session.id)
      assert SessionServer.get_state(session.id).status == :paused

      # Resume twice with no active run returns an error and normalizes to idle
      assert {:error, :no_active_run} = SessionServer.resume_session(session.id)
      assert {:error, :no_active_run} = SessionServer.resume_session(session.id)
      assert SessionServer.get_state(session.id).status == :idle
    end

    test "handles non-existent or deleted project root gracefully on cancel/rollback", %{
      session: session
    } do
      non_existent = Path.join(System.tmp_dir!(), "non_existent_#{Ecto.UUID.generate()}")

      {:ok, res} =
        SessionServer.cancel_session(session.id, project_root: non_existent, action: :rollback)

      assert res.status == :stopped
      assert res.action == :rollback
    end
  end
end
