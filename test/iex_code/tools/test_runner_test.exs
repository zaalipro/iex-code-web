defmodule IexCode.Tools.TestRunnerTest do
  use IexCode.DataCase, async: false

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Outputs
  alias IexCode.Tools.TestRunner
  alias IexCode.Tools.TestRunner.Result

  setup do
    governor =
      start_supervised!(
        Supervisor.child_spec(
          {ResourceGovernor, name: nil, poll_interval_ms: 60_000, read_memory: fn -> %{} end},
          id: make_ref()
        )
      )

    %{governor: governor}
  end

  describe "run/1 and run_file/3" do
    @tag :tmp_dir
    test "executes live test suite on a temporary mix project", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir)

      assert {:ok, %Result{} = result} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/sample_test.exs"],
                 resource_governor: governor,
                 output_opts: output_opts(tmp_dir)
               )

      assert result.status == :passed, result.raw_output
      assert result.total == 1
      assert result.failures_count == 0
      assert is_binary(result.artifact_id)
      assert result.output_bytes > 0
      assert %IexCode.Outputs.OutputArtifact{status: "ready"} = Outputs.get(result.artifact_id)
    end

    @tag :tmp_dir
    test "executes with progress callback", %{tmp_dir: tmp_dir, governor: governor} do
      setup_temp_project(tmp_dir)
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_progress = fn pct, msg ->
        Agent.update(agent, fn list -> [{pct, msg} | list] end)
      end

      assert {:ok, %Result{}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/sample_test.exs"],
                 resource_governor: governor,
                 output_opts: output_opts(tmp_dir),
                 on_progress: on_progress
               )

      progress_events = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert length(progress_events) >= 2
      assert Enum.any?(progress_events, fn {pct, _} -> pct == 100 end)
    end

    @tag :tmp_dir
    test "handles execution timeout gracefully", %{tmp_dir: tmp_dir, governor: governor} do
      # Run with 1ms timeout to force timeout
      assert {:error, :timeout} =
               TestRunner.run(
                 paths: ["test/sample_test.exs"],
                 resource_governor: governor,
                 timeout_ms: 1,
                 output_opts: output_opts(tmp_dir)
               )
    end

    @tag :tmp_dir
    test "retains a bounded preview and persists complete output", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir, String.duplicate("x", 8_192))

      assert {:ok, %Result{} = result} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 output_opts: output_opts(tmp_dir, preview_bytes: 64, limit_bytes: 32_768)
               )

      assert result.status == :passed, result.raw_output
      assert result.output_truncated?
      assert byte_size(result.raw_output) < 512

      artifact = Outputs.get(result.artifact_id)
      assert artifact.byte_size == result.output_bytes
      assert artifact.byte_size > byte_size(result.raw_output)
      assert {:ok, chunk} = Outputs.read_chunk(artifact, 0, 1_024, root: tmp_dir)
      assert byte_size(chunk) == 1_024
    end

    @tag :tmp_dir
    test "captures a middle failure despite more than 64 KiB of noise on both sides", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir)
      noise = String.duplicate("verbose-noise-0123456789\n", 3_000)

      diagnostic = """

        1) test middle diagnostic survives (MiddleFailureTest)
           test/middle_failure_test.exs:42
           Assertion with == failed
           code:  assert actual == expected
           left:  :actual_middle_value
           right: :expected_middle_value
           stacktrace:
             test/middle_failure_test.exs:42: (test)

      """

      File.write!(Path.join(tmp_dir, "test/test_helper.exs"), """
      IO.write(#{inspect(noise, limit: :infinity, printable_limit: :infinity)})
      IO.write(#{inspect(diagnostic)})
      IO.write(#{inspect(noise, limit: :infinity, printable_limit: :infinity)})
      IO.write("Finished in 0.1 seconds\n1 test, 1 failure\n")
      System.halt(1)
      """)

      assert {:ok, %Result{} = result} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 output_opts:
                   output_opts(tmp_dir,
                     preview_bytes: 64 * 1_024,
                     limit_bytes: 512 * 1_024,
                     global_quota_bytes: 1_048_576
                   )
               )

      assert result.status == :failed
      assert result.failures_count == 1
      assert [%{module: "MiddleFailureTest", line: 42} = failure] = result.failures
      assert failure.left =~ "actual_middle_value"
      assert failure.right =~ "expected_middle_value"
      assert result.raw_output =~ "bounded diagnostics captured"
      assert byte_size(result.raw_output) < 700 * 1_024
    end

    @tag :tmp_dir
    test "terminates the producer and returns the limit-exceeded artifact id", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir, String.duplicate("limit-me", 4_096))

      assert {:error, {:output_limit_exceeded, artifact_id}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 output_opts: output_opts(tmp_dir, preview_bytes: 32, limit_bytes: 512)
               )

      assert %{status: "limit_exceeded", byte_size: 512, limit_bytes: 512} =
               Outputs.get(artifact_id)
    end

    @tag :tmp_dir
    test "output limit kills every descendant in the tracked process group", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir)
      pid_file = Path.join(tmp_dir, "limit-child.pid")
      write_descendant_helper(tmp_dir, pid_file, :flood)

      assert {:error, {:output_limit_exceeded, _artifact_id}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 output_opts: output_opts(tmp_dir, preview_bytes: 32, limit_bytes: 2_048)
               )

      assert_dead_pid_file(pid_file)
    end

    @tag :tmp_dir
    test "deadline cannot be starved by output and kills every descendant", %{
      tmp_dir: tmp_dir,
      governor: governor
    } do
      setup_temp_project(tmp_dir)
      pid_file = Path.join(tmp_dir, "timeout-child.pid")
      write_descendant_helper(tmp_dir, pid_file, :steady)

      started_at = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 timeout_ms: 1_500,
                 output_opts:
                   output_opts(tmp_dir,
                     limit_bytes: 64 * 1_024 * 1_024,
                     global_quota_bytes: 128 * 1_024 * 1_024
                   )
               )

      assert System.monotonic_time(:millisecond) - started_at < 5_000
      assert_dead_pid_file(pid_file)
    end

    @tag :tmp_dir
    test "waits for build-test admission before creating output", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)

      governor =
        start_supervised!(
          Supervisor.child_spec(
            {ResourceGovernor,
             name: nil,
             poll_interval_ms: 60_000,
             read_memory: fn ->
               %{memory_current_bytes: 800, memory_limit_bytes: 1_000}
             end},
            id: make_ref()
          )
        )

      assert {:error, :capacity_timeout} =
               TestRunner.run(
                 project_root: tmp_dir,
                 resource_governor: governor,
                 resource_timeout: 10,
                 output_opts: output_opts(tmp_dir)
               )
    end
  end

  defp setup_temp_project(tmp_dir, printed_output \\ nil) do
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule TempApp.MixProject do
      use Mix.Project
      def project do
        [app: :temp_app, version: "0.1.0"]
      end
    end
    """)

    test_dir = Path.join(tmp_dir, "test")
    File.mkdir_p!(test_dir)

    helper =
      if printed_output do
        literal = inspect(printed_output, limit: :infinity, printable_limit: :infinity)
        "IO.write(#{literal})\nExUnit.start()"
      else
        "ExUnit.start()"
      end

    File.write!(Path.join(test_dir, "test_helper.exs"), helper)

    File.write!(Path.join(test_dir, "sample_test.exs"), """
    defmodule SampleTest do
      use ExUnit.Case
      test "truth" do
        assert 1 + 1 == 2
      end
    end
    """)
  end

  defp write_descendant_helper(tmp_dir, pid_file, mode) do
    chunk =
      case mode do
        :flood -> String.duplicate("0123456789abcdef", 256)
        :steady -> "x"
      end

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), """
    sleep = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["60"]])
    {:os_pid, child_pid} = Port.info(sleep, :os_pid)
    File.write!(#{inspect(pid_file)}, Integer.to_string(child_pid))
    Stream.repeatedly(fn -> IO.write(#{inspect(chunk)}) end) |> Stream.run()
    """)
  end

  defp assert_dead_pid_file(pid_file) do
    child_pid = pid_file |> File.read!() |> String.trim()

    case System.cmd("ps", ["-o", "stat=", "-p", child_pid], stderr_to_stdout: true) do
      {_, status} when status != 0 -> :ok
      {state, 0} -> assert String.trim(state) |> String.starts_with?("Z")
    end
  end

  defp output_opts(root, overrides \\ []) do
    Keyword.merge(
      [
        root: root,
        min_free_bytes: 1,
        free_bytes: fn _root -> 1_073_741_824 end,
        limit_bytes: 128 * 1_024,
        global_quota_bytes: 1_048_576
      ],
      overrides
    )
  end
end
