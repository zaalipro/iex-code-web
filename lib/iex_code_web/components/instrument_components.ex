defmodule IexCodeWeb.InstrumentComponents do
  use IexCodeWeb, :html

  attr :summaries, :map, required: true
  attr :active_view, :string, default: "deck"

  def instrument_deck(assigns) do
    ~H"""
    <section
      id="instrument-deck"
      aria-labelledby="instrument-deck-heading"
      tabindex="-1"
      class="sf-ambient-field sf-sheet-scroll flex-1 min-w-0 px-4 py-5 md:px-6 md:py-7 xl:px-8 xl:py-9"
    >
      <div class="mx-auto w-full max-w-[1500px] min-w-0">
        <div class="mb-6 flex min-w-0 items-end justify-between gap-4 md:mb-8">
          <div class="min-w-0">
            <p class="sf-metadata mb-2">Signal Foundry</p>
            <h2
              id="instrument-deck-heading"
              tabindex="-1"
              class="text-2xl font-semibold tracking-tight md:text-3xl"
            >
              Instrument Deck
            </h2>
          </div>
          <span class="sf-metadata hidden shrink-0 md:block">Eight operational surfaces</span>
        </div>

        <div class="sf-deck-grid">
          <%= for surface <- deck_surfaces() do %>
            <% summary = summary_for(@summaries, surface) %>
            <%= cond do %>
              <% surface == "research" and summary.navigable? -> %>
                <.link
                  id="instrument-card-research"
                  patch={summary.destination}
                  data-instrument-surface={surface}
                  data-status={status_key(summary.status)}
                  aria-current={if(@active_view == surface, do: "page", else: "false")}
                  aria-label={accessible_card_name(summary)}
                  class={card_classes(surface)}
                >
                  <.instrument_face summary={summary} surface={surface} />
                </.link>
              <% surface == "research" -> %>
                <button
                  id="instrument-card-research"
                  type="button"
                  disabled
                  aria-disabled="true"
                  data-instrument-surface={surface}
                  data-status={status_key(summary.status)}
                  aria-current={if(@active_view == surface, do: "page", else: "false")}
                  aria-label={accessible_card_name(summary)}
                  class={card_classes(surface)}
                >
                  <.instrument_face summary={summary} surface={surface} />
                </button>
              <% summary.navigable? -> %>
                <button
                  id={"instrument-card-#{surface}"}
                  type="button"
                  phx-click="switch_tab"
                  phx-value-tab={surface}
                  data-instrument-surface={surface}
                  data-status={status_key(summary.status)}
                  aria-pressed={to_string(@active_view == surface)}
                  aria-label={accessible_card_name(summary)}
                  class={card_classes(surface)}
                >
                  <.instrument_face summary={summary} surface={surface} />
                </button>
              <% true -> %>
                <button
                  id={"instrument-card-#{surface}"}
                  type="button"
                  disabled
                  aria-disabled="true"
                  data-instrument-surface={surface}
                  data-status={status_key(summary.status)}
                  aria-pressed={to_string(@active_view == surface)}
                  aria-label={accessible_card_name(summary)}
                  class={card_classes(surface)}
                >
                  <.instrument_face summary={summary} surface={surface} />
                </button>
            <% end %>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :summary, :map, required: true
  attr :surface, :string, required: true

  defp instrument_face(assigns) do
    ~H"""
    <div class="flex min-h-[250px] min-w-0 flex-col p-5 text-left md:min-h-[270px] md:p-6">
      <div class="flex min-w-0 items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="sf-metadata flex items-center gap-2">
            <span class="sf-display text-[1.25rem] tracking-[0.1em]">{surface_index(@surface)}</span>
            <span class="truncate">{@summary.title}</span>
          </div>
          <div class="mt-3 flex min-w-0 items-start gap-2">
            <span
              aria-hidden="true"
              class={["mt-1.5 h-2 w-2 shrink-0 rounded-full", status_mark_class(@summary.status)]}
            ></span>
            <span
              data-summary-primary
              class="sf-body-copy min-w-0 max-w-full break-words [overflow-wrap:anywhere] text-sm font-medium"
            >
              {primary_text(@summary)}
            </span>
          </div>
        </div>
        <span class="sf-metadata shrink-0">{status_label(@summary.status)}</span>
      </div>

      <div class="mt-4 min-w-0 space-y-2">
        <div class="flex min-w-0 flex-wrap gap-x-4 gap-y-1">
          <%= for fact <- bounded_secondary(@surface, @summary.secondary) do %>
            <span
              data-summary-fact
              class="sf-body-copy min-w-0 max-w-full break-words [overflow-wrap:anywhere] text-xs"
            >
              <span class="sf-metadata mr-1">{fact.label}</span><span
                data-summary-fact-value
                class="min-w-0 max-w-full break-words [overflow-wrap:anywhere]"
              >{fact.value}</span>
            </span>
          <% end %>
        </div>
        <%= if nonblank?(@summary.detail) do %>
          <p
            data-summary-detail
            class="sf-body-copy min-w-0 max-w-full break-words [overflow-wrap:anywhere] text-sm md:max-w-[48ch]"
          >
            {@summary.detail}
          </p>
        <% end %>
        <%= if match?(%DateTime{}, @summary.updated_at) do %>
          <time class="sf-metadata block" datetime={DateTime.to_iso8601(@summary.updated_at)}>
            Updated {format_timestamp(@summary.updated_at)}
          </time>
        <% end %>
      </div>

      <div class="mt-auto flex min-h-[100px] min-w-0 items-end pt-6 text-[var(--sf-topology-text)]">
        <.instrument_visual surface={@surface} status={@summary.status} />
      </div>
    </div>
    """
  end

  attr :surface, :string, required: true
  attr :status, :atom, required: true

  defp instrument_visual(assigns) do
    ~H"""
    <%= case @surface do %>
      <% "swarm" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <ellipse
            cx="180"
            cy="55"
            rx="118"
            ry="35"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
          <ellipse
            cx="180"
            cy="55"
            rx="70"
            ry="20"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".72"
          />
          <path
            d="M64 55h232"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            stroke-dasharray="3 8"
            opacity=".5"
          />
          <%= if @status in [:active, :attention] do %>
            <circle cx="180" cy="20" r="4" fill="currentColor" />
          <% end %>
          <circle cx="298" cy="55" r="3" fill="currentColor" opacity=".55" />
        </svg>
      <% "kanban" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <path d="M24 82H336" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path
            d="M62 82V45M142 82V32M222 82V57M302 82V24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          />
          <path
            d="M62 45h80M142 32h80M222 57h80"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            stroke-dasharray="4 5"
            opacity=".55"
          />
        </svg>
      <% "research" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <circle cx="180" cy="55" r="44" fill="none" stroke="currentColor" stroke-width="1" />
          <circle
            cx="180"
            cy="55"
            r="26"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".72"
          />
          <circle
            cx="180"
            cy="55"
            r="9"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".6"
          />
          <path
            d="M180 10v90M135 55h90M148 23l64 64M212 23l-64 64"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".4"
          />
        </svg>
      <% "calendar" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <circle cx="180" cy="55" r="43" fill="none" stroke="currentColor" stroke-width="1.5" />
          <circle cx="180" cy="55" r="3" fill="currentColor" />
          <path
            d="M180 8v10M180 92v10M133 55h10M217 55h10M147 22l7 9M213 22l-7 9M147 88l7-9M213 88l-7-9"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
        </svg>
      <% "changes" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <path
            d="M20 30H340M20 55H340M20 80H340"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".35"
          />
          <path d="M44 30h58M132 30h92M258 30h58" fill="none" stroke="currentColor" stroke-width="3" />
          <path
            d="M70 55h74M176 55h38M242 55h48"
            fill="none"
            stroke="currentColor"
            stroke-width="3"
            opacity=".72"
          />
          <path
            d="M32 80h88M154 80h84M272 80h56"
            fill="none"
            stroke="currentColor"
            stroke-width="3"
            opacity=".55"
          />
        </svg>
      <% "chat" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <path
            d="M180 14c-51 0-90 19-90 43s39 43 90 43c15 0 29-2 41-6l28 10-8-22c18-7 29-15 29-25 0-24-39-43-90-43Z"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
          <path
            d="M106 58h148"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            stroke-dasharray="4 6"
            opacity=".6"
          />
          <%= if @status in [:active, :ready, :attention] do %>
            <circle cx="180" cy="58" r="5" fill="currentColor" />
          <% end %>
        </svg>
      <% "files" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <path
            d="M180 22v68M180 42 104 76M180 42l76 34"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
          <path
            d="M180 55 134 28M180 55l46-27"
            fill="none"
            stroke="currentColor"
            stroke-width="1"
            opacity=".65"
          />
          <circle cx="180" cy="22" r="5" fill="currentColor" /><circle
            cx="104"
            cy="76"
            r="4"
            fill="currentColor"
            opacity=".7"
          /><circle cx="256" cy="76" r="4" fill="currentColor" opacity=".7" /><circle
            cx="134"
            cy="28"
            r="3"
            fill="currentColor"
            opacity=".55"
          /><circle cx="226" cy="28" r="3" fill="currentColor" opacity=".55" />
        </svg>
      <% "terminal" -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false">
          <path d="M20 70H340" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path
            d="M20 70 64 70 78 37 92 88 110 70 158 70 173 52 188 70 230 70 244 42 258 70 340 70"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linejoin="round"
          />
          <%= if @status == :active do %>
            <circle cx="244" cy="42" r="4" fill="currentColor" />
          <% end %>
        </svg>
      <% _ -> %>
        <svg viewBox="0 0 360 110" class="h-24 w-full" aria-hidden="true" focusable="false"><path
          d="M20 55h320"
          stroke="currentColor"
          stroke-width="1"
        /></svg>
    <% end %>
    """
  end

  attr :project, :any, required: true
  attr :session, :any, required: true
  attr :runtime, :map, required: true
  attr :active_view, :string, required: true
  slot :primary_action, required: true

  def mission_strip(assigns) do
    assigns =
      assigns
      |> assign(:primary_action, Enum.take(assigns.primary_action, 1))
      |> assign(:dispatcher_summary, dispatcher_text(assigns.runtime))

    ~H"""
    <header
      id="mission-strip"
      data-active-view={@active_view}
      class="flex min-w-0 flex-wrap items-center gap-3 border-b border-[var(--sf-hairline)] bg-[var(--sf-canvas-deep)] px-4 py-3 text-[var(--sf-text-primary)] md:gap-4 md:px-6"
    >
      <button
        id="signal-foundry-mark"
        type="button"
        phx-click="toggle_command_palette"
        aria-label="Open IexCode Signal Foundry command palette"
        class="sf-control inline-flex min-h-11 items-center gap-2 px-3 text-sm font-semibold"
      >
        <span aria-hidden="true" class="sf-live-mark h-2 w-2 rounded-full"></span>
        <span>IexCode</span>
      </button>
      <button
        id="all-instruments-trigger"
        type="button"
        phx-click="toggle_command_palette"
        class="sf-control min-h-11 px-3 text-sm"
      >All instruments</button>

      <div class="flex min-w-0 flex-1 basis-[16rem] items-center gap-1">
        <button
          id="project-switchboard-trigger"
          type="button"
          phx-click="toggle_command_palette"
          phx-value-category="projects"
          aria-label="Choose project"
          class="sf-control min-h-11 min-w-0 flex-1 px-3 text-left"
        >
          <span class="sf-metadata block truncate">{@project.name}</span>
        </button>
        <button
          id="session-switchboard-trigger"
          type="button"
          phx-click="toggle_command_palette"
          phx-value-category="sessions"
          aria-label="Choose session"
          class="sf-control min-h-11 min-w-0 flex-1 px-3 text-left"
        >
          <span class="sf-body-copy block truncate font-medium">{@session.title}</span>
        </button>
      </div>

      <div class="flex min-h-11 items-center gap-2" aria-controls="connection-status">
        <span class="sf-success-mark h-2 w-2 rounded-full" aria-hidden="true"></span>
        <span class="sf-body-copy text-sm">Connected</span>
      </div>

      <button
        id="runtime-switchboard-trigger"
        type="button"
        phx-click="toggle_command_palette"
        phx-value-category="settings_account"
        aria-label="Open runtime settings"
        class="sf-control min-h-11 min-w-0 px-3 text-left"
      >
        <div data-runtime-label class="sf-body-copy text-sm font-semibold">
          {runtime_label(@runtime)}
        </div>
        <%= if @dispatcher_summary do %>
          <div data-dispatcher-summary class="sf-metadata mt-1">{@dispatcher_summary}</div>
        <% end %>
      </button>

      <div class="flex items-center gap-1">
        <button
          id="theme-toggle-dark"
          type="button"
          data-phx-theme="dark"
          phx-click={JS.dispatch("phx:set-theme")}
          aria-label="Use dark theme"
          class="sf-control min-h-11 min-w-11 px-3 text-xs"
        >Dark</button>
        <button
          id="theme-toggle-light"
          type="button"
          data-phx-theme="light"
          phx-click={JS.dispatch("phx:set-theme")}
          aria-label="Use light theme"
          class="sf-control min-h-11 min-w-11 px-3 text-xs"
        >Light</button>
      </div>

      <button
        id="command-palette-trigger"
        type="button"
        phx-click="toggle_command_palette"
        aria-label="Open command palette, Cmd/Ctrl+K"
        class="sf-control min-h-11 px-3 text-sm"
      >Cmd/Ctrl+K</button>
      {render_slot(@primary_action)}
      <button
        id="profile-settings-trigger"
        type="button"
        phx-click="toggle_command_palette"
        phx-value-category="settings_account"
        aria-label="Open profile and account settings"
        class="sf-control min-h-11 min-w-11 px-3 text-sm"
      >Profile</button>
    </header>
    """
  end

  defp deck_surfaces, do: ~w(swarm kanban research calendar changes chat files terminal)

  defp summary_for(summaries, surface) do
    summary = if is_map(summaries), do: Map.get(summaries, surface), else: nil

    if valid_summary?(summary, surface) do
      %{
        surface: surface,
        title: canonical_title(surface),
        status: normalize_status(Map.get(summary, :status)),
        primary: Map.get(summary, :primary),
        secondary: Map.get(summary, :secondary),
        detail: Map.get(summary, :detail),
        destination: Map.get(summary, :destination),
        updated_at: Map.get(summary, :updated_at),
        attention?: Map.get(summary, :attention?) == true,
        navigable?: true
      }
    else
      %{
        surface: surface,
        title: canonical_title(surface),
        status: :standby,
        primary: nil,
        secondary: [],
        detail: nil,
        destination: nil,
        updated_at: nil,
        attention?: false,
        navigable?: false
      }
    end
  end

  defp valid_summary?(summary, surface) when is_map(summary) do
    Map.get(summary, :surface) == surface and
      valid_destination?(Map.get(summary, :destination), surface)
  end

  defp valid_summary?(_summary, _surface), do: false

  defp valid_destination?(destination, "research") when is_binary(destination) do
    canonical_path?(destination, ~r|\A/research\z|) or
      canonical_path?(destination, ~r|\A/sessions/[A-Za-z0-9._~-]+/research\z|)
  end

  defp valid_destination?(destination, surface) when is_binary(destination) do
    canonical_path?(destination, Regex.compile!("\\A/\\?view=" <> Regex.escape(surface) <> "\\z")) or
      canonical_path?(
        destination,
        Regex.compile!("\\A/sessions/[A-Za-z0-9._~-]+\\?view=" <> Regex.escape(surface) <> "\\z")
      )
  end

  defp valid_destination?(_destination, _surface), do: false

  defp canonical_path?(destination, regex) do
    Regex.match?(regex, destination) and not control_character?(destination)
  end

  defp control_character?(destination), do: Regex.match?(~r/\p{Cc}/u, destination)

  defp canonical_title("swarm"), do: "Active Mission"
  defp canonical_title("kanban"), do: "Mission Board"
  defp canonical_title("research"), do: "Research Radar"
  defp canonical_title("calendar"), do: "Schedule Chronometer"
  defp canonical_title("changes"), do: "Change Ledger"
  defp canonical_title("chat"), do: "Conversation Loop"
  defp canonical_title("files"), do: "File Atlas"
  defp canonical_title("terminal"), do: "Terminal Scope"

  defp surface_index("swarm"), do: "01"
  defp surface_index("kanban"), do: "02"
  defp surface_index("research"), do: "03"
  defp surface_index("calendar"), do: "04"
  defp surface_index("changes"), do: "05"
  defp surface_index("chat"), do: "06"
  defp surface_index("files"), do: "07"
  defp surface_index("terminal"), do: "08"
  defp surface_index(_), do: "00"

  defp normalize_status(status)
       when status in [:ready, :active, :attention, :empty, :error, :standby], do: status

  defp normalize_status(_), do: :standby

  defp status_key(status), do: status |> normalize_status() |> Atom.to_string()

  defp status_label(:ready), do: "Ready"
  defp status_label(:active), do: "Active"
  defp status_label(:attention), do: "Needs attention"
  defp status_label(:empty), do: "Empty"
  defp status_label(:error), do: "Error"
  defp status_label(:standby), do: "Standby"
  defp status_label(_), do: "Standby"

  defp accessible_card_name(summary), do: "#{summary.title} — #{status_label(summary.status)}"

  defp card_classes(surface) do
    ["sf-instrument", surface == "swarm" && "sf-instrument--featured"]
  end

  defp status_mark_class(:active), do: "sf-live-mark"
  defp status_mark_class(:attention), do: "sf-live-mark"
  defp status_mark_class(:ready), do: "sf-success-mark"
  defp status_mark_class(_), do: "border border-[var(--sf-topology-text)]"

  defp primary_text(summary) do
    if nonblank?(summary.primary),
      do: summary.primary,
      else: status_fallback(summary.surface, summary.status)
  end

  defp status_fallback("swarm", :empty), do: "No active run"
  defp status_fallback("swarm", :active), do: "Mission active"
  defp status_fallback("swarm", :attention), do: "Mission needs attention"
  defp status_fallback("swarm", :ready), do: "Mission ready"
  defp status_fallback("swarm", :standby), do: "Mission standby"
  defp status_fallback("swarm", _status), do: "Mission unavailable"

  defp status_fallback("kanban", :empty), do: "No tasks yet"
  defp status_fallback("kanban", :error), do: "Board unavailable"
  defp status_fallback("kanban", :standby), do: "Board unavailable"
  defp status_fallback("kanban", status), do: "Board #{status_label(status) |> String.downcase()}"

  defp status_fallback("research", :empty), do: "No research runs"
  defp status_fallback("research", :active), do: "Research active"
  defp status_fallback("research", :attention), do: "Research needs attention"
  defp status_fallback("research", :ready), do: "Research ready"
  defp status_fallback("research", _status), do: "Research pending"

  defp status_fallback("calendar", :empty), do: "No scheduled actions"
  defp status_fallback("calendar", :error), do: "Schedule unavailable"
  defp status_fallback("calendar", :standby), do: "Schedule unavailable"

  defp status_fallback("calendar", status),
    do: "Schedule #{status_label(status) |> String.downcase()}"

  defp status_fallback("changes", :standby), do: "Warming · checking Git"
  defp status_fallback("changes", :error), do: "Git unavailable"
  defp status_fallback("changes", :ready), do: "No changes"
  defp status_fallback("changes", :attention), do: "Changes need attention"
  defp status_fallback("changes", :active), do: "Changes detected"
  defp status_fallback("changes", _status), do: "Git unavailable"

  defp status_fallback("chat", :empty), do: "No messages yet"
  defp status_fallback("chat", :ready), do: "Latest message available"

  defp status_fallback("chat", status),
    do: "Conversation #{status_label(status) |> String.downcase()}"

  defp status_fallback("files", :empty), do: "No files discovered"
  defp status_fallback("files", :standby), do: "Standby · files not loaded"
  defp status_fallback("files", :error), do: "Files unavailable"
  defp status_fallback("files", :attention), do: "Files need attention"
  defp status_fallback("files", _status), do: "Files indexed"

  defp status_fallback("terminal", :error), do: "Terminal unavailable"
  defp status_fallback("terminal", :active), do: "Command active"
  defp status_fallback("terminal", :standby), do: "Terminal stopped"
  defp status_fallback("terminal", :attention), do: "Terminal needs attention"
  defp status_fallback("terminal", _status), do: "No command yet"
  defp status_fallback(_surface, status), do: status_label(status)

  defp bounded_secondary(surface, secondary) when is_list(secondary) do
    facts =
      secondary
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn fact ->
        %{
          label: bounded_value(Map.get(fact, :label)),
          value: bounded_value(Map.get(fact, :value))
        }
      end)
      |> Enum.reject(fn fact -> fact.label == "" and fact.value == "" end)

    select_secondary(surface, facts)
  end

  defp bounded_secondary(_surface, _secondary), do: []

  defp select_secondary("research", facts) do
    select_named_facts(facts, ["Level", "Round", "Sources", "Result"], 4)
  end

  defp select_secondary("changes", facts) do
    select_named_facts(
      facts,
      ["Branch", "Conflicts", "Latest test operation", "Tests"],
      3,
      required: ["Latest test operation", "Tests"]
    )
  end

  defp select_secondary(_surface, facts), do: Enum.take(facts, 3)

  defp select_named_facts(facts, labels, limit, opts \\ []) do
    selected = Enum.filter(facts, &(&1.label in labels))
    required_labels = Keyword.get(opts, :required, [])
    required = Enum.filter(selected, &(&1.label in required_labels))
    optional = Enum.reject(selected, &(&1.label in required_labels))

    optional
    |> Enum.take(max(limit - length(required), 0))
    |> Kernel.++(Enum.take(required, limit))
  end

  defp bounded_value(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp bounded_value(value) when is_integer(value), do: Integer.to_string(value)
  defp bounded_value(value) when is_atom(value), do: Atom.to_string(value)
  defp bounded_value(_), do: ""

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_timestamp(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %H:%M")

  defp runtime_label(runtime) when is_map(runtime) do
    governor = nested_value(runtime, :governor)
    governor_state = nested_value(governor, :state)
    state = nested_value(runtime, :state)

    cond do
      governor_state == :critical -> "Critical resource pressure"
      governor_state == :pressure -> "Resource pressure"
      state == :active -> "Runtime active"
      state == :idle -> "Runtime idle"
      true -> "Runtime unavailable"
    end
  end

  defp runtime_label(_), do: "Runtime unavailable"

  defp dispatcher_text(runtime) when is_map(runtime) do
    dispatcher = nested_value(runtime, :dispatcher)
    active = nested_value(dispatcher, :active)
    queued = nested_value(dispatcher, :queued)
    capacity = nested_value(dispatcher, :capacity)

    if valid_count?(active) and valid_count?(queued) and valid_count?(capacity) do
      "#{active} active · #{queued} queued · #{capacity} capacity"
    end
  end

  defp dispatcher_text(_), do: nil

  defp valid_count?(value), do: is_integer(value) and value >= 0

  defp nested_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp nested_value(_, _), do: nil
end
