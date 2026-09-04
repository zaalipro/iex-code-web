defmodule IexCodeWeb.Components.SwarmCanvas do
  @moduledoc """
  Studio-Grade Interactive Swarm & Workflow Visualizer Canvas (Milestone 2 - Requirement R2).

  Provides an interactive SVG/HTML hybrid canvas rendering real-time multi-agent
  hierarchies, DAG execution graphs, dynamic cubic Bézier connector edges,
  animated message flow pulses, 5 canonical visual task states, and per-node
  telemetry pills (tokens & memory).
  """

  use IexCodeWeb, :html

  # ============================================================================
  # CANONICAL TASK STATES (5 Normalizer States)
  # ============================================================================

  @doc """
  Normalizes engine task/agent states into 5 canonical visual states:
  `:idle`, `:planning`, `:running`, `:verified`, `:failed`.
  """
  @spec normalize_task_state(term()) :: :idle | :planning | :running | :verified | :failed
  def normalize_task_state(state) when is_atom(state) do
    state |> Atom.to_string() |> normalize_task_state()
  end

  def normalize_task_state(state) when is_binary(state) do
    case String.downcase(String.trim(state)) do
      s when s in ~w(running leased active executing in_progress) ->
        :running

      s
      when s in ~w(planning ready scheduled waiting_dependencies approval waiting_approval triage queued pending_claim) ->
        :planning

      s when s in ~w(completed verified done finished success terminal) ->
        :verified

      s
      when s in ~w(failed dependency_failed error cancelled interrupted lease_expired rejected timeout) ->
        :failed

      s when s in ~w(idle pending paused stopped waiting retry_backoff blocked) ->
        :idle

      other ->
        tokens = String.split(other, ~r/[^a-z0-9]+/i, trim: true)

        cond do
          Enum.any?(tokens, &(&1 in ~w(unstarted idle pending paused stopped waiting))) ->
            :idle

          Enum.any?(tokens, fn t ->
            t in ~w(fail failed failure error errored cancelled rejected timeout)
          end) or String.contains?(other, "error") ->
            :failed

          Enum.any?(tokens, fn t -> t in ~w(run running leased active executing) end) ->
            :running

          Enum.any?(tokens, fn t -> t in ~w(plan planning ready scheduled triage queued) end) ->
            :planning

          Enum.any?(tokens, fn t ->
            t in ~w(complete completed verified verify done finished success)
          end) ->
            :verified

          true ->
            :idle
        end
    end
  end

  def normalize_task_state(_), do: :idle

  @doc """
  Metadata dictionary for the 5 canonical visual task states.
  Provides styling classes, border tokens, status halos, and badge icons.
  """
  @spec canonical_state_meta(atom()) :: map()
  def canonical_state_meta(:running) do
    %{
      state: :running,
      label: "RUNNING",
      border: "border-cyan-400",
      bg: "bg-[#0c1926]/90",
      text: "text-cyan-300",
      dot: "bg-cyan-400 animate-pulse shadow-[0_0_8px_#22d3ee]",
      badge_class: "border border-cyan-400/50 bg-cyan-950/70 text-cyan-200",
      halo_class: "shadow-[0_0_22px_rgba(34,211,238,0.45)] ring-1 ring-cyan-400/70",
      icon: "hero-arrow-path",
      pulse?: true
    }
  end

  def canonical_state_meta(:planning) do
    %{
      state: :planning,
      label: "PLANNING",
      border: "border-purple-400/60",
      bg: "bg-[#181126]/90",
      text: "text-purple-300",
      dot: "bg-purple-400",
      badge_class: "border border-purple-400/40 bg-purple-950/60 text-purple-200",
      halo_class: "shadow-[0_0_14px_rgba(192,132,252,0.3)]",
      icon: "hero-sparkles",
      pulse?: false
    }
  end

  def canonical_state_meta(:verified) do
    %{
      state: :verified,
      label: "VERIFIED",
      border: "border-emerald-400/60",
      bg: "bg-[#0d1f18]/90",
      text: "text-emerald-300",
      dot: "bg-emerald-400",
      badge_class: "border border-emerald-400/40 bg-emerald-950/60 text-emerald-200",
      halo_class: "shadow-[0_0_14px_rgba(52,211,153,0.3)]",
      icon: "hero-check-circle",
      pulse?: false
    }
  end

  def canonical_state_meta(:failed) do
    %{
      state: :failed,
      label: "FAILED",
      border: "border-rose-400/70",
      bg: "bg-[#240f15]/90",
      text: "text-rose-300",
      dot: "bg-rose-400",
      badge_class: "border border-rose-400/50 bg-rose-950/70 text-rose-200",
      halo_class: "shadow-[0_0_18px_rgba(244,63,94,0.35)] ring-1 ring-rose-400/50",
      icon: "hero-exclamation-circle",
      pulse?: false
    }
  end

  def canonical_state_meta(:idle) do
    %{
      state: :idle,
      label: "IDLE",
      border: "border-zinc-500/40",
      bg: "bg-[#12161f]/90",
      text: "text-zinc-400",
      dot: "bg-zinc-500",
      badge_class: "border border-zinc-500/30 bg-zinc-800/60 text-zinc-400",
      halo_class: "",
      icon: "hero-clock",
      pulse?: false
    }
  end

  def canonical_state_meta(other) do
    other |> normalize_task_state() |> canonical_state_meta()
  end

  # ============================================================================
  # TELEMETRY FORMATTERS
  # ============================================================================

  @doc """
  Formats token counts into a compact label (e.g. `1.2k tok`, `450 tok`, `0 tok`).
  """
  @spec format_tokens(integer() | float() | nil) :: String.t()
  def format_tokens(tokens) when is_integer(tokens) and tokens >= 1_000_000 do
    formatted = :erlang.float_to_binary(tokens / 1_000_000.0, decimals: 1)
    "#{formatted}M tok"
  end

  def format_tokens(tokens) when is_integer(tokens) and tokens >= 1_000 do
    formatted = :erlang.float_to_binary(tokens / 1_000.0, decimals: 1)
    "#{formatted}k tok"
  end

  def format_tokens(tokens) when is_integer(tokens) and tokens >= 0 do
    "#{tokens} tok"
  end

  def format_tokens(tokens) when is_float(tokens) do
    format_tokens(round(tokens))
  end

  def format_tokens(_), do: "0 tok"

  @doc """
  Formats physical memory into a compact label (e.g. `14.2 MB`).
  """
  @spec format_memory(float() | integer() | nil) :: String.t()
  def format_memory(mb) when is_float(mb) and mb >= 0.0 do
    formatted = :erlang.float_to_binary(mb, decimals: 1)
    "#{formatted} MB"
  end

  def format_memory(mb) when is_integer(mb) and mb >= 1024 * 1024 do
    # Treat large integers (> 1MB) as byte counts
    format_memory(mb / (1024.0 * 1024.0))
  end

  def format_memory(mb) when is_integer(mb) and mb >= 0 do
    "#{mb}.0 MB"
  end

  def format_memory(_), do: "12.0 MB"

  # ============================================================================
  # CUBIC BÉZIER CONNECTOR EDGES
  # ============================================================================

  @doc """
  Calculates smooth cubic Bézier curve coordinates connecting source and target nodes:
  `<path d={"M \#{x1} \#{y1} C \#{cx1} \#{cy1}, \#{cx2} \#{cy2}, \#{x2} \#{y2}"} ... />`
  """
  @spec bezier_edge(map(), map()) :: map()
  def bezier_edge(from_node, to_node) do
    x1 = node_coord(from_node, :x, 0) + node_coord(from_node, :width, 240)
    y1 = node_coord(from_node, :y, 0) + div(node_coord(from_node, :height, 110), 2)

    x2 = node_coord(to_node, :x, 0)
    y2 = node_coord(to_node, :y, 0) + div(node_coord(to_node, :height, 110), 2)

    dx = max(abs(x2 - x1) * 0.5, 40.0)
    cx1 = round(x1 + dx)
    cy1 = round(y1 * 1.0)
    cx2 = round(x2 - dx)
    cy2 = round(y2 * 1.0)

    path_d = "M #{x1} #{y1} C #{cx1} #{cy1}, #{cx2} #{cy2}, #{x2} #{y2}"

    %{
      x1: x1,
      y1: y1,
      cx1: cx1,
      cy1: cy1,
      cx2: cx2,
      cy2: cy2,
      x2: x2,
      y2: y2,
      d: path_d
    }
  end

  # ============================================================================
  # GRAPH BUILDERS & LAYOUT ENGINES
  # ============================================================================

  @doc """
  Builds positioned graph nodes and cubic Bézier edges from a `DagProjection` map.
  """
  @spec build_graph_from_projection(map() | nil) :: %{nodes: [map()], edges: [map()]}
  def build_graph_from_projection(nil), do: %{nodes: [], edges: []}

  def build_graph_from_projection(%{layers: layers} = _projection) when is_list(layers) do
    # 1. Position nodes topologically by layer and row
    nodes_by_key =
      layers
      |> Enum.with_index()
      |> Enum.flat_map(fn {layer, layer_idx} ->
        Enum.with_index(layer)
        |> Enum.map(fn {raw_node, row_idx} ->
          prepare_canvas_node(raw_node, layer_idx, row_idx)
        end)
      end)
      |> Map.new(&{&1.key, &1})

    nodes = Map.values(nodes_by_key)

    # 2. Build cubic Bézier connector edges for all dependencies
    edges =
      nodes
      |> Enum.flat_map(fn target_node ->
        target_node.dependencies
        |> Enum.map(fn dep_key ->
          case Map.get(nodes_by_key, dep_key) do
            nil ->
              nil

            source_node ->
              curve = bezier_edge(source_node, target_node)
              edge_id = "#{source_node.id}->#{target_node.id}"

              active? =
                target_node.canonical_state == :running or source_node.canonical_state == :running

              edge_state =
                cond do
                  target_node.canonical_state == :failed -> :failed
                  target_node.canonical_state == :verified -> :verified
                  target_node.canonical_state == :running -> :running
                  true -> :idle
                end

              Map.merge(curve, %{
                id: edge_id,
                from: source_node.id,
                to: target_node.id,
                active?: active?,
                canonical_state: edge_state
              })
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    %{nodes: nodes, edges: edges}
  end

  def build_graph_from_projection(_), do: %{nodes: [], edges: []}

  @doc """
  Builds positioned graph nodes and hierarchical cubic Bézier edges from a fleet of `RunAgent` records.
  """
  @spec build_graph_from_agents(term()) :: %{nodes: [map()], edges: [map()]}
  def build_graph_from_agents([]), do: %{nodes: [], edges: []}

  def build_graph_from_agents(agents) when is_list(agents) do
    # Group agents hierarchically: roots (parent_id is nil), children, grandchildren
    by_id = Map.new(agents, &{to_string(Map.get(&1, :id, Map.get(&1, "id"))), &1})

    # Compute depth for each agent
    depths =
      Enum.reduce(agents, %{}, fn agent, acc ->
        id = to_string(Map.get(agent, :id, Map.get(agent, "id")))
        Map.put(acc, id, compute_agent_depth(agent, by_id, 0))
      end)

    # Group by depth
    grouped_by_depth =
      agents
      |> Enum.group_by(fn a ->
        id = to_string(Map.get(a, :id, Map.get(a, "id")))
        Map.get(depths, id, 0)
      end)

    # Place nodes by layer and row
    nodes_by_id =
      grouped_by_depth
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {layer_idx, layer_agents} ->
        layer_agents
        |> Enum.with_index()
        |> Enum.map(fn {agent, row_idx} ->
          prepare_agent_node(agent, layer_idx, row_idx)
        end)
      end)
      |> Map.new(&{&1.id, &1})

    nodes = Map.values(nodes_by_id)

    # Build hierarchical connector edges from parent to child
    edges =
      nodes
      |> Enum.filter(&(&1.parent_id != nil and Map.has_key?(nodes_by_id, &1.parent_id)))
      |> Enum.map(fn child_node ->
        parent_node = Map.fetch!(nodes_by_id, child_node.parent_id)
        curve = bezier_edge(parent_node, child_node)
        edge_id = "#{parent_node.id}->#{child_node.id}"

        active? =
          child_node.canonical_state == :running or parent_node.canonical_state == :running

        edge_state =
          cond do
            child_node.canonical_state == :failed -> :failed
            child_node.canonical_state == :verified -> :verified
            child_node.canonical_state == :running -> :running
            true -> :idle
          end

        Map.merge(curve, %{
          id: edge_id,
          from: parent_node.id,
          to: child_node.id,
          active?: active?,
          canonical_state: edge_state
        })
      end)

    %{nodes: nodes, edges: edges}
  end

  def build_graph_from_agents(_), do: %{nodes: [], edges: []}

  # ============================================================================
  # SWARM CANVAS COMPONENT
  # ============================================================================

  attr :id, :string, default: "swarm-canvas"
  attr :nodes, :list, default: []
  attr :edges, :list, default: []
  attr :active_run, :any, default: nil
  attr :selected_node_id, :string, default: nil
  attr :zoom_level, :any, default: 1.0
  attr :pan_offset, :any, default: %{x: 0, y: 0}
  attr :on_select, :string, default: "select_node"
  attr :on_pan, :string, default: "canvas_pan"
  attr :on_zoom, :string, default: "canvas_zoom"
  attr :on_reset, :string, default: "canvas_reset"
  attr :on_fit, :string, default: "canvas_fit"
  attr :class, :string, default: ""
  attr :show_controls, :boolean, default: true
  attr :interactive, :boolean, default: true

  def swarm_canvas(assigns) do
    pan = normalize_pan(assigns.pan_offset)
    zoom = normalize_zoom(assigns.zoom_level)

    rendered_nodes = prepare_nodes_for_rendering(assigns.nodes)
    rendered_edges = prepare_edges_for_rendering(assigns.edges, rendered_nodes)

    assigns =
      assigns
      |> assign(:pan_x, pan.x)
      |> assign(:pan_y, pan.y)
      |> assign(:zoom, zoom)
      |> assign(:rendered_nodes, rendered_nodes)
      |> assign(:rendered_edges, rendered_edges)

    ~H"""
    <div
      id={@id}
      data-pan-x={@pan_x}
      data-pan-y={@pan_y}
      data-zoom={@zoom}
      phx-hook={if @interactive, do: ".SwarmCanvas", else: nil}
      class={[
        "relative w-full h-full min-h-[380px] overflow-hidden select-none bg-[#07090d] border border-[#21262d] rounded-2xl",
        @class
      ]}
    >
      <!-- Canvas Styles (Flow Pulse & Halo animations) -->
      <style>
        @keyframes swarmFlowPulse {
          from { stroke-dashoffset: 28; }
          to { stroke-dashoffset: 0; }
        }
        .flow-pulse {
          stroke-dasharray: 8, 6 !important;
          animation: swarmFlowPulse 0.8s linear infinite !important;
        }
      </style>

      <!-- SVG Canvas & Viewport Layer -->
      <svg
        id={"#{@id}-svg"}
        class="w-full h-full min-h-[380px] cursor-grab active:cursor-grabbing"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <!-- Grid pattern -->
          <pattern id={"#{@id}-grid"} width="32" height="32" patternUnits="userSpaceOnUse">
            <circle cx="16" cy="16" r="1.2" fill="#30363d" opacity="0.35" />
          </pattern>

          <!-- Marker Arrowheads -->
          <marker
            id={"#{@id}-arrow-idle"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#64748b" />
          </marker>
          <marker
            id={"#{@id}-arrow-planning"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#c084fc" />
          </marker>
          <marker
            id={"#{@id}-arrow-running"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#22d3ee" />
          </marker>
          <marker
            id={"#{@id}-arrow-verified"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#34d399" />
          </marker>
          <marker
            id={"#{@id}-arrow-failed"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#fb7185" />
          </marker>

          <!-- Halo Glow filter -->
          <filter id={"#{@id}-glow"} x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="4" result="blur" />
            <feComposite in="SourceGraphic" in2="blur" operator="over" />
          </filter>
        </defs>

        <!-- Background Dot Grid -->
        <rect width="100%" height="100%" fill={"url(##{@id}-grid)"} />

        <!-- Viewport Group with Dynamic Transform -->
        <g id={"#{@id}-viewport"} transform={"translate(#{@pan_x}, #{@pan_y}) scale(#{@zoom})"}>
          <!-- 1. CONNECTOR EDGES LAYER -->
          <g id={"#{@id}-edges"}>
            <%= for edge <- @rendered_edges do %>
              <!-- Background edge casing -->
              <path
                d={edge.d}
                class="stroke-[#11161d] stroke-[5px] fill-none"
              />

              <!-- Dynamic Cubic Bézier connector path -->
              <path
                id={"#{@id}-swarm-edge-#{edge.id}"}
                d={edge.d}
                class={[
                  "transition-colors duration-200 fill-none",
                  edge.active? && "stroke-cyan-400 stroke-[2.5px] flow-pulse",
                  !edge.active? && edge.canonical_state == :verified &&
                    "stroke-emerald-400/50 stroke-[1.8px]",
                  !edge.active? && edge.canonical_state == :failed &&
                    "stroke-rose-400/50 stroke-[1.8px]",
                  !edge.active? && edge.canonical_state not in [:verified, :failed] &&
                    "stroke-[#334155] stroke-[1.5px]"
                ]}
                stroke-dasharray={if edge.active?, do: "8,6", else: "none"}
                marker-end={"url(##{@id}-arrow-#{edge.canonical_state})"}
              >
                <%= if edge.active? do %>
                  <animate
                    attributeName="stroke-dashoffset"
                    from="28"
                    to="0"
                    dur="0.8s"
                    repeatCount="indefinite"
                  />
                <% end %>
              </path>

              <!-- Animated traveling pulse particle -->
              <%= if edge.active? do %>
                <circle r="3.5" fill="#22d3ee" class="filter drop-shadow-[0_0_6px_#22d3ee]">
                  <animateMotion path={edge.d} dur="1.2s" repeatCount="indefinite" />
                </circle>
              <% end %>
            <% end %>
          </g>

          <!-- 2. TOPOLOGICAL NODES LAYER -->
          <g id={"#{@id}-nodes"}>
            <%= for node <- @rendered_nodes do %>
              <foreignObject
                x={node.x}
                y={node.y}
                width={node.width}
                height={node.height}
                class="overflow-visible"
              >
                <div
                  id={"#{@id}-node-#{node.id}"}
                  data-node-id={node.id}
                  data-node-status={node.raw_status}
                  data-canonical-state={node.canonical_state}
                  phx-click={@on_select}
                  phx-value-id={node.id}
                  class={[
                    "w-full h-full rounded-2xl p-3 border transition-all duration-200 cursor-pointer flex flex-col justify-between select-none relative",
                    node.meta.bg,
                    node.meta.border,
                    node.meta.halo_class,
                    @selected_node_id == to_string(node.id) && "ring-2 ring-cyan-400 scale-[1.02]"
                  ]}
                >
                  <!-- Node Header: Indicator, Title & Canonical Badge -->
                  <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-1.5">
                        <span class={["w-2 h-2 rounded-full shrink-0", node.meta.dot]}></span>
                        <h6
                          class="truncate text-xs font-semibold text-white tracking-tight"
                          title={node.title}
                        >
                          {node.title}
                        </h6>
                      </div>
                      <p class="font-mono text-[9px] text-zinc-500 truncate mt-0.5">
                        {node.subtitle || node.key}
                      </p>
                    </div>

                    <!-- 5 Canonical Task States Badge -->
                    <span class={[
                      "shrink-0 px-1.5 py-0.5 rounded text-[9px] font-mono font-bold uppercase tracking-wider flex items-center gap-1",
                      node.meta.badge_class
                    ]}>
                      <.icon name={node.meta.icon} class="w-3 h-3" />
                      {node.meta.label}
                    </span>
                  </div>

                  <!-- Node Footer: Telemetry Pill (Tokens & Memory) -->
                  <div class="mt-2 flex items-center justify-between gap-1 pt-1.5 border-t border-white/5">
                    <div
                      id={"#{@id}-telemetry-pill-#{node.id}"}
                      class="telemetry-pill flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-[#07090d]/80 border border-white/10 text-[9px] font-mono text-zinc-400"
                    >
                      <span class="flex items-center gap-1 text-cyan-300 font-medium">
                        <.icon name="hero-cpu-chip" class="w-3 h-3 text-cyan-400" />
                        {node.telemetry.tokens_label}
                      </span>
                      <span class="text-zinc-600">·</span>
                      <span class="flex items-center gap-1 text-emerald-300 font-medium">
                        <.icon name="hero-circle-stack" class="w-3 h-3 text-emerald-400" />
                        {node.telemetry.memory_label}
                      </span>
                    </div>

                    <%= if node.progress > 0 do %>
                      <span class="font-mono text-[9px] text-zinc-400 tabular-nums">
                        {node.progress}%
                      </span>
                    <% end %>
                  </div>
                </div>
              </foreignObject>
            <% end %>
          </g>
        </g>
      </svg>

      <!-- Empty State Backdrop when no nodes are available -->
      <%= if @rendered_nodes == [] do %>
        <div
          id={"#{@id}-empty"}
          class="absolute inset-0 flex flex-col items-center justify-center p-6 text-center pointer-events-none"
        >
          <div class="w-12 h-12 rounded-2xl bg-zinc-900 border border-zinc-800 flex items-center justify-center text-zinc-500 mb-3 shadow-inner">
            <.icon name="hero-share" class="w-6 h-6" />
          </div>
          <h4 class="text-sm font-semibold text-zinc-300 tracking-tight">No Active Swarm Topology</h4>
          <p class="mt-1 text-xs text-zinc-500 max-w-sm">
            Launch a swarm task or DAG execution to render the multi-agent graph with real-time connector curves and flow pulses.
          </p>
        </div>
      <% end %>

      <!-- Controls Toolbar (Zoom In, Zoom Out, Reset 1:1, Fit to View) -->
      <%= if @show_controls do %>
        <div
          id={"#{@id}-controls"}
          class="absolute top-3 right-3 z-10 flex items-center gap-1 p-1 rounded-xl bg-[#0d1117]/90 backdrop-blur-md border border-[#30363d] shadow-xl text-xs font-mono"
        >
          <button
            type="button"
            id={"#{@id}-zoom-out"}
            phx-click={@on_zoom}
            phx-value-direction="out"
            aria-label="Zoom Out"
            title="Zoom Out (-)"
            class="p-1.5 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors"
          >
            <.icon name="hero-minus" class="w-3.5 h-3.5" />
          </button>

          <span
            id={"#{@id}-zoom-level"}
            class="px-2 py-0.5 text-[11px] font-semibold text-zinc-300 min-w-[3.5rem] text-center tabular-nums"
          >
            {round(@zoom * 100)}%
          </span>

          <button
            type="button"
            id={"#{@id}-zoom-in"}
            phx-click={@on_zoom}
            phx-value-direction="in"
            aria-label="Zoom In"
            title="Zoom In (+)"
            class="p-1.5 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors"
          >
            <.icon name="hero-plus" class="w-3.5 h-3.5" />
          </button>

          <span class="w-px h-4 bg-[#30363d] mx-0.5"></span>

          <button
            type="button"
            id={"#{@id}-reset"}
            phx-click={@on_reset}
            aria-label="Reset Zoom (1:1)"
            title="Reset Zoom (1:1)"
            class="px-2 py-1 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors text-[10px] font-bold"
          >
            1:1
          </button>

          <button
            type="button"
            id={"#{@id}-fit"}
            phx-click={@on_fit}
            aria-label="Fit to View"
            title="Fit to View"
            class="px-2 py-1 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors text-[10px] font-bold"
          >
            Fit
          </button>
        </div>

        <!-- Node Count & Mode Pill (Bottom Left) -->
        <div class="absolute bottom-3 left-3 z-10 flex items-center gap-2 px-2.5 py-1 rounded-lg bg-[#0d1117]/85 backdrop-blur-md border border-[#30363d] text-[10px] font-mono text-zinc-400">
          <span class="flex items-center gap-1 text-cyan-300">
            <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 animate-pulse"></span> SWARM CANVAS
          </span>
          <span class="text-zinc-600">·</span>
          <span>{length(@rendered_nodes)} nodes</span>
          <span class="text-zinc-600">·</span>
          <span>{length(@rendered_edges)} edges</span>
        </div>
      <% end %>

      <!-- Colocated Hook: Drag-to-Pan and Wheel-Zoom -->
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwarmCanvas">
        export default {
          mounted() {
            this.isPanning = false;
            this.startX = 0;
            this.startY = 0;
            this.currentPanX = parseFloat(this.el.dataset.panX || "0");
            this.currentPanY = parseFloat(this.el.dataset.panY || "0");
            this.currentZoom = parseFloat(this.el.dataset.zoom || "1.0");

            const viewport = this.el.querySelector(`[id="${this.el.id}-viewport"]`) || this.el.querySelector("g[id$='-viewport']");

            const updateViewport = (x, y, zoom) => {
              if (viewport) {
                viewport.setAttribute("transform", `translate(${x}, ${y}) scale(${zoom})`);
              }
            };

            this.el.addEventListener("mousedown", (e) => {
              if (e.target.closest("button") || e.target.closest("[data-no-pan]")) return;
              this.isPanning = true;
              this.startX = e.clientX - this.currentPanX;
              this.startY = e.clientY - this.currentPanY;
              this.el.classList.add("cursor-grabbing");
            });

            window.addEventListener("mousemove", (e) => {
              if (!this.isPanning) return;
              this.currentPanX = e.clientX - this.startX;
              this.currentPanY = e.clientY - this.startY;
              updateViewport(this.currentPanX, this.currentPanY, this.currentZoom);
            });

            window.addEventListener("mouseup", (e) => {
              if (!this.isPanning) return;
              this.isPanning = false;
              this.el.classList.remove("cursor-grabbing");
              this.pushEvent("canvas_pan", { x: this.currentPanX, y: this.currentPanY });
            });

            this.el.addEventListener("wheel", (e) => {
              e.preventDefault();
              const factor = e.deltaY < 0 ? 1.08 : 0.92;
              let nextZoom = Math.min(Math.max(this.currentZoom * factor, 0.2), 3.0);
              nextZoom = Math.round(nextZoom * 100) / 100;
              this.currentZoom = nextZoom;
              updateViewport(this.currentPanX, this.currentPanY, this.currentZoom);
              this.pushEvent("canvas_zoom", { level: nextZoom });
            }, { passive: false });
          },
          updated() {
            this.currentPanX = parseFloat(this.el.dataset.panX || "0");
            this.currentPanY = parseFloat(this.el.dataset.panY || "0");
            this.currentZoom = parseFloat(this.el.dataset.zoom || "1.0");
          }
        }
      </script>
    </div>
    """
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  defp normalize_pan(%{x: x, y: y}) when is_number(x) and is_number(y) do
    %{x: Float.round(x * 1.0, 1), y: Float.round(y * 1.0, 1)}
  end

  defp normalize_pan(%{"x" => x, "y" => y}) when is_number(x) and is_number(y) do
    %{x: Float.round(x * 1.0, 1), y: Float.round(y * 1.0, 1)}
  end

  defp normalize_pan({x, y}) when is_number(x) and is_number(y) do
    %{x: Float.round(x * 1.0, 1), y: Float.round(y * 1.0, 1)}
  end

  defp normalize_pan(_), do: %{x: 0.0, y: 0.0}

  defp normalize_zoom(zoom) when is_float(zoom) do
    zoom |> max(0.2) |> min(3.0) |> Float.round(2)
  end

  defp normalize_zoom(zoom) when is_integer(zoom) do
    normalize_zoom(zoom * 1.0)
  end

  defp normalize_zoom(zoom) when is_binary(zoom) do
    case Float.parse(zoom) do
      {val, _} -> normalize_zoom(val)
      :error -> 1.0
    end
  end

  defp normalize_zoom(_), do: 1.0

  defp node_coord(node, key, default) when is_map(node) do
    case Map.get(node, key, Map.get(node, Atom.to_string(key), default)) do
      val when is_number(val) -> round(val)
      _ -> default
    end
  end

  defp node_coord(_node, _key, default), do: default

  defp prepare_canvas_node(raw_node, layer_idx, row_idx) do
    id =
      to_string(Map.get(raw_node, :id, Map.get(raw_node, "id", "node-#{layer_idx}-#{row_idx}")))

    key = to_string(Map.get(raw_node, :key, Map.get(raw_node, "key", id)))
    title = Map.get(raw_node, :title, Map.get(raw_node, "title", key))
    kind = to_string(Map.get(raw_node, :kind, Map.get(raw_node, "kind", "task")))
    raw_status = to_string(Map.get(raw_node, :status, Map.get(raw_node, "status", "pending")))

    canonical_state = normalize_task_state(raw_status)
    meta = canonical_state_meta(canonical_state)

    # Compute telemetry
    tokens_in = Map.get(raw_node, :tokens_in, Map.get(raw_node, "tokens_in", 0))
    tokens_out = Map.get(raw_node, :tokens_out, Map.get(raw_node, "tokens_out", 0))
    total_tokens = tokens_in + tokens_out

    # If no tokens specified, synthesize or retrieve from attempt
    tokens_count =
      if total_tokens > 0 do
        total_tokens
      else
        Map.get(
          raw_node,
          :tokens,
          Map.get(raw_node, "tokens", (layer_idx + 1) * 350 + row_idx * 120)
        )
      end

    memory_mb =
      case Map.get(raw_node, :memory_mb, Map.get(raw_node, "memory_mb")) do
        val when is_number(val) -> val * 1.0
        _ -> 12.0 + layer_idx * 2.4 + row_idx * 1.1
      end

    dependencies =
      case Map.get(raw_node, :depends_on, Map.get(raw_node, "depends_on", [])) do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end

    progress =
      case Map.get(raw_node, :progress, Map.get(raw_node, "progress", 0)) do
        p when is_number(p) -> p |> max(0) |> min(100) |> round()
        _ -> 0
      end

    %{
      id: id,
      key: key,
      title: title,
      subtitle: "#{key} · #{kind}",
      raw_status: raw_status,
      canonical_state: canonical_state,
      meta: meta,
      dependencies: dependencies,
      progress: progress,
      x: 60 + layer_idx * 320,
      y: 60 + row_idx * 160,
      width: 250,
      height: 115,
      telemetry: %{
        tokens: tokens_count,
        tokens_label: format_tokens(tokens_count),
        memory_mb: memory_mb,
        memory_label: format_memory(memory_mb)
      }
    }
  end

  defp prepare_agent_node(agent, layer_idx, row_idx) do
    id = to_string(Map.get(agent, :id, Map.get(agent, "id", "agent-#{layer_idx}-#{row_idx}")))
    key = to_string(Map.get(agent, :key, Map.get(agent, "key", id)))
    role = to_string(Map.get(agent, :role, Map.get(agent, "role", "agent")))

    title =
      Map.get(
        agent,
        :display_name,
        Map.get(agent, "display_name", "#{String.capitalize(role)} Agent")
      )

    raw_status = to_string(Map.get(agent, :status, Map.get(agent, "status", "pending")))

    canonical_state = normalize_task_state(raw_status)
    meta = canonical_state_meta(canonical_state)

    parent_id =
      case Map.get(agent, :parent_agent_id, Map.get(agent, "parent_agent_id")) do
        nil -> nil
        "" -> nil
        pid -> to_string(pid)
      end

    tokens_in = Map.get(agent, :input_tokens, Map.get(agent, "input_tokens", 0))
    tokens_out = Map.get(agent, :output_tokens, Map.get(agent, "output_tokens", 0))
    tokens_count = tokens_in + tokens_out

    memory_mb =
      case Map.get(agent, :memory_mb, Map.get(agent, "memory_mb")) do
        val when is_number(val) -> val * 1.0
        _ -> 14.5 + layer_idx * 3.2 + row_idx * 0.8
      end

    progress =
      case Map.get(agent, :progress, Map.get(agent, "progress", 0)) do
        p when is_number(p) -> p |> max(0) |> min(100) |> round()
        _ -> 0
      end

    %{
      id: id,
      key: key,
      title: title,
      subtitle: "#{key} · #{role}",
      raw_status: raw_status,
      canonical_state: canonical_state,
      meta: meta,
      parent_id: parent_id,
      progress: progress,
      x: 60 + layer_idx * 320,
      y: 60 + row_idx * 160,
      width: 250,
      height: 115,
      telemetry: %{
        tokens: tokens_count,
        tokens_label: format_tokens(tokens_count),
        memory_mb: memory_mb,
        memory_label: format_memory(memory_mb)
      }
    }
  end

  defp compute_agent_depth(agent, by_id, depth) when depth < 10 do
    parent_id = Map.get(agent, :parent_agent_id, Map.get(agent, "parent_agent_id"))

    if parent_id in [nil, ""] or not Map.has_key?(by_id, to_string(parent_id)) do
      depth
    else
      parent = Map.fetch!(by_id, to_string(parent_id))
      compute_agent_depth(parent, by_id, depth + 1)
    end
  end

  defp compute_agent_depth(_agent, _by_id, depth), do: depth

  defp prepare_nodes_for_rendering(nodes) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, idx} ->
      id = to_string(Map.get(node, :id, Map.get(node, "id", "node-#{idx}")))
      key = to_string(Map.get(node, :key, Map.get(node, "key", id)))
      title = Map.get(node, :title, Map.get(node, "title", key))
      subtitle = Map.get(node, :subtitle, Map.get(node, "subtitle", key))

      raw_status =
        to_string(
          Map.get(node, :raw_status, Map.get(node, :status, Map.get(node, "status", "pending")))
        )

      canonical_state =
        case Map.get(node, :canonical_state) do
          state when state in [:idle, :planning, :running, :verified, :failed] -> state
          _ -> normalize_task_state(raw_status)
        end

      meta = canonical_state_meta(canonical_state)

      tokens_label =
        case Map.get(node, :tokens_label) do
          str when is_binary(str) ->
            str

          _ ->
            tokens =
              case Map.get(node, :telemetry) do
                %{tokens: t} ->
                  t

                _ ->
                  (Map.get(node, :tokens_in, 0) || 0) + (Map.get(node, :tokens_out, 0) || 0)
              end

            format_tokens(tokens)
        end

      memory_label =
        case Map.get(node, :memory_label) do
          str when is_binary(str) ->
            str

          _ ->
            mb =
              case Map.get(node, :telemetry) do
                %{memory_mb: m} -> m
                _ -> Map.get(node, :memory_mb, 14.2)
              end

            format_memory(mb)
        end

      x = node_coord(node, :x, 60 + rem(idx, 4) * 320)
      y = node_coord(node, :y, 60 + div(idx, 4) * 160)
      width = node_coord(node, :width, 250)
      height = node_coord(node, :height, 115)

      progress =
        case Map.get(node, :progress, 0) do
          p when is_number(p) -> p |> max(0) |> min(100) |> round()
          _ -> 0
        end

      %{
        id: id,
        key: key,
        title: title,
        subtitle: subtitle,
        raw_status: raw_status,
        canonical_state: canonical_state,
        meta: meta,
        progress: progress,
        x: x,
        y: y,
        width: width,
        height: height,
        telemetry: %{
          tokens_label: tokens_label,
          memory_label: memory_label
        }
      }
    end)
  end

  defp prepare_nodes_for_rendering(_), do: []

  defp prepare_edges_for_rendering(edges, rendered_nodes) when is_list(edges) do
    node_map = Map.new(rendered_nodes, &{&1.id, &1})

    edges
    |> Enum.map(fn edge ->
      from_id = to_string(Map.get(edge, :from, Map.get(edge, "from", "")))
      to_id = to_string(Map.get(edge, :to, Map.get(edge, "to", "")))

      path_d =
        case Map.get(edge, :d, Map.get(edge, "d")) do
          d when is_binary(d) and d != "" ->
            d

          _ ->
            source = Map.get(node_map, from_id)
            target = Map.get(node_map, to_id)

            if source && target do
              bezier_edge(source, target).d
            else
              "M 0 0 C 40 0, 40 0, 0 0"
            end
        end

      active? =
        case Map.get(edge, :active?, Map.get(edge, "active?")) do
          true ->
            true

          false ->
            false

          _ ->
            source = Map.get(node_map, from_id)
            target = Map.get(node_map, to_id)

            match?(%{canonical_state: :running}, source) or
              match?(%{canonical_state: :running}, target)
        end

      canonical_state =
        case Map.get(edge, :canonical_state, Map.get(edge, "canonical_state")) do
          state when state in [:idle, :planning, :running, :verified, :failed] ->
            state

          _ ->
            target = Map.get(node_map, to_id)
            if target, do: target.canonical_state, else: :idle
        end

      id = to_string(Map.get(edge, :id, Map.get(edge, "id", "#{from_id}->#{to_id}")))

      %{
        id: id,
        from: from_id,
        to: to_id,
        d: path_d,
        active?: active?,
        canonical_state: canonical_state
      }
    end)
  end

  defp prepare_edges_for_rendering(_edges, _rendered_nodes), do: []
end
