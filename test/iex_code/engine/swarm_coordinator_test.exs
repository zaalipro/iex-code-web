defmodule IexCode.Engine.SwarmCoordinatorTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentSupervisor}
  alias IexCode.Tools.MultiPatch.Snapshot

  setup context do
    root_path = Map.get(context, :tmp_dir, File.cwd!())

    {:ok, project} =
      Projects.create_project(%{name: "SwarmCoord Test Proj", root_path: root_path})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "SwarmCoord Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  describe "SwarmCoordinator State Machine & PubSub Telemetry" do
    @tag :tmp_dir
    test "executes full swarm lifecycle and streams stage transitions", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_main.ex"),
        "defmodule LibMain do\n  def hello, do: :world\nend"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Inspect workspace and verify hello module",
          project_root: tmp_dir
        )

      assert is_map(final_msg)
      assert final_msg.role == "assistant"
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # Collect PubSub stage transitions
      assert_receive {:swarm_stage_changed, %{stage: :init, progress: 5}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 15}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :exploring, progress: 35}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :coding, progress: 45}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :verifying, progress: 75}}, 5000
      assert_receive {:session_status_changed, "idle"}, 5000

      # Clean up subagents
      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "run_swarm runs asynchronously under TaskSupervisor", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_async.ex"),
        "defmodule LibAsync do\n  def val, do: 1\nend"
      )

      {:ok, pid} = SwarmCoordinator.run_swarm(session.id, "Analyze async files", tmp_dir)
      assert is_pid(pid) and Process.alive?(pid)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:session_status_changed, "idle"}, 20_000

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "Autonomous Error Feedback Loop & Retries" do
    @tag :tmp_dir
    test "handles verification failure with max retries cap", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Write a file with an intentional compile/syntax error
      File.write!(
        Path.join(tmp_dir, "lib_error.ex"),
        "defmodule LibError do\n  def broken_syntax, do :error\nend"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Attempt to fix broken syntax",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert is_map(final_msg)
      # Assert message indicates completion of swarm attempt
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "direct re-verification optimization heals syntax error via AutoFix and completes",
         %{session: session, tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      file = Path.join(lib_path, "calc.ex")

      File.write!(file, """
      defmodule Calc do
        def hello(name), do "world"
      end
      """)

      transaction_id = "completed-swarm-#{System.unique_integer([:positive])}"

      assert :ok =
               Snapshot.save_snapshot(
                 transaction_id,
                 [
                   %{
                     path: "lib/calc.ex",
                     full_path: file,
                     file_existed?: true,
                     original_content: File.read!(file),
                     new_content: File.read!(file)
                   }
                 ],
                 project_root: tmp_dir,
                 session_id: session.id
               )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix syntax error in calc.ex",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :completed
      assert String.contains?(final_msg.content, "Swarm Execution Complete")
      assert {:error, :not_found} = Snapshot.get_snapshot(transaction_id)

      # Confirm AutoFix healed the syntax error
      assert File.read!(file) =~ ~s(do: "world")

      AgentSupervisor.stop_all_agents(session.id)
    end
  end
end
