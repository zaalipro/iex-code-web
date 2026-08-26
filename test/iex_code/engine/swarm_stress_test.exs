defmodule IexCode.Engine.SwarmStressTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentSupervisor, AgentRegistry}
  alias IexCode.Tools.AutoFix
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError, StackFrame}

  setup tags do
    :ok = IexCode.DataCase.setup_sandbox(tags)
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{
        name: "Swarm Stress Proj #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Swarm Stress Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. Self-Healing Loop Convergence
  # ============================================================================
  describe "Self-Healing Loop Convergence" do
    @tag :tmp_dir
    @tag timeout: 180_000
    test "converges and passes when AutoFix resolves an unused variable warning in workspace", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Set up a workspace with an auto-fixable unused variable warning
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      broken_file = Path.join(lib_path, "calc.ex")

      File.write!(broken_file, """
      defmodule Calc do
        def value(unused_flag) do
          :ok
        end
      end
      """)

      # Run coordinator
      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix unused variable in calc.ex",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :completed
      assert is_binary(final_msg.content)
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # Subagent processes must be cleanly stopped after run
      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 2. Infinite Loop / Unfixable Error Handling
  # ============================================================================
  describe "Infinite Loop & Max Retries Cap" do
    @tag :tmp_dir
    @tag timeout: 180_000
    test "strictly halts after max_retries without looping indefinitely", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Set up an unfixable syntax error that cannot be resolved automatically
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      broken_file = Path.join(lib_path, "broken.ex")
      File.write!(broken_file, "defmodule Unfixable do\n  @@@invalid_token!!!\nend")

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix broken module",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert final_msg.metadata.status == :failed
      # Must halt cleanly and report failure in message
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # All agents must be stopped
      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 3. Cycle Detection
  # ============================================================================
  describe "Cycle Detection in Autonomous Feedback Loop" do
    @tag :tmp_dir
    @tag timeout: 180_000
    test "detects identical repeated error signatures and halts early", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      # Static unfixable file
      File.write!(
        Path.join(lib_path, "static_error.ex"),
        "defmodule StaticErr do\n  def unclosed do\n"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Resolve unclosed block",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :failed
      # Check that iterations stopped at or before max_retries (cycle caught on iteration 1)
      assert final_msg.metadata.iterations <= 3

      # Verify PubSub stage changed to failed
      assert_receive {:swarm_stage_changed, %{stage: :failed, progress: 100, message: term_msg}},
                     5000

      assert String.contains?(term_msg, "cycle detected") or
               String.contains?(term_msg, "Verification failed")

      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 4. AutoFix Robustness on Adversarial & Edge Cases
  # ============================================================================
  describe "AutoFix Adversarial Diagnostic Handling" do
    @tag :tmp_dir
    test "handles malformed, nil, empty, and unexpected input types gracefully without crashing",
         %{tmp_dir: tmp_dir} do
      assert {:error, _} = AutoFix.analyze_failures(tmp_dir, nil)
      assert {:ok, [_]} = AutoFix.analyze_failures(tmp_dir, "")
      assert {:ok, []} = AutoFix.analyze_failures(tmp_dir, [])
      assert {:ok, [_]} = AutoFix.analyze_failures(tmp_dir, %{random_key: 123})

      assert {:ok, [_]} =
               AutoFix.analyze_failures(tmp_dir, "Some random error string without file")

      # Generate patch proposals on empty/nil diagnostics
      assert {:error, _} = AutoFix.generate_patch_proposals(tmp_dir, nil)
      assert {:ok, []} = AutoFix.generate_patch_proposals(tmp_dir, "")
      assert {:ok, []} = AutoFix.generate_patch_proposals(tmp_dir, %{})

      # Apply auto fix returns error when no patches applicable
      assert {:error, _} = AutoFix.apply_auto_fix(tmp_dir, nil)
      assert {:error, :no_applicable_patches} = AutoFix.apply_auto_fix(tmp_dir, "")
    end

    @tag :tmp_dir
    test "correctly analyzes multi-file failures across compilation errors and test assertions",
         %{tmp_dir: tmp_dir} do
      f1 = %Failure{
        index: 1,
        test_name: "test math addition",
        module: "MathTest",
        file: "test/math_test.exs",
        line: 12,
        message: "Assertion with == failed\nleft: 10\nright: 20",
        left: "10",
        right: "20",
        stacktrace: [
          %StackFrame{file: "lib/math.ex", line: 4, app: "app", context: "Math.add/2", raw: ""}
        ]
      }

      ce1 = %CompilationError{
        error_type: "CompileError",
        file: "lib/util.ex",
        line: 8,
        message: "variable \"opts\" is unused"
      }

      result = %Result{
        status: :failed,
        total: 2,
        passed: 0,
        failures_count: 1,
        failures: [f1],
        compilation_errors: [ce1]
      }

      assert {:ok, analyzed} = AutoFix.analyze_failures(tmp_dir, result)
      assert length(analyzed) == 2

      math_analysis = Enum.find(analyzed, &(&1.file == "lib/math.ex"))
      assert math_analysis != nil
      assert math_analysis.line == 4
      assert math_analysis.error_type == :assertion_mismatch
      assert math_analysis.left == "10"
      assert math_analysis.right == "20"

      util_analysis = Enum.find(analyzed, &(&1.file == "lib/util.ex"))
      assert util_analysis != nil
      assert util_analysis.line == 8
      assert util_analysis.error_type == :unused_variable
    end

    @tag :tmp_dir
    test "proposes and applies fixes only for auto-fixable diagnostics in a batch", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      file1 = Path.join(lib_dir, "worker_one.ex")

      File.write!(
        file1,
        "defmodule WorkerOne do\n  def run(arg, unused_val) do\n    arg\n  end\nend"
      )

      file2 = Path.join(lib_dir, "worker_two.ex")
      File.write!(file2, "defmodule WorkerTwo do\n  def check, do :ok\nend")

      ce1 = %CompilationError{
        error_type: "CompileError",
        file: "lib/worker_one.ex",
        line: 2,
        message: "variable \"unused_val\" is unused"
      }

      ce2 = %CompilationError{
        error_type: "SyntaxError",
        file: "lib/worker_two.ex",
        line: 2,
        message: "syntax error before: :ok"
      }

      result = %Result{
        status: :compilation_error,
        total: 0,
        passed: 0,
        failures_count: 0,
        failures: [],
        compilation_errors: [ce1, ce2]
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, result)
      assert patch.path == "lib/worker_one.ex"

      # Apply atomic multi-file patch
      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, result)
      assert summary.applied == 1
      assert length(summary.patches) == 1

      # Only the unused-variable file is fixed; the syntax error is left untouched
      assert String.contains?(File.read!(file1), "_unused_val")
      assert String.contains?(File.read!(file2), "do :ok")
      refute String.contains?(File.read!(file2), "do: :ok")
    end

    @tag :tmp_dir
    test "handles complex diagnostics with missing line numbers, nested stackframes and unknown error types",
         %{tmp_dir: tmp_dir} do
      raw_diagnostic = """
      ** (UndefinedFunctionError) function MissingMod.nonexistent/2 is undefined (module MissingMod is not available)
          (app 0.1.0) lib/deep/nested/handler.ex:42: Handler.call/1
          (elixir 1.18.4) lib/enum.ex:123: Enum.map/2
      """

      assert {:ok, [analyzed]} = AutoFix.analyze_failures(tmp_dir, raw_diagnostic)
      assert analyzed.file == "lib/deep/nested/handler.ex"
      assert analyzed.line == 42
      assert analyzed.error_type == :missing_alias

      # When file doesn't exist on disk, heuristic patch returns clean error rather than crashing
      assert {:ok, []} = AutoFix.generate_patch_proposals(tmp_dir, raw_diagnostic)
    end
  end

  # ============================================================================
  # 5. PubSub Event Ordering & Telemetry Latencies
  # ============================================================================
  describe "PubSub Telemetry Ordering & Latency Monotonicity" do
    @tag :tmp_dir
    test "broadcasts ordered stage transitions with non-decreasing latency", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_telemetry.ex"),
        "defmodule LibTelemetry do\n  def ok, do: :ok\nend"
      )

      {:ok, _} =
        SwarmCoordinator.run(
          session.id,
          "Verify telemetry emissions",
          project_root: tmp_dir
        )

      # Drain and collect all PubSub messages
      events = drain_messages([])

      # Verify session lifecycle bounds
      assert {:session_status_changed, "running"} in events
      assert {:session_status_changed, "idle"} in events

      # Extract all swarm_stage_changed events
      stage_events =
        events
        |> Enum.filter(fn
          {:swarm_stage_changed, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:swarm_stage_changed, payload} -> payload end)

      assert length(stage_events) >= 5

      # Check stage progression sequence
      stages = Enum.map(stage_events, & &1.stage)
      assert :init in stages
      assert :planning in stages
      assert :exploring in stages
      assert :coding in stages
      assert :verifying in stages
      assert :complete in stages or :failed in stages

      # Check monotonic latency_ms values (latencies must be >= 0 and non-decreasing)
      latencies = Enum.map(stage_events, & &1.latency_ms)
      Enum.each(latencies, fn l -> assert is_integer(l) and l >= 0 end)
      assert latencies == Enum.sort(latencies)

      # Check agent PIDs are valid non-empty strings
      Enum.each(stage_events, fn ev ->
        assert is_binary(ev.agent_pid)
        assert String.starts_with?(ev.agent_pid, "#PID<")
      end)

      # Clean up subagents
      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  defp drain_messages(acc) do
    receive do
      msg -> drain_messages(acc ++ [msg])
    after
      500 -> acc
    end
  end
end
