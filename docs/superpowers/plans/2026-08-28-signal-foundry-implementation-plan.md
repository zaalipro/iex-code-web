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

- [ ] Run `mix test test/iex_code/kanban_test.exs test/iex_code/sessions_test.exs test/iex_code/observability/runtime_status_test.exs test/iex_code_web/live/workspace_live_smoke_regression_test.exs test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/settings_live_test.exs`.
- [ ] Run `mix assets.build`.
- [ ] Record any pre-existing failures in the implementation branch notes; do not alter application behavior to hide a baseline failure.
- [ ] Run `git diff --check` and confirm the only tracked change is the approved spec commit (`2bb4d31`).

### Task 1: Add server-readable theme preference and flash-free root markup

**Files:**

- Create: `lib/iex_code_web/plugs/theme.ex`
- Modify: `lib/iex_code_web/router.ex` (`pipeline :browser`)
- Modify: `lib/iex_code_web/components/layouts/root.html.heex`
- Create: `test/iex_code_web/plugs/theme_test.exs`
- Create: `test/iex_code_web/layouts_root_test.exs`

**Interfaces:**

- Produces `IexCodeWeb.Plugs.Theme.call/2`, assigning `:theme_preference` to `"dark"`, `"light"`, or `nil`.
- Root markup exposes `data-theme` only for an explicit preference, `color-scheme`, and media-qualified theme-color metadata.

- [ ] **Step 1: Write failing plug tests.** Use `Plug.Test.conn/3` and `put_req_cookie/3`:

```elixir
test "accepts only dark and light cookie values" do
  conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_cookie("iexcode_theme", "light")
  assert %{assigns: %{theme_preference: "light"}} = Theme.call(conn, [])

  invalid = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_cookie("iexcode_theme", "blue")
  assert %{assigns: %{theme_preference: nil}} = Theme.call(invalid, [])
end
```

- [ ] **Step 2: Run `mix test test/iex_code_web/plugs/theme_test.exs` and verify the new tests fail because the plug is absent.**
- [ ] **Step 3: Implement `Theme.call/2`.** Call `fetch_cookies/1` first, read `conn.req_cookies["iexcode_theme"]`, accept exactly `"dark"`/`"light"`, and assign `nil` for absent/invalid values. Do not set or mutate cookies in the plug.
- [ ] **Step 4: Insert `plug IexCodeWeb.Plugs.Theme` after `:fetch_session` and before `:put_root_layout` in the browser pipeline.**
- [ ] **Step 5: Update `root.html.heex`.** Remove hardcoded `data-theme="dark"` and `style="color-scheme: dark;"`; derive the root attributes from `assigns[:theme_preference]`. Emit one explicit theme-color meta for a cookie preference or two media-qualified metas (`#171514` dark, `#EAE5DC` light) when the preference is nil. Add a real direct-child body status node:

```heex
<div id="connection-status" role="status" aria-live="polite" hidden>
  Signal paused · reconnecting
</div>
```

- [ ] **Step 6: Add root integration tests through public `/login`.** Assert `html[data-theme="light"]`, `meta[name="theme-color"][content="#EAE5DC"]`, absent `data-theme` for invalid/absent cookies, and both `media` theme-color tags for system mode. Assert `#connection-status` exists and is hidden initially.
- [ ] **Step 7: Run `mix test test/iex_code_web/plugs/theme_test.exs test/iex_code_web/layouts_root_test.exs test/iex_code_web/controllers/admin_session_controller_test.exs`.**
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/plugs/theme.ex lib/iex_code_web/router.ex lib/iex_code_web/components/layouts/root.html.heex test/iex_code_web/plugs/theme_test.exs test/iex_code_web/layouts_root_test.exs && git commit -m "feat: add server-readable theme preference"`.

### Task 2: Build Signal Foundry CSS materials and vendor the display font

**Files:**

- Create: `priv/static/fonts/doto-variable.woff2`
- Create: `priv/static/fonts/OFL.txt`
- Modify: `assets/css/app.css`
- Modify: `lib/iex_code_web/components/layouts.ex` if wrapper literals prevent token use

**Interfaces:**

- Produces `--sf-*` dark/light tokens and `.sf-display`, `.sf-instrument`, `.sf-chassis`, `.sf-pill`, `.sf-command-dock`, `.sf-focus-surface` classes used by later templates.

- [ ] **Step 1: Vendor the exact Google Fonts Doto webfont and license.** Download the Latin variable WOFF2 from `https://fonts.gstatic.com/s/doto/v3/t5t6IRMbNJ6TQG7Il_EKPqP9zTnvqouBWhoxrW5O.woff2` and the license from `https://raw.githubusercontent.com/google/fonts/ade3d1533e06b2b1462ffcde8e08b129627ca360/ofl/doto/OFL.txt`. Verify SHA-256 values `1c7d9f9c86f929fb4469b8a93510a65936d3bdc49e0a1a6878ae2b0f3f47c7c2` and `26a7b58bdba6cda8a78ca6e8b3791d8013b8abc6d5e6519f84193893aee02020`, then place them at the paths above. Verify `file priv/static/fonts/doto-variable.woff2` reports Web Open Font Format and the license begins `Copyright 2024 The Doto Project Authors`.
- [ ] **Step 2: Add `@font-face` using `/fonts/doto-variable.woff2` with `font-display: swap`; do not add a remote font URL.** Retain these exact imports/sources at the top of `app.css`:

```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/iex_code_web";
```

- [ ] **Step 3: Define `:root[data-theme="dark"]`, `:root[data-theme="light"]`, and media-query defaults for no explicit theme.** Include the approved canvas/surface/text/status pairs and darker light-theme text variants (`#655F58`, `#A8321F`, `#42624F`, `#4E6170`) so normal text meets AA contrast.
- [ ] **Step 4: Add material geometry and motion classes.** Use solid instrument faces, one ambient outer radial field, 22px instrument/chassis geometry, 14–18px controls, 9999px pills, broad diffuse shadows, inset top highlights, 44px coarse-pointer targets, and a reduced-motion block that removes transform/transition/animation.
- [ ] **Step 5: Remove the old `body.phx-disconnected::after` pseudo-banner and legacy rainbow/neon/card-running-glow rules as each replacement class lands.** Keep only rules still used by untouched screens; do not globally delete required terminal/editor styling.
- [ ] **Step 6: Add focus, overflow, safe-area, and light/dark contrast rules.** Keep essential text >=12px, body text >=14px, and code surfaces readable in both themes.
- [ ] **Step 7: Run static audit commands:**

```bash
grep -n '^@import "tailwindcss" source(none);\|^@source' assets/css/app.css
grep -RIn '@apply\|https\?://.*\(css\|js\|woff\)' assets lib/iex_code_web
find priv/static/fonts -maxdepth 1 -type f -print
git diff --check
```

- [ ] **Step 8: Run `mix assets.build` and commit:** `git add assets/css/app.css priv/static/fonts lib/iex_code_web/components/layouts.ex && git commit -m "feat: add Signal Foundry material system"`.

### Task 3: Replace theme runtime and make xterm/connection state theme-aware

**Files:**

- Modify: `assets/js/app.js`
- Modify: `assets/js/hooks/terminal_hook.js`
- Modify: `lib/iex_code_web/components/layouts/root.html.heex` only if status data attributes need a stable hook target
- Modify: `test/iex_code_web/components/workspace_components_test.exs` for unchanged terminal hook contract

- [ ] **Step 1: Extract pure theme helpers at the top of `app.js`:** `systemTheme()`, `resolvedTheme()`, `writeThemeCookie(theme)`, `clearThemeCookie()`, `updateThemeMeta(theme)`, and `setTheme(theme)`. `setTheme("dark"|"light")` writes a one-year `iexcode_theme` cookie with `Path=/; SameSite=Strict` and `Secure` on HTTPS; `setTheme("system")` removes the cookie/storage and resolves through media preference.
- [ ] **Step 2: Make initialization server-first.** Trust server-emitted `document.documentElement.dataset.theme`; when absent, use `matchMedia`. Clear legacy `phx:theme` on the first redesigned load instead of overriding server markup. Mirror explicit choice to `phx:theme` only for cross-tab notification.
- [ ] **Step 3: Dispatch `new CustomEvent("iexcode:theme-changed", {detail: {theme: resolved}})` after every resolved change; update `data-theme`, `color-scheme`, and the matching theme-color meta immediately. Listen for storage and media changes; remove every listener in teardown helpers.
- [ ] **Step 4: Add `updateConnectionStatus(connected, reason)` and call it from LiveSocket open/close/error and window offline/online callbacks.** Toggle `hidden`, `data-state`, and the compatibility body class on `#connection-status`; never rely on CSS pseudo-content.
- [ ] **Step 5: Refactor `TerminalHook` to expose `themeFor(theme)` and `applyTheme(theme)`.** Initialize xterm with dark or light Signal Foundry palette, listen for `iexcode:theme-changed`, mutate `term.options.theme` without remounting, and remove that listener in `destroyed()`.
- [ ] **Step 6: Run `mix assets.build` and existing terminal component tests.** Verify the hook element remains uniquely identified and uses `phx-update="ignore"` wherever it owns the DOM.
- [ ] **Step 7: Commit:** `git add assets/js/app.js assets/js/hooks/terminal_hook.js && git commit -m "feat: persist Signal Foundry themes and connection state"`.

### Task 4: Introduce canonical workspace view state without changing visual markup

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex` (`@workspace_tabs`, mount, `handle_params/3`, navigation handlers)
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs`
- Update: `test/iex_code_web/live/workspace_live_test.exs`

**Interfaces:**

- Produces `@workspace_views = ~w(deck kanban swarm research calendar changes chat files terminal)` and `@active_view`.
- Keeps `@active_tab` and both `switch_tab` event payload shapes as compatibility assigns/events.

- [ ] **Step 1: Write failing route tests** for `/`, `/sessions/:id`, each `?view=...`, canonical research URLs, malformed view replacement, and `view=deck` normalization.
- [ ] **Step 2: Implement a private `normalize_workspace_view/2` that accepts only the closed view set, maps absent/invalid to `"deck"`, and maps canonical research actions to `"research"`.** Never call `String.to_atom/1` on params.
- [ ] **Step 3: Update `handle_params/3` to derive `active_view`, mirror non-deck values into `active_tab`, and issue replace navigation for invalid values.** Keep existing research refresh and session/project rehydration behavior.
- [ ] **Step 4: Add exact path helpers:** root deck `/`, root workbench `/?view=<view>`; session deck `/sessions/:id`, session workbench `/sessions/:id?view=<view>`; research `/research` or `/sessions/:id/research`.
- [ ] **Step 5: Make non-research `switch_tab` handlers validate through the same helper and `push_patch` to the exact view URL.** Research uses its canonical route; Settings remains `push_navigate`.
- [ ] **Step 6: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs`.**
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_test.exs && git commit -m "feat: add canonical workspace view state"`.

---

## Slice B — Bounded Summary Data and Instrument Deck

### Task 5: Add the bounded Kanban aggregate and pure summary builder

**Files:**

- Modify: `lib/iex_code/kanban.ex`
- Create: `lib/iex_code_web/instrument_summary.ex`
- Create: `test/iex_code/kanban_summary_test.exs`
- Create: `test/iex_code_web/instrument_summary_test.exs`

**Interfaces:**

- `IexCode.Kanban.summary(project_id, opts \\ []) :: %{status_counts: %{String.t() => non_neg_integer()}, today_count: non_neg_integer(), next_scheduled_at: DateTime.t() | nil}`.
- `IexCodeWeb.InstrumentSummary.build/1` returns the exact closed summary map in the approved spec.

- [ ] **Step 1: Write `Kanban.summary/2` tests** with tasks across two projects, all `Task.statuses/0`, UTC today/past/future timestamps, and an empty project. Assert no task descriptions/rows are returned and project filtering is exact.
- [ ] **Step 2: Run the focused test and observe failure.**
- [ ] **Step 3: Implement one bounded query path.** Capture `now` once, derive UTC day start/stop, group closed statuses, count today, and select one future `scheduled_at` ordered ascending. Return zero counts for missing statuses.
- [ ] **Step 4: Write pure builder tests** for every surface's active/attention/empty/standby/error labels, bounded strings, no secret/process/lease fields, and exact fallback copy.
- [ ] **Step 5: Implement `InstrumentSummary` as a pure module.** Give it explicit functions for mission, board, research, schedule, changes, chat, files, terminal, and runtime; pass all source data in a map so tests do not call WorkspaceLive private functions.
- [ ] **Step 6: Run `mix test test/iex_code/kanban_summary_test.exs test/iex_code/kanban_test.exs test/iex_code_web/instrument_summary_test.exs test/iex_code/sessions_test.exs`.
- [ ] **Step 7: Commit:** `git add lib/iex_code/kanban.ex lib/iex_code_web/instrument_summary.ex test/iex_code/kanban_summary_test.exs test/iex_code_web/instrument_summary_test.exs && git commit -m "feat: add bounded instrument summaries"`.

### Task 6: Wire truthful summary orchestration into WorkspaceLive

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex` (mount, project/session rehydrate, event handlers, PubSub handlers, helpers)
- Create: `test/iex_code_web/live/workspace_live_instrument_summaries_test.exs`
- Update: `test/iex_code_web/live/workspace_live_async_runs_test.exs`
- Update: `test/iex_code_web/live/workspace_live_terminal_test.exs`

- [ ] **Step 1: Add mount assigns** `instrument_summaries`, `runtime_status`, `terminal_available?`, `latest_message_summary`, `kanban_summary`, `research_summary_steps`, and single-flight async markers. Keep existing `selected_run` semantics for untouched workbenches.
- [ ] **Step 2: Implement deterministic Active Mission selection**: first running, paused, queued, draft, then newest terminal. Use bounded `Runs.list_step_summaries/1` only for the selected research run when computing research rounds.
- [ ] **Step 3: Add latest-message query** using `Sessions.list_messages(session_id, limit: 1, content_limit: 160)` and update it on `:message_created`, session switch, and reconnect. Label `@messages_newer?` only as `Newer messages available`.
- [ ] **Step 4: Add runtime async refresh.** Start exactly one `start_async(:runtime_status, ...)` job on connected mount; schedule the next five-second refresh after the prior result; discard stale project/session results; map governor pressure to explicit text.
- [ ] **Step 5: Add deck Git async refresh.** Start exactly one `start_async(:deck_git_summary, ...)` job with existing bounded Git options; carry project ID in the result and discard it after project switches. Do not infer tests from Git; use newest `run_tests` operation only.
- [ ] **Step 6: Refresh summaries on exact existing events:** task create/update/delete, run create/update/event/control/agent, research result, message, terminal state, file load/save, project/session switch, and successful Git refresh. Never enumerate streams.
- [ ] **Step 7: Preserve terminal availability.** Set `terminal_available?` true only for `{:ok, state}`; keep real idle distinct from lookup failure.
- [ ] **Step 8: Test only-one-in-flight, stale-result discard, active-run tie breaking, filtered-task independence, latest-message correctness, research round lookup, Git truncation, and terminal unavailable/idle outcomes.
- [ ] **Step 9: Run `mix test test/iex_code_web/live/workspace_live_instrument_summaries_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_terminal_test.exs test/iex_code/observability/runtime_status_test.exs`.
- [ ] **Step 10: Commit:** `git add lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_instrument_summaries_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs test/iex_code_web/live/workspace_live_terminal_test.exs && git commit -m "feat: wire truthful Signal Foundry telemetry"`.

### Task 7: Render the Instrument Deck and preserve existing workbench branches

**Files:**

- Create: `lib/iex_code_web/components/instrument_components.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/live/workspace_live.ex` imports and deck branch
- Create: `test/iex_code_web/components/instrument_components_test.exs`
- Update: `test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs`

**Interfaces:**

- Public `<.instrument_deck summaries={@instrument_summaries} ...>` component.
- Stable visible IDs `instrument-deck`, `instrument-deck-heading`, `instrument-card-kanban`, `instrument-card-swarm`, `instrument-card-research`, `instrument-card-calendar`, `instrument-card-changes`, `instrument-card-chat`, `instrument-card-files`, `instrument-card-terminal`.

- [ ] **Step 1: Write component tests** asserting exact eight cards, semantic button/link roles, accessible names containing title and status, text fallbacks, `aria-hidden` decorative SVGs, and no nested interactive controls.
- [ ] **Step 2: Implement `InstrumentComponents` with one card shell and per-surface visualization slots.** Render summary text before SVG; use CSS/SVG dot instruments and no hard-coded theme colors in HEEx.
- [ ] **Step 3: Add a deck branch keyed by `@active_view == "deck"`; keep existing branches keyed by compatibility `@active_tab`.
- [ ] **Step 4: Use `<.link patch={...}>` for research and `<button phx-click="switch_tab">` for non-research cards, with `aria-pressed`/`aria-current` and `data-surface` attributes.
- [ ] **Step 5: Add a visible contextual resume signal that uses the stored last instrument title but never redirects automatically.
- [ ] **Step 6: Keep all existing workbench content available when opened through query view.** Do not delete old IDs or conditionally remove durable run sections needed by current tests.
- [ ] **Step 7: Run `mix test test/iex_code_web/components/instrument_components_test.exs test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`; run `mix assets.build`.
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/components/instrument_components.ex lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex test/iex_code_web/components/instrument_components_test.exs test/iex_code_web/live/workspace_live_signal_foundry_navigation_test.exs && git commit -m "feat: add Signal Foundry instrument deck"`.

---

## Slice C — Resume, Switchboard, Command Dock, and Shared Chassis

### Task 8: Add persistent resume, scroll, and focus restoration

**Files:**

- Create: `assets/js/hooks/instrument_deck_hook.js`
- Modify: `assets/js/app.js` hook registration
- Modify: `lib/iex_code_web/live/workspace_live.html.heex` persistent `#workspace-shell`
- Create: `test/iex_code_web/live/workspace_live_resume_test.exs`

- [ ] **Step 1: Add LiveView tests** for allowed last-instrument, invalid value, stale value, project/session keying, and visible resume shortcut.
- [ ] **Step 2: Implement the hook on persistent `#workspace-shell`, exposing `data-active-view`.** Do not mount it only on the conditional deck fragment.
- [ ] **Step 3: Capture before navigation.** On instrument click and `phx:page-loading-start`, store `{scrollTop, focusedInstrumentId, capturedAt}` under `iexcode:deck-state:<project-id>:<session-id>` and mirror it into `history.state`.
- [ ] **Step 4: Restore in both `mounted` and `updated` after one `requestAnimationFrame`; focus the stored `#instrument-card-<surface>` with `preventScroll: true`.** Fall back to `#instrument-deck-heading`, then the deck scroller, and scroll `0` when the card is gone.
- [ ] **Step 5: Remove all document/window listeners and pending animation frames in `destroyed()`.
- [ ] **Step 6: Register the hook in `LiveSocket` and add stable `data-project-id`, `data-session-id`, and `data-active-view` attributes.
- [ ] **Step 7: Run `mix test test/iex_code_web/live/workspace_live_resume_test.exs`; run `mix assets.build`.
- [ ] **Step 8: Commit:** `git add assets/js/hooks/instrument_deck_hook.js assets/js/app.js lib/iex_code_web/live/workspace_live.html.heex test/iex_code_web/live/workspace_live_resume_test.exs && git commit -m "feat: restore deck position and resume context"`.

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

- [ ] **Step 1: Extend command palette search data to include Research, Projects, Sessions, New Project, New Session, Settings anchors, Runtime, Account/Sign out, and all eight instruments.** Add tests for Research specifically.
- [ ] **Step 2: Build the rounded 2×4 switchboard overlay from the existing command palette component.** Keep `#command-palette-modal`, `#command-palette-dialog`, `#command-palette-input`, result IDs, ArrowUp/Down, Enter, Escape, and focus trap/return.
- [ ] **Step 3: Move project search/switch/create, session search/switch/create/delete, logout, settings links, and runtime access into explicit switchboard/top-strip controls.** Preserve `workspace-switcher-search-form`, `new-session-btn`, `workspace-logout-form`, confirmations, and event names.
- [ ] **Step 4: Replace the duplicate sidebar and top tab row only after all replacements render.** Keep `active_tab` compatibility events; do not render hidden duplicate controls solely for old tests.
- [ ] **Step 5: Change `toggle_settings_modal` to `push_navigate(~p"/sessions/#{id}/settings#execution")`. Remove the legacy workspace settings modal and duplicate form; migrate modal tests to SettingsLive. `open_research_settings` navigates to the canonical Settings research/providers anchor.
- [ ] **Step 6: Run the command palette, keyboard semantics, UI controls, settings navigation, and direct settings tests listed in the spec.
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/command_palette.ex lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex test/iex_code_web/live/workspace_live_command_palette_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_ui_controls_test.exs test/iex_code_web/live/workspace_live_settings_navigation_test.exs && git commit -m "feat: add Signal Foundry switchboard"`.

### Task 10: Add the shared workbench chassis and command dock

**Files:**

- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/components/workspace_components_workbench_test.exs`
- Create: `test/iex_code_web/components/workspace_components_signal_foundry_test.exs`

**Interfaces:**

- `<.workbench_chassis id surface index title status return_to return_instrument_id>` with `:primary_action`, `:local_modes`, `:primary_field`, `:signal_panel`, and `:command_dock` slots.
- Stable outer IDs `instrument-workbench-<surface>` and `return-to-instrument-deck-<surface>`.

- [ ] **Step 1: Write component tests** for chassis slots, replace-patch Return link, accessible status, no duplicate global nav, mobile signal order, and command dock presence.
- [ ] **Step 2: Implement the generic chassis in `WorkspaceComponents`.** Use opaque themed surfaces, 28–30px chassis radius, local mode tabs, responsive primary/signal grid, and one command dock slot.
- [ ] **Step 3: Render the existing prompt composer inside the chassis dock.** Preserve `#prompt-composer`, `#prompt-form`, model/tools/swarm controls, setup events, and form semantics; deck state uses compact capsule, Chat uses expanded form.
- [ ] **Step 4: Add explicit `replace` Return patch behavior matching the URL contract; retain the persistent InstrumentDeck hook attributes.
- [ ] **Step 5: Add real connection status styles and reduced-motion/mobile sheet classes; no inline scripts.
- [ ] **Step 6: Run component/adversarial workspace tests and `mix assets.build`.
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/components/workspace_components_workbench_test.exs test/iex_code_web/components/workspace_components_signal_foundry_test.exs && git commit -m "feat: add shared Signal Foundry workbench chassis"`.

---

## Slice D — Workbench Families

### Task 11: Mission Board / Kanban keyboard move and calendar agenda

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs`
- Create: `test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs`
- Update: `test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs`

- [ ] **Step 1: Add `moving_task_id`, `task_move_form`, and `task_move_announcement` assigns plus `open_task_move`, `cancel_task_move`, and nested `move_task` events.** Keep the existing flat drag payload event.
- [ ] **Step 2: Render each task as a noninteractive row with sibling `#task-card-<id>` and `#move-task-trigger-<id>` controls.** Use a native status select in `#move-task-form-<id>`, exact live announcement `Moved <task title> to <status>`, and `push_event("focus_task", %{id: ...})`.
- [ ] **Step 3: Add `#task-move-live-region` and the mobile task-detail `ModalFocus`/ResponsiveSheet` semantics.** Preserve all Kanban IDs/events and pointer drag behavior.
- [ ] **Step 4: Restyle Kanban as flat instrument channels and quiet gauges using the shared tokens; remove per-status rainbow accents.
- [ ] **Step 5: Add pure `calendar_agenda_items/2`, bounded to 100 real scheduled tasks sorted by timestamp/id.** Render `#calendar-mobile-agenda` below 640px and `#calendar-month-view` at/above 640px. Remove any fabricated monthly metric.
- [ ] **Step 6: Preserve calendar full-date cell matching, Monday-first weekdays, detail/edit/delete/run-now IDs/events, confirmations, and pending states.
- [ ] **Step 7: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs test/iex_code_web/live/workspace_live_kanban_scope_test.exs test/iex_code_web/live/kanban_workflow_stress_test.exs`; run `mix assets.build`.
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/live/workspace_live_signal_foundry_kanban_test.exs test/iex_code_web/live/workspace_live_signal_foundry_calendar_test.exs && git commit -m "feat: redesign mission board and schedule instruments"`.

### Task 12: Mission Control / Coach & Swarm workbench

**Files:**

- Modify: `lib/iex_code_web/components/run_components.ex`
- Modify: `lib/iex_code_web/components/workspace_components.ex` if chassis slots need no new run-specific behavior
- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `assets/css/app.css`
- Create: `test/iex_code_web/components/run_components_mission_test.exs`
- Update: `test/iex_code_web/live/workspace_live_async_runs_test.exs`

- [ ] **Step 1: Add validated `@mission_control_modes = ~w(overview topology execution journal)` and `mission_control_mode` assign/event.
- [ ] **Step 2: Add `workbench_chassis` wrapper `#instrument-workbench-swarm` and preserve all existing durable run IDs/events, including ledger, detail, actions, steering, budgets, steps, DAG, approvals, events, artifacts, locks, and fleet.
- [ ] **Step 3: Add the instrument hero, factual phase derivation, semantic waveform, local mode tabs, and `#mission-control-signal-panel`.** Pending approvals take precedence, then selected lock, failed/interrupted state, dispatcher offline, then `No operator decision required`.
- [ ] **Step 4: Keep all durable sections mounted with `<details>`/mode styling so current tests can still find IDs even when the overview visually emphasizes only the focal story. Keep legacy interactive Coach controls in a named local session mode.
- [ ] **Step 5: Use deterministic Active Mission selection only when entering swarm; leave generic selected-run behavior untouched elsewhere.
- [ ] **Step 6: Test no-run standby, running phase, local tab ARIA, truthful attention text, sensitive-field omission, active-run tie breaking, Return, and every existing pause/resume/cancel/retry/steer/approval/agent control.
- [ ] **Step 7: Run the full Mission Control component/live suite from the spec, then `mix assets.build`.
- [ ] **Step 8: Commit:** `git add lib/iex_code_web/components/run_components.ex lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/components/run_components_mission_test.exs test/iex_code_web/live/workspace_live_async_runs_test.exs && git commit -m "feat: focus Mission Control as an instrument workbench"`.

### Task 13: Research Radar and evidence workbench

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Consume the Signal Foundry DAG styling owned by Task 12; do not modify `lib/iex_code_web/components/dag_components.ex` in this task.
- Modify: `assets/css/app.css`
- Create or update: `test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs`
- Update: `test/iex_code_web/live/workspace_live_deep_research_test.exs`

- [ ] **Step 1: Wrap canonical research routes in `#instrument-workbench-research`; preserve `#deep-research-page`, all form/provider/result/download IDs, current scope, and report controller behavior.
- [ ] **Step 2: Reorder the form into numbered objective/depth/sources/run-contract stages using native controls and actual `research_level_semantics/1`; retain idempotency and `phx-disable-with`.
- [ ] **Step 3: Ensure `open_research_run` stays on `/research` or `/sessions/:id/research`, selects bounded research step summaries, and renders DAG projection only for authorized `dag_v1` data. Legacy/nonprojected runs show factual status/progress text.
- [ ] **Step 4: Render recent runs and ready reports as evidence instruments with public result number, level, source count, checksums/artifact readiness, and existing Open/HTML/Markdown actions.
- [ ] **Step 5: Test canonical route, stages, levels, selected-run URL stability, DAG/legacy fallback, foreign-session rejection, providers, attachments, idempotency, and script-free report downloads.
- [ ] **Step 6: Run `mix test test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs test/iex_code_web/controllers/research_report_controller_test.exs test/iex_code/research/results_test.exs test/iex_code/research/html_report_test.exs`; run `mix assets.build`.
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/live/workspace_live.html.heex assets/css/app.css test/iex_code_web/live/workspace_live_signal_foundry_research_test.exs test/iex_code_web/live/workspace_live_deep_research_test.exs && git commit -m "feat: redesign research as an evidence instrument"`.

### Task 14: Changes, Chat, Files, Terminal, and Settings workbenches

**Files:**

- Modify: `lib/iex_code_web/live/workspace_live.html.heex`
- Modify: `lib/iex_code_web/live/workspace_live.ex`
- Modify: `lib/iex_code_web/components/workspace_components.ex`
- Modify: `lib/iex_code_web/live/settings_live.html.heex`
- Modify: `lib/iex_code_web/live/settings_live.ex` only for theme/runtime presentation state
- Modify: `assets/css/app.css`
- Update: `assets/js/hooks/terminal_hook.js`
- Update: `test/iex_code_web/live/workspace_live_editor_diffs_test.exs`
- Update: `test/iex_code_web/live/workspace_live_ast_git_test.exs`
- Update: `test/iex_code_web/live/workspace_live_functional_state_test.exs`
- Update: `test/iex_code_web/live/workspace_live_terminal_test.exs`
- Update: `test/iex_code_web/live/settings_live_test.exs`

- [ ] **Step 1: Changes/Change Ledger.** Wrap in `#instrument-workbench-changes`; preserve `changes-toolbar`, `changes-layout`, staging/diff/branch/fetch/pull/commit IDs and readable code. Show bounded Git counts, `status.truncated?`, and latest `run_tests` operation only.
- [ ] **Step 2: Chat/Conversation Loop.** Wrap in `#instrument-workbench-chat`; preserve `#chat-viewport`, timeline/message IDs, pagination/events, and expanded `#prompt-form`. Replace phone minimap with accessible jump control; use `latest_message_summary` and normal sans prose.
- [ ] **Step 3: Files/File Atlas.** Wrap in `#instrument-workbench-files`; preserve tree/filter/editor/open-buffer/dirty/save/revert/copy/AST IDs/events. Label retained file count `500+ files indexed` when `@files_more?`; use `@selected_file`, not `@active_editor_path`.
- [ ] **Step 4: Terminal/Terminal Scope.** Wrap in `#instrument-workbench-terminal`; preserve `#terminal-session-container`, `#terminal-xterm-wrapper`, `#terminal-xterm-container`, `#terminal-form`, quick actions, PTY ownership, and all terminal events. Verify `phx-update="ignore"`, theme recolor without remount, and listener teardown.
- [ ] **Step 5: Settings/Calibration Bench.** Restyle dedicated SettingsLive with shared chassis/tokens and readable forms. Keep its single `#settings-form` and all fields. Remove workspace duplicate modal/form per Task 9; migrate all modal tests to navigation/SettingsLive outcomes.
- [ ] **Step 6: Run the grouped Changes/Chat/Files/Terminal/Settings suites from the spec plus terminal E2E; run `mix assets.build`.
- [ ] **Step 7: Commit:** `git add lib/iex_code_web/live/workspace_live.html.heex lib/iex_code_web/live/workspace_live.ex lib/iex_code_web/components/workspace_components.ex lib/iex_code_web/live/settings_live.html.heex lib/iex_code_web/live/settings_live.ex assets/css/app.css assets/js/hooks/terminal_hook.js test/iex_code_web/live test/iex_code_web/components && git commit -m "feat: move inspect and operate tools into Signal Foundry workbenches"`.

### Task 15: Static design/accessibility audit and focused regression repair

**Files:** files identified by audit; no new product behavior

- [ ] **Step 1: Run `mix format --check-formatted` and `git diff --check`.
- [ ] **Step 2: Audit with:**

```bash
grep -RIn '@apply\|<script\|https\?://.*\(css\|js\|woff\)' assets lib/iex_code_web
grep -RIn 'rainbow\|neon\|drop-shadow\|linear-gradient' assets/css/app.css lib/iex_code_web
find priv/static/fonts -maxdepth 1 -type f -print
```

- [ ] **Step 3: Remove only legacy visual rules that are still applied to migrated surfaces; retain the single approved ambient outer radial gradient and required untouched vendor styles.
- [ ] **Step 4: Check all new controls for labels/IDs, 44px coarse-pointer targets, contrast token pairs, `aria-live` scope, no nested buttons, and `phx-hook` IDs/ignore attributes.
- [ ] **Step 5: Run targeted LiveView tests for every changed family and repair failures without weakening assertions or adding duplicate hidden controls.
- [ ] **Step 6: Commit repairs as `fix: tighten Signal Foundry accessibility and visual contracts`.

---

## Final Verification and Release Gate

### Task 16: Automated release gate

- [ ] Run `mix assets.build`; JavaScript behavior is verified in the Ego Lite matrix below because this repository has no standalone JavaScript test runner.
- [ ] Run the exact terminal gate: `mix test test/iex_code/e2e_terminal/e2e_pty_terminal_test.exs test/iex_code/tools/terminal_stress_test.exs`.
- [ ] Run the complete `mix precommit` alias. If it formats or unlocks dependencies, rerun targeted tests and `mix assets.build` and inspect the diff.
- [ ] Run `git diff --check` and `git status --short`; do not include `.superpowers/` companion artifacts in commits.

### Task 17: Ego Lite browser matrix (last, never wipe sessions)

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

### Task 18: Final review and merge decision

- [ ] Review every changed template for `<Layouts.app>` wrapper, `current_scope`, `<.input>`, `<.form for={@form}>`, `<.icon>`, unique IDs, and HEEx class-list syntax.
- [ ] Review every new Elixir block for immutable rebinding correctness, no list index access syntax, no struct map access, no nested modules, and no user-input `String.to_atom/1`.
- [ ] Confirm all four slices have their own commits and targeted green tests.
- [ ] Confirm no backend execution/security behavior changed outside the explicitly bounded `Kanban.summary/2`, theme cookie, and view-state plumbing.
- [ ] Report final verification evidence with commands and outcomes before claiming completion.

## Self-Review Checklist

- [ ] Every requirement in the approved spec maps to Task 1–18: themes/font/root, URL state, summary truth, deck, resume, switchboard, chassis, command dock, all workbench families, accessibility, responsive states, settings migration, Ego Lite, and final gates.
- [ ] No task depends on an undefined interface: `Kanban.summary/2`, `InstrumentSummary.build/1`, `@workspace_views`, `@active_view`, `workbench_chassis/1`, `instrument_deck_hook`, and `terminal_available?` are defined above before use.
- [ ] No task asks for fabricated metrics or unspecified data sources.
- [ ] No task removes legacy IDs/events before a replacement test and migration step.
- [ ] No plan step uses a placeholder such as TBD/TODO or an undefined “handle edge cases” instruction.
- [ ] Each slice ends with an independently runnable test/build gate; the final gate adds Ego Lite and `mix precommit`.
