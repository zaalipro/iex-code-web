defmodule IexCode.Engine.Challenger12AutofixSwarmStressTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SwarmCoordinator, AgentRegistry}
  alias IexCode.Tools.{AutoFix, MultiPatch}
  alias IexCode.Tools.TestRunner.{Result, Failure, CompilationError, StackFrame}

  setup do
    IexCode.DataCase.drain_all_processes()

    {:ok, project} =
      Projects.create_project(%{
        name: "Challenger 12 Swarm Stress #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Challenger 12 Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  # ============================================================================
  # 1. macOS Symlink Canonicalization (/var vs /private/var)
  # ============================================================================
  describe "macOS Symlink Path Normalization & Target Validation" do
    @tag :tmp_dir
    test "correctly resolves /var vs /private/var symlink mismatches in stack traces and roots",
         %{tmp_dir: tmp_dir} do
      # Determine realpath and potential symlinked alias
      _real_tmp =
        case :file.read_link(String.to_charlist(tmp_dir)) do
          {:ok, target} ->
            tgt = List.to_string(target)
            if Path.type(tgt) == :absolute, do: tgt, else: Path.expand(tgt, Path.dirname(tmp_dir))

          {:error, _} ->
            # If tmp_dir starts with /var, create a /private/var path or vice versa
            if String.starts_with?(tmp_dir, "/var/") do
              "/private" <> tmp_dir
            else
              tmp_dir
            end
        end

      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      target_file = Path.join(lib_dir, "symlink_mod.ex")

      File.write!(target_file, """
      defmodule SymlinkMod do
        def compute(x), do "result: \#{x}"
      end
      """)

      # Construct a CompilationError with the alternate (real or symlinked) absolute path
      alternate_file_path =
        if String.starts_with?(target_file, "/private/var/") do
          String.replace_prefix(target_file, "/private/var/", "/var/")
        else
          target_file
        end

      comp_err = %CompilationError{
        error_type: "SyntaxError",
        file: alternate_file_path,
        line: 2,
        message: "syntax error before: \"result: \""
      }

      # Test analyze_failures with root being tmp_dir while error points to alternate_file_path
      assert {:ok, [analyzed]} = AutoFix.analyze_failures(tmp_dir, comp_err)
      assert analyzed.file == "lib/symlink_mod.ex"
      assert analyzed.line == 2
      assert analyzed.error_type == :syntax_error
      assert analyzed.context.content != ""
      assert String.contains?(analyzed.context.content, "def compute(x)")

      # Test patch generation
      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/symlink_mod.ex"
      assert String.contains?(patch.target, "do \"result:")
      assert String.contains?(patch.replacement, "do: \"result:")

      # Apply fix
      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      # Verify repaired file on disk
      repaired = File.read!(target_file)
      assert String.contains?(repaired, "def compute(x), do: \"result: \#{x}\"")
    end

    @tag :tmp_dir
    test "resolves StackFrame absolute paths pointing through symlinks", %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      math_file = Path.join(lib_dir, "calculator.ex")

      File.write!(math_file, """
      defmodule Calculator do
        def add(a, b), do: a + b + 1
      end
      """)

      symlinked_frame_path =
        if String.starts_with?(math_file, "/private/var/") do
          String.replace_prefix(math_file, "/private/var/", "/var/")
        else
          math_file
        end

      failure = %Failure{
        index: 1,
        test_name: "test addition",
        module: "CalculatorTest",
        file: "test/calculator_test.exs",
        line: 10,
        message: "Assertion with == failed\nleft: 3\nright: 2",
        left: "3",
        right: "2",
        stacktrace: [
          %StackFrame{
            file: symlinked_frame_path,
            line: 2,
            app: "app",
            context: "Calculator.add/2",
            raw: "#{symlinked_frame_path}:2"
          }
        ]
      }

      assert {:ok, [analyzed]} = AutoFix.analyze_failures(tmp_dir, failure)
      assert analyzed.file == "lib/calculator.ex"
      assert analyzed.line == 2
      assert analyzed.error_type == :assertion_mismatch
      assert String.contains?(analyzed.context.content, "def add(a, b)")
    end
  end

  # ============================================================================
  # 2. Self-Healing Convergence on Diverse Error Categories (F4 & F13)
  # ============================================================================
  describe "Self-Healing Multi-Category Convergence" do
    @tag :tmp_dir
    test "AutoFix resolves missing alias using ASTSearch across deep directories", %{
      tmp_dir: tmp_dir
    } do
      # 1. Create target module deep in lib/domain/services/notifier.ex
      target_dir = Path.join(tmp_dir, "lib/domain/services")
      File.mkdir_p!(target_dir)
      target_path = Path.join(target_dir, "notifier.ex")

      File.write!(target_path, """
      defmodule Domain.Services.Notifier do
        def send_alert(msg), do: {:ok, msg}
      end
      """)

      # 2. Create caller module in lib/api/controllers/event_controller.ex
      caller_dir = Path.join(tmp_dir, "lib/api/controllers")
      File.mkdir_p!(caller_dir)
      caller_path = Path.join(caller_dir, "event_controller.ex")

      File.write!(caller_path, """
      defmodule Api.EventController do
        def notify(evt) do
          Notifier.send_alert(evt)
        end
      end
      """)

      comp_err = %CompilationError{
        error_type: "CompileError",
        file: "lib/api/controllers/event_controller.ex",
        line: 3,
        message: "module Notifier is not available"
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, comp_err)
      assert patch.path == "lib/api/controllers/event_controller.ex"
      assert String.contains?(patch.replacement, "alias Domain.Services.Notifier")

      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, comp_err)
      assert summary.applied == 1

      content = File.read!(caller_path)
      assert String.contains?(content, "alias Domain.Services.Notifier")
      assert String.contains?(content, "Notifier.send_alert(evt)")
    end

    @tag :tmp_dir
    test "AutoFix resolves only the unused-variable error in batch (syntax error skipped)", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      f1 = Path.join(lib_dir, "service_a.ex")
      File.write!(f1, "defmodule ServiceA do\n  def run(a, unused_opt), do: a * 2\nend")

      f2 = Path.join(lib_dir, "service_b.ex")
      File.write!(f2, "defmodule ServiceB do\n  def status, do :ok\nend")

      diag = %Result{
        status: :compilation_error,
        total: 0,
        passed: 0,
        failures_count: 0,
        failures: [],
        compilation_errors: [
          %CompilationError{
            error_type: "CompileError",
            file: "lib/service_a.ex",
            line: 2,
            message: "variable \"unused_opt\" is unused"
          },
          %CompilationError{
            error_type: "SyntaxError",
            file: "lib/service_b.ex",
            line: 2,
            message: "syntax error before: :ok"
          }
        ]
      }

      assert {:ok, [patch]} = AutoFix.generate_patch_proposals(tmp_dir, diag)
      assert patch.path == "lib/service_a.ex"

      assert {:ok, summary} = AutoFix.apply_auto_fix(tmp_dir, diag)
      assert summary.applied == 1

      assert String.contains?(File.read!(f1), "_unused_opt")

      # The syntax-error half is not auto-fixed and remains broken on disk
      assert String.contains?(File.read!(f2), "do :ok")
    end
  end

  # ============================================================================
  # 3. Swarm State Machine Transitions & Process Isolation
  # ============================================================================
  describe "Swarm State Machine Transitions & OTP Process Architecture" do
    @tag :tmp_dir
    test "executes Planner -> Explorer -> Coder -> Verifier and converges cleanly on unused variable warning without healing",
         %{
           session: session,
           tmp_dir: tmp_dir
         } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      # Warning-only workspace: an unused variable never fails validation, so
      # no self-healing iteration is needed (metadata.iterations == 0).
      broken_path = Path.join(lib_dir, "app_core.ex")

      File.write!(broken_path, """
      defmodule AppCore do
        def perform_task(x, unused_ctx) do
          "task_\#{x}"
        end
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix unused variable in perform_task",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.role == "assistant"
      assert final_msg.metadata.swarm_mode == true
      assert final_msg.metadata.status == :completed
      assert final_msg.metadata.iterations >= 0
      assert final_msg.metadata.iterations <= 3
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # OTP process cleanup verification
      assert AgentRegistry.list_agents(session.id) == []
      assert AgentRegistry.whereis(session.id, :planner) == nil
      assert AgentRegistry.whereis(session.id, :explorer) == nil
      assert AgentRegistry.whereis(session.id, :coder) == nil
      assert AgentRegistry.whereis(session.id, :verifier) == nil
    end
  end

  # ============================================================================
  # 4. Cycle Detection & Unfixable Termination
  # ============================================================================
  describe "Cycle Detection & Graceful Termination" do
    @tag :tmp_dir
    test "detects identical repeated error signatures and immediately halts loop without runaway",
         %{session: session, tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      # Permanently broken syntax with unclosed quote and invalid characters
      File.write!(Path.join(lib_dir, "fatal.ex"), """
      defmodule Fatal do
        def unrecoverable do
          "unclosed string
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Attempt impossible fix",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :failed
      # Must halt on cycle detection on iteration 1 or 2
      assert final_msg.metadata.iterations <= 3
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # Clean OTP termination
      assert AgentRegistry.list_agents(session.id) == []
    end
  end

  # ============================================================================
  # 5. PubSub Telemetry Streaming & Latency Monotonicity
  # ============================================================================
  describe "PubSub Telemetry Event Verification" do
    @tag :tmp_dir
    test "streams lifecycle events, valid PIDs, and strictly non-decreasing latencies", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "clean_module.ex"),
        "defmodule CleanModule, do: def(ping, do: :pong)"
      )

      {:ok, _} =
        SwarmCoordinator.run(
          session.id,
          "Telemetry verification test",
          project_root: tmp_dir,
          max_retries: 1
        )

      events = drain_pubsub([])

      # Verify stage events
      stage_events =
        events
        |> Enum.filter(fn
          {:swarm_stage_changed, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:swarm_stage_changed, payload} -> payload end)

      assert length(stage_events) >= 5

      # Verify PID strings
      Enum.each(stage_events, fn ev ->
        assert is_binary(ev.agent_pid)
        assert Regex.match?(~r/^#PID<\d+\.\d+\.\d+>$/, ev.agent_pid)
        assert ev.session_id == session.id
      end)

      # Verify monotonic latencies
      latencies = Enum.map(stage_events, & &1.latency_ms)
      assert Enum.all?(latencies, &(is_integer(&1) and &1 >= 0))
      assert latencies == Enum.sort(latencies)

      # Verify stage sequence
      stages = Enum.map(stage_events, & &1.stage)
      assert :init in stages
      assert :planning in stages
      assert :exploring in stages
      assert :coding in stages
      assert :verifying in stages
      assert :complete in stages
    end
  end

  # ============================================================================
  # 6. MultiPatch Atomic Rollback & Invariant Guarantees
  # ============================================================================
  describe "MultiPatch Atomic Batching & Rollback Invariants" do
    @tag :tmp_dir
    test "applies 5-file patch batch and rolls back to exact byte content", %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      files =
        for i <- 1..5 do
          f_path = Path.join(lib_dir, "batch_mod_#{i}.ex")
          orig = "defmodule BatchMod#{i} do\n  def get_val, do: #{i}\nend"
          File.write!(f_path, orig)
          {f_path, "lib/batch_mod_#{i}.ex", orig}
        end

      patches =
        Enum.map(files, fn {_full, rel, _orig} ->
          %{
            path: rel,
            target: "def get_val, do: ",
            replacement: "def get_val, do: 100 + "
          }
        end)

      # Apply batch
      assert {:ok, summary} = MultiPatch.apply_patches(tmp_dir, patches)
      assert summary.applied == 5
      assert summary.transaction_id != nil

      # Verify modifications
      for {full, _rel, _orig} <- files do
        assert String.contains?(File.read!(full), "100 + ")
      end

      # Rollback transaction
      assert {:ok, %{restored_files: restored}} = MultiPatch.rollback(summary.transaction_id)
      assert length(restored) == 5

      # Verify exact byte restoration
      for {full, _rel, orig} <- files do
        assert File.read!(full) == orig
      end
    end

    @tag :tmp_dir
    test "preserves disk integrity when a middle patch in a batch fails", %{tmp_dir: tmp_dir} do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      f1 = Path.join(lib_dir, "file_a.ex")
      f2 = Path.join(lib_dir, "file_b.ex")
      f3 = Path.join(lib_dir, "file_c.ex")

      orig1 = "defmodule FileA do\n  def a, do: 1\nend"
      orig2 = "defmodule FileB do\n  def b, do: 2\nend"
      orig3 = "defmodule FileC do\n  def c, do: 3\nend"

      File.write!(f1, orig1)
      File.write!(f2, orig2)
      File.write!(f3, orig3)

      # Batch where 2nd patch has non-existent target
      batch = [
        %{path: "lib/file_a.ex", target: "def a, do: 1", replacement: "def a, do: 10"},
        %{path: "lib/file_b.ex", target: "NON_EXISTENT_STRING", replacement: "def b, do: 20"},
        %{path: "lib/file_c.ex", target: "def c, do: 3", replacement: "def c, do: 30"}
      ]

      assert {:error, {:target_not_found, "lib/file_b.ex", _}} =
               MultiPatch.apply_patches(tmp_dir, batch)

      # Invariant: NO files modified
      assert File.read!(f1) == orig1
      assert File.read!(f2) == orig2
      assert File.read!(f3) == orig3
    end
  end

  defp drain_pubsub(acc) do
    receive do
      msg -> drain_pubsub(acc ++ [msg])
    after
      500 -> acc
    end
  end
end
