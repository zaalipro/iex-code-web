defmodule IexCodeWeb.DagComponents do
  @moduledoc """
  Presentational primitives for the opt-in durable DAG execution plane.

  The component consumes a normalized, server-authorized projection. It never
  infers scheduler readiness, lease ownership, checkpoint safety, or available
  controls from raw database fields in the browser.
  """

  use IexCodeWeb, :html

  attr :projection, :map, required: true

  def dag_projection(assigns) do
    projection = assigns.projection
    layers = projection_value(projection, :layers, [])
    summary = projection_value(projection, :summary, %{})
    engine = projection_value(projection, :engine, "dag_v1")
    available? = projection_value(projection, :available?, false)
    error_code = projection_value(projection, :error_code, nil)

    assigns =
      assigns
      |> assign(:layers, normalize_layers(layers))
      |> assign(:summary, summary)
      |> assign(:engine, engine)
      |> assign(:available?, available?)
      |> assign(:error_code, safe_error_code(error_code))
      |> assign(:node_count, layers |> normalize_layers() |> List.flatten() |> length())

    ~H"""
    <section
      id="dag-execution-projection"
      aria-labelledby="dag-execution-heading"
      data-engine={@engine}
      data-scheduler-state={if(@available?, do: "available", else: "unavailable")}
      class="overflow-hidden border border-[#29313a] bg-[#0b0f14]"
    >
      <header class="border-b border-[#252c35] px-4 py-4 sm:px-5">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div class="max-w-2xl">
            <div class="mb-1.5 flex items-center gap-2 font-mono text-[10px] font-semibold uppercase tracking-[0.18em] text-cyan-300">
              <span class="h-1.5 w-1.5 bg-cyan-400"></span> Dependency-aware execution
            </div>
            <h4 id="dag-execution-heading" class="text-base font-semibold tracking-tight text-white">
              DAG execution map
            </h4>
            <p class="mt-1 max-w-[65ch] text-xs leading-5 text-gray-500">
              A durable topological projection of runnable, leased, blocked, retrying, and
              checkpointed work. Scheduler decisions remain server-authoritative.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2 font-mono text-[10px] uppercase tracking-wider">
            <span class="border border-[#303844] bg-[#11161d] px-2.5 py-1.5 text-gray-400">
              {@engine}
            </span>
            <span class={[
              "border px-2.5 py-1.5",
              @available? && "border-emerald-500/25 bg-emerald-500/[0.06] text-emerald-300",
              !@available? && "border-amber-500/25 bg-amber-500/[0.06] text-amber-300"
            ]}>
              {if @available?, do: "scheduler online", else: "fail closed"}
            </span>
          </div>
        </div>

        <div
          id="dag-execution-summary"
          role="status"
          class="mt-4 grid grid-cols-2 gap-px bg-[#252c35] sm:grid-cols-4 xl:grid-cols-8"
        >
          <.summary_fact label="Nodes" value={@node_count} tone="text-gray-100" />
          <.summary_fact label="Ready" value={summary_count(@summary, :ready)} tone="text-blue-300" />
          <.summary_fact
            label="Running"
            value={summary_count(@summary, :running)}
            tone="text-cyan-300"
          />
          <.summary_fact
            label="Blocked"
            value={summary_count(@summary, :blocked)}
            tone="text-amber-300"
          />
          <.summary_fact
            label="Approval"
            value={summary_count(@summary, :approval)}
            tone="text-violet-300"
          />
          <.summary_fact
            label="Retrying"
            value={summary_count(@summary, :retrying)}
            tone="text-orange-300"
          />
          <.summary_fact
            label="Complete"
            value={summary_count(@summary, :completed)}
            tone="text-emerald-300"
          />
          <.summary_fact label="Failed" value={summary_count(@summary, :failed)} tone="text-rose-300" />
        </div>
      </header>

      <div
        :if={@error_code}
        id="dag-projection-error"
        role="alert"
        class="flex items-start gap-3 border-b border-rose-500/20 bg-rose-500/[0.04] px-4 py-3 text-xs leading-5 text-rose-200 sm:px-5"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 h-4 w-4 shrink-0 text-rose-300" />
        <p>DAG projection unavailable · {@error_code}</p>
      </div>

      <div
        :if={!@available? and is_nil(@error_code)}
        id="dag-scheduler-unavailable"
        role="status"
        class="flex items-start gap-3 border-b border-amber-500/20 bg-amber-500/[0.04] px-4 py-3 text-xs leading-5 text-amber-100/80 sm:px-5"
      >
        <.icon name="hero-lock-closed" class="mt-0.5 h-4 w-4 shrink-0 text-amber-300" />
        <p>
          This manifest is preserved but cannot execute until its fenced DAG scheduler is
          available. It will not fall through to legacy execution.
        </p>
      </div>

      <div
        :if={@node_count == 0 and is_nil(@error_code)}
        id="dag-execution-empty"
        class="px-5 py-12 text-center"
      >
        <span class="mx-auto flex h-10 w-10 items-center justify-center border border-dashed border-[#3a4450] text-gray-600">
          <.icon name="hero-share" class="h-4 w-4" />
        </span>
        <p class="mt-3 text-sm font-medium text-gray-300">No DAG nodes persisted</p>
        <p class="mx-auto mt-1 max-w-md text-xs leading-5 text-gray-600">
          The execution map appears after a validated immutable manifest is committed.
        </p>
      </div>

      <div :if={@node_count > 0} id="dag-execution-map">
        <div class="hidden overflow-x-auto p-5 lg:block">
          <div class="flex min-w-max items-start gap-3">
            <section
              :for={{layer, layer_index} <- Enum.with_index(@layers)}
              id={"dag-layer-#{layer_index}"}
              aria-labelledby={"dag-layer-heading-#{layer_index}"}
              class="w-72 shrink-0"
            >
              <div class="mb-2 flex items-center justify-between border-b border-[#28313a] pb-2 font-mono text-[10px] uppercase tracking-wider text-gray-600">
                <h5 id={"dag-layer-heading-#{layer_index}"}>Stage {layer_index + 1}</h5>
                <span>{length(layer)} {pluralize(length(layer), "node", "nodes")}</span>
              </div>
              <div class="space-y-2">
                <.dag_node :for={node <- layer} node={node} layout="desktop" />
              </div>
            </section>
          </div>
        </div>

        <div class="space-y-3 p-4 lg:hidden">
          <section
            :for={{layer, layer_index} <- Enum.with_index(@layers)}
            id={"dag-mobile-layer-#{layer_index}"}
            aria-labelledby={"dag-mobile-layer-heading-#{layer_index}"}
          >
            <div class="mb-2 flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.14em] text-gray-600">
              <span class="flex h-5 w-5 items-center justify-center border border-[#303844] text-gray-400">
                {layer_index + 1}
              </span>
              <h5 id={"dag-mobile-layer-heading-#{layer_index}"}>Execution stage</h5>
              <span class="h-px flex-1 bg-[#28313a]"></span>
            </div>
            <div class="space-y-2">
              <.dag_node :for={node <- layer} node={node} layout="mobile" />
            </div>
          </section>
        </div>
      </div>
    </section>
    """
  end

  attr :node, :map, required: true
  attr :layout, :string, values: ~w(desktop mobile), default: "desktop"

  def dag_node(assigns) do
    node = assigns.node
    id = node_value(node, :id, node_value(node, :key, "unknown"))
    key = node_value(node, :key, "unknown")
    status = normalized_label(node_value(node, :status, "pending"))

    readiness =
      node
      |> node_value(:readiness, node_value(node, :readiness_reason, "waiting_dependencies"))
      |> normalized_label()

    dependencies = normalize_string_list(node_value(node, :depends_on, []))
    blocked_by = normalize_string_list(node_value(node, :blocked_by, []))
    latest_attempt = node_value(node, :latest_attempt, %{})

    assigns =
      assigns
      |> assign(:node_id, id)
      |> assign(:key, key)
      |> assign(:status, status)
      |> assign(:readiness, readiness)
      |> assign(:dependencies, dependencies)
      |> assign(:blocked_by, blocked_by)
      |> assign(:latest_attempt, latest_attempt)

    ~H"""
    <article
      id={"dag-node-#{@node_id}-#{@layout}"}
      data-node-key={@key}
      data-node-status={@status}
      data-node-readiness={@readiness}
      data-critical-path={to_string(node_value(@node, :critical_path?, false))}
      class={[
        "relative min-w-0 border bg-[#10151b] p-3.5 transition-colors",
        dag_node_border(@status, node_value(@node, :critical_path?, false))
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-2">
            <span class={["h-2 w-2 shrink-0 rounded-full", dag_status_dot(@status)]}></span>
            <h6 class="truncate text-sm font-semibold tracking-tight text-gray-100">
              {node_value(@node, :title, @key)}
            </h6>
          </div>
          <p class="mt-1 truncate pl-4 font-mono text-[10px] text-gray-600" title={@key}>
            {@key} · {normalized_label(node_value(@node, :kind, "task"))}
          </p>
        </div>
        <span class={[
          "shrink-0 border px-1.5 py-0.5 font-mono text-[9px] font-semibold uppercase tracking-wider",
          dag_status_tone(@status)
        ]}>
          {@status}
        </span>
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-1.5">
        <span class="border border-[#303844] bg-[#0c1117] px-2 py-1 font-mono text-[9px] uppercase tracking-wider text-gray-500">
          {readiness_label(@readiness)}
        </span>
      </div>

      <div :if={@dependencies != []} class="mt-3 border-l border-[#303844] pl-3">
        <p class="font-mono text-[9px] uppercase tracking-wider text-gray-600">
          {if @blocked_by == [], do: "After", else: "Blocked by"}
        </p>
        <div class="mt-1.5 flex flex-wrap gap-1">
          <span
            :for={dependency <- if(@blocked_by == [], do: @dependencies, else: @blocked_by)}
            class={[
              "max-w-full truncate border px-1.5 py-0.5 font-mono text-[9px]",
              dependency in @blocked_by &&
                "border-amber-500/20 bg-amber-500/[0.04] text-amber-300",
              dependency not in @blocked_by && "border-[#303844] bg-[#0c1117] text-gray-500"
            ]}
            title={dependency}
          >
            {dependency}
          </span>
        </div>
      </div>

      <div class="mt-3">
        <div class="mb-1.5 flex items-center justify-between font-mono text-[10px] text-gray-600">
          <span>Attempt {node_attempt(@node)}</span>
          <span class="tabular-nums text-gray-400">{node_progress(@node)}%</span>
        </div>
        <div
          role="progressbar"
          aria-label={"#{node_value(@node, :title, @key)} progress"}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={node_progress(@node)}
          class="h-1 overflow-hidden bg-[#29313a]"
        >
          <div
            class={[
              "h-full transition-[width] duration-300 motion-reduce:transition-none",
              dag_progress_tone(@status)
            ]}
            style={"width: #{node_progress(@node)}%"}
          >
          </div>
        </div>
      </div>

      <div class="mt-3 grid grid-cols-1 gap-px bg-[#252c35] sm:grid-cols-2 lg:grid-cols-1">
        <.node_fact
          :if={attempt_value(@latest_attempt, :retry_not_before, nil)}
          label="Next retry"
          value={format_timestamp(attempt_value(@latest_attempt, :retry_not_before, nil))}
        />
        <.node_fact
          :if={attempt_value(@latest_attempt, :checkpoint_version, nil)}
          label="Checkpoint"
          value={checkpoint_label(@latest_attempt)}
        />
      </div>

      <p
        :if={safe_error_code(node_value(@node, :error_code, nil))}
        id={"dag-node-error-#{@node_id}-#{@layout}"}
        role="alert"
        class="mt-3 border-l-2 border-rose-500 pl-3 text-xs leading-5 text-rose-300"
      >
        {safe_error_code(node_value(@node, :error_code, nil))}
      </p>

      <details class="group mt-3 border-t border-[#28313a] pt-2">
        <summary class="flex min-h-9 cursor-pointer list-none items-center justify-between font-mono text-[10px] uppercase tracking-wider text-gray-500 hover:text-gray-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-400/60 [&::-webkit-details-marker]:hidden">
          Node details
          <.icon
            name="hero-chevron-down"
            class="h-3 w-3 transition-transform group-open:rotate-180 motion-reduce:transition-none"
          />
        </summary>
        <dl class="grid grid-cols-2 gap-px bg-[#252c35]">
          <.detail_fact label="Readiness" value={readiness_label(@readiness)} />
          <.detail_fact
            label="Heartbeat"
            value={format_timestamp(attempt_value(@latest_attempt, :heartbeat_at, nil))}
          />
          <.detail_fact
            label="Started"
            value={format_timestamp(attempt_value(@latest_attempt, :started_at, nil))}
          />
          <.detail_fact
            label="Completed"
            value={format_timestamp(attempt_value(@latest_attempt, :completed_at, nil))}
          />
        </dl>
      </details>
    </article>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp summary_fact(assigns) do
    ~H"""
    <div class="bg-[#10151b] px-2.5 py-2.5 text-center">
      <span class={[@tone, "block font-mono text-sm font-semibold tabular-nums"]}>{@value}</span>
      <span class="mt-0.5 block text-[9px] uppercase tracking-wider text-gray-600">{@label}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp node_fact(assigns) do
    ~H"""
    <div class="min-w-0 bg-[#0d1218] px-2.5 py-2">
      <p class="font-mono text-[9px] uppercase tracking-wider text-gray-600">{@label}</p>
      <p class="mt-0.5 truncate text-[11px] text-gray-300" title={@value}>{@value}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail_fact(assigns) do
    ~H"""
    <div class="min-w-0 bg-[#0d1218] px-2.5 py-2">
      <dt class="font-mono text-[9px] uppercase tracking-wider text-gray-600">{@label}</dt>
      <dd class="mt-0.5 truncate font-mono text-[10px] text-gray-400" title={@value}>{@value}</dd>
    </div>
    """
  end

  defp projection_value(map, key, fallback) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), fallback))

  defp projection_value(_value, _key, fallback), do: fallback
  defp node_value(map, key, fallback), do: projection_value(map, key, fallback)
  defp attempt_value(map, key, fallback), do: projection_value(map, key, fallback)

  defp normalize_layers(layers) when is_list(layers) do
    layers
    |> Enum.filter(&is_list/1)
    |> Enum.map(&Enum.filter(&1, fn node -> is_map(node) end))
  end

  defp normalize_layers(_layers), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp normalized_label(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_label()

  defp normalized_label(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(" ", "_")

  defp normalized_label(_value), do: "unknown"

  defp summary_count(summary, key) do
    case projection_value(summary, key, 0) do
      value when is_integer(value) -> max(value, 0)
      _value -> 0
    end
  end

  defp node_progress(node) do
    case node_value(node, :progress, 0) do
      value when is_integer(value) -> value |> max(0) |> min(100)
      value when is_float(value) -> value |> round() |> max(0) |> min(100)
      _value -> 0
    end
  end

  defp node_attempt(node) do
    attempt = positive_or_zero(node_value(node, :attempt, 0))
    maximum = max(positive_or_zero(node_value(node, :max_attempts, 1)), 1)
    "#{attempt}/#{maximum}"
  end

  defp positive_or_zero(value) when is_integer(value), do: max(value, 0)
  defp positive_or_zero(_value), do: 0

  defp safe_error_code(nil), do: nil
  defp safe_error_code(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_error_code(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z0-9_.:-]{1,120}$/, value), do: value
  end

  defp safe_error_code(_value), do: nil

  defp format_timestamp(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_timestamp(%NaiveDateTime{} = value),
    do: value |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp format_timestamp(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp format_timestamp(_value), do: "Not reported"

  defp checkpoint_label(attempt) when is_map(attempt) do
    version = attempt_value(attempt, :checkpoint_version, nil)
    timestamp = format_timestamp(attempt_value(attempt, :checkpointed_at, nil))
    if is_integer(version), do: "v#{version} · #{timestamp}", else: "Not reported"
  end

  defp checkpoint_label(_attempt), do: "Not reported"

  defp readiness_label("ready"), do: "Ready to claim"
  defp readiness_label("waiting_dependencies"), do: "Waiting on dependencies"
  defp readiness_label("dependency_failed"), do: "Dependency failed"
  defp readiness_label("retry_backoff"), do: "Retry scheduled"
  defp readiness_label("approval"), do: "Approval required"
  defp readiness_label("leased"), do: "Lease active"
  defp readiness_label("lease_expired"), do: "Lease expired"
  defp readiness_label("interrupted"), do: "Interrupted"
  defp readiness_label("paused"), do: "Paused"
  defp readiness_label("terminal"), do: "Terminal"
  defp readiness_label(value), do: String.replace(value, "_", " ")

  defp dag_status_dot("running"), do: "animate-pulse bg-cyan-400 motion-reduce:animate-none"
  defp dag_status_dot("ready"), do: "bg-blue-400"
  defp dag_status_dot("completed"), do: "bg-emerald-400"
  defp dag_status_dot(status) when status in ~w(failed cancelled), do: "bg-rose-400"

  defp dag_status_dot(status) when status in ~w(blocked waiting_approval paused retrying),
    do: "bg-amber-400"

  defp dag_status_dot(_status), do: "bg-gray-600"

  defp dag_status_tone(status) when status in ~w(running completed),
    do: "border-emerald-500/20 bg-emerald-500/[0.05] text-emerald-300"

  defp dag_status_tone("ready"),
    do: "border-blue-500/20 bg-blue-500/[0.05] text-blue-300"

  defp dag_status_tone(status) when status in ~w(failed cancelled),
    do: "border-rose-500/20 bg-rose-500/[0.05] text-rose-300"

  defp dag_status_tone(status) when status in ~w(blocked waiting_approval paused retrying),
    do: "border-amber-500/20 bg-amber-500/[0.05] text-amber-300"

  defp dag_status_tone(_status),
    do: "border-[#303844] bg-[#151b22] text-gray-400"

  defp dag_node_border("failed", _critical), do: "border-rose-500/30"
  defp dag_node_border(_status, true), do: "border-cyan-400/40 shadow-[inset_2px_0_0_#22d3ee]"
  defp dag_node_border(_status, _critical), do: "border-[#29313a]"

  defp dag_progress_tone("failed"), do: "bg-rose-400"
  defp dag_progress_tone("blocked"), do: "bg-amber-400"
  defp dag_progress_tone("completed"), do: "bg-emerald-400"
  defp dag_progress_tone(_status), do: "bg-cyan-400"

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
