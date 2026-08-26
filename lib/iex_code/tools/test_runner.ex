defmodule IexCode.Tools.TestRunner do
  @moduledoc """
  Automated test execution engine for Mix and ExUnit test suites.
  Executes tests inside the project workspace with timeout controls,
  progress reporting, file/line filters, and structured failure parsing.
  """

  alias IexCode.Tools.TestRunner.{Parser, Result}

  @type run_opts :: [
          project_root: Path.t(),
          paths: [Path.t()] | Path.t(),
          line: pos_integer() | nil,
          failed: boolean(),
          stale: boolean(),
          seed: integer() | nil,
          max_failures: integer() | nil,
          include: String.t() | atom() | [String.t() | atom()],
          exclude: String.t() | atom() | [String.t() | atom()],
          only: String.t() | atom() | [String.t() | atom()],
          trace: boolean(),
          timeout_ms: integer(),
          env: %{String.t() => String.t()},
          on_progress: (non_neg_integer(), String.t() -> any())
        ]

  @doc """
  Runs `mix test` with the provided options.
  """
  @spec run(run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(opts) when is_list(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    run(project_root, opts)
  end

  @doc """
  Runs `mix test` inside `project_root` with the provided options.
  """
  @spec run(Path.t(), run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(project_root, opts) when is_binary(project_root) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    on_progress = Keyword.get(opts, :on_progress, fn _pct, _msg -> :ok end)
    env = Keyword.get(opts, :env, %{"MIX_ENV" => "test"})

    args = build_mix_test_args(opts)

    on_progress.(10, "Starting mix test in #{project_root}...")

    case run_mix_test(args, project_root, env, timeout_ms) do
      {:ok, {raw_output, exit_code}} ->
        on_progress.(80, "Parsing test results...")
        result = Parser.parse(raw_output, exit_code)

        on_progress.(
          100,
          "Completed test run (#{result.total} tests, #{result.failures_count} failures)"
        )

        {:ok, result}

      {:error, :timeout} ->
        on_progress.(100, "Test execution timed out after #{timeout_ms}ms")
        {:error, :timeout}

      {:error, reason} ->
        on_progress.(100, "Test execution failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Shortcut to run a specific test file and optional line number.
  """
  @spec run_file(Path.t(), pos_integer() | nil, run_opts()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_file(file_path, line \\ nil, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:paths, [file_path])
      |> Keyword.put(:line, line)

    run(opts)
  end

  # --- Internal Helpers ---

  # Runs `mix test` through a Port so that on timeout we can kill the whole
  # OS process tree (System.cmd gives no handle to the spawned process).
  defp run_mix_test(args, project_root, env, timeout_ms) do
    case System.find_executable("mix") do
      nil ->
        {:error, :mix_not_found}

      mix_path ->
        port =
          Port.open(
            {:spawn_executable, mix_path},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :hide,
              cd: Path.expand(project_root),
              args: args,
              env: port_env(env)
            ]
          )

        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect_port_output(port, deadline, [], nil)
    end
  end

  defp port_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp collect_port_output(port, deadline, acc, status) do
    now = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, deadline, [data | acc], status)

      {^port, {:exit_status, code}} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}}

      {:EXIT, ^port, _reason} ->
        {:ok, {acc |> Enum.reverse() |> IO.iodata_to_binary(), status || 1}}
    after
      max(0, deadline - now) ->
        kill_port_tree(port)
        {:error, :timeout}
    end
  end

  # Best-effort: kill child processes first, then the mix/erl process itself.
  defp kill_port_tree(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> to_string(pid)
        {:os_pid, pid} when is_binary(pid) -> pid
        _ -> nil
      end

    if os_pid do
      System.cmd("pkill", ["-9", "-P", os_pid], stderr_to_stdout: true)
      System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_mix_test_args(opts) do
    base_args = ["test", "--color"]

    paths_args =
      case Keyword.get(opts, :paths) do
        nil ->
          []

        path when is_binary(path) ->
          line = Keyword.get(opts, :line)

          if is_integer(line) and not String.contains?(path, ":") do
            ["#{path}:#{line}"]
          else
            [path]
          end

        paths when is_list(paths) ->
          line = Keyword.get(opts, :line)

          if length(paths) == 1 and is_integer(line) do
            single = hd(paths)

            if not String.contains?(single, ":") do
              ["#{single}:#{line}"]
            else
              paths
            end
          else
            paths
          end
      end

    flag_args =
      []
      |> add_bool_flag(opts, :failed, "--failed")
      |> add_bool_flag(opts, :stale, "--stale")
      |> add_bool_flag(opts, :trace, "--trace")
      |> add_val_flag(opts, :seed, "--seed")
      |> add_val_flag(opts, :max_failures, "--max-failures")
      |> add_tag_flags(opts, :include, "--include")
      |> add_tag_flags(opts, :exclude, "--exclude")
      |> add_tag_flags(opts, :only, "--only")

    base_args ++ flag_args ++ paths_args
  end

  defp add_bool_flag(acc, opts, key, flag) do
    if Keyword.get(opts, key) == true, do: acc ++ [flag], else: acc
  end

  defp add_val_flag(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      val when val != nil and val != "" -> acc ++ [flag, to_string(val)]
      _ -> acc
    end
  end

  defp add_tag_flags(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      tags when is_list(tags) ->
        Enum.reduce(tags, acc, fn t, a -> a ++ [flag, to_string(t)] end)

      tag when tag != nil and tag != "" ->
        acc ++ [flag, to_string(tag)]

      _ ->
        acc
    end
  end
end
