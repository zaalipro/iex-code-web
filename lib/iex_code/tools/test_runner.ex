defmodule IexCode.Tools.TestRunner do
  @moduledoc """
  Automated test execution engine for Mix and ExUnit test suites.

  Test output is streamed to a bounded, file-backed artifact. Only a fixed-size
  head/tail preview is retained in the runner process.
  """

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Outputs
  alias IexCode.Outputs.Writer
  alias IexCode.Tools.TestRunner.{DiagnosticCapture, Parser, Result}

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
          resource_priority: ResourceGovernor.priority(),
          resource_run_key: term(),
          run_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          operation_id: Ecto.UUID.t(),
          output_opts: keyword(),
          resource_governor: GenServer.server(),
          on_progress: (non_neg_integer(), String.t() -> any())
        ]

  @spec run(run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(opts) when is_list(opts), do: run(Keyword.get(opts, :project_root, File.cwd!()), opts)

  @spec run(Path.t(), run_opts()) :: {:ok, Result.t()} | {:error, term()}
  def run(project_root, opts) when is_binary(project_root) and is_list(opts) do
    governor_opts = ResourceGovernor.admission_opts(opts, priority: :background)

    ResourceGovernor.with_permit(:build_test, governor_opts, fn -> do_run(project_root, opts) end)
  end

  @spec run_file(Path.t(), pos_integer() | nil, run_opts()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_file(file_path, line \\ nil, opts \\ []) do
    opts = opts |> Keyword.put(:paths, [file_path]) |> Keyword.put(:line, line)
    run(opts)
  end

  defp do_run(project_root, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    on_progress = Keyword.get(opts, :on_progress, fn _pct, _msg -> :ok end)
    env = Keyword.get(opts, :env, %{"MIX_ENV" => "test"})

    attrs = %{
      run_id: opts[:run_id],
      session_id: opts[:session_id],
      operation_id: opts[:operation_id],
      kind: "test_output",
      name: "mix-test.log",
      metadata: %{"project_root" => Path.expand(project_root)}
    }

    with {:ok, writer} <- Outputs.open_writer(attrs, opts[:output_opts] || []) do
      on_progress.(10, "Starting mix test in #{project_root}...")

      case run_mix_test(build_mix_test_args(opts), project_root, env, timeout_ms, writer) do
        {:ok, writer, exit_code} ->
          status = if exit_code == 0, do: :ready, else: :failed

          with {:ok, artifact} <- Outputs.finish(writer, status, %{"exit_code" => exit_code}) do
            on_progress.(80, "Parsing test results...")

            result =
              writer
              |> parser_input()
              |> String.replace_invalid()
              |> Parser.parse(exit_code)
              |> Map.put(:artifact_id, artifact.id)
              |> Map.put(:output_bytes, artifact.byte_size)
              |> Map.put(:output_truncated?, artifact.byte_size > preview_size(writer))

            on_progress.(
              100,
              "Completed test run (#{result.total} tests, #{result.failures_count} failures)"
            )

            {:ok, result}
          end

        {:error, :timeout, writer} ->
          _ = Outputs.finish(writer, :failed, %{"reason" => "timeout"})
          on_progress.(100, "Test execution timed out after #{timeout_ms}ms")
          {:error, :timeout}

        {:error, :output_limit_exceeded, writer} ->
          case Outputs.finish(writer, :limit_exceeded, %{"reason" => "output_limit_exceeded"}) do
            {:ok, artifact} ->
              on_progress.(100, "Test output exceeded its configured limit")
              {:error, {:output_limit_exceeded, artifact.id}}

            {:error, reason} ->
              {:error, {:output_limit_exceeded, writer.artifact_id, reason}}
          end

        {:error, reason, writer} ->
          _ = Outputs.finish(writer, :failed, %{"reason" => inspect(reason)})
          on_progress.(100, "Test execution failed: #{inspect(reason)}")
          {:error, reason}

        {:start_error, reason, writer} ->
          _ = Outputs.discard(writer)
          on_progress.(100, "Test execution could not start: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp run_mix_test(args, project_root, env, timeout_ms, writer) do
    case System.find_executable("mix") do
      nil ->
        {:error, :mix_not_found, writer}

      mix_path ->
        with {:ok, python, runner} <- command_runner() do
          port =
            Port.open({:spawn_executable, python}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :hide,
              cd: Path.expand(project_root),
              args: [runner, "--exec", mix_path | args],
              env: port_env(env)
            ])

          os_pid = port |> Port.info(:os_pid) |> elem(1)
          deadline = System.monotonic_time(:millisecond) + timeout_ms
          collect_port_output(port, os_pid, deadline, writer)
        else
          {:error, reason} -> {:start_error, reason, writer}
        end
    end
  rescue
    error -> {:start_error, {:command_start_failed, error}, writer}
  end

  defp command_runner do
    case {System.find_executable("python3"), runner_path()} do
      {python, runner} when is_binary(python) and is_binary(runner) -> {:ok, python, runner}
      _missing -> {:error, :command_runner_unavailable}
    end
  end

  defp runner_path do
    case :code.priv_dir(:iex_code) do
      {:error, :bad_name} -> Path.expand("priv/command_runner.py")
      directory -> Path.join(to_string(directory), "command_runner.py")
    end
  end

  defp port_env(env),
    do: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

  defp collect_port_output(port, os_pid, deadline, writer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      terminate(port, os_pid, :timeout, writer)
    else
      receive do
        {^port, {:data, data}} ->
          case Outputs.append(writer, data) do
            {:ok, writer} ->
              collect_port_output(port, os_pid, deadline, writer)

            {:limit_exceeded, writer} ->
              terminate(port, os_pid, :output_limit_exceeded, writer)

            {:error, reason} ->
              terminate(port, os_pid, {:output_spool_failed, reason}, writer)
          end

        {^port, {:exit_status, code}} ->
          {:ok, writer, code}

        {:EXIT, ^port, _reason} ->
          {:ok, writer, 1}
      after
        remaining -> terminate(port, os_pid, :timeout, writer)
      end
    end
  end

  defp terminate(port, os_pid, reason, writer) do
    kill_port_tree(port, os_pid)
    {:error, reason, writer}
  end

  # command_runner.py establishes a private group and execs the Mix executable
  # in the same tracked PID, so the group leader cannot race or fork away.
  # BEAM Port children may establish their own groups, so walk descendants
  # before terminating the root group as well.
  defp kill_port_tree(port, os_pid) do
    kill_descendants(os_pid)
    kill_group(os_pid, "-TERM")
    kill_group(os_pid, "-KILL")
    close_port(port)
  rescue
    _error -> :ok
  catch
    _, _ -> :ok
  end

  defp kill_group(pid, signal) do
    _ = System.cmd("kill", [signal, "--", "-#{pid}"], stderr_to_stdout: true)
    :ok
  end

  defp kill_descendants(pid) do
    children =
      case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(fn value ->
            case Integer.parse(value) do
              {child, ""} when child > 0 -> [child]
              _invalid -> []
            end
          end)

        _other ->
          []
      end

    Enum.each(children, fn child ->
      kill_descendants(child)
      kill_pid(child, "-KILL")
    end)
  end

  defp kill_pid(pid, signal) do
    _ = System.cmd("kill", [signal, to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp close_port(port) do
    if is_port(port) and Port.info(port) do
      Port.close(port)
    end
  end

  defp output_preview(%Writer{} = writer) do
    cond do
      writer.bytes <= writer.preview_bytes ->
        writer.head

      writer.bytes <= writer.preview_bytes * 2 ->
        overlap = writer.preview_bytes * 2 - writer.bytes
        writer.head <> binary_part(writer.tail, overlap, byte_size(writer.tail) - overlap)

      true ->
        writer.head <>
          "\n\n--- output omitted; full output is available in artifact #{writer.artifact_id} ---\n\n" <>
          writer.tail
    end
  end

  defp parser_input(%Writer{} = writer) do
    preview = output_preview(writer)

    case DiagnosticCapture.from_file(writer.final_path) do
      "" ->
        preview

      diagnostics ->
        "--- bounded diagnostics captured across full output ---\n" <>
          diagnostics <> "\n\n" <> preview
    end
  end

  defp preview_size(writer), do: min(writer.bytes, writer.preview_bytes * 2)

  defp build_mix_test_args(opts) do
    paths_args =
      case Keyword.get(opts, :paths) do
        nil -> []
        path when is_binary(path) -> path_args([path], Keyword.get(opts, :line))
        paths when is_list(paths) -> path_args(paths, Keyword.get(opts, :line))
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

    ["test", "--color"] ++ flag_args ++ paths_args
  end

  defp path_args([single], line) when is_integer(line) do
    if String.contains?(single, ":"), do: [single], else: ["#{single}:#{line}"]
  end

  defp path_args(paths, _line), do: paths

  defp add_bool_flag(acc, opts, key, flag),
    do: if(Keyword.get(opts, key) == true, do: acc ++ [flag], else: acc)

  defp add_val_flag(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      val when val != nil and val != "" -> acc ++ [flag, to_string(val)]
      _other -> acc
    end
  end

  defp add_tag_flags(acc, opts, key, flag) do
    case Keyword.get(opts, key) do
      tags when is_list(tags) ->
        Enum.reduce(tags, acc, fn tag, list -> list ++ [flag, to_string(tag)] end)

      tag when tag != nil and tag != "" ->
        acc ++ [flag, to_string(tag)]

      _other ->
        acc
    end
  end
end
