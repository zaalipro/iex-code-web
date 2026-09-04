defmodule IexCodeWeb.WorkflowComponents do
  @moduledoc """
  Production UI components for the Grok-Like Workflows Cockpit (Milestone 2).
  Renders interactive SVG DAG canvas, animated cubic Bézier connectors, glowing node halos,
  circular progress rings, live slide-over inspector drawer, and execution control toolbar.
  """

  use IexCodeWeb, :html
  alias IexCode.Workflows.WorkflowDag

  # ============================================================================
  # CONSTANTS
  # ============================================================================

  @node_width 250
  @node_height 115
  @gap_x 90
  @gap_y 45
  @pad_x 60
  @pad_y 60

  @circle_radius 15.0
  @circle_circumference 2.0 * :math.pi() * @circle_radius

  # ============================================================================
  # INTERACTIVE WORKFLOW SVG CANVAS
  # ============================================================================

  attr :id, :string, default: "workflow-canvas"
  attr :workflow, :any, required: true
  attr :run, :any, required: true
  attr :selected_step_key, :string, default: nil
  attr :zoom_level, :float, default: 1.0
  attr :pan_offset, :map, default: %{x: 0.0, y: 0.0}
  attr :on_select_step, :string, default: "inspect_step"
  attr :on_pan, :string, default: "canvas_pan"
  attr :on_zoom, :string, default: "canvas_zoom"
  attr :class, :string, default: ""

  def workflow_canvas(assigns) do
    steps = assigns.run.resolved_steps || assigns.workflow.steps || []
    step_states = assigns.run.step_states || %{}
    current_step_key = assigns.run.current_step_key

    run_status =
      cond do
        is_map(assigns.run) -> Map.get(assigns.run, :status) || Map.get(assigns.run, "status")
        true -> nil
      end

    graph = layout_workflow_dag(steps, step_states, current_step_key, run_status)

    assigns =
      assigns
      |> assign(:nodes, graph.nodes)
      |> assign(:edges, graph.edges)
      |> assign(:canvas_width, graph.width)
      |> assign(:canvas_height, graph.height)
      |> assign(:circumference, Float.round(@circle_circumference, 4))

    ~H"""
    <div
      id={@id}
      data-pan-x={@pan_offset.x}
      data-pan-y={@pan_offset.y}
      data-zoom={@zoom_level}
      phx-hook=".WorkflowCanvasHook"
      class={[
        "relative w-full h-[620px] overflow-hidden select-none bg-[#07090e] border border-[#21262d] rounded-2xl shadow-2xl",
        @class
      ]}
    >
      <style>
        @keyframes workflowPulse {
          from { stroke-dashoffset: 28; }
          to { stroke-dashoffset: 0; }
        }
        .active-edge-flow {
          stroke-dasharray: 8 6 !important;
          animation: workflowPulse 0.8s linear infinite !important;
        }
      </style>

      <svg
        id={"#{@id}-svg"}
        class="w-full h-full cursor-grab active:cursor-grabbing"
        xmlns="http://www.w3.org/2000/svg"
        viewBox={"0 0 #{@canvas_width} #{@canvas_height}"}
      >
        <defs>
          <pattern id={"#{@id}-grid"} width="32" height="32" patternUnits="userSpaceOnUse">
            <circle cx="16" cy="16" r="1.2" fill="#30363d" opacity="0.3" />
          </pattern>

          <marker
            id={"#{@id}-arrow-pending"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#475569" />
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
            id={"#{@id}-arrow-completed"}
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
          <marker
            id={"#{@id}-arrow-paused"}
            markerWidth="8"
            markerHeight="8"
            refX="7"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 8 3.5, 0 7" fill="#fbbf24" />
          </marker>

          <filter id={"#{@id}-glow-running"} x="-30%" y="-30%" width="160%" height="160%">
            <feGaussianBlur stdDeviation="6" result="blur" />
            <feColorMatrix
              type="matrix"
              values="0 0 0 0 0.133  0 0 0 0 0.827  0 0 0 0 0.933  0 0 0 0.6 0"
              result="cyanGlow"
            />
            <feMerge>
              <feMergeNode in="cyanGlow" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          <filter id={"#{@id}-glow-completed"} x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="4" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          <filter id={"#{@id}-glow-failed"} x="-25%" y="-25%" width="150%" height="150%">
            <feGaussianBlur stdDeviation="5" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        <rect width="100%" height="100%" fill={"url(##{@id}-grid)"} />

        <g
          id={"#{@id}-viewport"}
          transform={"translate(#{@pan_offset.x}, #{@pan_offset.y}) scale(#{@zoom_level})"}
        >
          <!-- 1. CUBIC BÉZIER CONNECTOR EDGES -->
          <g id={"#{@id}-edges"}>
            <%= for edge <- @edges do %>
              <!-- Background Casing Stroke -->
              <path d={edge.d} class="stroke-[#0b0f14] stroke-[6px] fill-none" />

              <!-- State-Colored Main Stroke -->
              <path
                id={"edge-#{edge.id}"}
                d={edge.d}
                class={[
                  "fill-none transition-colors duration-200",
                  edge.active? && "stroke-cyan-400 stroke-[2.5px] active-edge-flow",
                  !edge.active? && edge.status == "completed" && "stroke-emerald-400/60 stroke-[2px]",
                  !edge.active? && edge.status == "failed" && "stroke-rose-400/60 stroke-[2px]",
                  !edge.active? && edge.status == "paused" &&
                    "stroke-amber-400/60 stroke-[1.8px] stroke-dasharray-[6,4]",
                  !edge.active? && edge.status == "pending" &&
                    "stroke-[#334155] stroke-[1.5px] stroke-dasharray-[4,4]"
                ]}
                marker-end={"url(##{@id}-arrow-#{edge.status})"}
              />

              <!-- Flowing Pulse Particles on Active Running Edges -->
              <%= if edge.active? do %>
                <circle
                  r="6"
                  fill="#22d3ee"
                  opacity="0.3"
                  class="filter drop-shadow-[0_0_8px_#22d3ee]"
                >
                  <animateMotion path={edge.d} dur="1.2s" repeatCount="indefinite" />
                </circle>
                <circle r="3" fill="#ffffff" class="filter drop-shadow-[0_0_4px_#22d3ee]">
                  <animateMotion path={edge.d} dur="1.2s" repeatCount="indefinite" />
                </circle>
              <% end %>
            <% end %>
          </g>

          <!-- 2. WORKFLOW STEP NODES -->
          <g id={"#{@id}-nodes"}>
            <%= for node <- @nodes do %>
              <foreignObject
                x={node.x}
                y={node.y}
                width={node.width}
                height={node.height}
                class="overflow-visible"
              >
                <article
                  id={"step-node-#{node.key}"}
                  data-step-key={node.key}
                  data-step-status={node.status}
                  phx-click={@on_select_step}
                  phx-value-key={node.key}
                  class={[
                    "w-full h-full rounded-2xl p-3.5 border transition-all duration-300 cursor-pointer flex flex-col justify-between select-none relative group backdrop-blur-xl",
                    node.meta.bg,
                    node.meta.border,
                    node.meta.halo,
                    @selected_step_key == node.key &&
                      "ring-2 ring-cyan-400 scale-[1.03] shadow-[0_0_28px_rgba(34,211,238,0.5)]"
                  ]}
                >
                  <!-- Card Header -->
                  <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <span class={["w-2 h-2 rounded-full shrink-0", node.meta.dot]}></span>
                        <h4
                          class="text-xs font-bold text-white tracking-tight truncate"
                          title={node.title}
                        >
                          {node.title}
                        </h4>
                      </div>
                      <p class="font-mono text-[10px] text-zinc-400 truncate mt-0.5">
                        {node.key} · {node.kind}
                      </p>
                    </div>

                    <!-- Circular Progress Ring Badge -->
                    <div class="shrink-0">
                      <.step_progress_ring status={node.status} progress={node.progress} />
                    </div>
                  </div>

                  <!-- Card Footer -->
                  <div class="mt-2 pt-2 border-t border-white/5 flex items-center justify-between text-[9px] font-mono text-zinc-400">
                    <span class="flex items-center gap-1 text-cyan-300 truncate max-w-[120px]">
                      <.icon name="hero-cpu-chip" class="w-3 h-3 text-cyan-400 shrink-0" />
                      {node.model_label}
                    </span>
                    <span class="tabular-nums">
                      {node.duration_label}
                    </span>
                  </div>
                </article>
              </foreignObject>
            <% end %>
          </g>
        </g>
      </svg>

      <!-- Bottom Status Pill -->
      <div class="absolute bottom-3 left-3 z-10 flex items-center gap-2 px-3 py-1.5 rounded-xl bg-[#0d1117]/90 backdrop-blur-md border border-[#30363d] text-[10px] font-mono text-zinc-400">
        <span class="flex items-center gap-1.5 text-cyan-300 font-bold">
          <span class="w-2 h-2 rounded-full bg-cyan-400 animate-pulse"></span> WORKFLOW CANVAS
        </span>
        <span class="text-zinc-600">·</span>
        <span>{length(@nodes)} steps</span>
        <span class="text-zinc-600">·</span>
        <span>{length(@edges)} dependencies</span>
      </div>

      <!-- Canvas Pan/Zoom Controls -->
      <div class="absolute top-3 right-3 z-10 flex items-center gap-1 p-1 rounded-xl bg-[#0d1117]/90 backdrop-blur-md border border-[#30363d] shadow-xl text-xs font-mono">
        <button
          type="button"
          id={"#{@id}-zoom-out-btn"}
          phx-click={@on_zoom}
          phx-value-direction="out"
          class="p-1.5 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors"
          title="Zoom Out (-)"
        >
          <.icon name="hero-minus" class="w-3.5 h-3.5" />
        </button>
        <span class="px-2 py-0.5 text-[11px] font-semibold text-zinc-300 min-w-[3.2rem] text-center tabular-nums">
          {round(@zoom_level * 100)}%
        </span>
        <button
          type="button"
          id={"#{@id}-zoom-in-btn"}
          phx-click={@on_zoom}
          phx-value-direction="in"
          class="p-1.5 rounded-lg hover:bg-white/10 text-zinc-300 hover:text-white transition-colors"
          title="Zoom In (+)"
        >
          <.icon name="hero-plus" class="w-3.5 h-3.5" />
        </button>
      </div>

      <!-- Colocated JS Hook for Pan & Zoom -->
      <script :type={Phoenix.LiveView.ColocatedHook} name=".WorkflowCanvasHook">
        export default {
          mounted() {
            this.isPanning = false;
            this.startX = 0;
            this.startY = 0;
            this.panX = parseFloat(this.el.dataset.panX || "0");
            this.panY = parseFloat(this.el.dataset.panY || "0");
            this.zoom = parseFloat(this.el.dataset.zoom || "1.0");

            const viewport = this.el.querySelector("g[id$='-viewport']");
            const updateTransform = (x, y, z) => {
              if (viewport) {
                viewport.setAttribute("transform", `translate(${x}, ${y}) scale(${z})`);
              }
            };

            this.el.addEventListener("mousedown", (e) => {
              if (e.target.closest("button") || e.target.closest("article")) return;
              this.isPanning = true;
              this.startX = e.clientX - this.panX;
              this.startY = e.clientY - this.panY;
              this.el.classList.add("cursor-grabbing");
            });

            window.addEventListener("mousemove", (e) => {
              if (!this.isPanning) return;
              this.panX = e.clientX - this.startX;
              this.panY = e.clientY - this.startY;
              updateTransform(this.panX, this.panY, this.zoom);
            });

            window.addEventListener("mouseup", () => {
              if (!this.isPanning) return;
              this.isPanning = false;
              this.el.classList.remove("cursor-grabbing");
              this.pushEvent("canvas_pan", { x: this.panX, y: this.panY });
            });

            this.el.addEventListener("wheel", (e) => {
              e.preventDefault();
              const factor = e.deltaY < 0 ? 1.08 : 0.92;
              let nextZoom = Math.min(Math.max(this.zoom * factor, 0.25), 2.5);
              nextZoom = Math.round(nextZoom * 100) / 100;
              this.zoom = nextZoom;
              updateTransform(this.panX, this.panY, this.zoom);
              this.pushEvent("canvas_zoom", { level: nextZoom });
            }, { passive: false });
          },
          updated() {
            this.panX = parseFloat(this.el.dataset.panX || "0");
            this.panY = parseFloat(this.el.dataset.panY || "0");
            this.zoom = parseFloat(this.el.dataset.zoom || "1.0");
          }
        }
      </script>
    </div>
    """
  end

  # ============================================================================
  # CIRCULAR PROGRESS RING COMPONENT
  # ============================================================================

  attr :status, :string, default: "pending"
  attr :progress, :integer, default: 0
  attr :radius, :float, default: @circle_radius
  attr :class, :string, default: ""

  def step_progress_ring(assigns) do
    r = assigns.radius
    circumference = 2.0 * :math.pi() * r
    progress = max(0, min(100, assigns.progress || 0))
    offset = calc_progress_dashoffset(progress, circumference)

    assigns =
      assigns
      |> assign(:r, r)
      |> assign(:circumference, Float.round(circumference, 4))
      |> assign(:offset, Float.round(offset, 4))

    ~H"""
    <div class={["relative flex items-center justify-center w-9 h-9 shrink-0", @class]}>
      <svg class="w-9 h-9 -rotate-90 transform" viewBox="0 0 36 36">
        <circle
          cx="18"
          cy="18"
          r={@r}
          fill="none"
          class="stroke-[#1e2530]"
          stroke-width="2.5"
        />
        <circle
          cx="18"
          cy="18"
          r={@r}
          fill="none"
          class={[
            "transition-all duration-300 ease-out",
            @status == "running" && "stroke-cyan-400 drop-shadow-[0_0_4px_#22d3ee]",
            @status == "completed" && "stroke-emerald-400",
            @status == "failed" && "stroke-rose-400",
            @status == "paused" && "stroke-amber-400",
            @status == "pending" && "stroke-zinc-700"
          ]}
          stroke-width="2.5"
          stroke-linecap="round"
          stroke-dasharray={@circumference}
          stroke-dashoffset={@offset}
        />
      </svg>
      <div class="absolute inset-0 flex items-center justify-center">
        <%= if @status == "running" and @progress > 0 do %>
          <span class="font-mono text-[9px] font-bold text-cyan-300 tabular-nums">
            {@progress}%
          </span>
        <% else %>
          <.icon name={status_icon_name(@status)} class={["w-3.5 h-3.5", status_icon_color(@status)]} />
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # 4-TAB LIVE SLIDE-OVER STEP INSPECTOR DRAWER
  # ============================================================================

  attr :step, :map, required: true
  attr :run, :any, required: true
  attr :active_tab, :atom, default: :logs
  attr :on_close, :string, default: "close_step_inspector"
  attr :on_set_tab, :string, default: "set_inspector_tab"
  attr :on_retry, :string, default: "retry_workflow_step"

  def step_inspector(assigns) do
    step_key = step_key(assigns.step)
    step_state = Map.get(assigns.run.step_states || %{}, step_key, %{})
    status = Map.get(step_state, "status", "pending")
    output = Map.get(step_state, "output", %{})
    output_map = if is_map(output), do: output, else: %{}
    error = Map.get(step_state, "error", Map.get(step_state, "error_message"))
    progress = if status == "completed", do: 100, else: Map.get(step_state, "progress", 0)

    model_config =
      Map.get(assigns.step, "model_config") || Map.get(assigns.step, :model_config) || %{}

    reasoning_effort = Map.get(model_config, "reasoning_effort", "none")
    model_id = Map.get(model_config, "model_id") || Map.get(model_config, "model", "default")
    provider = Map.get(model_config, "provider", "openai")

    safety_policy =
      Map.get(assigns.step, "safety_policy") || Map.get(assigns.step, :safety_policy) ||
        "full_auto"

    input_tokens = Map.get(step_state, "input_tokens", Map.get(output_map, "input_tokens", 0))
    output_tokens = Map.get(step_state, "output_tokens", Map.get(output_map, "output_tokens", 0))
    total_tokens = input_tokens + output_tokens
    duration_ms = Map.get(step_state, "duration_ms", Map.get(output_map, "duration_ms", 0))
    cost_cents = Map.get(step_state, "cost_cents", Map.get(output_map, "cost_cents", 0))

    # Artifact count
    artifacts = extract_step_artifacts(assigns.step, output_map)

    assigns =
      assigns
      |> assign(:step_key, step_key)
      |> assign(:step_state, step_state)
      |> assign(:status, status)
      |> assign(:output, output)
      |> assign(:error, error)
      |> assign(:progress, progress)
      |> assign(:reasoning_effort, reasoning_effort)
      |> assign(:model_id, model_id)
      |> assign(:provider, provider)
      |> assign(:safety_policy, safety_policy)
      |> assign(:input_tokens, input_tokens)
      |> assign(:output_tokens, output_tokens)
      |> assign(:total_tokens, total_tokens)
      |> assign(:duration_ms, duration_ms)
      |> assign(:cost_cents, cost_cents)
      |> assign(:artifacts, artifacts)

    ~H"""
    <div
      id="workflow-step-inspector-backdrop"
      class="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm transition-opacity"
      phx-click={@on_close}
    >
      <aside
        id="workflow-step-inspector"
        onclick="event.stopPropagation();"
        class="fixed inset-y-0 right-0 z-50 flex w-full max-w-2xl flex-col border-l border-white/10 bg-[#0a0e14]/95 backdrop-blur-2xl shadow-2xl font-sans text-gray-100"
      >
        <!-- Header -->
        <header class="flex items-center justify-between border-b border-white/10 px-6 py-4">
          <div class="flex items-center gap-3">
            <.step_progress_ring status={@status} progress={@progress} />
            <div>
              <div class="flex items-center gap-2">
                <h3 class="text-base font-bold text-white tracking-tight">
                  {Map.get(@step, "title") || Map.get(@step, :title) || @step_key}
                </h3>
                <span class={[
                  "px-2 py-0.5 rounded font-mono text-[9px] uppercase tracking-wider font-bold",
                  status_badge_class(@status)
                ]}>
                  {@status}
                </span>
              </div>
              <p class="font-mono text-[11px] text-zinc-500 mt-0.5">
                {@step_key} · {Map.get(@step, "kind") || Map.get(@step, :kind)}
              </p>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <!-- Retry Step Button when Failed or Cancelled -->
            <%= if @status in ["failed", "cancelled"] do %>
              <button
                type="button"
                id="btn-retry-step-inspector"
                phx-click={@on_retry}
                phx-value-step={@step_key}
                class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-rose-500/20 border border-rose-500/40 text-rose-300 font-mono text-xs hover:bg-rose-500/30 transition-colors"
              >
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                <span>Retry Step</span>
              </button>
            <% end %>

            <button
              type="button"
              id="btn-close-step-inspector"
              phx-click={@on_close}
              class="p-2 rounded-lg text-zinc-400 hover:text-white hover:bg-white/10 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>
        </header>

        <!-- 4-Tab Navigation Bar -->
        <nav class="flex border-b border-white/10 bg-[#070a0f] px-6">
          <button
            :for={
              {tab, label, icon} <- [
                {:logs, "Logs & Output", "hero-command-line"},
                {:thinking, "Thinking Traces", "hero-sparkles"},
                {:metrics, "Telemetry & Cost", "hero-chart-bar"},
                {:artifacts, "Artifacts & Diffs", "hero-document-duplicate"}
              ]
            }
            type="button"
            id={"inspector-tab-#{tab}"}
            phx-click={@on_set_tab}
            phx-value-tab={tab}
            class={[
              "flex items-center gap-2 px-4 py-3 font-mono text-xs font-medium border-b-2 transition-colors",
              @active_tab == tab && "border-cyan-400 text-cyan-300 bg-cyan-950/20",
              @active_tab != tab &&
                "border-transparent text-zinc-400 hover:text-zinc-200 hover:border-zinc-700"
            ]}
          >
            <.icon name={icon} class="w-4 h-4" />
            {label}
            <%= if tab == :artifacts and length(@artifacts) > 0 do %>
              <span class="px-1.5 py-0.2 rounded-full bg-cyan-400/20 text-cyan-300 text-[10px]">
                {length(@artifacts)}
              </span>
            <% end %>
          </button>
        </nav>

        <!-- Tab Panel Body -->
        <div class="flex-1 overflow-y-auto p-6 space-y-4">
          <!-- TAB 1: LOGS & OUTPUT -->
          <%= if @active_tab == :logs do %>
            <div id="inspector-panel-logs" class="space-y-3">
              <div class="flex items-center justify-between">
                <span class="font-mono text-xs text-zinc-400">Execution Output and Terminal Stream</span>
                <%= if @error do %>
                  <span class="text-xs font-mono text-rose-400 bg-rose-500/10 px-2 py-0.5 rounded border border-rose-500/30">
                    Failed with Error
                  </span>
                <% end %>
              </div>

              <%= if @error do %>
                <div class="rounded-xl border border-rose-500/40 bg-rose-950/30 p-3 font-mono text-xs text-rose-300">
                  <div class="flex items-center gap-1.5 font-bold mb-1">
                    <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-rose-400" />
                    <span>Error Details:</span>
                  </div>
                  <pre class="overflow-x-auto whitespace-pre-wrap"><code phx-no-curly-interpolation><%= if is_binary(@error), do: @error, else: inspect(@error) %></code></pre>
                </div>
              <% end %>

              <div class="relative rounded-xl border border-[#1e2530] bg-[#05070a] p-4 font-mono text-xs text-zinc-300 min-h-[260px] max-h-[500px] overflow-y-auto">
                <% raw_output = extract_log_content(@output, @step_state) %>
                <%= if raw_output != "" do %>
                  <pre class="whitespace-pre-wrap"><code phx-no-curly-interpolation><%= raw_output %></code></pre>
                <% else %>
                  <div class="flex flex-col items-center justify-center h-48 text-zinc-500">
                    <.icon name="hero-command-line" class="w-8 h-8 mb-2 opacity-40" />
                    <span>No execution logs streamed yet</span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <!-- TAB 2: AGENT THINKING TRACES -->
          <%= if @active_tab == :thinking do %>
            <div id="inspector-panel-thinking" class="space-y-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class="font-mono text-xs text-zinc-400">Model Reasoning & Chain-of-Thought</span>
                  <%= if @status == "running" do %>
                    <span class="flex items-center gap-1 text-[10px] font-mono text-amber-300 bg-amber-500/10 px-2 py-0.5 rounded border border-amber-500/30">
                      <span class="w-2 h-2 rounded-full bg-amber-400 animate-ping"></span>
                      Reasoning Active
                    </span>
                  <% end %>
                </div>

                <div class="flex items-center gap-2 font-mono text-[10px]">
                  <span class="px-2 py-0.5 rounded bg-white/5 border border-white/10 text-cyan-300">
                    Effort: {@reasoning_effort}
                  </span>
                  <span class="px-2 py-0.5 rounded bg-white/5 border border-white/10 text-zinc-400">
                    Provider: {@provider}
                  </span>
                </div>
              </div>

              <% thoughts = extract_thinking_traces(@output, @step_state) %>
              <%= if thoughts != "" do %>
                <div class="rounded-xl border border-amber-500/20 bg-[#0d1017] p-4 font-mono text-xs text-amber-100/90 max-h-[480px] overflow-y-auto">
                  <pre class="whitespace-pre-wrap"><code phx-no-curly-interpolation><%= thoughts %></code></pre>
                </div>
              <% else %>
                <div class="rounded-xl border border-dashed border-zinc-800 p-8 text-center text-zinc-500 font-mono text-xs">
                  <.icon name="hero-sparkles" class="w-8 h-8 mx-auto mb-2 opacity-30 text-amber-400" />
                  <p>No chain-of-thought traces recorded for this step.</p>
                  <p class="text-[11px] text-zinc-600 mt-1">
                    Configured reasoning effort: {@reasoning_effort}
                  </p>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- TAB 3: TELEMETRY & COST -->
          <%= if @active_tab == :metrics do %>
            <div id="inspector-panel-metrics" class="space-y-4 font-mono">
              <span class="text-xs text-zinc-400">Step Telemetry, Token Footprint & Safety Tier</span>

              <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Input Tokens</p>
                  <p class="text-lg font-bold text-white mt-1 tabular-nums">{@input_tokens}</p>
                </div>
                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Output Tokens</p>
                  <p class="text-lg font-bold text-white mt-1 tabular-nums">{@output_tokens}</p>
                </div>
                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Total Tokens</p>
                  <p class="text-lg font-bold text-cyan-300 mt-1 tabular-nums">{@total_tokens}</p>
                </div>

                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Execution Duration</p>
                  <p class="text-lg font-bold text-white mt-1 tabular-nums">
                    {if @duration_ms > 0, do: "#{@duration_ms}ms", else: "—"}
                  </p>
                </div>
                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Estimated Cost</p>
                  <p class="text-lg font-bold text-emerald-300 mt-1 tabular-nums">
                    {if @cost_cents > 0, do: "$#{Float.round(@cost_cents / 100.0, 4)}", else: "$0.00"}
                  </p>
                </div>
                <div class="p-3 rounded-xl bg-[#0e131b] border border-white/5">
                  <p class="text-[10px] text-zinc-500 uppercase">Safety Policy</p>
                  <p class="text-sm font-bold text-purple-300 mt-1.5 uppercase">{@safety_policy}</p>
                </div>
              </div>

              <!-- Model Configuration Summary -->
              <div class="p-4 rounded-xl bg-[#0e131b] border border-white/5 space-y-2 text-xs">
                <div class="flex items-center justify-between text-zinc-400">
                  <span>Model ID:</span>
                  <span class="text-white font-semibold">{@model_id}</span>
                </div>
                <div class="flex items-center justify-between text-zinc-400">
                  <span>Provider:</span>
                  <span class="text-white uppercase font-semibold">{@provider}</span>
                </div>
                <div class="flex items-center justify-between text-zinc-400">
                  <span>Reasoning Effort:</span>
                  <span class="text-cyan-300 uppercase font-semibold">{@reasoning_effort}</span>
                </div>
              </div>
            </div>
          <% end %>

          <!-- TAB 4: GENERATED ARTIFACTS & DIFFS -->
          <%= if @active_tab == :artifacts do %>
            <div id="inspector-panel-artifacts" class="space-y-4">
              <span class="font-mono text-xs text-zinc-400">Generated Artifacts, Patches, Reports & Commits</span>

              <%= if length(@artifacts) > 0 do %>
                <%= for artifact <- @artifacts do %>
                  <div class="rounded-xl border border-white/10 bg-[#0d1117] p-4 space-y-2">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <.icon name={artifact.icon} class="w-4 h-4 text-cyan-400" />
                        <span class="font-mono text-xs font-bold text-white">{artifact.title}</span>
                      </div>
                      <span class="px-2 py-0.5 rounded bg-white/5 text-[10px] font-mono text-zinc-400">
                        {artifact.type}
                      </span>
                    </div>

                    <%= if artifact.content do %>
                      <div class="rounded-lg bg-[#05070a] border border-[#1e2530] p-3 font-mono text-xs text-zinc-300 max-h-[320px] overflow-y-auto">
                        <pre class="whitespace-pre-wrap"><code phx-no-curly-interpolation><%= artifact.content %></code></pre>
                      </div>
                    <% end %>

                    <!-- Milestone 4: Multi-Model Swarm Consensus & Live Peer Stream Drawer -->
                    <%= if Map.get(artifact, :consensus_matrix) do %>
                      <div class="space-y-4 pt-3 border-t border-white/5">
                        <div class="flex items-center justify-between">
                          <span class="font-mono text-xs font-bold text-zinc-200 flex items-center gap-2">
                            <.icon name="hero-cpu-chip" class="w-4 h-4 text-cyan-400" />
                            <span>Swarm Consensus & Merge Gating</span>
                          </span>
                          <.merge_gating_badge decision={artifact.merge_verdict || :approved} />
                        </div>

                        <%= if artifact.dynamic_roster && length(artifact.dynamic_roster) > 0 do %>
                          <.swarm_roster_pills roster={artifact.dynamic_roster} />
                        <% end %>

                        <.consensus_heatmap matrix={artifact.consensus_matrix} />

                        <.dimensional_score_bars scores={
                          (is_map(artifact.consensus_matrix) &&
                             (artifact.consensus_matrix[:dimensional_averages] ||
                                artifact.consensus_matrix["dimensional_averages"])) || %{}
                        } />

                        <%= if artifact.peer_messages && length(artifact.peer_messages) > 0 do %>
                          <.peer_message_timeline messages={artifact.peer_messages} />
                        <% end %>
                      </div>
                    <% end %>

                    <!-- 1-Click Research Chaining Actions -->
                    <%= if artifact.type == "report" or (Map.get(artifact, :citations) && length(Map.get(artifact, :citations)) > 0) do %>
                      <div class="flex flex-wrap items-center gap-2 pt-2 border-t border-white/5">
                        <.link
                          navigate={
                            ~p"/create-workflow?research_query=#{Map.get(artifact, :query) || "Research Synthesis"}"
                          }
                          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-cyan-500/10 text-cyan-300 hover:bg-cyan-500/20 border border-cyan-500/30 text-xs font-mono font-medium transition"
                          id={"chain-workflow-btn-#{String.replace(artifact.title, " ", "-")}"}
                        >
                          <.icon name="hero-bolt" class="w-3.5 h-3.5 text-cyan-400" />
                          <span>Create Workflow from Research</span>
                        </.link>
                        <button
                          type="button"
                          phx-click="chain_to_swarm"
                          phx-value-query={Map.get(artifact, :query) || "Research Synthesis"}
                          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-violet-500/10 text-violet-300 hover:bg-violet-500/20 border border-violet-500/30 text-xs font-mono font-medium transition"
                          id={"chain-swarm-btn-#{String.replace(artifact.title, " ", "-")}"}
                        >
                          <.icon name="hero-cpu-chip" class="w-3.5 h-3.5 text-violet-400" />
                          <span>Chain to Swarm Code Gen</span>
                        </button>
                      </div>
                    <% end %>

                    <!-- Evidence Audit & Conflict Resolution Badges Panel -->
                    <%= if Map.get(artifact, :conflicts) && length(Map.get(artifact, :conflicts)) > 0 do %>
                      <div class="space-y-2 pt-3 border-t border-white/5">
                        <div class="flex items-center justify-between">
                          <span class="font-mono text-[11px] text-zinc-300 font-semibold flex items-center gap-1.5">
                            <.icon name="hero-scale" class="w-3.5 h-3.5 text-amber-400" />
                            Evidence Audit & Conflict Resolution:
                          </span>
                          <div class="flex items-center gap-1.5 font-mono text-[9px]">
                            <span class="px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-400 border border-emerald-500/30 font-bold">
                              {count_conflicts_by_status(Map.get(artifact, :conflicts), :verified)} VERIFIED
                            </span>
                            <span class="px-1.5 py-0.5 rounded bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-bold">
                              {count_conflicts_by_status(Map.get(artifact, :conflicts), :consensus)} CONSENSUS
                            </span>
                            <span class="px-1.5 py-0.5 rounded bg-amber-500/15 text-amber-400 border border-amber-500/30 font-bold">
                              {count_conflicts_by_status(Map.get(artifact, :conflicts), :disputed)} DISPUTED
                            </span>
                          </div>
                        </div>

                        <div class="space-y-2">
                          <%= for conflict <- Map.get(artifact, :conflicts) do %>
                            <div class="rounded-lg border border-white/5 bg-[#05070a] p-2.5 space-y-1.5 text-xs font-mono">
                              <div class="flex items-center justify-between">
                                <span class="font-bold text-zinc-200">
                                  {Map.get(conflict, :topic) || Map.get(conflict, "topic")}
                                </span>
                                <span class={[
                                  "px-1.5 py-0.5 rounded text-[9px] font-bold border uppercase tracking-wider",
                                  conflict_badge_classes(conflict)
                                ]}>
                                  {conflict_status_string(conflict)}
                                </span>
                              </div>
                              <div class="grid grid-cols-2 gap-2 text-[11px] pt-1">
                                <div class="p-1.5 rounded bg-white/[0.02] border border-white/5">
                                  <span class="text-zinc-500 text-[9px] block uppercase font-semibold">
                                    {get_claim_field(
                                      Map.get(conflict, :claim_a) || Map.get(conflict, "claim_a") ||
                                        %{},
                                      :domain,
                                      "Source A"
                                    )}
                                  </span>
                                  <span class="text-zinc-300 line-clamp-3">
                                    {get_claim_field(
                                      Map.get(conflict, :claim_a) || Map.get(conflict, "claim_a") ||
                                        %{},
                                      :text
                                    )}
                                  </span>
                                </div>
                                <div class="p-1.5 rounded bg-white/[0.02] border border-white/5">
                                  <span class="text-zinc-500 text-[9px] block uppercase font-semibold">
                                    {get_claim_field(
                                      Map.get(conflict, :claim_b) || Map.get(conflict, "claim_b") ||
                                        %{},
                                      :domain,
                                      "Source B"
                                    )}
                                  </span>
                                  <span class="text-zinc-300 line-clamp-3">
                                    {get_claim_field(
                                      Map.get(conflict, :claim_b) || Map.get(conflict, "claim_b") ||
                                        %{},
                                      :text
                                    )}
                                  </span>
                                </div>
                              </div>
                              <div class="text-[10px] text-zinc-400 pt-1 border-t border-white/5">
                                <span class="text-cyan-400 font-semibold">Resolution:</span> {Map.get(
                                  conflict,
                                  :rationale
                                ) || Map.get(conflict, "rationale") || ""}
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>

                    <!-- Visual Source Cards & Real-Time Citation Graph -->
                    <%= if artifact.citations && length(artifact.citations) > 0 do %>
                      <div class="space-y-2 pt-3 border-t border-white/5">
                        <div class="flex items-center justify-between">
                          <p class="font-mono text-[11px] text-zinc-300 font-semibold flex items-center gap-1.5">
                            <.icon name="hero-share" class="w-3.5 h-3.5 text-cyan-400" />
                            Visual Citations & Source Graph:
                          </p>
                          <span class="font-mono text-[10px] text-zinc-500">
                            {length(artifact.citations)} sources evaluated
                          </span>
                        </div>

                        <div class="grid grid-cols-1 gap-2">
                          <%= for cit <- artifact.citations do %>
                            <div class="rounded-lg border border-white/5 bg-[#05070a] p-2.5 space-y-2">
                              <div class="flex items-start justify-between gap-2">
                                <div class="flex items-center gap-2 min-w-0">
                                  <div class="p-1 rounded bg-white/5 text-cyan-400 shrink-0">
                                    <.icon
                                      name={
                                        citation_authority_icon(
                                          cit["authority_category"] || cit[:authority_category]
                                        )
                                      }
                                      class="w-3.5 h-3.5"
                                    />
                                  </div>
                                  <div class="min-w-0">
                                    <a
                                      href={cit["url"] || cit[:url]}
                                      target="_blank"
                                      rel="noopener noreferrer"
                                      class="text-cyan-300 hover:text-cyan-200 text-xs font-mono font-medium truncate flex items-center gap-1 hover:underline"
                                    >
                                      <span class="truncate max-w-[280px]">{cit["title"] ||
                                        cit[:title] || cit["url"]}</span>
                                      <.icon
                                        name="hero-arrow-top-right-on-square"
                                        class="w-3 h-3 shrink-0 opacity-70"
                                      />
                                    </a>
                                    <div class="flex items-center gap-1.5 text-[9px] font-mono text-zinc-500">
                                      <span class="text-zinc-400 font-semibold">{cit["domain"] ||
                                        cit[:domain] || "docs"}</span>
                                      <span
                                        :if={Map.get(cit, "ssl", true) || Map.get(cit, :ssl, true)}
                                        class="text-emerald-400"
                                      >· HTTPS</span>
                                      <span class="text-zinc-600">· {to_string(
                                        cit["authority_category"] || cit[:authority_category] ||
                                          "general"
                                      )}</span>
                                    </div>
                                  </div>
                                </div>

                                <div class="flex items-center gap-1.5 shrink-0">
                                  <span class="px-1.5 py-0.5 rounded bg-white/5 text-[9px] font-mono text-zinc-300 border border-white/10">
                                    {citation_relevance_percent(cit)}% Rel
                                  </span>
                                  <span
                                    :if={
                                      (cit["corroboration_count"] || cit[:corroboration_count] || 0) >
                                        0
                                    }
                                    class="px-1.5 py-0.5 rounded bg-violet-500/10 text-violet-300 text-[9px] font-mono border border-violet-500/20"
                                  >
                                    {cit["corroboration_count"] || cit[:corroboration_count]} edges
                                  </span>
                                </div>
                              </div>

                              <!-- Trust Meter Bar -->
                              <div class="flex items-center justify-between gap-3 pt-1 border-t border-white/[0.03]">
                                <div class="flex items-center gap-2 flex-1">
                                  <div class="h-1.5 flex-1 max-w-[120px] bg-zinc-800 rounded-full overflow-hidden">
                                    <div
                                      class={[
                                        "h-full rounded-full",
                                        citation_meter_color(citation_trust_percent(cit))
                                      ]}
                                      style={"width: #{citation_trust_percent(cit)}%;"}
                                    >
                                    </div>
                                  </div>
                                  <span class="font-mono text-[9px] text-zinc-400">{citation_trust_percent(
                                    cit
                                  )}% Trust</span>
                                </div>
                                <%= if cit["snippet"] do %>
                                  <p class="text-[10px] font-mono text-zinc-500 truncate max-w-[240px]">
                                    {cit["snippet"]}
                                  </p>
                                <% end %>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% else %>
                <div class="rounded-xl border border-dashed border-zinc-800 p-8 text-center text-zinc-500 font-mono text-xs">
                  <.icon
                    name="hero-document-duplicate"
                    class="w-8 h-8 mx-auto mb-2 opacity-30 text-zinc-400"
                  />
                  <p>No artifacts produced yet for this step.</p>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </aside>
    </div>
    """
  end

  # ============================================================================
  # EXECUTION CONTROL TOOLBAR
  # ============================================================================

  attr :run, :any, required: true
  attr :workflow, :any, required: true
  attr :on_pause, :string, default: "pause_run"
  attr :on_resume, :string, default: "resume_run"
  attr :on_cancel, :string, default: "cancel_run"
  attr :on_launch, :string, default: "launch_workflow"

  def execution_toolbar(assigns) do
    ~H"""
    <section
      id="workflow-execution-toolbar"
      class="flex flex-wrap items-center justify-between gap-4 p-4 rounded-2xl border border-white/10 bg-[#0d1218]/90 backdrop-blur-xl shadow-2xl"
    >
      <!-- Left: Workflow Info & Status -->
      <div class="flex items-center gap-4 min-w-0">
        <.step_progress_ring status={@run.status} progress={@run.progress} />
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <h2 class="text-base font-bold text-white tracking-tight truncate">
              {@workflow.name}
            </h2>
            <span class="font-mono text-xs text-zinc-500 truncate max-w-[120px]">
              #{String.slice(to_string(@run.id), 0, 8)}
            </span>
          </div>
          <div class="flex items-center gap-3 font-mono text-[11px] text-zinc-400 mt-0.5">
            <span class="flex items-center gap-1.5">
              <span class={["w-2 h-2 rounded-full", status_dot_class(@run.status)]}></span>
              <strong class="uppercase text-white">{@run.status}</strong>
            </span>
            <span class="text-zinc-600">·</span>
            <span>{@run.progress}% completed</span>
            <span class="text-zinc-600">·</span>
            <span class="tabular-nums">{format_duration(@run.duration_ms)}</span>
          </div>
        </div>
      </div>

      <!-- Right: Global Actions -->
      <div id="workflow-run-actions" class="flex items-center gap-2 shrink-0">
        <!-- Pause -->
        <%= if @run.status == "running" do %>
          <button
            type="button"
            id="toolbar-pause-btn"
            phx-click={@on_pause}
            phx-value-id={@run.id}
            class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl border border-amber-500/30 bg-amber-500/10 text-amber-300 font-mono text-xs font-semibold hover:bg-amber-500/20 transition-all shadow-[0_0_12px_rgba(245,158,11,0.15)]"
          >
            <.icon name="hero-pause" class="w-4 h-4" />
            <span>Pause</span>
          </button>
        <% end %>

        <!-- Resume -->
        <%= if @run.status == "paused" do %>
          <button
            type="button"
            id="toolbar-resume-btn"
            phx-click={@on_resume}
            phx-value-id={@run.id}
            class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl border border-emerald-500/30 bg-emerald-500/10 text-emerald-300 font-mono text-xs font-semibold hover:bg-emerald-500/20 transition-all shadow-[0_0_12px_rgba(16,185,129,0.15)]"
          >
            <.icon name="hero-play" class="w-4 h-4" />
            <span>Resume</span>
          </button>
        <% end %>

        <!-- Cancel -->
        <%= if @run.status in ["running", "paused", "pending"] do %>
          <button
            type="button"
            id="toolbar-cancel-btn"
            phx-click={@on_cancel}
            phx-value-id={@run.id}
            data-confirm="Are you sure you want to cancel this workflow run?"
            class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl border border-rose-500/30 bg-rose-500/10 text-rose-300 font-mono text-xs font-semibold hover:bg-rose-500/20 transition-all"
          >
            <.icon name="hero-stop" class="w-4 h-4" />
            <span>Cancel</span>
          </button>
        <% end %>

        <!-- Re-run / Launch -->
        <%= if @run.status in ["completed", "failed", "cancelled"] do %>
          <button
            type="button"
            id="toolbar-rerun-btn"
            phx-click={@on_launch}
            phx-value-id={@workflow.id}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 text-white font-mono text-xs font-bold hover:brightness-110 shadow-lg shadow-cyan-500/20 transition-all"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            <span>Run Again</span>
          </button>
        <% end %>
      </div>
    </section>
    """
  end

  # ============================================================================
  # WORKFLOW CARD (GALLERY VIEW)
  # ============================================================================

  attr :workflow, :any, required: true
  attr :active_run, :any, default: nil
  attr :on_launch, :string, default: "launch_workflow"
  attr :on_delete, :string, default: "delete_workflow"

  def workflow_card(assigns) do
    steps = assigns.workflow.steps || []
    step_count = length(steps)

    assigns =
      assigns
      |> assign(:steps, steps)
      |> assign(:step_count, step_count)

    ~H"""
    <div
      id={"workflow-card-#{@workflow.id}"}
      class="group rounded-2xl border border-[#21262d] bg-[#0e131b]/90 p-5 hover:border-cyan-500/40 hover:shadow-[0_0_24px_rgba(34,211,238,0.15)] transition-all flex flex-col justify-between"
    >
      <div>
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <.link
              navigate={~p"/workflows/#{@workflow.id}"}
              class="text-base font-bold text-white hover:text-cyan-300 transition-colors truncate block"
            >
              {@workflow.name}
            </.link>
            <p class="font-mono text-xs text-zinc-400 mt-0.5">
              {@workflow.slug}
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <%= if @active_run do %>
              <span class="flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-cyan-500/10 text-cyan-300 border border-cyan-500/30 text-[10px] font-mono font-bold">
                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 animate-pulse"></span> RUNNING
              </span>
            <% end %>
          </div>
        </div>

        <p class="text-xs text-zinc-300 mt-3 line-clamp-2 leading-relaxed">
          {@workflow.description || "No description provided."}
        </p>

        <!-- Step Pipeline Preview Pills -->
        <div class="mt-4 pt-3 border-t border-white/5 space-y-2">
          <p class="font-mono text-[10px] text-zinc-500 uppercase tracking-wider">
            Pipeline Steps ({@step_count})
          </p>
          <div class="flex flex-wrap gap-1.5">
            <%= for step <- Enum.take(@steps, 4) do %>
              <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-white/5 text-[10px] font-mono text-zinc-300 border border-white/5">
                <.icon
                  name={step_kind_icon(Map.get(step, "kind") || Map.get(step, :kind))}
                  class="w-3 h-3 text-cyan-400"
                />
                {Map.get(step, "title") || Map.get(step, :title) || Map.get(step, "key")}
              </span>
            <% end %>
            <%= if @step_count > 4 do %>
              <span class="px-1.5 py-0.5 rounded bg-white/5 text-[10px] font-mono text-zinc-500">
                +{@step_count - 4} more
              </span>
            <% end %>
          </div>
        </div>

        <!-- Tags -->
        <%= if @workflow.tags && length(@workflow.tags) > 0 do %>
          <div class="mt-3 flex flex-wrap gap-1">
            <%= for tag <- @workflow.tags do %>
              <span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-zinc-800/60 text-zinc-400">
                #{tag}
              </span>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Card Action Footer -->
      <div class="mt-5 pt-3 border-t border-white/5 flex items-center justify-between gap-3">
        <.link
          navigate={~p"/workflows/#{@workflow.id}"}
          class="text-xs font-mono text-zinc-400 hover:text-white transition-colors"
        >
          View Details →
        </.link>

        <button
          type="button"
          id={"btn-launch-#{@workflow.id}"}
          phx-click={@on_launch}
          phx-value-id={@workflow.id}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 text-white font-mono text-xs font-bold hover:brightness-110 shadow-md shadow-cyan-500/20 transition-all"
        >
          <.icon name="hero-play" class="w-3.5 h-3.5" />
          <span>Launch</span>
        </button>
      </div>
    </div>
    """
  end

  # ============================================================================
  # DAG COORDINATE CALCULATION & MATHEMATICS
  # ============================================================================

  @doc """
  Lays out DAG steps into horizontally layered columns with centered vertical offsets.
  Computes cubic Bézier paths with horizontal control tangents and active flow state.
  """
  def layout_workflow_dag(steps, step_states, current_step_key, run_status \\ nil) do
    steps = steps || []
    step_states = step_states || %{}

    # 1. Compute layer index using topological sorting / longest path
    levels = compute_dag_levels(steps)
    max_level = if map_size(levels) == 0, do: 0, else: levels |> Map.values() |> Enum.max()

    # 2. Group steps by layer
    step_map = Map.new(steps, fn s -> {step_key(s), s} end)

    layers =
      for lvl <- 0..max_level do
        levels
        |> Enum.filter(fn {_, l} -> l == lvl end)
        |> Enum.map(fn {k, _} -> Map.fetch!(step_map, k) end)
      end

    # 3. Dimensions
    node_w = @node_width
    node_h = @node_height
    gap_x = @gap_x
    gap_y = @gap_y
    pad_x = @pad_x
    pad_y = @pad_y

    max_nodes_in_layer = layers |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    max_height = max_nodes_in_layer * node_h + (max_nodes_in_layer - 1) * gap_y

    positioned_nodes =
      layers
      |> Enum.with_index()
      |> Enum.flat_map(fn {layer_steps, col_idx} ->
        col_count = length(layer_steps)
        offset_y = div(max(0, max_height - (col_count * node_h + (col_count - 1) * gap_y)), 2)

        layer_steps
        |> Enum.with_index()
        |> Enum.map(fn {step, row_idx} ->
          k = step_key(step)
          state_info = Map.get(step_states, k, %{})
          status = Map.get(state_info, "status", "pending")
          output = if is_map(state_info["output"]), do: state_info["output"], else: %{}
          dur_ms = Map.get(state_info, "duration_ms", Map.get(output, "duration_ms", 0))

          progress =
            cond do
              status == "completed" -> 100
              status == "running" -> Map.get(state_info, "progress", 50)
              true -> 0
            end

          meta = canonical_meta(status)

          model_config = Map.get(step, "model_config") || Map.get(step, :model_config) || %{}
          effort = Map.get(model_config, "reasoning_effort", "standard")

          %{
            key: k,
            title: Map.get(step, "title") || Map.get(step, :title) || k,
            kind: Map.get(step, "kind") || Map.get(step, :kind) || "task",
            status: status,
            meta: meta,
            progress: progress,
            depends_on: step_deps(step),
            x: pad_x + col_idx * (node_w + gap_x),
            y: pad_y + offset_y + row_idx * (node_h + gap_y),
            width: node_w,
            height: node_h,
            model_label: "#{effort}",
            duration_label: if(dur_ms > 0, do: "#{dur_ms}ms", else: "—")
          }
        end)
      end)

    node_dict = Map.new(positioned_nodes, &{&1.key, &1})

    # 4. Compute Bézier edges
    edges =
      positioned_nodes
      |> Enum.flat_map(fn target ->
        target.depends_on
        |> Enum.map(fn source_key ->
          case Map.get(node_dict, source_key) do
            nil ->
              nil

            source ->
              bezier = bezier_edge(source, target)

              active? =
                to_string(run_status) != "cancelled" and
                  ((source.status in ["running", "completed"] and target.status == "running") or
                     (target.status == "running" and target.key == current_step_key))

              edge_status =
                cond do
                  target.status == "failed" -> "failed"
                  target.status == "running" -> "running"
                  target.status == "completed" -> "completed"
                  target.status == "paused" -> "paused"
                  true -> "pending"
                end

              %{
                id: "#{source.key}--#{target.key}",
                from: source.key,
                to: target.key,
                d: bezier.d,
                active?: active?,
                status: edge_status
              }
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    total_width = max(800, pad_x + (max_level + 1) * (node_w + gap_x) + pad_x)
    total_height = max(500, pad_y + max_height + pad_y)

    %{
      nodes: positioned_nodes,
      edges: edges,
      width: total_width,
      height: total_height
    }
  end

  @doc """
  Calculates smooth parametric cubic Bézier curve with horizontal port tangents:
  `M x1 y1 C cx1 cy1, cx2 cy2, x2 y2`
  """
  def bezier_edge(source, target) do
    x1 = source.x + source.width
    y1 = source.y + div(source.height, 2)
    x2 = target.x
    y2 = target.y + div(target.height, 2)

    dx = max(abs(x2 - x1) * 0.5, 45.0)
    cx1 = round(x1 + dx)
    cy1 = y1
    cx2 = round(x2 - dx)
    cy2 = y2

    d = "M #{x1} #{y1} C #{cx1} #{cy1}, #{cx2} #{cy2}, #{x2} #{y2}"

    %{
      x1: x1,
      y1: y1,
      cx1: cx1,
      cy1: cy1,
      cx2: cx2,
      cy2: cy2,
      x2: x2,
      y2: y2,
      d: d
    }
  end

  @doc """
  Calculates stroke-dashoffset for a given progress and circumference.
  """
  def calc_progress_dashoffset(progress, circumference \\ @circle_circumference) do
    p = max(0, min(100, progress || 0))
    circumference * (1.0 - p / 100.0)
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  def compute_dag_levels(steps) do
    step_map = Map.new(steps, fn s -> {step_key(s), s} end)

    case WorkflowDag.topological_sort(steps) do
      {:ok, sorted_keys} ->
        Enum.reduce(sorted_keys, %{}, fn key, acc ->
          step = Map.fetch!(step_map, key)
          deps = step_deps(step)

          level =
            if deps == [] do
              0
            else
              max_dep_level = deps |> Enum.map(&Map.get(acc, &1, 0)) |> Enum.max()
              max_dep_level + 1
            end

          Map.put(acc, key, level)
        end)

      _error ->
        # Fallback to linear assignment if cycle or malformed
        steps
        |> Enum.with_index()
        |> Map.new(fn {s, idx} -> {step_key(s), idx} end)
    end
  end

  def canonical_meta("running") do
    %{
      border: "border-cyan-400 ring-2 ring-cyan-400/60",
      bg: "bg-[#081524]/95",
      dot: "bg-cyan-400 animate-ping",
      halo: "shadow-[0_0_24px_rgba(34,211,238,0.45)]"
    }
  end

  def canonical_meta("completed") do
    %{
      border: "border-emerald-400/70",
      bg: "bg-[#091a13]/95",
      dot: "bg-emerald-400",
      halo: "shadow-[0_0_16px_rgba(52,211,153,0.30)]"
    }
  end

  def canonical_meta("failed") do
    %{
      border: "border-rose-500/80 ring-1 ring-rose-500/50",
      bg: "bg-[#240c14]/95",
      dot: "bg-rose-500",
      halo: "shadow-[0_0_22px_rgba(244,63,94,0.40)]"
    }
  end

  def canonical_meta("paused") do
    %{
      border: "border-amber-400/70",
      bg: "bg-[#1c1409]/95",
      dot: "bg-amber-400",
      halo: "shadow-[0_0_16px_rgba(251,191,36,0.30)]"
    }
  end

  def canonical_meta("cancelled") do
    %{
      border: "border-zinc-600",
      bg: "bg-[#10141a]/95",
      dot: "bg-zinc-500",
      halo: "shadow-none"
    }
  end

  def canonical_meta(_pending) do
    %{
      border: "border-[#26313d]",
      bg: "bg-[#0d1218]/90",
      dot: "bg-zinc-600",
      halo: "shadow-none"
    }
  end

  def status_icon_name("running"), do: "hero-arrow-path"
  def status_icon_name("completed"), do: "hero-check"
  def status_icon_name("failed"), do: "hero-exclamation-triangle"
  def status_icon_name("paused"), do: "hero-pause"
  def status_icon_name("cancelled"), do: "hero-x-mark"
  def status_icon_name(_), do: "hero-clock"

  def status_icon_color("running"), do: "text-cyan-400 animate-spin"
  def status_icon_color("completed"), do: "text-emerald-400"
  def status_icon_color("failed"), do: "text-rose-400"
  def status_icon_color("paused"), do: "text-amber-400"
  def status_icon_color("cancelled"), do: "text-zinc-400"
  def status_icon_color(_), do: "text-zinc-500"

  def status_badge_class("running"), do: "bg-cyan-500/10 text-cyan-300 border border-cyan-500/30"

  def status_badge_class("completed"),
    do: "bg-emerald-500/10 text-emerald-300 border border-emerald-500/30"

  def status_badge_class("failed"), do: "bg-rose-500/10 text-rose-300 border border-rose-500/30"

  def status_badge_class("paused"),
    do: "bg-amber-500/10 text-amber-300 border border-amber-500/30"

  def status_badge_class("cancelled"),
    do: "bg-zinc-800 text-zinc-400 border border-zinc-700"

  def status_badge_class(_), do: "bg-zinc-800 text-zinc-400 border border-zinc-700"

  def status_dot_class("running"), do: "bg-cyan-400 animate-pulse"
  def status_dot_class("completed"), do: "bg-emerald-400"
  def status_dot_class("failed"), do: "bg-rose-400"
  def status_dot_class("paused"), do: "bg-amber-400"
  def status_dot_class("cancelled"), do: "bg-zinc-500"
  def status_dot_class(_), do: "bg-zinc-500"

  def step_kind_icon("deep_research"), do: "hero-magnifying-glass"
  def step_kind_icon("swarm_code_gen"), do: "hero-code-bracket"
  def step_kind_icon("test_verification"), do: "hero-beaker"
  def step_kind_icon("security_audit"), do: "hero-shield-check"
  def step_kind_icon("git_commit"), do: "hero-arrow-up-tray"
  def step_kind_icon(_), do: "hero-cpu-chip"

  def step_key(s), do: to_string(Map.get(s, "key") || Map.get(s, :key) || "")

  def step_deps(s) do
    deps = Map.get(s, "depends_on") || Map.get(s, :depends_on) || []
    Enum.map(deps, &to_string/1)
  end

  def format_duration(nil), do: "0s"
  def format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  def format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: "#{Float.round(ms / 1000.0, 1)}s"

  def format_duration(ms) when is_integer(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{secs}s"
  end

  def format_duration(_), do: "—"

  defp extract_log_content(output, state) do
    state = if is_map(state), do: state, else: %{}

    cond do
      is_binary(Map.get(state, "log")) -> Map.get(state, "log")
      is_binary(output) -> output
      is_map(output) and is_binary(Map.get(output, "output")) -> Map.get(output, "output")
      is_map(output) and is_binary(Map.get(output, "summary")) -> Map.get(output, "summary")
      is_map(output) and is_binary(Map.get(output, "report")) -> Map.get(output, "report")
      is_map(output) and map_size(output) > 0 -> Jason.encode!(output, pretty: true)
      true -> ""
    end
  rescue
    _ -> ""
  end

  defp extract_thinking_traces(output, state) do
    state = if is_map(state), do: state, else: %{}
    output_map = if is_map(output), do: output, else: %{}

    cond do
      is_binary(Map.get(state, "thinking")) -> Map.get(state, "thinking")
      is_binary(Map.get(state, "thoughts")) -> Map.get(state, "thoughts")
      is_binary(Map.get(output_map, "thoughts")) -> Map.get(output_map, "thoughts")
      is_binary(Map.get(output_map, "reasoning")) -> Map.get(output_map, "reasoning")
      true -> ""
    end
  end

  defp extract_step_artifacts(step, output) when is_map(output) do
    kind = to_string(Map.get(step, "kind") || Map.get(step, :kind) || "")
    artifacts = []

    # 1. Swarm Code Gen Patches & Consensus Matrix
    artifacts =
      case Map.get(output, "patches") do
        patches when is_list(patches) and patches != [] ->
          diff_text = format_patches_to_diff(patches)

          [
            %{
              title: "Unified Code Diffs & Swarm Consensus",
              type: "diff",
              icon: "hero-code-bracket",
              content: diff_text,
              citations: nil,
              consensus_matrix: Map.get(output, "consensus_matrix"),
              dynamic_roster: Map.get(output, "dynamic_roster"),
              peer_messages: Map.get(output, "peer_messages"),
              merge_verdict: Map.get(output, "merge_verdict")
            }
            | artifacts
          ]

        _ ->
          artifacts
      end

    # 2. Deep Research Report & Source Graph
    artifacts =
      case Map.get(output, "report") do
        report when is_binary(report) and report != "" ->
          [
            %{
              title: "Deep Research Report & Source Graph",
              type: "report",
              icon: "hero-document-magnifying-glass",
              content: report,
              query: Map.get(output, "query"),
              citations: Map.get(output, "citations") || [],
              source_graph: Map.get(output, "source_graph"),
              conflict_audit: Map.get(output, "conflict_audit"),
              conflicts: Map.get(output, "conflicts") || [],
              recommended_action: Map.get(output, "recommended_action")
            }
            | artifacts
          ]

        _ ->
          artifacts
      end

    # 3. Test Verification Results
    artifacts =
      if kind == "test_verification" and Map.has_key?(output, "verdict") do
        content = """
        Verdict: #{output["verdict"]}
        Total Tests: #{output["total"] || 0}
        Passed: #{output["passed"] || 0}
        Failed: #{output["failed"] || 0}
        Output:
        #{output["output"] || "All tests passed cleanly."}
        """

        [
          %{
            title: "Test Execution Summary",
            type: "test_result",
            icon: "hero-beaker",
            content: String.trim(content),
            citations: nil
          }
          | artifacts
        ]
      else
        artifacts
      end

    # 4. Git Commit
    artifacts =
      case Map.get(output, "commit_sha") || Map.get(output, "commit_hash") do
        sha when is_binary(sha) and sha != "" ->
          [
            %{
              title: "Git Commit: #{String.slice(sha, 0, 8)}",
              type: "git_commit",
              icon: "hero-arrow-up-tray",
              content:
                "Commit SHA: #{sha}\nMessage: #{output["commit_message"] || "Workflow commit"}",
              citations: nil
            }
            | artifacts
          ]

        _ ->
          artifacts
      end

    # 5. Security Audit
    artifacts =
      if kind == "security_audit" and Map.has_key?(output, "verdict") do
        violations = Map.get(output, "violations") || []

        [
          %{
            title: "Security Audit Summary",
            type: "security_audit",
            icon: "hero-shield-check",
            content:
              "Verdict: #{output["verdict"]}\nRisk Score: #{output["risk_score"] || 0}\nViolations: #{length(violations)}",
            citations: nil
          }
          | artifacts
        ]
      else
        artifacts
      end

    Enum.reverse(artifacts)
  end

  defp extract_step_artifacts(_step, _output), do: []

  defp format_patches_to_diff(patches) do
    Enum.map_join(patches, "\n\n", fn patch ->
      file = Map.get(patch, "file", "unknown")
      hunks = Map.get(patch, "hunks", [])

      hunk_text =
        Enum.map_join(hunks, "\n", fn hunk ->
          lines = Map.get(hunk, "lines", [])
          Enum.join(lines, "\n")
        end)

      "--- a/#{file}\n+++ b/#{file}\n#{hunk_text}"
    end)
  end

  # ============================================================================
  # HELPERS FOR RESEARCH ARTIFACTS & CITATIONS
  # ============================================================================

  defp conflict_status_string(conflict) do
    to_string(Map.get(conflict, :status) || Map.get(conflict, "status") || "disputed")
  end

  defp conflict_badge_classes(conflict) do
    case conflict_status_string(conflict) do
      "verified" -> "bg-emerald-500/15 text-emerald-400 border-emerald-500/30"
      "consensus" -> "bg-cyan-500/15 text-cyan-400 border-cyan-500/30"
      _ -> "bg-amber-500/15 text-amber-400 border-amber-500/30"
    end
  end

  defp count_conflicts_by_status(conflicts, target_status) when is_list(conflicts) do
    target_str = to_string(target_status)
    Enum.count(conflicts, fn c -> conflict_status_string(c) == target_str end)
  end

  defp count_conflicts_by_status(_, _), do: 0

  defp citation_trust_percent(cit) do
    val = cit["trust_score"] || cit[:trust_score] || 0.95
    round(val * 100)
  end

  defp citation_relevance_percent(cit) do
    val = cit["relevance_score"] || cit[:relevance_score] || 0.80
    round(val * 100)
  end

  defp citation_meter_color(trust_pct) do
    cond do
      trust_pct >= 85 -> "bg-emerald-400"
      trust_pct >= 70 -> "bg-cyan-400"
      true -> "bg-amber-400"
    end
  end

  defp citation_authority_icon(category) do
    case to_string(category) do
      "academic" -> "hero-academic-cap"
      "official_docs" -> "hero-book-open"
      "gov" -> "hero-building-library"
      "tech_registry" -> "hero-code-bracket-square"
      "community" -> "hero-chat-bubble-left-right"
      _ -> "hero-globe-alt"
    end
  end

  defp get_claim_field(claim, field, default \\ "") do
    Map.get(claim, field) || Map.get(claim, to_string(field)) || default
  end
end
