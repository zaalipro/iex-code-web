defmodule IexCode.Tools.TerminalSession do
  @moduledoc """
  GenServer representing an active, supervised PTY terminal session.
  Maintains PTY Port lifecycle, binary ring buffer history, UTF-8 chunk alignment,
  and Phoenix PubSub event broadcasts.
  """
  use GenServer, restart: :temporary
  require Logger

  alias IexCode.LLM.UTF8Buffer
  alias IexCode.Tools.PTYAdapter
  alias IexCode.Tools.TerminalSupervisor
  alias IexCode.WorkspaceLocks

  @default_cols 80
  @default_rows 24
  @default_max_buffer_bytes 512 * 1024
  @max_raw_input_bytes 256 * 1024
  @max_command_bytes 32 * 1024
  @max_pending_command_bytes 256 * 1024
  @max_history_command_bytes 4 * 1024
  @max_command_history_bytes 128 * 1024
  @max_command_history_entries 100
  @max_recent_command_inputs 64
  @history_consistency_timeout_ms 1_000
  @default_interrupt_signal_delay_ms 100
  @default_interrupt_timeout_ms 2_000
  @default_interrupt_force_timeout_ms 1_000
  @default_idle_timeout_ms 30 * 60 * 1_000
  @pubsub_server IexCode.PubSub

  defstruct [
    :session_id,
    :project_root,
    :adapter,
    :adapter_generation,
    :shell,
    :cols,
    :rows,
    :status,
    :history_buffer,
    :buffer_bytes,
    :max_buffer_bytes,
    :utf8_acc,
    :active_occupant,
    :env,
    :mode,
    :started_at,
    :exit_code,
    :exit_reason,
    :cleared,
    :active_command,
    :command_queue,
    :command_marker_buffer,
    :max_queued_commands,
    :history_suppressed_command_id,
    :recent_command_inputs,
    :command_history,
    :workspace_lock_handle,
    :raw_input_lock?,
    :external_lock_count,
    :agent_owner_pid,
    :agent_owner_ref,
    :pending_interrupt,
    :viewers,
    :idle_timeout_ms,
    :idle_timer,
    :interrupt_signal_delay_ms,
    :interrupt_timeout_ms,
    :interrupt_force_timeout_ms
  ]

  # --- Client API ---

  @doc """
  Starts a supervised `TerminalSession` GenServer registered under `IexCode.SessionRegistry`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  Returns the Registry `{:via, ...}` tuple for the given `session_id`.
  """
  @spec via_tuple(session_id :: String.t()) :: {:via, Registry, {atom(), {atom(), String.t()}}}
  def via_tuple(session_id) when is_binary(session_id) do
    {:via, Registry, {IexCode.SessionRegistry, {:terminal, session_id}}}
  end

  @doc """
  Looks up the PID for `session_id`.
  """
  @spec whereis(session_id :: String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(IexCode.SessionRegistry, {:terminal, session_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          pid
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc "Registers a process as an interactive viewer, preventing idle reaping."
  @spec attach_viewer(String.t(), pid()) :: :ok | {:error, :not_found | :invalid_viewer}
  def attach_viewer(session_id, viewer_pid \\ self())

  def attach_viewer(session_id, viewer_pid)
      when is_binary(session_id) and is_pid(viewer_pid) do
    try do
      GenServer.call(via_tuple(session_id), {:attach_viewer, viewer_pid})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  def attach_viewer(_session_id, _viewer_pid), do: {:error, :invalid_viewer}

  @doc "Unregisters an interactive viewer and begins the idle grace period when safe."
  @spec detach_viewer(String.t(), pid()) :: :ok
  def detach_viewer(session_id, viewer_pid \\ self())

  def detach_viewer(session_id, viewer_pid)
      when is_binary(session_id) and is_pid(viewer_pid) do
    try do
      GenServer.call(via_tuple(session_id), {:detach_viewer, viewer_pid})
    catch
      :exit, _ -> :ok
    end
  end

  def detach_viewer(_session_id, _viewer_pid), do: :ok

  @doc false
  def update_idle_timeout(session_id, timeout_ms)
      when is_binary(session_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    case whereis(session_id) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:update_idle_timeout, timeout_ms})
      nil -> :ok
    end
  end

  @doc """
  Sends raw binary input to the active PTY port.
  Enforces lock mode when occupied by an agent unless `force: true` is provided.
  """
  @spec send_input(session_id :: String.t(), data :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def send_input(session_id, data, opts \\ [])
      when is_binary(session_id) and is_binary(data) do
    with :ok <- validate_raw_input(data) do
      try do
        GenServer.call(via_tuple(session_id), {:send_input, data, opts})
      catch
        :exit, _ -> {:error, :not_found}
      end
    end
  end

  @doc false
  def validate_raw_input(data) when is_binary(data) do
    if byte_size(data) <= @max_raw_input_bytes,
      do: :ok,
      else: {:error, :terminal_input_too_large}
  end

  def validate_raw_input(_data), do: {:error, :invalid_terminal_input}

  @doc """
  Queues a complete command for serialized execution in the persistent shell.

  A cryptographically random, per-command shell marker is used to correlate the
  command's exit status without terminating the PTY. The marker is consumed by
  this process and is never included in terminal output or scrollback.
  """
  @spec run_command(session_id :: String.t(), command :: binary()) ::
          {:ok, String.t()} | {:error, term()}
  def run_command(session_id, command) when is_binary(session_id) and is_binary(command) do
    with :ok <- validate_command(command) do
      try do
        GenServer.call(via_tuple(session_id), {:run_command, command})
      catch
        :exit, _ -> {:error, :not_found}
      end
    end
  end

  @doc false
  def validate_command(command) when is_binary(command) do
    cond do
      byte_size(command) == 0 -> {:error, :empty_terminal_command}
      byte_size(command) > @max_command_bytes -> {:error, :terminal_command_too_large}
      not String.valid?(command) -> {:error, :invalid_terminal_command_encoding}
      not String.printable?(command) -> {:error, :invalid_terminal_command_characters}
      String.trim(command) == "" -> {:error, :empty_terminal_command}
      true -> :ok
    end
  end

  def validate_command(_command), do: {:error, :invalid_terminal_command}

  @doc false
  def command_summary(command) when is_binary(command) do
    command
    |> redact_command_secrets()
    |> bounded_utf8(@max_history_command_bytes)
  end

  def command_summary(_command), do: ""

  @doc """
  Searches accumulated scrollback history buffer.

  ## Options
    * `:case_sensitive` - boolean (default: `false`)
    * `:regex` / `:is_regex` - boolean (default: `false`)
    * `:strip_ansi` - boolean (default: `true`)
    * `:limit` / `:max_results` - integer or :infinity (default: `100`)
    * `:reverse` - boolean (default: `false`)
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
  def search_history(session_id, query, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:search_history, query, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Resizes the terminal window dimensions.
  """
  @spec resize(session_id :: String.t(), cols :: integer(), rows :: integer()) ::
          :ok | {:error, term()}
  def resize(session_id, cols, rows, opts \\ [])
      when is_binary(session_id) and is_integer(cols) and is_integer(rows) do
    try do
      GenServer.call(via_tuple(session_id), {:resize, cols, rows, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Sends an OS signal to the child shell process.
  """
  @spec send_signal(session_id :: String.t(), signal :: atom() | binary(), keyword()) ::
          :ok | {:error, term()}
  def send_signal(session_id, signal, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:send_signal, signal, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns all accumulated scrollback history as a continuous UTF-8 binary.
  """
  @spec get_history(session_id :: String.t()) :: binary()
  def get_history(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :get_history)
    catch
      :exit, _ -> ""
    end
  end

  @doc """
  Clears scrollback, structured command history, and recent-input fingerprints.
  A shell restart intentionally preserves bounded structured history; explicit
  clear is the privacy boundary that removes it.
  """
  @spec clear_history(session_id :: String.t()) :: :ok
  def clear_history(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :clear_history)
    catch
      :exit, _ -> :ok
    end
  end

  @doc false
  def clear_if_user(session_id, adapter_generation) when is_binary(session_id) do
    guarded_user_call(session_id, {:clear_if_user, adapter_generation})
  end

  @doc false
  def interrupt_if_user(session_id, adapter_generation) when is_binary(session_id) do
    guarded_user_call(session_id, {:interrupt_if_user, adapter_generation})
  end

  @doc """
  Updates the active occupant state (:user | {:agent, name, op_id}).
  """
  @spec set_occupant(
          session_id :: String.t(),
          occupant :: :user | {:agent, String.t(), String.t() | nil},
          keyword()
        ) :: :ok | {:error, term()}
  def set_occupant(session_id, occupant, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:set_occupant, occupant, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc false
  def begin_workspace_mutation(session_id, identity_opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:begin_workspace_mutation, identity_opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc false
  def end_workspace_mutation(session_id, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:end_workspace_mutation, opts})
    catch
      :exit, _ -> :ok
    end
  end

  @doc false
  def inject_test_output(session_id, data) when is_binary(session_id) and is_binary(data) do
    if Application.get_env(:iex_code, :allow_terminal_test_injection, false) and
         byte_size(data) <= @max_raw_input_bytes do
      GenServer.call(via_tuple(session_id), {:inject_test_output, data})
    else
      {:error, :test_injection_disabled}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Restarts the shell process within the existing session.
  """
  @spec restart(session_id :: String.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restart(session_id, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:restart, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc false
  def restart_if_user(session_id, adapter_generation, opts \\ []) when is_binary(session_id) do
    guarded_user_call(session_id, {:restart_if_user, adapter_generation, opts})
  end

  defp guarded_user_call(session_id, request) do
    try do
      GenServer.call(via_tuple(session_id), request)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns a snapshot map of the terminal session state.
  """
  @spec get_state(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :get_state)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Stops the terminal session GenServer.
  """
  @spec stop(session_id :: String.t(), reason :: term(), timeout :: timeout()) :: :ok
  def stop(session_id, reason \\ :normal, timeout \\ 5000) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, reason, timeout)
        catch
          :exit, _ -> :ok
        end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)

    project_root =
      Keyword.get(opts, :workspace_path) ||
        Keyword.get(opts, :project_root) ||
        Keyword.get(opts, :cwd, File.cwd!())

    cols = max(1, Keyword.get(opts, :cols, @default_cols))
    rows = max(1, Keyword.get(opts, :rows, @default_rows))
    shell = Keyword.get(opts, :shell)
    max_buffer_bytes = Keyword.get(opts, :max_buffer_bytes, @default_max_buffer_bytes)

    max_queued_commands =
      case Keyword.get(opts, :max_queued_commands, 256) do
        count when is_integer(count) -> count |> max(1) |> min(256)
        _invalid -> 256
      end

    env = Keyword.get(opts, :env, default_env(project_root))
    mode = Keyword.get(opts, :mode)

    interrupt_signal_delay_ms =
      bounded_timeout(
        Keyword.get(opts, :interrupt_signal_delay_ms, @default_interrupt_signal_delay_ms),
        @default_interrupt_signal_delay_ms,
        0,
        10_000
      )

    interrupt_timeout_ms =
      bounded_timeout(
        Keyword.get(opts, :interrupt_timeout_ms, @default_interrupt_timeout_ms),
        @default_interrupt_timeout_ms,
        100,
        30_000
      )

    interrupt_force_timeout_ms =
      bounded_timeout(
        Keyword.get(
          opts,
          :interrupt_force_timeout_ms,
          @default_interrupt_force_timeout_ms
        ),
        @default_interrupt_force_timeout_ms,
        100,
        10_000
      )

    idle_timeout_ms =
      normalize_idle_timeout(
        Keyword.get(
          opts,
          :idle_timeout_ms,
          Application.get_env(:iex_code, :terminal_idle_timeout_ms, @default_idle_timeout_ms)
        )
      )

    state = %__MODULE__{
      session_id: session_id,
      project_root: project_root,
      adapter: nil,
      adapter_generation: 0,
      shell: shell,
      cols: cols,
      rows: rows,
      status: :starting,
      history_buffer: [],
      buffer_bytes: 0,
      max_buffer_bytes: max_buffer_bytes,
      utf8_acc: UTF8Buffer.new(),
      active_occupant: :user,
      env: env,
      mode: mode,
      started_at: DateTime.utc_now(),
      exit_code: nil,
      exit_reason: nil,
      cleared: false,
      active_command: nil,
      command_queue: :queue.new(),
      command_marker_buffer: "",
      max_queued_commands: max_queued_commands,
      history_suppressed_command_id: nil,
      recent_command_inputs: [],
      command_history: TerminalSupervisor.cached_history(session_id),
      workspace_lock_handle: nil,
      raw_input_lock?: false,
      external_lock_count: 0,
      agent_owner_pid: nil,
      agent_owner_ref: nil,
      pending_interrupt: nil,
      viewers: %{},
      idle_timeout_ms: idle_timeout_ms,
      idle_timer: nil,
      interrupt_signal_delay_ms: interrupt_signal_delay_ms,
      interrupt_timeout_ms: interrupt_timeout_ms,
      interrupt_force_timeout_ms: interrupt_force_timeout_ms
    }

    {:ok, schedule_idle_reap(state), {:continue, :spawn_shell}}
  end

  @impl true
  def handle_continue(:spawn_shell, state) do
    case spawn_adapter(state) do
      {:ok, adapter} ->
        running_state = %{
          state
          | adapter: adapter,
            adapter_generation: next_adapter_generation(),
            shell: adapter.shell || state.shell,
            status: :running
        }

        :telemetry.execute(
          [:iex_code, :terminal, :session_started],
          %{system_time: System.system_time()},
          %{
            session_id: running_state.session_id,
            shell: running_state.shell,
            project_root: running_state.project_root,
            workspace_path: running_state.project_root,
            cols: running_state.cols,
            rows: running_state.rows,
            os_pid: adapter && adapter.os_pid
          }
        )

        broadcast_status(running_state)
        {:noreply, running_state}

      {:error, reason} ->
        Logger.error("[TerminalSession] Failed to spawn shell: #{inspect(reason)}")
        err_state = %{state | status: :error, exit_reason: reason}
        broadcast_status(err_state)
        {:noreply, err_state}
    end
  end

  # --- Calls ---

  @impl true
  def handle_cast({:update_idle_timeout, timeout_ms}, state) do
    {:noreply,
     state
     |> cancel_idle_reap()
     |> Map.put(:idle_timeout_ms, timeout_ms)
     |> schedule_idle_reap()}
  end

  @impl true
  def handle_call({:attach_viewer, viewer_pid}, _from, state) do
    cond do
      not Process.alive?(viewer_pid) ->
        {:reply, {:error, :invalid_viewer}, state}

      Map.has_key?(state.viewers, viewer_pid) ->
        {:reply, :ok, cancel_idle_reap(state)}

      true ->
        ref = Process.monitor(viewer_pid)

        {:reply, :ok,
         cancel_idle_reap(%{state | viewers: Map.put(state.viewers, viewer_pid, ref)})}
    end
  end

  @impl true
  def handle_call({:detach_viewer, viewer_pid}, _from, state) do
    state = remove_viewer(state, viewer_pid)
    {:reply, :ok, schedule_idle_reap(state)}
  end

  @impl true
  def handle_call(
        {:send_input, data, opts},
        _from,
        %{status: :running, adapter: %PTYAdapter{} = adapter} = state
      ) do
    force? = Keyword.get(opts, :force, false)

    cond do
      validate_raw_input(data) != :ok ->
        {:reply, validate_raw_input(data), state}

      stale_adapter_generation?(state, opts) ->
        {:reply, {:error, :stale_terminal_generation}, state}

      state.active_occupant != :user and not force? ->
        {:reply, {:error, :agent_occupied}, state}

      true ->
        case ensure_workspace_lock(state) do
          {:ok, locked_state, acquired?} ->
            {payload, locked_state} = append_heredoc_marker_if_complete(locked_state, data)

            case PTYAdapter.send_input(adapter, payload) do
              :ok ->
                new_state = %{
                  locked_state
                  | raw_input_lock?: locked_state.raw_input_lock? or not force?
                }

                new_state =
                  if force?, do: maybe_release_workspace_lock(new_state), else: new_state

                {:reply, :ok, cancel_idle_reap(new_state)}

              {:error, reason} ->
                locked_state =
                  if acquired?, do: release_workspace_lock(locked_state), else: locked_state

                {:reply, {:error, reason}, locked_state}
            end

          {:error, reason, locked_state} ->
            {:reply, {:error, reason}, locked_state}
        end
    end
  end

  def handle_call({:send_input, _data, _opts}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:send_input, data}, from, state) do
    handle_call({:send_input, data, []}, from, state)
  end

  @impl true
  def handle_call(
        {:run_command, command},
        _from,
        %{status: :running, adapter: %PTYAdapter{}} = state
      ) do
    queued_count = :queue.len(state.command_queue) + if(state.active_command, do: 1, else: 0)
    pending_bytes = pending_command_bytes(state)

    cond do
      validate_command(command) != :ok ->
        {:reply, validate_command(command), state}

      state.active_occupant != :user ->
        {:reply, {:error, :agent_occupied}, state}

      queued_count >= state.max_queued_commands ->
        {:reply, {:error, :command_queue_full}, state}

      pending_bytes + byte_size(command) > @max_pending_command_bytes ->
        {:reply, {:error, :command_queue_bytes_exceeded}, state}

      true ->
        case ensure_workspace_lock(state) do
          {:ok, locked_state, acquired?} ->
            entry = new_command_entry(command)

            case locked_state.active_command do
              nil ->
                case dispatch_command(locked_state, entry) do
                  {:ok, new_state} ->
                    {:reply, {:ok, entry.id}, cancel_idle_reap(new_state)}

                  {:error, reason, new_state} ->
                    new_state =
                      if acquired?, do: release_workspace_lock(new_state), else: new_state

                    {:reply, {:error, reason}, new_state}
                end

              _active ->
                new_state = %{
                  locked_state
                  | command_queue: :queue.in(entry, locked_state.command_queue)
                }

                {:reply, {:ok, entry.id}, cancel_idle_reap(new_state)}
            end

          {:error, reason, locked_state} ->
            {:reply, {:error, reason}, locked_state}
        end
    end
  end

  def handle_call({:run_command, _command}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:search_history, query, opts}, _from, state) do
    # A subscriber can observe a PTY-echoed command before the shell's output
    # packet reaches this GenServer. If a correlated command is active, consume
    # its port messages through its completion boundary (with a bounded wait)
    # so search cannot race the command whose output prompted the query.
    state = drain_active_command_output(state, @history_consistency_timeout_ms)
    result = do_search_history(state, query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:resize, cols, rows, opts}, _from, state) do
    new_cols = max(1, cols)
    new_rows = max(1, rows)

    cond do
      stale_adapter_generation?(state, opts) ->
        {:reply, {:error, :stale_terminal_generation}, state}

      state.active_occupant != :user ->
        {:reply, {:error, :agent_occupied}, state}

      true ->
        case ensure_workspace_lock(state) do
          {:ok, locked_state, acquired?} ->
            new_adapter =
              if locked_state.adapter && locked_state.status == :running do
                case PTYAdapter.resize(locked_state.adapter, new_cols, new_rows) do
                  {:ok, updated_adapter} -> updated_adapter
                  _ -> locked_state.adapter
                end
              else
                locked_state.adapter
              end

            new_state = %{
              locked_state
              | adapter: new_adapter,
                cols: new_cols,
                rows: new_rows
            }

            new_state = if acquired?, do: release_workspace_lock(new_state), else: new_state

            broadcast_event(state.session_id, {
              :terminal_resized,
              %{session_id: state.session_id, cols: new_cols, rows: new_rows}
            })

            {:reply, :ok, new_state}

          {:error, reason, locked_state} ->
            {:reply, {:error, reason}, locked_state}
        end
    end
  end

  def handle_call({:resize, cols, rows}, from, state),
    do: handle_call({:resize, cols, rows, []}, from, state)

  @impl true
  def handle_call({:send_signal, signal, opts}, _from, state)
      when signal in [:sigint, :interrupt, "SIGINT"] do
    case {stale_adapter_generation?(state, opts), state.adapter} do
      {true, _adapter} ->
        {:reply, {:error, :stale_terminal_generation}, state}

      {false, %PTYAdapter{port: port}} ->
        case ensure_workspace_lock(state) do
          {:ok, locked_state, _acquired?} ->
            {:reply, :ok, schedule_interrupt(locked_state, signal, port)}

          {:error, reason, locked_state} ->
            {:reply, {:error, reason}, locked_state}
        end

      {false, _not_running} ->
        {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call({:send_signal, signal, opts}, _from, state) do
    cond do
      stale_adapter_generation?(state, opts) ->
        {:reply, {:error, :stale_terminal_generation}, state}

      state.adapter ->
        case signal do
          sig when sig in [:eof, :ctrl_d, "EOF"] ->
            PTYAdapter.send_input(state.adapter, <<4>>)

          other ->
            PTYAdapter.send_signal(state.adapter, other)
        end

        {:reply, :ok, state}

      true ->
        {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, %{cleared: true} = state) do
    {:reply, "", state}
  end

  @impl true
  def handle_call(:get_history, _from, %{history_buffer: []} = state) do
    state = drain_pending_port_output(state, 150)

    history_str =
      state.history_buffer
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {:reply, history_str, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    history_str =
      state.history_buffer
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {:reply, history_str, state}
  end

  @impl true
  def handle_call(:clear_history, _from, state) do
    # Consume already-delivered port packets before establishing the logical
    # boundary. If a command is still active, its remaining echo/output stays
    # visible live but is excluded from the new searchable history epoch.
    state = drain_pending_port_output(state, 150)

    new_state = %{
      state
      | history_buffer: [],
        buffer_bytes: 0,
        cleared: true,
        utf8_acc: UTF8Buffer.new(),
        history_suppressed_command_id: state.active_command && state.active_command.id,
        recent_command_inputs: [],
        command_history: []
    }

    broadcast_event(state.session_id, {:terminal_cleared, %{session_id: state.session_id}})
    TerminalSupervisor.clear_cached_history(state.session_id)
    {:reply, :ok, touch_activity(new_state)}
  end

  @impl true
  def handle_call({:clear_if_user, generation}, from, state) do
    case authorize_user_effect(state, generation) do
      :ok -> handle_call(:clear_history, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:interrupt_if_user, generation}, from, state) do
    case authorize_user_effect(state, generation) do
      :ok -> handle_call({:send_signal, :sigint, [adapter_generation: generation]}, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_occupant, occupant, opts}, _from, state) do
    if stale_adapter_generation?(state, opts) do
      {:reply, {:error, :stale_terminal_generation}, state}
    else
      apply_occupant(occupant, state)
    end
  end

  def handle_call({:inject_test_output, data}, _from, state) do
    if Application.get_env(:iex_code, :allow_terminal_test_injection, false) do
      case process_output_bytes(state, data) do
        {:noreply, state} -> {:reply, :ok, state}
      end
    else
      {:reply, {:error, :test_injection_disabled}, state}
    end
  end

  @impl true
  def handle_call({:begin_workspace_mutation, identity_opts}, from, state)
      when state.external_lock_count > 0 or not is_nil(state.active_command) do
    cond do
      stale_adapter_generation?(state, identity_opts) ->
        {:reply, {:error, :stale_terminal_generation}, state}

      Keyword.get(identity_opts, :terminal_mutation_kind) == :agent ->
        {:reply, {:error, :terminal_mutation_busy}, state}

      true ->
        do_begin_workspace_mutation(identity_opts, from, state)
    end
  end

  def handle_call({:begin_workspace_mutation, identity_opts}, from, state) do
    cond do
      stale_adapter_generation?(state, identity_opts) ->
        {:reply, {:error, :stale_terminal_generation}, state}

      Keyword.get(identity_opts, :terminal_mutation_kind) == :agent and
          not :queue.is_empty(state.command_queue) ->
        {:reply, {:error, :terminal_mutation_busy}, state}

      true ->
        do_begin_workspace_mutation(identity_opts, from, state)
    end
  end

  @impl true
  def handle_call({:end_workspace_mutation, opts}, _from, state) do
    if stale_adapter_generation?(state, opts) do
      {:reply, {:error, :stale_terminal_generation}, state}
    else
      state =
        state
        |> Map.put(:external_lock_count, max(state.external_lock_count - 1, 0))
        |> maybe_clear_agent_owner()

      {:reply, :ok, maybe_release_workspace_lock(state)}
    end
  end

  @impl true
  def handle_call({:restart, opts}, _from, state) do
    state = state |> cancel_pending_interrupt() |> maybe_clear_agent_owner()
    if state.adapter, do: PTYAdapter.close(state.adapter)
    state = release_workspace_lock(state)
    next_adapter_generation = next_adapter_generation()

    updated_shell = Keyword.get(opts, :shell, state.shell)

    updated_root =
      Keyword.get(opts, :workspace_path) ||
        Keyword.get(opts, :project_root) ||
        Keyword.get(opts, :cwd, state.project_root)

    updated_cols = max(1, Keyword.get(opts, :cols, state.cols))
    updated_rows = max(1, Keyword.get(opts, :rows, state.rows))
    updated_env = Keyword.get(opts, :env, state.env)
    updated_mode = Keyword.get(opts, :mode, state.mode)

    reset_state = %{
      state
      | adapter: nil,
        adapter_generation: next_adapter_generation,
        shell: updated_shell,
        project_root: updated_root,
        cols: updated_cols,
        rows: updated_rows,
        env: updated_env,
        mode: updated_mode,
        status: :restarting,
        exit_code: nil,
        exit_reason: nil,
        cleared: false,
        active_command: nil,
        command_queue: :queue.new(),
        command_marker_buffer: "",
        recent_command_inputs: [],
        raw_input_lock?: false,
        external_lock_count: 0,
        pending_interrupt: nil
    }

    broadcast_status(reset_state)

    case spawn_adapter(reset_state) do
      {:ok, new_adapter} ->
        running_state = %{
          reset_state
          | adapter: new_adapter,
            shell: new_adapter.shell || updated_shell,
            status: :running,
            started_at: DateTime.utc_now()
        }

        :telemetry.execute(
          [:iex_code, :terminal, :session_started],
          %{system_time: System.system_time()},
          %{
            session_id: running_state.session_id,
            shell: running_state.shell,
            project_root: running_state.project_root,
            workspace_path: running_state.project_root,
            cols: running_state.cols,
            rows: running_state.rows,
            os_pid: new_adapter && new_adapter.os_pid
          }
        )

        broadcast_status(running_state)
        {:reply, {:ok, self()}, running_state}

      {:error, reason} ->
        err_state = %{reset_state | status: :error, exit_reason: reason}
        broadcast_status(err_state)
        {:reply, {:error, reason}, err_state}
    end
  end

  @impl true
  def handle_call({:restart_if_user, generation, opts}, from, state) do
    case authorize_user_effect(state, generation) do
      :ok -> handle_call({:restart, opts}, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    summary = %{
      session_id: state.session_id,
      project_root: state.project_root,
      workspace_path: state.project_root,
      status: state.status,
      shell: (state.adapter && state.adapter.shell) || state.shell,
      cols: state.cols,
      rows: state.rows,
      occupant: state.active_occupant,
      active_occupant: state.active_occupant,
      adapter_generation: state.adapter_generation,
      buffer_bytes: state.buffer_bytes,
      os_pid: state.adapter && state.adapter.os_pid,
      mode: state.adapter && state.adapter.mode,
      started_at: state.started_at,
      exit_code: state.exit_code,
      active_command_id: state.active_command && state.active_command.id,
      queued_command_count: :queue.len(state.command_queue),
      raw_input_lock?: state.raw_input_lock?,
      interrupt_pending?: not is_nil(state.pending_interrupt),
      command_history: state.command_history,
      viewer_count: map_size(state.viewers)
    }

    {:reply, {:ok, summary}, state}
  end

  # --- Port & System Info Messages ---

  @impl true
  def handle_info({:DOWN, ref, :process, viewer_pid, _reason}, state) do
    cond do
      ref == state.agent_owner_ref and viewer_pid == state.agent_owner_pid ->
        {:noreply, recover_agent_owner_death(state)}

      Map.get(state.viewers, viewer_pid) == ref ->
        {:noreply, state |> remove_viewer(viewer_pid, false) |> schedule_idle_reap()}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:terminal_idle_timeout, timer_ref},
        %{idle_timer: {timer_ref, _timer_handle}} = state
      ) do
    handle_idle_timeout(state)
  end

  # Compatibility for tests and already-materialized state using the earlier
  # logical-reference-only representation.
  def handle_info({:terminal_idle_timeout, timer_ref}, %{idle_timer: timer_ref} = state) do
    handle_idle_timeout(state)
  end

  def handle_info({:terminal_idle_timeout, _stale_ref}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {port, {:data, _raw_bytes}} = msg,
        %{adapter: %PTYAdapter{port: port} = adapter} = state
      ) do
    case PTYAdapter.handle_port_message(adapter, msg) do
      {:output, data, new_adapter} ->
        process_output_bytes(%{state | adapter: new_adapter}, data)

      {:exit, exit_code, new_adapter} ->
        process_exit(%{state | adapter: new_adapter}, exit_code, :normal)

      {:ready, os_pid, new_adapter} ->
        {:noreply, %{state | adapter: %{new_adapter | os_pid: os_pid}}}

      {:interrupt_boundary, boundary_id, new_adapter} ->
        {:noreply, settle_interrupt_boundary(%{state | adapter: new_adapter}, boundary_id)}

      {:noop, new_adapter} ->
        {:noreply, %{state | adapter: new_adapter}}

      :unknown ->
        # PTY protocol frames that are not recognized are never terminal
        # output. Treating their raw bytes as output could synthesize command
        # markers and prematurely complete a correlated command.
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {port, {:exit_status, status}},
        %{adapter: %PTYAdapter{port: port}} = state
      ) do
    process_exit(state, status, :exit_status)
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{adapter: %PTYAdapter{port: port}} = state) do
    Logger.warning(
      "[TerminalSession] Port trapped exit: #{inspect(reason)} (session: #{state.session_id})"
    )

    process_exit(state, -1, reason)
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:deferred_signal, request_id, signal, generation, port},
        %{
          adapter: %PTYAdapter{port: port},
          adapter_generation: generation,
          pending_interrupt: %{
            request_id: request_id,
            generation: generation,
            port: port,
            delivered?: false
          }
        } = state
      ) do
    {:noreply, deliver_interrupt(state, signal)}
  end

  def handle_info({:deferred_signal, _request_id, _signal, _generation, _port}, state),
    do: {:noreply, state}

  @impl true
  def handle_info(
        {:interrupt_timeout, request_id, generation, port},
        %{
          adapter: %PTYAdapter{port: port},
          adapter_generation: generation,
          pending_interrupt: %{
            request_id: request_id,
            generation: generation,
            port: port,
            delivered?: true
          }
        } = state
      ) do
    {:noreply, force_interrupt(state)}
  end

  def handle_info({:interrupt_timeout, _request_id, _generation, _port}, state),
    do: {:noreply, state}

  @impl true
  def handle_info(
        {:interrupt_force_timeout, request_id, generation, port},
        %{
          adapter: %PTYAdapter{port: port},
          adapter_generation: generation,
          pending_interrupt: %{
            request_id: request_id,
            generation: generation,
            port: port
          }
        } = state
      ) do
    {:noreply, restart_after_stuck_interrupt(state)}
  end

  def handle_info({:interrupt_force_timeout, _request_id, _generation, _port}, state),
    do: {:noreply, state}

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Termination Callback ---

  @impl true
  def terminate(reason, state) do
    Logger.debug("[TerminalSession] Terminating #{state.session_id}: #{inspect(reason)}")
    TerminalSupervisor.cache_history(state.session_id, state.command_history)
    if state.adapter, do: PTYAdapter.close(state.adapter)
    _ = release_workspace_lock(state)

    if state.status != :stopped do
      duration_ms =
        if state.started_at do
          DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
        else
          0
        end

      code = state.exit_code || 0

      :telemetry.execute(
        [:iex_code, :terminal, :session_stopped],
        %{
          duration_ms: duration_ms,
          exit_code: code,
          system_time: System.system_time()
        },
        %{
          session_id: state.session_id,
          exit_code: code,
          reason: reason
        }
      )
    end

    :ok
  end

  # --- Internal Helpers ---

  defp handle_idle_timeout(state) do
    state = %{state | idle_timer: nil}

    if idle_reap_safe?(state) do
      {:stop, :normal, state}
    else
      {:noreply, schedule_idle_reap(state)}
    end
  end

  defp apply_occupant(occupant, state) do
    new_state = touch_activity(%{state | active_occupant: occupant})

    broadcast_event(state.session_id, {
      :terminal_occupant,
      %{session_id: state.session_id, occupant: occupant}
    })

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  defp bounded_timeout(value, _default, minimum, maximum) when is_integer(value) do
    value |> max(minimum) |> min(maximum)
  end

  defp bounded_timeout(_value, default, _minimum, _maximum), do: default

  defp normalize_idle_timeout(:infinity), do: :infinity
  defp normalize_idle_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_idle_timeout(_invalid), do: @default_idle_timeout_ms

  defp touch_activity(state), do: schedule_idle_reap(state)

  defp schedule_idle_reap(%{idle_timeout_ms: :infinity} = state), do: cancel_idle_reap(state)

  defp schedule_idle_reap(%{viewers: viewers} = state) when map_size(viewers) > 0,
    do: cancel_idle_reap(state)

  defp schedule_idle_reap(state) do
    cond do
      not idle_reap_safe?(state) ->
        cancel_idle_reap(state)

      state.idle_timer != nil ->
        state

      true ->
        timer_ref = make_ref()

        timer_handle =
          Process.send_after(self(), {:terminal_idle_timeout, timer_ref}, state.idle_timeout_ms)

        %{state | idle_timer: {timer_ref, timer_handle}}
    end
  end

  defp cancel_idle_reap(%{idle_timer: nil} = state), do: state

  defp cancel_idle_reap(%{idle_timer: {_timer_ref, timer_handle}} = state) do
    # Keep the logical reference check in handle_info for already-delivered
    # messages, while actively releasing timers that are still pending.
    _ = Process.cancel_timer(timer_handle, async: false, info: false)
    %{state | idle_timer: nil}
  end

  defp cancel_idle_reap(state) do
    # Compatibility with state created before timer handles were retained.
    %{state | idle_timer: nil}
  end

  defp idle_reap_safe?(state) do
    map_size(state.viewers) == 0 and state.active_occupant == :user and
      is_nil(state.active_command) and :queue.is_empty(state.command_queue) and
      is_nil(state.workspace_lock_handle) and state.external_lock_count == 0 and
      not state.raw_input_lock? and is_nil(state.pending_interrupt)
  end

  defp remove_viewer(state, viewer_pid, demonitor? \\ true) do
    case Map.pop(state.viewers, viewer_pid) do
      {nil, _viewers} ->
        state

      {ref, viewers} ->
        if demonitor?, do: Process.demonitor(ref, [:flush])
        %{state | viewers: viewers}
    end
  end

  defp schedule_interrupt(state, signal, port) do
    case state.pending_interrupt do
      %{generation: generation, port: ^port, delivered?: true, forced?: false}
      when generation == state.adapter_generation ->
        force_interrupt(state)

      %{generation: generation, port: ^port}
      when generation == state.adapter_generation ->
        state

      _none_or_stale ->
        state = cancel_pending_interrupt(state)
        request_id = make_ref()
        generation = state.adapter_generation

        signal_timer =
          Process.send_after(
            self(),
            {:deferred_signal, request_id, signal, generation, port},
            state.interrupt_signal_delay_ms
          )

        pending = %{
          request_id: request_id,
          boundary_id: :binary.decode_unsigned(:crypto.strong_rand_bytes(8)),
          generation: generation,
          port: port,
          signal_timer: signal_timer,
          timeout_timer: nil,
          force_timer: nil,
          delivered?: false,
          forced?: false
        }

        %{state | pending_interrupt: pending}
    end
  end

  defp deliver_interrupt(state, signal) do
    pending = state.pending_interrupt

    case PTYAdapter.send_tracked_signal(state.adapter, signal, pending.boundary_id) do
      :ok ->
        request_id = pending.request_id
        generation = pending.generation
        port = pending.port

        timeout_timer =
          Process.send_after(
            self(),
            {:interrupt_timeout, request_id, generation, port},
            state.interrupt_timeout_ms
          )

        state = %{
          state
          | pending_interrupt: %{
              pending
              | signal_timer: nil,
                timeout_timer: timeout_timer,
                delivered?: true
            }
        }

        state

      {:error, _reason} ->
        force_interrupt(%{
          state
          | pending_interrupt: %{pending | signal_timer: nil, delivered?: true}
        })
    end
  end

  defp force_interrupt(state) do
    pending = state.pending_interrupt
    cancel_timer(pending.timeout_timer)
    cancel_timer(pending.force_timer)
    _ = PTYAdapter.send_signal(state.adapter, :sigkill)

    force_timer =
      Process.send_after(
        self(),
        {:interrupt_force_timeout, pending.request_id, pending.generation, pending.port},
        state.interrupt_force_timeout_ms
      )

    %{
      state
      | pending_interrupt: %{
          pending
          | timeout_timer: nil,
            force_timer: force_timer,
            forced?: true
        }
    }
  end

  defp restart_after_stuck_interrupt(state) do
    Logger.warning(
      "[TerminalSession] Interrupt boundary timed out; restarting shell " <>
        "(session: #{state.session_id})"
    )

    old_adapter = state.adapter
    next_generation = next_adapter_generation()
    if old_adapter, do: PTYAdapter.close(old_adapter)

    state =
      state
      |> cancel_pending_interrupt()
      |> complete_active_on_shell_exit(-1)
      |> complete_queued_on_shell_exit()

    reset_state = %{
      state
      | adapter: nil,
        adapter_generation: next_generation,
        status: :restarting,
        exit_code: nil,
        exit_reason: :interrupt_timeout,
        active_command: nil,
        command_queue: :queue.new(),
        command_marker_buffer: "",
        utf8_acc: UTF8Buffer.new(),
        raw_input_lock?: false,
        pending_interrupt: nil
    }

    broadcast_status(reset_state)

    case spawn_adapter(reset_state) do
      {:ok, adapter} ->
        running_state = %{
          reset_state
          | adapter: adapter,
            shell: adapter.shell || reset_state.shell,
            status: :running,
            started_at: DateTime.utc_now(),
            exit_reason: nil
        }

        broadcast_status(running_state)
        maybe_release_workspace_lock(running_state)

      {:error, reason} ->
        error_state = %{
          reset_state
          | status: :error,
            exit_reason: reason,
            raw_input_lock?: false
        }

        broadcast_status(error_state)
        release_workspace_lock(error_state)
    end
  end

  defp cancel_pending_interrupt(%{pending_interrupt: nil} = state), do: state

  defp cancel_pending_interrupt(state) do
    pending = state.pending_interrupt
    cancel_timer(pending.signal_timer)
    cancel_timer(pending.timeout_timer)
    cancel_timer(pending.force_timer)
    %{state | pending_interrupt: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp settle_interrupt_boundary(
         %{pending_interrupt: %{delivered?: true, boundary_id: boundary_id}} = state,
         boundary_id
       ) do
    state
    |> cancel_pending_interrupt()
    |> Map.put(:raw_input_lock?, false)
    |> maybe_release_workspace_lock()
  end

  defp settle_interrupt_boundary(state, _boundary_id), do: state

  defp spawn_adapter(state) do
    PTYAdapter.open(
      cwd: state.project_root,
      shell: state.shell,
      cols: state.cols,
      rows: state.rows,
      env: state.env,
      mode: state.mode
    )
  end

  defp process_output_bytes(state, raw_bytes) when is_binary(raw_bytes) do
    {valid_text, new_acc} = UTF8Buffer.process_bytes(state.utf8_acc, raw_bytes)

    new_state =
      if valid_text != "" do
        consume_command_output(state, valid_text)
      else
        state
      end

    {:noreply, %{new_state | utf8_acc: new_acc}}
  end

  defp process_exit(state, code, reason) do
    Logger.info(
      "[TerminalSession] Shell exited with code #{code} (reason: #{inspect(reason)}, session: #{state.session_id})"
    )

    if state.adapter, do: PTYAdapter.close(state.adapter)

    {remaining, _} = UTF8Buffer.flush(state.utf8_acc)

    flushed_state =
      if remaining != "" do
        consume_command_output(state, remaining)
      else
        state
      end

    flushed_state =
      flushed_state
      |> complete_active_on_shell_exit(code)
      |> complete_queued_on_shell_exit()
      |> cancel_pending_interrupt()
      |> maybe_clear_agent_owner()
      |> Map.put(:raw_input_lock?, false)
      |> release_workspace_lock()

    duration_ms =
      if state.started_at do
        DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
      else
        0
      end

    :telemetry.execute(
      [:iex_code, :terminal, :session_stopped],
      %{
        duration_ms: duration_ms,
        exit_code: code,
        system_time: System.system_time()
      },
      %{
        session_id: state.session_id,
        exit_code: code,
        reason: reason
      }
    )

    stopped_state = %{
      flushed_state
      | adapter: nil,
        status: :stopped,
        exit_code: code,
        exit_reason: reason,
        utf8_acc: UTF8Buffer.new(),
        active_command: nil,
        command_queue: :queue.new(),
        command_marker_buffer: "",
        recent_command_inputs: [],
        raw_input_lock?: false,
        external_lock_count: 0,
        pending_interrupt: nil
    }

    broadcast_event(state.session_id, {
      :terminal_exit,
      %{
        session_id: state.session_id,
        adapter_generation: state.adapter_generation,
        exit_code: code,
        reason: reason
      }
    })

    broadcast_status(stopped_state)
    {:noreply, stopped_state}
  end

  defp new_command_entry(command) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    %{
      id: id,
      token: token,
      command: command,
      heredoc_delimiter: heredoc_delimiter(command),
      marker_sent?: false,
      enqueued_at: System.monotonic_time(:millisecond)
    }
  end

  defp pending_command_bytes(state) do
    active_bytes = if state.active_command, do: byte_size(state.active_command.command), else: 0

    Enum.reduce(:queue.to_list(state.command_queue), active_bytes, fn entry, total ->
      total + byte_size(entry.command)
    end)
  end

  defp dispatch_command(state, entry) do
    command =
      if String.ends_with?(entry.command, "\n"), do: entry.command, else: entry.command <> "\n"

    # The token is generated inside this process and is not present in the user
    # command. Control-character framing prevents the echoed wrapper text from
    # being mistaken for the actual marker produced by printf.
    marker_command = command_marker(entry)

    payload =
      if entry.heredoc_delimiter do
        command
      else
        command <> marker_command
      end

    case PTYAdapter.send_input(state.adapter, payload) do
      :ok ->
        started_entry =
          entry
          |> Map.put(:started_at, System.monotonic_time(:millisecond))
          |> Map.put(:marker_sent?, is_nil(entry.heredoc_delimiter))

        display_command = command_summary(entry.command)

        :telemetry.execute(
          [:iex_code, :terminal, :command_dispatched],
          %{system_time: System.system_time()},
          %{session_id: state.session_id, command_id: entry.id, command: display_command}
        )

        broadcast_event(state.session_id, {
          :terminal_command_started,
          %{session_id: state.session_id, command_id: entry.id, command: display_command}
        })

        {:ok,
         %{
           state
           | active_command: started_entry,
             command_marker_buffer: "",
             cleared: false,
             recent_command_inputs:
               entry.command
               |> String.split(~r/\r\n|\r|\n/, trim: true)
               |> Enum.map(&String.trim/1)
               |> Enum.map(&command_input_fingerprint/1)
               |> Kernel.++(state.recent_command_inputs)
               |> Enum.take(@max_recent_command_inputs)
         }}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp consume_command_output(%{active_command: nil} = state, text) do
    publish_output(state, text)
  end

  defp consume_command_output(state, text) do
    active = state.active_command
    prefix = <<30>> <> "IEX_CODE_COMMAND:#{active.token}:"
    suffix = <<31>>
    buffered = state.command_marker_buffer <> text

    case :binary.match(buffered, prefix) do
      :nomatch ->
        # Retain only enough bytes for a prefix split across PTY chunks. This
        # bounds parser memory independently of command output volume.
        retained_bytes = partial_prefix_size(buffered, prefix)
        emitted_bytes = byte_size(buffered) - retained_bytes
        <<emitted::binary-size(emitted_bytes), retained::binary>> = buffered

        state
        |> publish_output(emitted)
        |> Map.put(:command_marker_buffer, retained)

      {prefix_at, prefix_size} ->
        <<before::binary-size(prefix_at), _prefix::binary-size(prefix_size), rest::binary>> =
          buffered

        state = publish_output(state, before)

        case :binary.match(rest, suffix) do
          :nomatch ->
            if byte_size(rest) <= 32 do
              %{state | command_marker_buffer: prefix <> rest}
            else
              state
              |> publish_output(prefix <> rest)
              |> Map.put(:command_marker_buffer, "")
            end

          {suffix_at, suffix_size} ->
            <<code_text::binary-size(suffix_at), _suffix::binary-size(suffix_size),
              after_marker::binary>> =
              rest

            code = parse_command_exit_code(code_text)

            state
            |> Map.put(:command_marker_buffer, "")
            |> finish_active_command(code)
            |> publish_output(after_marker)
            |> dispatch_next_command()
            |> maybe_release_workspace_lock()
        end
    end
  end

  defp parse_command_exit_code(code_text) do
    case Integer.parse(String.trim(code_text)) do
      {code, ""} -> code
      _ -> -1
    end
  end

  defp partial_prefix_size(buffered, prefix) do
    max_size = min(byte_size(buffered), byte_size(prefix) - 1)

    Enum.find(max_size..1//-1, 0, fn size ->
      suffix = binary_part(buffered, byte_size(buffered) - size, size)
      String.starts_with?(prefix, suffix)
    end)
  end

  defp finish_active_command(%{active_command: nil} = state, _code), do: state

  defp finish_active_command(state, code) do
    command = state.active_command
    duration_ms = System.monotonic_time(:millisecond) - command.started_at
    status = if code == 0, do: :ok, else: :error

    payload = %{
      session_id: state.session_id,
      command_id: command.id,
      command: command_summary(command.command),
      exit_code: code,
      status: status,
      duration_ms: duration_ms
    }

    :telemetry.execute(
      [:iex_code, :terminal, :command_completed],
      %{duration_ms: duration_ms, exit_code: code, system_time: System.system_time()},
      payload
    )

    broadcast_event(state.session_id, {:terminal_command_completed, payload})

    history_suppressed? = state.history_suppressed_command_id == command.id

    suppressed_id =
      if history_suppressed?, do: nil, else: state.history_suppressed_command_id

    history_entry =
      payload
      |> Map.take([:command_id, :command, :exit_code, :status, :duration_ms])
      |> Map.put(:completed_at, DateTime.utc_now())

    command_history =
      if history_suppressed?,
        do: state.command_history,
        else: bounded_command_history([history_entry | state.command_history])

    TerminalSupervisor.cache_history(state.session_id, command_history)

    %{
      state
      | active_command: nil,
        history_suppressed_command_id: suppressed_id,
        command_history: command_history
    }
  end

  defp dispatch_next_command(%{active_command: nil} = state) do
    case :queue.out(state.command_queue) do
      {{:value, entry}, remaining} ->
        state = %{state | command_queue: remaining}

        case dispatch_command(state, entry) do
          {:ok, new_state} -> new_state
          {:error, reason, new_state} -> fail_queued_command(new_state, entry, reason)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next_command(state), do: state

  defp fail_queued_command(state, entry, reason) do
    payload = %{
      session_id: state.session_id,
      command_id: entry.id,
      command: command_summary(entry.command),
      exit_code: -1,
      status: :error,
      reason: reason,
      duration_ms: 0
    }

    broadcast_event(state.session_id, {:terminal_command_completed, payload})

    state
    |> dispatch_next_command()
    |> maybe_release_workspace_lock()
  end

  defp complete_active_on_shell_exit(%{active_command: nil} = state, _code) do
    publish_output(state, state.command_marker_buffer)
  end

  defp complete_active_on_shell_exit(state, code) do
    state
    |> publish_output(state.command_marker_buffer)
    |> Map.put(:command_marker_buffer, "")
    |> finish_active_command(code)
  end

  defp complete_queued_on_shell_exit(state) do
    Enum.each(:queue.to_list(state.command_queue), fn entry ->
      payload = %{
        session_id: state.session_id,
        command_id: entry.id,
        command: command_summary(entry.command),
        exit_code: -1,
        status: :error,
        reason: :shell_exited,
        duration_ms: 0
      }

      broadcast_event(state.session_id, {:terminal_command_completed, payload})
    end)

    %{state | command_queue: :queue.new()}
  end

  defp do_begin_workspace_mutation(identity_opts, from, state) do
    agent? = Keyword.get(identity_opts, :terminal_mutation_kind) == :agent
    identity_opts = Keyword.drop(identity_opts, [:terminal_mutation_kind, :adapter_generation])

    case ensure_workspace_lock(state, identity_opts) do
      {:ok, locked_state, _acquired?} ->
        locked_state =
          locked_state
          |> Map.put(:external_lock_count, locked_state.external_lock_count + 1)
          |> maybe_monitor_agent_owner(agent?, elem(from, 0))

        {:reply, :ok, locked_state}

      {:error, reason, locked_state} ->
        {:reply, {:error, reason}, locked_state}
    end
  end

  defp maybe_monitor_agent_owner(state, false, _owner), do: state

  defp maybe_monitor_agent_owner(%{agent_owner_ref: nil} = state, true, owner) do
    %{state | agent_owner_pid: owner, agent_owner_ref: Process.monitor(owner)}
  end

  defp maybe_monitor_agent_owner(state, true, _owner), do: state

  defp maybe_clear_agent_owner(%{external_lock_count: count} = state) when count > 0, do: state

  defp maybe_clear_agent_owner(state) do
    if state.agent_owner_ref, do: Process.demonitor(state.agent_owner_ref, [:flush])
    %{state | agent_owner_pid: nil, agent_owner_ref: nil}
  end

  defp recover_agent_owner_death(state) do
    Logger.warning("[TerminalSession] Agent command owner exited; recovering #{state.session_id}")
    if state.adapter, do: PTYAdapter.close(state.adapter)

    state =
      state
      |> remove_viewer(state.agent_owner_pid, false)
      |> cancel_pending_interrupt()
      |> release_workspace_lock()
      |> Map.merge(%{
        adapter: nil,
        adapter_generation: next_adapter_generation(),
        status: :restarting,
        active_occupant: :user,
        external_lock_count: 0,
        agent_owner_pid: nil,
        agent_owner_ref: nil,
        active_command: nil,
        command_queue: :queue.new(),
        command_marker_buffer: "",
        utf8_acc: UTF8Buffer.new(),
        raw_input_lock?: false,
        pending_interrupt: nil
      })

    broadcast_event(
      state.session_id,
      {:terminal_occupant, %{session_id: state.session_id, occupant: :user}}
    )

    broadcast_status(state)

    case spawn_adapter(state) do
      {:ok, adapter} ->
        recovered = %{
          state
          | adapter: adapter,
            shell: adapter.shell || state.shell,
            status: :running
        }

        broadcast_status(recovered)
        schedule_idle_reap(recovered)

      {:error, reason} ->
        failed = %{state | status: :error, exit_reason: {:agent_owner_recovery_failed, reason}}
        broadcast_status(failed)
        schedule_idle_reap(failed)
    end
  end

  defp ensure_workspace_lock(%{workspace_lock_handle: %WorkspaceLocks{}} = state) do
    case WorkspaceLocks.assert(state.workspace_lock_handle) do
      :ok -> {:ok, state, false}
      {:error, reason} -> {:error, reason, release_workspace_lock(state)}
    end
  end

  defp ensure_workspace_lock(state), do: ensure_workspace_lock(state, [])

  defp ensure_workspace_lock(%{workspace_lock_handle: %WorkspaceLocks{}} = state, _identity_opts) do
    ensure_workspace_lock(state)
  end

  defp ensure_workspace_lock(state, identity_opts) do
    identity = workspace_lock_identity(state, identity_opts)

    case WorkspaceLocks.acquire(state.project_root, [{:project, :exclusive}], identity) do
      {:ok, handle} ->
        {:ok, %{state | workspace_lock_handle: handle}, true}

      {:error, reason} when reason == :unmanaged_workspace ->
        acquire_unmanaged_workspace_lock(state, identity)

      {:error, {:workspace_lock_database_error, message}}
      when is_binary(message) ->
        if test_sandbox_ownership_error?(message) do
          acquire_unmanaged_workspace_lock(state, identity)
        else
          {:error, {:workspace_lock_database_error, message}, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp workspace_lock_identity(state, opts) when is_list(opts) do
    allowed_keys = [
      :owner_id,
      :project_id,
      :run_id,
      :session_id,
      :delegation,
      :allow_unmanaged,
      :lease_seconds,
      :heartbeat_interval_ms
    ]

    opts = Keyword.take(opts, allowed_keys)
    Keyword.put_new(opts, :owner_id, "terminal-session:#{state.session_id}")
  end

  defp workspace_lock_identity(state, _opts),
    do: [owner_id: "terminal-session:#{state.session_id}"]

  defp acquire_unmanaged_workspace_lock(state, identity) do
    case WorkspaceLocks.acquire(
           state.project_root,
           [{:project, :exclusive}],
           Keyword.put(identity, :allow_unmanaged, true)
         ) do
      {:ok, handle} -> {:ok, %{state | workspace_lock_handle: handle}, true}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp test_sandbox_ownership_error?(message) do
    String.contains?(message, "cannot find ownership process") and
      String.contains?(message, "using mode :manual")
  end

  defp maybe_release_workspace_lock(state) do
    state =
      if state.raw_input_lock? or state.external_lock_count > 0 or
           not is_nil(state.pending_interrupt) or not is_nil(state.active_command) or
           not :queue.is_empty(state.command_queue) do
        state
      else
        release_workspace_lock(state)
      end

    schedule_idle_reap(state)
  end

  defp release_workspace_lock(%{workspace_lock_handle: nil} = state), do: state

  defp release_workspace_lock(state) do
    _ = WorkspaceLocks.release(state.workspace_lock_handle)
    %{state | workspace_lock_handle: nil}
  end

  defp publish_output(state, ""), do: state

  defp publish_output(state, text) do
    :telemetry.execute(
      [:iex_code, :terminal, :output_chunk],
      %{byte_size: byte_size(text), system_time: System.system_time()},
      %{session_id: state.session_id, occupant: state.active_occupant, data: text}
    )

    payload = %{
      session_id: state.session_id,
      adapter_generation: state.adapter_generation,
      data: text,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(state.session_id, {:terminal_output, payload})

    if suppress_history?(state) do
      state
    else
      append_to_history(state, text)
    end
  end

  defp suppress_history?(%{history_suppressed_command_id: nil}), do: false

  defp suppress_history?(state) do
    state.active_command && state.active_command.id == state.history_suppressed_command_id
  end

  defp append_heredoc_marker_if_complete(
         %{active_command: %{heredoc_delimiter: delimiter, marker_sent?: false} = active} = state,
         data
       )
       when is_binary(delimiter) do
    terminator = ~r/(?:^|\r?\n)\s*#{Regex.escape(delimiter)}\s*(?:\r?\n|$)/

    if Regex.match?(terminator, data) do
      {data <> command_marker(active),
       %{state | active_command: Map.put(active, :marker_sent?, true)}}
    else
      {data, state}
    end
  end

  defp append_heredoc_marker_if_complete(state, data), do: {data, state}

  defp command_marker(entry) do
    "__iex_code_status=$?; printf '\\036IEX_CODE_COMMAND:#{entry.token}:%s\\037' \"$__iex_code_status\"\n"
  end

  defp heredoc_delimiter(command) do
    case Regex.run(~r/<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)/, command) do
      [_, delimiter] -> delimiter
      _ -> nil
    end
  end

  defp append_to_history(state, chunk) do
    chunk_size = byte_size(chunk)
    new_chunks = [chunk | state.history_buffer]
    new_total_bytes = state.buffer_bytes + chunk_size

    {trimmed_chunks, final_bytes} =
      prune_history(new_chunks, new_total_bytes, state.max_buffer_bytes)

    %{state | history_buffer: trimmed_chunks, buffer_bytes: final_bytes, cleared: false}
  end

  defp prune_history(chunks, total_bytes, max_bytes) when total_bytes <= max_bytes do
    {chunks, total_bytes}
  end

  defp prune_history(chunks, total_bytes, max_bytes) do
    case List.pop_at(chunks, -1) do
      {nil, []} ->
        {[], 0}

      {oldest, remaining} ->
        prune_history(remaining, total_bytes - byte_size(oldest), max_bytes)
    end
  end

  defp default_env(project_root) do
    %{
      "TERM" => "xterm-256color",
      "COLORTERM" => "truecolor",
      "LANG" => "en_US.UTF-8",
      "WORKSPACE_ROOT" => project_root
    }
  end

  defp broadcast_event(session_id, payload) do
    Phoenix.PubSub.broadcast(@pubsub_server, "session:#{session_id}:terminal", payload)
  end

  defp broadcast_status(state) do
    payload = %{
      session_id: state.session_id,
      adapter_generation: state.adapter_generation,
      status: state.status,
      shell: (state.adapter && state.adapter.shell) || state.shell,
      occupant: state.active_occupant
    }

    broadcast_event(state.session_id, {:terminal_status, payload})
  end

  # A globally monotonic value scopes asynchronous lifecycle work even when a
  # public restart replaces the whole TerminalSession process. A per-process
  # counter would reset and could let a timed-out command signal the new PTY.
  defp next_adapter_generation do
    System.unique_integer([:positive, :monotonic])
  end

  defp stale_adapter_generation?(state, opts) do
    case Keyword.get(opts, :adapter_generation) do
      nil -> false
      generation -> generation != state.adapter_generation
    end
  end

  defp drain_pending_port_output(%{adapter: %PTYAdapter{port: port}} = state, timeout_ms)
       when is_port(port) do
    receive do
      {^port, {:data, _raw_bytes}} = msg ->
        case PTYAdapter.handle_port_message(state.adapter, msg) do
          {:output, data, new_adapter} ->
            new_state = process_output_bytes_sync(%{state | adapter: new_adapter}, data)
            drain_pending_port_output(new_state, 30)

          {:ready, os_pid, new_adapter} ->
            drain_pending_port_output(
              %{state | adapter: %{new_adapter | os_pid: os_pid}},
              timeout_ms
            )

          {:interrupt_boundary, boundary_id, new_adapter} ->
            new_state =
              settle_interrupt_boundary(%{state | adapter: new_adapter}, boundary_id)

            drain_pending_port_output(new_state, 30)

          _ ->
            state
        end
    after
      timeout_ms ->
        state
    end
  end

  defp drain_pending_port_output(state, _timeout_ms), do: state

  defp drain_active_command_output(%{active_command: nil} = state, _timeout_ms), do: state

  defp drain_active_command_output(state, timeout_ms) do
    command_id = state.active_command.id
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_drain_active_command_output(state, command_id, deadline)
  end

  defp do_drain_active_command_output(state, command_id, deadline) do
    if is_nil(state.active_command) or state.active_command.id != command_id do
      state
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case state.adapter do
        %PTYAdapter{port: port} when is_port(port) ->
          receive do
            {^port, {:data, _raw_bytes}} = msg ->
              new_state =
                case PTYAdapter.handle_port_message(state.adapter, msg) do
                  {:output, data, new_adapter} ->
                    process_output_bytes_sync(%{state | adapter: new_adapter}, data)

                  {:ready, os_pid, new_adapter} ->
                    %{state | adapter: %{new_adapter | os_pid: os_pid}}

                  {:interrupt_boundary, boundary_id, new_adapter} ->
                    settle_interrupt_boundary(%{state | adapter: new_adapter}, boundary_id)

                  {:noop, new_adapter} ->
                    %{state | adapter: new_adapter}

                  _ ->
                    state
                end

              do_drain_active_command_output(new_state, command_id, deadline)
          after
            remaining -> state
          end

        _ ->
          state
      end
    end
  end

  defp process_output_bytes_sync(state, raw_bytes) when is_binary(raw_bytes) do
    {valid_text, new_acc} = UTF8Buffer.process_bytes(state.utf8_acc, raw_bytes)

    new_state =
      if valid_text != "" do
        consume_command_output(state, valid_text)
      else
        state
      end

    %{new_state | utf8_acc: new_acc}
  end

  defp do_search_history(state, query, opts) do
    raw_history =
      if state.cleared do
        ""
      else
        state.history_buffer
        |> Enum.reverse()
        |> IO.iodata_to_binary()
      end

    if raw_history == "" or query == "" do
      {:ok, []}
    else
      case compile_search_matcher(query, opts) do
        {:ok, matcher_fn} ->
          strip_ansi? = Keyword.get(opts, :strip_ansi, true)
          limit = Keyword.get(opts, :limit, Keyword.get(opts, :max_results, 100))
          reverse? = Keyword.get(opts, :reverse, false)

          lines =
            raw_history
            |> String.split(~r/\r\n|\r|\n/)
            |> Enum.reject(&terminal_input_echo?(&1, state))
            |> Enum.with_index(1)

          lines_to_search = if reverse?, do: Enum.reverse(lines), else: lines

          matches =
            lines_to_search
            |> Enum.reduce_while([], fn {line, line_num}, acc ->
              processed_line = if strip_ansi?, do: strip_ansi(line), else: line

              case matcher_fn.(processed_line) do
                {:match, match_range} ->
                  item = %{
                    line_number: line_num,
                    text: processed_line,
                    match_range: match_range
                  }

                  new_acc = [item | acc]

                  if limit != :infinity and length(new_acc) >= limit do
                    {:halt, new_acc}
                  else
                    {:cont, new_acc}
                  end

                :nomatch ->
                  {:cont, acc}
              end
            end)
            |> Enum.reverse()

          {:ok, matches}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp compile_search_matcher(%Regex{} = regex, _opts) do
    matcher = fn line ->
      case Regex.run(regex, line, return: :index) do
        [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
        nil -> :nomatch
      end
    end

    {:ok, matcher}
  end

  defp compile_search_matcher(query, opts) when is_binary(query) do
    case_sensitive? = Keyword.get(opts, :case_sensitive, false)
    is_regex? = Keyword.get(opts, :regex, false) || Keyword.get(opts, :is_regex, false)
    modifiers = if case_sensitive?, do: "", else: "i"

    if is_regex? do
      case Regex.compile(query, modifiers) do
        {:ok, regex} ->
          matcher = fn line ->
            case Regex.run(regex, line, return: :index) do
              [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
              nil -> :nomatch
            end
          end

          {:ok, matcher}

        {:error, {reason, _pos}} ->
          {:error, {:invalid_regex, reason}}

        {:error, reason} ->
          {:error, {:invalid_regex, reason}}
      end
    else
      pattern = Regex.escape(query)

      case Regex.compile(pattern, modifiers) do
        {:ok, regex} ->
          matcher = fn line ->
            case Regex.run(regex, line, return: :index) do
              [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
              nil -> :nomatch
            end
          end

          {:ok, matcher}

        {:error, {reason, _pos}} ->
          {:error, {:invalid_regex, reason}}

        {:error, reason} ->
          {:error, {:invalid_regex, reason}}
      end
    end
  end

  defp strip_ansi(text) when is_binary(text) do
    text
    |> String.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\x1b\([a-zA-Z]/, "")
    |> String.replace(~r/\e\[[0-9;]*[mK]/, "")
  end

  defp terminal_input_echo?(line, state) do
    bracketed_paste_echo? =
      String.contains?(line, "\e[?2004h") or String.contains?(line, "\e[?2004l")

    normalized_line = line |> strip_ansi() |> String.trim()
    fingerprint = command_input_fingerprint(normalized_line)

    bracketed_paste_echo? or
      (normalized_line != "" and Enum.any?(state.recent_command_inputs, &(&1 == fingerprint)))
  end

  defp bounded_command_history(entries) do
    {bounded, _bytes} =
      Enum.reduce_while(entries, {[], 0}, fn entry, {kept, bytes} ->
        command = command_summary(Map.get(entry, :command, ""))
        entry = Map.put(entry, :command, command)
        entry_bytes = byte_size(command)

        if length(kept) < @max_command_history_entries and
             bytes + entry_bytes <= @max_command_history_bytes do
          {:cont, {[entry | kept], bytes + entry_bytes}}
        else
          {:halt, {kept, bytes}}
        end
      end)

    Enum.reverse(bounded)
  end

  defp bounded_utf8(value, maximum) when byte_size(value) <= maximum, do: value

  defp bounded_utf8(value, maximum) do
    suffix = "… [truncated]"
    prefix = valid_utf8_prefix(value, maximum - byte_size(suffix))
    prefix <> suffix
  end

  defp valid_utf8_prefix(_value, maximum) when maximum <= 0, do: ""

  defp valid_utf8_prefix(value, maximum) do
    prefix = binary_part(value, 0, min(byte_size(value), maximum))

    if String.valid?(prefix),
      do: prefix,
      else: valid_utf8_prefix(value, maximum - 1)
  end

  defp redact_command_secrets(command) do
    command
    |> String.replace(
      ~r/\b((?:[A-Z][A-Z0-9_]*_)?(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|TOKEN|PASSWORD|PRIVATE_KEY|SECRET))=(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s]+)/u,
      "\\1=[REDACTED]"
    )
    |> String.replace(
      ~r/(?i)(--?(?:api[-_]?key|access[-_]?token|auth[-_]?token|token|password|private[-_]?key|secret)(?:=|\s+))(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s]+)/u,
      "\\1[REDACTED]"
    )
    |> String.replace(
      ~r/(?i)((?:authorization|proxy-authorization):\s*(?:bearer|basic)\s+|(?:x-api-key|api-key|x-goog-api-key|ocp-apim-subscription-key):\s*)([^'"\s]+)/u,
      "\\1[REDACTED]"
    )
  end

  defp command_input_fingerprint(input),
    do: :crypto.hash(:sha256, input)

  defp authorize_user_effect(state, generation) do
    cond do
      generation != state.adapter_generation -> {:error, :stale_terminal_generation}
      state.active_occupant != :user -> {:error, :agent_occupied}
      true -> :ok
    end
  end
end
