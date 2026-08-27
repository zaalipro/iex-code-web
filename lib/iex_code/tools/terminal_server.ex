defmodule IexCode.Tools.TerminalServer do
  @moduledoc """
  Public client facade for interactive PTY terminal sessions.
  Provides high-level, fail-safe APIs for LiveViews, autonomous agents, and test suites.
  """
  require Logger

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Outputs
  alias IexCode.Outputs.{OutputArtifact, Writer}
  alias IexCode.Repo
  alias IexCode.Tools.TerminalSession
  alias IexCode.Tools.TerminalSupervisor

  @pubsub_server IexCode.PubSub
  @workspace_lock_retry_timeout_ms 5_000
  @collector_lookbehind_bytes 256
  @fallback_preview_bytes 64 * 1_024
  @default_output_limit_bytes 256 * 1_048_576

  # --- Session Lifecycle ---

  @doc """
  Ensures a terminal session is running for the given `session_id`.
  If already running, returns `{:ok, pid}`. Otherwise, spawns a new session under `TerminalSupervisor`.
  """
  @spec ensure_started(session_id :: String.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(session_id, opts \\ []) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          case TerminalSession.get_state(session_id) do
            {:ok, %{status: status}} when status in [:starting, :ready, :running, :restarting] ->
              {:ok, pid}

            {:ok, _inactive_state} ->
              TerminalSession.restart(session_id, opts)

            {:error, _reason} ->
              TerminalSupervisor.start_session(session_id, opts)
          end
        else
          TerminalSupervisor.start_session(session_id, opts)
        end

      nil ->
        TerminalSupervisor.start_session(session_id, opts)
    end
  end

  @doc """
  Looks up the PID of the active terminal session for `session_id`.
  Returns `pid` if alive, or `nil` if not running.
  """
  @spec whereis(session_id :: String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    TerminalSession.whereis(session_id)
  end

  @doc """
  Returns true if the terminal session is currently running.
  """
  @spec running?(session_id :: String.t()) :: boolean()
  def running?(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc "Ensures the PTY exists and registers an interactive viewer."
  @spec attach_viewer(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def attach_viewer(session_id, viewer_pid \\ self(), opts \\ [])

  def attach_viewer(session_id, viewer_pid, opts)
      when is_binary(session_id) and is_pid(viewer_pid) and is_list(opts) do
    with {:ok, pid} <- ensure_started(session_id, opts),
         :ok <- TerminalSession.attach_viewer(session_id, viewer_pid) do
      {:ok, pid}
    end
  end

  def attach_viewer(_session_id, _viewer_pid, _opts), do: {:error, :invalid_viewer}

  @doc "Releases an interactive viewer without stopping a busy PTY."
  @spec detach_viewer(String.t(), pid()) :: :ok
  def detach_viewer(session_id, viewer_pid \\ self())

  def detach_viewer(session_id, viewer_pid)
      when is_binary(session_id) and is_pid(viewer_pid) do
    TerminalSession.detach_viewer(session_id, viewer_pid)
  end

  def detach_viewer(_session_id, _viewer_pid), do: :ok

  # --- Input & Commands ---

  @doc """
  Sends raw input bytes (keystrokes, escape sequences, control chars) to the shell process.
  Returns `{:error, :agent_occupied}` if terminal is occupied by an agent unless `force: true` is passed.
  Returns `{:error, :not_found}` if the session is not started.
  """
  @spec send_input(session_id :: String.t(), data :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def send_input(session_id, data, opts \\ [])

  def send_input(session_id, data, opts)
      when is_binary(session_id) and is_binary(data) do
    with :ok <- TerminalSession.validate_raw_input(data) do
      case whereis(session_id) do
        nil ->
          {:error, :not_found}

        _pid ->
          retry_transient_workspace_lock(fn ->
            TerminalSession.send_input(session_id, data, opts)
          end)
      end
    end
  end

  def send_input(_session_id, _data, _opts), do: {:error, :invalid_terminal_input}

  @doc """
  Queues a complete command for correlated, serialized execution.

  This compatibility API returns `:ok`; use `run_command_with_id/2` when the
  caller needs the generated command ID.
  """
  @spec run_command(session_id :: String.t(), command :: String.t()) :: :ok | {:error, term()}
  def run_command(session_id, command) when is_binary(session_id) and is_binary(command) do
    case run_command_with_id(session_id, command) do
      {:ok, _command_id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Queues a command and returns the opaque ID used by command lifecycle PubSub events.
  """
  @spec run_command_with_id(session_id :: String.t(), command :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def run_command_with_id(session_id, command)
      when is_binary(session_id) and is_binary(command) do
    with :ok <- TerminalSession.validate_command(command) do
      case whereis(session_id) do
        nil ->
          {:error, :not_found}

        _pid ->
          retry_transient_workspace_lock(fn ->
            TerminalSession.run_command(session_id, command)
          end)
      end
    end
  end

  @doc """
  Executes a command synchronously on behalf of an autonomous agent. Output is
  streamed as before, while the complete capture is spooled to a bounded disk
  artifact and only a fixed-size preview is returned to the caller.
  Emits telemetry events `[:iex_code, :terminal, :command_dispatched]` and `[:iex_code, :terminal, :command_completed]`.
  Guarantees occupant cleanup back to `:user`.
  """
  @spec run_agent_command(
          session_id :: String.t(),
          command :: String.t(),
          agent_name :: String.t(),
          opts :: keyword()
        ) ::
          {:ok,
           %{
             output: String.t(),
             exit_code: integer(),
             duration_ms: integer(),
             artifact_id: String.t() | nil,
             output_bytes: non_neg_integer(),
             output_truncated?: boolean()
           }}
          | {:error, term()}
  def run_agent_command(session_id, command, agent_name, opts \\ [])
      when is_binary(session_id) and is_binary(command) and is_binary(agent_name) do
    governor_opts =
      ResourceGovernor.admission_opts(opts,
        priority: :background,
        run_key: Keyword.get(opts, :op_id) || session_id
      )

    ResourceGovernor.with_permit(:native_command, governor_opts, fn ->
      do_run_agent_command(session_id, command, agent_name, opts)
    end)
  end

  defp do_run_agent_command(session_id, command, agent_name, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    op_id = Keyword.get(opts, :op_id)
    occupant = {:agent, agent_name, op_id}

    workspace_lock_identity =
      opts
      |> Keyword.get(:workspace_lock_identity, [])
      |> Keyword.put(:terminal_mutation_kind, :agent)

    lock_started_at = System.monotonic_time(:millisecond)

    with :ok <- TerminalSession.validate_command(command),
         {:ok, terminal_pid} <- ensure_started(session_id, opts),
         :ok <- await_running(session_id, terminal_pid, 5_000),
         {:ok, %{adapter_generation: adapter_generation}} <-
           TerminalSession.get_state(session_id),
         :ok <- validate_terminal_instance(session_id, terminal_pid),
         {:ok, command_timeout_ms} <-
           begin_workspace_mutation_with_retry(
             session_id,
             Keyword.put(workspace_lock_identity, :adapter_generation, adapter_generation),
             lock_started_at,
             timeout_ms
           ) do
      result =
        try do
          case TerminalSession.set_occupant(session_id, occupant,
                 adapter_generation: adapter_generation
               ) do
            :ok ->
              run_locked_agent_command(
                session_id,
                command,
                agent_name,
                occupant,
                op_id,
                command_timeout_ms,
                Keyword.put(opts, :adapter_generation, adapter_generation)
              )

            {:error, _reason} = error ->
              error
          end
        after
          _ =
            TerminalSession.set_occupant(session_id, :user,
              adapter_generation: adapter_generation
            )

          _ =
            TerminalSession.end_workspace_mutation(session_id,
              adapter_generation: adapter_generation
            )
        end

      result
    end
  end

  defp validate_terminal_instance(session_id, expected_pid) do
    if whereis(session_id) == expected_pid,
      do: :ok,
      else: {:error, :terminal_restarted}
  end

  defp begin_workspace_mutation_with_retry(session_id, identity, started_at, timeout_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = timeout_ms - elapsed

    if remaining <= 0 do
      {:error, :timeout}
    else
      case TerminalSession.begin_workspace_mutation(session_id, identity) do
        :ok ->
          # `timeout_ms` governs command execution after exclusive ownership is
          # acquired. Lock contention has the same bounded allowance, but must
          # not consume the command's runtime budget under database load.
          {:ok, timeout_ms}

        {:error, reason} = error ->
          if retryable_workspace_lock_conflict?(reason) do
            receive do
            after
              min(40, remaining) -> :ok
            end

            begin_workspace_mutation_with_retry(session_id, identity, started_at, timeout_ms)
          else
            error
          end
      end
    end
  end

  defp retryable_workspace_lock_conflict?(:terminal_mutation_busy), do: true
  defp retryable_workspace_lock_conflict?({:workspace_lock_waiting, _locks}), do: true
  defp retryable_workspace_lock_conflict?({:conflict, _locks}), do: true

  defp retryable_workspace_lock_conflict?({:workspace_lock_database_error, message})
       when is_binary(message) do
    transient_workspace_lock_database_error?(message)
  end

  defp retryable_workspace_lock_conflict?(_reason), do: false

  defp retry_transient_workspace_lock(fun) do
    deadline = System.monotonic_time(:millisecond) + @workspace_lock_retry_timeout_ms
    do_retry_transient_workspace_lock(fun, deadline)
  end

  defp do_retry_transient_workspace_lock(fun, deadline) do
    case fun.() do
      {:error, {:workspace_lock_database_error, message}} = error when is_binary(message) ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 and transient_workspace_lock_database_error?(message) do
          receive do
          after
            min(40, remaining) -> do_retry_transient_workspace_lock(fun, deadline)
          end
        else
          error
        end

      result ->
        result
    end
  end

  defp transient_workspace_lock_database_error?(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "connection not available") or
      String.contains?(normalized, "could not checkout the connection") or
      String.contains?(normalized, "request was dropped from queue") or
      String.contains?(normalized, "database is busy") or
      String.contains?(normalized, "database is locked")
  end

  defp run_locked_agent_command(
         session_id,
         command,
         agent_name,
         occupant,
         op_id,
         timeout_ms,
         opts
       ) do
    adapter_generation = Keyword.fetch!(opts, :adapter_generation)
    token = "CMD_FIN_#{:erlang.unique_integer([:positive])}"
    # The command may end in a shell comment. Start the completion probe on a
    # fresh line so an interactive bash cannot consume it as part of that
    # comment and leave the collector waiting forever.
    wrapped_cmd = "#{command}\necho '__AGENT_EXIT:'$?':TOKEN:#{token}__'\n"
    collector_owner = self()
    collector_ready_ref = make_ref()

    with {:ok, output_writer} <- open_command_output(session_id, agent_name, op_id, opts) do
      # Execute collector in an isolated task to preserve caller PubSub subscriptions.
      collector_task =
        Task.async(fn ->
          topic = "session:#{session_id}:terminal"

          case Phoenix.PubSub.subscribe(@pubsub_server, topic) do
            :ok ->
              send(collector_owner, {:terminal_collector_ready, collector_ready_ref, self()})

              try do
                receive do
                  {:terminal_collector_start, ^collector_ready_ref} ->
                    start_time = System.monotonic_time(:millisecond)

                    collect_agent_output(
                      session_id,
                      adapter_generation,
                      token,
                      output_writer,
                      start_time,
                      timeout_ms
                    )
                after
                  timeout_ms + @workspace_lock_retry_timeout_ms -> {:error, :timeout}
                end
              after
                Phoenix.PubSub.unsubscribe(@pubsub_server, topic)
              end

            {:error, reason} ->
              {:error, {:pubsub_subscribe_failed, reason}}
          end
        end)

      start_monotonic = System.monotonic_time(:millisecond)

      case await_collector_ready(collector_task, collector_ready_ref, timeout_ms) do
        :ok ->
          dispatch_locked_agent_command(
            collector_task,
            collector_ready_ref,
            session_id,
            command,
            wrapped_cmd,
            agent_name,
            occupant,
            op_id,
            timeout_ms,
            start_monotonic,
            output_writer,
            adapter_generation
          )

        {:error, reason} ->
          Task.shutdown(collector_task, :brutal_kill)
          discard_output(output_writer)
          emit_command_completed(session_id, command, agent_name, op_id, start_monotonic, :error)
          {:error, reason}
      end
    end
  end

  defp await_collector_ready(collector_task, ready_ref, timeout_ms) do
    receive do
      {:terminal_collector_ready, ^ready_ref, collector_pid}
      when collector_pid == collector_task.pid ->
        :ok
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp dispatch_locked_agent_command(
         collector_task,
         collector_ready_ref,
         session_id,
         command,
         wrapped_cmd,
         agent_name,
         occupant,
         op_id,
         timeout_ms,
         start_monotonic,
         output_writer,
         adapter_generation
       ) do
    command_summary = TerminalSession.command_summary(command)

    :telemetry.execute(
      [:iex_code, :terminal, :command_dispatched],
      %{system_time: System.system_time()},
      %{
        session_id: session_id,
        command: command_summary,
        occupant: occupant,
        agent_name: agent_name,
        op_id: op_id
      }
    )

    try do
      case retry_transient_workspace_lock(fn ->
             TerminalSession.send_input(session_id, wrapped_cmd,
               force: true,
               adapter_generation: adapter_generation
             )
           end) do
        :ok ->
          # Start the execution clock only after input is accepted. Output that
          # races this message is already queued in the subscribed collector's
          # mailbox and is consumed immediately after the start handshake.
          send(collector_task.pid, {:terminal_collector_start, collector_ready_ref})

          case Task.await(collector_task, timeout_ms + 2_000) do
            {:ok, res} ->
              :telemetry.execute(
                [:iex_code, :terminal, :command_completed],
                %{
                  duration_ms: res.duration_ms,
                  exit_code: res.exit_code,
                  system_time: System.system_time()
                },
                %{
                  session_id: session_id,
                  command: command_summary,
                  agent_name: agent_name,
                  op_id: op_id,
                  exit_code: res.exit_code,
                  status: if(res.exit_code == 0, do: :ok, else: :error)
                }
              )

              {:ok, res}

            {:error, _reason} = err ->
              duration = System.monotonic_time(:millisecond) - start_monotonic

              :telemetry.execute(
                [:iex_code, :terminal, :command_completed],
                %{
                  duration_ms: duration,
                  exit_code: -1,
                  system_time: System.system_time()
                },
                %{
                  session_id: session_id,
                  command: command_summary,
                  agent_name: agent_name,
                  op_id: op_id,
                  exit_code: -1,
                  status: :error
                }
              )

              err
          end

        {:error, reason} ->
          Task.shutdown(collector_task, :brutal_kill)
          discard_output(output_writer)

          emit_command_completed(
            session_id,
            command,
            agent_name,
            op_id,
            start_monotonic,
            :error
          )

          {:error, reason}
      end
    rescue
      e ->
        Task.shutdown(collector_task, :brutal_kill)
        terminate_agent_producer(session_id, adapter_generation)
        discard_output(output_writer)

        emit_command_completed(
          session_id,
          command,
          agent_name,
          op_id,
          start_monotonic,
          :error
        )

        {:error, e}
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(collector_task, :brutal_kill)
        terminate_agent_producer(session_id, adapter_generation)
        discard_output(output_writer)
        duration = System.monotonic_time(:millisecond) - start_monotonic

        :telemetry.execute(
          [:iex_code, :terminal, :command_completed],
          %{
            duration_ms: duration,
            exit_code: -1,
            system_time: System.system_time()
          },
          %{
            session_id: session_id,
            command: command_summary,
            agent_name: agent_name,
            op_id: op_id,
            exit_code: -1,
            status: :error
          }
        )

        {:error, :timeout}

      :exit, reason ->
        Task.shutdown(collector_task, :brutal_kill)
        terminate_agent_producer(session_id, adapter_generation)
        discard_output(output_writer)

        emit_command_completed(
          session_id,
          command,
          agent_name,
          op_id,
          start_monotonic,
          :error
        )

        {:error, {:exit, reason}}
    end
  end

  defp emit_command_completed(
         session_id,
         command,
         agent_name,
         op_id,
         start_monotonic,
         status
       ) do
    command_summary = TerminalSession.command_summary(command)

    :telemetry.execute(
      [:iex_code, :terminal, :command_completed],
      %{
        duration_ms: max(System.monotonic_time(:millisecond) - start_monotonic, 0),
        exit_code: -1,
        system_time: System.system_time()
      },
      %{
        session_id: session_id,
        command: command_summary,
        agent_name: agent_name,
        op_id: op_id,
        exit_code: -1,
        status: status
      }
    )

    :ok
  end

  defp open_command_output(session_id, agent_name, op_id, opts) do
    output_config = Application.get_env(:iex_code, :output_artifacts, [])

    if Keyword.get(opts, :output_artifact, Keyword.get(output_config, :enabled, true)) do
      artifact_attrs = Keyword.get(opts, :output_artifact_attrs, %{})

      attrs = %{
        run_id: persisted_id(IexCode.Runs.Run, map_value(artifact_attrs, :run_id)),
        session_id:
          persisted_id(
            IexCode.Sessions.Session,
            map_value(artifact_attrs, :session_id) || session_id
          ),
        operation_id:
          persisted_id(
            IexCode.Sessions.Operation,
            map_value(artifact_attrs, :operation_id)
          ),
        kind: "terminal_command_output",
        name: "terminal-command.log",
        metadata: %{
          "terminal_session_id" => session_id,
          "agent" => String.slice(agent_name, 0, 120),
          "operation_ref" => safe_operation_ref(op_id)
        }
      }

      output_opts = Keyword.get(opts, :output_options, [])

      output_opts =
        case Keyword.get(opts, :output_limit_bytes) do
          bytes when is_integer(bytes) and bytes > 0 ->
            Keyword.put(output_opts, :limit_bytes, bytes)

          _other ->
            output_opts
        end

      case Outputs.open_writer(attrs, output_opts) do
        {:ok, writer} -> {:ok, writer}
        {:error, reason} -> {:error, {:output_artifact_unavailable, reason}}
      end
    else
      limit = Keyword.get(opts, :output_limit_bytes, @default_output_limit_bytes)

      {:ok,
       %{
         fallback?: true,
         bytes: 0,
         head: "",
         tail: "",
         limit_bytes: limit,
         preview_bytes: @fallback_preview_bytes
       }}
    end
  end

  defp collect_agent_output(
         session_id,
         adapter_generation,
         token,
         writer,
         start_time,
         timeout_ms
       ) do
    regex = ~r/\r?\n?__AGENT_EXIT:(\d+):TOKEN:#{token}__\r?\n?/

    case do_collect_agent_output(
           session_id,
           adapter_generation,
           regex,
           writer,
           "",
           start_time,
           timeout_ms
         ) do
      {:completed, writer, code, duration} ->
        finish_collected_output(writer, code, duration, token)

      {:terminal_exit, writer, code, duration} ->
        finish_collected_output(writer, code || 0, duration, token)

      {:limit_exceeded, writer} ->
        # PTY mode targets the foreground process group; fallback mode attempts
        # the negative PGID first. This terminates the complete producer tree,
        # not merely its BEAM collector.
        _ =
          TerminalSession.send_signal(session_id, :sigkill,
            adapter_generation: adapter_generation
          )

        # Do not release the workspace mutation until the shell consumes this
        # command's completion probe. Otherwise the next command can subscribe
        # while output/exit events from the killed producer are still in flight.
        _ =
          await_agent_boundary(
            session_id,
            adapter_generation,
            regex,
            "",
            System.monotonic_time(:millisecond) + 1_000
          )

        case finish_output(writer, :limit_exceeded, %{"reason" => "output_limit_exceeded"}) do
          {:ok, artifact} -> {:error, {:output_limit_exceeded, artifact_id(artifact)}}
          {:error, _reason} -> {:error, :output_limit_exceeded}
        end

      {:timeout, writer} ->
        _ =
          TerminalSession.send_signal(session_id, :sigkill,
            adapter_generation: adapter_generation
          )

        _ =
          await_agent_boundary(
            session_id,
            adapter_generation,
            regex,
            "",
            System.monotonic_time(:millisecond) + 1_000
          )

        _ = finish_output(writer, :failed, %{"reason" => "timeout"})
        {:error, :timeout}

      {:error, writer, reason} ->
        terminate_agent_producer(session_id, adapter_generation)

        _ =
          await_agent_boundary(
            session_id,
            adapter_generation,
            regex,
            "",
            System.monotonic_time(:millisecond) + 1_000
          )

        _ = finish_output(writer, :failed, %{"reason" => "capture_error"})
        {:error, {:output_capture_failed, reason}}
    end
  end

  defp do_collect_agent_output(
         session_id,
         adapter_generation,
         regex,
         writer,
         pending,
         start_time,
         timeout_ms
       ) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout_ms - elapsed, 0)

    if remaining == 0 do
      case append_output(writer, pending) do
        {:ok, writer} -> {:timeout, writer}
        {:limit_exceeded, writer} -> {:limit_exceeded, writer}
        {:error, reason} -> {:error, writer, reason}
      end
    else
      receive do
        {:terminal_output,
         %{
           session_id: ^session_id,
           adapter_generation: ^adapter_generation,
           data: chunk
         }} ->
          buffer = pending <> chunk

          case Regex.run(regex, buffer, return: :index) do
            [{marker_start, _marker_length}, {code_start, code_length}] ->
              output = binary_part(buffer, 0, marker_start)
              code = buffer |> binary_part(code_start, code_length) |> String.to_integer()

              case append_output(writer, output) do
                {:ok, writer} ->
                  {:completed, writer, code, System.monotonic_time(:millisecond) - start_time}

                {:limit_exceeded, writer} ->
                  {:limit_exceeded, writer}

                {:error, reason} ->
                  {:error, writer, reason}
              end

            nil ->
              {flush, pending} = split_collector_buffer(buffer)

              case append_output(writer, flush) do
                {:ok, writer} ->
                  do_collect_agent_output(
                    session_id,
                    adapter_generation,
                    regex,
                    writer,
                    pending,
                    start_time,
                    timeout_ms
                  )

                {:limit_exceeded, writer} ->
                  {:limit_exceeded, writer}

                {:error, reason} ->
                  {:error, writer, reason}
              end
          end

        {:terminal_exit,
         %{
           session_id: ^session_id,
           adapter_generation: ^adapter_generation,
           exit_code: code
         }} ->
          case append_output(writer, pending) do
            {:ok, writer} ->
              {:terminal_exit, writer, code, System.monotonic_time(:millisecond) - start_time}

            {:limit_exceeded, writer} ->
              {:limit_exceeded, writer}

            {:error, reason} ->
              {:error, writer, reason}
          end
      after
        remaining ->
          case append_output(writer, pending) do
            {:ok, writer} -> {:timeout, writer}
            {:limit_exceeded, writer} -> {:limit_exceeded, writer}
            {:error, reason} -> {:error, writer, reason}
          end
      end
    end
  end

  defp terminate_agent_producer(session_id, adapter_generation) do
    _ =
      TerminalSession.send_signal(session_id, :sigkill, adapter_generation: adapter_generation)

    :ok
  end

  defp await_agent_boundary(session_id, adapter_generation, regex, pending, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:terminal_output,
         %{
           session_id: ^session_id,
           adapter_generation: ^adapter_generation,
           data: chunk
         }} ->
          buffer = pending <> chunk

          if Regex.match?(regex, buffer) do
            :ok
          else
            {_discard, pending} = split_collector_buffer(buffer)
            await_agent_boundary(session_id, adapter_generation, regex, pending, deadline)
          end

        {:terminal_exit, %{session_id: ^session_id, adapter_generation: ^adapter_generation}} ->
          :terminal_exit
      after
        remaining -> :timeout
      end
    end
  end

  defp split_collector_buffer(buffer) when byte_size(buffer) <= @collector_lookbehind_bytes,
    do: {"", buffer}

  defp split_collector_buffer(buffer) do
    flush_bytes = byte_size(buffer) - @collector_lookbehind_bytes

    {binary_part(buffer, 0, flush_bytes),
     binary_part(buffer, flush_bytes, @collector_lookbehind_bytes)}
  end

  defp append_output(%Writer{} = writer, data), do: Outputs.append(writer, data)

  defp append_output(%{fallback?: true} = writer, data) do
    remaining = max(writer.limit_bytes - writer.bytes, 0)
    accepted_bytes = min(byte_size(data), remaining)
    accepted = binary_part(data, 0, accepted_bytes)
    writer = account_fallback(writer, accepted)

    if accepted_bytes == byte_size(data),
      do: {:ok, writer},
      else: {:limit_exceeded, writer}
  end

  defp account_fallback(writer, data) do
    preview_bytes = writer.preview_bytes

    head =
      if byte_size(writer.head) >= preview_bytes do
        writer.head
      else
        needed = preview_bytes - byte_size(writer.head)
        writer.head <> binary_part(data, 0, min(byte_size(data), needed))
      end

    tail = bounded_tail(writer.tail, data, preview_bytes)
    %{writer | bytes: writer.bytes + byte_size(data), head: head, tail: tail}
  end

  defp bounded_tail(_tail, data, limit) when byte_size(data) >= limit,
    do: binary_part(data, byte_size(data) - limit, limit)

  defp bounded_tail(tail, data, limit) when byte_size(tail) + byte_size(data) <= limit,
    do: tail <> data

  defp bounded_tail(tail, data, limit) do
    keep = limit - byte_size(data)
    binary_part(tail, byte_size(tail) - keep, keep) <> data
  end

  defp finish_collected_output(writer, code, duration, token) do
    with {:ok, artifact} <- finish_output(writer, :ready, %{"exit_code" => code}) do
      output =
        artifact_preview(artifact) |> strip_agent_command_echo(token) |> String.trim_trailing()

      {:ok,
       %{
         output: output,
         exit_code: code,
         duration_ms: duration,
         artifact_id: artifact_id(artifact),
         output_bytes: artifact_bytes(artifact),
         output_truncated?: artifact_truncated?(artifact)
       }}
    end
  end

  defp finish_output(%Writer{} = writer, status, metadata),
    do: Outputs.finish(writer, status, metadata)

  defp finish_output(%{fallback?: true} = writer, _status, _metadata), do: {:ok, writer}

  defp discard_output(%Writer{} = writer), do: Outputs.discard(writer)
  defp discard_output(%{fallback?: true}), do: :ok

  defp artifact_preview(%OutputArtifact{} = artifact) do
    combine_preview(
      artifact.preview_head,
      artifact.preview_tail,
      artifact.byte_size,
      "\n\n… output truncated; retrieve artifact #{artifact.id} …\n\n"
    )
  end

  defp artifact_preview(%{fallback?: true} = writer) do
    combine_preview(
      writer.head,
      writer.tail,
      writer.bytes,
      "\n\n… output truncated …\n\n"
    )
  end

  defp combine_preview(head, _tail, bytes, _notice) when bytes <= byte_size(head), do: head

  defp combine_preview(head, tail, bytes, _notice)
       when bytes <= byte_size(head) + byte_size(tail) do
    overlap = byte_size(head) + byte_size(tail) - bytes
    head <> binary_part(tail, overlap, byte_size(tail) - overlap)
  end

  defp combine_preview(head, tail, _bytes, notice), do: head <> notice <> tail

  defp artifact_id(%OutputArtifact{id: id}), do: id
  defp artifact_id(%{fallback?: true}), do: nil
  defp artifact_bytes(%OutputArtifact{byte_size: bytes}), do: bytes
  defp artifact_bytes(%{fallback?: true, bytes: bytes}), do: bytes

  defp artifact_truncated?(%OutputArtifact{} = artifact),
    do:
      artifact.byte_size >
        byte_size(artifact.preview_head) + byte_size(artifact.preview_tail)

  defp artifact_truncated?(%{fallback?: true} = writer),
    do: writer.bytes > byte_size(writer.head) + byte_size(writer.tail)

  defp safe_operation_ref(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp safe_operation_ref(_value), do: nil
  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp map_value(_map, _key), do: nil

  defp persisted_id(schema, id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{id: ^uuid} <- Repo.get(schema, uuid) do
      uuid
    else
      _missing_or_invalid -> nil
    end
  rescue
    _error -> nil
  end

  defp persisted_id(_schema, _id), do: nil

  defp strip_agent_command_echo(output, token) do
    output
    |> String.replace(~r/;?\s*echo\s+['"]__AGENT_EXIT:[^'"]*['"]/, "")
    |> String.replace(token, "")
  end

  # --- Terminal Window & Signals ---

  @doc """
  Resizes the terminal dimensions (cols x rows) and triggers SIGWINCH.
  """
  @spec resize(session_id :: String.t(), cols :: integer(), rows :: integer()) ::
          :ok | {:error, term()}
  def resize(session_id, cols, rows)
      when is_binary(session_id) and is_integer(cols) and is_integer(rows) do
    if cols <= 0 or rows <= 0 do
      {:error, :invalid_dimensions}
    else
      case whereis(session_id) do
        nil -> {:error, :not_found}
        _pid -> TerminalSession.resize(session_id, cols, rows)
      end
    end
  end

  @doc """
  Dispatches an OS signal or control sequence (`:sigint`, `:sigterm`, `:sigkill`, `:sigtstp`, `:eof`) to the shell.
  """
  @spec send_signal(session_id :: String.t(), signal :: atom() | binary()) ::
          :ok | {:error, term()}
  def send_signal(session_id, signal) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        {:error, :not_found}

      _pid ->
        with :ok <- TerminalSession.begin_workspace_mutation(session_id) do
          try do
            case TerminalSession.send_signal(session_id, signal) do
              {:error, :not_running} -> :ok
              result -> result
            end
          after
            _ = TerminalSession.end_workspace_mutation(session_id)
          end
        end
    end
  end

  # --- History & Inspection ---

  @doc """
  Searches the terminal session scrollback history for matching lines.

  ## Options
    * `:regex` / `:is_regex` - boolean, treat query as regex (default: `false`).
    * `:case_sensitive` - boolean, case sensitive search (default: `false`).
    * `:strip_ansi` - boolean, strip ANSI sequences before search (default: `true`).
    * `:limit` / `:max_results` - pos_integer() | :infinity, max results (default: `100`).
    * `:reverse` - boolean, return newest matches first (default: `false`).
  """
  @spec search_history(
          session_id :: String.t(),
          query :: String.t() | Regex.t(),
          opts :: keyword()
        ) ::
          {:ok,
           [
             %{
               line_number: integer(),
               text: String.t(),
               match_range: {integer(), integer()}
             }
           ]}
          | {:error, term()}
  def search_history(session_id, query, opts \\ [])
      when is_binary(session_id) and (is_binary(query) or is_struct(query, Regex)) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> TerminalSession.search_history(session_id, query, opts)
    end
  end

  @doc """
  Retrieves accumulated UTF-8 scrollback history from the ring buffer.
  Returns empty string if session is not running.
  """
  @spec get_history(session_id :: String.t()) :: binary()
  def get_history(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> ""
      _pid -> TerminalSession.get_history(session_id)
    end
  end

  @doc """
  Clears scrollback plus bounded structured command history/recent input identity,
  and broadcasts `{:terminal_cleared, ...}` over PubSub.
  """
  @spec clear(session_id :: String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> :ok
      _pid -> TerminalSession.clear_history(session_id)
    end
  end

  @doc """
  Retrieves a full state inspection map from the running terminal session.
  """
  @spec get_state(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> TerminalSession.get_state(session_id)
    end
  end

  # --- Restart & Termination ---

  @doc """
  Restarts the shell process within the terminal session by stopping the existing child
  and spawning a fresh supervised session.
  """
  @spec restart(session_id :: String.t(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  def restart(session_id, opts \\ []) when is_binary(session_id) do
    saved_opts =
      case get_state(session_id) do
        {:ok, state} ->
          [
            workspace_path: state.workspace_path,
            cols: state.cols,
            rows: state.rows,
            shell: state.shell
          ]

        _ ->
          []
      end

    merged_opts = Keyword.merge(saved_opts, opts)

    with :ok <- kill(session_id),
         {:ok, pid} <- TerminalSupervisor.start_session(session_id, merged_opts),
         :ok <- await_running(session_id, pid, 5_000) do
      {:ok, pid}
    end
  end

  defp await_running(session_id, pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_running(session_id, pid, deadline)
  end

  defp do_await_running(session_id, pid, deadline) do
    cond do
      not Process.alive?(pid) ->
        {:error, :terminal_start_failed}

      true ->
        case TerminalSession.get_state(session_id) do
          {:ok, %{status: status}} when status in [:ready, :running] ->
            :ok

          {:ok, %{status: status}} when status in [:stopped, :error] ->
            {:error, :terminal_start_failed}

          _other ->
            remaining = deadline - System.monotonic_time(:millisecond)

            if remaining <= 0 do
              {:error, :terminal_start_timeout}
            else
              receive do
              after
                min(10, remaining) -> do_await_running(session_id, pid, deadline)
              end
            end
        end
    end
  end

  @doc """
  Stops and terminates the terminal session, sending SIGKILL and stopping the child process under supervision.
  """
  @spec kill(session_id :: String.t()) :: :ok | {:error, term()}
  def kill(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        :ok

      pid ->
        with :ok <- TerminalSession.begin_workspace_mutation(session_id) do
          ref = Process.monitor(pid)
          _ = TerminalSession.send_signal(session_id, :sigkill)
          _ = TerminalSupervisor.stop_session(session_id)
          _ = TerminalSession.stop(session_id)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1_000 -> :ok
          end
        end
    end
  end
end
