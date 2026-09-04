defmodule IexCodeWeb.SwarmConsensusComponents do
  @moduledoc """
  Reusable Phoenix v1.8 UI components for Swarm Consensus and Peer Telemetry (Milestone 4).
  Includes Consensus Matrix Heatmap, 5-Dimensional Score Progress Bars,
  Live Peer Message Timeline, Swarm Roster Pills, and Merge Gating Badges.
  """

  use Phoenix.Component
  import IexCodeWeb.CoreComponents
  use Gettext, backend: IexCodeWeb.Gettext

  # ============================================================================
  # 1. CONSENSUS MATRIX HEATMAP
  # ============================================================================

  attr :id, :string, default: "consensus-matrix-heatmap"
  attr :matrix, :any, default: nil
  attr :assessments, :list, default: []
  attr :class, :string, default: ""

  def consensus_heatmap(assigns) do
    assessments =
      cond do
        is_map(assigns.matrix) and is_list(assigns.matrix[:assessments]) ->
          assigns.matrix[:assessments]

        is_map(assigns.matrix) and is_list(assigns.matrix["assessments"]) ->
          assigns.matrix["assessments"]

        is_list(assigns.assessments) and assigns.assessments != [] ->
          assigns.assessments

        true ->
          []
      end

    grid =
      cond do
        is_map(assigns.matrix) and is_list(assigns.matrix[:pairwise_matrix]) ->
          assigns.matrix[:pairwise_matrix]

        is_map(assigns.matrix) and is_list(assigns.matrix["pairwise_matrix"]) ->
          assigns.matrix["pairwise_matrix"]

        assessments != [] ->
          for a <- assessments do
            for b <- assessments do
              IexCode.Swarm.ConsensusMatrix.pairwise_agreement(a, b)
            end
          end

        true ->
          []
      end

    assigns =
      assigns
      |> assign(:assessments, assessments)
      |> assign(:grid, grid)

    ~H"""
    <div
      id={@id}
      class={["overflow-x-auto rounded-xl border border-[#21262d] bg-[#0b0f14] p-4", @class]}
    >
      <div class="flex items-center justify-between border-b border-[#21262d] pb-3 mb-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-table-cells" class="w-4 h-4 text-purple-400" />
          <span class="text-xs font-mono font-bold uppercase tracking-wider text-white">
            Consensus Agreement Heatmap (N &times; N)
          </span>
        </div>
        <span class="text-[10px] font-mono px-2 py-0.5 rounded bg-purple-950/60 border border-purple-800/40 text-purple-300">
          Pairwise Bounds [0.0, 1.0]
        </span>
      </div>

      <%= if @assessments == [] or @grid == [] do %>
        <p class="text-xs font-mono text-zinc-500 italic text-center py-4">
          No consensus matrix assessments recorded for this run.
        </p>
      <% else %>
        <table class="w-full text-center border-collapse">
          <thead>
            <tr>
              <th class="p-2 text-left text-zinc-500 font-mono text-[11px]">Reviewer</th>
              <%= for rev <- @assessments do %>
                <th class="p-2 text-zinc-400 font-mono text-[11px] font-bold">
                  {get_reviewer_id(rev)}
                </th>
              <% end %>
            </tr>
          </thead>
          <tbody>
            <%= for {row_rev, i} <- Enum.with_index(@assessments) do %>
              <tr class="border-t border-[#21262d]/50">
                <td class="p-2 text-left font-mono font-bold text-zinc-300 text-[11px]">
                  {get_reviewer_id(row_rev)}
                </td>
                <%= for {col_rev, j} <- Enum.with_index(@assessments) do %>
                  <% val = get_grid_val(@grid, i, j, row_rev, col_rev) %>
                  <td class="p-2 font-mono">
                    <span
                      id={"#{@id}-cell-#{i}-#{j}"}
                      class={[
                        "px-2.5 py-1 rounded-md text-xs font-bold inline-block min-w-14",
                        heatmap_cell_classes(val)
                      ]}
                    >
                      {Float.round(val * 100, 1)}%
                    </span>
                  </td>
                <% end %>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # 2. 5-DIMENSIONAL SCORE PROGRESS BARS
  # ============================================================================

  attr :id, :string, default: "dimensional-score-bars"
  attr :scores, :any, default: %{}
  attr :class, :string, default: ""

  def dimensional_score_bars(assigns) do
    scores_map = assigns.scores || %{}

    correctness = get_score_pct(scores_map, :correctness, 90)
    security = get_score_pct(scores_map, :security, 88)
    architecture = get_score_pct_multi(scores_map, [:architectural_fit, :architecture], 85)
    maintainability = get_score_pct(scores_map, :maintainability, 82)
    testability = get_score_pct(scores_map, :testability, 88)

    assigns =
      assigns
      |> assign(:correctness, correctness)
      |> assign(:security, security)
      |> assign(:architecture, architecture)
      |> assign(:maintainability, maintainability)
      |> assign(:testability, testability)

    ~H"""
    <div id={@id} class={["p-4 bg-[#11151c] border border-[#21262d] rounded-xl space-y-4", @class]}>
      <div class="flex items-center justify-between border-b border-[#21262d] pb-2">
        <span class="text-xs font-mono font-bold uppercase tracking-wider text-zinc-300 flex items-center gap-2">
          <.icon name="hero-chart-bar" class="w-4 h-4 text-cyan-400" />
          <span>Dimensional Scores</span>
        </span>
        <span class="text-[10px] font-mono text-zinc-500">5 Canonical Axes</span>
      </div>

      <!-- Correctness -->
      <div id="score-bar-correctness" class="space-y-1">
        <div class="flex items-center justify-between text-[11px] font-mono">
          <span class="text-zinc-300 font-semibold">Correctness</span>
          <span class="text-emerald-400 font-bold">{@correctness}%</span>
        </div>
        <div class="w-full bg-[#0d1117] rounded-full h-2 overflow-hidden border border-white/5">
          <div
            id="score-bar-correctness-fill"
            class="bg-emerald-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@correctness}%"}
          >
          </div>
        </div>
      </div>

      <!-- Security -->
      <div id="score-bar-security" class="space-y-1">
        <div class="flex items-center justify-between text-[11px] font-mono">
          <span class="text-zinc-300 font-semibold">Security</span>
          <span class="text-cyan-400 font-bold">{@security}%</span>
        </div>
        <div class="w-full bg-[#0d1117] rounded-full h-2 overflow-hidden border border-white/5">
          <div
            id="score-bar-security-fill"
            class="bg-cyan-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@security}%"}
          >
          </div>
        </div>
      </div>

      <!-- Architecture -->
      <div id="score-bar-architecture" class="space-y-1">
        <div class="flex items-center justify-between text-[11px] font-mono">
          <span class="text-zinc-300 font-semibold">Architecture</span>
          <span class="text-purple-400 font-bold">{@architecture}%</span>
        </div>
        <div class="w-full bg-[#0d1117] rounded-full h-2 overflow-hidden border border-white/5">
          <div
            id="score-bar-architecture-fill"
            class="bg-purple-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@architecture}%"}
          >
          </div>
        </div>
      </div>

      <!-- Maintainability -->
      <div id="score-bar-maintainability" class="space-y-1">
        <div class="flex items-center justify-between text-[11px] font-mono">
          <span class="text-zinc-300 font-semibold">Maintainability</span>
          <span class="text-indigo-400 font-bold">{@maintainability}%</span>
        </div>
        <div class="w-full bg-[#0d1117] rounded-full h-2 overflow-hidden border border-white/5">
          <div
            id="score-bar-maintainability-fill"
            class="bg-indigo-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@maintainability}%"}
          >
          </div>
        </div>
      </div>

      <!-- Testability -->
      <div id="score-bar-testability" class="space-y-1">
        <div class="flex items-center justify-between text-[11px] font-mono">
          <span class="text-zinc-300 font-semibold">Testability</span>
          <span class="text-blue-400 font-bold">{@testability}%</span>
        </div>
        <div class="w-full bg-[#0d1117] rounded-full h-2 overflow-hidden border border-white/5">
          <div
            id="score-bar-testability-fill"
            class="bg-blue-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@testability}%"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # 3. LIVE PEER MESSAGE STREAM TIMELINE
  # ============================================================================

  attr :id, :string, default: "peer-message-stream"
  attr :messages, :list, default: []
  attr :active_role_filter, :any, default: nil
  attr :class, :string, default: ""

  def peer_message_timeline(assigns) do
    raw_messages = assigns.messages || []

    filtered_messages =
      case assigns.active_role_filter do
        nil ->
          raw_messages

        "" ->
          raw_messages

        "all" ->
          raw_messages

        filter ->
          target = to_string(filter) |> String.downcase()

          Enum.filter(raw_messages, fn msg ->
            role = to_string(msg[:role] || msg["role"] || "") |> String.downcase()
            role == target
          end)
      end

    assigns = assign(assigns, :filtered_messages, filtered_messages)

    ~H"""
    <div id={@id} class={["p-4 bg-[#0d1117] border border-[#21262d] rounded-2xl space-y-4", @class]}>
      <div class="flex items-center justify-between border-b border-[#21262d] pb-3">
        <div class="flex items-center gap-2">
          <span class="w-2 h-2 rounded-full bg-cyan-400 animate-pulse"></span>
          <h4 class="text-xs font-mono font-bold uppercase tracking-wider text-white">
            Live Peer Message Stream
          </h4>
        </div>
        <span class="text-[10px] font-mono px-2 py-0.5 rounded-full bg-cyan-950/60 border border-cyan-800/40 text-cyan-300 font-bold">
          {length(@filtered_messages)} Exchanges
        </span>
      </div>

      <%= if @filtered_messages == [] do %>
        <div class="py-8 text-center text-xs font-mono text-zinc-500 italic space-y-2">
          <.icon name="hero-chat-bubble-left-right" class="w-8 h-8 text-zinc-700 mx-auto" />
          <p>Awaiting inter-agent communication pulses...</p>
        </div>
      <% else %>
        <div class="space-y-3 max-h-[460px] overflow-y-auto pr-1">
          <%= for {msg, idx} <- Enum.with_index(@filtered_messages) do %>
            <% role = msg[:role] || msg["role"] || :coder %>
            <% from_agent = msg[:from_agent] || msg["from_agent"] || "agent" %>
            <% to_agent = msg[:to_agent] || msg["to_agent"] || "swarm:all" %>
            <% type = msg[:type] || msg["type"] || :message %>
            <% timestamp = msg[:timestamp] || msg["timestamp"] %>
            <% payload = msg[:payload] || msg["payload"] || %{} %>

            <div
              id={"peer-msg-#{idx}"}
              class="rounded-xl border border-white/5 bg-[#11151c] p-3 space-y-2 text-xs font-mono transition hover:border-white/10"
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <!-- Role Avatar Chip -->
                  <span class={[
                    "px-2 py-0.5 rounded-md text-[10px] font-bold border uppercase tracking-wider",
                    role_avatar_classes(role)
                  ]}>
                    {role}
                  </span>
                  <span class="text-zinc-300 font-semibold">{from_agent}</span>
                  <span class="text-zinc-500">&rarr;</span>
                  <span class="text-zinc-400">{to_agent}</span>
                </div>

                <div class="flex items-center gap-2">
                  <span class="px-1.5 py-0.5 rounded text-[9px] bg-white/5 text-zinc-400 font-mono">
                    {type}
                  </span>
                  <%= if timestamp do %>
                    <span class="text-[9px] text-zinc-500 font-mono">
                      {format_timestamp(timestamp)}
                    </span>
                  <% end %>
                </div>
              </div>

              <%= if map_size(payload) > 0 do %>
                <div class="rounded-lg bg-[#070a0e] border border-white/5 p-2 text-[11px] text-zinc-300 overflow-x-auto">
                  <pre class="whitespace-pre-wrap"><code phx-no-curly-interpolation><%= Jason.encode!(payload, pretty: true) %></code></pre>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # 4. MERGE GATING BADGE
  # ============================================================================

  attr :decision, :any, default: :approved
  attr :class, :string, default: ""

  def merge_gating_badge(assigns) do
    dec =
      case assigns.decision do
        d when d in [:approved, "approved"] -> :approved
        d when d in [:rejected, "rejected"] -> :rejected
        _ -> :revision_required
      end

    assigns = assign(assigns, :dec, dec)

    ~H"""
    <span class={[
      "px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-wider font-mono border",
      gating_badge_classes(@dec),
      @class
    ]}>
      <%= case @dec do %>
        <% :approved -> %>
          <.icon name="hero-check-circle" class="w-3.5 h-3.5 inline mr-1 text-emerald-400" />
          APPROVED (GATED MERGE)
        <% :revision_required -> %>
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5 inline mr-1 text-amber-400" />
          REVISION REQUIRED
        <% :rejected -> %>
          <.icon name="hero-x-circle" class="w-3.5 h-3.5 inline mr-1 text-rose-400" />
          REJECTED (HALTED)
      <% end %>
    </span>
    """
  end

  # ============================================================================
  # 5. SWARM ROSTER PILLS
  # ============================================================================

  attr :roster, :list, default: []
  attr :class, :string, default: ""

  def swarm_roster_pills(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      <%= for agent <- @roster do %>
        <% role = agent[:role] || agent["role"] || :coder %>
        <% name = agent[:display_name] || agent["display_name"] || to_string(role) %>
        <% model = agent[:model_id] || agent["model_id"] %>
        <div class={[
          "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full border text-[10px] font-mono font-medium",
          role_avatar_classes(role)
        ]}>
          <span class="w-1.5 h-1.5 rounded-full bg-current"></span>
          <span class="font-bold">{name}</span>
          <%= if model do %>
            <span class="opacity-70 text-[9px]">({model})</span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # PRIVATE STYLING HELPERS
  # ============================================================================

  defp heatmap_cell_classes(val) when is_number(val) do
    cond do
      val >= 0.80 ->
        "bg-emerald-950 text-emerald-300 border border-emerald-800"

      val >= 0.50 ->
        "bg-amber-950 text-amber-300 border border-amber-800"

      true ->
        "bg-rose-950 text-rose-300 border border-rose-800"
    end
  end

  defp heatmap_cell_classes(_), do: "bg-zinc-900 text-zinc-400 border border-zinc-700"

  defp role_avatar_classes(role) do
    case to_string(role) |> String.downcase() do
      "explorer" ->
        "border-cyan-400 bg-cyan-950/40 text-cyan-300"

      "architect" ->
        "border-violet-400 bg-violet-950/40 text-violet-300"

      "coder" ->
        "border-emerald-400 bg-emerald-950/40 text-emerald-300"

      "auditor" ->
        "border-amber-400 bg-amber-950/40 text-amber-300"

      "security_auditor" ->
        "border-rose-400 bg-rose-950/40 text-rose-300"

      "synthesizer" ->
        "border-purple-400 bg-purple-950/40 text-purple-300"

      "verifier" ->
        "border-blue-400 bg-blue-950/40 text-blue-300"

      _ ->
        "border-zinc-500 bg-zinc-900 text-zinc-300"
    end
  end

  defp gating_badge_classes(:approved) do
    "bg-emerald-950/80 text-emerald-300 border-emerald-800/60 shadow-[0_0_8px_rgba(16,185,129,0.2)]"
  end

  defp gating_badge_classes(:revision_required) do
    "bg-amber-950/80 text-amber-300 border-amber-800/60 shadow-[0_0_8px_rgba(245,158,11,0.2)]"
  end

  defp gating_badge_classes(:rejected) do
    "bg-rose-950/80 text-rose-300 border-rose-800/60 shadow-[0_0_8px_rgba(244,63,94,0.2)]"
  end

  defp get_reviewer_id(%{reviewer_id: id}), do: id
  defp get_reviewer_id(%{"reviewer_id" => id}), do: id

  defp get_reviewer_id(map) when is_map(map),
    do: Map.get(map, :id) || Map.get(map, "id") || "reviewer"

  defp get_reviewer_id(_), do: "reviewer"

  defp get_grid_val(grid, i, j, row_rev, col_rev) when is_list(grid) do
    case Enum.at(grid, i) do
      row when is_list(row) ->
        case Enum.at(row, j) do
          val when is_number(val) -> val * 1.0
          _ -> IexCode.Swarm.ConsensusMatrix.pairwise_agreement(row_rev, col_rev)
        end

      _ ->
        IexCode.Swarm.ConsensusMatrix.pairwise_agreement(row_rev, col_rev)
    end
  end

  defp get_grid_val(_, _, _, row_rev, col_rev) do
    IexCode.Swarm.ConsensusMatrix.pairwise_agreement(row_rev, col_rev)
  end

  defp get_score_pct(map, key, default) when is_map(map) do
    val = Map.get(map, key) || Map.get(map, to_string(key))

    case val do
      n when is_number(n) ->
        if n <= 1.0, do: trunc(n * 100), else: trunc(n)

      _ ->
        default
    end
  end

  defp get_score_pct(_, _, default), do: default

  defp get_score_pct_multi(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn k ->
      val = Map.get(map, k) || Map.get(map, to_string(k))

      case val do
        n when is_number(n) ->
          if n <= 1.0, do: trunc(n * 100), else: trunc(n)

        _ ->
          nil
      end
    end)
  end

  defp get_score_pct_multi(_, _, default), do: default

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso
    end
  end

  defp format_timestamp(_), do: ""
end
