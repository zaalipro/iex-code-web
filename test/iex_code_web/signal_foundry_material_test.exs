defmodule IexCodeWeb.SignalFoundryMaterialTest do
  use ExUnit.Case, async: true

  @css_path Path.expand("../../assets/css/app.css", __DIR__)
  @font_path Path.expand("../../priv/static/fonts/doto-variable.woff2", __DIR__)
  @license_path Path.expand("../../priv/static/fonts/OFL.txt", __DIR__)

  setup_all do
    {:ok, css: File.read!(@css_path)}
  end

  test "keeps the Tailwind v4 sources and serves Doto locally", %{css: css} do
    for declaration <- [
          ~s|@import "tailwindcss" source(none);|,
          ~s|@source "../css";|,
          ~s|@source "../js";|,
          ~s|@source "../../lib/iex_code_web";|
        ] do
      assert css =~ declaration
    end

    assert css =~ ~r/@font-face\s*\{[^}]*font-family:\s*["']Doto["'][^}]*\}/s
    assert css =~ ~s|url("/fonts/doto-variable.woff2")|
    assert css =~ ~r/font-display:\s*swap/

    refute css =~ "fonts.gstatic.com"
    refute css =~ "fonts.googleapis.com"

    refute css =~
             ~r/https?:\/\/[^"'\s]+\.(?:css|js|woff2?)(?:[?#][^"'\s]*)?/i
  end

  test "vendors the approved Doto bytes and OFL license" do
    assert File.exists?(@font_path)
    assert File.exists?(@license_path)

    assert sha256(@font_path) ==
             "1c7d9f9c86f929fb4469b8a93510a65936d3bdc49e0a1a6878ae2b0f3f47c7c2"

    assert sha256(@license_path) ==
             "26a7b58bdba6cda8a78ca6e8b3791d8013b8abc6d5e6519f84193893aee02020"

    assert File.read!(@license_path) =~
             ~r/^Copyright 2024 The Doto Project Authors/

    if executable = System.find_executable("file") do
      {description, 0} = System.cmd(executable, [@font_path])
      assert description =~ "Web Open Font Format"
    end
  end

  test "defines explicit and system-default Signal Foundry theme tokens", %{css: css} do
    dark_tokens = css_block(css, ~s|:root[data-theme="dark"]|)
    light_tokens = css_block(css, ~s|:root[data-theme="light"]|)

    for declaration <- [
          "--sf-canvas-ambient: #171514",
          "--sf-canvas-deep: #101214",
          "--sf-instrument: #0B0E10",
          "--sf-instrument-raised: #151616",
          "--sf-raised-control: #1D1F20",
          "--sf-text-primary: #F4EFE7",
          "--sf-text-secondary: #918B84",
          "--sf-hairline: rgba(255, 255, 255, 0.10)",
          "--sf-live-mark: #F6532E",
          "--sf-live-text: #F6532E",
          "--sf-success-mark: #9EBDA7",
          "--sf-success-text: #9EBDA7",
          "--sf-topology-text: #9DAEC2",
          "--sf-code-surface: #101214",
          "--sf-code-text: #F4EFE7",
          "--sf-ambient-glow: rgba(244, 239, 231, 0.055)",
          "--sf-inset-highlight: rgba(255, 255, 255, 0.075)",
          "--sf-shadow: rgba(0, 0, 0, 0.46)",
          "--sf-focus-ring: #F4EFE7"
        ] do
      assert dark_tokens =~ declaration, "expected dark token #{declaration}"
    end

    for declaration <- [
          "--sf-canvas-ambient: #EAE5DC",
          "--sf-canvas-deep: #EAE5DC",
          "--sf-instrument: #F3EEE5",
          "--sf-instrument-raised: #FBF8F2",
          "--sf-raised-control: #EEE8DF",
          "--sf-text-primary: #202321",
          "--sf-text-secondary: #655F58",
          "--sf-hairline: rgba(23, 25, 26, 0.14)",
          "--sf-live-mark: #D74628",
          "--sf-live-text: #A8321F",
          "--sf-success-mark: #60836E",
          "--sf-success-text: #42624F",
          "--sf-topology-text: #4E6170",
          "--sf-code-surface: #E4DED5",
          "--sf-code-text: #202321",
          "--sf-ambient-glow: rgba(255, 253, 247, 0.68)",
          "--sf-inset-highlight: rgba(255, 255, 255, 0.88)",
          "--sf-shadow: rgba(0, 0, 0, 0.16)",
          "--sf-focus-ring: #202321"
        ] do
      assert light_tokens =~ declaration, "expected light token #{declaration}"
    end

    refute light_tokens =~ "rgba(91, 70, 44"

    for {scheme, explicit_tokens} <- [{"dark", dark_tokens}, {"light", light_tokens}] do
      media_block =
        css
        |> at_rule_blocks("@media (prefers-color-scheme: #{scheme})")
        |> Enum.find(&String.contains?(&1, ":root:not([data-theme])"))

      assert media_block, "missing no-theme #{scheme} media default"

      default_tokens = css_block(media_block, ":root:not([data-theme])")

      for declaration <- Regex.scan(~r/--sf-[^;]+/, explicit_tokens) |> List.flatten() do
        assert default_tokens =~ declaration,
               "expected no-theme #{scheme} default to mirror #{declaration}"
      end
    end
  end

  test "exposes solid tactile materials with accessible type and geometry", %{css: css} do
    for class <- [
          ".sf-display",
          ".sf-instrument",
          ".sf-chassis",
          ".sf-pill",
          ".sf-command-dock",
          ".sf-focus-surface",
          ".sf-deck-grid",
          ".sf-ambient-field",
          ".sf-instrument--featured"
        ] do
      assert css =~ class, "expected the public material class #{class}"
    end

    assert rule(css, ".sf-display") =~ ~r/font-family:\s*["']Doto["']/
    assert rule(css, ".sf-display") =~ ~r/font-size:\s*clamp\(1\.75rem,[^,]+,\s*4rem\)/
    assert rule(css, ".sf-instrument") =~ "border-radius: 22px"
    assert rule(css, ".sf-chassis") =~ ~r/border-radius:\s*(?:28|29|30)px/
    assert rule(css, ".sf-focus-surface") =~ ~r/border-radius:\s*(?:28|29|30)px/
    assert css =~ ~r/\.sf-control\s*\{[^}]*border-radius:\s*(?:14|15|16|17|18)px/s
    assert rule(css, ".sf-pill") =~ "border-radius: 9999px"
    assert rule(css, ".sf-command-dock") =~ "border-radius: 9999px"
    assert css =~ ~r/box-shadow:\s*inset\s+0\s+1px\s+0[^;]*,[^;]*(?:48|56|64|72|80)px/s

    refute rule(css, ".sf-instrument") =~ "gradient("
    refute rule(css, ".sf-chassis") =~ "gradient("
    refute rule(css, ".sf-focus-surface") =~ "gradient("

    assert rule(css, ".sf-body-copy") =~ "font-size: 0.875rem"
    assert rule(css, ".sf-metadata") =~ "font-size: 0.75rem"
    assert rule(css, ".sf-code-surface") =~ ~r/overflow:\s*auto/
    assert rule(css, ".sf-command-dock") =~ "safe-area-inset-bottom"

    ambient_rule = rule(css, ".sf-ambient-field")
    assert length(Regex.scan(~r/radial-gradient\(/, ambient_rule)) == 1

    for material <- [".sf-instrument", ".sf-chassis", ".sf-focus-surface", ".sf-command-dock"] do
      assert rule(css, material) =~ "var(--sf-shadow)",
             "expected #{material} to consume the neutral shared shadow"
    end
  end

  test "Signal Foundry focus rings win the legacy cascade on real controls", %{css: css} do
    focus_rule =
      css_block(
        css,
        ~s|:where(.sf-instrument, .sf-pill, .sf-control, .sf-command-dock, .sf-focus-surface, .sf-chassis):is(button, a, input, textarea, select, [role="button"]):focus-visible|
      )

    assert focus_rule =~ "outline: 2px solid var(--sf-focus-ring) !important"
    assert focus_rule =~ "outline-offset: 3px !important"

    assert css =~
             ~s|:where(.sf-instrument, .sf-pill, .sf-control, .sf-command-dock, .sf-focus-surface, .sf-chassis) :where(button, a, input, textarea, select, [role="button"]):focus-visible|
  end

  test "lays out the featured instrument across the approved responsive units", %{css: css} do
    assert rule(css, ".sf-deck-grid") =~
             ~r/grid-template-columns:\s*repeat\(1,\s*minmax\(0,\s*1fr\)\)/

    assert rule(css, ".sf-instrument--featured") =~ ~r/grid-column:\s*span\s+1/

    assert css =~
             ~r/@media\s*\(min-width:\s*40rem\)\s*\{.*?\.sf-deck-grid\s*\{[^}]*repeat\(2,\s*minmax\(0,\s*1fr\)\).*?\.sf-instrument--featured\s*\{[^}]*grid-column:\s*span\s+2/s

    assert css =~
             ~r/@media\s*\(min-width:\s*64rem\)\s*\{.*?\.sf-deck-grid\s*\{[^}]*repeat\(3,\s*minmax\(0,\s*1fr\)\)/s

    assert css =~
             ~r/@media\s*\(min-width:\s*90rem\)\s*\{.*?\.sf-deck-grid\s*\{[^}]*repeat\(4,\s*minmax\(0,\s*1fr\)\)/s

    assert css =~
             ~r/@media\s*\(max-width:\s*39\.99rem\)\s*\{.*?\.sf-deck-grid\s*\{[^}]*perspective:\s*none.*?\.sf-instrument[^\{]*\{[^}]*transform:\s*none/s
  end

  test "bounds optical movement and removes choreography for reduced motion", %{css: css} do
    assert css =~
             ~r/@media\s*\(min-width:\s*80rem\)\s*\{.*?--sf-card-offset-y:\s*-?1px.*?--sf-card-tilt:\s*-?0\.15deg/s

    assert css =~ ~r/translateY\(calc\(var\(--sf-card-offset-y\)\s*-\s*3px\)\)/

    assert rule(css, ".sf-workbench-enter") =~
             ~r/animation:\s*sf-workbench-enter\s+180ms\s+cubic-bezier/

    refute rule(css, ".sf-instrument") =~ ~r/animation\s*:/

    reduced_motion =
      css
      |> at_rule_blocks("@media (prefers-reduced-motion: reduce)")
      |> Enum.find(&String.contains?(&1, ".sf-workbench-enter"))

    assert reduced_motion, "missing Signal Foundry reduced-motion block"
    assert css_block(reduced_motion, ".sf-deck-grid") =~ "perspective: none"

    reduced_instrument = css_block(reduced_motion, ".sf-instrument,")
    assert reduced_instrument =~ "transform: none"
    assert reduced_instrument =~ "transition: none"

    reduced_entry = css_block(reduced_motion, ".sf-workbench-enter,")
    assert reduced_entry =~ "animation: none"
    assert reduced_entry =~ "transition: none"

    reduced_scroll = css_block(reduced_motion, ".sf-smooth-scroll,")
    assert reduced_scroll =~ "scroll-behavior: auto"
  end

  test "raises Signal Foundry touch targets to 44px on coarse pointers", %{css: css} do
    coarse_pointer =
      at_rule_blocks(css, "@media (pointer: coarse)")
      |> Enum.find(&String.contains?(&1, "min-height: 44px"))

    assert coarse_pointer

    target_rule =
      css_block(
        coarse_pointer,
        ~s|:where(.sf-instrument:is(a, button, [role="button"]), .sf-control, .sf-pill, .sf-command-dock :is(a, button, input, textarea, select), .sf-focus-surface :is(a, button, input, textarea, select))|
      )

    assert target_rule =~ "min-width: 44px"
    assert target_rule =~ "min-height: 44px"
  end

  test "research workbench owns bounded scroll and exact tablet and phone compositions", %{
    css: css
  } do
    research_chassis = rule(css, "#instrument-workbench-research")
    assert research_chassis =~ "height: 100%"
    assert research_chassis =~ "min-height: 0"
    assert research_chassis =~ "overflow: hidden"

    research_page = rule(css, "#deep-research-page")
    assert research_page =~ "overflow-x: hidden"
    assert research_page =~ "overflow-y: auto"

    assert css =~
             ~r/@media\s*\(max-width:\s*64rem\)\s*\{.*?#instrument-workbench-research \.sf-workbench-fields\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s

    assert css =~
             ~r/@media\s*\(max-width:\s*39\.99rem\)\s*\{.*?#instrument-workbench-research\s*\{[^}]*width:\s*100%[^}]*border-radius:\s*0/s

    assert rule(css, ".sf-dag-projection summary") =~ "min-height: 44px"
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp rule(css, selector) do
    escaped_selector = Regex.escape(selector)

    case Regex.run(~r/(?:^|\n)#{escaped_selector}\s*\{([^}]*)\}/s, css, capture: :all_but_first) do
      [declarations] -> declarations
      nil -> flunk("missing CSS rule for #{selector}")
    end
  end

  defp at_rule_blocks(css, prelude) do
    escaped_prelude = Regex.escape(prelude)

    ~r/^#{escaped_prelude}\s*\{(.*?)^\}/ms
    |> Regex.scan(css, capture: :all_but_first)
    |> List.flatten()
  end

  defp css_block(css, prelude) do
    case String.split(css, prelude, parts: 2) do
      [_before, after_prelude] ->
        case Regex.run(~r/\{([^}]*)\}/s, after_prelude, capture: :all_but_first) do
          [declarations] -> declarations
          nil -> flunk("missing declarations for CSS block #{prelude}")
        end

      [_all_css] ->
        flunk("missing CSS block for #{prelude}")
    end
  end
end
