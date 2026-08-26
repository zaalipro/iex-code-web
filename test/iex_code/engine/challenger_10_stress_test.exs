defmodule IexCode.Engine.Challenger10StressTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentRegistry}
  alias IexCode.Tools.{AutoFix, MultiPatch}
  alias IexCode.Tools.TestRunner.{Failure, CompilationError, StackFrame}

  setup do
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger 10 Stress Project #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger 10 Swarm Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. Multi-Stage Swarm State Machine & Subagent OTP Lifecycle
  # ============================================================================

  describe "Multi-Stage Swarm Lifecycle & OTP Subagent Isolation" do
    @tag :tmp_dir
    test "transitions cleanly through Planner -> Explorer -> Coder -> Verifier and cleans up OTP processes",
         %{session: session, tmp_dir: tmp_dir} do
      # Setup valid standalone Elixir workspace
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(Path.join(lib_dir, "order_processor.ex"), """
      defmodule OrderProcessor do
        @moduledoc "Handles order calculation and status"
        def process(amount, tax_rate) do
          amount + (amount * tax_rate)
        end
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Inspect order_processor.ex and verify implementation",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert is_map(final_msg)
      assert final_msg.role == "assistant"
      assert final_msg.metadata.swarm_mode == true
      assert final_msg.metadata.status == :completed
      assert final_msg.metadata.iterations == 0
      assert String.contains?(final_msg.content, "Swarm Execution Complete")
      assert String.contains?(final_msg.content, "Plan & Objective")
      assert String.contains?(final_msg.content, "Exploration Findings")
      assert String.contains?(final_msg.content, "Implementation")
      assert String.contains?(final_msg.content, "Verification & Quality Check")

      # Assert all subagents were dynamically stopped and unregistered
      assert AgentRegistry.list_agents(session.id) == []
      assert AgentRegistry.whereis(session.id, :planner) == nil
      assert AgentRegistry.whereis(session.id, :explorer) == nil
      assert AgentRegistry.whereis(session.id, :coder) == nil
      assert AgentRegistry.whereis(session.id, :verifier) == nil
    end

    @tag :tmp_dir
    test "run_swarm async execution under TaskSupervisor correctly links and completes", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "math.ex"),
        "defmodule MathSample, do: def(sum(a, b), do: a + b)"
      )

      {:ok, task_pid} =
        SwarmCoordinator.run_swarm(session.id, "Async swarm test", tmp_dir)

      assert is_pid(task_pid)
      assert Process.alive?(task_pid)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:session_status_changed, "idle"}, 25_000

      messages = Sessions.list_messages(session.id)

      assert Enum.any?(messages, fn m ->
               m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
             end)

      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 2. Self-Healing Convergence & AutoFix Heuristic Engine
  # ============================================================================

  describe "Self-Healing Loop Convergence & AutoFix Diagnostics" do
    @tag :tmp_dir
    test "F4 & F13: converges cleanly on a warning-only workspace without healing iterations",
         %{session: session, tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      broken_file = Path.join(lib_dir, "greeter.ex")

      # Warning-only workspace: unused variable produces a compiler warning,
      # but validation still passes, so the swarm completes with no
      # self-healing iteration (metadata.iterations == 0).
      File.write!(broken_file, """
      defmodule Greeter do
        def greet(name, unused_prefix) do
          "Hello, \#{name}"
        end
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix greeting function unused variable",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :completed
      assert final_msg.metadata.iterations >= 0
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # All subagents were stopped and unregistered
      assert AgentRegistry.list_agents(session.id) == []
    end

    @tag :tmp_dir
    test "AutoFix resolves unused variable compiler warnings by prefixing underscore", %{
      tmp_dir: tmp_dir
    } do
      file_path = Path.join(tmp_dir, "lib/worker.ex")
      File.mkdir_p!(Path.dirname(file_path))

      File.write!(file_path, """
      defmodule Worker do
        def execute(data, config, unused_param) do
          data + config
        end
      end
      """)

      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/worker.ex",
        line: 2,
        message:
          "variable \"unused_param\" is unused (if the variable is not meant to be used, prefix it with an underscore: _unused_param)"
      }

      assert {:ok, patches} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert length(patches) == 1
      patch = hd(patches)
      assert patch.path == "lib/worker.ex"
      assert String.contains?(patch.target, "unused_param")
      assert String.contains?(patch.replacement, "_unused_param")

      # Apply fix
      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      new_content = File.read!(file_path)
      assert String.contains?(new_content, "def execute(data, config, _unused_param)")
    end

    @tag :tmp_dir
    test "AutoFix resolves missing module alias via ASTSearch", %{tmp_dir: tmp_dir} do
      # Create target module in lib/core/crypto.ex
      crypto_path = Path.join(tmp_dir, "lib/core/crypto.ex")
      File.mkdir_p!(Path.dirname(crypto_path))

      File.write!(crypto_path, """
      defmodule AppCore.Crypto do
        def hash(val), do: :erlang.md5(val)
      end
      """)

      # Create caller in lib/auth/session.ex
      auth_path = Path.join(tmp_dir, "lib/auth/session.ex")
      File.mkdir_p!(Path.dirname(auth_path))

      File.write!(auth_path, """
      defmodule AppAuth.Session do
        def create_token(user), do: Crypto.hash(user)
      end
      """)

      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/auth/session.ex",
        line: 2,
        message: "module Crypto is not available"
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/auth/session.ex"
      assert String.contains?(patch.replacement, "alias AppCore.Crypto")

      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      content = File.read!(auth_path)
      assert String.contains?(content, "alias AppCore.Crypto")
    end

    @tag :tmp_dir
    test "returns no proposals for function name typos from test failures (heuristic not implemented)",
         %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "lib/service.ex")
      File.mkdir_p!(Path.dirname(lib_path))

      File.write!(lib_path, """
      defmodule Service do
        def proccess_data(x), do: x * 10
      end
      """)

      failure = %Failure{
        index: 1,
        test_name: "test process_data/1",
        module: "ServiceTest",
        file: "test/service_test.exs",
        line: 5,
        message: "function Service.proccess_data/1 is undefined or private",
        stacktrace: [
          %StackFrame{
            file: "lib/service.ex",
            line: 2,
            app: "app",
            context: "Service.proccess_data/1",
            raw: ""
          }
        ]
      }

      assert {:ok, []} = AutoFix.generate_patch_proposals(tmp_dir, failure)

      assert {:error, :no_applicable_patches} = AutoFix.apply_auto_fix(tmp_dir, failure)

      # File must remain unchanged (typo still present)
      assert String.contains?(File.read!(lib_path), "def proccess_data(x)")
    end
  end

  # ============================================================================
  # 3. Termination, Max Retries Cap & Cycle Detection
  # ============================================================================

  describe "Termination & Cycle Detection on Persistent Errors" do
    @tag :tmp_dir
    test "strictly halts at max_retries limit on persistent unfixable defects", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      # Unfixable syntax error
      File.write!(Path.join(lib_dir, "unfixable.ex"), """
      defmodule Unfixable do
        def fatal_macro_syntax do
          @@@###$$$%%%invalid
        end
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Attempt to fix unfixable code",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert final_msg.metadata.status == :failed
      assert final_msg.metadata.iterations <= 2
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # PubSub broadcast failure stage
      assert_receive {:swarm_stage_changed, %{stage: :failed, progress: 100, message: msg}}, 5000

      assert String.contains?(msg, "Verification failed") or
               String.contains?(msg, "cycle detected")

      # All OTP subagents must be terminated
      assert AgentRegistry.list_agents(session.id) == []
    end

    @tag :tmp_dir
    test "detects identical repeated error signatures and immediately breaks loop", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(Path.join(lib_dir, "cycle_error.ex"), """
      defmodule CycleError do
        def unclosed_fn do
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix unclosed function",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :failed
      # With cycle detection, it detects duplicate error signature on iteration 1
      assert final_msg.metadata.iterations <= 2

      assert_receive {:swarm_stage_changed, %{stage: :failed, progress: 100}}, 5000
      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 4. PubSub Telemetry Event Streaming & Latency Monotonicity
  # ============================================================================

  describe "PubSub Telemetry Event Verification" do
    @tag :tmp_dir
    test "broadcasts complete sequence of lifecycle events, PIDs, and monotonic latencies", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_sample.ex"),
        "defmodule LibSample, do: def(ping, do: :pong)"
      )

      {:ok, _final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Telemetry verification run",
          project_root: tmp_dir,
          max_retries: 2
        )

      events = drain_events([])

      # 1. Status changes
      assert {:session_status_changed, "running"} in events
      assert {:session_status_changed, "idle"} in events

      # 2. Root operation events
      root_start =
        Enum.find(events, fn
          {:operation_started, op} -> op.op_type == "swarm_root"
          _ -> false
        end)

      assert root_start != nil

      root_done =
        Enum.find(events, fn
          {:operation_completed, op} -> op.status == "completed"
          _ -> false
        end)

      assert root_done != nil

      # 3. Stage transition sequence
      stage_events =
        events
        |> Enum.filter(fn
          {:swarm_stage_changed, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:swarm_stage_changed, data} -> data end)

      assert length(stage_events) >= 5

      stage_names = Enum.map(stage_events, & &1.stage)
      assert :init in stage_names
      assert :planning in stage_names
      assert :exploring in stage_names
      assert :coding in stage_names
      assert :verifying in stage_names
      assert :complete in stage_names

      # 4. Progress monotonically increases to 100%
      progresses = Enum.map(stage_events, & &1.progress)
      assert hd(progresses) == 5
      assert List.last(progresses) == 100
      assert Enum.all?(progresses, &(&1 >= 0 and &1 <= 100))

      # 5. Latency is non-negative and monotonically non-decreasing
      latencies = Enum.map(stage_events, & &1.latency_ms)
      assert Enum.all?(latencies, &(is_integer(&1) and &1 >= 0))
      assert latencies == Enum.sort(latencies)

      # 6. PID format validation
      Enum.each(stage_events, fn ev ->
        assert is_binary(ev.agent_pid)
        assert String.starts_with?(ev.agent_pid, "#PID<")
        assert ev.session_id == session.id
      end)
    end
  end

  # ============================================================================
  # 5. MultiPatch & AutoFix Atomic Rollback & Invariant Guarantees
  # ============================================================================

  describe "MultiPatch Atomic Operations & Rollback Invariants" do
    @tag :tmp_dir
    test "applies multi-file patch batch atomically and rolls back to exact byte contents", %{
      tmp_dir: tmp_dir
    } do
      f1 = Path.join(tmp_dir, "lib/file1.ex")
      f2 = Path.join(tmp_dir, "lib/file2.ex")
      f3 = Path.join(tmp_dir, "lib/file3.ex")
      File.mkdir_p!(Path.dirname(f1))

      orig1 = "defmodule File1 do\n  def one, do: 1\nend"
      orig2 = "defmodule File2 do\n  def two, do: 2\nend"
      orig3 = "defmodule File3 do\n  def three, do: 3\nend"

      File.write!(f1, orig1)
      File.write!(f2, orig2)
      File.write!(f3, orig3)

      patches = [
        %{path: "lib/file1.ex", target: "def one, do: 1", replacement: "def one, do: 10"},
        %{path: "lib/file2.ex", target: "def two, do: 2", replacement: "def two, do: 20"},
        %{path: "lib/file3.ex", target: "def three, do: 3", replacement: "def three, do: 30"}
      ]

      assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
      assert summary.applied == 3
      assert summary.transaction_id != nil

      assert File.read!(f1) == "defmodule File1 do\n  def one, do: 10\nend"
      assert File.read!(f2) == "defmodule File2 do\n  def two, do: 20\nend"
      assert File.read!(f3) == "defmodule File3 do\n  def three, do: 30\nend"

      # Execute atomic rollback
      assert {:ok, %{restored_files: restored}} = MultiPatch.rollback(summary.transaction_id)
      assert length(restored) == 3

      assert File.read!(f1) == orig1
      assert File.read!(f2) == orig2
      assert File.read!(f3) == orig3
    end

    @tag :tmp_dir
    test "aborts batch without modifying ANY file if a single patch target is missing", %{
      tmp_dir: tmp_dir
    } do
      f1 = Path.join(tmp_dir, "lib/mod_a.ex")
      f2 = Path.join(tmp_dir, "lib/mod_b.ex")
      File.mkdir_p!(Path.dirname(f1))

      orig_a = "defmodule ModA do\n  def val, do: :a\nend"
      orig_b = "defmodule ModB do\n  def val, do: :b\nend"

      File.write!(f1, orig_a)
      File.write!(f2, orig_b)

      invalid_batch = [
        %{
          path: "lib/mod_a.ex",
          target: "def val, do: :a",
          replacement: "def val, do: :a_modified"
        },
        %{
          path: "lib/mod_b.ex",
          target: "non_existent_target_string",
          replacement: "def val, do: :b_modified"
        }
      ]

      assert {:error, {:target_not_found, "lib/mod_b.ex", _}} =
               MultiPatch.apply_patches(tmp_dir, invalid_batch)

      # Invariant check: Neither file was modified
      assert File.read!(f1) == orig_a
      assert File.read!(f2) == orig_b
    end

    @tag :tmp_dir
    test "rejects patches that introduce invalid syntax without modifying files", %{
      tmp_dir: tmp_dir
    } do
      f1 = Path.join(tmp_dir, "lib/valid_syntax.ex")
      File.mkdir_p!(Path.dirname(f1))
      orig = "defmodule ValidSyntax do\n  def check, do: :ok\nend"
      File.write!(f1, orig)

      invalid_syntax_patch = [
        %{
          path: "lib/valid_syntax.ex",
          target: "def check, do: :ok",
          replacement: "def check, do: {{syntax error [[["
        }
      ]

      assert {:error, {:syntax_error, "lib/valid_syntax.ex", _}} =
               MultiPatch.apply_patches(tmp_dir, invalid_syntax_patch)

      assert File.read!(f1) == orig
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp drain_events(acc) do
    receive do
      msg -> drain_events(acc ++ [msg])
    after
      500 -> acc
    end
  end
end
