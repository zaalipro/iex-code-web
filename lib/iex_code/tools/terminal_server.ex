defmodule IexCode.Tools.TerminalServer do
  @moduledoc """
  Public client facade for interactive PTY terminal sessions.
  Provides high-level, fail-safe APIs for LiveViews, autonomous agents, and test suites.
  """
  require Logger

  alias IexCode.Tools.TerminalSession
  alias IexCode.Tools.TerminalSupervisor

  @pubsub_server IexCode.PubSub
  @workspace_lock_retry_timeout_ms 5_000

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
          {:ok, pid}
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
  Executes a command synchronously on behalf of an autonomous agent, capturing output until completion.
  Emits telemetry events `[:iex_code, :terminal, :command_dispatched]` and `[:iex_code, :terminal, :command_completed]`.
  Guarantees occupant cleanup back to `:user`.
  """
  @spec run_agent_command(
          session_id :: String.t(),
          command :: String.t(),
          agent_name :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{output: String.t(), exit_code: integer(), duration_ms: integer()}}
          | {:error, term()}
  def run_agent_command(session_id, command, agent_name, opts \\ [])
      when is_binary(session_id) and is_binary(command) and is_binary(agent_name) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    op_id = Keyword.get(opts, :op_id)
    occupant = {:agent, agent_name, op_id}

    workspace_lock_identity =
      opts
      |> Keyword.get(:workspace_lock_identity, [])
      |> Keyword.put(:terminal_mutation_kind, :agent)

    lock_started_at = System.monotonic_time(:millisecond)

    with :ok <- TerminalSession.validate_command(command),
         {:ok, _pid} <- ensure_started(session_id, opts),
         {:ok, command_timeout_ms} <-
           begin_workspace_mutation_with_retry(
             session_id,
             workspace_lock_identity,
             lock_started_at,
             timeout_ms
           ) do
      result =
        case TerminalSession.set_occupant(session_id, occupant) do
          :ok ->
            run_locked_agent_command(
              session_id,
              command,
              agent_name,
              occupant,
              op_id,
              command_timeout_ms
            )

          {:error, _reason} = error ->
            error
        end

      _ = TerminalSession.set_occupant(session_id, :user)
      _ = TerminalSession.end_workspace_mutation(session_id)
      result
    end
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

  defp run_locked_agent_command(session_id, command, agent_name, occupant, op_id, timeout_ms) do
    token = "CMD_FIN_#{:erlang.unique_integer([:positive])}"
    # The command may end in a shell comment. Start the completion probe on a
    # fresh line so an interactive bash cannot consume it as part of that
    # comment and leave the collector waiting forever.
    wrapped_cmd = "#{command}\necho '__AGENT_EXIT:'$?':TOKEN:#{token}__'\n"
    collector_owner = self()
    collector_ready_ref = make_ref()

    # Execute collector in an isolated task to preserve caller's PubSub subscriptions
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
                  collect_agent_output(session_id, token, "", start_time, timeout_ms)
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
          start_monotonic
        )

      {:error, reason} ->
        Task.shutdown(collector_task, :brutal_kill)
        emit_command_completed(session_id, command, agent_name, op_id, start_monotonic, :error)
        {:error, reason}
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
         start_monotonic
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
             TerminalSession.send_input(session_id, wrapped_cmd, force: true)
           end) do
        :ok ->
          # Start the execution clock only after input is accepted. Output that
          # races this message is already queued in the subscribed collector's
          # mailbox and is consumed immediately after the start handshake.
          send(collector_task.pid, {:terminal_collector_start, collector_ready_ref})

          case Task.await(collector_task, timeout_ms + 1_000) do
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

  defp collect_agent_output(session_id, token, acc, start_time, timeout_ms) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout_ms - elapsed, 0)
    regex = ~r/\r?\n?__AGENT_EXIT:(\d+):TOKEN:#{token}__\r?\n?/

    receive do
      {:terminal_output, %{session_id: ^session_id, data: chunk}} ->
        new_acc = acc <> chunk

        case Regex.run(regex, new_acc) do
          [match, code_str] ->
            duration = System.monotonic_time(:millisecond) - start_time

            clean_output =
              new_acc
              |> String.split(match, parts: 2)
              |> List.first()
              |> strip_agent_command_echo(token)
              |> String.trim_trailing()

            {:ok,
             %{
               output: clean_output,
               exit_code: String.to_integer(code_str),
               duration_ms: duration
             }}

          nil ->
            collect_agent_output(session_id, token, new_acc, start_time, timeout_ms)
        end

      {:terminal_exit, %{session_id: ^session_id, exit_code: code}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        {:ok, %{output: acc, exit_code: code || 0, duration_ms: duration}}
    after
      remaining ->
        {:error, :timeout}
    end
  end

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

    with :ok <- kill(session_id) do
      TerminalSupervisor.start_session(session_id, merged_opts)
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
