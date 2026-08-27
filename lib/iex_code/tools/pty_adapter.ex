defmodule IexCode.Tools.PTYAdapter do
  @moduledoc """
  Dual-mode adapter managing OS shell processes.
  Supports POSIX pseudo-terminal allocation via `priv/pty_shim.py` (:pty mode)
  with graceful fallback to native pipe-based Erlang Ports (:fallback mode).
  """
  require Logger

  @type mode :: :pty | :fallback
  @type signal ::
          :sigint
          | :sigterm
          | :sigkill
          | :sighup
          | :sigwinch
          | :sigquit
          | :sigtstp
          | :sigcont
          | :interrupt
          | :kill
          | :suspend
          | :continue
          | binary()
          | integer()

  defstruct [
    :port,
    :mode,
    :os_pid,
    :shim_pid,
    :cols,
    :rows,
    :cwd,
    :shell
  ]

  @type t :: %__MODULE__{
          port: port(),
          mode: mode(),
          os_pid: integer() | nil,
          shim_pid: integer() | nil,
          cols: pos_integer(),
          rows: pos_integer(),
          cwd: String.t(),
          shell: String.t() | nil
        }

  @doc """
  Spawns an interactive shell process wrapped in a PTY master/slave pair
  or a standard Erlang Port.
  """
  @spec open(opts :: keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    cwd =
      Keyword.get(opts, :cwd) ||
        Keyword.get(opts, :workspace_path) ||
        Keyword.get(opts, :project_root) ||
        File.cwd!()

    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    shell = Keyword.get(opts, :shell)
    env = Keyword.get(opts, :env, default_env(cwd))
    requested_mode = Keyword.get(opts, :mode)

    mode = determine_mode(requested_mode)

    case mode do
      :pty ->
        open_pty(cwd, cols, rows, shell, env)

      :fallback ->
        open_fallback(cwd, cols, rows, shell, env)
    end
  end

  @doc """
  Sends raw stdin binary data (keystrokes, commands, escape sequences) to the shell process.
  """
  @spec send_input(adapter :: t(), data :: binary()) :: :ok | {:error, term()}
  def send_input(%__MODULE__{port: port, mode: :pty}, data) when is_binary(data) do
    try do
      # Opcode 1 = OP_INPUT
      Port.command(port, <<1, data::binary>>)
      :ok
    rescue
      e in ArgumentError -> {:error, {:port_error, e}}
    end
  end

  def send_input(%__MODULE__{port: port, mode: :fallback}, data) when is_binary(data) do
    try do
      Port.command(port, data)
      :ok
    rescue
      e in ArgumentError -> {:error, {:port_error, e}}
    end
  end

  def send_input(_adapter, _data), do: {:error, :invalid_adapter}

  @doc """
  Resizes the terminal window dimensions (columns x rows) and triggers SIGWINCH in PTY mode.
  In fallback mode, this is a safe no-op.
  """
  @spec resize(adapter :: t(), cols :: pos_integer(), rows :: pos_integer()) ::
          {:ok, t()} | {:error, term()}
  def resize(%__MODULE__{port: port, mode: :pty} = adapter, cols, rows)
      when is_integer(cols) and is_integer(rows) do
    c = max(1, cols)
    r = max(1, rows)

    try do
      # Opcode 2 = OP_RESIZE: <<cols::16-big, rows::16-big>>
      Port.command(port, <<2, c::16-big, r::16-big>>)
      {:ok, %{adapter | cols: c, rows: r}}
    rescue
      e in ArgumentError -> {:error, {:port_error, e}}
    end
  end

  def resize(%__MODULE__{mode: :fallback} = adapter, cols, rows)
      when is_integer(cols) and is_integer(rows) do
    {:ok, %{adapter | cols: max(1, cols), rows: max(1, rows)}}
  end

  def resize(_adapter, _cols, _rows), do: {:error, :invalid_adapter}

  @doc """
  Sends an OS signal or control character to the child process.
  """
  @spec send_signal(adapter_or_pid :: t() | integer(), signal :: signal()) ::
          :ok | {:error, term()}
  def send_signal(%__MODULE__{port: port, mode: :pty}, signal) do
    sig_num = signal_to_int(signal)

    try do
      # Opcode 3 = OP_SIGNAL: <<sig_num::8>>
      Port.command(port, <<3, sig_num::8>>)
      :ok
    rescue
      e in ArgumentError -> {:error, {:port_error, e}}
    end
  end

  def send_signal(%__MODULE__{mode: :fallback, os_pid: os_pid, port: port}, signal) do
    if signal in [:sigint, :interrupt, "SIGINT"] do
      try do
        Port.command(port, <<3>>)
      rescue
        _ -> :ok
      end
    end

    if is_integer(os_pid) and os_pid > 0 do
      signal_os_pid(os_pid, signal)
    else
      :ok
    end
  end

  def send_signal(os_pid, signal) when is_integer(os_pid) and os_pid > 0 do
    signal_os_pid(os_pid, signal)
  end

  def send_signal(_target, _signal), do: {:error, :invalid_target}

  @doc "Terminates an OS process group, falling back to its leader when necessary."
  @spec terminate_process_group(pos_integer(), signal()) :: :ok
  def terminate_process_group(os_pid, signal \\ :sigkill)

  def terminate_process_group(os_pid, signal)
      when is_integer(os_pid) and os_pid > 0 do
    signal_os_pid(os_pid, signal)
  end

  def terminate_process_group(_os_pid, _signal), do: :ok

  @doc false
  @spec send_tracked_signal(t(), signal(), non_neg_integer()) :: :ok | {:error, term()}
  def send_tracked_signal(
        %__MODULE__{port: port, mode: :pty},
        signal,
        boundary_id
      )
      when is_integer(boundary_id) and boundary_id >= 0 and boundary_id <= 0xFFFFFFFFFFFFFFFF do
    sig_num = signal_to_int(signal)

    try do
      Port.command(port, <<3, sig_num::8, boundary_id::unsigned-big-64>>)
      :ok
    rescue
      e in ArgumentError -> {:error, {:port_error, e}}
    end
  end

  def send_tracked_signal(%__MODULE__{} = adapter, signal, _boundary_id) do
    send_signal(adapter, signal)
  end

  def send_tracked_signal(_adapter, _signal, _boundary_id), do: {:error, :invalid_target}

  @doc """
  Closes the port and cleanly tears down child processes.
  """
  @spec close(adapter :: t()) :: :ok
  def close(%__MODULE__{port: port, mode: :pty, shim_pid: shim_pid, os_pid: shell_pid}) do
    if is_port(port) do
      shim_pid = shim_pid || port_os_pid(port)

      # Output backpressure can block the shim in stdout and prevent it from
      # reading an OP_CLOSE control frame. SIGTERM invokes its teardown handler
      # out-of-band, which kills foreground jobs, kills the shell group, and
      # synchronously waitpid-reaps the shell before exiting.
      if shim_pid, do: signal_single_pid(shim_pid, 15)

      # Give the shim ownership of teardown: it terminates and waitpid-reaps
      # the session leader before exiting. Do not consume Port exit messages
      # here: they are delivered to the TerminalSession owner, while callers of
      # close/1 may be different processes during supervised lifecycle churn.
      wait_for_port_close(port, shim_pid, 1_000)

      if Port.info(port) do
        if shell_pid, do: kill_process_tree(shell_pid)
        if shim_pid, do: signal_single_pid(shim_pid, 9)

        try do
          Port.close(port)
        rescue
          _ -> :ok
        end
      end
    else
      if shell_pid, do: kill_process_tree(shell_pid)
      if shim_pid, do: signal_single_pid(shim_pid, 9)
    end

    :ok
  end

  def close(%__MODULE__{port: port, mode: :fallback, os_pid: os_pid}) do
    if is_port(port) do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    if is_integer(os_pid) and os_pid > 0 do
      signal_os_pid(os_pid, :sigkill)
    end

    :ok
  end

  def close(_adapter), do: :ok

  defp wait_for_port_close(_port, _shim_pid, remaining_ms) when remaining_ms <= 0, do: :timeout

  defp wait_for_port_close(port, shim_pid, remaining_ms) do
    if Port.info(port) do
      case Port.info(port, :connected) do
        {:connected, owner} when owner == self() ->
          receive do
            {^port, {:exit_status, _status}} -> :ok
            {:EXIT, ^port, _reason} -> :ok
          after
            10 -> wait_for_port_close(port, shim_pid, remaining_ms - 10)
          end

        _different_owner ->
          receive do
          after
            10 -> wait_for_port_close(port, shim_pid, remaining_ms - 10)
          end
      end
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp signal_single_pid(pid, signal) do
    _ = System.cmd("kill", ["-#{signal}", to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  catch
    _, _ -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp kill_process_tree(pid) when is_integer(pid) and pid > 0 do
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

    Enum.each(children, &kill_process_tree/1)
    _ = signal_os_pid(pid, :sigkill)
    :ok
  end

  defp kill_process_tree(_pid), do: :ok

  @doc """
  Processes a raw message from the Erlang Port.
  Returns `{:output, data, adapter}`, `{:exit, exit_code, adapter}`,
  `{:ready, os_pid, adapter}`, `{:interrupt_boundary, id, adapter}`,
  `{:noop, adapter}`, or `:unknown`.
  """
  @spec handle_port_message(adapter :: t(), msg :: term()) ::
          {:output, binary(), t()}
          | {:exit, integer(), t()}
          | {:ready, integer(), t()}
          | {:interrupt_boundary, non_neg_integer(), t()}
          | {:noop, t()}
          | :unknown
  def handle_port_message(%__MODULE__{port: port, mode: :pty} = adapter, {port, {:data, payload}}) do
    case payload do
      <<1, data::binary>> ->
        # OP_OUTPUT
        {:output, data, adapter}

      <<2, exit_code::32-signed-big>> ->
        # OP_EXIT
        {:exit, exit_code, adapter}

      <<3, child_pid::32-signed-big>> ->
        # OP_READY
        {:ready, child_pid, %{adapter | os_pid: child_pid}}

      <<4, boundary_id::unsigned-big-64>> ->
        # OP_INTERRUPT_BOUNDARY
        {:interrupt_boundary, boundary_id, adapter}

      _other ->
        {:noop, adapter}
    end
  end

  def handle_port_message(
        %__MODULE__{port: port, mode: :fallback} = adapter,
        {port, {:data, data}}
      ) do
    {:output, data, adapter}
  end

  def handle_port_message(
        %__MODULE__{port: port} = adapter,
        {port, {:exit_status, status}}
      ) do
    {:exit, status, adapter}
  end

  def handle_port_message(_adapter, _msg), do: :unknown

  # --- Internal Helpers ---

  defp determine_mode(:fallback), do: :fallback
  defp determine_mode(:pty), do: :pty

  defp determine_mode(nil) do
    python_path = find_python()
    shim_path = shim_file_path()

    if python_path != nil and File.exists?(shim_path) do
      :pty
    else
      :fallback
    end
  end

  defp open_pty(cwd, cols, rows, shell, env) do
    python_path = find_python()
    shim_path = shim_file_path()

    if is_nil(python_path) or not File.exists?(shim_path) do
      open_fallback(cwd, cols, rows, shell, env)
    else
      args = [
        shim_path,
        "--cols",
        to_string(cols),
        "--rows",
        to_string(rows),
        "--cwd",
        cwd
      ]

      args = if shell && shell != "", do: args ++ ["--shell", shell], else: args

      port_opts = [
        :binary,
        {:packet, 4},
        :use_stdio,
        :exit_status,
        :hide,
        args: args,
        env: format_env(env)
      ]

      try do
        port = Port.open({:spawn_executable, python_path}, port_opts)

        os_pid =
          receive do
            {^port, {:data, <<3, child_pid::32-signed-big>>}} ->
              child_pid
          after
            500 ->
              nil
          end

        {:ok,
         %__MODULE__{
           port: port,
           mode: :pty,
           os_pid: os_pid,
           shim_pid: port_os_pid(port),
           cols: cols,
           rows: rows,
           cwd: cwd,
           shell: shell || default_shell()
         }}
      rescue
        e ->
          Logger.warning(
            "[PTYAdapter] PTY open failed, falling back to native Port: #{inspect(e)}"
          )

          open_fallback(cwd, cols, rows, shell, env)
      end
    end
  end

  defp open_fallback(cwd, cols, rows, shell, env) do
    shell_bin =
      shell ||
        System.get_env("SHELL") ||
        System.find_executable("zsh") ||
        System.find_executable("bash") ||
        "/bin/sh"

    port_opts = [
      :binary,
      :stream,
      :use_stdio,
      :exit_status,
      :hide,
      cd: cwd,
      args: ["-l"],
      env: format_env(env)
    ]

    try do
      port = Port.open({:spawn_executable, shell_bin}, port_opts)
      info = Port.info(port)
      os_pid = info[:os_pid]

      {:ok,
       %__MODULE__{
         port: port,
         mode: :fallback,
         os_pid: os_pid,
         cols: cols,
         rows: rows,
         cwd: cwd,
         shell: shell_bin
       }}
    rescue
      e ->
        {:error, {:fallback_spawn_failed, e}}
    end
  end

  defp find_python do
    System.find_executable("python3") || System.find_executable("python")
  end

  defp shim_file_path do
    case :code.priv_dir(:iex_code) do
      {:error, :bad_name} ->
        Path.expand("priv/pty_shim.py")

      priv_dir when is_list(priv_dir) or is_binary(priv_dir) ->
        Path.join(to_string(priv_dir), "pty_shim.py")
    end
  end

  defp default_shell do
    System.get_env("SHELL") ||
      System.find_executable("zsh") ||
      System.find_executable("bash") ||
      "/bin/sh"
  end

  defp default_env(cwd) do
    %{
      "TERM" => "xterm-256color",
      "COLORTERM" => "truecolor",
      "LANG" => "en_US.UTF-8",
      "WORKSPACE_ROOT" => cwd
    }
  end

  defp format_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp format_env(env) when is_list(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp format_env(_), do: []

  defp signal_os_pid(os_pid, signal) when is_integer(os_pid) and os_pid > 0 do
    sig_num = signal_to_int(signal)

    try do
      # Attempt process group kill first (-pid), then single process kill
      case System.cmd("kill", ["-" <> to_string(sig_num), "-" <> to_string(os_pid)],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        _ ->
          System.cmd("kill", ["-" <> to_string(sig_num), to_string(os_pid)],
            stderr_to_stdout: true
          )

          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp signal_to_int(:sigint), do: 2
  defp signal_to_int(:interrupt), do: 2
  defp signal_to_int("SIGINT"), do: 2
  defp signal_to_int(:sigquit), do: 3
  defp signal_to_int("SIGQUIT"), do: 3
  defp signal_to_int(:sighup), do: 1
  defp signal_to_int("SIGHUP"), do: 1
  defp signal_to_int(:sigkill), do: 9
  defp signal_to_int(:kill), do: 9
  defp signal_to_int("SIGKILL"), do: 9
  defp signal_to_int(:sigterm), do: 15
  defp signal_to_int("SIGTERM"), do: 15
  defp signal_to_int(:sigcont), do: 19
  defp signal_to_int(:continue), do: 19
  defp signal_to_int("SIGCONT"), do: 19
  defp signal_to_int(:sigtstp), do: 20
  defp signal_to_int(:suspend), do: 20
  defp signal_to_int("SIGTSTP"), do: 20
  defp signal_to_int(:sigwinch), do: 28
  defp signal_to_int("SIGWINCH"), do: 28
  defp signal_to_int(int) when is_integer(int), do: int
  defp signal_to_int(_), do: 15
end
