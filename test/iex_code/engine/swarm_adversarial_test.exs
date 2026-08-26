defmodule IexCode.Engine.SwarmAdversarialTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentSupervisor, AgentRegistry}
  alias IexCode.Tools.{AutoFix, MultiPatch}
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError, StackFrame}

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Adversarial Test Project #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Adversarial Swarm Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. SwarmCoordinator State Machine & Feedback Loop Stress Tests
  # ============================================================================

  describe "SwarmCoordinator State Machine & Flow" do
    @tag :tmp_dir
    test "traverses full state machine and streams PubSub stage events",
         %{session: session, tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "lib_calculator.ex"),
        """
        defmodule Calculator do
          def add(a, b), do: a + b
        end
        """
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Verify calculator module",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert final_msg.role == "assistant"
      assert String.contains?(final_msg.content, "Swarm Execution Complete")
      assert final_msg.metadata.swarm_mode == true

      # Assert all stage transition PubSub events were broadcast in correct sequence
      assert_receive {:swarm_stage_changed, %{stage: :init, progress: 5, latency_ms: l1}}
                     when l1 >= 0

      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 15}}
      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 25}}
      assert_receive {:swarm_stage_changed, %{stage: :exploring, progress: 35}}
      assert_receive {:swarm_stage_changed, %{stage: :exploring, progress: 45}}
      assert_receive {:swarm_stage_changed, %{stage: :coding, progress: 45}}
      assert_receive {:swarm_stage_changed, %{stage: :verifying, progress: 75}}
      assert_receive {:session_status_changed, "idle"}

      # Verify all subagents were stopped cleanly
      assert AgentRegistry.list_agents(session.id) == []
    end

    @tag :tmp_dir
    test "enforces max_retries limit on persistent verification failure", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # File with persistent non-auto-fixable syntax/semantic defect
      File.write!(
        Path.join(tmp_dir, "persistent_broken.ex"),
        """
        defmodule PersistentBroken do
          def fatal_syntax do
            @@@###$$$%%%invalid_token
          end
        end
        """
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix persistent broken file",
          project_root: tmp_dir,
          max_retries: 1
        )

      assert is_map(final_msg)
      assert final_msg.metadata.status == :failed
      # Iterations should not exceed max_retries
      assert final_msg.metadata.iterations <= 1

      # PubSub should broadcast failure terminal state
      assert_receive {:swarm_stage_changed, %{stage: :failed, progress: 100, message: msg}}

      assert String.contains?(msg, "Verification failed") or
               String.contains?(msg, "cycle detected")

      # Subagents stopped
      assert AgentRegistry.list_agents(session.id) == []
    end

    @tag :tmp_dir
    test "detects error signature cycles and halts immediately", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "cycle_test.exs"),
        "defmodule CycleTest do\n  def unclosed do\n"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Cycle test",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :failed
      # Cycle detection halts before reaching all 3 full retries
      assert final_msg.metadata.iterations <= 2

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "supports concurrent swarm sessions without AgentRegistry key collisions", %{
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, session_a} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Swarm Session A",
          swarm_mode: true
        })

      {:ok, session_b} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Swarm Session B",
          swarm_mode: true
        })

      File.write!(Path.join(tmp_dir, "mod_a.ex"), "defmodule ModA, do: :ok")
      File.write!(Path.join(tmp_dir, "mod_b.ex"), "defmodule ModB, do: :ok")

      # Start agents for both sessions
      {:ok, pid_a_planner} =
        AgentSupervisor.start_agent(session_a.id, :planner, project_root: tmp_dir)

      {:ok, pid_b_planner} =
        AgentSupervisor.start_agent(session_b.id, :planner, project_root: tmp_dir)

      assert is_pid(pid_a_planner) and is_pid(pid_b_planner)
      assert pid_a_planner != pid_b_planner

      assert AgentRegistry.whereis(session_a.id, :planner) == pid_a_planner
      assert AgentRegistry.whereis(session_b.id, :planner) == pid_b_planner

      # Stopping session_a agents does NOT affect session_b
      AgentSupervisor.stop_all_agents(session_a.id)
      assert AgentRegistry.whereis(session_a.id, :planner) == nil
      assert AgentRegistry.whereis(session_b.id, :planner) == pid_b_planner

      AgentSupervisor.stop_all_agents(session_b.id)
      assert AgentRegistry.whereis(session_b.id, :planner) == nil
    end
  end

  # ============================================================================
  # 2. AutoFix Diagnostic & AST Resolution Stress Tests
  # ============================================================================

  describe "AutoFix Diagnostic & AST-Assisted Fixing" do
    test "parses and classifies all major error categories" do
      # 1. Unused variable
      unused_res = %Result{
        status: :compilation_error,
        total: 0,
        passed: 0,
        failures_count: 0,
        failures: [],
        compilation_errors: [
          %CompilationError{
            error_type: "CompileError",
            file: "lib/my_mod.ex",
            line: 14,
            message: "variable \"opts\" is unused"
          }
        ]
      }

      {:ok, [analyzed1]} = AutoFix.analyze_failures("/root", unused_res)
      assert analyzed1.error_type == :unused_variable
      assert analyzed1.file == "lib/my_mod.ex"
      assert analyzed1.line == 14

      # 2. Missing alias
      alias_res = %Result{
        status: :compilation_error,
        total: 0,
        passed: 0,
        failures_count: 0,
        failures: [],
        compilation_errors: [
          %CompilationError{
            error_type: "CompileError",
            file: "lib/caller.ex",
            line: 5,
            message: "module MyApp.Worker is not available"
          }
        ]
      }

      {:ok, [analyzed2]} = AutoFix.analyze_failures("/root", alias_res)
      assert analyzed2.error_type == :missing_alias

      # 3. Undefined function
      undef_res = %Failure{
        index: 1,
        test_name: "test undefined",
        module: "ModTest",
        file: "test/mod_test.exs",
        line: 8,
        message: "function Mod.calc/2 is undefined or private",
        stacktrace: [
          %StackFrame{file: "lib/mod.ex", line: 20, app: "app", context: "Mod.calc/2", raw: ""}
        ]
      }

      {:ok, [analyzed3]} = AutoFix.analyze_failures("/root", undef_res)
      assert analyzed3.error_type == :undefined_function
      assert analyzed3.file == "lib/mod.ex"
      assert analyzed3.line == 20
      assert analyzed3.source == :stacktrace

      # 4. Assertion mismatch
      assert_res = %Failure{
        index: 1,
        test_name: "test math equality",
        module: "MathTest",
        file: "test/math_test.exs",
        line: 15,
        message: "Assertion with == failed\nleft: 10\nright: 20",
        left: "10",
        right: "20"
      }

      {:ok, [analyzed4]} = AutoFix.analyze_failures("/root", assert_res)
      assert analyzed4.error_type == :assertion_mismatch
      assert analyzed4.left == "10"
      assert analyzed4.right == "20"

      # 5. Syntax error
      syntax_res = %CompilationError{
        error_type: "SyntaxError",
        file: "lib/syntax.ex",
        line: 3,
        message: "syntax error before: :bar"
      }

      {:ok, [analyzed5]} = AutoFix.analyze_failures("/root", syntax_res)
      assert analyzed5.error_type == :syntax_error
      assert analyzed5.line == 3

      # 6. Raw string diagnostic parsing
      raw_str =
        "== Compilation error in file lib/parser.ex ==\nlib/parser.ex:42: syntax error before: end"

      {:ok, [analyzed6]} = AutoFix.analyze_failures("/root", raw_str)
      assert analyzed6.file == "lib/parser.ex"
      assert analyzed6.line == 42
      assert analyzed6.error_type == :syntax_error
    end

    @tag :tmp_dir
    test "resolves missing module alias via AST search and generates patch", %{tmp_dir: tmp_dir} do
      # Target module defined in lib/engine/math.ex
      math_path = Path.join(tmp_dir, "lib/engine/math.ex")
      File.mkdir_p!(Path.dirname(math_path))
      File.write!(math_path, "defmodule SuperApp.Engine.Math do\n  def calc, do: 42\nend")

      # Caller module in lib/caller.ex missing alias
      caller_path = Path.join(tmp_dir, "lib/caller.ex")

      File.write!(
        caller_path,
        "defmodule SuperApp.Caller do\n  def call_it, do: Math.calc()\nend"
      )

      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/caller.ex",
        line: 2,
        message: "module Math is not available"
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/caller.ex"
      assert String.contains?(patch.replacement, "alias SuperApp.Engine.Math")

      # Apply fix
      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      content = File.read!(caller_path)
      assert String.contains?(content, "alias SuperApp.Engine.Math")
    end

    test "handles malformed, empty, or unparseable diagnostics gracefully" do
      assert {:ok, []} =
               AutoFix.analyze_failures("/tmp", %Result{failures: [], compilation_errors: []})

      assert {:error, :no_applicable_patches} =
               AutoFix.apply_auto_fix("/tmp", %Result{failures: [], compilation_errors: []})

      # Unparseable nil and unexpected structures
      assert {:ok, _} = AutoFix.analyze_failures("/tmp", %{})
      assert {:ok, []} = AutoFix.generate_patch_proposals("/tmp", %{})
    end
  end

  # ============================================================================
  # 3. Multi-File Atomic Patching & Rollback Stress Tests
  # ============================================================================

  describe "MultiPatch Atomic Operations & Rollback" do
    @tag :tmp_dir
    test "applies multi-file patch batch atomically across multiple files", %{tmp_dir: tmp_dir} do
      f1 = Path.join(tmp_dir, "lib/file_one.ex")
      f2 = Path.join(tmp_dir, "lib/file_two.ex")
      File.mkdir_p!(Path.dirname(f1))

      File.write!(f1, "defmodule FileOne do\n  def one, do: 1\nend")
      File.write!(f2, "defmodule FileTwo do\n  def two, do: 2\nend")

      patches = [
        %{path: "lib/file_one.ex", target: "def one, do: 1", replacement: "def one, do: 100"},
        %{path: "lib/file_two.ex", target: "def two, do: 2", replacement: "def two, do: 200"}
      ]

      assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
      assert summary.applied == 2
      assert summary.transaction_id != nil

      assert File.read!(f1) == "defmodule FileOne do\n  def one, do: 100\nend"
      assert File.read!(f2) == "defmodule FileTwo do\n  def two, do: 200\nend"

      # Verify rollback restores both files to original contents
      assert {:ok, %{restored_files: restored}} = MultiPatch.rollback(summary.transaction_id)
      assert length(restored) == 2
      assert File.read!(f1) == "defmodule FileOne do\n  def one, do: 1\nend"
      assert File.read!(f2) == "defmodule FileTwo do\n  def two, do: 2\nend"
    end

    @tag :tmp_dir
    test "aborts transaction and makes ZERO disk changes when any patch target is missing", %{
      tmp_dir: tmp_dir
    } do
      f1 = Path.join(tmp_dir, "lib/valid.ex")
      f2 = Path.join(tmp_dir, "lib/target_missing.ex")
      File.mkdir_p!(Path.dirname(f1))

      orig1 = "defmodule Valid do\n  def valid, do: :ok\nend"
      orig2 = "defmodule Missing do\n  def existing_fn, do: :ok\nend"

      File.write!(f1, orig1)
      File.write!(f2, orig2)

      patches = [
        %{
          path: "lib/valid.ex",
          target: "def valid, do: :ok",
          replacement: "def valid, do: :changed"
        },
        %{
          path: "lib/target_missing.ex",
          target: "non_existent_target_string_12345",
          replacement: "foo"
        }
      ]

      # Must return target not found error
      assert {:error, {:target_not_found, "lib/target_missing.ex", _}} =
               MultiPatch.apply_patches(tmp_dir, patches)

      # In-memory validation prevents ANY disk writes
      assert File.read!(f1) == orig1
      assert File.read!(f2) == orig2
    end

    @tag :tmp_dir
    test "rejects patches that would create invalid Elixir syntax", %{tmp_dir: tmp_dir} do
      f1 = Path.join(tmp_dir, "lib/syntax_check.ex")
      File.mkdir_p!(Path.dirname(f1))
      orig = "defmodule SyntaxCheck do\n  def good, do: :ok\nend"
      File.write!(f1, orig)

      invalid_syntax_patch = [
        %{
          path: "lib/syntax_check.ex",
          target: "def good, do: :ok",
          replacement: "def good, do: {{invalid syntax [[["
        }
      ]

      assert {:error, {:syntax_error, "lib/syntax_check.ex", _}} =
               MultiPatch.apply_patches(tmp_dir, invalid_syntax_patch)

      # Disk remains untouched
      assert File.read!(f1) == orig
    end

    @tag :tmp_dir
    test "supports multi-patch preview without writing to disk", %{tmp_dir: tmp_dir} do
      f1 = Path.join(tmp_dir, "lib/preview_test.ex")
      File.mkdir_p!(Path.dirname(f1))
      orig = "defmodule PreviewTest do\n  def val, do: 1\nend"
      File.write!(f1, orig)

      patches = [
        %{path: "lib/preview_test.ex", target: "do: 1", replacement: "do: 999"}
      ]

      assert {:ok, %{diff: diff, patches: planned}} = MultiPatch.preview_patches(tmp_dir, patches)
      assert is_binary(diff) and String.contains?(diff, "-  def val, do: 1")
      assert String.contains?(diff, "+  def val, do: 999")
      assert length(planned) == 1

      # Disk must remain untouched
      assert File.read!(f1) == orig
    end
  end
end
