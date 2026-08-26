defmodule IexCode.Engine.Challenger1SwarmFeedbackAdversarialTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentRegistry}
  alias IexCode.Tools.{MultiPatch, TestRunner}
  alias IexCode.Tools.TestRunner.Parser

  setup tags do
    :ok = IexCode.DataCase.setup_sandbox(tags)
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger1 Project #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger1 Swarm Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. Multi-Turn Autonomous Swarm Convergence & Self-Correction Loops
  # ============================================================================
  describe "1. Multi-Turn Autonomous Swarm Convergence & Self-Correction" do
    @tag :tmp_dir
    test "converges through multi-turn loop when AutoFix repairs missing alias", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      # 1. Target module
      File.write!(Path.join(lib_dir, "math_helper.ex"), """
      defmodule MathHelper do
        def add(a, b), do: a + b
      end
      """)

      # 2. Module with missing alias (needs auto-fix or coder repair)
      File.write!(Path.join(lib_dir, "calculator.ex"), """
      defmodule Calculator do
        def compute(x, y), do: MathHelper.add(x, y)
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Verify and compile calculator module",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :completed
      assert String.contains?(final_msg.content, "Swarm Execution Complete")
      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 2. Cycle Detection Stress-Testing
  # ============================================================================
  describe "2. Cycle Detection on Repeated Identical Diagnostics" do
    @tag :tmp_dir
    test "detects repeated syntax error diagnostics and halts before max retries", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      # Unclosed block that produces deterministic syntax error
      File.write!(Path.join(lib_dir, "unclosed.ex"), """
      defmodule Unclosed do
        def broken do
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix unclosed file",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :failed
      # Must halt on cycle detection before burning all 3 retries
      assert final_msg.metadata.iterations <= 2
      assert AgentRegistry.list_agents(session.id) == []
    end

    test "demonstrates hash stability defect: test runner duration jitter causes different hashes for identical failures" do
      out1 = """
        1) test something (MyTest)
           test/my_test.exs:4
           Assertion with == failed
           code:  assert 1 == 2
           left:  1
           right: 2
           stacktrace:
             test/my_test.exs:5: (test)

      Finished in 0.04 seconds (0.00s async, 0.04s sync)
      1 test, 1 failure
      """

      out2 = """
        1) test something (MyTest)
           test/my_test.exs:4
           Assertion with == failed
           code:  assert 1 == 2
           left:  1
           right: 2
           stacktrace:
             test/my_test.exs:5: (test)

      Finished in 0.05 seconds (0.00s async, 0.05s sync)
      1 test, 1 failure
      """

      res1 = Parser.parse(out1, 1)
      res2 = Parser.parse(out2, 1)

      diag1 = %{
        status: :failed,
        summary: "Tests failed: 1/1 failures",
        failures: res1.failures,
        compilation_errors: [],
        raw_output: res1.raw_output,
        result: res1
      }

      diag2 = %{
        status: :failed,
        summary: "Tests failed: 1/1 failures",
        failures: res2.failures,
        compilation_errors: [],
        raw_output: res2.raw_output,
        result: res2
      }

      raw_hash1 = :erlang.phash2(diag1)
      raw_hash2 = :erlang.phash2(diag2)

      # Raw hashing produces different hashes due to duration_s and raw_output jitter
      assert raw_hash1 != raw_hash2

      # Semantic hashing produces identical hashes
      sem_hash1 = :erlang.phash2({diag1.status, diag1.failures, diag1.compilation_errors})
      sem_hash2 = :erlang.phash2({diag2.status, diag2.failures, diag2.compilation_errors})
      assert sem_hash1 == sem_hash2
    end
  end

  # ============================================================================
  # 3. MultiPatch Rollback & Transactional Safety Stress-Testing
  # ============================================================================
  describe "3. MultiPatch Rollback on Crashes, Invalid Targets & Stale Stats" do
    @tag :tmp_dir
    test "aborts cleanly without writing when target is not found in file",
         %{tmp_dir: tmp_dir} do
      f1 = Path.join(tmp_dir, "lib/missing_target.ex")
      File.mkdir_p!(Path.dirname(f1))
      orig_content = "defmodule Missing do\n  def val, do: 1\nend"
      File.write!(f1, orig_content)

      # Target string that does not exist in the file
      patches = [
        %{
          path: "lib/missing_target.ex",
          target: "non_existent_target_string_999",
          replacement: "do: 2"
        }
      ]

      res = MultiPatch.apply_patches(tmp_dir, patches)
      assert match?({:error, {:target_not_found, "lib/missing_target.ex", _}}, res)

      # Verify file was never modified
      assert File.read!(f1) == orig_content
    end

    @tag :tmp_dir
    test "correctly scopes and restores snapshots by session_id in perform_rollback", %{
      tmp_dir: tmp_dir
    } do
      f1 = Path.join(tmp_dir, "lib/scoped_patch.ex")
      File.mkdir_p!(Path.dirname(f1))
      File.write!(f1, "defmodule Scoped do\n  def one, do: 1\nend")

      {:ok, summary} =
        MultiPatch.apply_patches(
          tmp_dir,
          [%{path: "lib/scoped_patch.ex", target: "do: 1", replacement: "do: 2"}],
          session_id: "test-session-uuid-123"
        )

      assert summary.applied == 1
      assert File.read!(f1) =~ "do: 2"

      # When SwarmCoordinator.perform_rollback is called with matching session_id
      state = %SwarmCoordinator.State{session_id: "test-session-uuid-123", project_root: tmp_dir}
      {:ok, res} = SwarmCoordinator.perform_rollback(tmp_dir, state)

      # perform_rollback finds snapshot with matching session_id and restores the file
      assert res == :rolled_back
      file_content = File.read!(f1)
      assert file_content =~ "do: 1"

      # Rollback for unrelated session does not affect other snapshots
      state_other = %SwarmCoordinator.State{
        session_id: "unrelated-session-uuid",
        project_root: tmp_dir
      }

      {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(tmp_dir, state_other)
    end
  end

  # ============================================================================
  # 4. TestRunner Port Process Termination & Timeout Handling
  # ============================================================================
  describe "4. TestRunner Port Process Termination & Timeout" do
    test "demonstrates List.to_string bug when Port.info returns integer os_pid" do
      port =
        Port.open({:spawn_executable, System.find_executable("mix")}, [
          :binary,
          :exit_status,
          args: ["--version"]
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)
      assert is_integer(pid)

      # List.to_string(pid) raises FunctionClauseError because pid is an integer
      assert_raise FunctionClauseError, fn ->
        List.to_string(pid)
      end

      # Proper conversion is to_string(pid) or Integer.to_string(pid)
      assert is_binary(to_string(pid))
      assert is_binary(Integer.to_string(pid))

      Port.close(port)
    end

    test "handles TestRunner timeout cleanly when timeout_ms is exceeded" do
      # Run TestRunner with a small timeout on current workspace
      res = TestRunner.run(File.cwd!(), timeout_ms: 10)
      assert res == {:error, :timeout}
    end
  end
end
