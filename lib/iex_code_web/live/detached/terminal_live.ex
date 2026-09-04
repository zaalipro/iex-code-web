defmodule IexCodeWeb.Detached.TerminalLive do
  @moduledoc """
  Dedicated standalone LiveView for the native detached Terminal Multiplexer.
  Supports real-time bi-directional PTY I/O, quick actions, tab switching,
  and instant synchronization with the primary workspace.
  """

  use IexCodeWeb, :live_view
  require Logger

  alias IexCode.Sessions
  alias IexCode.Tools.TerminalServer
  alias IexCode.Tools.TerminalSession
  alias IexCodeWeb.WorkspaceComponents

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:terminal")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")
    end

    session = Sessions.get_session!(session_id)

    shell_status =
      case TerminalServer.get_state(session_id) do
        {:ok, s} ->
          s

        _ ->
          %{
            running: TerminalServer.running?(session_id),
            shell: "zsh",
            cols: 120,
            rows: 36,
            history: []
          }
      end

    {:ok,
     socket
     |> assign(:page_title, "Terminal Multiplexer — #{session_id}")
     |> assign(:current_scope, nil)
     |> assign(:session, session)
     |> assign(:session_id, session_id)
     |> assign(:active_tab, "shell")
     |> assign(:tabs, [
       %{id: "shell", label: "Shell", icon: "hero-command-line"},
       %{id: "iex", label: "iex -S mix", icon: "hero-bolt"},
       %{id: "test", label: "mix test", icon: "hero-play"}
     ])
     |> assign(:status, if(shell_status.running, do: :running, else: :stopped))
     |> assign(:running, shell_status.running)
     |> assign(:shell, shell_status[:shell] || "zsh")
     |> assign(:cols, shell_status[:cols] || 120)
     |> assign(:rows, shell_status[:rows] || 36)
     |> assign(:terminal_history, shell_status[:history] || [])
     |> assign(:terminal_active_cmd, nil)
     |> assign(:terminal_output, "")
     |> assign(:workspace_locks, [])
     |> assign(:terminal_form, to_form(%{"command" => ""}))
     |> assign(:input_locked, false)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    case tab do
      "iex" ->
        _ = TerminalServer.run_command_with_id(socket.assigns.session_id, "iex -S mix")

      "test" ->
        _ = TerminalServer.run_command_with_id(socket.assigns.session_id, "mix test")

      _ ->
        :ok
    end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    session_id = socket.assigns.session_id

    case TerminalServer.send_input(session_id, data) do
      :ok ->
        {:noreply, socket}

      {:error, :agent_occupied} ->
        {:noreply, put_flash(socket, :warning, "Terminal is locked by active agent.")}

      {:error, reason} ->
        Logger.warning("[TerminalLive] Input error: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_resize", params, socket) do
    session_id = socket.assigns.session_id
    cols = parse_dim(params["cols"] || params[:cols], socket.assigns.cols)
    rows = parse_dim(params["rows"] || params[:rows], socket.assigns.rows)

    if cols > 0 and rows > 0 do
      _ = TerminalServer.resize(session_id, cols, rows)
      {:noreply, socket |> assign(:cols, cols) |> assign(:rows, rows)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_terminal_quick_action", params, socket) do
    cmd = params["cmd"] || params["command"] || ""
    session_id = socket.assigns.session_id

    if String.trim(cmd) != "" do
      case TerminalServer.run_command_with_id(session_id, cmd) do
        {:ok, _id} ->
          public_cmd = TerminalSession.command_summary(cmd)

          updated =
            [public_cmd | Enum.reject(socket.assigns.terminal_history, &(&1 == public_cmd))]
            |> Enum.take(25)

          {:noreply,
           socket
           |> assign(:terminal_history, updated)
           |> assign(:terminal_active_cmd, public_cmd)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Command failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_terminal", _params, socket) do
    session_id = socket.assigns.session_id
    _ = TerminalServer.clear(session_id)
    {:noreply, socket |> assign(:terminal_output, "") |> push_event("terminal_clear", %{})}
  end

  @impl true
  def handle_event("restart_terminal_session", _params, socket) do
    session_id = socket.assigns.session_id
    _ = TerminalServer.restart(session_id)
    {:noreply, put_flash(socket, :info, "Terminal session restarted.")}
  end

  # PubSub Info Handlers

  @impl true
  def handle_info({:terminal_output, %{session_id: sid, data: data}}, socket) do
    if sid == socket.assigns.session_id do
      {:noreply, push_event(socket, "terminal_output", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_output, sid, data}, socket)
      when is_binary(sid) and is_binary(data) do
    if sid == socket.assigns.session_id do
      {:noreply, push_event(socket, "terminal_output", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_history, %{session_id: sid, history: history}}, socket) do
    if sid == socket.assigns.session_id do
      {:noreply, push_event(socket, "terminal_history", %{data: history})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_clear, %{session_id: sid}}, socket) do
    if sid == socket.assigns.session_id do
      {:noreply, socket |> assign(:terminal_output, "") |> push_event("terminal_clear", %{})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_status, %{running: running} = st}, socket) do
    {:noreply,
     socket
     |> assign(:running, running)
     |> assign(:status, if(running, do: :running, else: :stopped))
     |> assign(:shell, st[:shell] || socket.assigns.shell)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp parse_dim(val, _default) when is_integer(val) and val > 0, do: val

  defp parse_dim(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, ""} when num > 0 -> num
      _ -> default
    end
  end

  defp parse_dim(_, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="detached-terminal-container"
        class="flex flex-col h-screen w-screen bg-[#0a0d12] overflow-hidden"
      >
        <!-- Top Navigation Bar -->
        <header class="flex items-center justify-between px-4 py-2.5 bg-[#161b22] border-b border-[#30363d] shrink-0">
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.5)]"></span>
              <span class="font-mono text-sm font-semibold text-white tracking-wide">TERMINAL MULTIPLEXER</span>
            </div>
            <span class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
              Session: {@session_id}
            </span>
          </div>

          <!-- Multiplexer Tabs -->
          <div class="flex items-center gap-1 bg-[#0d1117] p-1 rounded-lg border border-[#30363d]">
            <%= for tab <- @tabs do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab.id}
                class={[
                  "flex items-center gap-1.5 px-3 py-1 rounded text-xs font-mono transition-smooth",
                  @active_tab == tab.id && "bg-[#21262d] text-white font-bold shadow-sm",
                  @active_tab != tab.id && "text-zinc-400 hover:text-zinc-200"
                ]}
              >
                <.icon name={tab.icon} class="w-3.5 h-3.5" />
                <span>{tab.label}</span>
              </button>
            <% end %>
          </div>

          <!-- Actions -->
          <div class="flex items-center gap-2">
            <button
              phx-click="restart_terminal_session"
              class="px-2.5 py-1 text-xs font-mono rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-300 border border-[#30363d] transition-smooth flex items-center gap-1"
              title="Restart PTY"
            >
              <.icon name="hero-arrow-path" class="w-3 h-3" />
              <span>Restart</span>
            </button>
            <button
              phx-click="clear_terminal"
              class="px-2.5 py-1 text-xs font-mono rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-300 border border-[#30363d] transition-smooth flex items-center gap-1"
              title="Clear screen"
            >
              <.icon name="hero-trash" class="w-3 h-3" />
              <span>Clear</span>
            </button>
          </div>
        </header>

        <!-- Main Terminal Body -->
        <main class="flex-1 min-h-0 relative">
          <WorkspaceComponents.terminal_session
            session={@session}
            workspace_locks={@workspace_locks}
            status={@status}
            shell={@shell}
            cols={@cols}
            rows={@rows}
            running={@running}
            occupant={:user}
            active_cmd={@terminal_active_cmd}
            output={@terminal_output}
            form={@terminal_form}
          />
        </main>
      </div>
    </Layouts.app>
    """
  end
end
