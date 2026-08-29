defmodule IexCodeWeb.WorkspaceComponents do
  @moduledoc """
  Reusable Phoenix function components for the IexCode Web workspace.
  Implements Milestone 3 & 4 UI/UX, Inline Editor, Diff Hunk Management & Live Telemetry:
  - F5: Live Telemetry & 4-Column Subagent Cards (<.subagent_cards>)
  - F6: Hierarchical Operation Tree (<.operation_tree>, <.tree_node>)
  - F7: Interactive Diff Hunk Viewer (<.interactive_diff_viewer>, <.diff_viewer>)
  - F8: Interactive Inline Code Editor & File Explorer (<.file_explorer>)
  - F9: Terminal Session Integration & Runner (<.terminal_session>)
  - F10: Collapsible Reasoning / Thinking Trace (<.thinking_trace>)
  - F11: Markdown & Code Block Formatter (<.markdown_content>)
  """
  use Phoenix.Component
  import IexCodeWeb.CoreComponents
  import Phoenix.HTML
  alias IexCode.Engine.OperationManager
  alias IexCode.Tools.Git.DiffParser
  alias Phoenix.LiveView.JS

  # ============================================================================
  # F5: Live Telemetry & 4-Column Subagent Cards
  # ============================================================================

  @doc """
  Renders legacy interactive-session role templates (Planner, Explorer, Coder, Verifier).
  A card becomes operation telemetry only when a matching operation exists; idle cards
  are templates and never claim to be live or persisted workers.
  """
  attr :operations, :list, default: []
  attr :active_stage, :atom, default: :init
  attr :active_agent, :string, default: nil
  attr :swarm_mode, :boolean, default: true

  def subagent_cards(assigns) do
    agents = [
      %{
        name: "PlannerAgent",
        key: :planner,
        title: "Planner",
        desc: "Architecture decomposition & milestone planning",
        icon: "hero-map",
        color: "purple",
        bg_color: "bg-purple-500",
        text_color: "text-purple-400",
        border_color: "border-purple-500/50",
        shadow: "shadow-[0_0_10px_rgba(168,85,247,0.5)]",
        shadow_tint: "shadow-purple-500/10"
      },
      %{
        name: "ExplorerAgent",
        key: :explorer,
        title: "Explorer",
        desc: "AST code discovery, file tree inspection, symbol lookups",
        icon: "hero-magnifying-glass",
        color: "cyan",
        bg_color: "bg-cyan-500",
        text_color: "text-cyan-400",
        border_color: "border-cyan-500/50",
        shadow: "shadow-[0_0_10px_rgba(6,182,212,0.5)]",
        shadow_tint: "shadow-cyan-500/10"
      },
      %{
        name: "CoderAgent",
        key: :coder,
        title: "Coder",
        desc: "MultiPatch fuzzy patch formulation & atomic file generation",
        icon: "hero-code-bracket",
        color: "amber",
        bg_color: "bg-amber-500",
        text_color: "text-amber-400",
        border_color: "border-amber-500/50",
        shadow: "shadow-[0_0_10px_rgba(245,158,11,0.5)]",
        shadow_tint: "shadow-amber-500/10"
      },
      %{
        name: "VerifierAgent",
        key: :verifier,
        title: "Verifier",
        desc: "ExUnit test runner, compiler backtrace parser & AutoFix loop",
        icon: "hero-check-badge",
        color: "emerald",
        bg_color: "bg-emerald-500",
        text_color: "text-emerald-400",
        border_color: "border-emerald-500/50",
        shadow: "shadow-[0_0_10px_rgba(34,197,94,0.5)]",
        shadow_tint: "shadow-emerald-500/10"
      }
    ]

    assigns = assign(assigns, :agents, agents)

    ~H"""
    <div id="subagent-cards-grid" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
      <%= for agent <- @agents do %>
        <% op = latest_op_for_agent(@operations, agent.name)

        status =
          cond do
            is_nil(op) or is_nil(op.status) -> "idle"
            is_binary(op.status) -> op.status
            is_atom(op.status) -> Atom.to_string(op.status)
            true -> to_string(op.status)
          end

        normalized_status =
          case String.downcase(status) do
            "completed" -> "completed"
            "done" -> "completed"
            "failed" -> "failed"
            "error" -> "failed"
            "running" -> "running"
            _ -> "idle"
          end

        progress = if op && is_number(op.progress), do: op.progress, else: 0
        pid_str = if op && op.pid_str, do: op.pid_str, else: nil
        duration = if op && op.duration_ms, do: "#{op.duration_ms}ms", else: "--"
        current_msg = if op, do: op.result || op.title || agent.desc, else: agent.desc

        is_active =
          is_binary(@active_agent) and
            String.contains?(@active_agent, String.replace(agent.name, "Agent", ""))

        stage_label = @active_stage |> to_string() |> String.upcase()
        stage_failed = stage_label in ["FAILED", "ERROR"] %>
        <div
          id={"subagent-card-#{agent.key}"}
          class={[
            "bg-[#11151c] border rounded-2xl p-4 flex flex-col justify-between transition-smooth relative overflow-hidden",
            normalized_status == "running" && "#{agent.border_color} shadow-lg #{agent.shadow_tint}",
            normalized_status != "running" && "border-[#21262d] hover:border-[#30363d]",
            is_active && "ring-1 ring-cyan-500/40"
          ]}
        >
          <!-- Active neon top line -->
          <%= if normalized_status == "running" do %>
            <div class={[
              "absolute top-0 left-0 right-0 h-0.5",
              agent.bg_color,
              agent.shadow,
              "animate-pulse"
            ]}>
            </div>
          <% end %>

          <div>
            <!-- Header -->
            <div class="flex items-center justify-between mb-2">
              <span class={[
                "font-mono text-xs font-semibold uppercase tracking-wider flex items-center gap-1.5",
                agent.text_color
              ]}>
                <.icon name={agent.icon} class="w-4 h-4" />
                {agent.name}
              </span>
              <div class="flex items-center gap-1.5">
                <%= if pid_str do %>
                  <span
                    class="text-[10px] font-mono text-emerald-400 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20 truncate max-w-[90px]"
                    title={pid_str}
                  >
                    {pid_str}
                  </span>
                <% else %>
                  <span class="text-[10px] font-mono text-emerald-400/80 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20">
                    Role template · OTP Supervised when active
                  </span>
                <% end %>
                <span class={[
                  "text-[10px] font-mono px-1.5 py-0.5 rounded border font-semibold",
                  normalized_status == "running" &&
                    "text-amber-400 bg-amber-500/10 border-amber-500/30 animate-pulse",
                  normalized_status == "completed" &&
                    "text-emerald-400 bg-emerald-500/10 border-emerald-500/30",
                  normalized_status == "failed" && "text-rose-400 bg-rose-500/10 border-rose-500/30",
                  normalized_status == "idle" && "text-gray-400 bg-[#161b22] border-[#21262d]"
                ]}>
                  {String.upcase(normalized_status)}
                </span>
              </div>
            </div>

            <!-- Role & Activity -->
            <p class="text-[11px] text-gray-400 font-mono mb-2 line-clamp-2">
              {current_msg}
            </p>

            <!-- Active Stage / Agent indicator -->
            <%= if is_active do %>
              <div class="flex items-center gap-1.5 mb-2">
                <span class={[
                  "text-[10px] font-mono px-1.5 py-0.5 rounded border font-semibold uppercase tracking-wider",
                  stage_failed && "text-rose-400 bg-rose-500/10 border-rose-500/30",
                  not stage_failed && "text-cyan-300 bg-cyan-500/10 border-cyan-500/30"
                ]}>
                  Stage: {stage_label}
                </span>
                <span class="text-[10px] font-mono text-gray-500">Active Agent</span>
              </div>
            <% end %>
          </div>

          <!-- Progress & Latency Footer -->
          <div class="pt-3 border-t border-[#21262d] space-y-1.5">
            <div class="flex justify-between items-center text-[11px] font-mono text-gray-400">
              <span class="text-[10px] text-gray-500">Latency:
              <strong class="text-gray-300">{duration}</strong></span>
              <span class={[
                "font-semibold",
                if(normalized_status == "completed", do: "text-emerald-400", else: "text-gray-300")
              ]}>
                {progress}%
              </span>
            </div>
            <div class="w-full bg-[#1c2128] h-1.5 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-all duration-300 ease-out",
                  agent.bg_color,
                  normalized_status == "running" && agent.shadow
                ]}
                style={"width: #{max(progress, if(normalized_status == "running", do: 10, else: 0))}%"}
              >
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp latest_op_for_agent(operations, agent_name) do
    short_name = String.replace(agent_name, "Agent", "")

    Enum.find(operations, fn op ->
      op_agent = to_string(op.agent_name || "")
      op_agent == agent_name or String.contains?(op_agent, short_name)
    end)
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree
  # ============================================================================

  @doc """
  Renders a visual nested parent-child operation tree using `parent_op_id` with CSS connector lines.
  Includes expand/collapse toggles, status badges, execution metrics, and error trace previews.
  """
  attr :operations, :list, default: []
  attr :expanded_ops, :any, default: %MapSet{}

  def operation_tree(assigns) do
    tree = OperationManager.build_tree(assigns.operations)
    stats = OperationManager.tree_stats(assigns.operations)
    assigns = assign(assigns, tree: tree, stats: stats)

    ~H"""
    <div
      id="operation-tree-root"
      class="bg-[#11151c] border border-[#21262d] rounded-2xl p-5 space-y-4"
    >
      <!-- Tree Header -->
      <div class="flex items-center justify-between pb-3 border-b border-[#21262d]">
        <div class="flex items-center gap-3">
          <h3 class="text-sm font-semibold text-white font-mono flex items-center gap-2">
            <.icon name="hero-list-bullet" class="w-4 h-4 text-emerald-400" /> Execution Hierarchy
            <span class="px-2 py-0.5 rounded-full bg-[#1c2128] text-xs text-gray-400 border border-[#30363d]">
              {@stats.total} ops
            </span>
          </h3>
          <div class="hidden sm:flex items-center gap-2 text-[11px] font-mono text-gray-400">
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span> {@stats.completed} done</span>
            <span class="flex items-center gap-1"><span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></span> {@stats.running} running</span>
            <%= if @stats.failed > 0 do %>
              <span class="flex items-center gap-1 text-rose-400"><span class="w-1.5 h-1.5 rounded-full bg-rose-400"></span> {@stats.failed} failed</span>
            <% end %>
          </div>
        </div>

        <button
          phx-click="clear_operations"
          class="text-xs font-mono text-gray-500 hover:text-rose-400 transition-smooth flex items-center gap-1"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Clear Operations
        </button>
      </div>

      <!-- Tree Nodes List -->
      <%= if @tree == [] do %>
        <div class="p-8 text-center text-gray-500 font-mono text-xs border border-dashed border-[#21262d] rounded-xl">
          No operations recorded in this session.
        </div>
      <% else %>
        <div class="space-y-2 font-mono text-xs">
          <%= for root_op <- @tree do %>
            <.tree_node op={root_op} depth={0} expanded_ops={@expanded_ops} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Recursive tree node component rendering an operation with status badge, latency, PID, and child operations.
  """
  attr :op, :map, required: true
  attr :depth, :integer, default: 0
  attr :expanded_ops, :any, default: %MapSet{}

  def tree_node(assigns) do
    has_children = length(assigns.op.children || []) > 0
    is_expanded = MapSet.member?(assigns.expanded_ops, assigns.op.id)
    assigns = assign(assigns, has_children: has_children, is_expanded: is_expanded)

    ~H"""
    <div class={["relative", @depth > 0 && "pl-6 tree-node-connector"]}>
      <div class={[
        "p-3 rounded-xl border transition-smooth",
        @op.status == "running" && "bg-[#161b22] border-amber-500/40 shadow-sm",
        @op.status == "failed" && "bg-[#1a1215] border-rose-500/40",
        @op.status != "running" && @op.status != "failed" &&
          "bg-[#161b22] border-[#21262d] hover:border-[#38404a]"
      ]}>
        <!-- Top Row: Status, Agent, Title, Metrics, Chevron -->
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2.5 min-w-0 flex-1">
            <!-- Expand / Collapse chevron if children exist -->
            <%= if @has_children do %>
              <button
                phx-click="toggle_op_detail"
                phx-value-id={@op.id}
                class="text-gray-400 hover:text-white transition-smooth"
              >
                <.icon
                  name={if(@is_expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
                  class="w-3.5 h-3.5"
                />
              </button>
            <% else %>
              <span class="w-3.5"></span>
            <% end %>

            <!-- Status Dot -->
            <span class={[
              "w-2 h-2 rounded-full shrink-0",
              @op.status == "completed" && "bg-emerald-400",
              @op.status == "running" &&
                "bg-amber-400 animate-pulse shadow-[0_0_8px_rgba(245,158,11,0.6)]",
              @op.status == "failed" && "bg-rose-400 shadow-[0_0_8px_rgba(244,63,94,0.6)]",
              @op.status == "pending" && "bg-gray-500"
            ]}></span>

            <!-- Agent Tag -->
            <span class="font-bold text-white shrink-0 text-xs">
              {@op.agent_name || "System"}
            </span>

            <!-- Operation Type Badge -->
            <span class="text-[10px] text-gray-400 bg-[#0d1117] border border-[#21262d] px-1.5 py-0.5 rounded shrink-0">
              {@op.op_type}
            </span>

            <!-- Title -->
            <span class="text-gray-300 truncate text-xs">
              {@op.title}
            </span>
          </div>

          <!-- Right side metrics -->
          <div class="flex items-center gap-3 text-[11px] text-gray-400 shrink-0">
            <%= if @op.duration_ms do %>
              <span class="text-gray-400">{@op.duration_ms}ms</span>
            <% end %>
            <%= if @op.pid_str do %>
              <span class="text-emerald-400 bg-emerald-500/10 px-1.5 py-0.5 rounded border border-emerald-500/20 text-[10px]">
                {@op.pid_str}
              </span>
            <% end %>
            <button
              phx-click="toggle_op_detail"
              phx-value-id={@op.id}
              class="text-gray-400 hover:text-white p-1 rounded transition-smooth"
              title="Inspect Details"
            >
              <.icon name="hero-ellipsis-horizontal" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        <!-- Detail Drawer (Parameters, Error, Result) -->
        <%= if @is_expanded do %>
          <div class="mt-3 pt-3 border-t border-[#21262d] space-y-2 text-[11px] font-mono animate-in fade-in">
            <%= if @op.error_message do %>
              <div class="p-2.5 rounded-lg bg-rose-950/40 border border-rose-500/30 text-rose-300 whitespace-pre-wrap">
                <strong class="text-rose-400">Error:</strong> {@op.error_message}
              </div>
            <% end %>

            <%= if @op.result do %>
              <div class="p-2.5 rounded-lg bg-[#0d1117] border border-[#21262d] text-gray-300 whitespace-pre-wrap max-h-48 overflow-y-auto">
                <strong class="text-gray-400 block mb-1">Result:</strong>
                {@op.result}
              </div>
            <% end %>

            <%= if @op.params && @op.params != %{} do %>
              <div class="p-2 rounded bg-[#0d1117] border border-[#21262d] text-gray-400">
                <span class="text-gray-500">Params:</span> {inspect(@op.params)}
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Recursive Children Rendering -->
      <%= if @has_children and @is_expanded do %>
        <div class="space-y-2 mt-2">
          <%= for child <- @op.children do %>
            <.tree_node op={child} depth={@depth + 1} expanded_ops={@expanded_ops} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # F7: Interactive Code Diff Hunk Viewer (<.interactive_diff_viewer>, <.diff_viewer>)
  # ============================================================================

  @doc """
  Renders interactive side-by-side and inline code diff viewer with per-hunk action buttons:
  - "Accept Hunk" (`accept_hunk`), "Reject Hunk" (`reject_hunk`), "Revert Hunk" (`revert_hunk`)
  - "Revert File" (`revert_file`), "Accept All Hunks" (`accept_all_hunks`)
  """
  attr :diff_text, :string, default: ""
  attr :diff_mode, :string, default: "inline"
  attr :file_path, :string, default: nil
  attr :hunks, :list, default: nil
  attr :status, :any, default: :modified
  attr :additions, :integer, default: 0
  attr :deletions, :integer, default: 0

  def diff_viewer(assigns), do: interactive_diff_viewer(assigns)

  def interactive_diff_viewer(assigns) do
    diff_text = assigns[:diff_text] || ""
    hunks = assigns[:hunks]
    status = assigns[:status] || :modified
    file_path = assigns[:file_path]
    diff_mode = assigns[:diff_mode] || "inline"

    # Decompose diff_text into structured hunks if not explicitly passed
    resolved_hunks =
      cond do
        is_list(hunks) && hunks != [] ->
          hunks

        is_binary(diff_text) && String.trim(diff_text) != "" ->
          case DiffParser.parse(diff_text) do
            {:ok, [file_diff | _]} -> file_diff.hunks
            _ -> []
          end

        true ->
          []
      end

    assigns =
      assigns
      |> assign(:diff_text, diff_text)
      |> assign(:status, status)
      |> assign(:file_path, file_path)
      |> assign(:diff_mode, diff_mode)
      |> assign(:resolved_hunks, resolved_hunks)

    ~H"""
    <div
      id="diff-viewer-container"
      class="min-h-0 min-w-0 bg-[#11151c] border border-[#21262d] rounded-2xl flex flex-col h-full overflow-hidden"
    >
      <!-- Toolbar Header -->
      <div class="diff-viewer-header p-3 border-b border-[#21262d] bg-[#161b22] flex flex-wrap items-center justify-between gap-2 shrink-0 font-mono text-xs">
        <div class="flex min-w-0 flex-1 items-center gap-2">
          <.icon name="hero-code-bracket-square" class="w-4 h-4 text-cyan-400 shrink-0" />
          <span class="min-w-0 truncate font-semibold text-white">
            {@file_path || "Multi-File Patch Preview"}
          </span>
          <span class={[
            "px-2 py-0.5 rounded text-[10px] font-bold uppercase shrink-0",
            to_string(@status) in ["added", "untracked"] &&
              "bg-emerald-500/10 text-emerald-400 border border-emerald-500/30",
            to_string(@status) == "deleted" &&
              "bg-rose-500/10 text-rose-400 border border-rose-500/30",
            true && "bg-amber-500/10 text-amber-400 border border-amber-500/30"
          ]}>
            {to_string(@status || "MODIFIED")}
          </span>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <!-- File Actions: Revert File & Accept All -->
          <%= if @file_path do %>
            <button
              phx-click="revert_file"
              phx-value-file={@file_path}
              data-confirm="Revert every uncommitted change in this file?"
              class="px-2.5 py-1 bg-rose-500/10 hover:bg-rose-500/20 text-rose-300 border border-rose-500/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
              title="Revert entire file to clean git state"
            >
              <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
              <span class="hidden sm:inline">Revert File</span>
            </button>
            <button
              phx-click="accept_all_hunks"
              phx-value-file={@file_path}
              class="px-2.5 py-1 bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-300 border border-emerald-500/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
              title="Stage all changes for this file"
            >
              <.icon name="hero-check" class="w-3.5 h-3.5" />
              <span class="hidden sm:inline">Accept All</span>
            </button>
          <% end %>

          <!-- View Mode Toggle -->
          <div class="flex items-center bg-[#0d1117] p-1 rounded-lg border border-[#21262d]">
            <button
              phx-click="set_diff_mode"
              phx-value-mode="inline"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "inline" && "bg-[#21262d] text-white font-semibold",
                @diff_mode != "inline" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              Inline
            </button>
            <button
              phx-click="set_diff_mode"
              phx-value-mode="split"
              class={[
                "px-2.5 py-1 rounded text-xs transition-smooth",
                @diff_mode == "split" && "bg-[#21262d] text-white font-semibold",
                @diff_mode != "split" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              Side-by-Side
            </button>
          </div>

          <!-- Copy Diff Button -->
          <button
            id="copy-diff-btn"
            phx-hook="CodeCopy"
            data-code={@diff_text}
            class="px-2.5 py-1 bg-[#21262d] hover:bg-[#30363d] text-gray-200 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
          >
            <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
            <span class="hidden md:inline">Copy Diff</span>
          </button>
        </div>
      </div>

      <!-- Diff Body with Granular Hunks -->
      <div class="flex-1 min-h-0 min-w-0 overflow-auto font-mono text-xs leading-relaxed p-2 sm:p-3 bg-[#0a0d12] space-y-4">
        <%= if is_nil(@diff_text) or String.trim(@diff_text) == "" do %>
          <div class="p-8 text-center text-gray-500">
            No patch or diff selected.
          </div>
        <% else %>
          <%= if @resolved_hunks != [] do %>
            <%= for hunk <- @resolved_hunks do %>
              <.hunk_card
                hunk={hunk}
                file_path={@file_path}
                diff_mode={@diff_mode}
              />
            <% end %>
          <% else %>
            <!-- Fallback to plain line renderer if no hunks parsed -->
            <%= if @diff_mode == "inline" do %>
              <.inline_diff diff={@diff_text} />
            <% else %>
              <.split_diff diff={@diff_text} />
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders an individual hunk card with hunk header and Accept / Reject / Revert action buttons.
  """
  attr :hunk, :any, required: true
  attr :file_path, :string, default: nil
  attr :diff_mode, :string, default: "inline"
  attr :staged, :boolean, default: false

  def hunk_card(assigns) do
    ~H"""
    <div
      id={"hunk-card-#{@hunk.id}"}
      class="border border-[#21262d] rounded-xl overflow-hidden bg-[#11151c] shadow-md"
    >
      <!-- Hunk Control Header -->
      <div class="bg-[#161b22] px-3 py-2 border-b border-[#21262d] flex items-center justify-between font-mono text-xs">
        <div class="flex items-center gap-2 truncate">
          <span class="px-2 py-0.5 rounded bg-indigo-950/60 text-indigo-300 font-semibold text-[11px] border border-indigo-500/30">
            {@hunk.header ||
              "@@ -#{@hunk.old_start},#{@hunk.old_count || @hunk.old_lines} +#{@hunk.new_start},#{@hunk.new_count || @hunk.new_lines} @@"}
          </span>
          <span class="text-[10px] text-gray-400">
            Hunk {@hunk.id}
          </span>
        </div>

        <div class="flex items-center gap-1.5">
          <%= if @staged do %>
            <button
              phx-click="unstage_hunk"
              phx-value-file={@file_path}
              phx-value-hunk_id={@hunk.id}
              class="px-2 py-1 bg-amber-500/20 hover:bg-amber-500/30 text-amber-300 border border-amber-500/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
              title="Unstage this hunk from the index"
            >
              <.icon name="hero-minus-circle" class="w-3 h-3" />
              <span>Unstage Hunk</span>
            </button>
          <% else %>
            <button
              phx-click="accept_hunk"
              phx-value-file={@file_path}
              phx-value-hunk_id={@hunk.id}
              class="px-2 py-1 bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-300 border border-emerald-500/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
              title="Stage this hunk"
            >
              <.icon name="hero-check" class="w-3 h-3" />
              <span>Accept Hunk</span>
            </button>
            <button
              phx-click="reject_hunk"
              phx-value-file={@file_path}
              phx-value-hunk_id={@hunk.id}
              data-confirm="Discard this hunk?"
              class="px-2 py-1 bg-rose-500/20 hover:bg-rose-500/30 text-rose-300 border border-rose-500/30 rounded text-[11px] font-semibold transition-smooth flex items-center gap-1"
              title="Reject / Discard this hunk"
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
              <span>Reject Hunk</span>
            </button>
            <button
              phx-click="revert_hunk"
              phx-value-file={@file_path}
              phx-value-hunk_id={@hunk.id}
              data-confirm="Revert this hunk?"
              class="px-2 py-1 bg-gray-700/40 hover:bg-gray-700/60 text-gray-300 border border-gray-600/30 rounded text-[11px] transition-smooth flex items-center gap-1"
              title="Revert this hunk"
            >
              <.icon name="hero-arrow-uturn-left" class="w-3 h-3" />
              <span>Revert</span>
            </button>
          <% end %>
        </div>
      </div>

      <!-- Hunk Body Lines -->
      <div class="p-2 bg-[#0d1117] overflow-x-auto">
        <%= if @diff_mode == "inline" do %>
          <.hunk_inline_lines lines={@hunk.lines} />
        <% else %>
          <.hunk_split_lines lines={@hunk.lines} />
        <% end %>
      </div>
    </div>
    """
  end

  def hunk_inline_lines(assigns) do
    ~H"""
    <div class="space-y-0.5 font-mono text-xs">
      <%= for line <- @lines do %>
        <% {bg, text_color, sign} =
          case line.type do
            :addition ->
              {"bg-emerald-950/40 border-l-2 border-emerald-500", "text-emerald-300", "+"}

            :deletion ->
              {"bg-rose-950/40 border-l-2 border-rose-500", "text-rose-300", "-"}

            :header ->
              {"bg-indigo-950/30 text-indigo-300 font-semibold py-0.5 px-2 rounded",
               "text-indigo-300", "@"}

            _ ->
              {"hover:bg-[#161b22]", "text-gray-300", " "}
          end %>
        <div class={["flex items-center px-2 py-0.5 rounded", bg]}>
          <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{line.old_num || " "}</span>
          <span class="w-8 text-right text-gray-600 select-none pr-3 text-[10px]">{line.new_num || " "}</span>
          <span class="w-4 text-center select-none font-bold text-[11px] text-gray-500">{sign}</span>
          <span class={["flex-1 whitespace-pre-wrap", text_color]}>{line.content}</span>
        </div>
      <% end %>
    </div>
    """
  end

  def hunk_split_lines(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2 font-mono text-xs">
      <div class="space-y-0.5 border-r border-[#21262d] pr-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Original
        </div>
        <%= for line <- @lines do %>
          <%= if line.type in [:context, :deletion] do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              line.type == :deletion && "bg-rose-950/40 text-rose-300 border-l-2 border-rose-500",
              line.type == :context && "text-gray-300 hover:bg-[#161b22]"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{line.old_num}</span>
              <span class="flex-1 whitespace-pre-wrap">{line.content}</span>
            </div>
          <% end %>
        <% end %>
      </div>
      <div class="space-y-0.5 pl-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Modified
        </div>
        <%= for line <- @lines do %>
          <%= if line.type in [:context, :addition] do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              line.type == :addition &&
                "bg-emerald-950/40 text-emerald-300 border-l-2 border-emerald-500",
              line.type == :context && "text-gray-300 hover:bg-[#161b22]"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{line.new_num}</span>
              <span class="flex-1 whitespace-pre-wrap">{line.content}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  def inline_diff(assigns) do
    lines = String.split(assigns.diff, ~r/\r?\n/)
    assigns = assign(assigns, lines: lines)

    ~H"""
    <div class="space-y-0.5">
      <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
        <% {bg, text_color, sign} =
          cond do
            String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
              {"bg-emerald-950/40 border-l-2 border-emerald-500", "text-emerald-300", "+"}

            String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
              {"bg-rose-950/40 border-l-2 border-rose-500", "text-rose-300", "-"}

            String.starts_with?(line, "@@") ->
              {"bg-indigo-950/30 text-indigo-300 font-semibold my-1 py-0.5 px-2 rounded",
               "text-indigo-300", "@"}

            String.starts_with?(line, "---") || String.starts_with?(line, "+++") ->
              {"bg-[#161b22] text-gray-400 font-semibold py-1 px-2", "text-gray-400", "#"}

            true ->
              {"hover:bg-[#11151c]", "text-gray-300", " "}
          end %>
        <div class={["flex items-center px-2 py-0.5 rounded font-mono", bg]}>
          <span class="w-10 text-right text-gray-600 select-none pr-3 text-[10px]">{idx}</span>
          <span class="w-4 text-center select-none font-bold text-[11px] text-gray-500">{sign}</span>
          <span class={["flex-1 whitespace-pre-wrap", text_color]}>{line}</span>
        </div>
      <% end %>
    </div>
    """
  end

  def split_diff(assigns) do
    lines = String.split(assigns.diff, ~r/\r?\n/)
    assigns = assign(assigns, lines: lines)

    ~H"""
    <div class="grid min-w-[42rem] grid-cols-2 gap-2">
      <div class="space-y-0.5 border-r border-[#21262d] pr-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Original
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "+") || String.starts_with?(line, "+++") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "-") &&
                "bg-rose-950/40 text-rose-300 border-l-2 border-rose-500"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
      <div class="space-y-0.5 pl-2">
        <div class="text-gray-500 text-[10px] uppercase font-bold px-2 py-1 bg-[#11151c] rounded mb-1">
          Modified
        </div>
        <%= for {line, idx} <- Enum.with_index(@lines, 1) do %>
          <%= if !String.starts_with?(line, "-") || String.starts_with?(line, "---") do %>
            <div class={[
              "px-2 py-0.5 rounded flex items-center",
              String.starts_with?(line, "+") &&
                "bg-emerald-950/40 text-emerald-300 border-l-2 border-emerald-500"
            ]}>
              <span class="w-8 text-right text-gray-600 select-none pr-2 text-[10px]">{idx}</span>
              <span class="flex-1 whitespace-pre-wrap">{line}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # F8: Interactive Inline Code Editor & File Explorer (<.file_explorer>)
  # ============================================================================

  @doc """
  Renders an interactive inline code editor and file directory tree with:
  - Open buffer tabs (`@open_buffers`)
  - Dirty state tracking and visual indicator (`●`)
  - Gutter line numbers and Tab key indentation (via `.CodeEditor` hook)
  - `Cmd+S` save hotkey and explicit Save / Revert buttons
  """
  attr :files, :list, default: []
  attr :filter, :string, default: ""
  attr :filter_form, :any, default: nil
  attr :expanded_folders, :any, default: MapSet.new()
  attr :selected_file, :string, default: nil
  attr :file_content, :string, default: nil
  attr :dirty_content, :string, default: nil
  attr :is_dirty, :boolean, default: false
  attr :open_buffers, :list, default: []
  attr :editor_lock, :map, default: nil
  attr :auto_save, :boolean, default: false
  attr :more_files, :boolean, default: false

  def file_explorer(assigns) do
    has_filter = assigns.filter != "" and not is_nil(assigns.filter)
    expanded = assigns.expanded_folders || MapSet.new()

    tree_items =
      if has_filter do
        query = String.downcase(assigns.filter)

        assigns.files
        |> Enum.filter(&String.contains?(String.downcase(&1), query))
        |> Enum.map(fn file ->
          %{type: :file, name: file, path: file, depth: 0}
        end)
      else
        assigns.files
        |> build_file_tree()
        |> flatten_file_tree(expanded, 0)
      end

    current_text = assigns.dirty_content || assigns.file_content || ""
    editor_locked? = not is_nil(assigns.editor_lock)

    assigns =
      assigns
      |> assign(:tree_items, tree_items)
      |> assign(:has_filter, has_filter)
      |> assign(:current_text, current_text)
      |> assign(:editor_locked?, editor_locked?)
      |> assign(:filter_form, assigns.filter_form || to_form(%{"filter" => assigns.filter}))

    ~H"""
    <div
      id="file-explorer-container"
      class="flex-1 flex min-h-0 min-w-0 flex-col overflow-hidden bg-[#0a0d12] md:flex-row"
    >
      <!-- Left Tree / List Navigation -->
      <aside
        id="file-tree-panel"
        aria-label="Project files"
        class="flex h-[min(38%,20rem)] w-full shrink-0 flex-col overflow-hidden border-b border-[#21262d] bg-[#11151c] md:h-full md:w-64 md:border-r md:border-b-0 xl:w-72"
      >
        <!-- Search Header -->
        <div class="p-3 border-b border-[#21262d]">
          <.form
            for={@filter_form}
            id="file-filter-form"
            phx-change="filter_files"
            class="relative"
          >
            <input
              type="text"
              name="filter"
              value={@filter}
              placeholder="Search files (e.g. .ex)..."
              class="w-full bg-[#0d1117] border border-[#30363d] rounded-xl px-3 py-1.5 pl-8 text-xs text-white placeholder-gray-500 font-mono focus:border-cyan-500 focus:outline-none"
            />
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-gray-400 absolute left-2.5 top-2" />
          </.form>
          <div class="flex items-center justify-between mt-2 px-1 text-[11px] font-mono text-gray-400">
            <span>{if @has_filter, do: length(@tree_items), else: length(@files)} files</span>
            <button
              phx-click="refresh_files"
              class="hover:text-white transition-smooth flex items-center gap-1"
            >
              <.icon name="hero-arrow-path" class="w-3 h-3" /> Refresh
            </button>
          </div>
        </div>

        <!-- Files List & Hierarchical Tree -->
        <div class="flex-1 overflow-y-auto p-2 space-y-0.5 font-mono text-xs">
          <%= for item <- @tree_items do %>
            <%= if item.type == :dir do %>
              <button
                type="button"
                phx-click="toggle_folder"
                phx-value-path={item.path}
                style={"padding-left: #{item.depth * 12 + 6}px"}
                class="w-full text-left py-1 pr-2 rounded-lg truncate transition-smooth flex items-center gap-1.5 text-gray-400 hover:text-white hover:bg-[#161b22] group"
              >
                <.icon
                  name={if item.expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                  class="w-3 h-3 text-gray-500 group-hover:text-gray-300 shrink-0"
                />
                <.icon
                  name={if item.expanded, do: "hero-folder-open", else: "hero-folder"}
                  class="w-3.5 h-3.5 text-amber-400 shrink-0"
                />
                <span class="truncate font-medium text-gray-300 group-hover:text-white">{item.name}</span>
              </button>
            <% else %>
              <% is_open = Enum.any?(@open_buffers, &(&1.path == item.path))
              buffer = Enum.find(@open_buffers, &(&1.path == item.path))
              is_buffer_dirty = buffer && buffer.dirty? %>
              <button
                type="button"
                phx-click="select_file"
                phx-value-path={item.path}
                style={"padding-left: #{if @has_filter, do: 8, else: item.depth * 12 + 16}px"}
                class={[
                  "w-full text-left py-1.5 pr-2.5 rounded-lg truncate transition-smooth flex items-center justify-between gap-2 group",
                  @selected_file == item.path &&
                    "bg-[#21262d] text-cyan-300 font-medium shadow-sm border border-[#30363d]",
                  @selected_file != item.path &&
                    "text-gray-400 hover:text-gray-200 hover:bg-[#161b22]"
                ]}
              >
                <div class="flex items-center gap-2 truncate">
                  <.icon
                    name={file_icon(item.name)}
                    class={["w-3.5 h-3.5 shrink-0", @selected_file == item.path && "text-cyan-400"]}
                  />
                  <span class="truncate">{item.name}</span>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <%= if is_buffer_dirty do %>
                    <span
                      class="w-2 h-2 rounded-full bg-amber-400 shadow-[0_0_4px_rgba(245,158,11,0.8)]"
                      title="Unsaved changes"
                    ></span>
                  <% else %>
                    <%= if is_open do %>
                      <span class="w-1.5 h-1.5 rounded-full bg-cyan-400/60" title="Open tab"></span>
                    <% end %>
                  <% end %>
                </div>
              </button>
            <% end %>
          <% end %>
          <button
            :if={@more_files}
            id="load-more-files"
            type="button"
            phx-click="load_more_files"
            class="mt-2 flex w-full items-center justify-center gap-1.5 rounded-lg border border-[#30363d] bg-[#161b22] px-3 py-2 text-[11px] font-semibold text-cyan-300 transition-smooth hover:border-cyan-500/50 hover:text-cyan-200"
          >
            <.icon name="hero-chevron-down" class="h-3.5 w-3.5" /> Load more files
          </button>
        </div>
      </aside>

      <!-- Right Interactive Code Editor Viewport -->
      <div
        id="file-editor-panel"
        class="flex min-h-0 min-w-0 flex-1 flex-col bg-[#0a0d12] overflow-hidden"
      >
        <%= if @selected_file do %>
          <!-- Open Buffer Tabs Bar -->
          <div class="flex items-center bg-[#11151c] border-b border-[#21262d] overflow-x-auto px-2 pt-1.5 gap-1 shrink-0">
            <%= for tab <- @open_buffers do %>
              <% is_active = tab.path == @selected_file %>
              <div class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-t-xl text-xs font-mono transition-smooth border-t border-x border-[#21262d] group shrink-0",
                is_active && "bg-[#0a0d12] text-cyan-300 font-medium border-b-0",
                !is_active && "bg-[#161b22] text-gray-400 hover:text-gray-200 hover:bg-[#1c2128]"
              ]}>
                <button
                  type="button"
                  phx-click="select_file"
                  phx-value-path={tab.path}
                  class="flex items-center gap-1.5 truncate max-w-[160px]"
                >
                  <.icon name={file_icon(tab.path)} class="w-3.5 h-3.5 shrink-0" />
                  <span class="truncate">{Path.basename(tab.path)}</span>
                </button>

                <%= if tab.dirty? do %>
                  <span class="w-2 h-2 rounded-full bg-amber-400 shrink-0" title="Unsaved changes">●</span>
                <% end %>

                <button
                  type="button"
                  phx-click="close_file_buffer"
                  phx-value-path={tab.path}
                  aria-label={"Close #{Path.basename(tab.path)} buffer"}
                  class="text-gray-500 hover:text-rose-400 p-0.5 rounded transition-smooth ml-1 shrink-0"
                  title="Close buffer"
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </div>
            <% end %>
          </div>

          <!-- Active File Toolbar -->
          <div class="file-editor-toolbar p-2.5 border-b border-[#21262d] bg-[#161b22] flex flex-wrap items-center justify-between gap-2 shrink-0 font-mono text-xs">
            <div class="flex items-center gap-2 min-w-0">
              <.icon name={file_icon(@selected_file)} class="w-4 h-4 text-cyan-400 shrink-0" />
              <span class="text-white font-semibold truncate">{@selected_file}</span>
              <%= if @is_dirty do %>
                <span class="text-[10px] font-mono text-amber-400 bg-amber-500/10 border border-amber-500/30 px-2 py-0.5 rounded font-semibold shrink-0">
                  ● Unsaved Changes
                </span>
              <% end %>
            </div>

            <!-- Editor Action Buttons: Revert, Save, Copy -->
            <div class="flex max-w-full items-center gap-1.5 sm:gap-2 shrink-0 overflow-x-auto">
              <%= if @is_dirty do %>
                <button
                  phx-click="revert_file_buffer"
                  class="px-2.5 py-1 bg-gray-700/40 hover:bg-gray-700/60 text-gray-300 border border-gray-600/30 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1"
                  title="Discard unsaved buffer edits"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                  <span class="hidden sm:inline">Revert</span>
                </button>
              <% end %>

              <button
                id="save-file-btn"
                phx-click="save_file"
                disabled={@editor_locked?}
                class={[
                  "px-3 py-1 rounded-lg text-xs font-mono font-semibold transition-smooth flex items-center gap-1.5",
                  @editor_locked? &&
                    "cursor-not-allowed bg-rose-950/50 text-rose-300/60 border border-rose-500/20",
                  @is_dirty &&
                    !@editor_locked? &&
                    "bg-emerald-600 hover:bg-emerald-500 text-white shadow-md shadow-emerald-600/20",
                  !@is_dirty && !@editor_locked? &&
                    "bg-[#21262d] text-gray-400 hover:text-gray-200"
                ]}
                title={
                  if(@editor_locked?,
                    do: "Save unavailable while another session owns this workspace resource",
                    else: "Save file to disk (Cmd+S)"
                  )
                }
              >
                <.icon name="hero-document-check" class="w-3.5 h-3.5" />
                <span>Save</span>
                <span class="text-[10px] opacity-70 hidden sm:inline">⌘S</span>
              </button>

              <button
                id="copy-file-btn"
                phx-hook="CodeCopy"
                data-code={@current_text}
                class="px-2.5 py-1 bg-[#21262d] hover:bg-[#30363d] text-gray-200 rounded-lg text-xs font-mono transition-smooth flex items-center gap-1.5"
              >
                <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
                <span class="hidden sm:inline">Copy</span>
              </button>
            </div>
          </div>

          <%= if @editor_locked? do %>
            <div
              id="editor-lock-ribbon"
              role="status"
              data-lock-state="foreign"
              data-lock-resource={@editor_lock.resource_type}
              class="flex items-center justify-between gap-4 border-b border-rose-500/30 bg-rose-950/35 px-3 py-2 font-mono text-xs text-rose-100"
            >
              <div class="flex min-w-0 items-center gap-2">
                <.icon name="hero-lock-closed" class="h-4 w-4 shrink-0 text-rose-400" />
                <span class="truncate">
                  Read-only while
                  <strong class="text-rose-300">{workspace_lock_label(@editor_lock)}</strong>
                  holds the {editor_lock_label(@editor_lock)} lock. Your unsaved buffer is safe.
                </span>
              </div>
              <button
                id="retry-file-lock-btn"
                type="button"
                phx-click="retry_file_lock"
                class="shrink-0 rounded-lg border border-rose-400/30 bg-rose-400/10 px-2.5 py-1 font-semibold text-rose-200 transition hover:border-rose-300/60 hover:bg-rose-400/20"
              >
                Retry access
              </button>
            </div>
          <% end %>

          <!-- Code Editor Body with Line Numbers & Colocated JS Hook -->
          <div
            id="code-editor-viewport"
            phx-hook=".CodeEditor"
            data-auto-save={to_string(@auto_save)}
            class="flex-1 flex overflow-hidden bg-[#0a0d12] relative font-mono text-xs"
          >
            <!-- Line Numbers Gutter -->
            <div class="editor-gutter w-12 bg-[#0d1117] border-r border-[#21262d] py-3 pr-2 text-right text-gray-600 select-none overflow-hidden shrink-0 font-mono text-[11px] leading-relaxed">
            </div>

            <!-- Code Input Textarea -->
            <textarea
              id="code-editor-textarea"
              name="file_content"
              spellcheck="false"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              readonly={@editor_locked?}
              aria-readonly={to_string(@editor_locked?)}
              class={[
                "flex-1 bg-transparent border-0 p-3 text-gray-200 font-mono text-xs leading-relaxed focus:outline-none focus:ring-0 resize-none overflow-auto whitespace-pre tab-2",
                @editor_locked? && "cursor-not-allowed bg-rose-950/5 text-gray-400"
              ]}
            ><%= @current_text %></textarea>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".CodeEditor">
            export default {
              mounted() {
                this.textarea = this.el.querySelector('textarea');
                this.gutter = this.el.querySelector('.editor-gutter');
                this.autoSaveTimer = null;
                this.updateGutter();

                this.textarea.addEventListener('input', () => {
                  this.updateGutter();
                  this.pushEvent('file_content_changed', { content: this.textarea.value });

                  clearTimeout(this.autoSaveTimer);
                  if (this.el.dataset.autoSave === 'true' && !this.textarea.readOnly) {
                    this.autoSaveTimer = setTimeout(() => {
                      this.pushEvent('save_file', {
                        content: this.textarea.value,
                        autosave: true
                      });
                    }, 900);
                  }
                });

                this.textarea.addEventListener('keydown', (e) => {
                  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                    e.preventDefault();
                    if (this.textarea.readOnly) return;
                    clearTimeout(this.autoSaveTimer);
                    this.pushEvent('save_file', { content: this.textarea.value });
                  }
                  if (e.key === 'Tab') {
                    if (this.textarea.readOnly) return;
                    e.preventDefault();
                    const start = this.textarea.selectionStart;
                    const end = this.textarea.selectionEnd;
                    this.textarea.value = this.textarea.value.substring(0, start) + '  ' + this.textarea.value.substring(end);
                    this.textarea.selectionStart = this.textarea.selectionEnd = start + 2;
                    this.updateGutter();
                    this.pushEvent('file_content_changed', { content: this.textarea.value });
                  }
                });

                this.textarea.addEventListener('scroll', () => {
                  if (this.gutter) {
                    this.gutter.scrollTop = this.textarea.scrollTop;
                  }
                });

                this.handleEvent('jump_to_editor_line', ({line, file}) => {
                  setTimeout(() => {
                    if (!this.textarea) return;
                    const lines = this.textarea.value.split('\n');
                    const targetLine = parseInt(line, 10) || 1;
                    let charPos = 0;
                    for (let i = 0; i < Math.min(targetLine - 1, lines.length); i++) {
                      charPos += lines[i].length + 1;
                    }
                    this.textarea.focus();
                    const lineLen = lines[targetLine - 1] ? lines[targetLine - 1].length : 0;
                    this.textarea.setSelectionRange(charPos, charPos + lineLen);
                    const lineHeight = 18;
                    this.textarea.scrollTop = Math.max(0, (targetLine - 5) * lineHeight);
                    if (this.gutter) {
                      this.gutter.scrollTop = this.textarea.scrollTop;
                    }
                  }, 50);
                });
              },
              updated() {
                this.updateGutter();
              },
              destroyed() {
                clearTimeout(this.autoSaveTimer);
              },
              updateGutter() {
                if (!this.gutter || !this.textarea) return;
                const lineCount = (this.textarea.value.match(/\n/g) || []).length + 1;
                let numbers = '';
                for (let i = 1; i <= lineCount; i++) {
                  numbers += `<div>${i}</div>`;
                }
                this.gutter.innerHTML = numbers;
              }
            }
          </script>
        <% else %>
          <div class="flex-1 flex flex-col items-center justify-center text-gray-500 font-mono text-xs space-y-2">
            <.icon name="hero-folder-open" class="w-8 h-8 text-gray-600" />
            <p>Select a workspace file on the left to preview contents</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp editor_lock_label(%{resource_type: "project"}), do: "project"
  defp editor_lock_label(%{resource_type: "file"}), do: "file"
  defp editor_lock_label(_lock), do: "workspace"

  defp file_icon(path) do
    path_str = to_string(path || "")

    cond do
      String.ends_with?(path_str, [".ex", ".exs"]) -> "hero-cube"
      String.ends_with?(path_str, [".heex", ".html"]) -> "hero-code-bracket"
      String.ends_with?(path_str, [".css", ".scss"]) -> "hero-paint-brush"
      String.ends_with?(path_str, [".js", ".ts"]) -> "hero-bolt"
      String.ends_with?(path_str, [".json", ".yaml", ".yml"]) -> "hero-document-text"
      String.ends_with?(path_str, [".md", ".markdown"]) -> "hero-document"
      true -> "hero-document"
    end
  end

  defp build_file_tree(files) do
    Enum.reduce(files, %{}, fn file, acc ->
      parts = Path.split(file)
      put_file_in_tree(acc, parts, file)
    end)
  end

  defp put_file_in_tree(acc, [filename], full_path) do
    Map.put(acc, filename, {:file, filename, full_path})
  end

  defp put_file_in_tree(acc, [dir | rest], full_path) do
    dir_entry =
      case Map.get(acc, dir) do
        {:dir, name, path, children} ->
          {:dir, name, path, children}

        _ ->
          full_parts = Path.split(full_path)
          dir_idx = Enum.find_index(full_parts, &(&1 == dir))

          dir_path =
            if dir_idx do
              full_parts |> Enum.take(dir_idx + 1) |> Path.join()
            else
              dir
            end

          {:dir, dir, dir_path, %{}}
      end

    {:dir, name, path, children} = dir_entry
    updated_children = put_file_in_tree(children, rest, full_path)
    Map.put(acc, dir, {:dir, name, path, updated_children})
  end

  defp flatten_file_tree(tree, expanded_folders, depth) do
    tree
    |> Enum.sort_by(fn
      {name, {:dir, _, _, _}} -> {0, String.downcase(name)}
      {name, {:file, _, _}} -> {1, String.downcase(name)}
    end)
    |> Enum.flat_map(fn
      {_name, {:dir, name, path, children}} ->
        is_expanded = MapSet.member?(expanded_folders, path)
        item = %{type: :dir, name: name, path: path, depth: depth, expanded: is_expanded}

        if is_expanded do
          [item | flatten_file_tree(children, expanded_folders, depth + 1)]
        else
          [item]
        end

      {_name, {:file, name, full_path}} ->
        [%{type: :file, name: name, path: full_path, depth: depth}]
    end)
  end

  # ============================================================================
  # F9: Interactive xterm.js Terminal Session (<.terminal_session>)
  # ============================================================================

  @doc """
  Renders an interactive PTY terminal session powered by xterm.js.
  Includes a top toolbar with shell badges, dimensions, quick actions,
  terminal lifecycle controls, visual active agent indicator, and xterm canvas viewport.
  """
  attr :session, :any, default: nil
  attr :running, :boolean, default: true
  attr :status, :atom, default: :running
  attr :shell, :string, default: "zsh"
  attr :cols, :integer, default: 80
  attr :rows, :integer, default: 24
  attr :occupant, :any, default: :user
  attr :active_cmd, :string, default: nil
  attr :output, :string, default: ""
  attr :form, :any, default: nil
  attr :workspace_locks, :list, default: []

  def terminal_session(assigns) do
    session_id =
      case assigns[:session] do
        %{id: id} -> id
        id when is_binary(id) and id != "" -> id
        _ -> "default"
      end

    owner_id = "terminal-session:#{session_id}"

    foreign_lock =
      Enum.find(assigns.workspace_locks, fn lock ->
        workspace_lock_value(lock, :status) == "held" and
          workspace_lock_value(lock, :owner_id) != owner_id
      end)

    assigns =
      assigns
      |> assign(:session_id, session_id)
      |> assign(:monitor_only, not is_nil(foreign_lock))
      |> assign(:foreign_lock, foreign_lock)

    ~H"""
    <div
      id="terminal-session-container"
      class="flex-1 flex flex-col h-full bg-[#0a0d12] p-4 gap-3 select-none overflow-hidden"
    >
      <!-- Top Toolbar: Badges, Quick Actions, Controls -->
      <div class="flex items-center justify-between shrink-0 font-mono text-xs flex-wrap gap-2">
        <!-- Left: Shell Info, Dimensions, Quick Action Launchers -->
        <div class="flex items-center gap-2 flex-wrap">
          <!-- Shell Info Badge -->
          <div
            id="terminal-shell-badge"
            class="flex items-center gap-1.5 px-2.5 py-1 bg-[#161b22] border border-[#30363d] rounded-lg text-gray-300 font-mono text-xs shadow-sm"
          >
            <span class={[
              "w-2 h-2 rounded-full",
              @status in [:running, :ready] &&
                "bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.6)] animate-pulse",
              @status == :restarting &&
                "bg-amber-400 shadow-[0_0_8px_rgba(251,191,36,0.6)] animate-spin",
              @status in [:stopped, :idle] && "bg-gray-500"
            ]}></span>
            <span class="font-semibold text-gray-200">{@shell || "zsh"}</span>
            <span class="text-gray-500 text-[10px]">PTY</span>
          </div>

          <!-- Dimensions Badge -->
          <div
            id="terminal-dimensions-badge"
            class="px-2 py-1 bg-[#161b22]/70 border border-[#30363d]/70 rounded-lg text-gray-400 font-mono text-[11px] shadow-sm"
          >
            {@cols}x{@rows}
          </div>

          <div class="h-4 w-px bg-[#30363d] mx-1"></div>

          <!-- Quick Action Buttons -->
          <button
            id="btn-quick-iex"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="iex -S mix"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-purple-300 hover:text-purple-200 transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Start Interactive Elixir Shell"
          >
            <.icon
              name="hero-bolt"
              class="w-3.5 h-3.5 text-purple-400 group-hover:scale-110 transition-transform"
            />
            <span>iex -S mix</span>
          </button>

          <button
            id="btn-quick-test"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="mix test"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-emerald-300 hover:text-emerald-200 transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Run Mix Test Suite"
          >
            <.icon
              name="hero-play"
              class="w-3.5 h-3.5 text-emerald-400 group-hover:scale-110 transition-transform"
            />
            <span>mix test</span>
          </button>

          <button
            id="btn-quick-precommit"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="mix precommit"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-cyan-300 hover:text-cyan-200 transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Run Precommit Quality Checks"
          >
            <.icon
              name="hero-check-badge"
              class="w-3.5 h-3.5 text-cyan-400 group-hover:scale-110 transition-transform"
            />
            <span>mix precommit</span>
          </button>

          <button
            id="btn-quick-git-status"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="git status"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-amber-300 hover:text-amber-200 transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Check Git Working Directory Status"
          >
            <.icon
              name="hero-document-text"
              class="w-3.5 h-3.5 text-amber-400 group-hover:scale-110 transition-transform"
            />
            <span>git status</span>
          </button>

          <button
            id="btn-quick-git-diff"
            phx-click="run_terminal_quick_action"
            phx-value-cmd="git diff"
            disabled={!@running or @monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-amber-300 hover:text-amber-200 transition-smooth font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:pointer-events-none group shadow-sm"
            title="Show Git Diff of Unstaged Changes"
          >
            <.icon
              name="hero-code-bracket"
              class="w-3.5 h-3.5 text-amber-400 group-hover:scale-110 transition-transform"
            />
            <span>git diff</span>
          </button>
        </div>

        <!-- Right: Terminal Controls (Clear, Restart, Kill) -->
        <div class="flex items-center gap-2">
          <button
            id="btn-terminal-clear"
            phx-click="clear_terminal"
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-gray-400 hover:text-gray-200 transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Clear Terminal Screen & Buffer"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" />
            <span>Clear</span>
          </button>

          <button
            id="btn-terminal-restart"
            phx-click="restart_terminal_session"
            disabled={@monitor_only}
            class="px-2.5 py-1 bg-[#161b22] hover:bg-[#21262d] active:bg-[#30363d] border border-[#30363d] rounded-lg text-sky-400 hover:text-sky-300 transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Restart PTY Shell Process"
          >
            <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
            <span>Restart</span>
          </button>

          <button
            id="btn-terminal-kill"
            phx-click="kill_terminal_session"
            disabled={@monitor_only}
            class="px-2.5 py-1 bg-rose-950/40 hover:bg-rose-900/50 active:bg-rose-800/60 border border-rose-800/60 rounded-lg text-rose-300 hover:text-rose-200 transition-smooth font-mono text-xs flex items-center gap-1.5 shadow-sm"
            title="Send SIGINT / Interrupt Shell"
          >
            <.icon name="hero-stop" class="w-3.5 h-3.5 text-rose-400" />
            <span>Kill</span>
          </button>
        </div>
      </div>

      <%= if @monitor_only do %>
        <div
          id="terminal-workspace-lock-banner"
          role="status"
          data-lock-state="foreign"
          class="flex shrink-0 items-center justify-between gap-3 rounded-xl border border-sky-400/25 bg-sky-400/10 px-3.5 py-2 font-mono text-xs text-sky-100"
        >
          <div class="flex items-center gap-2.5">
            <.icon name="hero-eye" class="size-4 text-sky-300" />
            <span class="font-semibold">Monitor-only terminal</span>
            <span class="text-sky-200/70">
              Workspace changes are locked by {workspace_lock_label(@foreign_lock)}.
            </span>
          </div>
          <span class="rounded-md border border-sky-300/20 bg-black/20 px-2 py-0.5 text-[10px] uppercase tracking-wider text-sky-200/70">
            Input disabled
          </span>
        </div>
      <% end %>

      <!-- Visual Active Agent Banner -->
      <%= if match?({:agent, _, _}, @occupant) or match?({:agent, _}, @occupant) do %>
        <% {agent_name, op_id} =
          case @occupant do
            {:agent, name, id} -> {name, id}
            {:agent, name} -> {name, nil}
            _ -> {"Agent", nil}
          end %>
        <div
          id="terminal-agent-banner"
          class="flex items-center justify-between px-3.5 py-2 bg-gradient-to-r from-amber-500/15 via-purple-500/15 to-indigo-500/15 border border-amber-500/30 rounded-xl text-xs font-mono text-amber-200 shadow-lg animate-in fade-in slide-in-from-top-1 shrink-0"
        >
          <div class="flex items-center gap-2.5 flex-wrap">
            <span class="flex h-2.5 w-2.5 relative">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-amber-500"></span>
            </span>
            <span class="font-bold text-amber-300">🤖 Agent Active:</span>
            <span class="px-2 py-0.5 bg-amber-400/20 text-amber-200 rounded font-semibold text-[11px] border border-amber-400/30">
              {agent_name}
            </span>
            <%= if @active_cmd do %>
              <span class="text-gray-400 text-[11px]">Executing:</span>
              <code class="px-2 py-0.5 bg-black/40 text-emerald-300 rounded font-mono text-[11px] border border-emerald-500/20">
                {@active_cmd}
              </code>
            <% end %>
            <%= if op_id do %>
              <span class="text-gray-500 text-[10px]">({op_id})</span>
            <% end %>
          </div>

          <div class="flex items-center gap-2 text-[11px] text-amber-300/80">
            <svg
              class="animate-spin h-3.5 w-3.5 text-amber-400"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"></path>
            </svg>
            <span class="italic text-[10px]">User input locked during autonomous execution</span>
          </div>
        </div>
      <% end %>

      <!-- xterm Container Viewport -->
      <div
        id="terminal-xterm-wrapper"
        class="flex-1 min-h-0 bg-[#0d1117] border border-[#21262d] rounded-2xl overflow-hidden shadow-2xl relative flex flex-col"
      >
        <div
          id="terminal-xterm-container"
          phx-hook="TerminalHook"
          phx-update="ignore"
          data-session-id={@session_id}
          data-monitor-only={to_string(@monitor_only)}
          aria-disabled={to_string(@monitor_only)}
          class="flex-1 w-full h-full p-2 bg-[#0d1117]"
        >
        </div>
        <div id="terminal-rendered-output" class="hidden">
          {@output}
        </div>
      </div>

      <!-- Quick Command Input Form -->
      <%= if @form do %>
        <.form
          for={@form}
          id="terminal-form"
          phx-submit="run_terminal_command"
          class="flex gap-2 shrink-0"
        >
          <div class="relative flex-1">
            <span class="absolute left-3 top-2.5 text-emerald-400 font-mono text-xs font-bold">$</span>
            <input
              type="text"
              name="command"
              value={Phoenix.HTML.Form.input_value(@form, :command)}
              placeholder="Enter shell command..."
              disabled={!@running or @monitor_only}
              class="w-full bg-[#11151c] border border-[#21262d] rounded-xl pl-7 pr-4 py-2 text-xs font-mono text-white focus:outline-none focus:border-emerald-500 disabled:opacity-50"
            />
            <%= if @active_cmd do %>
              <span id="terminal-active-cmd" class="hidden">{@active_cmd}</span>
            <% end %>
          </div>
          <button
            type="submit"
            disabled={!@running or @monitor_only}
            class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-xl text-xs font-mono font-medium transition-smooth disabled:opacity-50 disabled:pointer-events-none"
          >
            Run
          </button>
        </.form>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # F10: Collapsible Reasoning / Thinking Trace (<.thinking_trace>)
  # ============================================================================

  defp workspace_lock_value(nil, _key), do: nil

  defp workspace_lock_value(lock, key) when is_map(lock) do
    Map.get(lock, key) || Map.get(lock, Atom.to_string(key))
  end

  defp workspace_lock_label(lock) do
    cond do
      workspace_lock_value(lock, :run_id) -> "a coding run"
      workspace_lock_value(lock, :session_id) -> "another session"
      true -> "another task"
    end
  end

  @doc """
  Renders a collapsible disclosure card for LLM chain-of-thought reasoning deltas with latency metrics and markdown formatting.
  """
  attr :reasoning, :string, default: nil
  attr :duration_ms, :any, default: nil
  attr :tokens, :any, default: nil

  def thinking_trace(assigns) do
    ~H"""
    <%= if @reasoning && String.trim(@reasoning) != "" do %>
      <details class="mb-3 rounded-2xl bg-[#161b22] border border-[#21262d] p-3 text-xs font-mono group">
        <summary class="font-semibold text-amber-400 cursor-pointer flex items-center gap-2 select-none">
          <.icon name="hero-sparkles" class="w-3.5 h-3.5 text-amber-400 shrink-0" />
          <span>Thought Process (Reasoning Trace)</span>
          <div class="ml-auto flex items-center gap-2 text-[10px] font-mono text-gray-500">
            <%= if @duration_ms do %>
              <span>{@duration_ms}ms</span>
            <% end %>
            <%= if @tokens do %>
              <span>· {@tokens} tokens</span>
            <% end %>
            <.icon
              name="hero-chevron-down"
              class="w-3 h-3 text-gray-400 group-open:rotate-180 transition-transform"
            />
          </div>
        </summary>
        <div class="mt-2 pt-2 border-t border-[#21262d] text-[11px] text-gray-300 leading-relaxed whitespace-pre-wrap font-mono">
          {@reasoning}
        </div>
      </details>
    <% end %>
    """
  end

  # ============================================================================
  # F11: Markdown & Code Block Formatter (<.markdown_content>)
  # ============================================================================

  @doc """
  Renders markdown text with formatted code blocks, bold/italics, bullet points, headers, and code copy buttons.
  """
  attr :content, :string, required: true

  def markdown_content(assigns) do
    # Separate <think> blocks if present in content
    {reasoning, main_body} = extract_think_blocks(assigns.content)
    chunks = parse_markdown_chunks(main_body)
    assigns = assign(assigns, reasoning: reasoning, chunks: chunks)

    ~H"""
    <div class="markdown-body space-y-2">
      <%= if @reasoning do %>
        <.thinking_trace reasoning={@reasoning} />
      <% end %>
      <div class="space-y-2.5 font-sans text-sm leading-relaxed text-gray-200">
        <%= for chunk <- @chunks do %>
          <%= case chunk do %>
            <% {:text, text} -> %>
              <div class="whitespace-pre-wrap">
                {text}
              </div>
            <% {:code, lang, code} -> %>
              <div class="rounded-xl border border-[#30363d] bg-[#0d1117] overflow-hidden my-2.5 shadow-sm">
                <div class="flex items-center justify-between px-3 py-1.5 bg-[#161b22] border-b border-[#21262d] text-xs font-mono text-gray-400">
                  <span class="text-cyan-400 font-bold uppercase tracking-wider text-[11px]">{lang}</span>
                  <div class="flex items-center gap-1.5">
                    <button
                      type="button"
                      phx-click="insert_code_to_editor"
                      phx-value-code={code}
                      class="flex items-center gap-1 text-[11px] font-mono px-2 py-0.5 rounded bg-emerald-600/20 hover:bg-emerald-600/40 text-emerald-300 border border-emerald-500/30 transition-smooth"
                      title="Insert into active editor buffer"
                    >
                      <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" />
                      <span>Insert into Editor</span>
                    </button>
                    <button
                      type="button"
                      phx-hook="CodeCopy"
                      data-code={code}
                      id={"copy-code-" <> to_string(:erlang.phash2({lang, code}))}
                      class="flex items-center gap-1 text-[11px] font-mono px-2 py-0.5 rounded bg-[#21262d] hover:bg-gray-700 text-gray-300 transition-smooth"
                      title="Copy code"
                    >
                      <.icon name="hero-clipboard" class="w-3.5 h-3.5" />
                      <span>Copy</span>
                    </button>
                  </div>
                </div>
                <pre class="p-3 font-mono text-xs text-gray-200 overflow-x-auto selection:bg-cyan-900/60 leading-normal"><code>{code}</code></pre>
              </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp parse_markdown_chunks(text) when is_binary(text) do
    regex = ~r/```([a-zA-Z0-9_\-\.\+\#]*)\r?\n(.*?)```/s

    case Regex.scan(regex, text, return: :index) do
      [] ->
        if text != "", do: [{:text, text}], else: []

      matches ->
        {chunks, last_idx} =
          Enum.reduce(matches, {[], 0}, fn
            [{start, len}, {lang_start, lang_len}, {code_start, code_len}], {acc, prev} ->
              before_text =
                if start > prev do
                  String.slice(text, prev, start - prev)
                else
                  nil
                end

              lang =
                if lang_len > 0 do
                  String.slice(text, lang_start, lang_len) |> String.trim()
                else
                  "code"
                end

              code = String.slice(text, code_start, code_len) |> String.trim_trailing()

              acc =
                if before_text && before_text != "" do
                  [{:text, before_text} | acc]
                else
                  acc
                end

              acc = [{:code, if(lang == "", do: "code", else: lang), code} | acc]
              {acc, start + len}
          end)

        remaining = String.slice(text, last_idx..-1)

        final_chunks =
          if remaining && remaining != "" do
            [{:text, remaining} | chunks]
          else
            chunks
          end

        Enum.reverse(final_chunks)
    end
  end

  defp parse_markdown_chunks(_), do: []

  defp extract_think_blocks(text) when is_binary(text) do
    case Regex.run(~r/<think>(.*?)<\/think>/s, text) do
      [full_match, think_content] ->
        remaining = String.replace(text, full_match, "") |> String.trim()
        {String.trim(think_content), remaining}

      _ ->
        {nil, text}
    end
  end

  defp extract_think_blocks(other), do: {nil, to_string(other || "")}

  # ============================================================================
  # ANSI Escape Code to HTML Color Parser
  # ============================================================================

  @doc """
  Converts ANSI SGR escape codes into sanitized styled HTML spans with Tailwind CSS colors.
  """
  def ansi_to_html(raw_terminal_text) when is_binary(raw_terminal_text) do
    raw_terminal_text
    |> html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> parse_ansi_colors()
    |> raw()
  end

  def ansi_to_html(nil), do: raw("")

  defp parse_ansi_colors(text) do
    text
    # 24-bit TrueColor foreground: \e[38;2;R;G;Bm
    |> then(fn s ->
      Regex.replace(~r/\e\[38;2;(\d+);(\d+);(\d+)m/, s, fn _, r, g, b ->
        "<span style=\"color: rgb(#{r},#{g},#{b});\">"
      end)
    end)
    # 24-bit TrueColor background: \e[48;2;R;G;Bm
    |> then(fn s ->
      Regex.replace(~r/\e\[48;2;(\d+);(\d+);(\d+)m/, s, fn _, r, g, b ->
        "<span style=\"background-color: rgb(#{r},#{g},#{b});\">"
      end)
    end)
    # Compound SGR sequences (e.g. \e[1;31m, \e[1;32;40m)
    |> String.replace("\e[1;31m", "<span class=\"font-bold text-rose-400\">")
    |> String.replace("\e[1;32m", "<span class=\"font-bold text-emerald-400\">")
    |> String.replace("\e[1;33m", "<span class=\"font-bold text-amber-400\">")
    |> String.replace("\e[1;34m", "<span class=\"font-bold text-sky-400\">")
    |> String.replace("\e[1;35m", "<span class=\"font-bold text-purple-400\">")
    |> String.replace("\e[1;36m", "<span class=\"font-bold text-cyan-400\">")
    # Standard colors
    |> String.replace("\e[31m", "<span class=\"text-rose-400 font-medium\">")
    |> String.replace("\e[32m", "<span class=\"text-emerald-400 font-medium\">")
    |> String.replace("\e[33m", "<span class=\"text-amber-400 font-medium\">")
    |> String.replace("\e[34m", "<span class=\"text-sky-400 font-medium\">")
    |> String.replace("\e[35m", "<span class=\"text-purple-400 font-medium\">")
    |> String.replace("\e[36m", "<span class=\"text-cyan-400 font-medium\">")
    |> String.replace("\e[37m", "<span class=\"text-gray-200 font-medium\">")
    |> String.replace("\e[90m", "<span class=\"text-gray-500 font-medium\">")
    |> String.replace("\e[1m", "<span class=\"font-bold text-white\">")
    |> String.replace("\e[0m", "</span>")
    |> String.replace("\e[m", "</span>")
    # Clean any remaining control sequences / cursor movements
    |> String.replace(~r/\e\[[?0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\[[0-9;]*[HfABCDsuJK]/, "")
    |> String.replace(~r/\e[\(\)][0-9A-Za-z]/, "")
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)/, "")
    |> String.replace(~r/\e(\[[\d;]*|\][^\a\e]*|\([A-Z]|\[\?[0-9]+[a-zA-Z])?/, "")
    |> String.replace("\e", "")
  end

  # ============================================================================
  # M2: Global Command Palette (Cmd+K)
  # ============================================================================

  @doc """
  Renders the global Command Palette modal.
  """
  attr :show, :boolean, default: false
  attr :query, :string, default: ""
  attr :search_form, :map, required: true
  attr :category, :string, default: "all"
  attr :results, :list, default: []
  attr :selected_index, :integer, default: 0

  def command_palette(assigns) do
    indexed = Enum.with_index(assigns.results)

    assigns =
      assigns
      |> assign(:view_rows, Enum.filter(indexed, fn {item, _index} -> item.category == :view end))
      |> assign(
        :deck_rows,
        Enum.filter(indexed, fn {item, _index} -> item.id == "all-instruments" end)
      )
      |> assign(:other_groups, palette_groups(indexed))

    ~H"""
    <div id="command-palette-controller" phx-hook="CommandPalette" class="contents">
      <%= if @show do %>
        <div
          id="command-palette-modal"
          class="fixed inset-0 z-50 flex items-start justify-center bg-[var(--sf-shadow)] px-4 pt-[7vh] backdrop-blur-md"
        >
          <div class="fixed inset-0" phx-click="close_command_palette" aria-hidden="true"></div>
          <div
            id="command-palette-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="command-palette-title"
            aria-describedby="command-palette-description"
            tabindex="-1"
            data-sheet-close-event="close_command_palette"
            data-sheet-return-id="command-palette-trigger"
            data-sheet-background-id="workspace-shell"
            class="sf-chassis relative z-10 flex max-h-[84vh] w-full max-w-3xl flex-col overflow-hidden"
            phx-click-away="close_command_palette"
          >
            <h2 id="command-palette-title" class="sr-only">Signal Foundry switchboard</h2>
            <p id="command-palette-description" class="sr-only">
              Search instruments, projects, sessions, commands, settings, and account actions.
            </p>
            <div class="flex min-h-16 items-center gap-3 border-b border-[var(--sf-hairline)] bg-[var(--sf-instrument-raised)] px-5">
              <.icon
                name="hero-magnifying-glass"
                class="size-5 shrink-0 text-[var(--sf-text-secondary)]"
              />
              <.form
                for={@search_form}
                id="command-palette-form"
                phx-change="command_palette_search"
                phx-submit="command_palette_submit_noop"
                class="flex-1"
              >
                <.input
                  field={@search_form[:query]}
                  id="command-palette-input"
                  type="text"
                  role="combobox"
                  aria-label="Search Signal Foundry switchboard"
                  aria-autocomplete="list"
                  aria-expanded="true"
                  aria-controls="command-palette-results"
                  aria-activedescendant={
                    if(@results == [], do: nil, else: "palette-item-#{@selected_index}")
                  }
                  phx-debounce="80"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder="Find an instrument, project, session, or command"
                  class="min-h-11 w-full border-0 bg-transparent p-0 text-sm text-[var(--sf-text-primary)] placeholder:text-[var(--sf-text-secondary)] focus:outline-none focus:ring-0"
                />
              </.form>
              <button
                id="command-palette-close"
                type="button"
                phx-click="close_command_palette"
                aria-label="Close command palette"
                class="sf-control min-h-11 px-3 font-mono text-xs"
              >ESC</button>
            </div>

            <div class="flex items-center gap-1.5 overflow-x-auto border-b border-[var(--sf-hairline)] px-5 py-2.5 text-xs">
              <%= for {category, label} <- [{"all", "All"}, {"views", "Instruments"}, {"projects", "Projects"}, {"sessions", "Sessions"}, {"actions", "Commands"}, {"settings_account", "Settings / Account"}] do %>
                <button
                  type="button"
                  phx-click="command_palette_set_category"
                  phx-value-category={category}
                  aria-pressed={to_string(@category == category)}
                  class={[
                    "min-h-11 shrink-0 rounded-xl border px-3 transition-colors",
                    @category == category &&
                      "border-[var(--sf-live-mark)] bg-[var(--sf-raised-control)] text-[var(--sf-live-text)]",
                    @category != category &&
                      "border-transparent text-[var(--sf-text-secondary)] hover:border-[var(--sf-hairline)] hover:text-[var(--sf-text-primary)]"
                  ]}
                >{label}</button>
              <% end %>
            </div>

            <div
              id="command-palette-results"
              role="listbox"
              aria-label="Switchboard results"
              class="flex-1 overflow-y-auto p-4 sm:p-5"
            >
              <%= if @results == [] do %>
                <div class="py-16 text-center text-sm text-[var(--sf-text-secondary)]">
                  No matching switchboard controls
                </div>
              <% else %>
                <%= if @view_rows != [] or @deck_rows != [] do %>
                  <section aria-labelledby="switchboard-instruments-heading">
                    <h3
                      id="switchboard-instruments-heading"
                      class="sf-metadata mb-2 text-xs font-semibold uppercase tracking-[0.16em]"
                    >
                      Instruments
                    </h3>
                    <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                      <%= for {item, index} <- @view_rows do %>
                        <.palette_option
                          item={item}
                          index={index}
                          selected={index == @selected_index}
                        />
                      <% end %>
                    </div>
                    <div :if={@deck_rows != []} class="mt-2 space-y-1.5">
                      <%= for {item, index} <- @deck_rows do %>
                        <.palette_option
                          item={item}
                          index={index}
                          selected={index == @selected_index}
                        />
                      <% end %>
                    </div>
                  </section>
                <% end %>
                <%= for {{group_id, label}, rows} <- @other_groups do %>
                  <section
                    id={"switchboard-group-#{group_id}"}
                    aria-labelledby={"switchboard-#{group_id}-heading"}
                    class="mt-5"
                  >
                    <h3
                      id={"switchboard-#{group_id}-heading"}
                      class="sf-metadata mb-2 text-xs font-semibold uppercase tracking-[0.16em]"
                    >
                      {label}
                    </h3>
                    <div class="space-y-1.5">
                      <%= for {item, index} <- rows do %>
                        <.palette_option
                          item={item}
                          index={index}
                          selected={index == @selected_index}
                        />
                      <% end %>
                    </div>
                  </section>
                <% end %>
              <% end %>
            </div>
            <div class="sf-metadata flex items-center justify-between border-t border-[var(--sf-hairline)] px-5 py-3 font-mono text-xs">
              <span>↑↓ navigate · enter select · esc close</span><span>Signal Foundry</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :index, :integer, required: true
  attr :selected, :boolean, required: true

  defp palette_option(%{item: %{category: :account}} = assigns) do
    ~H"""
    <div
      id={"palette-item-#{@index}"}
      role="option"
      aria-selected={to_string(@selected)}
      tabindex="-1"
      data-palette-item-id={@item.id}
      class={[
        "flex min-h-12 items-center rounded-xl border px-3 transition-colors",
        @selected && "border-[var(--sf-live-mark)] bg-[var(--sf-raised-control)]",
        !@selected && "border-transparent hover:bg-[var(--sf-raised-control)]"
      ]}
    >
      <IexCodeWeb.Layouts.logout_button id="workspace-logout-form" class="w-full" />
    </div>
    """
  end

  defp palette_option(%{item: %{id: "new-session"}} = assigns) do
    ~H"""
    <div
      id={"palette-item-#{@index}"}
      role="option"
      aria-selected={to_string(@selected)}
      tabindex="-1"
      data-palette-item-id={@item.id}
      class={[
        "rounded-xl border transition-colors",
        @selected && "border-[var(--sf-live-mark)] bg-[var(--sf-raised-control)]",
        !@selected && "border-transparent hover:bg-[var(--sf-raised-control)]"
      ]}
    >
      <button
        id="new-session-btn"
        type="button"
        phx-click={
          JS.push("command_palette_select_item", page_loading: true, value: %{index: @index})
        }
        class="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-[var(--sf-text-primary)]"
      >
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-[var(--sf-hairline)] bg-[var(--sf-raised-control)] text-[var(--sf-text-secondary)]"><.icon
          name={@item.icon}
          class="size-4"
        /></span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-sm font-semibold">{@item.title}</span>
          <span class="block truncate text-xs text-[var(--sf-text-secondary)]">{@item.subtitle}</span>
        </span>
      </button>
    </div>
    """
  end

  defp palette_option(assigns) do
    ~H"""
    <div class="contents">
      <button
        id={"palette-item-#{@index}"}
        type="button"
        role="option"
        aria-selected={to_string(@selected)}
        tabindex="-1"
        data-palette-item-id={@item.id}
        data-palette-option-id={"palette-item-#{@index}"}
        data-palette-href={Map.get(@item, :href)}
        data-palette-surface={if(@item.category == :view, do: Map.get(@item, :tab), else: nil)}
        data-confirm={Map.get(@item, :confirmation)}
        data-sheet-close-event={
          if(@item.category == :confirmation, do: "close_command_palette", else: nil)
        }
        data-sheet-return-id={
          if(@item.category == :confirmation, do: "palette-item-#{@index}", else: nil)
        }
        data-sheet-background-id={
          if(@item.category == :confirmation, do: "workspace-shell", else: nil)
        }
        phx-click={
          JS.push("command_palette_select_item", page_loading: true, value: %{index: @index})
        }
        class={[
          "group flex min-h-12 w-full items-center gap-3 rounded-xl border px-3 py-2 text-left transition-colors",
          @selected &&
            "border-[var(--sf-live-mark)] bg-[var(--sf-raised-control)] text-[var(--sf-text-primary)]",
          !@selected &&
            "border-transparent text-[var(--sf-text-primary)] hover:border-[var(--sf-hairline)] hover:bg-[var(--sf-raised-control)]"
        ]}
      >
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-[var(--sf-hairline)] bg-[var(--sf-raised-control)] text-[var(--sf-text-secondary)]"><.icon
          name={Map.get(@item, :icon, "hero-cube")}
          class="size-4"
        /></span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-sm font-semibold">{@item.title}</span>
          <span class="block truncate text-xs text-[var(--sf-text-secondary)]">{Map.get(
            @item,
            :subtitle,
            to_string(@item.category)
          )}</span>
        </span>
        <span class="sf-metadata shrink-0 text-xs uppercase tracking-wider">{to_string(@item.category)}</span>
      </button>
    </div>
    """
  end

  defp palette_groups(indexed) do
    indexed
    |> Enum.reject(fn {item, _index} ->
      item.category == :view or item.id == "all-instruments"
    end)
    |> Enum.group_by(
      fn {item, _index} -> palette_group(item) end,
      fn row -> row end
    )
    |> Enum.sort_by(fn {{group_id, _label}, _rows} -> palette_group_order(group_id) end)
  end

  defp palette_group(%{id: "new-project"}), do: {"projects", "Projects"}
  defp palette_group(%{id: "new-session"}), do: {"sessions", "Sessions"}
  defp palette_group(%{category: :project}), do: {"projects", "Projects"}

  defp palette_group(%{category: category}) when category in [:session, :confirmation],
    do: {"sessions", "Sessions"}

  defp palette_group(%{category: :action}), do: {"commands", "Commands"}
  defp palette_group(%{category: :navigation}), do: {"settings", "Settings"}
  defp palette_group(%{category: :account}), do: {"account", "Account"}
  defp palette_group(_item), do: {"other", "Other"}

  defp palette_group_order("projects"), do: 1
  defp palette_group_order("sessions"), do: 2
  defp palette_group_order("commands"), do: 3
  defp palette_group_order("settings"), do: 4
  defp palette_group_order("account"), do: 5
  defp palette_group_order(_), do: 9
end
