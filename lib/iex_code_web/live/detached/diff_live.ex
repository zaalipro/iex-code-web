defmodule IexCodeWeb.Detached.DiffLive do
  @moduledoc """
  Dedicated standalone LiveView for Git 3-tier Staging Hub and Diff Inspector.
  Provides full-window side-by-side or inline diff viewing, granular hunk staging/unstaging,
  AI commit generation, and real-time PubSub synchronization with the primary workspace.
  """

  use IexCodeWeb, :live_view
  require Logger

  alias IexCode.Projects
  alias IexCode.Sessions
  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.Git.HunkOps
  alias IexCodeWeb.WorkspaceComponents

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)

    project =
      cond do
        is_struct(session) and Map.has_key?(session, :project) and
            is_struct(session.project, Projects.Project) ->
          session.project

        is_struct(session) and Map.has_key?(session, :project_id) and
            is_binary(session.project_id) ->
          Projects.get_project!(session.project_id)

        is_map(session) and Map.get(session, :project) != nil and
            is_struct(Map.get(session, :project)) ->
          Map.get(session, :project)

        is_map(session) and Map.get(session, :project_id) != nil ->
          Projects.get_project!(Map.get(session, :project_id))

        true ->
          %{id: "default", name: "Project", root_path: "."}
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(IexCode.PubSub, "project:#{project.id}:git")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")
    end

    checkpoints = IexCode.TimeTravel.list_checkpoints(session_id)

    socket =
      socket
      |> assign(:page_title, "Git Changes & Diff Inspector — #{session_id}")
      |> assign(:current_scope, nil)
      |> assign(:session, session)
      |> assign(:session_id, session_id)
      |> assign(:project, project)
      |> assign(:changes_subtab, "changes")
      |> assign(:checkpoints, checkpoints)
      |> assign(:selected_checkpoint, List.first(checkpoints))
      |> assign(:diff_mode, "split")
      |> assign(:active_diff_scope, :unstaged)
      |> assign(:selected_diff_file, nil)
      |> assign(:diff_file_path, nil)
      |> assign(:diff_text, "")
      |> assign(:diff_hunks, [])
      |> assign(:commit_message, "")
      |> assign(:creating_branch?, false)
      |> assign(:new_branch_name, "")
      |> assign(:git_status, %{staged: [], unstaged: [], untracked: []})
      |> assign(:branches, [])
      |> assign(:current_branch, "main")
      |> refresh_git_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_changes_subtab", %{"tab" => tab}, socket) do
    checkpoints = IexCode.TimeTravel.list_checkpoints(socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(:changes_subtab, tab)
     |> assign(:checkpoints, checkpoints)
     |> assign(
       :selected_checkpoint,
       socket.assigns[:selected_checkpoint] || List.first(checkpoints)
     )}
  end

  @impl true
  def handle_event("select_checkpoint", %{"tx_id" => tx_id}, socket) do
    checkpoint =
      Enum.find(socket.assigns.checkpoints, fn cp ->
        cp.transaction_id == tx_id or cp.id == tx_id or to_string(cp.transaction_id) == tx_id or
          to_string(cp.id) == tx_id
      end) || IexCode.TimeTravel.get_checkpoint(tx_id)

    {:noreply, assign(socket, :selected_checkpoint, checkpoint)}
  end

  @impl true
  def handle_event("rollback_to_checkpoint", %{"tx_id" => tx_id}, socket) do
    session_id = socket.assigns.session_id

    case IexCode.TimeTravel.rollback_to(tx_id, session_id: session_id) do
      {:ok, summary} ->
        checkpoints = IexCode.TimeTravel.list_checkpoints(session_id)
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> assign(:checkpoints, checkpoints)
         |> assign(:selected_checkpoint, List.first(checkpoints))
         |> refresh_git_state()
         |> put_flash(
           :info,
           "Rolled back #{summary.reverted_checkpoints} checkpoint(s) successfully."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rollback failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rollback_latest_checkpoint", _params, socket) do
    session_id = socket.assigns.session_id

    case IexCode.TimeTravel.rollback_latest(session_id) do
      {:ok, summary} ->
        checkpoints = IexCode.TimeTravel.list_checkpoints(session_id)
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> assign(:checkpoints, checkpoints)
         |> assign(:selected_checkpoint, List.first(checkpoints))
         |> refresh_git_state()
         |> put_flash(
           :info,
           "Rolled back #{summary.reverted_checkpoints} checkpoint successfully."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rollback failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("set_diff_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :diff_mode, mode)}
  end

  @impl true
  def handle_event("set_diff_scope", %{"scope" => scope}, socket) do
    scope_atom = if scope == "staged", do: :staged, else: :unstaged
    {:noreply, socket |> assign(:active_diff_scope, scope_atom) |> refresh_git_state()}
  end

  @impl true
  def handle_event("select_diff_file", %{"file" => file, "scope" => scope}, socket) do
    scope_atom = if scope == "staged", do: :staged, else: :unstaged

    {:noreply,
     socket
     |> assign(:selected_diff_file, file)
     |> assign(:active_diff_scope, scope_atom)
     |> refresh_git_state()}
  end

  @impl true
  def handle_event("stage_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case Git.stage(file, root) do
      :ok ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Staging failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case Git.unstage(file, root) do
      :ok ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstaging failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("stage_all", _params, socket) do
    root = socket.assigns.project.root_path

    case Git.stage(:all, root) do
      :ok ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Stage all failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_all", _params, socket) do
    root = socket.assigns.project.root_path

    case Git.unstage(:all, root) do
      :ok ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstage all failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case HunkOps.unstage_hunk(root, file, hunk_id) do
      {:ok, _diff} ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstage hunk failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("accept_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case HunkOps.accept_hunk(root, file, hunk_id, diff: socket.assigns[:diff_text]) do
      {:ok, _} ->
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Accepted hunk #{hunk_id} for #{file}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to accept hunk: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case HunkOps.reject_hunk(root, file, hunk_id, diff: socket.assigns[:diff_text]) do
      {:ok, _} ->
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Reverted hunk #{hunk_id} in #{file}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revert hunk: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("revert_hunk", params, socket), do: handle_event("reject_hunk", params, socket)

  @impl true
  def handle_event("accept_all_hunks", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case HunkOps.accept_all_hunks(root, file) do
      {:ok, _} ->
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Staged all changes for #{file}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stage changes: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("revert_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case HunkOps.revert_file(root, file) do
      {:ok, _} ->
        broadcast_git_changed(socket)

        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Reverted #{file} to clean git working state")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revert file: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("update_commit_message", params, socket) do
    msg = params["message"] || params["commit_message"] || ""
    {:noreply, assign(socket, :commit_message, msg)}
  end

  @impl true
  def handle_event("generate_commit_msg", _params, socket) do
    root = socket.assigns.project.root_path

    case Git.generate_commit_message(root) do
      {:ok, msg} ->
        {:noreply, assign(socket, :commit_message, msg)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to generate commit message: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("git_commit", _params, socket) do
    root = socket.assigns.project.root_path
    msg = String.trim(socket.assigns.commit_message || "")

    if msg == "" do
      {:noreply, put_flash(socket, :error, "Please enter a commit message")}
    else
      case Git.commit(msg, root) do
        {:ok, _res} ->
          broadcast_git_changed(socket)

          {:noreply,
           socket
           |> assign(:commit_message, "")
           |> put_flash(:info, "Changes committed successfully.")
           |> refresh_git_state()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Commit failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("switch_branch", %{"branch" => branch}, socket) do
    root = socket.assigns.project.root_path

    case Git.switch_branch(root, branch) do
      {:ok, _} ->
        broadcast_git_changed(socket)
        {:noreply, refresh_git_state(socket) |> put_flash(:info, "Switched to branch #{branch}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Switch branch failed: #{inspect(reason)}")}
    end
  end

  # PubSub Info Handlers

  @impl true
  def handle_info({:git_state_changed, _project_id}, socket) do
    drain_git_messages()
    {:noreply, refresh_git_state(socket)}
  end

  @impl true
  def handle_info({:checkpoint_created, checkpoint}, socket) do
    checkpoints =
      [checkpoint | socket.assigns[:checkpoints] || []]
      |> Enum.uniq_by(&(&1.transaction_id || &1.id))

    {:noreply,
     socket
     |> assign(:checkpoints, checkpoints)
     |> assign(:selected_checkpoint, socket.assigns[:selected_checkpoint] || checkpoint)}
  end

  @impl true
  def handle_info({:checkpoint_rolled_back, _tx_id, _details}, socket) do
    checkpoints = IexCode.TimeTravel.list_checkpoints(socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(:checkpoints, checkpoints)
     |> assign(:selected_checkpoint, List.first(checkpoints))
     |> refresh_git_state()}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp drain_git_messages do
    receive do
      {:git_state_changed, _} -> drain_git_messages()
    after
      0 -> :ok
    end
  end

  # Helpers

  defp broadcast_git_changed(socket) do
    project = socket.assigns.project
    project_id = if is_struct(project), do: project.id, else: project[:id]

    if project_id do
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project_id}:git",
        {:git_state_changed, project_id}
      )
    end
  end

  defp refresh_git_state(socket) do
    root = socket.assigns.project.root_path

    status =
      case Git.status(root) do
        {:ok, s} -> s
        _ -> %{staged: [], unstaged: [], untracked: []}
      end

    branches =
      case Git.branches(root) do
        {:ok, b} -> b
        _ -> []
      end

    current_branch =
      case Git.current_branch(root) do
        {:ok, cb} -> cb
        _ -> "main"
      end

    unstaged_diff_raw =
      case Git.diff(root, unified: 3) do
        {:ok, d} -> d || ""
        _ -> ""
      end

    staged_diff_raw =
      case Git.diff(root, staged: true, unified: 3) do
        {:ok, d} -> d || ""
        _ -> ""
      end

    unstaged_diffs = DiffParser.parse!(unstaged_diff_raw)
    staged_diffs = DiffParser.parse!(staged_diff_raw)
    parsed_diffs = unstaged_diffs ++ staged_diffs

    scope = socket.assigns[:active_diff_scope] || :unstaged

    active_list =
      case scope do
        :staged -> staged_diffs
        _ -> unstaged_diffs
      end

    selected_diff_file =
      socket.assigns[:selected_diff_file] ||
        (List.first(active_list) &&
           (List.first(active_list).path || List.first(active_list).new_path)) ||
        (List.first(parsed_diffs) &&
           (List.first(parsed_diffs).path || List.first(parsed_diffs).new_path)) ||
        socket.assigns[:diff_file_path]

    selected_file_diff =
      Enum.find(
        if(active_list != [], do: active_list, else: parsed_diffs),
        &(&1.path == selected_diff_file or &1.new_path == selected_diff_file or
            &1.old_path == selected_diff_file)
      )

    diff_hunks = if selected_file_diff, do: selected_file_diff.hunks, else: []

    diff_text =
      cond do
        selected_file_diff && selected_file_diff.hunks != [] ->
          Enum.map_join(
            selected_file_diff.hunks,
            "\n",
            &DiffParser.format_hunk_patch(selected_file_diff, &1)
          )

        scope == :staged and staged_diff_raw != "" ->
          staged_diff_raw

        true ->
          unstaged_diff_raw
      end

    socket
    |> assign(:git_status, status)
    |> assign(:branches, branches)
    |> assign(:current_branch, current_branch)
    |> assign(:selected_diff_file, selected_diff_file)
    |> assign(:diff_file_path, selected_diff_file)
    |> assign(:diff_hunks, diff_hunks)
    |> assign(:diff_text, diff_text)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="detached-diff-container"
        class="flex flex-col h-screen w-screen bg-[#0a0d12] overflow-hidden text-gray-200"
      >
        <!-- Top Navigation Bar -->
        <header class="flex items-center justify-between px-4 py-2.5 bg-[#161b22] border-b border-[#30363d] shrink-0">
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-blue-500 shadow-[0_0_8px_rgba(59,130,246,0.5)]"></span>
              <span class="font-mono text-sm font-semibold text-white tracking-wide">GIT STAGING & DIFF INSPECTOR</span>
            </div>
            <span class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
              Branch: <span class="text-blue-400 font-bold">{@current_branch}</span>
            </span>

            <!-- Subtab Switcher: Staging & Diff vs Time-Travel -->
            <div class="flex items-center gap-1 bg-[#0d1117] p-1 rounded-lg border border-[#30363d] text-xs font-mono ml-2">
              <button
                type="button"
                phx-click="switch_changes_subtab"
                phx-value-tab="changes"
                class={[
                  "px-2.5 py-1 rounded transition-smooth flex items-center gap-1.5",
                  @changes_subtab == "changes" && "bg-blue-600 text-white font-semibold",
                  @changes_subtab != "changes" && "text-zinc-400 hover:text-white"
                ]}
              >
                <.icon name="hero-arrows-right-left" class="w-3.5 h-3.5" />
                <span>Staging & Diff</span>
              </button>
              <button
                type="button"
                phx-click="switch_changes_subtab"
                phx-value-tab="checkpoints"
                class={[
                  "px-2.5 py-1 rounded transition-smooth flex items-center gap-1.5",
                  @changes_subtab == "checkpoints" && "bg-blue-600 text-white font-semibold",
                  @changes_subtab != "checkpoints" && "text-zinc-400 hover:text-white"
                ]}
              >
                <.icon name="hero-clock" class="w-3.5 h-3.5" />
                <span>Time-Travel ({length(@checkpoints)})</span>
              </button>
            </div>
          </div>

          <!-- Top Right Actions -->
          <div class="flex items-center gap-3">
            <%= if @changes_subtab == "changes" do %>
              <!-- Scope Toggles (Unstaged vs Staged) -->
              <div class="flex items-center gap-1 bg-[#0d1117] p-1 rounded-lg border border-[#30363d] text-xs font-mono">
                <button
                  type="button"
                  phx-click="set_diff_scope"
                  phx-value-scope="unstaged"
                  class={[
                    "px-3 py-1 rounded transition-smooth",
                    @active_diff_scope == :unstaged && "bg-[#21262d] text-white font-bold",
                    @active_diff_scope != :unstaged && "text-zinc-400 hover:text-zinc-200"
                  ]}
                >
                  Unstaged ({length(@git_status.unstaged)})
                </button>
                <button
                  type="button"
                  phx-click="set_diff_scope"
                  phx-value-scope="staged"
                  class={[
                    "px-3 py-1 rounded transition-smooth",
                    @active_diff_scope == :staged && "bg-[#21262d] text-white font-bold",
                    @active_diff_scope != :staged && "text-zinc-400 hover:text-zinc-200"
                  ]}
                >
                  Staged ({length(@git_status.staged)})
                </button>
              </div>
            <% else %>
              <!-- Checkpoint Actions: 1-Click Rollback Latest -->
              <%= if @checkpoints != [] do %>
                <button
                  type="button"
                  phx-click="rollback_latest_checkpoint"
                  class="px-2.5 py-1 rounded bg-rose-600 hover:bg-rose-500 text-white font-semibold text-xs font-mono transition-smooth flex items-center gap-1.5 shadow-sm"
                  title="Rollback the most recent checkpoint"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                  <span>Rollback Latest</span>
                </button>
              <% end %>
            <% end %>

            <!-- Diff Mode Switcher -->
            <div class="flex items-center gap-1 bg-[#0d1117] p-1 rounded-lg border border-[#30363d] text-xs font-mono">
              <button
                type="button"
                phx-click="set_diff_mode"
                phx-value-mode="split"
                class={[
                  "px-2.5 py-1 rounded transition-smooth flex items-center gap-1",
                  @diff_mode in ["split", "side-by-side"] && "bg-[#21262d] text-white font-bold",
                  @diff_mode not in ["split", "side-by-side"] && "text-zinc-400 hover:text-zinc-200"
                ]}
              >
                <.icon name="hero-view-columns" class="w-3.5 h-3.5" />
                <span>Split</span>
              </button>
              <button
                type="button"
                phx-click="set_diff_mode"
                phx-value-mode="inline"
                class={[
                  "px-2.5 py-1 rounded transition-smooth flex items-center gap-1",
                  @diff_mode in ["inline", "unified"] && "bg-[#21262d] text-white font-bold",
                  @diff_mode not in ["inline", "unified"] && "text-zinc-400 hover:text-zinc-200"
                ]}
              >
                <.icon name="hero-bars-3-bottom-left" class="w-3.5 h-3.5" />
                <span>Unified</span>
              </button>
            </div>
          </div>
        </header>

        <!-- Main Content Area: Sidebar & Diff Viewer -->
        <div class="flex flex-1 min-h-0 overflow-hidden">
          <%= if @changes_subtab == "checkpoints" do %>
            <!-- Checkpoints Scrubber Timeline Sidebar -->
            <aside class="w-80 border-r border-[#30363d] bg-[#0d1117] flex flex-col shrink-0">
              <div class="p-3 border-b border-[#30363d] flex items-center justify-between font-mono text-xs text-zinc-400">
                <span class="font-bold text-white flex items-center gap-1.5">
                  <.icon name="hero-clock" class="w-4 h-4 text-blue-400" />
                  <span>CHECKPOINTS TIMELINE</span>
                </span>
                <span class="text-[10px] px-1.5 py-0.5 rounded bg-blue-900/40 text-blue-300">
                  {length(@checkpoints)}
                </span>
              </div>

              <div
                id="checkpoints-timeline"
                class="flex-1 overflow-y-auto p-3 space-y-2 font-mono text-xs"
              >
                <%= if @checkpoints == [] do %>
                  <div class="p-8 text-center text-zinc-500">
                    No checkpoints recorded yet.
                  </div>
                <% else %>
                  <%= for cp <- @checkpoints do %>
                    <% tx_id = cp.transaction_id || cp.id %>
                    <% is_selected =
                      @selected_checkpoint &&
                        (@selected_checkpoint.transaction_id == tx_id ||
                           @selected_checkpoint.id == tx_id) %>
                    <div
                      id={"checkpoint-node-#{tx_id}"}
                      phx-click="select_checkpoint"
                      phx-value-tx_id={tx_id}
                      class={[
                        "p-3 rounded-xl border transition-smooth cursor-pointer text-left",
                        is_selected && "bg-blue-950/40 border-blue-500/50 shadow-md",
                        !is_selected && "bg-[#11151c] border-[#21262d] hover:border-zinc-700"
                      ]}
                    >
                      <div class="flex items-center justify-between gap-2 mb-1">
                        <span class="font-bold text-white truncate">{cp.label || "Checkpoint"}</span>
                        <span class={[
                          "px-1.5 py-0.5 rounded text-[10px] uppercase font-bold shrink-0",
                          cp.status == "active" &&
                            "bg-emerald-950/60 text-emerald-400 border border-emerald-500/30",
                          cp.status == "rolled_back" && "bg-zinc-800 text-zinc-400"
                        ]}>
                          {cp.status}
                        </span>
                      </div>
                      <div class="text-[10px] text-zinc-400 truncate mb-1">
                        Seq #{cp.seq} &middot; {cp.diff_summary ||
                          "#{length(cp.patches || [])} file(s)"}
                      </div>
                      <div class="flex items-center justify-between text-[10px] text-zinc-500">
                        <span>{Calendar.strftime(cp.created_at || DateTime.utc_now(), "%H:%M:%S")}</span>
                        <%= if cp.status == "active" do %>
                          <button
                            type="button"
                            phx-click="rollback_to_checkpoint"
                            phx-value-tx_id={tx_id}
                            class="px-2 py-0.5 rounded bg-rose-600/20 hover:bg-rose-600/30 text-rose-300 border border-rose-500/30 font-semibold transition-smooth"
                            title="Rollback to this checkpoint"
                          >
                            Rollback
                          </button>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </aside>

            <!-- Checkpoint Diff Inspector Viewport -->
            <main class="flex-1 min-w-0 bg-[#0a0d12] flex flex-col overflow-hidden">
              <%= if @selected_checkpoint do %>
                <% tx_id = @selected_checkpoint.transaction_id || @selected_checkpoint.id %>
                <div class="p-3 bg-[#161b22] border-b border-[#30363d] flex items-center justify-between font-mono text-xs shrink-0">
                  <div class="truncate">
                    <span class="font-bold text-white text-sm">{@selected_checkpoint.label}</span>
                    <span class="text-zinc-500 text-[11px] ml-2 font-mono">TX: {tx_id}</span>
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    <%= if @selected_checkpoint.status == "active" do %>
                      <button
                        type="button"
                        phx-click="rollback_to_checkpoint"
                        phx-value-tx_id={tx_id}
                        class="px-3 py-1.5 rounded-lg bg-rose-600 hover:bg-rose-500 text-white font-semibold text-xs transition-smooth flex items-center gap-1.5 shadow-sm"
                      >
                        <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                        <span>1-Click Rollback to this Checkpoint</span>
                      </button>
                    <% end %>
                  </div>
                </div>

                <div id="checkpoint-diff-inspector" class="flex-1 overflow-auto p-3 space-y-4">
                  <%= for {p_diff, idx} <- Enum.with_index(IexCode.TimeTravel.checkpoint_diffs(@selected_checkpoint)) do %>
                    <WorkspaceComponents.interactive_diff_viewer
                      id={"detached-checkpoint-diff-#{tx_id}-#{idx}"}
                      diff_text={p_diff.diff_text}
                      hunks={p_diff.hunks}
                      file_path={p_diff.path}
                      status={p_diff.status}
                      diff_mode={if @diff_mode in ["inline", "unified"], do: "inline", else: "split"}
                      is_checkpoint={true}
                      rollback_tx_id={tx_id}
                      class="min-h-[280px]"
                    />
                  <% end %>
                </div>
              <% else %>
                <div class="flex-1 flex flex-col items-center justify-center text-center p-8 text-zinc-500">
                  <.icon name="hero-magnifying-glass" class="w-8 h-8 text-zinc-600 mb-2" />
                  <p>Select a checkpoint from the timeline to inspect diffs and rollback.</p>
                </div>
              <% end %>
            </main>
          <% else %>
            <!-- 3-Tier Staging Sidebar -->
            <aside class="w-80 border-r border-[#30363d] bg-[#0d1117] flex flex-col shrink-0">
              <!-- Staging Actions -->
              <div class="p-3 border-b border-[#30363d] flex items-center justify-between gap-2">
                <button
                  type="button"
                  phx-click="stage_all"
                  class="flex-1 px-2.5 py-1.5 rounded bg-blue-600/20 hover:bg-blue-600/30 text-blue-300 border border-blue-500/30 text-xs font-mono font-semibold transition-smooth"
                >
                  Stage All
                </button>
                <button
                  type="button"
                  phx-click="unstage_all"
                  class="flex-1 px-2.5 py-1.5 rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-300 border border-[#30363d] text-xs font-mono font-semibold transition-smooth"
                >
                  Unstage All
                </button>
              </div>

              <!-- File Lists -->
              <div class="flex-1 overflow-y-auto p-3 space-y-4 text-xs font-mono">
                <!-- Staged Changes -->
                <div>
                  <div class="flex items-center justify-between text-emerald-400 font-semibold mb-1.5">
                    <span>STAGED CHANGES</span>
                    <span class="text-[10px] px-1.5 py-0.5 rounded bg-emerald-900/40">{length(
                      @git_status.staged
                    )}</span>
                  </div>
                  <%= if @git_status.staged == [] do %>
                    <div class="text-zinc-600 italic py-1">No staged changes</div>
                  <% else %>
                    <div class="space-y-1">
                      <%= for file <- @git_status.staged do %>
                        <% path = if is_map(file), do: file.path, else: file %>
                        <div class={[
                          "flex items-center justify-between p-1.5 rounded hover:bg-[#161b22] cursor-pointer group",
                          @selected_diff_file == path && @active_diff_scope == :staged &&
                            "bg-[#161b22] border-l-2 border-emerald-400"
                        ]}>
                          <span
                            phx-click="select_diff_file"
                            phx-value-file={path}
                            phx-value-scope="staged"
                            class="truncate flex-1 text-zinc-300"
                          >
                            {path}
                          </span>
                          <button
                            type="button"
                            phx-click="unstage_file"
                            phx-value-file={path}
                            class="opacity-0 group-hover:opacity-100 text-zinc-400 hover:text-rose-400 p-1"
                            title="Unstage"
                          >
                            <.icon name="hero-minus" class="w-3 h-3" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <!-- Unstaged Changes -->
                <div>
                  <div class="flex items-center justify-between text-amber-400 font-semibold mb-1.5">
                    <span>UNSTAGED CHANGES</span>
                    <span class="text-[10px] px-1.5 py-0.5 rounded bg-amber-900/40">{length(
                      @git_status.unstaged
                    )}</span>
                  </div>
                  <%= if @git_status.unstaged == [] do %>
                    <div class="text-zinc-600 italic py-1">No unstaged changes</div>
                  <% else %>
                    <div class="space-y-1">
                      <%= for file <- @git_status.unstaged do %>
                        <% path = if is_map(file), do: file.path, else: file %>
                        <div class={[
                          "flex items-center justify-between p-1.5 rounded hover:bg-[#161b22] cursor-pointer group",
                          @selected_diff_file == path && @active_diff_scope == :unstaged &&
                            "bg-[#161b22] border-l-2 border-amber-400"
                        ]}>
                          <span
                            phx-click="select_diff_file"
                            phx-value-file={path}
                            phx-value-scope="unstaged"
                            class="truncate flex-1 text-zinc-300"
                          >
                            {path}
                          </span>
                          <button
                            type="button"
                            phx-click="stage_file"
                            phx-value-file={path}
                            class="opacity-0 group-hover:opacity-100 text-zinc-400 hover:text-emerald-400 p-1"
                            title="Stage"
                          >
                            <.icon name="hero-plus" class="w-3 h-3" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <!-- Untracked Files -->
                <%= if @git_status.untracked != [] do %>
                  <div>
                    <div class="flex items-center justify-between text-blue-400 font-semibold mb-1.5">
                      <span>UNTRACKED FILES</span>
                      <span class="text-[10px] px-1.5 py-0.5 rounded bg-blue-900/40">{length(
                        @git_status.untracked
                      )}</span>
                    </div>
                    <div class="space-y-1">
                      <%= for file <- @git_status.untracked do %>
                        <% path = if is_map(file), do: file.path, else: file %>
                        <div class="flex items-center justify-between p-1.5 rounded hover:bg-[#161b22] group">
                          <span class="truncate flex-1 text-zinc-400">{path}</span>
                          <button
                            type="button"
                            phx-click="stage_file"
                            phx-value-file={path}
                            class="opacity-0 group-hover:opacity-100 text-zinc-400 hover:text-emerald-400 p-1"
                            title="Stage"
                          >
                            <.icon name="hero-plus" class="w-3 h-3" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- Commit Composer -->
              <div class="p-3 border-t border-[#30363d] bg-[#161b22] space-y-2">
                <div class="flex items-center justify-between text-xs font-mono text-zinc-400">
                  <span>Commit Message</span>
                  <button
                    type="button"
                    phx-click="generate_commit_msg"
                    class="text-[11px] text-purple-400 hover:text-purple-300 flex items-center gap-1"
                    title="Generate with AI"
                  >
                    <.icon name="hero-sparkles" class="w-3 h-3" />
                    <span>AI Generate</span>
                  </button>
                </div>

                <textarea
                  name="commit_message"
                  phx-change="update_commit_message"
                  rows="3"
                  placeholder="Summary of changes..."
                  class="w-full bg-[#0d1117] border border-[#30363d] rounded p-2 text-xs font-mono text-zinc-200 placeholder-zinc-500 focus:outline-none focus:border-blue-500 resize-none"
                >{@commit_message}</textarea>

                <button
                  type="button"
                  phx-click="git_commit"
                  disabled={@git_status.staged == [] or String.trim(@commit_message) == ""}
                  class="w-full py-1.5 rounded bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 disabled:pointer-events-none text-white text-xs font-mono font-bold transition-smooth"
                >
                  Commit Changes ({length(@git_status.staged)})
                </button>
              </div>
            </aside>

            <!-- Interactive Diff Viewer Viewport -->
            <main class="flex-1 min-w-0 bg-[#0a0d12] flex flex-col overflow-hidden">
              <div class="flex items-center justify-between px-4 py-2 bg-[#161b22]/50 border-b border-[#30363d] font-mono text-xs">
                <span class="text-zinc-300 font-semibold truncate">
                  {@diff_file_path || "Select a file to inspect diff"}
                </span>
                <span class="text-[11px] text-zinc-500">
                  {length(@diff_hunks)} hunk(s)
                </span>
              </div>

              <div class="flex-1 overflow-auto p-3">
                <WorkspaceComponents.interactive_diff_viewer
                  diff_text={@diff_text}
                  diff_mode={if @diff_mode in ["inline", "unified"], do: "inline", else: "split"}
                  file_path={@diff_file_path}
                  hunks={@diff_hunks}
                  staged={@active_diff_scope == :staged}
                />
              </div>
            </main>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
