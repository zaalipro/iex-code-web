defmodule IexCodeWeb.RunComponents do
  @moduledoc """
  UI primitives for the durable asynchronous run control plane.

  The component deliberately renders persisted run projections rather than
  process-local state. A LiveView can therefore reconnect and replay the same
  ordered journal after the browser or application shell has been closed.
  """

  use IexCodeWeb, :html

  alias IexCodeWeb.DagComponents

  attr :mode, :string, required: true

  def mission_control_tabs(assigns) do
    ~H"""
    <div role="tablist" aria-label="Mission Control modes" class="sf-mission-control-tabs">
      <button
        :for={mode <- ~w(overview topology execution journal)}
        id={"mission-control-mode-#{mode}"}
        type="button"
        role="tab"
        phx-click="switch_mission_control_mode"
        phx-value-mode={mode}
        aria-selected={to_string(@mode == mode)}
        aria-controls={"mission-control-panel-#{mode}"}
        tabindex="0"
        class={[
          "sf-mission-control-tab sf-control min-h-11 px-3 text-sm font-semibold",
          @mode == mode && "is-active"
        ]}
      >
        <span class="sf-mission-control-tab-marker" aria-hidden="true">{if @mode == mode,
          do: "●",
          else: "○"}</span>
        {String.capitalize(mode)}
      </button>
    </div>
    """
  end

  attr :selected_run, :any, default: nil
  attr :phase, :string, default: nil

  def mission_control_hero(assigns) do
    progress =
      case assigns.selected_run do
        %{progress: value} when is_integer(value) -> min(max(value, 0), 100)
        _ -> 0
      end

    run_status = if assigns.selected_run, do: assigns.selected_run.status, else: "none"

    assigns =
      assigns
      |> assign(:progress, progress)
      |> assign(:run_status, run_status)

    ~H"""
    <section
      id="mission-control-hero"
      class="sf-mission-control-hero"
      aria-labelledby="mission-control-hero-title"
    >
      <div>
        <p class="sf-metadata">Instrument 01 · Active Mission</p>
        <h2 id="mission-control-hero-title" class="text-xl font-semibold">Mission Control</h2>
        <p id="mission-control-phase" class="mt-1 text-sm text-[var(--sf-text-secondary)]">
          <%= if @selected_run do %>
            {if @phase, do: @phase, else: "Status: #{@selected_run.status}"}
          <% else %>
            No active run
          <% end %>
        </p>
        <p :if={@selected_run} class="sf-metadata mt-2">
          Status · {String.capitalize(@selected_run.status)}
        </p>
      </div>
      <div :if={@selected_run} class="sf-mission-control-progress">
        <div class="mb-2 flex items-center justify-between gap-3">
          <span class="sf-metadata">Persisted mission progress</span>
          <span
            id="mission-control-progress-text"
            class="font-mono text-sm font-semibold text-[var(--sf-text-primary)]"
          >{@progress}%</span>
        </div>
        <div
          id="mission-control-waveform"
          aria-hidden="true"
          data-run-status={@run_status}
          data-progress={@progress}
          class="sf-mission-control-waveform"
        >
          <span
            :for={segment <- 1..12}
            data-active={to_string(segment * 100 <= @progress * 12)}
          ></span>
        </div>
        <div
          role="progressbar"
          aria-label="Mission progress"
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@progress}
          class="mt-2 h-1.5 overflow-hidden bg-[var(--sf-hairline)]"
        >
          <div class="h-full bg-[var(--sf-live-mark)]" style={"width: #{@progress}%"}></div>
        </div>
      </div>
    </section>
    """
  end

  attr :selected_run, :any, default: nil
  attr :run_counts, :map, default: %{}
  attr :workspace_locks, :list, default: []
  attr :stats, :map, default: %{}

  def mission_control_signal_panel(assigns) do
    signal =
      mission_control_signal(
        assigns.selected_run,
        assigns.run_counts,
        assigns.workspace_locks,
        assigns.stats
      )

    assigns = assign(assigns, :signal, signal)

    ~H"""
    <section id="mission-control-signal-panel" aria-labelledby="mission-control-signal-title">
      <p class="sf-metadata">Decision surface</p>
      <h3 id="mission-control-signal-title" class="mt-1 text-base font-semibold">What needs you</h3>
      <p
        id="mission-control-signal"
        role="status"
        aria-live="polite"
        class="mt-3 text-sm leading-6 text-[var(--sf-text-secondary)]"
      >
        {@signal}
      </p>
    </section>
    """
  end

  defp mission_control_signal(selected_run, run_counts, locks, stats) do
    approvals = Map.get(run_counts || %{}, :approvals, 0)

    selected_lock =
      selected_run_workspace_lock(
        selected_run,
        locks,
        run_workspace_lock_state(selected_run, locks)
      )

    cond do
      approvals > 0 ->
        if approvals == 1,
          do: "Session has 1 pending approval",
          else: "Session has #{approvals} pending approvals"

      selected_lock && lock_value(selected_lock, :status) == "held" ->
        "Selected run holds the workspace lock"

      selected_lock && lock_value(selected_lock, :status) == "waiting" ->
        "Selected run is waiting for workspace access"

      selected_run && selected_run.status == "failed" ->
        "Selected run failed"

      selected_run && selected_run.status == "interrupted" ->
        "Selected run was interrupted"

      not Map.get(stats || %{}, :online, false) ->
        "Dispatcher offline"

      true ->
        "No operator decision required"
    end
  end

  attr :runs, :list, required: true
  attr :run_count, :integer, default: 0
  attr :run_counts, :map, default: %{active: 0, queued: 0, attention: 0, approvals: 0}
  attr :selected_run, :any, default: nil
  attr :steps, :list, default: []
  attr :approvals, :list, default: []
  attr :artifacts, :list, default: []
  attr :controls, :list, default: []
  attr :run_manifest, :map, default: %{}
  attr :events, :any, required: true
  attr :stats, :map, default: %{}
  attr :workspace_locks, :list, default: []
  attr :agents, :any, default: []
  attr :agent_count, :integer, default: 0

  attr :fleet_summary, :map,
    default: %{active: 0, paused: 0, attention: 0, recovering: 0, tokens: 0}

  attr :fleet_loading, :boolean, default: false
  attr :agent_guidance, :map, default: %{}
  attr :agent_receipts, :map, default: %{}
  attr :dag_projection, :map, default: nil
  attr :mode, :string, default: "overview"
  attr :phase, :string, default: nil
  slot :interactive_execution

  def run_control_plane(assigns) do
    active_workspace_locks =
      Enum.filter(assigns.workspace_locks, &(lock_value(&1, :status) in ["held", "waiting"]))

    held_workspace_locks =
      Enum.filter(active_workspace_locks, &(lock_value(&1, :status) == "held"))

    waiting_workspace_locks =
      Enum.filter(active_workspace_locks, &(lock_value(&1, :status) == "waiting"))

    selected_lock_state = run_workspace_lock_state(assigns.selected_run, active_workspace_locks)

    selected_workspace_lock =
      selected_run_workspace_lock(
        assigns.selected_run,
        active_workspace_locks,
        selected_lock_state
      )

    workspace_lock_state =
      cond do
        selected_lock_state in ["held", "waiting"] -> selected_lock_state
        held_workspace_locks != [] -> "held"
        waiting_workspace_locks != [] -> "waiting"
        true -> "free"
      end

    assigns =
      assigns
      |> assign(:steering_form, to_form(%{"steering" => ""}))
      |> assign(:active_workspace_locks, active_workspace_locks)
      |> assign(:held_workspace_locks, held_workspace_locks)
      |> assign(:waiting_workspace_locks, waiting_workspace_locks)
      |> assign(:selected_lock_state, selected_lock_state)
      |> assign(:selected_workspace_lock, selected_workspace_lock)
      |> assign(:workspace_lock_state, workspace_lock_state)

    ~H"""
    <section id="async-run-control" aria-labelledby="async-run-heading" class="space-y-4">
      <.mission_control_hero selected_run={@selected_run} phase={@phase} />

      <section
        id="mission-control-panel-overview"
        role="tabpanel"
        aria-labelledby="mission-control-mode-overview"
        hidden={@mode != "overview"}
        class="sf-mission-control-panel"
      >
        <details open class="sf-disclosure">
          <summary>Mission status and workspace safety</summary>
          <div class="space-y-4 p-4">
            <div class="flex flex-col gap-4 border-b border-[var(--sf-hairline)] pb-4 lg:flex-row lg:items-end lg:justify-between">
              <div class="max-w-2xl">
                <p class="sf-metadata">Mission Control · Durable execution plane</p>
                <h2 id="async-run-heading" class="mt-2 text-xl font-semibold tracking-tight">
                  Work continues after you leave.
                </h2>
                <p class="mt-2 text-sm leading-6 text-[var(--sf-text-secondary)]">
                  Run transitions and journal events are persisted before broadcast and replay after reconnect.
                </p>
              </div>
              <div
                id="async-dispatcher-status"
                role="status"
                class="sf-control min-h-11 px-3 font-mono text-xs"
              >
                <%= if Map.get(@stats, :online, false) do %>
                  Dispatcher online · {Map.get(@stats, :capacity, 0)} slots ready
                <% else %>
                  Dispatcher offline · Run controls are unavailable
                <% end %>
              </div>
            </div>

            <section
              id="workspace-lock-overview"
              aria-labelledby="workspace-lock-heading"
              aria-live="polite"
              aria-atomic="true"
              data-lock-state={@workspace_lock_state}
              class="border border-[var(--sf-hairline)] bg-[var(--sf-instrument-raised)]"
            >
              <div class="flex flex-col gap-3 p-4 md:flex-row md:items-center md:justify-between">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-baseline gap-2">
                    <h3 id="workspace-lock-heading" class="text-sm font-semibold">
                      Workspace access
                    </h3>
                    <span id="workspace-lock-summary" class="sf-metadata">
                      {workspace_lock_summary(
                        @workspace_lock_state,
                        @selected_lock_state,
                        selected_or_first(@selected_workspace_lock, @held_workspace_locks),
                        selected_or_first(@selected_workspace_lock, @waiting_workspace_locks)
                      )}
                    </span>
                  </div>
                  <p
                    id="workspace-lock-context"
                    class="mt-1 truncate text-xs text-[var(--sf-text-secondary)]"
                  >
                    {workspace_lock_context(
                      @workspace_lock_state,
                      @selected_lock_state,
                      selected_or_first(@selected_workspace_lock, @held_workspace_locks),
                      selected_or_first(@selected_workspace_lock, @waiting_workspace_locks)
                    )}
                  </p>
                </div>
                <div class="flex flex-wrap items-center gap-3 font-mono text-xs">
                  <span id="workspace-lock-held-count">
                    <strong>{length(@held_workspace_locks)}</strong> held resources
                  </span>
                  <span id="workspace-lock-waiting-count">
                    <strong>{length(@waiting_workspace_locks)}</strong> waiting resources
                  </span>
                  <details
                    :if={@active_workspace_locks != []}
                    id="workspace-lock-details"
                    class="relative"
                  >
                    <summary class="sf-control min-h-11">Lock details</summary>
                    <div class="mt-2 grid max-h-80 overflow-y-auto border border-[var(--sf-hairline)] md:grid-cols-2">
                      <article
                        :for={lock <- @active_workspace_locks}
                        id={"workspace-lock-#{lock_value(lock, :id)}"}
                        data-lock-status={lock_value(lock, :status)}
                        class="min-w-0 border-b border-[var(--sf-hairline)] p-3"
                      >
                        <p class="truncate text-xs font-medium" title={workspace_lock_resource(lock)}>
                          {workspace_lock_resource(lock)}
                        </p>
                        <p class="mt-1 truncate text-xs text-[var(--sf-text-secondary)]">
                          Owner · {workspace_lock_owner(lock)}
                        </p>
                        <p class="mt-2 font-mono text-[10px] uppercase">
                          {lock_value(lock, :status)} · {display_value(
                            lock_value(lock, :mode),
                            "access"
                          )} · {workspace_lock_lease(lock)}
                        </p>
                      </article>
                    </div>
                  </details>
                </div>
              </div>
            </section>

            <div
              id="async-run-metrics"
              role="status"
              aria-live="polite"
              aria-atomic="true"
              data-pending-approvals={Map.get(@run_counts, :approvals, 0)}
              class="grid grid-cols-2 border border-[var(--sf-hairline)] md:grid-cols-4"
            >
              <.run_metric label="Active now" value={Map.get(@run_counts, :active, 0)} tone="emerald" />
              <.run_metric label="Queued" value={Map.get(@run_counts, :queued, 0)} tone="blue" />
              <.run_metric
                label="Needs attention"
                value={Map.get(@run_counts, :attention, 0)}
                tone="rose"
              />
              <.run_metric label="Approvals" value={Map.get(@run_counts, :approvals, 0)} tone="amber" />
            </div>
          </div>
        </details>

        <details open class="sf-disclosure mt-4">
          <summary>Run ledger and selected mission</summary>
          <div class="grid min-h-[24rem] border-t border-[var(--sf-hairline)] xl:grid-cols-[21rem_minmax(0,1fr)]">
            <aside
              class="border-b border-[var(--sf-hairline)] xl:border-b-0 xl:border-r"
              aria-label="Run ledger"
            >
              <div class="flex items-center justify-between border-b border-[var(--sf-hairline)] p-4">
                <h3 class="text-sm font-semibold">Run ledger</h3>
                <span class="font-mono text-xs">{@run_count}</span>
              </div>
              <div id="async-run-list" class="max-h-[32rem] overflow-y-auto p-2">
                <div :if={@runs == []} id="async-runs-empty" class="p-8 text-center">
                  <p class="text-sm font-medium">No durable runs yet</p>
                </div>
                <button
                  :for={run <- @runs}
                  id={"async-run-#{run.id}"}
                  type="button"
                  phx-click="select_async_run"
                  phx-value-id={run.id}
                  aria-pressed={to_string(not is_nil(@selected_run) and @selected_run.id == run.id)}
                  data-run-status={run.status}
                  data-workspace-lock-state={run_workspace_lock_state(run, @active_workspace_locks)}
                  class="sf-control mb-1 block min-h-11 w-full px-3 py-3 text-left"
                >
                  <span class="flex items-center justify-between gap-2">
                    <.run_status status={run.status} />
                    <span class="font-mono text-[10px]">#{String.slice(run.id, 0, 7)}</span>
                  </span>
                  <span class="mt-2 line-clamp-2 block text-xs">{run.objective}</span>
                  <span
                    :if={run_workspace_lock_state(run, @active_workspace_locks) != "none"}
                    class="mt-2 block font-mono text-[10px] uppercase"
                  >
                    {if run_workspace_lock_state(run, @active_workspace_locks) == "held",
                      do: "owns workspace",
                      else: "waiting for workspace"}
                  </span>
                  <span
                    role="progressbar"
                    aria-label={"#{run.objective} progress"}
                    aria-valuemin="0"
                    aria-valuemax="100"
                    aria-valuenow={min(max(run.progress || 0, 0), 100)}
                    class="mt-2 block h-1 overflow-hidden bg-[var(--sf-hairline)]"
                  >
                    <span
                      class="block h-full bg-[var(--sf-live-mark)]"
                      style={"width: #{min(max(run.progress || 0, 0), 100)}%"}
                    ></span>
                  </span>
                </button>
              </div>
            </aside>
            <div class="min-w-0 p-4">
              <p
                :if={is_nil(@selected_run)}
                class="py-12 text-center text-sm text-[var(--sf-text-secondary)]"
              >
                No active run
              </p>
              <section
                :if={@selected_run}
                id="async-run-detail"
                data-run-status={@selected_run.status}
                aria-labelledby="async-run-detail-heading"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <.run_status status={@selected_run.status} />
                  <span class="sf-metadata">{@selected_run.mode} · {@selected_run.priority} priority</span>
                </div>
                <h3 id="async-run-detail-heading" class="mt-3 text-lg font-semibold">
                  {@selected_run.objective}
                </h3>
                <p
                  :if={@selected_run.error_message}
                  class="mt-3 border-l-2 border-[var(--sf-live-mark)] pl-3 text-sm"
                >
                  {@selected_run.error_message}
                </p>
              </section>
            </div>
          </div>
        </details>
      </section>

      <section
        id="mission-control-panel-topology"
        role="tabpanel"
        aria-labelledby="mission-control-mode-topology"
        hidden={@mode != "topology"}
        class="sf-mission-control-panel"
      >
        <%= if @selected_run do %>
          <details open class="sf-disclosure">
            <summary>Persisted agent fleet</summary>
            <.agent_fleet
              run={@selected_run}
              agents={@agents}
              agent_count={@agent_count}
              summary={@fleet_summary}
              loading={@fleet_loading}
              guidance={@agent_guidance}
              receipts={@agent_receipts}
            />
          </details>
          <details open class="sf-disclosure mt-4">
            <summary>Execution dependency projection</summary>
            <div
              id="async-run-graph-and-controls"
              data-graph-mode={
                if @selected_run.execution_engine == "dag_v1", do: "dag", else: "legacy"
              }
              class="sf-mission-topology p-4"
            >
              <div
                :if={@selected_run.execution_engine == "dag_v1" and @dag_projection}
                id="async-run-dag-projection"
              >
                <DagComponents.dag_projection projection={@dag_projection} />
              </div>
              <div
                :if={@selected_run.execution_engine == "dag_v1" and is_nil(@dag_projection)}
                id="async-run-dag-unavailable"
                role="status"
                class="border border-dashed border-[var(--sf-hairline)] p-6 text-sm"
              >
                Execution topology unavailable
              </div>
              <div
                :if={@selected_run.execution_engine != "dag_v1"}
                id="async-run-steps"
                class="space-y-2"
              >
                <p :if={@steps == []} class="p-6 text-sm text-[var(--sf-text-secondary)]">
                  Steps appear when the dispatcher claims this run.
                </p>
                <article
                  :for={step <- @steps}
                  id={"async-run-step-#{step.id}"}
                  class="border-b border-[var(--sf-hairline)] py-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-sm font-medium">{step.title}</p>
                    <span class="sf-metadata">{step.status}</span>
                  </div>
                  <p
                    :if={step.depends_on != []}
                    class="mt-1 font-mono text-[10px] text-[var(--sf-text-secondary)]"
                  >
                    waits for {Enum.join(step.depends_on, ", ")}
                  </p>
                  <div
                    role="progressbar"
                    aria-label={"#{step.title} progress"}
                    aria-valuemin="0"
                    aria-valuemax="100"
                    aria-valuenow={min(max(step.progress || 0, 0), 100)}
                    class="mt-2 h-1 bg-[var(--sf-hairline)]"
                  >
                    <div
                      class="h-full bg-[var(--sf-live-mark)]"
                      style={"width: #{min(max(step.progress || 0, 0), 100)}%"}
                    >
                    </div>
                  </div>
                </article>
              </div>
            </div>
          </details>
        <% else %>
          <p class="p-6 text-sm text-[var(--sf-text-secondary)]">No active run</p>
        <% end %>
      </section>

      <section
        id="mission-control-panel-execution"
        role="tabpanel"
        aria-labelledby="mission-control-mode-execution"
        hidden={@mode != "execution"}
        class="sf-mission-control-panel"
      >
        <%= if @selected_run do %>
          <details open class="sf-disclosure">
            <summary>Selected-run controls and budgets</summary>
            <div class="space-y-4 p-4">
              <div id="async-run-actions" class="flex flex-wrap items-center gap-2">
                <button
                  :if={@selected_run.status == "running"}
                  id="pause-async-run"
                  type="button"
                  phx-click="pause_async_run"
                  phx-value-id={@selected_run.id}
                  phx-disable-with="Pausing…"
                  class="sf-control min-h-11 px-3"
                >Pause</button>
                <button
                  :if={@selected_run.status == "draft"}
                  id="start-async-run"
                  type="button"
                  phx-click="start_async_run"
                  phx-value-id={@selected_run.id}
                  phx-disable-with="Starting…"
                  class="sf-control min-h-11 px-3"
                >Start</button>
                <button
                  :if={@selected_run.status == "paused"}
                  id="resume-async-run"
                  type="button"
                  phx-click="resume_async_run"
                  phx-value-id={@selected_run.id}
                  phx-disable-with="Resuming…"
                  class="sf-control min-h-11 px-3"
                >Resume</button>
                <button
                  :if={@selected_run.status in ["draft", "queued", "running", "paused"]}
                  id="cancel-async-run"
                  type="button"
                  phx-click="cancel_async_run"
                  phx-value-id={@selected_run.id}
                  data-confirm={
                    if(@selected_run.status == "draft",
                      do: "Cancel this draft? It will be marked cancelled without starting any work.",
                      else: "Cancel this run? Execution will stop after the request is persisted."
                    )
                  }
                  phx-disable-with="Cancelling…"
                  class="sf-control min-h-11 px-3"
                >Cancel</button>
                <button
                  :if={
                    @selected_run.status in ["failed", "cancelled", "interrupted"] and
                      @selected_run.attempt < @selected_run.max_attempts
                  }
                  id="retry-async-run"
                  type="button"
                  phx-click="retry_async_run"
                  phx-value-id={@selected_run.id}
                  phx-disable-with="Retrying…"
                  class="sf-control min-h-11 px-3"
                >Retry on current workspace</button>
              </div>

              <.form
                :if={@selected_run.execution_engine != "dag_v1"}
                for={@steering_form}
                id="async-run-steering-form"
                phx-submit="steer_async_run"
                class="grid gap-2 md:grid-cols-[minmax(0,1fr)_auto]"
              >
                <.input
                  type="hidden"
                  id="async-run-steering-run-id"
                  name="run_id"
                  value={@selected_run.id}
                />
                <.input
                  field={@steering_form[:steering]}
                  id="async-run-steering-input"
                  name="steering"
                  type="text"
                  label="Steering instruction"
                  disabled={@selected_run.status not in ["running", "paused"]}
                  class="block min-h-11 w-full border border-[var(--sf-hairline)] bg-[var(--sf-code-surface)] px-3 text-sm"
                />
                <button
                  id="async-run-steering-submit"
                  type="submit"
                  disabled={@selected_run.status not in ["running", "paused"]}
                  class="sf-control min-h-11 px-3"
                >Steer</button>
              </.form>

              <div
                :if={@selected_run.kind == "deep_research"}
                id="async-run-research-manifest"
                class="border border-[var(--sf-hairline)] p-3"
              >
                <p class="sf-metadata">Research manifest · Committed execution intent</p>
                <div class="mt-2 grid grid-cols-3 gap-px">
                  <.manifest_fact
                    label="Mode"
                    value={manifest_value(@run_manifest, :mode, "Not requested")}
                  />
                  <.manifest_fact label="Provider" value={manifest_providers(@run_manifest)} />
                  <.manifest_fact
                    label="Depth"
                    value={manifest_value(@run_manifest, :depth, "Unset")}
                  />
                </div>
              </div>

              <div
                id="async-run-budget-meters"
                class="grid gap-px border border-[var(--sf-hairline)] md:grid-cols-3"
              >
                <.budget_meter
                  id="async-run-token-budget"
                  label="Tokens"
                  actual={(@selected_run.input_tokens || 0) + (@selected_run.output_tokens || 0)}
                  limit={@selected_run.token_budget}
                  unit="tokens"
                />
                <.budget_meter
                  id="async-run-cost-budget"
                  label="Cost · reported or reserved"
                  actual={@selected_run.cost_cents || 0}
                  limit={@selected_run.cost_budget_cents}
                  unit="cost"
                  limit_prefix="target"
                />
                <.budget_meter
                  id="async-run-time-budget"
                  label="Elapsed"
                  actual={elapsed_ms(@selected_run)}
                  limit={@selected_run.time_budget_ms}
                  unit="time"
                />
              </div>
            </div>
          </details>

          <details open class="sf-disclosure mt-4">
            <summary>Durable controls and approval gates</summary>
            <div class="space-y-5 p-4">
              <div id="async-run-control-timeline">
                <p class="sf-metadata">Durable controls · {length(@controls)} entries</p>
                <div
                  :if={@controls == []}
                  id="async-run-controls-empty"
                  class="mt-3 border border-dashed border-[var(--sf-hairline)] p-5 text-sm"
                >
                  No operator controls have been recorded.
                </div>
                <article
                  :for={control <- @controls}
                  id={"async-run-control-entry-#{control_value(control, :id, control_fingerprint(control))}"}
                  data-status={control_value(control, :status, "recorded")}
                  class="border-b border-[var(--sf-hairline)] py-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-sm font-medium">{control_title(control)}</p>
                    <span class="sf-metadata">{control_value(control, :status, "recorded")}</span>
                  </div>
                  <p class="mt-1 text-sm text-[var(--sf-text-secondary)]">
                    {control_summary(control)}
                  </p>
                </article>
              </div>
              <div :if={@approvals != []}>
                <h4 class="text-sm font-semibold">Approval gates</h4>
                <article
                  :for={approval <- @approvals}
                  id={"async-run-approval-#{approval.id}"}
                  class="border-b border-[var(--sf-hairline)] py-3"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium">{approval.action}</span>
                    <span class="sf-metadata">{approval.status}</span>
                  </div>
                  <p class="mt-1 text-sm text-[var(--sf-text-secondary)]">{approval.reason}</p>
                  <div :if={approval.status == "pending"} class="mt-2 flex gap-2">
                    <button
                      id={"approve-run-action-#{approval.id}"}
                      type="button"
                      phx-click="decide_run_approval"
                      phx-value-id={approval.id}
                      phx-value-decision="approved"
                      class="sf-control min-h-11 px-3"
                    >Approve</button>
                    <button
                      id={"deny-run-action-#{approval.id}"}
                      type="button"
                      phx-click="decide_run_approval"
                      phx-value-id={approval.id}
                      phx-value-decision="denied"
                      class="sf-control min-h-11 px-3"
                    >Deny</button>
                  </div>
                </article>
              </div>
            </div>
          </details>
        <% else %>
          <p class="p-6 text-sm text-[var(--sf-text-secondary)]">No active run</p>
        <% end %>

        <details open class="sf-disclosure mt-4">
          <summary>Interactive session plane</summary>
          <div id="mission-control-interactive-slot" class="p-4">
            {render_slot(@interactive_execution)}
          </div>
        </details>
      </section>

      <section
        id="mission-control-panel-journal"
        role="tabpanel"
        aria-labelledby="mission-control-mode-journal"
        hidden={@mode != "journal"}
        class="sf-mission-control-panel"
      >
        <details open class="sf-disclosure">
          <summary>Ordered event journal</summary>
          <div
            id="async-run-events"
            role="log"
            aria-live="polite"
            aria-relevant="additions"
            aria-atomic="false"
            class="max-h-[28rem] overflow-y-auto p-4"
          >
            <div :if={@events == []} id="async-run-events-empty" class="p-6 text-center text-sm">
              Waiting for the first persisted event.
            </div>
            <article
              :for={event <- @events}
              id={"run-event-#{event.id}"}
              class="grid grid-cols-[3rem_minmax(0,1fr)] border-b border-[var(--sf-hairline)] py-3"
            >
              <span class="font-mono text-xs">{event.sequence
              |> Integer.to_string()
              |> String.pad_leading(3, "0")}</span>
              <div class="min-w-0">
                <div class="flex items-center justify-between gap-3">
                  <p class="truncate text-sm font-medium">{event.type}</p>
                  <span class="sf-metadata">{event.source}</span>
                </div>
                <p class="mt-1 text-sm text-[var(--sf-text-secondary)]">{event_summary(event)}</p>
              </div>
            </article>
          </div>
        </details>

        <details :if={@artifacts != []} open id="async-run-artifacts" class="sf-disclosure mt-4">
          <summary>Evidence and artifacts · {length(@artifacts)} saved</summary>
          <div class="space-y-3 p-4">
            <article
              :for={artifact <- @artifacts}
              id={"async-run-artifact-#{artifact.id}"}
              class="border-b border-[var(--sf-hairline)] pb-3"
            >
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-medium">{artifact.name}</p>
                <span class="sf-metadata">{artifact.kind}</span>
              </div>
              <p
                :if={artifact_preview(artifact)}
                id={"async-run-artifact-preview-#{artifact.id}"}
                class="mt-2 text-sm text-[var(--sf-text-secondary)]"
              >
                {artifact_preview(artifact)}
              </p>
              <details
                :if={artifact_content(artifact)}
                id={"async-run-artifact-detail-#{artifact.id}"}
                class="mt-3"
              >
                <summary class="sf-control min-h-11">Open full artifact</summary>
                <pre class="sf-code-surface mt-2 max-h-96 whitespace-pre-wrap p-3">{artifact_content(artifact)}</pre>
              </details>
              <div
                :if={artifact_sources(artifact) != []}
                id={"async-run-artifact-sources-#{artifact.id}"}
                class="mt-3 flex flex-wrap gap-2"
              >
                <a
                  :for={{source, index} <- Enum.with_index(artifact_sources(artifact))}
                  id={"async-run-artifact-source-#{artifact.id}-#{index}"}
                  href={source_url(source)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="sf-control min-h-11 px-3"
                >
                  {source_label(source)}
                </a>
              </div>
            </article>
          </div>
        </details>
      </section>
    </section>
    """
  end

  attr :run, :any, required: true
  attr :agents, :any, required: true
  attr :agent_count, :integer, required: true
  attr :summary, :map, required: true
  attr :loading, :boolean, default: false
  attr :guidance, :map, default: %{}
  attr :receipts, :map, default: %{}

  def agent_fleet(assigns) do
    ~H"""
    <section
      id="run-agent-fleet"
      aria-labelledby="run-agent-fleet-heading"
      aria-busy={to_string(@loading)}
      data-fleet-state={fleet_state(@run, @agent_count, @summary, @loading)}
      class="mt-5 border border-[var(--sf-hairline)] bg-[var(--sf-instrument-raised)]"
    >
      <header class="flex flex-col gap-4 border-b border-[var(--sf-hairline)] p-4 lg:flex-row lg:items-end lg:justify-between">
        <div class="min-w-0">
          <p class="sf-metadata">Persisted run roster</p>
          <h4
            id="run-agent-fleet-heading"
            class="mt-1 text-base font-semibold text-[var(--sf-text-primary)]"
          >
            Agent fleet
          </h4>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-[var(--sf-text-secondary)]">
            Persisted workers attached to this selected run. Health, usage, and controls replay after reconnect.
          </p>
        </div>
        <div
          id="run-agent-fleet-summary"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          class="grid grid-cols-2 border border-[var(--sf-hairline)] sm:grid-cols-4"
        >
          <.fleet_fact label="Agents" value={@agent_count} tone="neutral" />
          <.fleet_fact label="Active" value={Map.get(@summary, :active, 0)} tone="neutral" />
          <.fleet_fact label="Paused" value={Map.get(@summary, :paused, 0)} tone="neutral" />
          <.fleet_fact label="Attention" value={Map.get(@summary, :attention, 0)} tone="attention" />
        </div>
      </header>

      <div
        :if={Map.get(@summary, :recovering, 0) > 0}
        id="run-agent-fleet-recovering"
        role="status"
        class="flex items-start gap-2 border-b border-[var(--sf-hairline)] px-4 py-3 text-sm leading-6 text-[var(--sf-text-secondary)]"
      >
        <.icon name="hero-arrow-path" class="mt-1 size-4 shrink-0" />
        <span>
          {Map.get(@summary, :recovering, 0)} worker {pluralize(
            Map.get(@summary, :recovering, 0),
            "is",
            "are"
          )} reconciling durable state. Commands remain recorded while ownership is restored.
        </span>
      </div>

      <div :if={@loading} id="run-agent-fleet-loading" role="status" class="grid md:grid-cols-2">
        <div
          :for={index <- 1..2}
          id={"run-agent-fleet-skeleton-#{index}"}
          class="border-b border-[var(--sf-hairline)] p-5 md:border-r"
        >
          <div class="h-3 w-28 bg-[var(--sf-hairline)]"></div>
          <div class="mt-4 h-2 w-4/5 bg-[var(--sf-hairline)]"></div>
          <div class="mt-2 h-2 w-2/3 bg-[var(--sf-hairline)]"></div>
        </div>
      </div>

      <div
        :if={!@loading}
        id="run-agent-fleet-list"
        phx-update="stream"
        class="grid md:grid-cols-2"
      >
        <div
          id="run-agent-fleet-empty"
          class="hidden border-b border-[var(--sf-hairline)] px-5 py-10 text-center only:block md:col-span-2"
        >
          <.icon name="hero-cpu-chip" class="mx-auto size-5 text-[var(--sf-text-secondary)]" />
          <p class="mt-3 text-sm font-semibold text-[var(--sf-text-primary)]">
            {fleet_empty_title(@run)}
          </p>
          <p class="mx-auto mt-2 max-w-md text-sm leading-6 text-[var(--sf-text-secondary)]">
            {fleet_empty_copy(@run)}
          </p>
        </div>

        <article
          :for={{dom_id, agent} <- @agents}
          id={dom_id}
          data-agent-status={agent_value(agent, :status, "pending")}
          data-agent-health={agent_health(agent)}
          class="min-w-0 border-b border-[var(--sf-hairline)] p-4 md:border-r sm:p-5"
        >
          <% receipt = latest_agent_receipt(@receipts, agent) %>
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="flex min-w-0 items-start gap-3">
              <span class="flex size-9 shrink-0 items-center justify-center border border-[var(--sf-hairline)] text-[var(--sf-text-secondary)]">
                <.icon name={agent_role_icon(agent)} class="size-4" />
              </span>
              <div class="min-w-0">
                <p class="truncate text-sm font-semibold text-[var(--sf-text-primary)]">
                  {agent_display_name(agent)}
                </p>
                <p class="sf-metadata mt-1 truncate" title={agent_value(agent, :key, "agent")}>
                  {agent_value(agent, :role, "worker")} · {agent_value(agent, :key, "agent")}
                </p>
              </div>
            </div>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <span class="sf-pill px-2 py-1 text-xs font-semibold uppercase">
                {agent_value(agent, :status, "pending")}
              </span>
              <span class="sf-pill px-2 py-1 text-xs uppercase">Health · {agent_health(agent)}</span>
            </div>
          </div>

          <div class="mt-4 border-l border-[var(--sf-hairline)] pl-3">
            <p class="sf-metadata">Current task</p>
            <p class="mt-1 line-clamp-2 break-words text-sm leading-6 text-[var(--sf-text-secondary)]">
              {agent_task(agent)}
            </p>
          </div>

          <div class="mt-4">
            <div class="mb-2 flex items-center justify-between gap-3 text-xs text-[var(--sf-text-secondary)]">
              <span class="min-w-0 truncate" title={agent_model(agent)}>{agent_model(agent)}</span>
              <span class="font-mono font-semibold tabular-nums">{agent_progress(agent)}%</span>
            </div>
            <div
              role="progressbar"
              aria-label={"#{agent_display_name(agent)} progress"}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow={agent_progress(agent)}
              class="h-1 bg-[var(--sf-hairline)]"
            >
              <div class="h-full bg-[var(--sf-live-mark)]" style={"width: #{agent_progress(agent)}%"}>
              </div>
            </div>
          </div>

          <div class="mt-4 grid grid-cols-3 border border-[var(--sf-hairline)]">
            <.agent_metric label="Tokens" value={format_count(agent_tokens(agent))} />
            <.agent_metric label="Avg latency" value={agent_average_latency(agent)} />
            <.agent_metric
              label="Requests"
              value={format_count(agent_value(agent, :request_count, 0))}
            />
          </div>

          <div class="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs text-[var(--sf-text-secondary)]">
            <span title={agent_heartbeat_title(agent)}>Heartbeat · {agent_heartbeat_label(agent)}</span>
            <span :if={agent_desired_state_pending?(agent)}>
              Requested · {agent_value(agent, :desired_state)}
            </span>
            <span :if={!agent_desired_state_pending?(agent)}>Last · {agent_last_latency(agent)}</span>
          </div>

          <div
            :if={agent_value(agent, :error_message)}
            id={"run-agent-error-#{agent_value(agent, :id)}"}
            role="alert"
            class="mt-3 border-l-2 border-[var(--sf-live-mark)] pl-3 text-sm leading-6 text-[var(--sf-text-primary)]"
          >
            {agent_value(agent, :error_message)}
          </div>

          <div
            :if={receipt}
            id={"run-agent-control-receipt-#{agent_value(agent, :id)}"}
            role="status"
            data-control-status={agent_receipt_value(receipt, :status, "pending")}
            data-control-result-status={agent_receipt_result_status(receipt)}
            class="mt-3 border border-[var(--sf-hairline)] p-3"
          >
            <div class="flex items-start justify-between gap-3 text-xs uppercase tracking-wide">
              <span class="font-semibold">
                #{agent_receipt_value(receipt, :sequence, 0)} · {agent_receipt_value(
                  receipt,
                  :kind,
                  "control"
                )}
              </span>
              <span class="shrink-0">{agent_receipt_lifecycle(receipt)}</span>
            </div>
            <p class="mt-2 text-sm leading-6 text-[var(--sf-text-secondary)]">
              {agent_receipt_summary(receipt)}
            </p>
            <p
              class="mt-1 text-xs text-[var(--sf-text-secondary)]"
              title={agent_receipt_timestamp_title(receipt)}
            >
              {agent_receipt_timestamp_label(receipt)}
            </p>
          </div>

          <div class="mt-4 border-t border-[var(--sf-hairline)] pt-3">
            <div class="flex flex-wrap gap-2">
              <button
                :if={agent_value(agent, :status) in ["idle", "running"]}
                id={"pause-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="pause"
                phx-disable-with="Pausing…"
                disabled={agent_control_pending?(@receipts, agent, "pause")}
                aria-label={"Pause #{agent_display_name(agent)}"}
                class="sf-control min-h-11 px-3 text-sm"
              >Pause</button>
              <button
                :if={agent_value(agent, :status) == "paused"}
                id={"resume-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="resume"
                phx-disable-with="Resuming…"
                disabled={agent_control_pending?(@receipts, agent, "resume")}
                aria-label={"Resume #{agent_display_name(agent)}"}
                class="sf-control min-h-11 px-3 text-sm"
              >Resume</button>
              <button
                :if={agent_retryable?(agent)}
                id={"restart-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="restart"
                phx-disable-with="Restarting…"
                disabled={agent_control_pending?(@receipts, agent, "restart")}
                aria-label={"Restart #{agent_display_name(agent)}"}
                class="sf-control min-h-11 px-3 text-sm"
              >Restart</button>
              <button
                :if={agent_cancellable?(agent)}
                id={"cancel-run-agent-#{agent_value(agent, :id)}"}
                type="button"
                phx-click="control_run_agent"
                phx-value-id={agent_value(agent, :id)}
                phx-value-action="cancel"
                phx-disable-with="Stopping…"
                disabled={agent_control_pending?(@receipts, agent, "cancel")}
                aria-label={"Stop #{agent_display_name(agent)}"}
                data-confirm="Stop only this agent? Dependent work may wait for recovery or operator action."
                class="sf-control min-h-11 px-3 text-sm"
              >Stop</button>
            </div>

            <.form
              :if={agent_steerable?(agent)}
              for={agent_steering_form(agent, @guidance)}
              id={"run-agent-steering-form-#{agent_value(agent, :id)}"}
              phx-change="update_run_agent_guidance"
              phx-submit="steer_run_agent"
              class="mt-3 grid min-w-0 gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
            >
              <.input
                type="hidden"
                id={"run-agent-steering-agent-id-#{agent_value(agent, :id)}"}
                name="agent_id"
                value={agent_value(agent, :id)}
              />
              <.input
                field={agent_steering_form(agent, @guidance)[:guidance]}
                id={"run-agent-steering-input-#{agent_value(agent, :id)}"}
                type="text"
                label="Agent guidance"
                placeholder="Redirect this worker…"
                class="min-h-11 min-w-0 w-full border border-[var(--sf-hairline)] bg-[var(--sf-code-surface)] px-3 text-sm text-[var(--sf-text-primary)] outline-none placeholder:text-[var(--sf-text-secondary)]"
              />
              <button
                id={"run-agent-steering-submit-#{agent_value(agent, :id)}"}
                type="submit"
                phx-disable-with="Queueing…"
                disabled={agent_control_pending?(@receipts, agent, "steer")}
                aria-label={"Send guidance to #{agent_display_name(agent)}"}
                class="sf-control min-h-11 px-3 text-sm font-semibold"
              >Steer</button>
            </.form>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp fleet_fact(assigns) do
    ~H"""
    <div
      data-tone={@tone}
      class="border-r border-[var(--sf-hairline)] px-3 py-2 text-center last:border-r-0"
    >
      <span class="block text-sm font-semibold tabular-nums text-[var(--sf-text-primary)]">{@value}</span>
      <span class="sf-metadata mt-1 block">{@label}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp agent_metric(assigns) do
    ~H"""
    <div class="min-w-0 border-r border-[var(--sf-hairline)] px-3 py-2 last:border-r-0">
      <span class="sf-metadata block">{@label}</span>
      <span class="mt-1 block truncate font-mono text-sm tabular-nums text-[var(--sf-text-primary)]">{@value}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp manifest_fact(assigns) do
    ~H"""
    <div class="min-w-0 border-r border-[var(--sf-hairline)] px-3 py-2 last:border-r-0">
      <p class="sf-metadata">{@label}</p>
      <p class="mt-1 truncate font-mono text-sm text-[var(--sf-text-primary)]" title={@value}>
        {@value}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :actual, :integer, required: true
  attr :limit, :integer, default: nil
  attr :unit, :string, required: true
  attr :limit_prefix, :string, default: "limit"

  defp budget_meter(assigns) do
    assigns =
      assigns
      |> assign(:percent, budget_percent(assigns.actual, assigns.limit))
      |> assign(:actual_label, budget_value(assigns.actual, assigns.unit))
      |> assign(:limit_label, budget_limit(assigns.limit, assigns.unit))

    ~H"""
    <div
      id={@id}
      data-budget-actual={@actual}
      data-budget-limit={@limit || "unset"}
      class="border-r border-[var(--sf-hairline)] px-3 py-3 last:border-r-0"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="sf-metadata font-semibold">{@label}</p>
          <p class="mt-1 font-mono text-sm tabular-nums text-[var(--sf-text-primary)]">
            {@actual_label}
          </p>
        </div>
        <span class="font-mono text-xs text-[var(--sf-text-secondary)]">{@limit_prefix} {@limit_label}</span>
      </div>
      <div class="mt-2 h-1 overflow-hidden bg-[var(--sf-hairline)]">
        <div
          role="progressbar"
          aria-label={"#{@label} budget used"}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@percent}
          class="h-full bg-[var(--sf-live-mark)] transition-[width] duration-300"
          style={"width: #{@percent}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp run_metric(assigns) do
    ~H"""
    <div
      data-tone={@tone}
      class="border-b border-r border-[var(--sf-hairline)] px-4 py-3 last:border-r-0 md:border-b-0"
    >
      <span class="sf-metadata">{@label}</span>
      <div class="mt-1 font-mono text-xl font-medium tabular-nums text-[var(--sf-text-primary)]">
        {@value}
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp run_status(assigns) do
    ~H"""
    <span
      data-status={@status}
      class="sf-pill inline-flex items-center px-2 py-1 font-mono text-xs font-semibold uppercase tracking-wide"
    >
      {@status |> String.replace("_", " ")}
    </span>
    """
  end

  defp budget_percent(_actual, nil), do: 0
  defp budget_percent(_actual, limit) when not is_integer(limit) or limit <= 0, do: 0

  defp budget_percent(actual, limit) do
    actual
    |> Kernel.*(100)
    |> div(limit)
    |> min(100)
    |> max(0)
  end

  defp budget_limit(nil, _unit), do: "unset"
  defp budget_limit(value, unit), do: budget_value(value, unit)

  defp budget_value(value, "cost"), do: format_cost(value)

  defp budget_value(value, "time") do
    seconds = div(max(value || 0, 0), 1_000)

    cond do
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp budget_value(value, _unit) when is_integer(value) do
    value
    |> Integer.to_string()
    |> add_digit_separators()
  end

  defp budget_value(_value, _unit), do: "0"

  defp add_digit_separators(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp elapsed_ms(%{started_at: nil}), do: 0

  defp elapsed_ms(%{started_at: started_at} = run) do
    finished_at = Map.get(run, :completed_at) || DateTime.utc_now()
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp elapsed_ms(_run), do: 0

  defp manifest_value(manifest, key, fallback) do
    research = manifest_section(manifest)

    flat_key =
      case key do
        :mode -> :research_mode
        :depth -> :research_depth
        _other -> key
      end

    value = manifest_get(research, key) || manifest_get(manifest, flat_key)

    display_value(value, fallback)
  end

  defp manifest_providers(manifest) do
    research = manifest_section(manifest)

    providers =
      manifest_get(research, :providers) || manifest_get(research, :provider) ||
        manifest_get(manifest, :research_providers)

    case providers do
      [] -> "Automatic"
      values when is_list(values) -> Enum.map_join(values, ", ", &display_value(&1, ""))
      value -> display_value(value, "Automatic")
    end
  end

  defp manifest_section(manifest) do
    case manifest_get(manifest, :research) do
      research when is_map(research) -> research
      _other -> manifest
    end
  end

  defp run_workspace_lock_state(nil, _locks), do: "none"

  defp run_workspace_lock_state(run, locks) do
    run_id = lock_value(run, :id)

    cond do
      Enum.any?(locks, fn lock ->
        lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == "held"
      end) ->
        "held"

      Enum.any?(locks, fn lock ->
        lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == "waiting"
      end) ->
        "waiting"

      true ->
        "none"
    end
  end

  defp selected_run_workspace_lock(nil, _locks, _state), do: nil

  defp selected_run_workspace_lock(run, locks, state) when state in ["held", "waiting"] do
    run_id = lock_value(run, :id)

    Enum.find(locks, fn lock ->
      lock_value(lock, :run_id) == run_id and lock_value(lock, :status) == state
    end)
  end

  defp selected_run_workspace_lock(_run, _locks, _state), do: nil

  defp selected_or_first(nil, locks), do: List.first(locks)
  defp selected_or_first(selected, _locks), do: selected

  defp workspace_lock_summary("free", _selected_state, _held, _waiting), do: "Available"

  defp workspace_lock_summary("held", "held", _held, _waiting),
    do: "Reserved by this run"

  defp workspace_lock_summary("waiting", "waiting", _held, _waiting),
    do: "This run is waiting"

  defp workspace_lock_summary("held", _selected_state, held, _waiting),
    do: "Reserved by #{workspace_lock_owner(held)}"

  defp workspace_lock_summary("waiting", _selected_state, _held, _waiting),
    do: "Waiting for workspace"

  defp workspace_lock_summary(_state, _selected_state, _held, _waiting), do: "Available"

  defp workspace_lock_context("free", _selected_state, _held, _waiting),
    do: "No active IexCode workspace reservations."

  defp workspace_lock_context("held", _selected_state, held, _waiting),
    do:
      "#{workspace_lock_resource(held)} · #{display_value(lock_value(held, :mode), "access")} access · #{workspace_lock_lease(held)}"

  defp workspace_lock_context("waiting", _selected_state, _held, waiting),
    do: "#{workspace_lock_resource(waiting)} · queued behind another workspace owner"

  defp workspace_lock_context(_state, _selected_state, _held, _waiting),
    do: "Workspace ownership is synchronized from the durable lock ledger."

  defp workspace_lock_resource(nil), do: "Workspace"

  defp workspace_lock_resource(lock) do
    resource_type = display_value(lock_value(lock, :resource_type), "workspace")
    resource_key = lock_value(lock, :resource_key)

    case {resource_type, resource_key} do
      {"project", _key} -> "Project workspace"
      {"git", _key} -> "Git repository"
      {"file", key} when is_binary(key) and key != "" -> "File · #{Path.basename(key)}"
      {type, _key} -> String.capitalize(type)
    end
  end

  defp workspace_lock_owner(nil), do: "another run"

  defp workspace_lock_owner(lock) do
    cond do
      is_binary(lock_value(lock, :run_id)) ->
        "Run ##{String.slice(lock_value(lock, :run_id), 0, 7)}"

      is_binary(lock_value(lock, :session_id)) ->
        "Session ##{String.slice(lock_value(lock, :session_id), 0, 7)}"

      true ->
        "workspace worker"
    end
  end

  defp workspace_lock_lease(lock) do
    case lock_value(lock, :status) do
      "held" ->
        case lock_value(lock, :lease_expires_at) do
          %DateTime{} = expires_at -> "lease until #{format_lock_time(expires_at)}"
          _ -> "active lease"
        end

      "waiting" ->
        case lock_value(lock, :wait_reason) do
          "queue_predecessor" -> "queued by request order"
          "batch_blocked" -> "waiting for lock batch"
          _ -> "waiting on owner release"
        end

      _ ->
        "inactive"
    end
  end

  defp format_lock_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp lock_value(nil, _key), do: nil

  defp lock_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp lock_value(_value, _key), do: nil

  defp manifest_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp manifest_get(_value, _key), do: nil

  defp display_value(nil, fallback), do: fallback
  defp display_value("", fallback), do: fallback

  defp display_value(value, _fallback) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp display_value(value, _fallback) when is_binary(value), do: String.replace(value, "_", " ")
  defp display_value(value, _fallback), do: to_string(value)

  defp fleet_state(_run, _count, _summary, true), do: "loading"
  defp fleet_state(_run, 0, _summary, false), do: "empty"

  defp fleet_state(_run, _count, summary, false) do
    cond do
      Map.get(summary, :recovering, 0) > 0 -> "recovering"
      Map.get(summary, :attention, 0) > 0 -> "attention"
      Map.get(summary, :active, 0) > 0 -> "active"
      Map.get(summary, :paused, 0) > 0 -> "paused"
      true -> "settled"
    end
  end

  defp fleet_empty_title(run) do
    case agent_value(run, :status) do
      "draft" -> "Draft has not started"
      "queued" -> "Fleet awaits dispatcher claim"
      "running" -> "No worker instances attached"
      _ -> "No persisted agent fleet"
    end
  end

  defp fleet_empty_copy(run) do
    case agent_value(run, :status) do
      "draft" ->
        "Start this draft when it is ready. No worker instances are created before it enters the queue."

      "queued" ->
        "Worker records appear only when the dispatcher materializes this run's topology."

      "running" ->
        "This run may be executing a non-agent step, or its durable topology has not materialized yet."

      status when status in ["completed", "failed", "cancelled", "interrupted"] ->
        "This archived run ended without a durable agent instance record."

      _ ->
        "This run has no agent workers attached. Tool-only and provider work can run without a fleet."
    end
  end

  defp agent_value(record, key, default \\ nil)
  defp agent_value(nil, _key, default), do: default

  defp agent_value(record, key, default) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key), default))
  end

  defp agent_value(_record, _key, default), do: default

  defp agent_display_name(agent) do
    display_value(
      agent_value(agent, :display_name),
      agent_value(agent, :role, agent_value(agent, :key, "Agent worker"))
    )
  end

  defp agent_task(agent) do
    cond do
      present_value?(agent_value(agent, :current_task)) -> agent_value(agent, :current_task)
      agent_value(agent, :status) == "queued" -> "Waiting for a runnable step"
      agent_value(agent, :status) == "paused" -> "Paused with durable context retained"
      agent_value(agent, :status) in ["completed", "cancelled"] -> "No active task"
      true -> "No current task reported"
    end
  end

  defp agent_model(agent) do
    provider = agent_value(agent, :model_provider)
    model = agent_value(agent, :model_name)

    case {present_value?(provider), present_value?(model)} do
      {true, true} -> "#{provider} · #{model}"
      {false, true} -> to_string(model)
      {true, false} -> to_string(provider)
      _ -> "Model not reported"
    end
  end

  defp agent_progress(agent) do
    case agent_value(agent, :progress, 0) do
      value when is_integer(value) -> min(max(value, 0), 100)
      value when is_float(value) -> value |> round() |> min(100) |> max(0)
      _ -> 0
    end
  end

  defp agent_tokens(agent) do
    nonnegative_integer(agent_value(agent, :input_tokens)) +
      nonnegative_integer(agent_value(agent, :output_tokens))
  end

  defp nonnegative_integer(value) when is_integer(value), do: max(value, 0)
  defp nonnegative_integer(_value), do: 0

  defp format_count(value) when is_integer(value) and value >= 1_000_000,
    do: "#{Float.round(value / 1_000_000, 1)}m"

  defp format_count(value) when is_integer(value) and value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}k"

  defp format_count(value) when is_integer(value), do: Integer.to_string(max(value, 0))
  defp format_count(_value), do: "0"

  defp format_latency(value) when is_integer(value) and value >= 60_000,
    do: "#{Float.round(value / 60_000, 1)}m"

  defp format_latency(value) when is_integer(value) and value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}s"

  defp format_latency(value) when is_integer(value) and value >= 0, do: "#{value}ms"
  defp format_latency(_value), do: "—"

  defp agent_average_latency(agent) do
    if nonnegative_integer(agent_value(agent, :request_count)) > 0,
      do: format_latency(agent_value(agent, :average_latency_ms)),
      else: "—"
  end

  defp agent_last_latency(agent) do
    if nonnegative_integer(agent_value(agent, :request_count)) > 0,
      do: format_latency(agent_value(agent, :last_latency_ms)),
      else: "—"
  end

  defp agent_health(agent) do
    status = agent_value(agent, :status, "pending")

    cond do
      status in ["starting", "recovering"] -> "recovering"
      status == "failed" -> "degraded"
      status in ["completed", "cancelled", "interrupted"] -> "offline"
      status in ["pending", "queued"] -> "unknown"
      timestamp_past?(agent_value(agent, :lease_expires_at)) -> "stale"
      present_value?(agent_value(agent, :heartbeat_at)) -> "healthy"
      true -> "unknown"
    end
  end

  defp timestamp_past?(%DateTime{} = timestamp),
    do: DateTime.compare(timestamp, DateTime.utc_now()) == :lt

  defp timestamp_past?(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> timestamp_past?()
  end

  defp timestamp_past?(_timestamp), do: false

  defp agent_heartbeat_label(agent) do
    case agent_value(agent, :heartbeat_at) || agent_value(agent, :last_active_at) do
      %DateTime{} = timestamp ->
        relative_time(timestamp)

      %NaiveDateTime{} = timestamp ->
        timestamp |> DateTime.from_naive!("Etc/UTC") |> relative_time()

      _ ->
        "not reported"
    end
  end

  defp agent_heartbeat_title(agent) do
    case agent_value(agent, :heartbeat_at) || agent_value(agent, :last_active_at) do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      %NaiveDateTime{} = timestamp -> NaiveDateTime.to_iso8601(timestamp)
      _ -> "No heartbeat has been persisted"
    end
  end

  defp relative_time(%DateTime{} = timestamp) do
    seconds = max(DateTime.diff(DateTime.utc_now(), timestamp, :second), 0)

    cond do
      seconds < 5 -> "now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3_600)}h ago"
    end
  end

  defp agent_role_icon(agent) do
    case agent_value(agent, :role, "") |> to_string() |> String.downcase() do
      "planner" -> "hero-map"
      "explorer" -> "hero-magnifying-glass"
      "coder" -> "hero-code-bracket"
      "verifier" -> "hero-check-badge"
      "researcher" -> "hero-globe-alt"
      _ -> "hero-cpu-chip"
    end
  end

  defp agent_cancellable?(agent),
    do:
      agent_value(agent, :status) in [
        "pending",
        "starting",
        "idle",
        "running",
        "paused",
        "stopping"
      ]

  defp agent_retryable?(agent) do
    agent_value(agent, :status) == "interrupted" and
      nonnegative_integer(agent_value(agent, :attempt)) <
        max(nonnegative_integer(agent_value(agent, :max_attempts)), 1)
  end

  defp agent_steerable?(agent),
    do: agent_value(agent, :status) in ["idle", "running", "paused"]

  defp agent_desired_state_pending?(agent) do
    desired = agent_value(agent, :desired_state)
    status = agent_value(agent, :status)

    case desired do
      "paused" -> status != "paused"
      "stopped" -> status not in ["stopping", "completed", "failed", "cancelled"]
      "active" -> status in ["paused", "stopping", "failed", "cancelled", "interrupted"]
      _ -> false
    end
  end

  defp agent_steering_form(agent, guidance) do
    value = Map.get(guidance, agent_value(agent, :id), "")
    to_form(%{"guidance" => value}, as: :agent_control)
  end

  defp latest_agent_receipt(receipts, agent) when is_map(receipts) do
    receipts
    |> Map.get(agent_value(agent, :id), [])
    |> List.first()
  end

  defp latest_agent_receipt(_receipts, _agent), do: nil

  defp agent_control_pending?(receipts, agent, kind) do
    receipts
    |> Map.get(agent_value(agent, :id), [])
    |> Enum.any?(fn receipt ->
      agent_receipt_value(receipt, :kind, nil) == kind and
        agent_receipt_value(receipt, :status, nil) in ["pending", "claimed"]
    end)
  end

  defp agent_receipt_lifecycle(receipt) do
    case {agent_receipt_value(receipt, :status, "pending"), agent_receipt_result_status(receipt)} do
      {"applied", result_status} when result_status in ["queued", "consumed"] -> result_status
      {status, _result_status} -> status
    end
  end

  defp agent_receipt_result_status(receipt) do
    status =
      receipt
      |> agent_receipt_value(:result, %{})
      |> agent_receipt_map_value(:status)
      |> safe_agent_receipt_value()

    if status in ~w(queued consumed applied completed paused resumed stopped cancelled restarted steered),
      do: status,
      else: nil
  end

  defp agent_receipt_summary(receipt) do
    status = agent_receipt_value(receipt, :status, "pending")
    kind = agent_receipt_value(receipt, :kind, "control")
    result = agent_receipt_value(receipt, :result, %{})
    result_status = agent_receipt_result_status(receipt)
    error = result |> agent_receipt_map_value(:error) |> safe_agent_receipt_error()

    case {status, kind, result_status, error} do
      {"pending", _kind, _result_status, _error} ->
        "Persisted and waiting for the worker lease."

      {"claimed", _kind, _result_status, _error} ->
        "Claimed by the current worker generation."

      {"applied", "steer", "queued", _error} ->
        "Guidance is durable and waiting for worker consumption."

      {"applied", "steer", "consumed", _error} ->
        "Guidance was consumed by the worker."

      {"applied", _kind, result_status, _error} when is_binary(result_status) ->
        "Worker reported #{String.replace(result_status, "_", " ")}."

      {"applied", _kind, _result_status, _error} ->
        "The worker applied this control."

      {"rejected", _kind, _result_status, error} when is_binary(error) ->
        "Rejected · #{String.slice(error, 0, 180)}"

      {"rejected", _kind, _result_status, _error} ->
        "The worker rejected this control."

      {"superseded", _kind, _result_status, _error} ->
        "Replaced by a newer control or worker generation."

      {_status, _kind, _result_status, _error} ->
        "Recorded in the durable agent control log."
    end
  end

  defp agent_receipt_timestamp_label(receipt) do
    requested =
      receipt_timestamp_part("Requested", agent_receipt_value(receipt, :inserted_at, nil))

    lifecycle =
      cond do
        agent_receipt_value(receipt, :resolved_at, nil) ->
          receipt_timestamp_part("Resolved", agent_receipt_value(receipt, :resolved_at, nil))

        agent_receipt_value(receipt, :claimed_at, nil) ->
          receipt_timestamp_part("Claimed", agent_receipt_value(receipt, :claimed_at, nil))

        true ->
          nil
      end

    [requested, lifecycle]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp agent_receipt_timestamp_title(receipt) do
    [
      receipt_timestamp_title_part("Requested", agent_receipt_value(receipt, :inserted_at, nil)),
      receipt_timestamp_title_part("Claimed", agent_receipt_value(receipt, :claimed_at, nil)),
      receipt_timestamp_title_part("Resolved", agent_receipt_value(receipt, :resolved_at, nil))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No control timestamp has been persisted"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp receipt_timestamp_part(prefix, %DateTime{} = value),
    do: "#{prefix} #{relative_time(value)}"

  defp receipt_timestamp_part(prefix, %NaiveDateTime{} = value),
    do: "#{prefix} #{value |> DateTime.from_naive!("Etc/UTC") |> relative_time()}"

  defp receipt_timestamp_part("Requested", _value), do: "Requested time not reported"
  defp receipt_timestamp_part(_prefix, _value), do: nil

  defp receipt_timestamp_title_part(prefix, %DateTime{} = value),
    do: "#{prefix} #{DateTime.to_iso8601(value)}"

  defp receipt_timestamp_title_part(prefix, %NaiveDateTime{} = value),
    do: "#{prefix} #{NaiveDateTime.to_iso8601(value)}"

  defp receipt_timestamp_title_part(_prefix, _value), do: nil

  defp agent_receipt_value(nil, _key, fallback), do: fallback

  defp agent_receipt_value(receipt, key, fallback) when is_map(receipt) do
    Map.get(receipt, key, Map.get(receipt, Atom.to_string(key), fallback))
  end

  defp agent_receipt_value(_receipt, _key, fallback), do: fallback

  defp agent_receipt_map_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp agent_receipt_map_value(_value, _key), do: nil

  defp safe_agent_receipt_value(value) when is_binary(value), do: value
  defp safe_agent_receipt_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_agent_receipt_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_agent_receipt_value(_value), do: nil

  defp safe_agent_receipt_error(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_agent_receipt_error(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z0-9_.:-]{1,80}$/, value), do: value, else: "worker_error"
  end

  defp safe_agent_receipt_error(_value), do: nil

  defp present_value?(value), do: not is_nil(value) and value != ""

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  defp control_value(control, key, fallback) do
    case manifest_get(control, key) do
      nil -> fallback
      value -> value
    end
  end

  defp control_fingerprint(control), do: :erlang.phash2(control)

  defp control_title(control) do
    control_value(control, :action, nil) ||
      control_value(control, :kind, nil) ||
      control_value(control, :type, nil) ||
      control_value(control, :tool_name, "Operator control")
      |> display_value("Operator control")
  end

  defp control_summary(control) do
    value =
      control_value(control, :instruction, nil) ||
        control_value(control, :message, nil) ||
        control_value(control, :reason, nil) ||
        control_value(control, :summary, nil) ||
        control_value(control, :output, nil)

    display_value(value, "Persisted in the run control journal.")
  end

  defp artifact_preview(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}

    [:report_preview, :preview, :excerpt, :summary, :report, :content]
    |> Enum.find_value(&manifest_get(metadata, &1))
    |> preview_content()
  end

  defp artifact_content(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}

    case manifest_get(metadata, :content) do
      content when is_binary(content) and content != "" -> String.slice(content, 0, 250_000)
      _ -> nil
    end
  end

  defp artifact_sources(artifact) do
    metadata = Map.get(artifact, :metadata, %{}) || %{}
    decoded = decode_metadata_content(metadata)

    case manifest_get(metadata, :sources) || manifest_get(metadata, :source) ||
           manifest_get(decoded, :sources) do
      sources when is_list(sources) -> Enum.take(sources, 8)
      nil -> []
      source -> [source]
    end
  end

  defp decode_metadata_content(metadata) do
    case manifest_get(metadata, :content) do
      content when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp preview_content(nil), do: nil

  defp preview_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) ->
        manifest_get(decoded, :summary) ||
          case manifest_get(decoded, :sources) do
            sources when is_list(sources) ->
              "#{length(sources)} normalized research sources preserved."

            _other ->
              String.slice(content, 0, 1_200)
          end

      _other ->
        String.slice(content, 0, 1_200)
    end
  end

  defp source_label(source) when is_map(source) do
    manifest_get(source, :title) || manifest_get(source, :name) || manifest_get(source, :url) ||
      manifest_get(source, :uri) || "Recorded source"
  end

  defp source_label(source), do: display_value(source, "Recorded source")

  defp source_url(source) when is_map(source) do
    case manifest_get(source, :url) || manifest_get(source, :uri) do
      "https://" <> _ = url -> url
      "http://" <> _ = url -> url
      _ -> "#"
    end
  end

  defp source_url(_source), do: "#"

  defp event_summary(event) do
    payload = event.payload || %{}

    payload_value(payload, "message") ||
      status_transition(payload) ||
      payload_value(payload, "reason") ||
      payload_value(payload, "objective") ||
      "Persisted at #{format_time(event.occurred_at)}"
  end

  defp status_transition(payload) do
    from = payload_value(payload, "from")
    to = payload_value(payload, "to")
    if from && to, do: "#{from} → #{to}"
  end

  defp payload_value(payload, key) do
    atom_key =
      case key do
        "message" -> :message
        "reason" -> :reason
        "objective" -> :objective
        "from" -> :from
        "to" -> :to
      end

    Map.get(payload, key) || Map.get(payload, atom_key)
  end

  defp format_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
  end

  defp format_time(_), do: "unknown time"

  defp format_cost(nil), do: "$0.00"

  defp format_cost(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{remainder}"
  end

  defp format_cost(_), do: "$0.00"
end
