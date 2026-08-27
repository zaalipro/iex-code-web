defmodule IexCode.Tools.NativeCommand do
  @moduledoc false

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Outputs
  alias IexCode.Outputs.{OutputArtifact, Writer}
  alias IexCode.Tools.PTYAdapter

  @default_limit_bytes 256 * 1_048_576
  @test_preview_bytes 256_000

  @spec run(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(command, cwd, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_list(opts) do
    governor_opts = ResourceGovernor.admission_opts(opts, priority: :background)

    ResourceGovernor.with_permit(:native_command, governor_opts, fn ->
      do_run(command, cwd, opts)
    end)
  end

  defp do_run(command, cwd, opts) do
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, 30_000))

    with {:ok, writer} <- open_output(opts) do
      case open_port(command, cwd) do
        {:ok, port, os_pid} ->
          deadline = System.monotonic_time(:millisecond) + timeout_ms

          case collect(port, os_pid, writer, deadline) do
            {:done, exit_code, writer} -> finish_success(writer, exit_code)
            {:limit_exceeded, writer} -> finish_limit_exceeded(writer)
            {:timeout, writer} -> finish_timeout(writer)
            {:capture_error, writer, reason} -> finish_capture_error(writer, reason)
          end

        {:error, reason} ->
          discard(writer)
          {:error, reason}
      end
    end
  end

  defp open_output(opts) do
    config = Application.get_env(:iex_code, :output_artifacts, [])

    if Keyword.get(opts, :output_artifact, Keyword.get(config, :enabled, true)) do
      attrs = %{
        run_id: Keyword.get(opts, :run_id),
        session_id: Keyword.get(opts, :session_id),
        operation_id: Keyword.get(opts, :operation_id),
        kind: "native_command_output",
        name: "command.log",
        metadata: %{"source" => "run_command"}
      }

      output_options = Keyword.get(opts, :output_options, [])

      output_options =
        case Keyword.get(opts, :output_limit_bytes) do
          bytes when is_integer(bytes) and bytes > 0 ->
            Keyword.put(output_options, :limit_bytes, bytes)

          _other ->
            output_options
        end

      case Outputs.open_writer(attrs, output_options) do
        {:ok, writer} -> {:ok, writer}
        {:error, reason} -> {:error, {:output_artifact_unavailable, reason}}
      end
    else
      {:ok,
       %{
         fallback?: true,
         bytes: 0,
         head: "",
         tail: "",
         limit_bytes: Keyword.get(opts, :output_limit_bytes, @default_limit_bytes),
         preview_bytes: @test_preview_bytes
       }}
    end
  end

  defp open_port(command, cwd) do
    with python when is_binary(python) <- System.find_executable("python3"),
         runner when is_binary(runner) <- runner_path() do
      port =
        Port.open(
          {:spawn_executable, python},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: [runner, command],
            cd: cwd
          ]
        )

      {:ok, port, Port.info(port, :os_pid) |> elem(1)}
    else
      _missing -> {:error, :command_runner_unavailable}
    end
  rescue
    error -> {:error, {:command_start_failed, error}}
  end

  defp collect(port, os_pid, writer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      terminate(port, os_pid)
      {:timeout, writer}
    else
      receive do
        {^port, {:data, data}} ->
          case append(writer, data) do
            {:ok, writer} ->
              collect(port, os_pid, writer, deadline)

            {:limit_exceeded, writer} ->
              terminate(port, os_pid)
              {:limit_exceeded, writer}

            {:error, reason} ->
              terminate(port, os_pid)
              {:capture_error, writer, reason}
          end

        {^port, {:exit_status, status}} ->
          drain(port, os_pid, writer, status)
      after
        remaining ->
          terminate(port, os_pid)
          {:timeout, writer}
      end
    end
  end

  defp drain(port, os_pid, writer, status) do
    receive do
      {^port, {:data, data}} ->
        case append(writer, data) do
          {:ok, writer} ->
            drain(port, os_pid, writer, status)

          {:limit_exceeded, writer} ->
            terminate(port, os_pid)
            {:limit_exceeded, writer}

          {:error, reason} ->
            terminate(port, os_pid)
            {:capture_error, writer, reason}
        end
    after
      0 -> {:done, status, writer}
    end
  end

  defp terminate(port, os_pid) do
    _ = PTYAdapter.terminate_process_group(os_pid, :sigkill)

    if is_port(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp finish_success(writer, exit_code) do
    with {:ok, artifact} <- finish(writer, :ready, %{"exit_code" => exit_code}) do
      {:ok, result(artifact, exit_code)}
    end
  end

  defp finish_limit_exceeded(writer) do
    case finish(writer, :limit_exceeded, %{"reason" => "output_limit_exceeded"}) do
      {:ok, artifact} -> {:error, {:output_limit_exceeded, artifact_id(artifact)}}
      {:error, _reason} -> {:error, :output_limit_exceeded}
    end
  end

  defp finish_timeout(writer) do
    case finish(writer, :failed, %{"reason" => "timeout"}) do
      {:ok, artifact} -> {:error, {:timeout, artifact_id(artifact), preview(artifact)}}
      {:error, _reason} -> {:error, :timeout}
    end
  end

  defp finish_capture_error(writer, reason) do
    _ = finish(writer, :failed, %{"reason" => "capture_error"})
    {:error, {:output_capture_failed, reason}}
  end

  defp result(artifact, exit_code) do
    %{
      output: preview(artifact),
      exit_code: exit_code,
      artifact_id: artifact_id(artifact),
      output_bytes: artifact_bytes(artifact),
      output_truncated?: truncated?(artifact)
    }
  end

  defp append(%Writer{} = writer, data), do: Outputs.append(writer, data)

  defp append(%{fallback?: true} = writer, data) do
    remaining = max(writer.limit_bytes - writer.bytes, 0)
    accepted_size = min(byte_size(data), remaining)
    accepted = binary_part(data, 0, accepted_size)
    writer = fallback_account(writer, accepted)

    if accepted_size == byte_size(data),
      do: {:ok, writer},
      else: {:limit_exceeded, writer}
  end

  defp fallback_account(writer, data) do
    head_space = max(writer.preview_bytes - byte_size(writer.head), 0)
    head = writer.head <> binary_part(data, 0, min(byte_size(data), head_space))
    tail = fallback_tail(writer.tail, data, writer.preview_bytes)
    %{writer | bytes: writer.bytes + byte_size(data), head: head, tail: tail}
  end

  defp fallback_tail(_tail, data, limit) when byte_size(data) >= limit,
    do: binary_part(data, byte_size(data) - limit, limit)

  defp fallback_tail(tail, data, limit) when byte_size(tail) + byte_size(data) <= limit,
    do: tail <> data

  defp fallback_tail(tail, data, limit) do
    keep = limit - byte_size(data)
    binary_part(tail, byte_size(tail) - keep, keep) <> data
  end

  defp finish(%Writer{} = writer, status, metadata), do: Outputs.finish(writer, status, metadata)
  defp finish(%{fallback?: true} = writer, _status, _metadata), do: {:ok, writer}
  defp discard(%Writer{} = writer), do: Outputs.discard(writer)
  defp discard(%{fallback?: true}), do: :ok
  defp preview(%OutputArtifact{} = artifact), do: Outputs.preview(artifact)
  defp preview(%{fallback?: true} = writer), do: fallback_preview(writer)
  defp truncated?(%OutputArtifact{} = artifact), do: Outputs.truncated?(artifact)

  defp truncated?(%{fallback?: true} = writer),
    do: writer.bytes > byte_size(writer.head) + byte_size(writer.tail)

  defp artifact_id(%OutputArtifact{id: id}), do: id
  defp artifact_id(%{fallback?: true}), do: nil
  defp artifact_bytes(%OutputArtifact{byte_size: bytes}), do: bytes
  defp artifact_bytes(%{fallback?: true, bytes: bytes}), do: bytes

  defp fallback_preview(writer) when writer.bytes <= byte_size(writer.head), do: writer.head

  defp fallback_preview(writer)
       when writer.bytes <= byte_size(writer.head) + byte_size(writer.tail) do
    overlap = byte_size(writer.head) + byte_size(writer.tail) - writer.bytes
    writer.head <> binary_part(writer.tail, overlap, byte_size(writer.tail) - overlap)
  end

  defp fallback_preview(writer),
    do: writer.head <> "\n\n[output truncated]\n\n" <> writer.tail

  defp runner_path do
    case :code.priv_dir(:iex_code) do
      {:error, :bad_name} -> Path.expand("priv/command_runner.py")
      directory -> Path.join(to_string(directory), "command_runner.py")
    end
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: 30_000
end
