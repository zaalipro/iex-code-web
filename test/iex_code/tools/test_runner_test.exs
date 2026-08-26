defmodule IexCode.Tools.TestRunnerTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.TestRunner
  alias IexCode.Tools.TestRunner.Result

  describe "run/1 and run_file/3" do
    @tag :tmp_dir
    test "executes live test suite on a temporary mix project", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)

      assert {:ok, %Result{} = result} =
               TestRunner.run(project_root: tmp_dir, paths: ["test/sample_test.exs"])

      assert result.status == :passed
      assert result.total == 1
      assert result.failures_count == 0
    end

    @tag :tmp_dir
    test "executes with progress callback", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_progress = fn pct, msg ->
        Agent.update(agent, fn list -> [{pct, msg} | list] end)
      end

      assert {:ok, %Result{}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/sample_test.exs"],
                 on_progress: on_progress
               )

      progress_events = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert length(progress_events) >= 2
      assert Enum.any?(progress_events, fn {pct, _} -> pct == 100 end)
    end

    test "handles execution timeout gracefully" do
      # Run with 1ms timeout to force timeout
      assert {:error, :timeout} =
               TestRunner.run(
                 paths: ["test/sample_test.exs"],
                 timeout_ms: 1
               )
    end
  end

  defp setup_temp_project(tmp_dir) do
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
    File.write!(Path.join(test_dir, "test_helper.exs"), "ExUnit.start()")

    File.write!(Path.join(test_dir, "sample_test.exs"), """
    defmodule SampleTest do
      use ExUnit.Case
      test "truth" do
        assert 1 + 1 == 2
      end
    end
    """)
  end
end
