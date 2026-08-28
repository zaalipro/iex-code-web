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
    assert css =~ ~s(:root[data-theme="dark"])
    assert css =~ ~s(:root[data-theme="light"])

    for value <- [
          "#171514",
          "#101214",
          "#0B0E10",
          "#151616",
          "#1D1F20",
          "#F4EFE7",
          "#918B84",
          "rgba(255, 255, 255, 0.10)",
          "#F6532E",
          "#9EBDA7",
          "#9DAEC2",
          "#EAE5DC",
          "#F3EEE5",
          "#FBF8F2",
          "#EEE8DF",
          "#202321",
          "#655F58",
          "rgba(23, 25, 26, 0.14)",
          "#D74628",
          "#A8321F",
          "#60836E",
          "#42624F",
          "#4E6170"
        ] do
      assert css =~ value, "expected the approved theme value #{value}"
    end

    assert css =~
             ~r/@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root:not\(\[data-theme\]\)\s*\{/s

    assert css =~
             ~r/@media\s*\(prefers-color-scheme:\s*light\)\s*\{\s*:root:not\(\[data-theme\]\)\s*\{/s
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
    assert css =~ ~r/:focus-visible\s*\{[^}]*outline:/s
    assert rule(css, ".sf-command-dock") =~ "safe-area-inset-bottom"

    assert length(Regex.scan(~r/radial-gradient\(/, signal_foundry_section(css))) == 1
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
      |> String.split("@media (prefers-reduced-motion: reduce)")
      |> List.last()

    assert reduced_motion =~ ".sf-instrument"
    assert reduced_motion =~ ".sf-workbench-enter"
    assert reduced_motion =~ ".sf-waveform-travel"
    assert reduced_motion =~ "scroll-behavior: auto"
    assert reduced_motion =~ "transform: none"
    assert reduced_motion =~ "animation: none"
    assert reduced_motion =~ "transition: none"
  end

  test "raises Signal Foundry touch targets to 44px on coarse pointers", %{css: css} do
    assert css =~
             ~r/@media\s*\(pointer:\s*coarse\)\s*\{.*?min-width:\s*44px;.*?min-height:\s*44px;/s
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

  defp signal_foundry_section(css) do
    [_legacy, section] = String.split(css, "Signal Foundry material system", parts: 2)
    section
  end
end
