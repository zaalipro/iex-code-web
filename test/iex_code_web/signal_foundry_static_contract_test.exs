defmodule IexCodeWeb.SignalFoundryStaticContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @source_paths [
    "assets/css/app.css",
    "assets/js/app.js",
    "lib/iex_code_web/components/layouts/root.html.heex",
    "lib/iex_code_web/live/workspace_live.html.heex",
    "lib/iex_code_web/live/settings_live.html.heex",
    "lib/iex_code_web/components/instrument_components.ex",
    "lib/iex_code_web/components/workspace_components.ex",
    "lib/iex_code_web/components/run_components.ex"
  ]

  @heex_paths [
    "lib/iex_code_web/components/layouts/root.html.heex",
    "lib/iex_code_web/live/workspace_live.html.heex",
    "lib/iex_code_web/live/settings_live.html.heex",
    "lib/iex_code_web/components/instrument_components.ex",
    "lib/iex_code_web/components/workspace_components.ex",
    "lib/iex_code_web/components/run_components.ex"
  ]

  @remote_asset_re ~r{https?://[^\s"']+\.(?:css|js|woff2?)(?:[?#][^\s"']*)?}

  @surface_root_re ~r/^(?::where\()?(
    \.sf-instrument(?:--[a-z0-9_-]+)? |
    \.sf-chassis |
    \#instrument-deck |
    \#instrument-workbench-[a-z0-9_-]+ |
    \[id\^=["']instrument-workbench-["']\]
  )(?:$|[\s>+~:.#\[])/ix

  @prohibited_surface_re ~r/rainbow|neon|drop-shadow|(?:linear|radial|conic)-gradient\s*\(/i

  setup_all do
    sources =
      Map.new(@source_paths, fn path ->
        {path, File.read!(Path.join(@root, path))}
      end)

    {:ok, sources: sources}
  end

  test "keeps Tailwind v4 imports, local fonts, and no remote asset or apply directives", %{
    sources: sources
  } do
    css = sources["assets/css/app.css"]

    for declaration <- [
          ~s|@import "tailwindcss" source(none);|,
          ~s|@source "../css";|,
          ~s|@source "../js";|,
          ~s|@source "../../lib/iex_code_web";|
        ] do
      assert css =~ declaration
    end

    refute css =~ ~r/@apply\b/

    for {path, source} <- sources do
      assert Regex.scan(@remote_asset_re, source) == [],
             "remote stylesheet/script/font in #{path}"
    end

    assert File.exists?(Path.join(@root, "priv/static/fonts/doto-variable.woff2"))
    assert File.exists?(Path.join(@root, "priv/static/fonts/OFL.txt"))
  end

  test "HEEx sources use only colocated hooks and one generated local bundle", %{sources: sources} do
    root_path = "lib/iex_code_web/components/layouts/root.html.heex"
    root_bundle_tags = opening_script_tags(sources[root_path]) |> Enum.filter(&root_bundle_tag?/1)

    assert length(root_bundle_tags) == 1

    for path <- @heex_paths do
      for tag <- opening_script_tags(sources[path]) do
        assert colocated_hook_tag?(tag) or (path == root_path and root_bundle_tag?(tag)),
               "unsupported script tag in #{path}: #{tag}"
      end
    end
  end

  test "migrated surface CSS has no legacy visual effects", %{sources: sources} do
    css = strip_css_comments(sources["assets/css/app.css"])

    violations =
      css
      |> leaf_rules()
      |> Enum.filter(&migrated_surface_rule?/1)
      |> Enum.filter(fn {selector, declarations} ->
        Regex.match?(@prohibited_surface_re, selector <> " " <> declarations)
      end)

    assert violations == [],
           "legacy visual effects on Signal Foundry surfaces: #{inspect(violations)}"
  end

  test "literal hook hosts have IDs and ownership-safe ignore attributes", %{sources: sources} do
    for path <- @heex_paths do
      for {hook, tag} <- hook_tags(sources[path]) do
        assert attr_value(tag, "id") not in [nil, ""],
               "#{hook} hook in #{path} is missing an id"

        case hook do
          hook when hook in ["TerminalHook", "LocalTime", "CodeCopy"] ->
            assert attr_value(tag, "phx-update") == "ignore",
                   "#{hook} mutates/replaces host children and must be ignored"

          hook ->
            refute attr_value(tag, "phx-update") == "ignore",
                   "#{hook} must leave LiveView-owned children patchable"
        end
      end
    end
  end

  test "app.js preserves additive hook registration", %{sources: sources} do
    javascript = sources["assets/js/app.js"]
    assert javascript =~ "hooks: {...colocatedHooks, ...Hooks}"

    for hook <- [
          "TerminalHook",
          "InstrumentDeck",
          "ResponsiveSheet",
          "TaskMoveFocus",
          "LocalTime"
        ] do
      assert javascript =~ hook
    end
  end

  test "resume shortcut keeps its migrated multi-class attribute in HEEx list form", %{
    sources: sources
  } do
    workspace = sources["lib/iex_code_web/live/workspace_live.html.heex"]

    assert workspace =~ ~r/id="resume-instrument"[^>]*class=\{\[/s
  end

  test "light theme semantic text tokens meet normal text contrast", %{sources: sources} do
    css = sources["assets/css/app.css"]
    light = css_block(css, ~s|:root[data-theme="light"]|)

    expected = %{
      "--sf-text-primary" => "#202321",
      "--sf-text-secondary" => "#655F58",
      "--sf-live-text" => "#A8321F",
      "--sf-success-text" => "#42624F",
      "--sf-topology-text" => "#4E6170",
      "--sf-code-text" => "#202321"
    }

    for {token, value} <- expected do
      assert light =~ "#{token}: #{value}"
    end

    for foreground <- Map.values(expected) do
      for background <- ["#EAE5DC", "#F3EEE5", "#FBF8F2", "#EEE8DF"] do
        assert contrast_ratio(foreground, background) >= 4.5,
               "#{foreground} does not meet 4.5:1 against #{background}"
      end
    end

    assert contrast_ratio(expected["--sf-code-text"], "#E4DED5") >= 4.5
  end

  test "coarse pointers expose 44px native controls across migrated workbenches", %{
    sources: sources
  } do
    css = sources["assets/css/app.css"]

    coarse =
      css
      |> at_rule_blocks("@media (pointer: coarse)")
      |> Enum.find(
        &(String.contains?(&1, ".sf-instrument") and String.contains?(&1, "min-height: 44px"))
      )

    assert coarse, "missing Signal Foundry coarse-pointer target block"

    selector =
      ~r/:where\([^{}]*\.sf-chassis[^{}]*:is\(a,\s*button,\s*input,\s*textarea,\s*select\)[^{}]*\)/s

    assert Regex.match?(selector, coarse),
           "coarse-pointer rule must cover native controls under .sf-chassis"

    assert coarse =~
             ~r/\[id\^=["']instrument-workbench-["']\][^{}]*:is\(a,\s*button,\s*input,\s*textarea,\s*select\)/s

    assert coarse =~ "min-width: 44px"
    assert coarse =~ "min-height: 44px"
  end

  defp opening_script_tags(source), do: Regex.scan(~r/<script\b[^>]*>/s, source) |> List.flatten()

  defp colocated_hook_tag?(tag),
    do: String.contains?(tag, ":type={Phoenix.LiveView.ColocatedHook}")

  defp root_bundle_tag?(tag) do
    Enum.all?(
      ["defer", "phx-track-static", ~s|type="text/javascript"|, ~s|src={~p"/assets/js/app.js"}|],
      &String.contains?(tag, &1)
    )
  end

  defp hook_tags(source) do
    Regex.scan(~r/(<[a-z][^>]*\bphx-hook\s*=\s*["']([^"']+)["'][^>]*>)/s, source,
      capture: :all_but_first
    )
    |> Enum.map(fn [tag, hook] -> {hook, tag} end)
  end

  defp attr_value(tag, name) do
    regex = ~r/\b#{Regex.escape(name)}\s*=\s*(?:"([^"]+)"|'([^']+)'|\{([^{}]+)\})/s

    case Regex.run(regex, tag, capture: :all_but_first) do
      nil ->
        if Regex.match?(~r/\b#{Regex.escape(name)}\s*=\s*\{\s*[^}>\s]/s, tag),
          do: "expression",
          else: nil

      values ->
        Enum.find(values, &(&1 not in [nil, ""]))
    end
  end

  defp strip_css_comments(css), do: String.replace(css, ~r{/\*.*?\*/}s, "")

  defp leaf_rules(css) do
    Regex.scan(~r/([^{}]+)\{([^{}]*)\}/s, css, capture: :all_but_first)
    |> Enum.map(fn [selector, declarations] ->
      {String.trim(selector), String.trim(declarations)}
    end)
  end

  defp migrated_surface_rule?({selector, _declarations}) do
    selector
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&Regex.match?(@surface_root_re, &1))
  end

  defp css_block(css, selector) do
    case Regex.run(~r/#{Regex.escape(selector)}\s*\{([^{}]*)\}/s, css, capture: :all_but_first) do
      [block] -> block
      _ -> ""
    end
  end

  defp at_rule_blocks(css, at_rule) do
    css
    |> String.split(at_rule)
    |> Enum.drop(1)
    |> Enum.map(fn tail ->
      {_head, body} = take_balanced_block(tail)
      body
    end)
  end

  defp take_balanced_block(text) do
    case :binary.match(text, "{") do
      :nomatch ->
        {text, ""}

      {open, 1} ->
        {body, _rest} =
          consume_balanced(binary_part(text, open + 1, byte_size(text) - open - 1), 1, [])

        {binary_part(text, 0, open), body}
    end
  end

  defp consume_balanced(<<>> = rest, _depth, acc),
    do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_balanced(<<char, rest::binary>>, depth, acc) when char == ?{,
    do: consume_balanced(rest, depth + 1, ["{" | acc])

  defp consume_balanced(<<char, rest::binary>>, 1, acc) when char == ?},
    do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_balanced(<<char, rest::binary>>, depth, acc) when char == ?},
    do: consume_balanced(rest, depth - 1, ["}" | acc])

  defp consume_balanced(<<char, rest::binary>>, depth, acc),
    do: consume_balanced(rest, depth, [<<char>> | acc])

  defp contrast_ratio(foreground, background) do
    {lighter, darker} =
      [relative_luminance(foreground), relative_luminance(background)]
      |> Enum.min_max()
      |> then(fn {minimum, maximum} -> {maximum, minimum} end)

    (lighter + 0.05) / (darker + 0.05)
  end

  defp relative_luminance(<<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    [r, g, b]
    |> Enum.map(&(String.to_integer(&1, 16) / 255))
    |> Enum.map(fn channel ->
      if channel <= 0.04045, do: channel / 12.92, else: :math.pow((channel + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end
end
