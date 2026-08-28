defmodule IexCodeWeb.InstrumentComponentsTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest
  alias IexCodeWeb.InstrumentComponents

  @surfaces ~w(swarm kanban research calendar changes chat files terminal)
  @titles %{
    "swarm" => "Active Mission",
    "kanban" => "Mission Board",
    "research" => "Research Radar",
    "calendar" => "Schedule Chronometer",
    "changes" => "Change Ledger",
    "chat" => "Conversation Loop",
    "files" => "File Atlas",
    "terminal" => "Terminal Scope"
  }

  defp summary(surface, overrides \\ %{}) do
    Map.merge(
      %{
        surface: surface,
        title: Map.fetch!(@titles, surface),
        status: :ready,
        primary: "Ready summary",
        secondary: [%{label: "Fact", value: "1"}],
        detail: nil,
        destination: if(surface == "research", do: "/research", else: "/?view=#{surface}"),
        updated_at: nil,
        attention?: false
      },
      overrides
    )
  end

  defp summaries(overrides) do
    Map.new(@surfaces, fn surface ->
      {surface, Map.merge(summary(surface, %{}), Map.get(overrides, surface, %{}))}
    end)
  end

  defp render_deck(overrides \\ %{}, active_view \\ "deck") do
    InstrumentComponents.instrument_deck(%{
      summaries: summaries(overrides),
      active_view: active_view
    })
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp render_mission(runtime, primary_action \\ nil) do
    primary_action =
      primary_action ||
        [
          %{
            inner_block: fn _, _ ->
              Phoenix.HTML.raw(
                "<button id='new-mission-button' type='button' phx-click='open_goal_modal'>New mission</button>"
              )
            end
          }
        ]

    render_component(&InstrumentComponents.mission_strip/1,
      project: %{name: "Signal Project"},
      session: %{title: "Morning Session"},
      runtime: runtime,
      active_view: "deck",
      primary_action: primary_action
    )
    |> LazyHTML.from_fragment()
  end

  test "renders the closed eight-card deck in fixed order with semantic navigation" do
    scrambled =
      @surfaces
      |> Enum.reverse()
      |> Map.new(&{&1, summary(&1)})
      |> Map.put("unknown", %{surface: "unknown", primary: "Must not render"})

    document =
      render_component(&InstrumentComponents.instrument_deck/1,
        summaries: scrambled,
        active_view: "swarm"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(
             document,
             "section#instrument-deck[aria-labelledby='instrument-deck-heading'][tabindex='-1']"
           )

    assert document
           |> LazyHTML.query("h2#instrument-deck-heading[tabindex='-1']")
           |> LazyHTML.text() =~
             "Instrument Deck"

    assert LazyHTML.query(document, "#instrument-deck .sf-deck-grid")
    roots = LazyHTML.query(document, "#instrument-deck [data-instrument-surface]")
    assert Enum.count(roots) == 8

    assert Enum.map(roots, &(&1 |> LazyHTML.attribute("data-instrument-surface") |> List.first())) ==
             @surfaces

    assert Enum.count(LazyHTML.query(document, ".sf-instrument--featured")) == 1

    assert LazyHTML.query(
             document,
             "#instrument-card-swarm.sf-instrument.sf-instrument--featured"
           )

    assert LazyHTML.query(
             document,
             "a#instrument-card-research[href='/research'][data-phx-link='patch']"
           )

    for surface <- @surfaces -- ["research"] do
      assert LazyHTML.query(
               document,
               "button#instrument-card-#{surface}[type='button'][phx-click='switch_tab'][phx-value-tab='#{surface}']"
             )
    end

    assert Enum.count(
             LazyHTML.query(
               document,
               "#instrument-deck svg[aria-hidden='true'][focusable='false']"
             )
           ) == 8
  end

  test "uses active_view for every card's pressed or current state" do
    for active_view <- ["deck" | @surfaces] do
      document = render_deck(%{}, active_view)

      for surface <- @surfaces -- ["research"] do
        expected = to_string(active_view == surface)

        assert LazyHTML.query(
                 document,
                 "#instrument-card-#{surface}[aria-pressed='#{expected}']"
               )
      end

      expected_current = if(active_view == "research", do: "page", else: "false")

      assert LazyHTML.query(
               document,
               "#instrument-card-research[aria-current='#{expected_current}']"
             )
    end
  end

  test "card roots have accessible title and status names and no nested interaction" do
    document = render_deck()

    for surface <- @surfaces do
      root = LazyHTML.query(document, "#instrument-card-#{surface}[data-status='ready']")
      label = root |> LazyHTML.attribute("aria-label") |> List.first()
      assert label =~ Map.fetch!(@titles, surface)
      assert label =~ "Ready"
    end

    forbidden = [
      "button button",
      "button a",
      "button input",
      "button select",
      "button textarea",
      "button details",
      "a button",
      "a a",
      "a input",
      "a select",
      "a textarea",
      "a details",
      "[data-instrument-surface] [role='button']",
      "[data-instrument-surface] [tabindex]:not([tabindex='-1'])"
    ]

    for selector <- forbidden do
      assert Enum.empty?(LazyHTML.query(document, "#instrument-deck #{selector}"))
    end
  end

  test "nil primary fallbacks distinguish valid empty, standby, ready, and error states" do
    cases = [
      {"kanban", :empty, "No tasks yet"},
      {"kanban", :error, "Board unavailable"},
      {"calendar", :empty, "No scheduled actions"},
      {"calendar", :error, "Schedule unavailable"},
      {"files", :empty, "No files discovered"},
      {"files", :standby, "Standby · files not loaded"},
      {"terminal", :ready, "No command yet"},
      {"terminal", :empty, "No command yet"},
      {"terminal", :error, "Terminal unavailable"},
      {"changes", :standby, "Warming · checking Git"},
      {"changes", :error, "Git unavailable"},
      {"changes", :ready, "No changes"}
    ]

    for {surface, status, expected} <- cases do
      document = render_deck(%{surface => %{status: status, primary: nil}})

      assert document
             |> LazyHTML.query("#instrument-card-#{surface} [data-summary-primary]")
             |> LazyHTML.text() =~ expected
    end
  end

  test "surface-aware facts keep Research result and Change Ledger test outcome" do
    research = [
      %{label: "Level", value: "High"},
      %{label: "Round", value: "2/3 complete"},
      %{label: "Sources", value: "12"},
      %{label: "Result", value: "Ready"}
    ]

    changes = [
      %{label: "Branch", value: "main"},
      %{label: "Staged", value: "1"},
      %{label: "Unstaged", value: "2"},
      %{label: "Untracked", value: "3"},
      %{label: "Conflicts", value: "0"},
      %{label: "Latest test operation", value: "completed · 81 ms"}
    ]

    document =
      render_deck(%{
        "research" => %{secondary: research},
        "changes" => %{secondary: changes, detail: "Showing bounded Git status"},
        "files" => %{primary: "500+ files indexed"}
      })

    research_facts = LazyHTML.query(document, "#instrument-card-research [data-summary-fact]")
    assert Enum.count(research_facts) == 4
    assert research_facts |> LazyHTML.text() =~ "ResultReady"

    changes_facts = LazyHTML.query(document, "#instrument-card-changes [data-summary-fact]")
    assert Enum.count(changes_facts) <= 3
    assert changes_facts |> LazyHTML.text() =~ "Latest test operationcompleted · 81 ms"

    assert document
           |> LazyHTML.query("#instrument-card-changes [data-summary-detail]")
           |> LazyHTML.text() =~ "Showing bounded Git status"

    assert document
           |> LazyHTML.query("#instrument-card-files [data-summary-primary]")
           |> LazyHTML.text() =~ "500+ files indexed"

    no_test =
      render_deck(%{
        "changes" => %{
          secondary:
            List.replace_at(changes, 5, %{label: "Tests", value: "No test operation recorded"})
        }
      })

    assert no_test
           |> LazyHTML.query("#instrument-card-changes [data-summary-fact]")
           |> LazyHTML.text() =~ "TestsNo test operation recorded"
  end

  test "long bounded summary values expose structural wrapping guards" do
    unbroken = String.duplicate("x", 160)

    document =
      render_deck(%{
        "terminal" => %{
          primary: unbroken,
          secondary: [%{label: "Command", value: unbroken}],
          detail: unbroken
        }
      })

    for selector <- [
          "[data-summary-primary]",
          "[data-summary-fact-value]",
          "[data-summary-detail]"
        ] do
      node = LazyHTML.query(document, "#instrument-card-terminal #{selector}")
      classes = LazyHTML.attribute(node, "class") |> List.first()
      assert classes =~ "min-w-0"
      assert classes =~ "break-words"
      assert classes =~ "[overflow-wrap:anywhere]"
    end
  end

  test "mismatched summary surface fails closed to descriptor and invalid Research destination disables navigation" do
    document =
      render_deck(%{
        "kanban" => %{surface: "files", title: "Wrong title", status: :empty, primary: nil},
        "research" => %{destination: "#"}
      })

    kanban = LazyHTML.query(document, "#instrument-card-kanban[data-instrument-surface='kanban']")
    assert LazyHTML.text(kanban) =~ "Mission Board"

    assert kanban |> LazyHTML.query("[data-summary-primary]") |> LazyHTML.text() =~
             "Board unavailable"

    assert LazyHTML.query(
             document,
             "button#instrument-card-research[disabled][aria-disabled='true']"
           )

    assert Enum.empty?(LazyHTML.query(document, "a#instrument-card-research"))
  end

  test "destination validation accepts canonical root and session shapes" do
    session_id = "0c47c96c-81f0-4fd3-b722-4e76f3f80db4"
    assert LazyHTML.query(render_deck(), "#instrument-card-kanban[phx-click='switch_tab']")

    overrides =
      Map.new(@surfaces, fn surface ->
        destination =
          if surface == "research",
            do: "/sessions/#{session_id}/research",
            else: "/sessions/#{session_id}?view=#{surface}"

        {surface, %{destination: destination}}
      end)

    document = render_deck(overrides)

    for surface <- @surfaces -- ["research"] do
      assert LazyHTML.query(document, "#instrument-card-#{surface}[phx-click='switch_tab']")
    end

    assert LazyHTML.query(
             document,
             "a#instrument-card-research[href='/sessions/#{session_id}/research']"
           )
  end

  test "invalid destinations disable cards without links or events" do
    cases = [
      {"research", "/wrong"},
      {"research", "//host/research"},
      {"research", "/research?extra=1"},
      {"research", "/research#fragment"},
      {"kanban", "/?view=files"},
      {"kanban", "/?view=kanban&extra=1"},
      {"kanban", "/?view=kanban#fragment"},
      {"kanban", "/sessions/id?view=kanban&extra=1"},
      {"kanban", "/sessions//?view=kanban"}
    ]

    for {surface, destination} <- cases do
      document = render_deck(%{surface => %{destination: destination}})

      assert LazyHTML.query(
               document,
               "button#instrument-card-#{surface}[disabled][aria-disabled='true']"
             )

      assert Enum.empty?(LazyHTML.query(document, "a#instrument-card-#{surface}"))
      assert Enum.empty?(LazyHTML.query(document, "#instrument-card-#{surface}[phx-click]"))
      assert Enum.empty?(LazyHTML.query(document, "#instrument-card-#{surface}[phx-value-tab]"))
    end
  end

  test "mission strip exposes exact controls, context, and only the first primary slot" do
    primary_action = [
      %{
        inner_block: fn _, _ ->
          Phoenix.HTML.raw("<button id='new-mission-button' type='button'>New mission</button>")
        end
      },
      %{
        inner_block: fn _, _ ->
          Phoenix.HTML.raw("<button id='forbidden-second-action' type='button'>Second</button>")
        end
      }
    ]

    document =
      render_mission(
        %{
          state: :active,
          governor: %{state: :normal},
          dispatcher: %{active: 2, queued: 1, capacity: 4}
        },
        primary_action
      )

    assert LazyHTML.query(document, "header#mission-strip[data-active-view='deck']")
    assert LazyHTML.query(document, "#signal-foundry-mark[phx-click='toggle_command_palette']")

    assert LazyHTML.query(
             document,
             "#all-instruments-trigger[phx-click='toggle_command_palette']"
           )

    assert LazyHTML.text(document) =~ "Signal Project"
    assert LazyHTML.text(document) =~ "Morning Session"
    assert LazyHTML.text(document) =~ "Connected"
    assert LazyHTML.query(document, "[aria-controls='connection-status']")
    assert Enum.empty?(LazyHTML.query(document, "#connection-status"))
    assert Enum.empty?(LazyHTML.query(document, "[role='status']"))
    assert Enum.empty?(LazyHTML.query(document, "[aria-live]"))

    for {id, theme} <- [{"theme-toggle-dark", "dark"}, {"theme-toggle-light", "light"}] do
      button = LazyHTML.query(document, "button##{id}[data-phx-theme='#{theme}']")

      assert button |> LazyHTML.attribute("phx-click") |> List.first() ==
               ~s([["dispatch",{"event":"phx:set-theme"}]])
    end

    assert LazyHTML.query(
             document,
             "#command-palette-trigger[phx-click='toggle_command_palette']"
           )

    assert LazyHTML.query(
             document,
             "#profile-settings-trigger[phx-click='toggle_command_palette'][phx-value-category='settings_account']"
           )

    assert Enum.count(LazyHTML.query(document, "#new-mission-button")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#forbidden-second-action"))
    assert Enum.empty?(LazyHTML.query(document, "nav"))
    assert Enum.empty?(LazyHTML.query(document, "[phx-click='switch_tab']"))
  end

  test "mission runtime label follows the complete precedence table" do
    cases = [
      {%{state: :active, governor: %{state: :critical}}, "Critical resource pressure"},
      {%{state: :active, governor: %{state: :pressure}}, "Resource pressure"},
      {%{state: :active, governor: %{state: :normal}}, "Runtime active"},
      {%{state: :idle, governor: %{state: :normal}}, "Runtime idle"},
      {%{state: :unavailable}, "Runtime unavailable"},
      {%{"state" => "malformed", "governor" => []}, "Runtime unavailable"}
    ]

    for {runtime, expected} <- cases do
      assert render_mission(runtime)
             |> LazyHTML.query("[data-runtime-label]")
             |> LazyHTML.text() =~ expected
    end
  end

  test "dispatcher triple renders only when every member is a nonnegative integer" do
    valid = %{state: :active, dispatcher: %{active: 0, queued: 1, capacity: 4}}

    assert render_mission(valid)
           |> LazyHTML.query("[data-dispatcher-summary]")
           |> LazyHTML.text() =~ "0 active · 1 queued · 4 capacity"

    invalid_dispatchers = [
      %{queued: 1, capacity: 4},
      %{active: nil, queued: 1, capacity: 4},
      %{active: -1, queued: 1, capacity: 4},
      %{active: "1", queued: 1, capacity: 4},
      %{active: 1, capacity: 4},
      %{active: 1, queued: nil, capacity: 4},
      %{active: 1, queued: -1, capacity: 4},
      %{active: 1, queued: 1.0, capacity: 4},
      %{active: 1, queued: 1},
      %{active: 1, queued: 1, capacity: nil},
      %{active: 1, queued: 1, capacity: -1},
      %{active: 1, queued: 1, capacity: "4"}
    ]

    for dispatcher <- invalid_dispatchers do
      document = render_mission(%{state: :active, dispatcher: dispatcher})
      assert Enum.empty?(LazyHTML.query(document, "[data-dispatcher-summary]"))
    end
  end
end
