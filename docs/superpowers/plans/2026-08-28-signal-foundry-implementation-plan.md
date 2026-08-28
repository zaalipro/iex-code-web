# Signal Foundry UI/UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved Signal Foundry Instrument Deck, dark/light material system, focused workbench chassis, and progressive workbench redesign without changing IexCode's execution, persistence, safety, or routing contracts.

**Architecture:** Execute four dependency-ordered, independently testable slices. Slice A establishes flash-free themes and canonical view state. Slice B adds bounded summary data and the Instrument Deck. Slice C adds persistent resume/focus behavior, the switchboard, command dock, and responsive chassis. Slice D migrates each existing workbench family behind the chassis. Every slice keeps the prior slice deployable and ends with targeted tests plus `mix assets.build`.

**Tech Stack:** Phoenix 1.8.8, LiveView 1.2, Elixir 1.15+, Ecto/SQLite, Tailwind CSS v4, bundled `app.js`/`app.css`, xterm.js, inline SVG, Ego Lite browser smoke tests.

**Spec:** `docs/superpowers/specs/2026-08-28-signal-foundry-redesign-design.md`

## Global Constraints

- Preserve the approved Signal Foundry dark matte-black instrument language and bone-ceramic light language.
- Use `#171514`/`#101214` dark canvas layers, `#EAE5DC`/`#F3EEE5` light canvas layers, and vermilion only as a rare semantic signal.
- Use 22px instrument radii, 28–30px chassis radii, 14–18px controls, and full-pill action docks.
- Do not add neon, rainbow status surfaces, colored card glows, fabricated metrics, demo data, or nested card chrome.
- Preserve Phoenix 1.8 `<Layouts.app flash={@flash} current_scope={@current_scope}>` wrappers and authenticated-route rules.
- Preserve the Tailwind v4 imports/sources in `assets/css/app.css`; never use `@apply`.
- Use only bundled `assets/js/app.js` and `assets/css/app.css`; never add remote scripts/stylesheets or raw `<script>` tags in HEEx.
- Use `<.icon>` for icons, `<.input>` and `to_form/2` for forms, semantic controls, and unique DOM IDs.
- Keep existing routes, durable run behavior, workspace locks, terminal/PTy behavior, research artifacts, credentials, and authorization unchanged.
- Preserve existing LiveView event names and test-sensitive IDs unless the spec explicitly retires the duplicate workspace settings modal.
- Use LiveView streams for collections; never enumerate streams in summaries or templates.
- Tests use `start_supervised!/1`, `:sys.get_state/1`, `has_element?/2`, and `element/2`; do not add `Process.sleep/1`, `Process.alive?/1`, or raw HTML assertions for new coverage.
- Browser smoke tests use Ego Lite only, never wipe cookies/sessions, and close the Ego Lite space/session after verification.
- Run `mix precommit` only after all implementation and targeted verification work is complete; also run `mix assets.build` because `precommit` does not include it.

## Dependency Graph and Slice Boundaries

```text
Slice A: Theme + canonical URL/view state
        ↓
Slice B: bounded summaries + Instrument Deck
        ↓
Slice C: resume/focus + switchboard + command dock + chassis
        ↓
Slice D: workbench families + final browser/release gate
```

Each slice can be reviewed independently:

- **A** leaves the current workbenches visually intact but gives them correct theme and URL semantics.
- **B** leaves the existing sidebar and workbenches available while adding the new deck behind an explicit view.
- **C** replaces duplicated navigation only after its replacements and accessibility behavior pass.
- **D** changes one workbench family at a time and retains all existing IDs/events.

---

## Slice A — Theme and Canonical View Foundation

### Task 0: Establish a regression baseline

**Files:** none (read-only gate)

**Tests/commands:**

**Interfaces:** This read-only gate produces no code or assigns; it records baseline command outcomes for later comparison.

- [ ] Run `mix test test/iex_code/kanban_test.exs test/iex_code/sessions_test.exs test/iex_code/observability/runtime_status_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/settings_live_test.exs`.
- [ ] Run `mix assets.build`.
- [ ] Record any pre-existing failures in the implementation branch notes; do not alter application behavior to hide a baseline failure.
- [ ] Run `git diff --check`, `git status --short`, and `git log -2 --oneline`. Confirm there are no tracked worktree changes, HEAD contains the plan commit after `2bb4d31`, and the only allowed untracked path is `.superpowers/` from the visual companion.

### Task 1: Add server-readable theme preference and flash-free root markup

**Files:**

- Create: `lib/iex_code_web/plugs/theme.ex`
- Modify: `lib/iex_code_web/router.ex` (`pipeline :browser`)
- Modify: `lib/iex_code_web/components/layouts/root.html.heex`
- Create: `test/iex_code_web/plugs/theme_test.exs`
- Create: `test/iex_code_web/layouts_root_test.exs`

**Interfaces:**

- Produces `IexCodeWeb.Plugs.Theme.init/1`, which returns its options unchanged, and `IexCodeWeb.Plugs.Theme.call/2`, which assigns `:theme_preference` to `"dark"`, `"light"`, or `nil`.
- Root markup exposes `data-theme` only for an explicit preference, `color-scheme`, and media-qualified theme-color metadata.

- [ ] **Step 1: Write failing plug and root integration tests.** Use `Plug.Test.conn/3` and `Plug.Test.put_req_cookie/3`; through public `/login`, also assert explicit light metadata, absent `data-theme` for invalid/absent cookies, both system media metadata tags, and hidden `#connection-status`:

```elixir
test "accepts only dark and light cookie values" do
  assert Theme.init(source: :cookie) == [source: :cookie]

  conn = Plug.Test.conn(:get, "/") |> Plug.Test.put_req_cookie("iexcode_theme", "light")
  assert %{assigns: %{theme_preference: "light"}} = Theme.call(conn, [])

  invalid = Plug.Test.conn(:get, "/") |> Plug.Test.put_req_cookie("iexcode_theme", "blue")
  assert %{assigns: %{theme_preference: nil}} = Theme.call(invalid, [])
end
```

- [ ] **Step 2: Run `mix test test/iex_code_web/plugs/theme_test.exs test/iex_code_web/layouts_root_test.exs` and verify the plug/root assertions fail before implementation.**
- [ ] **Step 3: Implement the Plug callbacks.** Add `@behaviour Plug`, implement `init/1` as the identity function, and implement `call/2` by calling `fetch_cookies/1`, reading `conn.req_cookies["iexcode_theme"]`, accepting exactly `"dark"`/`"light"`, and assigning `nil` for absent/invalid values. Do not set or mutate cookies in the plug.
- [ ] **Step 4: Insert `plug IexCodeWeb.Plugs.Theme` after `:fetch_session` and before `:put_root_layout` in the browser pipeline.**
- [ ] **Step 5: Update `root.html.heex`.** Remove hardcoded `data-theme="dark"` and `style="color-scheme: dark;"`; derive the root attributes from `assigns[:theme_preference]`. Emit one explicit theme-color meta for a cookie preference or two media-qualified metas (`#171514` dark, `#EAE5DC` light) when the preference is nil. Add a real direct-child body status node:

```heex
<div id="connection-status" role="status" aria-live="polite" hidden>
  Signal paused · reconnecting
</div>
```

- [ ] **Step 6: Complete the root markup until the Step 1 integration assertions pass.** Assert `html[data-theme="light"]`, `meta[name="theme-color"][content="#EAE5DC"]`, absent `data-theme` for invalid/absent cookies, both `media` tags, and initially hidden `#connection-status`.
- [ ] **Step 7: Run `mix test test/iex_code_web/plugs/theme_test.exs test/iex_code_web/layouts_root_test.exs test/iex_code_web/controllers/admin_session_controller_test.exs`.**
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/plugs/theme.ex lib/iex_code_web/router.ex lib/iex_code_web/components/layouts/root.html.heex test/iex_code_web/plugs/theme_test.exs test/iex_code_web/layouts_root_test.exs && git commit -m "feat: add server-readable theme preference"`.

### Task 2: Build Signal Foundry CSS materials and vendor the display font

**Files:**

- Create: `priv/static/fonts/doto-variable.woff2`
- Create: `priv/static/fonts/OFL.txt`
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/signal_foundry_material_test.exs`

**Interfaces:**

- Produces `--sf-*` dark/light tokens and `.sf-display`, `.sf-instrument`, `.sf-chassis`, `.sf-pill`, `.sf-command-dock`, `.sf-focus-surface` classes used by later templates.

- [ ] **Step 1: Write a failing material contract test.** Read `app.css` and assert the exact Tailwind sources, `@font-face`, dark/light token selectors, the six public `.sf-*` classes, `.sf-deck-grid`, `.sf-ambient-field`, coarse-pointer 44px rule, 180ms workbench entry, and reduced-motion overrides. Assert grid breakpoints produce one unit below 640px, two at 640–1023px, three at 1024–1439px, and four at 1440px; Active Mission spans two units where space permits and all rotation/perspective is removed below 640px.
- [ ] **Step 2: Run `mix test test/iex_code_web/signal_foundry_material_test.exs` and verify it fails on the absent Signal Foundry tokens/classes.**
- [ ] **Step 3: Vendor the exact Google Fonts Doto webfont and license.** Download the Latin variable WOFF2 from `https://fonts.gstatic.com/s/doto/v3/t5t6IRMbNJ6TQG7Il_EKPqP9zTnvqouBWhoxrW5O.woff2` and the license from `https://raw.githubusercontent.com/google/fonts/ade3d1533e06b2b1462ffcde8e08b129627ca360/ofl/doto/OFL.txt`. Verify SHA-256 values `1c7d9f9c86f929fb4469b8a93510a65936d3bdc49e0a1a6878ae2b0f3f47c7c2` and `26a7b58bdba6cda8a78ca6e8b3791d8013b8abc6d5e6519f84193893aee02020`, then place them at the paths above. Verify `file priv/static/fonts/doto-variable.woff2` reports Web Open Font Format and the license begins `Copyright 2024 The Doto Project Authors`.
- [ ] **Step 4: Add `@font-face` using `/fonts/doto-variable.woff2` with `font-display: swap`; do not add a remote font URL.** Retain these exact imports/sources at the top of `app.css`:

```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/iex_code_web";
```

- [ ] **Step 5: Define `:root[data-theme="dark"]`, `:root[data-theme="light"]`, and media-query defaults for no explicit theme.** Include the approved canvas/surface/text/status pairs and darker light-theme text variants (`#655F58`, `#A8321F`, `#42624F`, `#4E6170`) so normal text meets AA contrast.
- [ ] **Step 6: Add material, deck geometry, and motion classes.** Implement the exact responsive units tested in Step 1, a featured two-unit Active Mission, solid faces, one `.sf-ambient-field`, 22px instrument radii, 28–30px chassis radii, 14–18px controls, 9999px pills, broad diffuse shadows, inset highlights, and 44px coarse-pointer targets. At >=1280px optical offset is <=1px/0.2deg; hover lift is <=3px; workbench entry is 180ms; initial cards do not all animate. Reduced motion removes tilt, lift, entry, smooth scroll, and waveform travel.
- [ ] **Step 7: Remove legacy rainbow/neon/card-running-glow rules only where migrated components no longer use them.** Keep the current disconnected pseudo-banner until Task 3 activates and styles the real DOM banner, so this commit remains deployable.
- [ ] **Step 8: Add focus, overflow, safe-area, and light/dark contrast rules.** Keep essential text >=12px, body text >=14px, and code surfaces readable in both themes.
- [ ] **Step 9: Run static audit commands:**

```bash
grep -n '^@import "tailwindcss" source(none);\|^@source' assets/css/app.css
grep -ERIn --exclude-dir=node_modules --exclude-dir=vendor '@apply|https?://[^"'"'"'[:space:]]+\.(css|js|woff2?)([?#][^"'"'"'[:space:]]*)?' assets lib/iex_code_web
find priv/static/fonts -maxdepth 1 -type f -print
git diff --check
```

- [ ] **Step 10: Run `mix test test/iex_code_web/signal_foundry_material_test.exs` and `mix assets.build`.**
- [ ] **Step 11: Commit:** `git add assets/css/app.css priv/static/fonts test/iex_code_web/signal_foundry_material_test.exs && git commit -m "feat: add Signal Foundry material system"`.

### Task 3: Replace theme runtime and make xterm/connection state theme-aware

**Files:**

- Create: `assets/js/theme.mjs`
- Create: `assets/js/theme.test.mjs`
- Modify: `assets/js/app.js`
- Modify: `assets/js/hooks/terminal_hook.js`
- Modify: `test/iex_code_web/components/workspace_components_test.exs` for unchanged terminal hook contract

**Interfaces:**

```js
// assets/js/theme.mjs
export function resolveTheme({explicitTheme, prefersDark}) // => "dark" | "light"
export function themeCookie(theme, {secure}) // => exact Set-Cookie-style document.cookie value
export function expiredThemeCookie({secure}) // => Max-Age=0 cookie value
export function applyTheme(theme, env) // env supplies document/localStorage/matchMedia
export function setSystemTheme(env)
export function setTheme(theme, env) // theme is "dark" | "light" | "system"
```

`themeCookie("dark", {secure: false})` returns exactly `iexcode_theme=dark; Path=/; Max-Age=31536000; SameSite=Strict`; light substitutes only the value; `{secure: true}` appends `; Secure`. `expiredThemeCookie({secure: false})` returns exactly `iexcode_theme=; Path=/; Max-Age=0; SameSite=Strict`, again appending `; Secure` only on HTTPS.

`setTheme(theme, env)` is the browser adapter for `"dark"`, `"light"`, and `"system"`; it delegates to `applyTheme/2` or `setSystemTheme/1` with the supplied `{window, document, localStorage, matchMedia}` environment and is the sole `phx:set-theme` listener in `app.js`.

`applyTheme/2` and `setSystemTheme/1` dispatch `new CustomEvent("iexcode:theme-changed", {detail: {theme: resolved}})` on `env.window`. `app.js` supplies the real `window`, and `TerminalHook` listens on that same `window`. Global `app.js` listeners are process-lifetime singletons registered once at bundle load; they do not have a component teardown. `TerminalHook` owns and removes only its own `window` `iexcode:theme-changed` listener.

- [ ] **Step 1: Write `assets/js/theme.test.mjs` with `node:test`.** Cover explicit dark/light precedence, system resolution, exact one-year cookie flags, HTTPS `Secure`, System expiry, removal of `data-theme`, localStorage cleanup, meta update, and one `iexcode:theme-changed` dispatch on the supplied fake `window` with exact `{theme: resolved}` detail.
- [ ] **Step 2: Run `node --test assets/js/theme.test.mjs` and verify imports/functions fail before implementation.**
- [ ] **Step 3: Implement the pure helpers in `theme.mjs` and import them from `app.js`.** `setTheme("dark"|"light")` writes a one-year `iexcode_theme` cookie; System removes the `data-theme` attribute, cookie, and storage mirror, sets `color-scheme: light dark`, and resolves through media preference.
- [ ] **Step 4: Make initialization server-first.** Trust server-emitted `document.documentElement.dataset.theme`; when absent, use `matchMedia`. Clear legacy `phx:theme` once instead of overriding server markup. Mirror explicit choice only for cross-tab notification.
- [ ] **Step 5: Dispatch `iexcode:theme-changed` on `window` after every resolved change and update theme-color metadata.** Register `window` storage and media-query listeners once at bundle initialization; document them as application-lifetime listeners.
- [ ] **Step 6: Add `updateConnectionStatus(connected, reason)` and call it from LiveSocket open/close/error and window offline/online callbacks.** Toggle `hidden`, `data-state`, and compatibility body class on `#connection-status`; in this same step remove the old `body.phx-disconnected::after` CSS rule.
- [ ] **Step 7: Refactor `TerminalHook` to expose `themeFor(theme)` and `applyTheme(theme)`.** Initialize xterm from the resolved theme, subscribe with `window.addEventListener("iexcode:theme-changed", this.handleThemeChanged)`, mutate `term.options.theme` without remounting, and remove that exact `window` listener in `destroyed()`.
- [ ] **Step 8: Run `node --test assets/js/theme.test.mjs`, `mix assets.build`, and existing terminal component tests.**
- [ ] **Step 9: Commit:** `git add assets/js/theme.mjs assets/js/theme.test.mjs assets/js/app.js assets/js/hooks/terminal_hook.js test/iex_code_web/components/workspace_components_test.exs && git commit -m "feat: persist Signal Foundry themes and connection state"`.

### Task 4: Introduce canonical workspace view state without changing visual markup

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex` (`@workspace_tabs`, mount, `handle_params/3`, navigation handlers)
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs`
- Update: `test/iex_code_web/live/workspace_live_test.exs`

**Interfaces:**

- Produces `@workspace_views = ~w(deck kanban swarm research calendar changes chat files terminal)` and `@active_view`.
- Keeps `@active_tab` and both `switch_tab` event payload shapes as compatibility assigns/events.

The declarations below specify signatures only; Steps 3 and 5 supply their bodies.

```elixir
@spec normalize_workspace_view(map(), atom()) ::
        {:ok, String.t()} | {:replace, String.t()}
defp normalize_workspace_view(params, live_action)

@spec workspace_path(project_route :: :root | {:session, String.t()}, view :: String.t()) :: String.t()
defp workspace_path(route_context, view)
```

`normalize_workspace_view/2` returns `{:ok, "deck"}` for an absent workspace query, `{:ok, view}` for a valid non-deck workspace value, `{:replace, deck_path}` for explicit `deck` or invalid values, `{:ok, "research"}` for a canonical research action without a query, and `{:replace, canonical_research_path}` for any query on a canonical research route. `workspace_path/2` returns `/`, `/?view=<view>`, `/sessions/:id`, `/sessions/:id?view=<view>`, or the canonical research path.

- [ ] **Step 1: Write failing route tests** for `/`, `/sessions/:id`, each concrete closed-set query (`kanban`, `swarm`, `calendar`, `changes`, `chat`, `files`, `terminal`), canonical research URLs, conflicting `/research?view=terminal` and session research queries being removed with replace, `/?view=research` → `/research`, `/sessions/:id?view=research` → `/sessions/:id/research`, malformed view replacement, and explicit `view=deck` query removal.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs` and verify default/canonical/malformed URL assertions fail before implementation.**
- [ ] **Step 3: Implement `normalize_workspace_view/2` with the exact return cases above.** Never call `String.to_atom/1` on params.
- [ ] **Step 4: Update `handle_params/3` to derive `active_view`, mirror non-deck values into `active_tab`, and issue replace navigation for invalid values.** Keep existing research refresh and session/project rehydration behavior.
- [ ] **Step 5: Add exact path helpers:** root deck `/`, root workbench `/?view=<view>`; session deck `/sessions/:id`, session workbench `/sessions/:id?view=<view>`; research `/research` or `/sessions/:id/research`.
- [ ] **Step 6: Make non-research `switch_tab` handlers validate through the same helper and `push_patch` to the exact view URL.** Research uses its canonical route; Settings remains `push_navigate`.
- [ ] **Step 7: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs`.**
- [ ] **Step 8: Run `mix assets.build` so Slice A ends with both server and bundle gates green.**
- [ ] **Step 9: Commit:** `git add lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_test.exs && git commit -m "feat: add canonical workspace view state"`.

---

## Slice B — Bounded Summary Data and Instrument Deck

### Task 5: Add the bounded Kanban aggregate and pure summary builder

**Files:**

- Modify: `lib/iex_code/kanban.ex`
- Create: `lib/iex_code_web/instrument_summary.ex`
- Create: `test/iex_code/kanban_summary_test.exs`
- Create: `test/iex_code_web/instrument_summary_test.exs`

**Interfaces:**

- `IexCode.Kanban.summary(project_id, opts \\ []) :: %{status_counts: %{String.t() => non_neg_integer()}, today_count: non_neg_integer(), next_scheduled_at: DateTime.t() | nil}`. Supported options are `:today` (`Date.t()`) and `:now` (`DateTime.t()`); production defaults capture `Date.utc_today()` and `DateTime.utc_now()` once, while tests pass both values.

```elixir
@surfaces ~w(kanban swarm research calendar changes chat files terminal)
@type surface :: String.t()
@type status :: :ready | :active | :attention | :empty | :error | :standby
@type secondary_fact :: %{required(:label) => String.t(), required(:value) => String.t()}
@type summary :: %{
  surface: surface(),
  title: String.t(),
  status: status(),
  primary: String.t() | nil,
  secondary: [%{label: String.t(), value: String.t()}],
  detail: String.t() | nil,
  destination: String.t(),
  updated_at: DateTime.t() | nil,
  attention?: boolean()
}

@spec build(surface(), map()) :: summary()
def build(surface, facts)
@spec mission(map()) :: summary()
@spec board(map()) :: summary()
@spec research(map()) :: summary()
@spec schedule(map()) :: summary()
@spec changes(map()) :: summary()
@spec chat(map()) :: summary()
@spec files(map()) :: summary()
@spec terminal(map()) :: summary()
```

The declarations above are signature-only interfaces; Task 5 supplies their function bodies.

`build/2` dispatches only the eight functions above (and raises `ArgumentError` for any other surface). Each function documents its accepted fact keys in its module docstring: `mission` (`run`, `phase`, `progress`, `pending_approvals`), `board`/`schedule` (`status_counts`, `today_count`, `next_scheduled_at`, `error?`), `research` (`run`, `level`, `completed_round`, `source_count`, `result_ready?`), `changes` (`git_status`, `git_error`, `latest_test`), `chat` (`latest_message`, `messages_newer?`), `files` (`loaded?`, `file_count`, `files_more?`, `selected_file`, `dirty?`, `git_relation`), and `terminal` (`available?`, `state`, `active_command`, `latest_command`, `owner`).
Because Elixir typespecs do not support singleton binary literals, `surface()` is `String.t()` and runtime membership in the exact `@surfaces` list enforces the closed union.

`primary`, `detail`, and every secondary value produced by `build/2` are capped at 160 UTF-8 characters. Unsupported surfaces raise `ArgumentError` in trusted internal code; user parameters are validated before constructing this input. The eight functions use the exact source/refresh/fallback table in the approved spec; notably `Board unavailable`, `Schedule unavailable`, `No active run`, `No research runs`, `Warming · checking Git`, `Git unavailable`, `No messages yet`, `Standby · files not loaded`, and `Terminal unavailable` are literal outputs.

- [ ] **Step 1: Write `Kanban.summary/2` tests** with tasks across two projects, all `Task.statuses/0`, UTC today/past/future timestamps, and an empty project. Assert no task descriptions/rows are returned and project filtering is exact.
- [ ] **Step 2: Run the focused test and observe failure.**
- [ ] **Step 3: Implement one bounded query path.** Capture `now` once, derive UTC day start/stop, group closed statuses, count today, and select one future `scheduled_at` ordered ascending. Return zero counts for missing statuses.
- [ ] **Step 4: Write pure builder tests** for every surface's active/attention/empty/standby/error labels, bounded strings, no secret/process/lease fields, and exact fallback copy.
- [ ] **Step 5: Run `mix test test/iex_code_web/instrument_summary_test.exs` and verify it fails because `InstrumentSummary` is absent.**
- [ ] **Step 6: Implement `InstrumentSummary` as a pure module.** Implement exactly `build/2`, `mission/1`, `board/1`, `research/1`, `schedule/1`, `changes/1`, `chat/1`, `files/1`, and `terminal/1`; keep runtime in the separate `RuntimeStatus`/mission-strip assign. Pass all source data in the documented fact maps so tests do not call WorkspaceLive private functions, and validate against `@surfaces` before dispatch.
- [ ] **Step 7: Run `mix test test/iex_code/kanban_summary_test.exs test/iex_code/kanban_test.exs test/iex_code_web/instrument_summary_test.exs test/iex_code/sessions_test.exs`.**
- [ ] **Step 8: Commit:** `git add lib/iex_code/kanban.ex lib/iex_code_web/instrument_summary.ex test/iex_code/kanban_summary_test.exs test/iex_code_web/instrument_summary_test.exs && git commit -m "feat: add bounded instrument summaries"`.

### Task 6: Wire truthful summary orchestration into WorkspaceLive

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex` (mount, project/session rehydrate, event handlers, PubSub handlers, helpers)
- Create: `test/iex_code_web/live/workspace_live_instrument_summaries_test.exs`
- Update: `test/iex_code_web/live/workspace_live_async_runs_test.exs`
- Update: `test/iex_code_web/live/workspace_live_terminal_test.exs`

**Interfaces:**

- Assign `runtime_refresh_pending? :: boolean()` prevents a second `start_async(:runtime_status, fn -> RuntimeStatus.snapshot() end)` job.
- Assigns `deck_git_generation :: non_neg_integer()`, `deck_git_in_flight :: nil | %{project_id: String.t(), generation: non_neg_integer()}`, and `deck_git_queued_project_id :: String.t() | nil` implement Git single-flight. A trigger increments the generation. If no job is running, start `{:deck_git_summary, generation}` with the current project ID; otherwise queue only the latest current project ID. A result mutates Git assigns and clears the marker only when both project ID and generation match `deck_git_in_flight` and the current project. Every completion then starts the one queued current-project refresh, if present. Stale results never clear a newer marker.
- `terminal_available? :: boolean()` is true only for `{:ok, state}` and false for every lookup failure; `terminal_error_reason :: term() | nil` supports logging without exposing it in card text.
- `safe_kanban_summary(project_id) :: {:ok, map()} | {:error, :unavailable}`; the latter feeds exact `Board unavailable`/`Schedule unavailable` summaries.
- `select_active_mission(runs) :: nil | %IexCode.Runs.Run{}` uses the bounded newest-first 100-run list. `mission_phase(run)` performs one bounded `Runs.list_step_summaries/1` lookup for that selected run and chooses the first running step, then first paused step, then newest completed step; if absent, it returns `Status: <run status>`. Research separately performs one bounded step-summary lookup for its newest research run.

- [ ] **Step 1: Write failing orchestration tests.** Cover initial assigns; only-one-in-flight runtime and Git jobs; runtime/Git success and error marker clearing; queued latest-project Git refresh and stale generation rejection; active-run tie breaking over the bounded 100-run list; running/paused/latest-completed mission phase; pending approvals; filtered-task independence/query failure; newest research run with rounds clamped 1–4; newest-message correctness; Git entry/reconnect/action triggers and truncation; and terminal unavailable/idle outcomes.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_instrument_summaries_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_terminal_test.exs` and verify the new assigns/helpers/async outcomes fail before implementation.**
- [ ] **Step 3: Add mount assigns** `instrument_summaries`, `runtime_status`, `runtime_refresh_pending?`, `deck_git_generation`, `deck_git_in_flight`, `deck_git_queued_project_id`, `terminal_available?`, `terminal_error_reason`, `latest_message_summary`, `kanban_summary`, and `research_summary_steps`. Keep existing `selected_run` semantics for untouched workbenches.
- [ ] **Step 4: Implement deterministic mission and research selection.** Select running, paused, queued, draft, then newest terminal; use `mission_phase/1` for the selected mission and a separate bounded `Runs.list_step_summaries/1` call for only the newest research run.
- [ ] **Step 5: Add latest-message query** using `Sessions.list_messages(session_id, limit: 1, content_limit: 160)` and update it on `:message_created`, session switch, and reconnect. Label `@messages_newer?` only as `Newer messages available`.
- [ ] **Step 6: Add runtime async refresh.** Guard with `runtime_refresh_pending?`; start exactly one `start_async(:runtime_status, fn -> RuntimeStatus.snapshot() end)` job on connected mount, clear the marker in both success/error `handle_async/3` clauses, and schedule the next five-second refresh only after handling the prior result.
- [ ] **Step 7: Implement the Git generation/queue contract above.** Trigger on Deck/Changes entry, reconnect, project switch, and explicit Git refresh/fetch/pull/save; use existing bounded Git options. Do not infer tests from Git; use only the newest `run_tests` operation.
- [ ] **Step 8: Wrap `Kanban.summary/2` with `safe_kanban_summary/1`.** On query error, emit exact `Board unavailable` and `Schedule unavailable` summaries rather than crashing the LiveView.
- [ ] **Step 9: Refresh summaries on exact existing notifications** for task, run/control/agent/step, research result, message, terminal, file, project/session, and successful Git changes. Never enumerate streams.
- [ ] **Step 10: Preserve terminal availability.** Map `{:ok, state}` to true; every error sets false and records only a loggable reason. Real idle renders `Idle · no active command`.
- [ ] **Step 11: Run `mix test test/iex_code_web/live/workspace_live_instrument_summaries_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_terminal_test.exs test/iex_code/observability/runtime_status_test.exs`.**
- [ ] **Step 12: Commit:** `git add lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_instrument_summaries_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_terminal_test.exs && git commit -m "feat: wire truthful Signal Foundry telemetry"`.

### Task 7: Render the Instrument Deck and preserve existing workbench branches

**Files:**

- Create: `lib/iex_code_web/components/instrument_components.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/live/workspace_live.ex` imports and deck branch
- Create: `test/iex_code_web/components/instrument_components_test.exs`
- Update: `test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs`

**Interfaces:**

```elixir
# InstrumentComponents.instrument_deck/1
attr :summaries, :map, required: true
attr :active_view, :string, default: "deck"

# InstrumentComponents.mission_strip/1
attr :project, :any, required: true
attr :session, :any, required: true
attr :runtime, :map, required: true
attr :active_view, :string, required: true
slot :primary_action, required: true
```

Every summary supplies its exact canonical `destination` from the closed summary contract in Task 5. Connectivity is browser-owned: the strip labels the root-layout `#connection-status` target and does not consume a LiveView connection assign. The mission strip renders exactly one entry from `:primary_action`; the deck caller supplies `#new-mission-button`, and each workbench caller supplies one contextual action defined in its Task 11–19 tests. The IexCode mark (`#signal-foundry-mark`), `#all-instruments-trigger`, and `#profile-settings-trigger` all fire `toggle_command_palette`; the profile trigger additionally passes `phx-value-category="settings_account"` for Task 9.

- Stable visible IDs `instrument-deck`, `instrument-deck-heading`, `instrument-card-kanban`, `instrument-card-swarm`, `instrument-card-research`, `instrument-card-calendar`, `instrument-card-changes`, `instrument-card-chat`, `instrument-card-files`, `instrument-card-terminal`.

- [ ] **Step 1: Write component tests** asserting exact eight cards, the closed surface union, semantic button/link roles, accessible names containing title and status, text fallbacks, `aria-hidden` decorative SVGs, and no nested interactive controls.
- [ ] **Step 2: Run `mix test test/iex_code_web/components/instrument_components_test.exs` and verify the deck-card selectors fail before implementation.**
- [ ] **Step 3: Implement `InstrumentComponents` with one card shell and per-surface visualization slots.** Render summary text before SVG; use CSS/SVG dot instruments and no hard-coded theme colors in HEEx.
- [ ] **Step 4: Write mission-strip tests.** Assert exact project/session context, `Connected`/reconnecting target, `Runtime active|idle|unavailable`, pressure/critical override, the dispatcher triple only when all three values exist, `theme-toggle-dark`, `theme-toggle-light`, `command-palette-trigger`, one `new-mission-button`, and `profile-settings-trigger`. Assert no second tab bar.
- [ ] **Step 5: Run `mix test test/iex_code_web/components/instrument_components_test.exs` and verify mission-strip status/action assertions fail before implementation.**
- [ ] **Step 6: Implement `mission_strip/1`.** Use the runtime assign from Task 6 and browser-owned `#connection-status`, direct dark/light buttons that dispatch `phx:set-theme` with `data-phx-theme`, mark/All instruments/Cmd+K/profile switchboard triggers, and exactly one contextual primary-action slot. Do not create `@connection_state`.
- [ ] **Step 7: Add a deck branch keyed by `@active_view == "deck"`; keep existing branches keyed by compatibility `@active_tab`.**
- [ ] **Step 8: Use `<.link patch={summary.destination}>` for Research and `<button phx-click="switch_tab" phx-value-tab={summary.surface}>` for non-research cards, with `aria-pressed`/`aria-current` and `data-instrument-surface={summary.surface}` attributes.**
- [ ] **Step 9: Apply `.sf-deck-grid` and the featured Active Mission class from Task 2.** Component tests assert all eight cards, the featured two-unit card, and the exact one/two/three/four-unit responsive class contract.
- [ ] **Step 10: Keep all existing workbench content available when opened through query view.** Do not delete old IDs or conditionally remove durable run sections needed by current tests.
- [ ] **Step 11: Run `mix test test/iex_code_web/components/instrument_components_test.exs test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`; run `mix assets.build`.**
- [ ] **Step 12: Commit:** `git add lib/iex_code_web/components/instrument_components.ex lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex test/iex_code_web/components/instrument_components_test.exs test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs && git commit -m "feat: add Signal Foundry instrument deck"`.

---

## Slice C — Resume, Switchboard, Command Dock, and Shared Chassis

### Task 8: Add persistent resume, scroll, and focus restoration

**Files:**

- Create: `assets/js/hooks/instrument_deck_hook.mjs`
- Create: `assets/js/hooks/instrument_deck_hook.test.mjs`
- Modify: `assets/js/app.js` hook registration
- Modify: `lib/iex_code_web/live/workspace_live.html.heex` persistent `#workspace-shell`
- Modify: `lib/iex_code_web/live/workspace_live.ex` resume validation event/assign
- Create: `test/iex_code_web/live/workspace_live_resume_test.exs`

**Interfaces:**

- LocalStorage key: `iexcode:last-instrument:<project-id>:<session-id>`; value is one of the eight closed surface strings.
- SessionStorage key: `iexcode:deck-state:<project-id>:<session-id>`; JSON value is `{scrollTop, focusedInstrumentId, capturedAt}`.
- History key: `history.state.iexcodeDeckState`; value is `{storageKey, scrollTop, focusedInstrumentId, capturedAt}` so popstate ignores another project/session's entry.
- Hook → server event: `restore_last_instrument`, payload `%{"surface" => surface}`.
- Server assign: `resume_instrument :: nil | %{surface: String.t(), title: String.t(), path: String.t()}`.
- Visible shortcut ID: `resume-instrument`; it renders only when `@active_view == "deck"` and `@resume_instrument != nil`, patches to `resume_instrument.path`, and never redirects automatically.
- `assets/js/hooks/instrument_deck_hook.mjs` exports `const InstrumentDeck` and `default InstrumentDeck`; `app.js` registers it under `InstrumentDeck`.

- [ ] **Step 1: Add LiveView tests** for `restore_last_instrument` with every allowed surface, invalid/unknown strings, project/session keying, and `#resume-instrument[data-surface][href]`. Assert the shortcut is absent for `nil`/invalid state, appears only on the deck for valid state, patches only after activation, and never redirects on restore. The handler validates membership in `@workspace_tabs`, never creates atoms, and ignores invalid values.
- [ ] **Step 2: Write `instrument_deck_hook.test.mjs` with `node:test`.** Use fake DOM/storage/history/RAF objects to cover last-instrument write; mount event push; visible-card click capture; `phx:page-loading-start` programmatic capture; Return deriving `instrument-card-<active-view>`; matching-history-first browser Back restoration; session fallback; project/session key-change cleanup only after successful restore; missing-card heading/scroller fallback; focus-after-scroll order; and destroyed cleanup.
- [ ] **Step 3: Run `node --test assets/js/hooks/instrument_deck_hook.test.mjs` and verify the module is absent.**
- [ ] **Step 4: Implement the hook on persistent `#workspace-shell`, exposing `data-active-view`, `data-project-id`, and `data-session-id`.** `mounted()` computes the storage key and pushes `restore_last_instrument` once. `updated()` recomputes it; only when project/session changes does it clear prior-key restoration bookkeeping and push once for the new key. Repeated renders for the same key never push again. Instrument activation writes only a closed surface to that key.
- [ ] **Step 5: Initialize `resume_instrument: nil`, implement the validated server handler, and render the contextual `#resume-instrument` shortcut under the exact interface above.** Returning to the deck retains the assign; project/session changes clear it until the hook's next update for the new storage key supplies a value.
- [ ] **Step 6: Capture deck state immediately before navigation.** A card click stores that card ID; `phx:page-loading-start` captures the focused card for palette/programmatic patches while `data-active-view="deck"`; a Return control stores `instrument-card-${data-active-view}`. Write the exact sessionStorage and `history.state.iexcodeDeckState` shapes above before patch begins.
- [ ] **Step 7: Restore in both `mounted` and `updated` after one `requestAnimationFrame`; focus with `preventScroll: true`.** On popstate read `history.state.iexcodeDeckState` first only when `storageKey` matches, otherwise read sessionStorage. Fall back to heading, then scroller, and scroll 0. Retain ordinary round-trip state; after a successful restore under a different project/session key, remove only the prior key's stale entry.
- [ ] **Step 8: Register click, `phx:page-loading-start`, and popstate listeners once and remove all three plus pending RAF in `destroyed()`; register the hook in `LiveSocket`.**
- [ ] **Step 9: Run `node --test assets/js/hooks/instrument_deck_hook.test.mjs`, `mix test test/iex_code_web/live/workspace_live_resume_test.exs`, and `mix assets.build`.** Actual browser coordinates remain an Ego Lite acceptance case in Task 22.
- [ ] **Step 10: Commit:** `git add assets/js/hooks/instrument_deck_hook.mjs assets/js/hooks/instrument_deck_hook.test.mjs assets/js/app.js lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_resume_test.exs && git commit -m "feat: restore deck position and resume context"`.

### Task 9: Implement the switchboard and displace the sidebar safely

**Files:**

- Modify: `lib/iex_code_web/components/workspace_components.ex` command palette component
- Modify: `lib/iex_code_web/command_palette.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex` top strip/sidebar sections
- Modify: `lib/iex_code_web/live/workspace_live.ex` project/session/settings events
- Update: `test/iex_code_web/live/workspace_live_command_palette_test.exs`
- Update: `test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`
- Update: `test/iex_code_web/live/workspace_live_ui_controls_test.exs`
- Create: `test/iex_code_web/live/workspace_live_settings_navigation_test.exs`

**Interfaces:**

The declarations below specify the public types and function signature only; Step 3 supplies the body.

```elixir
@type action_item :: %{
        required(:id) => String.t(),
        required(:category) => :action,
        required(:title) => String.t(),
        required(:event) => String.t(),
        required(:params) => map()
      }
@type view_item :: %{
        required(:id) => String.t(),
        required(:category) => :view,
        required(:title) => String.t(),
        required(:tab) => String.t()
      }
@type navigation_item :: %{
        required(:id) => String.t(),
        required(:category) => :navigation,
        required(:title) => String.t(),
        required(:href) => String.t()
      }
@type session_item :: %{
        required(:id) => String.t(),
        required(:category) => :session,
        required(:title) => String.t(),
        required(:session_id) => String.t()
      }
@type project_item :: %{required(:id) => String.t(), required(:category) => :project, required(:title) => String.t(), required(:project_id) => String.t()}
@type account_item :: %{required(:id) => String.t(), required(:category) => :account, required(:title) => String.t(), required(:event) => String.t(), required(:params) => map()}
@type confirmation_item :: %{required(:id) => String.t(), required(:category) => :confirmation, required(:title) => String.t(), required(:event) => String.t(), required(:params) => map(), required(:confirmation) => String.t()}
@type palette_item :: action_item() | view_item() | navigation_item() | session_item() | project_item() | account_item() | confirmation_item()

@spec search(String.t() | nil, [%IexCode.Sessions.Session{}], String.t()) :: [palette_item()]
def search(query, sessions, category_filter \\ "all")
```

Add `project_item`, `account_item`, and `confirmation_item` variants to the union, each with an exact stable `id`, title, and one server-owned event/params or canonical href. Required IDs/actions are `view_<surface>` for all eight surfaces, `new-project`, `new-session`, `delete-session-<id>`, `settings-models`, `settings-execution`, `settings-research`, `settings-runtime`, `account-sign-out`, and `all-instruments`. `execute_command_palette_item/2` consumes only a server-produced `palette_item`; it never accepts an event name or destination from client params. `toggle_settings_modal` navigates to `/sessions/:id/settings#execution`, `open_research_settings` navigates to `/sessions/:id/settings#research`, and root-level Settings items use `/settings#<anchor>` only when no session route context exists.

- [ ] **Step 1: Write failing command-palette tests for all eight instruments, Research canonical navigation, project/session search, New Project, New Session, delete-session confirmation, Models, Execution, Research, Runtime settings anchors, and Account/Sign out.** Assert every item has a stable ID and one authorized action.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/workspace_live_settings_navigation_test.exs` and verify the new item IDs, routes, and visible replacements fail.**
- [ ] **Step 3: Extend command palette search data with those exact groups/actions.** Preserve bounded search results and never expose credentials or prompt content in labels.
- [ ] **Step 4: Build the rounded 2×4 desktop switchboard overlay from the existing command palette component.** Keep modal/dialog/input/result IDs, ArrowUp/Down, Enter, Escape, and focus trap/return. Render explicit `data-sheet-*` attributes but defer bottom-sheet activation to Task 10's registered `ResponsiveSheet` hook.
- [ ] **Step 5: Move project/session/create/delete/logout/settings/runtime actions into switchboard controls; keep the top strip exact and free of a second tab/action row.** Preserve workspace/session/logout IDs, confirmations, and event names.
- [ ] **Step 6: Replace the duplicate sidebar and top tab row only after all replacements render.** Keep compatibility events; do not render hidden duplicate controls. The mark and `#all-instruments-trigger` open the switchboard, while profile opens the Settings/Account category.
- [ ] **Step 7: Change `toggle_settings_modal` to `/sessions/:id/settings#execution`, remove the duplicate modal/form, and change `open_research_settings` to `/sessions/:id/settings#research`.** Use the root `/settings#<anchor>` variants only when the route context has no session ID. Destructive delete-session actions keep the existing confirmation but add `data-sheet-*` hooks consumed by Task 10 for mobile focus isolation.
- [ ] **Step 8: Run `mix test test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_settings_navigation_test.exs test/iex_code_web/live/settings_live_test.exs test/iex_code_web/live/challenger2_m1_template_stress_test.exs test/iex_code_web/live/empirical_dead_assign_challenge_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs`.**
- [ ] **Step 9: Commit:** `git add lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/command_palette.ex lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_settings_navigation_test.exs test/iex_code_web/live/challenger2_m1_template_stress_test.exs test/iex_code_web/live/empirical_dead_assign_challenge_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs && git commit -m "feat: add Signal Foundry switchboard"`.

### Task 10: Add the shared workbench chassis and command dock

**Files:**

- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `assets/js/hooks/responsive_sheet_hook.mjs`
- Create: `assets/js/hooks/responsive_sheet_hook.test.mjs`
- Modify: `assets/js/app.js`
- Create: `test/iex_code_web/components/workspace_components_workbench_test.exs`
- Create: `test/iex_code_web/components/workspace_components_signal_foundry_test.exs`

**Interfaces:**

- `<.workbench_chassis id surface index title status return_to return_instrument_id>` with `:primary_action`, `:local_modes`, `:primary_field`, `:signal_panel`, and `:command_dock` slots.
- Stable outer IDs `instrument-workbench-<surface>` and `return-to-instrument-deck-<surface>`.

```elixir
attr :id, :string, required: true
attr :surface, :string, required: true
attr :index, :string, required: true
attr :title, :string, required: true
attr :status, :string, required: true
attr :return_to, :string, required: true
attr :return_instrument_id, :string, required: true
slot :primary_action
slot :local_modes
slot :primary_field, required: true
slot :signal_panel
slot :command_dock
```

`assets/js/hooks/responsive_sheet_hook.mjs` exports `const ResponsiveSheet` and `default ResponsiveSheet`. `app.js` imports it and registers it alongside the existing colocated hooks and named hooks under the `ResponsiveSheet` key. Every host has a unique ID and `data-sheet-close-event`, `data-sheet-return-id`, and `data-sheet-background-id`. It traps focus, marks the background inert, handles Escape, and restores focus only while `matchMedia("(max-width: 639px)").matches`; it removes all effects/listeners on wider layouts and in `destroyed()`.

- [ ] **Step 1: Write failing component/LiveView tests** for chassis slots, replace-patch Return, accessible status, signal order, no duplicate global nav, compact/expanded/focus-expanded dock states, setup-tray value preservation, exact one contextual primary action per view, and `ResponsiveSheet` datasets on switchboard, task detail, and every destructive confirmation.
- [ ] **Step 2: Run `mix test test/iex_code_web/components/workspace_components_workbench_test.exs test/iex_code_web/components/workspace_components_signal_foundry_test.exs` and verify the chassis, dock, tray, and sheet contracts fail.**
- [ ] **Step 3: Implement the generic chassis in `WorkspaceComponents`.** Use opaque themed surfaces, 28–30px chassis radius, local mode tabs, responsive primary/signal grid, and one command dock slot.
- [ ] **Step 4: Render the existing prompt composer inside the chassis dock.** Preserve `#prompt-composer`, `#prompt-form`, model/tools/swarm controls, setup events, and form semantics; deck state uses compact capsule, Chat uses expanded form, and every other workbench expands the dock on focus.
- [ ] **Step 5: Add `#run-setup-tray` as a rounded secondary tray opened by labeled `#run-setup-toggle`.** Keep run mode, priority, budgets, providers, agent count, and advanced fields in `@run_setup_form`; closing does not reset values.
- [ ] **Step 6: Add explicit `replace` Return patch behavior and retain persistent InstrumentDeck attributes. Add connection-status, reduced-motion, safe-area, and mobile-sheet classes.**
- [ ] **Step 7: Write `responsive_sheet_hook.test.mjs` with fakes for mobile activation, desktop deactivation, Escape close event, focus trap/return, background inert cleanup, media-query change, and destroyed cleanup.**
- [ ] **Step 8: Run `node --test assets/js/hooks/responsive_sheet_hook.test.mjs` and verify it fails because the hook module is absent.**
- [ ] **Step 9: Implement/register `ResponsiveSheet` and activate the Task 9 switchboard dataset.** Reuse `ModalFocus` discipline; do not add `phx-update="ignore"` because the hook does not own DOM. Annotate task detail plus delete-session, calendar delete, file revert, Git discard/revert, and run cancel/kill confirmation hosts with exact dataset attributes so all mobile destructive overlays are inert, Escape-dismissible, and focus-restoring.
- [ ] **Step 10: Run `node --test assets/js/hooks/responsive_sheet_hook.test.mjs`, `mix test test/iex_code_web/components/workspace_components_workbench_test.exs test/iex_code_web/components/workspace_components_signal_foundry_test.exs test/iex_code_web/components/workspace_components_test.exs test/iex_code_web/components/workspace_components_adversarial_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs`, and `mix assets.build`.**
- [ ] **Step 11: Commit:** `git add lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css assets/js/hooks/responsive_sheet_hook.mjs assets/js/hooks/responsive_sheet_hook.test.mjs assets/js/app.js test/iex_code_web/components/workspace_components_workbench_test.exs test/iex_code_web/components/workspace_components_signal_foundry_test.exs test/iex_code_web/components/workspace_components_test.exs test/iex_code_web/components/workspace_components_adversarial_test.exs && git commit -m "feat: add shared Signal Foundry workbench chassis"`.

---

## Slice D — Workbench Families

### Task 11: Mission Board / Kanban keyboard and touch movement

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `assets/js/hooks/task_move_focus_hook.js`
- Create: `assets/js/hooks/task_move_focus_hook.test.mjs`
- Modify: `assets/js/app.js`
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs`
- Update: `test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`

**Interfaces:**

The event declarations below specify pattern-matched signatures only; Steps 4–5 supply their bodies.

```elixir
def handle_event("open_task_move", %{"id" => id}, socket)
def handle_event("cancel_task_move", %{"id" => id}, socket)
def handle_event("move_task", %{"move_task" => %{"id" => id, "status" => status}}, socket)

move_form = to_form(%{"id" => task.id, "status" => task.status}, as: :move_task)
```

```heex
<.form for={@task_move_form} id={"move-task-form-#{task.id}"} phx-submit="move_task">
  <.input field={@task_move_form[:id]} type="hidden" />
  <.input field={@task_move_form[:status]} type="select" options={Kanban.Task.statuses()} />
  <button type="submit">Move</button>
  <button type="button" phx-click="cancel_task_move" phx-value-id={task.id}>Cancel</button>
</.form>
```

`assets/js/hooks/task_move_focus_hook.js` exports `const TaskMoveFocus` and default; `app.js` registers it under the `TaskMoveFocus` hook key. It accepts only `%{"id" => "task-card-<uuid>"}` pushed by the server, calls `document.getElementById(payload.id)`, waits one RAF, focuses with `preventScroll: true`, cancels RAF in `destroyed()`, and owns no DOM. `moving_task_id` is a UUID string or nil. `expanded_task_status` initializes to the first non-empty status (or `triage`), and channel activation sets one status while collapsing the previous channel.

The Kanban branch mounts the hook exactly once on `<div id="task-move-focus-host" phx-hook="TaskMoveFocus"></div>`. It does not use `phx-update="ignore"` because the hook owns no DOM.

- [ ] **Step 1: Write failing LiveView/JS tests** for the unique `#task-move-focus-host[phx-hook="TaskMoveFocus"]`, valid/invalid moves, exact UUID/card IDs, Escape cancellation and focus return, live announcement, and selected-channel initialization/expand-collapse.
- [ ] **Step 2: Run `node --test assets/js/hooks/task_move_focus_hook.test.mjs` and `mix test test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs`; verify the absent hook and movement/channel selectors fail before implementation.**
- [ ] **Step 3: Add `moving_task_id`, `task_move_form`, `task_move_announcement`, and `expanded_task_status` assigns plus `open_task_move`, `cancel_task_move`, `move_task`, and `expand_task_status` events.** Keep the existing flat drag payload event.
- [ ] **Step 4: Render each task as a noninteractive row with sibling `#task-card-<uuid>` and `#move-task-trigger-<uuid>` controls.** Use native status select `#move-task-form-<uuid>`, exact announcement `Moved <task title> to <status>`, and push `%{"id" => "task-card-<uuid>"}`.
- [ ] **Step 5: Add the exact `#task-move-focus-host`, `#task-move-live-region`, and mobile task-detail `ResponsiveSheet` data.** Preserve Kanban IDs/events and pointer drag; do not add `phx-update="ignore"` to the focus-hook host.
- [ ] **Step 6: Implement/register `TaskMoveFocus` and Escape cancellation.** Cancel focuses `#move-task-trigger-<uuid>`; success refetches filtered tasks, expands destination, announces, and focuses `#task-card-<uuid>`.
- [ ] **Step 7: Restyle Kanban as flat channels and quiet gauges.** Activation expands one selected channel and collapses the prior one; remove rainbow accents.
- [ ] **Step 8: Run `node --test assets/js/hooks/task_move_focus_hook.test.mjs`, `mix test test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_kanban_scope_test.exs test/iex_code_web/live/kanban_workflow_stress_test.exs`, and `mix assets.build`.**
- [ ] **Step 9: Commit:** `git add lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css assets/js/hooks/task_move_focus_hook.js assets/js/hooks/task_move_focus_hook.test.mjs assets/js/app.js test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs && git commit -m "feat: redesign the mission board instrument"`.

### Task 12: Schedule Chronometer desktop month and mobile agenda

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `assets/js/local_time.mjs`
- Create: `assets/js/local_time.test.mjs`
- Create: `assets/js/hooks/local_time_hook.js`
- Modify: `assets/js/app.js`
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs`
- Update: `test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`

**Interfaces:** `assets/js/hooks/local_time_hook.js` exports `const LocalTime` and default; `app.js` registers it under `LocalTime`. Each `<time>` host has a unique `calendar-local-time-<task-id>` ID, `phx-update="ignore"`, and `data-utc`. The hook performs one render in `mounted()` and one in `updated()` with no event listeners or timers, so `destroyed()` has nothing to retain.

```js
// assets/js/local_time.mjs
export function formatLocalTime(iso, locale, timeZone, fallbackText)
// => {ok: true, text: string} | {ok: false, text: string}

// assets/js/hooks/local_time_hook.js
export const LocalTime = {mounted(), updated()}
export default LocalTime
```

For valid ISO-8601 input, `text` is formatted with `Intl.DateTimeFormat(locale, {dateStyle: "medium", timeStyle: "short", timeZone})`. For invalid input or an `Intl` failure, the pure function returns `{ok: false, text: fallbackText}`. At mount the hook stores the host's initial text content as `serverFallback` and passes that string on every render. `app.js` imports the default export and registers `Hooks.LocalTime = LocalTime`.

- [ ] **Step 1: Write failing calendar tests.** Assert `#instrument-workbench-calendar`, `#calendar-mobile-agenda[data-mobile-default="true"]`, `#calendar-month-view`, `#calendar-desktop-agenda`, chronological real-task ordering, exact `No scheduled actions`, and absence of fabricated monthly-run metrics.
- [ ] **Step 2: Write `local_time.test.mjs` for fixed `Asia/Tbilisi` output, invalid input, `Intl` failure, and exact passed fallback text; run it and the calendar test and verify both fail before implementation.**
- [ ] **Step 3: Add pure `calendar_agenda_items(tasks, from_date \\ Date.utc_today())`.** Filter tasks with real `scheduled_at`, sort by timestamp then ID, and `Enum.take(100)`; do not create presentation-only rows.
- [ ] **Step 4: Implement `formatLocalTime(iso, locale, timeZone, fallbackText)` and register `LocalTime`.** Render `<time id={"calendar-local-time-#{task.id}"} phx-hook="LocalTime" phx-update="ignore" data-utc={DateTime.to_iso8601(task.scheduled_at)}>{DateTime.to_iso8601(task.scheduled_at)} UTC</time>`; the hook captures server text before formatting and preserves it on failure.
- [ ] **Step 5: Render one data source in two responsive views.** Use `sm:hidden` for the mobile agenda and `hidden sm:block` for the month view so the boundary is exactly 640px.
- [ ] **Step 6: Add `#calendar-desktop-agenda` beside the month grid and preserve `#calendar-weekdays`, `#calendar-grid`, `#calendar-day-*`, detail/edit modal IDs, and prev/next/today/run/edit/delete events.** Add 44px mobile actions, `phx-disable-with`, and ResponsiveSheet-backed delete confirmations.
- [ ] **Step 7: Run `node --test assets/js/local_time.test.mjs`, `mix test test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs test/iex_code_web/live/workspace_live_kanban_scope_test.exs`, and `mix assets.build`.**
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css assets/js/local_time.mjs assets/js/local_time.test.mjs assets/js/hooks/local_time_hook.js assets/js/app.js test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs && git commit -m "feat: redesign the schedule chronometer"`.

### Task 13: Mission Control / Coach & Swarm workbench

**Files:**

- Modify: `lib/iex_code_web/components/run_components.ex`
- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/components/run_components_mission_test.exs`
- Update: `test/iex_code_web/live/workspace_live_async_runs_test.exs`

**Interfaces:**

The declarations below specify signatures and guards only; Steps 4–7 supply all omitted bodies.

```elixir
@mission_control_modes ~w(overview topology execution journal)

def handle_event("switch_mission_control_mode", %{"mode" => mode}, socket)
    when mode in @mission_control_modes

@spec select_active_mission([%IexCode.Runs.Run{}]) :: %IexCode.Runs.Run{} | nil
defp select_active_mission(runs)

def handle_event("switch_mission_control_mode", _invalid, socket), do: {:noreply, socket}
```

- [ ] **Step 1: Write failing Mission Control component tests.** Assert each of `#mission-control-mode-overview`, `#mission-control-mode-topology`, `#mission-control-mode-execution`, and `#mission-control-mode-journal` has `role="tab"`; assert `#instrument-workbench-swarm`, exactly one `[role="tab"][aria-selected="true"]`, `#mission-control-signal-panel`, `#mission-control-waveform[aria-hidden="true"]`, one DOM instance for each durable section ID, and no objective/prompt/lease-owner text in the instrument hero.
- [ ] **Step 2: Write failing LiveView behavior tests.** Activate `switch_mission_control_mode` with each allowed mode and assert its tab/panel; submit an invalid mode and assert the mode is unchanged. Open Swarm with running, paused, queued, draft, terminal-only, and no-run fixtures; assert the selected run order, `No active run` fallback, pending-approval/lock/failure/dispatcher precedence, exact `No operator decision required` fallback, and existing pause/resume/cancel/retry/steer/approval/agent event outcomes.
- [ ] **Step 3: Run `mix test test/iex_code_web/components/run_components_mission_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs` and verify the new chassis, mode, and signal selectors fail before implementation.**
- [ ] **Step 4: Add validated `@mission_control_modes = ~w(overview topology execution journal)` and the `mission_control_mode` assign/event.** Invalid values return the socket unchanged and never become atoms.
- [ ] **Step 5: Add the `workbench_chassis` wrapper `#instrument-workbench-swarm` and preserve all existing durable run IDs/events.** Keep ledger, detail, actions, steering, budgets, steps, DAG, approvals, events, artifacts, locks, and fleet as one DOM instance each inside labeled `<details>` disclosures.
- [ ] **Step 6: Add the instrument hero, factual phase derivation, semantic waveform, local mode tabs, and `#mission-control-signal-panel`.** Pending approvals take precedence, then selected lock, failed/interrupted state, dispatcher offline, then `No operator decision required`; legacy interactive Coach controls remain in the named execution mode.
- [ ] **Step 7: Use deterministic Active Mission selection only when entering Swarm.** Leave generic `selected_run` behavior untouched elsewhere and retain every existing pause/resume/cancel/retry/steer/approval/agent outcome.
- [ ] **Step 8: Run `mix test test/iex_code_web/components/run_components_mission_test.exs test/iex_code_web/components/run_components_fleet_test.exs test/iex_code_web/components/run_components_lock_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_m3_m4_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_telemetry_test.exs test/iex_code_web/live/workspace_live_adversarial_telemetry_controls_test.exs`; run `mix assets.build`.**
- [ ] **Step 9: Commit:** `git add lib/iex_code_web/components/run_components.ex lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/components/run_components_mission_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs && git commit -m "feat: focus Mission Control as an instrument workbench"`.

### Task 14: Research Radar and evidence workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Consume the Signal Foundry DAG styling owned by Task 13; do not modify `lib/iex_code_web/components/dag_components.ex` in this task.
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs`
- Update: `test/iex_code_web/live/workspace_live_deep_research_test.exs`

**Interfaces:**

`research_path/1` is complete below; the `open_research_run` line is a signature-only declaration whose body is supplied in Step 4.

```elixir
@spec research_path(:root | {:session, String.t()}) :: String.t()
defp research_path(:root), do: "/research"
defp research_path({:session, id}), do: "/sessions/#{id}/research"

def handle_event("open_research_run", %{"id" => run_id}, socket)
```

`open_research_run` accepts only an authorized `deep_research` run belonging to `socket.assigns.session.id`, selects at most the bounded `Runs.list_step_summaries/1` result, and patches to the unchanged canonical `research_path/1`. A foreign, missing, or non-research run leaves selection/path unchanged and sets `Research run not found in this session`. Authorized metadata with `"projection" => "dag_v1"` may render the existing DAG component; all other metadata renders factual status/progress text without attempting projection.

Stable new IDs are `instrument-workbench-research`, `research-stage-objective`, `research-stage-depth`, `research-stage-sources`, `research-stage-contract`, `research-run-contract`, `research-progress-dag`, `research-progress-fallback`, and `research-evidence-<public-id>`. Existing `deep-research-page`, form/provider/result, Open, HTML, and Markdown IDs remain unchanged.

- [ ] **Step 1: Write failing route and anatomy tests.** Visit `/research` and `/sessions/:id/research`; assert `#instrument-workbench-research`, `#deep-research-page`, the four ordered stage IDs, `#research-run-contract`, native depth/provider controls, existing form IDs, and submit `phx-disable-with`. Assert the URL stays canonical after `open_research_run`.
- [ ] **Step 2: Write failing authorization/evidence tests.** For an authorized `dag_v1` run assert `#research-progress-dag`; for a legacy run assert `#research-progress-fallback` and no DAG; for foreign/missing/non-research IDs assert the exact flash and unchanged path. For a ready result assert `#research-evidence-<public-id>`, level, source count, checksum/artifact readiness, and existing Open/HTML/Markdown actions. Submit the existing form twice with one idempotency key and assert one durable run/result.
- [ ] **Step 3: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs` and verify the chassis/stage/evidence selectors and canonical open-run behavior fail before implementation.**
- [ ] **Step 4: Wrap both canonical research routes in `#instrument-workbench-research` and reorder the existing form into the four numbered stages.** Use native controls and actual `research_level_semantics/1`; retain all current-scope, attachment, provider, validation, idempotency, and `phx-disable-with` behavior.
- [ ] **Step 5: Implement the exact `research_path/1` and `open_research_run` contract.** Select only authorized bounded step summaries, render DAG projection only for authorized `dag_v1` data, and render factual status/progress text in `#research-progress-fallback` otherwise.
- [ ] **Step 6: Render recent runs and ready reports as `#research-evidence-<public-id>` instruments.** Use only persisted level, source count, checksum/artifact readiness, and the existing Open/HTML/Markdown actions; preserve script-free report controllers and downloads.
- [ ] **Step 7: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs test/iex_code_web/controllers/research_report_controller_test.exs test/iex_code/research/results_test.exs test/iex_code/research/html_report_test.exs`; run `mix assets.build`.**
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs && git commit -m "feat: redesign research as an evidence instrument"`.

### Task 15: Change Ledger workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `assets/css/app.css`
- Update: `test/iex_code_web/live/workspace_live_editor_diffs_test.exs`
- Update: `test/iex_code_web/live/workspace_live_ast_git_test.exs`

**Interfaces:** Consumes `workbench_chassis/1`, `@git_status`, and `@instrument_summaries["changes"]`; preserves every existing Git event and diff/staging DOM ID.

- [ ] **Step 1: Write failing workbench assertions** for `#instrument-workbench-changes`, bounded/truncated status copy, latest `run_tests` operation, and `No test operation recorded` fallback.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_ast_git_test.exs` and verify the new chassis/bounded-test selectors fail.**
- [ ] **Step 3: Wrap the Changes branch in the shared chassis.** Preserve `changes-toolbar`, `changes-layout`, staging panel, diff panel, branch/fetch/pull/commit IDs, hunk actions, confirmations, and readable code typography.
- [ ] **Step 4: Render staged/unstaged/untracked/conflicted facts from the bounded Git summary.** Show `Showing bounded Git status` when truncated and never infer test coverage/currentness.
- [ ] **Step 5: Restyle the ledger and diff hierarchy with Signal Foundry tokens while keeping code surfaces flat and high contrast.**
- [ ] **Step 6: Run `mix test test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_ast_git_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs test/iex_code/tools/git_bounded_diff_test.exs`; run `mix assets.build`.**
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/components/workspace_components.ex assets/css/app.css test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_ast_git_test.exs && git commit -m "feat: redesign the change ledger workbench"`.

### Task 16: Conversation Loop workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `assets/css/app.css`
- Update: `test/iex_code_web/live/workspace_live_functional_state_test.exs`
- Update: `test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`

**Interfaces:** Consumes `latest_message_summary` and shared command dock; preserves chat paging, expansion, timeline, and composer events/IDs. Mobile uses trigger `#chat-jump-to-message` and sheet `#chat-jump-sheet` with `data-sheet-close-event="close_chat_jump_sheet"`, `data-sheet-return-id="chat-jump-to-message"`, and `data-sheet-background-id="chat-viewport"`; server events are `open_chat_jump_sheet` and `jump_to_message` with an authorized message ID.

- [ ] **Step 1: Add failing selectors** for `#instrument-workbench-chat`, the accessible phone jump control, normal prose typography, and exact `Newer messages available` language.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_functional_state_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs` and verify the Chat chassis/jump selectors fail.**
- [ ] **Step 3: Wrap Chat in the chassis and retain `#chat-viewport`, `#chat-empty-state`, timeline/message IDs, paging, expand, scroll, and prompt form behavior.**
- [ ] **Step 4: Replace nested trace cards with instrument dividers/event marks.** Keep chat messages in system sans and code/paths in monospace; never use Doto for prose.
- [ ] **Step 5: Hide the minimap below 640px and render `#chat-jump-to-message` plus `#chat-jump-sheet` as a ResponsiveSheet with Escape, inert background, and focus return.**
- [ ] **Step 6: Run `mix test test/iex_code_web/live/workspace_live_functional_state_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_m3_m4_test.exs`; run `mix assets.build`.**
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/components/workspace_components.ex assets/css/app.css test/iex_code_web/live/workspace_live_functional_state_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs && git commit -m "feat: redesign the conversation loop workbench"`.

### Task 17: File Atlas workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `assets/css/app.css`
- Update: `test/iex_code_web/live/workspace_live_editor_diffs_test.exs`
- Update: `test/iex_code_web/live/workspace_live_editor_lock_test.exs`
- Update: `test/iex_code_web/live/workspace_live_functional_state_test.exs`

**Interfaces:** Consumes `@selected_file`, `@project_files`, `@files_more?`, and bounded Git relation; preserves file/filter/editor/buffer/save/revert/copy/AST events and IDs.

```elixir
def handle_event("toggle_files_focus_mode", _params, socket) do
  {:noreply, update(socket, :files_focus_mode?, &(!&1))}
end
```

Mount initializes `files_focus_mode?: false`; visible control ID is `files-focus-mode-toggle` and `aria-pressed` mirrors the assign.

- [ ] **Step 1: Add failing selectors** for `#instrument-workbench-files`, standby, empty, retained-count `500+ files indexed`, selected path, dirty state, and focus-mode control.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_functional_state_test.exs` and verify File Atlas/focus-mode selectors fail.**
- [ ] **Step 3: Wrap the existing file explorer/editor in one chassis.** Preserve `#file-explorer-container`, `#file-tree-panel`, filter form, open buffers, save/revert/copy, and AST jump behavior.
- [ ] **Step 4: Use `@selected_file` as the active path.** Never display `length(@project_files)` as a total when `@files_more?` is true; show Git relation only when the bounded Git summary is present.
- [ ] **Step 5: Add focus mode that collapses secondary chrome without removing the editor or tree from accessible navigation.**
- [ ] **Step 6: Run `mix test test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_editor_lock_test.exs test/iex_code_web/live/workspace_live_functional_state_test.exs test/iex_code_web/components/workspace_components_editor_lock_test.exs test/iex_code/workspace_files_test.exs`; run `mix assets.build`.**
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/components/workspace_components.ex assets/css/app.css test/iex_code_web/live/workspace_live_editor_diffs_test.exs test/iex_code_web/live/workspace_live_editor_lock_test.exs test/iex_code_web/live/workspace_live_functional_state_test.exs && git commit -m "feat: redesign the file atlas workbench"`.

### Task 18: Terminal Scope workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `assets/css/app.css`
- Modify: `assets/js/hooks/terminal_hook.js`
- Update: `test/iex_code_web/live/workspace_live_terminal_test.exs`
- Update: `test/iex_code_web/live/workspace_live_terminal_adversarial_test.exs`

**Interfaces:** Consumes `terminal_available?`, terminal summary, and `iexcode:theme-changed`; preserves PTY lifecycle, ownership, history, quick actions, and every terminal DOM ID/event.

- [ ] **Step 1: Add failing workbench assertions** for `#instrument-workbench-terminal`, factual unavailable/idle/no-command labels, and existing xterm hook attributes.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/workspace_live_terminal_test.exs` and verify Terminal Scope labels/chassis selectors fail.**
- [ ] **Step 3: Wrap Terminal in the chassis and retain `#terminal-session-container`, `#terminal-xterm-wrapper`, `#terminal-xterm-container`, `#terminal-form`, quick actions, resize, clear, restart, kill, replay, and ownership controls.**
- [ ] **Step 4: Keep `phx-update="ignore"` on the unique xterm-owned element.** Apply dark/light palettes in place and remove the theme listener in `destroyed()`.
- [ ] **Step 5: Run `mix test test/iex_code_web/live/workspace_live_terminal_test.exs test/iex_code_web/live/workspace_live_terminal_adversarial_test.exs test/iex_code_web/live/workspace_live_terminal_adversarial_stress_test.exs test/iex_code_web/components/workspace_components_terminal_lock_test.exs`; run `mix assets.build`.**
- [ ] **Step 6: Commit:** `git add lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/components/workspace_components.ex assets/css/app.css assets/js/hooks/terminal_hook.js test/iex_code_web/live/workspace_live_terminal_test.exs test/iex_code_web/live/workspace_live_terminal_adversarial_test.exs && git commit -m "feat: redesign the terminal scope workbench"`.

### Task 19: Settings Calibration Bench

**Files:**

- Modify: `lib/iex_code_web/live/settings_live.html.heex`
- Modify: `lib/iex_code_web/live/settings_live.ex`
- Modify: `assets/css/app.css`
- Update: `test/iex_code_web/live/settings_live_test.exs`
- Update: `test/iex_code_web/live/workspace_live_ui_controls_test.exs`
- Update: `test/iex_code_web/live/workspace_live_test.exs`

**Interfaces:** Keeps SettingsLive as the only settings form owner; consumes shared theme tokens and provides explicit Dark, Light, and System controls. Stable anchors are `#models`, `#execution`, `#swarm`, `#research`, `#runtime`, `#editor`, `#resources`, `#usage`, `#providers`, and `#goals`; the page root uses shared workbench-chassis geometry while retaining `#settings-form`.

- [ ] **Step 1: Migrate every legacy workspace-modal test** to either assert navigation to SettingsLive or exercise the canonical `#settings-form`. Explicitly refute retired `:show_settings_modal`, `:settings_form` workspace assigns, and `#settings-modal`.
- [ ] **Step 2: Run `mix test test/iex_code_web/live/settings_live_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs` and verify Calibration Bench/theme/navigation assertions fail before restyling.**
- [ ] **Step 3: Restyle SettingsLive as the Calibration Bench with shared chassis geometry/tokens.** Preserve anchors `#models`, `#execution`, `#swarm`, `#research`, `#runtime`, `#editor`, `#resources`, `#usage`, `#providers`, `#goals`, all field IDs, credential clear events, save/discard semantics, runtime cadence, session context, and readable form hierarchy.
- [ ] **Step 4: Add visible `#settings-theme-dark`, `#settings-theme-light`, and `#settings-theme-system` buttons.** Each carries `data-phx-theme` and dispatches `phx:set-theme`; tests assert the exact attributes, `aria-pressed`, and that theme clicks do not submit/reset `#settings-form`.
- [ ] **Step 5: Ensure `toggle_settings_modal` and `open_research_settings` are navigation shims only and no duplicate settings form remains in WorkspaceLive.**
- [ ] **Step 6: Run `mix test test/iex_code_web/live/settings_live_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_test.exs test/iex_code_web/live/workspace_live_settings_navigation_test.exs`; run `mix assets.build`.**
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/settings_live.html.heex lib/iex_code_web/live/settings_live.ex assets/css/app.css test/iex_code_web/live/settings_live_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_test.exs && git commit -m "feat: redesign settings as the calibration bench"`.

### Task 20: Static design/accessibility audit and focused regression repair

**Files:**

- Create: `test/iex_code_web/signal_foundry_static_contract_test.exs`
- Modify: `assets/css/app.css`
- Modify: `assets/js/app.js`
- Modify: `lib/iex_code_web/components/layouts/root.html.heex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/components/instrument_components.ex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `lib/iex_code_web/components/run_components.ex`
- Modify: `lib/iex_code_web/live/settings_live.html.heex`

**Interfaces:**

`IexCodeWeb.SignalFoundryStaticContractTest` reads only these application-owned paths: `assets/css/app.css`, `assets/js/app.js`, `lib/iex_code_web/components/layouts/root.html.heex`, `lib/iex_code_web/live/workspace_live.html.heex`, `lib/iex_code_web/live/settings_live.html.heex`, `lib/iex_code_web/components/instrument_components.ex`, `lib/iex_code_web/components/workspace_components.ex`, and `lib/iex_code_web/components/run_components.ex`. It also checks that `priv/static/fonts/doto-variable.woff2` and `priv/static/fonts/OFL.txt` exist.

The remote-asset matcher is exactly `~r{https?://[^\s"']+\.(?:css|js|woff2?)(?:[?#][^\s"']*)?}`. The HEEx script check accepts only tags containing the literal `:type={Phoenix.LiveView.ColocatedHook}` and rejects every other script tag except the root layout's Phoenix-generated local `/assets/js/app.js` bundle tag. The visual-rule check scopes legacy `rainbow`, `neon`, colored `drop-shadow`, and internal gradient assertions to selectors rooted at `.sf-instrument`, `.sf-chassis`, `#instrument-deck`, or `[id^="instrument-workbench-"]`; it does not reject unrelated login artwork, code highlighting, xterm vendor CSS, or the single `.sf-ambient-field` radial background.

- [ ] **Step 1: Write a static contract test** that reads the listed application sources and asserts required Tailwind imports, both font/license files, no `@apply`, no remote URL ending in `.css`, `.js`, `.woff`, or `.woff2`, and no raw `<script>` tag in HEEx. Explicitly allow `<script :type={Phoenix.LiveView.ColocatedHook}>`; reject script tags lacking that attribute. Assert no legacy rainbow class on migrated instrument/workbench roots and only the named ambient background class may contain an outer radial gradient.
- [ ] **Step 2: Run `mix test test/iex_code_web/signal_foundry_static_contract_test.exs` and verify it exposes any remaining migrated-surface violations.**
- [ ] **Step 3: Replace each reported violation with the approved `--sf-*` token or bundled hook/component.** Do not change untouched vendor files or code syntax highlighting.
- [ ] **Step 4: Run source audits with node_modules/vendor excluded:**

```bash
grep -ERIn --exclude-dir=node_modules --exclude-dir=vendor '@apply|https?://[^"'"'"'[:space:]]+\.(css|js|woff2?)([?#][^"'"'"'[:space:]]*)?' assets lib/iex_code_web
grep -RIn --exclude-dir=node_modules --exclude-dir=vendor 'rainbow\|neon\|drop-shadow\|linear-gradient' assets/css/app.css lib/iex_code_web
find priv/static/fonts -maxdepth 1 -type f -print
```

- [ ] **Step 5: Add assertions for labels/IDs, coarse-pointer 44px rules, approved light contrast tokens, live-region scope, no nested interactive controls, and every `phx-hook` unique ID/ignore requirement to the static or component tests that own that markup.**
- [ ] **Step 6: Run `mix test test/iex_code_web/signal_foundry_static_contract_test.exs test/iex_code_web/components/instrument_components_test.exs test/iex_code_web/components/workspace_components_workbench_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`; run `mix format --check-formatted`, `mix assets.build`, and `git diff --check`.**
- [ ] **Step 7: Commit:** `git add test/iex_code_web/signal_foundry_static_contract_test.exs assets/css/app.css assets/js/app.js lib/iex_code_web/components/layouts/root.html.heex lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/components/instrument_components.ex lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/components/run_components.ex lib/iex_code_web/live/settings_live.html.heex && git commit -m "fix: tighten Signal Foundry accessibility and visual contracts"`.

---

## Final Verification and Release Gate

### Task 21: Automated release gate

**Interfaces:** Consumes all artifacts and test modules from Tasks 1–20; produces command output only and makes no application changes.

- [ ] Run `node --test assets/js/theme.test.mjs assets/js/hooks/instrument_deck_hook.test.mjs assets/js/hooks/responsive_sheet_hook.test.mjs assets/js/local_time.test.mjs`.
- [ ] Run `mix assets.build`.
- [ ] Run the exact terminal gate: `mix test test/iex_code/e2e_terminal/e2e_pty_terminal_test.exs test/iex_code/tools/terminal_stress_test.exs`.
- [ ] Run the complete `mix precommit` alias. If it formats or unlocks dependencies, rerun targeted tests and `mix assets.build` and inspect the diff.
- [ ] Run `git diff --check` and `git status --short`; do not include `.superpowers/` companion artifacts in commits.

### Task 22: Ego Lite browser matrix (last, never wipe sessions)

**Interfaces:** Consumes the built release from Tasks 1–21; produces screenshots under `/tmp/signal-foundry-smoke-<viewport>-<theme>.png` and a verification report, never repository files.

Use one named Ego Lite task space, retain the user's existing browser profile/cookies, and close the space/session after evidence capture. Never call a session-wipe or cookie-wipe helper.

- [ ] Verify 1440×900 dark/light: four-unit deck, material cards, no dock overlap, eight accessible instruments, Mission Control expansion.
- [ ] Verify 1024×768 dark/light: three-unit deck and side signal panel; verify 1023×768 switches to two columns and stacked signal panel.
- [ ] Verify 390×844 dark/light: one-column deck, no tilt, bottom-sheet switchboard, two-row dock, full-page workbench, all essential controls >=44px.
- [ ] Verify first paint with no theme cookie under mocked dark and light system preference; assert no wrong-theme frame. Toggle/reload, inspect `iexcode_theme`, reset System, and change media preference.
- [ ] Verify xterm palette changes in place on theme toggle and does not react after hook teardown.
- [ ] Verify root/session entry opens deck; all eight cards map to correct URL/workbench; Return uses replace behavior; malformed view falls back to deck; canonical research/settings links remain valid.
- [ ] Verify resume shortcut, stale allowed-list value rejection, desktop/mobile scroll and focus restoration, missing-card heading fallback, and browser Back.
- [ ] Verify switchboard Cmd/Ctrl+K, ArrowUp/Down wrap, Enter, Escape, focus trap/return, and mobile inert background.
- [ ] Verify reduced-motion emulation removes tilt/entry transitions.
- [ ] Verify offline LiveSocket state produces `[role="status"][aria-live="polite"]` text `Signal paused · reconnecting`, then clears on reconnect.
- [ ] Verify Kanban keyboard move announcement/focus return, mobile task sheet, calendar mobile agenda, research DAG/evidence, Git bounded labels, Files retained count, and Terminal ownership.
- [ ] Capture screenshots only under `/tmp/signal-foundry-smoke-<viewport>-<theme>.png`; do not commit them.
- [ ] Close the Ego Lite space/session and confirm the network is restored before closing.

### Task 23: Final review and merge decision

**Interfaces:** Consumes all changed files, commits, and verification evidence; produces the final go/no-go report and merge decision without modifying application code.

- [ ] Review every changed template for `<Layouts.app>` wrapper, `current_scope`, `<.input>`, `<.form for={@form}>`, `<.icon>`, unique IDs, and HEEx class-list syntax.
- [ ] Review every new Elixir block for immutable rebinding correctness, no list index access syntax, no struct map access, no nested modules, and no user-input `String.to_atom/1`.
- [ ] Confirm all four slices have their own commits and targeted green tests.
- [ ] Confirm no backend execution/security behavior changed outside the explicitly bounded `Kanban.summary/2`, theme cookie, and view-state plumbing.
- [ ] Report final verification evidence with commands and outcomes before claiming completion.

## Self-Review Checklist

- [ ] Every requirement in the approved spec maps to Task 1–23: themes/font/root, URL state, summary truth, deck, resume, switchboard, chassis, command dock, all workbench families, accessibility, responsive states, settings migration, Ego Lite, and final gates.
- [ ] No task depends on an undefined interface: `Kanban.summary/2`, `InstrumentSummary.build/2`, `@workspace_views`, `@active_view`, `workbench_chassis/1`, `InstrumentDeck`, and `terminal_available?` are defined above before use.
- [ ] No task asks for fabricated metrics or unspecified data sources.
- [ ] No task removes legacy IDs/events before a replacement test and migration step.
- [ ] Every implementation step names its concrete behavior, files, verification command, and expected contract.
- [ ] Each slice ends with an independently runnable test/build gate; the final gate adds Ego Lite and `mix precommit`.
