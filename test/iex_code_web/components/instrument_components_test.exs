defmodule IexCodeWeb.InstrumentComponentsTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest
  alias IexCodeWeb.InstrumentComponents

  @surfaces ~w(swarm kanban research calendar changes chat files terminal)

  defp summary(surface, overrides) do
    Map.merge(
      %{
        surface: surface,
        title: String.capitalize(surface),
        status: :ready,
        primary: "No data",
        secondary: [%{label: "Fact", value: "1"}],
        detail: nil,
        destination: "/?view=#{surface}",
        updated_at: nil,
        attention?: false
      },
      overrides
    )
  end

  test "renders closed eight-card deck in fixed order with semantic navigation" do
    summaries =
      @surfaces
      |> Enum.reverse()
      |> Map.new(&{&1, summary(&1, %{title: String.capitalize(&1)})})

    html =
      render_component(&InstrumentComponents.instrument_deck/1,
        summaries: summaries,
        active_view: "swarm"
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "section#instrument-deck[aria-labelledby='instrument-deck-heading']"
           )

    assert LazyHTML.query(document, "h2#instrument-deck-heading[tabindex='-1']")
    roots = LazyHTML.query(document, "#instrument-deck [data-instrument-surface]")
    assert Enum.count(roots) == 8

    assert Enum.map(roots, &(&1 |> LazyHTML.attribute("data-instrument-surface") |> List.first())) ==
             @surfaces

    assert LazyHTML.query(
             document,
             "#instrument-card-swarm.sf-instrument.sf-instrument--featured"
           )

    assert LazyHTML.query(document, "#instrument-card-research[data-phx-link='patch']")
    assert LazyHTML.query(document, "#instrument-card-research[href='/?view=research']")

    for surface <- @surfaces -- ["research"] do
      assert LazyHTML.query(
               document,
               "#instrument-card-#{surface}[phx-click='switch_tab'][phx-value-tab='#{surface}'][type='button']"
             )
    end

    assert LazyHTML.query(document, "#instrument-card-swarm[aria-pressed='true']")
    assert LazyHTML.query(document, "#instrument-card-research[aria-current='false']")

    assert Enum.count(
             LazyHTML.query(
               document,
               "#instrument-deck svg[aria-hidden='true'][focusable='false']"
             )
           ) == 8

    assert Enum.empty?(LazyHTML.query(document, "#instrument-deck button button"))
    assert Enum.empty?(LazyHTML.query(document, "#instrument-deck button a"))
    assert Enum.empty?(LazyHTML.query(document, "#instrument-deck a button"))
  end

  test "renders factual fallbacks and accessible status names" do
    summaries =
      Map.new(
        @surfaces,
        &{&1, summary(&1, %{title: "Mission #{&1}", status: :empty, primary: nil, detail: nil})}
      )

    html =
      render_component(&InstrumentComponents.instrument_deck/1,
        summaries: summaries,
        active_view: "deck"
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.text(document) =~ "No active run"
    assert LazyHTML.text(document) =~ "Board unavailable"
    assert LazyHTML.text(document) =~ "Terminal unavailable"

    for surface <- @surfaces do
      root = LazyHTML.query(document, "#instrument-card-#{surface}")
      label = root |> LazyHTML.attribute("aria-label") |> List.first()
      assert label =~ "Mission #{surface}"
      assert label =~ "Empty"
    end
  end

  test "mission strip exposes context, runtime truth and switchboard controls" do
    project = %{name: "Signal Project"}
    session = %{title: "Morning Session"}

    runtime = %{
      state: :active,
      governor: %{state: :normal},
      dispatcher: %{active: 2, queued: 1, capacity: 4}
    }

    html =
      render_component(&InstrumentComponents.mission_strip/1,
        project: project,
        session: session,
        runtime: runtime,
        active_view: "deck",
        primary_action: [
          %{
            inner_block: fn _, _ ->
              Phoenix.HTML.raw(
                "<button id='new-mission-button' type='button' phx-click='open_goal_modal'>New mission</button>"
              )
            end
          }
        ]
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "header")
    assert LazyHTML.query(document, "#signal-foundry-mark[phx-click='toggle_command_palette']")

    assert LazyHTML.query(
             document,
             "#all-instruments-trigger[phx-click='toggle_command_palette']"
           )

    assert LazyHTML.text(document) =~ "Signal Project"
    assert LazyHTML.text(document) =~ "Morning Session"
    assert LazyHTML.text(document) =~ "Connected"
    assert LazyHTML.query(document, "[aria-controls='connection-status']")
    assert LazyHTML.text(document) =~ "Runtime active"
    assert LazyHTML.text(document) =~ "2 active · 1 queued · 4 capacity"
    assert LazyHTML.query(document, "#theme-toggle-dark[data-phx-theme='dark']")
    assert LazyHTML.query(document, "#theme-toggle-light[data-phx-theme='light']")

    assert LazyHTML.query(
             document,
             "#command-palette-trigger[phx-click='toggle_command_palette']"
           )

    assert LazyHTML.query(
             document,
             "#profile-settings-trigger[phx-value-category='settings_account']"
           )

    assert Enum.count(LazyHTML.query(document, "#new-mission-button")) == 1
    assert Enum.empty?(LazyHTML.query(document, "nav"))
    assert Enum.empty?(LazyHTML.query(document, "[phx-click='switch_tab']"))
  end

  test "mission runtime pressure precedence and invalid dispatcher fail closed" do
    project = %{name: "Signal Project"}
    session = %{title: "Morning Session"}

    for runtime <- [
          %{state: :idle, governor: %{state: :critical}},
          %{state: :idle, governor: %{state: :pressure}},
          %{state: :idle, governor: %{state: :normal}},
          %{state: :unavailable}
        ] do
      html =
        render_component(&InstrumentComponents.mission_strip/1,
          project: project,
          session: session,
          runtime: runtime,
          active_view: "deck",
          primary_action: [
            %{
              inner_block: fn _, _ ->
                Phoenix.HTML.raw(
                  "<button id='new-mission-button' type='button'>New mission</button>"
                )
              end
            }
          ]
        )

      text = LazyHTML.text(LazyHTML.from_fragment(html))

      expected =
        case runtime do
          %{governor: %{state: :critical}} -> "Critical resource pressure"
          %{governor: %{state: :pressure}} -> "Resource pressure"
          %{state: :idle} -> "Runtime idle"
          _ -> "Runtime unavailable"
        end

      assert text =~ expected
      refute text =~ "active ·"
    end
  end
end
