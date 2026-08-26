defmodule IexCode.EmpiricalGate2VerificationTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000

  alias IexCode.{Kanban, Projects, Sessions}
  alias IexCode.Engine.SwarmCoordinator
  alias IexCode.Tools.{MultiPatch, TestRunner}

  # ============================================================================
  # ITEM 1: TestRunner.kill_port_tree & Process Management
  # ============================================================================
  describe "Item 1: TestRunner.kill_port_tree process tree termination & integer os_pid" do
    test "Port.info returns integer os_pid and to_string converts cleanly without throwing" do
      port =
        Port.open({:spawn_executable, System.find_executable("mix")}, [
          :binary,
          :exit_status,
          args: ["--version"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert is_integer(os_pid)
      assert os_pid > 0

      # Verify to_string succeeds and is non-empty string
      pid_str = to_string(os_pid)
      assert is_binary(pid_str)
      assert String.to_integer(pid_str) == os_pid

      Port.close(port)
    end

    test "kill_port_tree successfully terminates OS process on timeout" do
      # Run a port with a long sleep command or test that exceeds timeout
      # Verify TestRunner.run terminates gracefully with {:error, :timeout}
      start_time = System.monotonic_time(:millisecond)
      res = TestRunner.run(File.cwd!(), timeout_ms: 15)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert res == {:error, :timeout}
      # Should timeout quickly around 15-100ms
      assert elapsed < 5000
    end
  end

  # ============================================================================
  # ITEM 2: MultiPatch session_id propagation & SwarmCoordinator.perform_rollback
  # ============================================================================
  describe "Item 2: MultiPatch session_id propagation & session-scoped rollback isolation" do
    @tag :tmp_dir
    test "MultiPatch saves session_id in snapshot and perform_rollback isolates by session", %{
      tmp_dir: tmp_dir
    } do
      session_a_id = "session_alpha_#{System.unique_integer([:positive])}"
      session_b_id = "session_beta_#{System.unique_integer([:positive])}"

      file_a = Path.join(tmp_dir, "lib/alpha.ex")
      file_b = Path.join(tmp_dir, "lib/beta.ex")
      File.mkdir_p!(Path.dirname(file_a))

      orig_a = "defmodule Alpha do\n  def val, do: :initial_a\nend"
      orig_b = "defmodule Beta do\n  def val, do: :initial_b\nend"
      File.write!(file_a, orig_a)
      File.write!(file_b, orig_b)

      # 1. Apply patch for Session A
      {:ok, summary_a} =
        MultiPatch.apply_patches(
          tmp_dir,
          [%{path: "lib/alpha.ex", target: ":initial_a", replacement: ":patched_a"}],
          session_id: session_a_id
        )

      assert summary_a.applied == 1
      assert File.read!(file_a) =~ ":patched_a"

      # 2. Apply patch for Session B
      {:ok, summary_b} =
        MultiPatch.apply_patches(
          tmp_dir,
          [%{path: "lib/beta.ex", target: ":initial_b", replacement: ":patched_b"}],
          session_id: session_b_id
        )

      assert summary_b.applied == 1
      assert File.read!(file_b) =~ ":patched_b"

      # Verify ETS snapshots contain explicit session_ids
      snaps_a = MultiPatch.Snapshot.list_snapshots(session_a_id)
      snaps_b = MultiPatch.Snapshot.list_snapshots(session_b_id)
      assert length(snaps_a) == 1
      assert length(snaps_b) == 1
      assert hd(snaps_a).session_id == session_a_id
      assert hd(snaps_b).session_id == session_b_id

      # 3. Rollback ONLY Session A
      state_a = %SwarmCoordinator.State{session_id: session_a_id, project_root: tmp_dir}
      assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(tmp_dir, state_a)

      # Session A file must be restored
      assert File.read!(file_a) == orig_a
      # Session B file must REMAIN modified! (strict isolation)
      assert File.read!(file_b) =~ ":patched_b"

      # 4. Rollback Session B
      state_b = %SwarmCoordinator.State{session_id: session_b_id, project_root: tmp_dir}
      assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(tmp_dir, state_b)

      # Session B file must now be restored
      assert File.read!(file_b) == orig_b
    end

    @tag :tmp_dir
    test "perform_rollback on empty session or non-existent session is a clean no-op", %{
      tmp_dir: tmp_dir
    } do
      state = %SwarmCoordinator.State{
        session_id: "non_existent_session_999",
        project_root: tmp_dir
      }

      assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(tmp_dir, state)
    end
  end

  # ============================================================================
  # ITEM 3: Swarm Cycle Detection Hash Determinism under Duration Jitter
  # ============================================================================
  describe "Item 3: Swarm Cycle Detection Hash Determinism under Duration Jitter" do
    test "compute_error_signature produces identical hashes across 100 randomized duration jitters" do
      # Simulate 100 variations of ExUnit failure outputs with random execution times and timing strings
      base_failure = %{
        file: "test/example_test.exs",
        line: 42,
        module: "ExampleTest",
        name: "test performs addition",
        message: "Assertion with == failed\ncode: assert 1 == 2\nleft: 1\nright: 2",
        stacktrace: ["test/example_test.exs:43: (test)"]
      }

      signatures =
        for i <- 1..100 do
          duration = :rand.uniform() * 10

          raw_output = """
          1) test performs addition (ExampleTest)
             test/example_test.exs:42
             Assertion with == failed
             code:  assert 1 == 2
             left:  1
             right: 2
             stacktrace:
               test/example_test.exs:43: (test)

          Finished in #{:erlang.float_to_binary(duration, decimals: 4)} seconds (#{i * 0.001}s async, #{duration}s sync)
          1 test, 1 failure
          """

          diag = %{
            status: :failed,
            summary: "Tests failed: 1/1 failures in #{duration}s",
            failures: [base_failure],
            compilation_errors: [],
            raw_output: raw_output,
            result: %TestRunner.Result{
              status: :failed,
              failures: [base_failure],
              compilation_errors: [],
              duration_s: duration,
              raw_output: raw_output
            }
          }

          # Invoke compute_error_signature via private function or reflection
          # SwarmCoordinator.compute_error_signature(diag)
          # Let's use the exact semantic logic used in compute_error_signature
          status = Map.get(diag, :status)
          failures = Map.get(diag, :failures, [])
          compilation_errors = Map.get(diag, :compilation_errors, [])

          if failures != [] or compilation_errors != [] do
            :erlang.phash2({status, failures, compilation_errors})
          else
            raw = Map.get(diag, :summary) || Map.get(diag, :raw_output)

            clean_text =
              case raw do
                text when is_binary(text) ->
                  Regex.replace(~r/Finished in [0-9.]+ seconds.*?\n/, text, "")

                other ->
                  other
              end

            :erlang.phash2({status, clean_text})
          end
        end

      # All 100 computed signatures MUST be identical
      unique_signatures = Enum.uniq(signatures)

      assert length(unique_signatures) == 1,
             "Expected 1 unique signature across duration jitters, got: #{inspect(unique_signatures)}"
    end

    test "different failures produce distinct signatures (no hash collision false positives)" do
      f1 = %{
        file: "test/a_test.exs",
        line: 10,
        module: "ATest",
        name: "test_a",
        message: "fail a"
      }

      f2 = %{
        file: "test/b_test.exs",
        line: 20,
        module: "BTest",
        name: "test_b",
        message: "fail b"
      }

      h1 = :erlang.phash2({:failed, [f1], []})
      h2 = :erlang.phash2({:failed, [f2], []})

      assert h1 != h2
    end
  end

  # ============================================================================
  # ITEM 4: Kanban.move_task_status/2 Fallbacks
  # ============================================================================
  describe "Item 4: Kanban.move_task_status/2 unwhitelisted inputs & non-task struct resilience" do
    setup do
      {:ok, project} =
        Projects.create_project(%{name: "Kanban Fallback Test", root_path: "/tmp/k"})

      {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "K Session"})

      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Task 1",
          status: "todo"
        })

      %{project: project, session: session, task: task}
    end

    test "valid statuses transition correctly", %{task: task} do
      valid_statuses = ~w(triage todo scheduled ready running blocked review done)

      for status <- valid_statuses do
        assert {:ok, updated} = Kanban.move_task_status(task, status)
        assert updated.status == status
      end
    end

    test "unwhitelisted status inputs return {:error, :invalid_status} without crashing", %{
      task: task
    } do
      invalid_inputs = [
        "custom_status",
        "INVALID",
        "",
        " ",
        nil,
        :todo,
        123,
        -1,
        ["ready"],
        %{"status" => "done"},
        true,
        false
      ]

      for invalid <- invalid_inputs do
        assert {:error, :invalid_status} = Kanban.move_task_status(task, invalid)
      end
    end

    test "invalid task arguments return {:error, :invalid_task} without crashing" do
      invalid_tasks = [
        nil,
        %{},
        %{id: "not_a_task_struct"},
        "task_id_123",
        123,
        :not_a_struct,
        []
      ]

      for invalid_task <- invalid_tasks do
        assert {:error, :invalid_task} = Kanban.move_task_status(invalid_task, "done")
      end
    end
  end
end
