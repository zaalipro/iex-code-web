# Signal Foundry UI/UX Redesign

**Date:** 2026-08-28  
**Status:** Approved in visual brainstorming; awaiting written-spec review  
**Application:** IexCode Web

## Summary

IexCode Web will be redesigned as **Signal Foundry**: a field of tactile, purpose-built software instruments rather than a conventional SaaS dashboard. The redesign is based on the user's approved visual reference and the approved dark, light, overview, and focused-workbench mockups.

The default project view becomes an **Instrument Deck**. Each instrument exposes one honest, immediately useful signal and opens the corresponding existing IexCode workflow. Opening an instrument expands it into a focused workbench while preserving its identity, visualization, live state, and command context.

The redesign changes presentation and information architecture, not the underlying execution model. Durable runs, OTP supervision, SQLite persistence, research workflows, Git operations, native PTY behavior, routes, authorization, LiveView events, and safety boundaries remain intact.

## Goals

1. Give IexCode a distinctive visual identity that feels like a collection of precision instruments.
2. Make system state understandable at a glance without inventing metrics or duplicating large collections in LiveView assigns.
3. Replace the permanent sidebar and duplicated eight-tab navigation with the Instrument Deck, a searchable switchboard, direct card navigation, and the existing command palette.
4. Preserve every current workflow while reducing equal-weight chrome and nested-card fatigue.
5. Provide equally intentional dark and light themes with shared geometry and semantics.
6. Improve responsive behavior, touch targets, keyboard access, focus handling, status communication, and reduced-motion support.
7. Keep the redesign compatible with Phoenix 1.8, LiveView 1.2, Tailwind v4, the existing `app.js`/`app.css` bundles, and test-sensitive DOM IDs and events.

## Success Criteria

- A project opens on a recognizable Signal Foundry Instrument Deck.
- The user can identify active work, waiting decisions, and unhealthy state without opening a workbench.
- All eight current workspace surfaces remain reachable within one action from the deck or switchboard.
- A focused workbench exposes dense functionality without looking like a new dashboard inside the deck.
- Dark and light themes both feel materially designed; light is not a simple inversion.
- No instrument shows fabricated or placeholder operational data.
- Critical keyboard, mobile, terminal, route, and LiveView behaviors continue to pass automated and browser verification.

## Existing Product Constraints

- IexCode is a self-hosted, single-trusted-operator coding control plane.
- Commands and tools act directly in the selected project root; there is no OS sandbox or shadow workspace.
- The application must keep workspace locks, leases, approvals, budgets, run controls, and runtime health visible.
- Existing authenticated routes, current-scope handling, research routes, report downloads, and health routes remain valid.
- Existing LiveView event names and test-sensitive IDs must remain or receive stable compatibility anchors.
- Templates continue to start with `<Layouts.app flash={@flash} current_scope={@current_scope}>` where required.
- No external script or stylesheet URLs are added to layouts. New frontend assets must be bundled locally through `app.js` or `app.css`.
- No new charting dependency is needed; instrument graphics use semantic HTML, CSS, and inline SVG.

## Design Principles

### Software as physical instrumentation

The visual identity comes from object presence, strict information composition, and purpose-built visualization—not from dark colors alone. Every instrument repeats a common grammar:

1. Index and concise uppercase label.
2. One dominant status, value, or phrase.
3. One bespoke visualization tied to real product semantics.
4. Sparse footer facts or a single next action.

Approximately half of each overview card remains visually quiet. Data does not get enclosed in nested cards.

### One rare signal color

Vermilion represents live activity, attention, selected execution steps, and review gates. It occupies less than roughly one percent of a normal screen. It does not fill large cards or ordinary primary buttons. Success, warning, and error states include text or shape in addition to color.

### Each surface earns its own visual metaphor

Examples include a run orbit, fleet pulse bars, research radar, schedule chronometer, diff waveform, terminal scope, file topology, and task progression path. Decorative charts and invented scores are forbidden.

### Readability before imitation

The reference's tiny display typography is a visual influence, not a production font-size specification. Essential controls and labels remain readable, keyboard accessible, and touch friendly.

## Visual System

### Dark theme: Signal Foundry

| Role | Value |
| --- | --- |
| Ambient canvas | `#171514` with restrained warm-stone radial light fading to graphite |
| Deep canvas | `#101214` |
| Instrument surface | `#0B0E10` to `#151616`, with no colored internal gradient |
| Raised control | `#1D1F20` |
| Primary text | `#F4EFE7` |
| Secondary text | `#918B84` |
| Hairline | `rgba(255, 255, 255, 0.10)` |
| Live/attention signal | `#F6532E` |
| Success | `#9EBDA7` |
| Semantic cool signal | `#9DAEC2`, reserved for neutral telemetry paths and non-status topology nodes |

The environment uses one broad warm ambient radial gradient fading into graphite. Instrument faces remain matte and solid.

### Light theme: Signal Foundry Daylight

| Role | Value |
| --- | --- |
| Ambient canvas | `#EAE5DC` with warm vellum illumination |
| Instrument surface | `#F3EEE5` or `#FBF8F2` |
| Raised control | `#EEE8DF` |
| Primary text | `#202321` |
| Secondary text | `#655F58` (at least 5.03:1 against the listed light surfaces) |
| Hairline | `rgba(23, 25, 26, 0.14)` |
| Live/attention mark | `#D74628`; marks and large display text only |
| Live/attention text | `#A8321F` (at least 5.33:1) |
| Success mark | `#60836E`; non-text marks only |
| Success text | `#42624F` (at least 5.41:1) |
| Semantic slate text | `#4E6170` (at least 5.12:1) |

Light mode renders bone-ceramic instruments with soft umber shadows. It preserves the same object model and data hierarchy instead of simply swapping foreground and background colors.

### Typography

- Vendor the OFL-licensed **Doto** variable font at `priv/static/fonts/doto-variable.woff2` with its license text at `priv/static/fonts/OFL.txt`; `IexCodeWeb.static_paths/0` already serves `fonts`. It is used for large values, short statuses, card indices, and selected instrument labels only.
- Use the existing system sans stack for prose, forms, settings, chat messages, and explanations.
- Use the existing system monospace stack for code, commands, paths, hashes, and terminal-adjacent metadata.
- Essential metadata is at least 12px at production scale. Body text is at least 14px. Display values use responsive `clamp()` sizing within a 28px to 64px range.
- Display words use generous tracking; long prose never uses the dot-display face.

### Geometry and depth

- Instrument cards: 22px radius.
- Workbench chassis and major sheets: 28–30px radius.
- Inputs and compact controls: 14–18px radius.
- Action capsules and the command dock: full pill geometry.
- Touch targets: at least 44 by 44 CSS pixels on coarse-pointer layouts.
- Overview instruments use an alternating optical offset no greater than 1px or `0.2deg` at widths of 1280px and above. Focused workbenches, mobile views, keyboard-focused cards, and reduced-motion layouts remain aligned.
- Depth uses a low-contrast edge, faint inset top highlight, and broad diffuse shadow. Neon glow, rainbow borders, and colored drop shadows are excluded.

### Motion

- Hover lifts an overview instrument by at most 2–3px.
- Live updates animate only the relevant dots, waveform segment, or timeline marker.
- Opening an instrument uses a 180ms CSS scale-and-opacity transition on the entering workbench. It does not depend on the browser View Transitions API and never delays LiveView navigation.
- Initial page appearance does not animate every card.
- `prefers-reduced-motion: reduce` removes tilt, lift, smooth scrolling, waveform travel, and transition choreography.

## Information Architecture

### Project entry

- `/` and `/sessions/:id` open the Instrument Deck by default.
- A stored last-instrument value produces a small `Resume <instrument title>` signal on the deck, such as **Resume Mission** or **Resume Terminal**.
- The application does not automatically bypass the deck on ordinary project entry.
- Explicit deep links, including research and settings URLs, open their intended target directly.
- Browser back from a workbench returns to the deck and restores the previous deck scroll position and focused card.

### View and URL contract

The workspace has one explicit closed view set: `deck`, `kanban`, `swarm`, `research`, `calendar`, `changes`, `chat`, `files`, and `terminal`. `deck` is the new default view; the other eight values are the existing workspace tabs.

- `/` and `/sessions/:id` with no `view` query parameter resolve to `deck`.
- On the root route, non-research deck links use `/?view=<value>` and the Return control uses `/`; on a session route, non-research deck links use `/sessions/:id?view=<value>` and Return uses `/sessions/:id`.
- `/sessions/:id?view=deck` resolves to `deck`.
- `/sessions/:id?view=kanban`, `swarm`, `calendar`, `changes`, `chat`, `files`, or `terminal` resolve to the corresponding existing workbench.
- `/research` and `/sessions/:id/research` always resolve to the research workbench and remain canonical deep links. A conflicting `view` parameter is ignored and removed with a replace navigation.
- `/settings` and `/sessions/:id/settings` remain separate SettingsLive routes.
- A missing, malformed, or unsupported `view` value resolves to `deck` with a replace navigation and no exception.
- `WorkspaceLive` keeps the existing `@workspace_tabs` list for compatibility and introduces a separate `@workspace_views` list containing `deck` plus those tabs. `active_tab` remains the compatibility assign; `active_view` is the canonical navigation assign.
- Clicking a non-research instrument or switchboard item issues a `push_patch` to the matching `view` URL, creating one browser-history entry. The existing `switch_tab` event remains the server event used to validate and activate that destination. Research is the sole exception: from `/` it patches to `/research`, and from `/sessions/:id` it patches to `/sessions/:id/research`.
- The visible **← Instrument Deck** control issues a `push_patch` with `replace: true` to the deck URL. This prevents a second deck entry, so browser Back from a workbench returns to the page before the workbench rather than reopening it.
- Browser Back/Forward is handled by `handle_params/3`; it never relies on client-only tab state.

### Top mission strip

The permanent top strip is deliberately quiet. It contains exactly:

- IexCode mark and project switcher.
- Current project/session context.
- Connection/runtime status.
- Dark/light toggle.
- `Cmd/Ctrl+K` command palette trigger.
- One contextual primary action: **New mission** on the deck, or the active workbench's documented primary action.
- A profile/settings utility that opens the switchboard's Settings and Account groups.

It is not a second tab bar.

### Instrument Deck

The fixed eight-instrument deck maps directly to existing workspace surfaces:

| Instrument | Destination | Honest overview signal |
| --- | --- | --- |
| 01 Active Mission | Coach & Swarm / Mission Control | Selected active or most recent durable run, current phase, progress, next review gate |
| 02 Mission Board | Kanban | Project-wide status counts and progression through current statuses |
| 03 Research Radar | Deep Research | Latest run level/state, completed rounds, sources, result readiness |
| 04 Schedule Chronometer | Calendar | Next scheduled action and today's project task count |
| 05 Change Ledger | Changes & Diffs | Bounded Git branch and staged/unstaged/untracked summary, plus latest test operation |
| 06 Conversation Loop | Chat | Latest durable message summary and timestamp; newer-page availability when factual |
| 07 File Atlas | Files & Editor | Loaded-file bound, current selected buffer, dirty state, and bounded Git relation |
| 08 Terminal Scope | Terminal | PTY state, active/last command, exit/idle signal, ownership state |

Runtime health is always visible in the mission strip. Detailed Runtime, Usage, Providers, Models, Goals, Swarm, Research, Editor, and Resources configuration remain in Settings rather than consuming additional deck cards.

The runtime signal is distinct from LiveSocket connectivity:

- **Connection** reports `Connected` or `Signal paused · reconnecting` from browser socket callbacks.
- **Runtime** comes from the failure-tolerant `IexCode.Observability.RuntimeStatus.snapshot/0`, whose call is bounded to one second.
- WorkspaceLive starts one `start_async(:runtime_status, fn -> RuntimeStatus.snapshot() end)` job on connected mount and schedules another every five seconds after the prior result is handled, matching SettingsLive's existing cadence without blocking the LiveView. Only one runtime snapshot job is in flight.
- Runtime state `:active` renders `Runtime active`; `:idle` renders `Runtime idle`; `:unavailable` renders `Runtime unavailable` and never appears healthy.
- Governor `:pressure` and `:critical` override the neutral runtime presentation with explicit `Resource pressure` or `Critical resource pressure` attention text.
- The strip shows bounded dispatcher active/queued/capacity counts when the snapshot supplies all three; otherwise it shows only the runtime label. It never shows IDs, objectives, prompts, or lease values.
- The refresh timer is scoped to the LiveView process and disappears when the process terminates.

The deck is a fixed small set, not a LiveView stream. It consumes small derived summary maps and does not duplicate large message, event, file, or task collections in socket assigns.

### Closed summary contract

Each instrument summary has exactly this bounded shape:

```elixir
%{
  surface: "kanban" | "swarm" | "research" | "calendar" | "changes" | "chat" | "files" | "terminal",
  title: String.t(),
  status: :ready | :active | :attention | :empty | :error | :standby,
  primary: String.t() | nil,
  secondary: [%{label: String.t(), value: String.t()}],
  detail: String.t() | nil,
  destination: String.t(),
  updated_at: DateTime.t() | nil,
  attention?: boolean()
}
```

`primary`, `detail`, and secondary values are bounded to 160 UTF-8 characters; no summary contains full message bodies, event journals, credentials, process IDs, lease owners, or arbitrary user-provided metadata.

The following source and fallback rules are mandatory:

| Surface | Source and selection rule | Refresh trigger | Factual fallbacks |
| --- | --- | --- | --- |
| Active Mission | `Runs.list_runs(session_id: ..., limit: 100)`; select the first `running`, then `paused`, then `queued`, then `draft`, otherwise the newest terminal run. Progress comes from `run.progress`; phase comes from the first running/paused step or latest completed step title; review comes from `Runs.count_pending_approvals/1`. | Existing run create/update/event/control/agent notifications; selected-run refresh. | No run → `No active run`; no phase → `Status: <run status>`; failed/interrupted → attention. |
| Mission Board | New bounded `Kanban.summary(project_id, today: Date.utc_today())` query returns one count per `Task.statuses/0`, today's scheduled count, and the next future `scheduled_at`. It is never derived from filtered `@tasks`. | `:task_created`, `:task_updated`, `:task_deleted`, and project switch. | No tasks → `No tasks yet`; query failure → `Board unavailable`. |
| Research Radar | `research_runs` from the durable run list, newest first; level from run metadata or matching `ResearchResult.level`; one bounded `Runs.list_step_summaries/1` lookup for that newest research run supplies completed steps, and completed round is the maximum `params["round"]` among them, bounded to 1–4; source count comes from the matching ready result; readiness comes from `length(@research_results)`. | Existing run create/update/step notifications, `:research_result_updated`, session switch, and reconnect refresh the newest run's bounded step summary. | No run/result → `No research runs`; queued/running → explicit state; failed/cancelled → explicit state. |
| Schedule Chronometer | The same bounded Kanban summary returns the minimum future `scheduled_at` and today's count in UTC; display converts to the browser timezone only for presentation. | Task notifications and project switch. | No future task → `No scheduled actions`; no today tasks → `0 today`. |
| Change Ledger | Only the latest successful `refresh_git_state/1` result; counts are exact lengths of staged/unstaged/untracked/conflicted arrays and include `status.truncated?`. Branch comes from `current_branch`. Deck entry starts one bounded asynchronous Git summary refresh so mount is not blocked. | Entering the Deck or Changes, explicit Git refresh/fetch/pull/save actions, project switch, and reconnect; there is no periodic native Git polling. | `git_status == nil` → `Warming · checking Git`; `git_error` → `Git unavailable`; truncated → `Showing bounded Git status`. |
| Conversation Loop | A new `Sessions.list_messages(session_id, limit: 1, content_limit: 160)` query initializes and updates `latest_message_summary`; it is not inferred from the tail of the paged `@messages`. `@messages_newer?` is labeled only `Newer messages available`, never an unread count. | `:message_created`, session switch, and reconnect. | No message → `No messages yet`; no streaming claim is made because no durable streaming boolean exists. |
| File Atlas | Only after `WorkspaceFiles.page/2` loads; use `length(@project_files)` as a retained count and show `500+ files indexed` when `@files_more?`; active path is `@selected_file`; Git relation is shown only when Git status exists and is labeled bounded when truncated. | File load/open/save/revert/close actions, project switch, Git refresh, and reconnect. | Not loaded → `Standby · files not loaded`; empty → `No files discovered`. |
| Terminal Scope | `TerminalServer.get_state/1` and existing terminal assigns; add a `terminal_available?` assign that is `true` only for `{:ok, state}` and `false` for `{:error, _}`. Active command wins, then latest nonblank history command. | Existing terminal output/status/occupant/command/resize notifications and session switch. | `terminal_available? == false` → `Terminal unavailable`; real idle → `Idle · no active command`; no history → `No command yet`. |

The latest test fact is not a general Git metric: if `@operations` contains a newest row with `op_type == "run_tests"`, Change Ledger shows it as **Latest test operation** with status and duration only. If no such row exists, it shows **No test operation recorded**. It never infers coverage or current pass state.

The active-run selection is deterministic and independent of the existing `selected_run` default: opening instrument 01 assigns the selected active/queued/draft run to the Mission Control workbench, or the newest terminal run when no nonterminal run exists. Other workbenches continue to use their existing selection semantics.

`Kanban.summary/2` returns `%{status_counts: %{status => non_neg_integer()}, today_count: non_neg_integer(), next_scheduled_at: DateTime.t() | nil}`. It restricts by `project_id`, groups only the closed `Task.statuses/0` values, compares dates in UTC, and never returns task descriptions or unbounded rows.

### Switchboard and command palette

- The existing command palette becomes the searchable Signal Foundry switchboard.
- It opens from the mark, an **All instruments** control, or `Cmd/Ctrl+K`.
- It includes all eight workbenches, projects, sessions, research, settings, and current commands.
- Research must be added to the palette's current view index.
- Keyboard arrow navigation, Enter execution, Escape dismissal, focus trapping, and focus restoration remain supported.
- On mobile, the switchboard becomes an accessible bottom sheet.

The permanent sidebar is removed only after every displaced action has a defined replacement:

| Current sidebar action | Signal Foundry location |
| --- | --- |
| Open/search/switch project | Project switcher in the top mission strip and the switchboard's Projects group |
| Create project/workspace | **New project** action in the project switcher; reuses `toggle_project_modal` and the existing validated project form |
| Search/switch session | Switchboard Sessions group and top-strip session control |
| Create session | **New session** action in the switchboard and session control; reuses `new_session` |
| Delete session | Session-row overflow action with the existing explicit confirmation; reuses `delete_session` |
| Open Models/API settings | Switchboard Settings group → `/sessions/:id/settings#models` |
| Open general settings | Switchboard Settings group → `/sessions/:id/settings#execution` |
| Open Runtime | Top runtime signal and switchboard → `/sessions/:id/settings#runtime` |
| Sign out | Account utility in the top strip and switchboard; preserves the existing CSRF-protected logout form |

All replacements are keyboard reachable. Destructive actions remain labeled, confirmed, and available in the mobile bottom sheet.

### Command dock

The existing prompt composer becomes a floating command instrument:

- On the deck it is a compact single-line capsule.
- In Chat it expands by default.
- In other workbenches it expands on focus.
- Attachments, research context, tools, swarm mode, model selection, and dispatch remain available.
- Run setup, providers, budgets, and advanced options open in a secondary rounded tray rather than expanding the primary viewport permanently.
- The send control uses a thin vermilion ring or signal mark instead of a large filled accent button.

## Navigation and Resume State

- Keep the canonical paths `/`, `/sessions/:id`, `/research`, `/sessions/:id/research`, `/settings`, and `/sessions/:id/settings`; apply the exact view contract above for workspace query parameters.
- Store the last instrument in `localStorage`, keyed by project and session identifiers.
- A required `InstrumentDeck` hook sends the stored value to LiveView after mount. The server accepts only values from the closed `@workspace_tabs` set; `deck` is represented separately and invalid or stale values are ignored.
- Opening a workbench updates the stored value. Returning to the deck does not erase it.
- The resume signal is a shortcut, not an automatic redirect.

### Deck scroll and focus restoration protocol

The required `InstrumentDeck` hook is mounted on the persistent `#workspace-shell`, not on a conditionally rendered deck fragment. `#workspace-shell` exposes `data-active-view` on every render. The server does not store scroll positions; the hook owns ephemeral restoration in `sessionStorage` under `iexcode:deck-state:<project-id>:<session-id>` and stores `{scrollTop, focusedInstrumentId, capturedAt}`.

1. On `click` of a visible instrument link/button, the persistent hook immediately captures the deck scroller's `scrollTop` and the clicked element's stable `id` (`instrument-card-<surface>`) before the LiveView patch begins, writes the state to `sessionStorage`, and mirrors it into `history.state` for the current entry.
2. The hook also listens for `phx:page-loading-start`. If `data-active-view == "deck"`, it captures the current scroll and focused instrument before a programmatic patch such as a command-palette action. It removes this listener in `destroyed()`.
3. `mounted` and `updated` both handle the transition to `active_view == deck`: each waits for one `requestAnimationFrame`, restores the stored scroll position, then focuses the stored instrument without scrolling it again (`focus({preventScroll: true})`). This covers both persistent-hook updates and a full LiveView remount.
4. On a visible Return control, the hook captures the originating instrument ID before the replace patch; on browser Back/Forward it reads the matching `history.state` first and falls back to `sessionStorage`.
5. If the stored card no longer exists, focus falls back to `#instrument-deck-heading`, then the deck scroller itself. Scroll falls back to `0`.
6. The hook removes stale state after a successful restore only when the project/session key changes; ordinary deck/workbench round trips retain it.
7. A JS browser test covers click-away, Return, browser Back, missing-card fallback, and focus/scroll order at desktop and mobile widths.

## Expanded Workbench Pattern

Every deck card opens a focused workbench with the following anatomy:

1. **Return control:** `← Instrument Deck`, preserving deck position and focus.
2. **Instrument identity:** index, title, live status, and one contextual primary action.
3. **Local modes:** workbench-specific tabs or segmented controls, never a duplicate global navigation row.
4. **Primary field:** the real workflow and its signature visualization.
5. **Signal panel:** only decisions, errors, locks, approvals, or context that currently need attention.
6. **Command dock:** contextual command and steering surface.

At widths below 1024px the signal panel renders below the primary field. On mobile, task details, the switchboard, and destructive confirmations use modal sheets with focus isolation; ordinary signal text remains inline.

### Workbench-specific treatment

#### Active Mission / Coach & Swarm

- Uses the approved agent topology, live execution waveform, phase tabs, and **What needs you** signal panel.
- Existing run ledger, fleet, DAG steps, events, controls, approvals, journal, artifacts, locks, budgets, pause/resume/cancel/retry, and steering remain available through local modes.
- Dense sections are progressively disclosed; the initial view prioritizes objective, current phase, next decision, and safety state.

#### Mission Board / Kanban

- Statuses become flat instrument channels separated by hairlines, not tall nested card columns.
- One selected channel is expanded by default. Activating another channel expands it and collapses the previous one; all quiet channels render as labeled gauges.
- Pointer drag-and-drop remains available. Every task also exposes a visible-on-focus **Move task** button that opens a native status select followed by a **Move** action; this is the canonical keyboard and touch alternative.
- After a successful move, focus returns to the same task in its new channel and a polite live region announces `Moved <task title> to <status>`. Escape closes the move control without changing state and returns focus to its trigger.
- The existing task-detail drawer becomes a rounded side instrument with correct dialog semantics on mobile.
- Filters and counts remain visible without making every status a different accent color.

#### Research Radar

- The launch form is a calibrated sequence: objective, depth, sources/providers, then a visible run contract.
- Current research progress uses a real DAG/checkpoint visualization.
- Ready reports appear as evidence instruments with source and artifact state.
- Exported Markdown and self-contained HTML remain downloadable and script free.

#### Schedule Chronometer

- Desktop retains an accessible month view with a clear agenda rail.
- Mobile defaults to an agenda/list view instead of squeezing a seven-column calendar.
- Scheduled tasks expose run-now, edit, and delete actions with pending/confirmation states.

#### Change Ledger

- Staged, unstaged, and untracked state use a quiet ledger and one diff waveform summary.
- The detailed workbench preserves current staging, hunk, revert, branch, fetch, pull, commit-message, and commit behavior.
- Diff content remains a readable code surface, not dot typography.

#### Conversation Loop

- Chat messages use normal readable typography.
- Thinking/tool traces use instrument dividers and event marks rather than nested cards.
- The command dock remains expanded and is the principal action.
- The current scroll minimap is hidden on phones and replaced by an accessible jump-to-message control.

#### File Atlas

- The tree and editor become two surfaces in one focused chassis, with optional focus mode.
- Existing open buffers, dirty/save/revert/copy actions, AST results, and file-line jumps remain intact.
- Code uses the existing editor/monospace treatment, not the dot-display face.

#### Terminal Scope

- The PTY remains the central surface, with command trace and state instrumentation around it.
- Existing quick actions, form, history, signals, restart/kill behavior, resizing, and xterm integration remain intact.
- Xterm colors update when the application theme changes.

#### Settings / Calibration Bench

- The dedicated Settings LiveView remains the single settings source of truth.
- The legacy workspace settings modal is removed. `toggle_settings_modal` remains as a compatibility event handler that performs a `push_navigate` to `/sessions/:id/settings#execution`; it never renders a second form.
- The legacy `#settings-modal` and the workspace's duplicate `#settings-form` are intentionally retired. Their UI tests are migrated to SettingsLive; the dedicated SettingsLive `#settings-form` and all field IDs remain stable.
- Settings uses the same chassis, control geometry, status signals, and theme tokens, but prioritizes readable forms over decorative visualization.

## Theme Behavior

- First visit follows the system preference.
- Add `IexCodeWeb.Plugs.Theme` to the browser pipeline after `:fetch_session` and before `:put_root_layout`. It fetches cookies, accepts only `dark` or `light` from the non-secret, non-HttpOnly `iexcode_theme` cookie, and writes the validated value to `conn.assigns.theme_preference`. The root layout reads that assign and emits the matching `data-theme` and `color-scheme` before CSS loads.
- When the cookie is absent, the root omits `data-theme`, uses `color-scheme: light dark`, and the base CSS selects the initial tokens with `prefers-color-scheme`; this makes a first system-based paint correct without inline JavaScript.
- The visible toggle switches directly between dark and light. `app.js` updates `data-theme`, `color-scheme`, a one-year `iexcode_theme` cookie scoped to `/` with `SameSite=Strict` (and `Secure` on HTTPS), and a `phx:theme` localStorage mirror used only for cross-tab synchronization.
- Legacy localStorage-only theme values are deliberately cleared on the redesign's first load rather than migrated, because the server cannot read them before first paint without forbidden inline JavaScript. The first post-redesign visit follows the system preference; the next explicit toggle establishes the flash-free cookie. Initialization always trusts the server-emitted preference before localStorage.
- Settings provides **System** as an explicit reset option while the mission-strip toggle remains a direct dark/light control.
- **System** removes both the cookie and localStorage preference and restores media-query behavior.
- With an explicit cookie, the root emits one `<meta name="theme-color">` using `#171514` for dark or `#EAE5DC` for light. Without a cookie, it emits two media-qualified theme-color tags for dark and light system preferences. `app.js` updates the resolved tag immediately on theme changes.
- `setTheme` dispatches `iexcode:theme-changed` with the resolved theme. `TerminalHook` applies the matching xterm palette on mount and on that event, then removes the listener in `destroyed()`.
- Theme changes do not move controls, alter data meaning, or reset the current workbench.
- Both themes meet contrast requirements against their actual surfaces.

## Data Flow

1. Existing contexts and LiveView assigns remain the source of truth.
2. WorkspaceLive derives a small `instrument_summaries` map from already loaded state or the bounded summary queries specified above.
3. Each summary contains a closed, typed shape for status, primary value, optional secondary facts, attention state, and destination.
4. Instrument components render only the summary and an inline visual representation.
5. Non-research cards use the existing validated `switch_tab` event, which assigns the view-specific state and issues the `push_patch` defined by the URL contract. Research uses `<.link patch={...}>` to its canonical research route. Settings uses `<.link navigate={...}>` to SettingsLive.
6. Workbenches continue using their existing data flow, streams, PubSub updates, and persistence boundaries.

Summary derivation must not enumerate LiveView streams, retain full event journals twice, or issue unbounded per-card queries. The only new aggregate query is `Kanban.summary/2`, which uses grouped counts and bounded date aggregates rather than loading all tasks. RuntimeStatus uses the single-flight async contract above. Deck Git status uses one single-flight `start_async(:deck_git_summary, ...)` job and the existing bounded Git options; stale results carry the project ID and are discarded after project switches. When summary data is unavailable, the instrument renders **Standby**, **No active run**, **No changes**, or another factual empty state.

## Loading, Error, and Resilience States

- Loading uses a restrained dot-sequence or instrument **Warming** state. Generic shimmer skeletons are not used.
- Pending mutation controls use `phx-disable-with`, visible busy language, and disabled repeat interaction.
- Disconnection uses a real DOM status banner with `role="status"` and `aria-live="polite"`; it is not CSS pseudo-content alone.
- A disconnected live instrument says **Signal paused · reconnecting** and keeps the last timestamp visible.
- Failed data retrieval replaces the visualization with a concise error, retry action where valid, and preserved surrounding navigation.
- Destructive actions retain explicit confirmation.
- Stale or invalid resume data is ignored safely and never converted to an atom.

## Responsive Behavior

### Wide desktop

- The deck uses a 12-column layout with a featured Active Mission instrument and compact peer instruments.
- At 1440px and wider, the deck uses four card units across; from 1024px through 1439px, it uses three; from 640px through 1023px it uses two; below 640px it uses one.
- The command dock remains centered and does not obscure the final content row.

### Tablet

- From 640px through 1023px, the deck uses two columns; a 1024px-wide landscape tablet uses the three-unit desktop rule.
- At widths below 1024px, expanded workbench signal panels collapse below the primary field.
- The switchboard remains a centered overlay.

### Mobile

- The deck becomes a one-column list of instruments with no rotation or perspective offset.
- The switchboard becomes a bottom sheet.
- Expanded workbenches become full-page surfaces.
- The command dock respects safe areas and uses two rows below 640px: context/tools above and input/dispatch below.
- Calendar defaults to agenda mode.
- The task detail drawer, switchboard, and destructive-confirmation overlays use real dialog semantics, inert background, Escape handling, and focus return.
- Essential controls remain at least 44px high.

## Accessibility

- Instrument cards are semantic buttons or links with concise accessible names and state descriptions. They contain no nested interactive controls.
- Inline SVG and dot visualizations are `aria-hidden` when the same meaning is present in text; otherwise they receive an accessible title and description.
- Status is never communicated by color alone.
- The deck and switchboard support logical tab order, Enter/Space activation, visible focus, and focus restoration.
- Live status regions announce only meaningful phase, completion, error, or connection changes—not every streamed token or animation frame.
- Essential text meets at least WCAG AA contrast.
- The display face is excluded from long text and critical form instructions.
- Existing skip link, reduced-motion CSS, command-palette focus trap, and modal focus behavior are retained and extended.
- Filters, settings choices, priority, status, and assignee controls use native selects. Searchable model, project, and session pickers remain custom comboboxes and implement Arrow, Home, End, typeahead, Escape, selection, and focus-return behavior with correct ARIA relationships.

## Component Boundaries

Implementation boundaries are:

- `IexCodeWeb.InstrumentComponents`: deck card shells, instrument headers/footers, truthful summary states, and reusable dot/SVG primitives.
- `IexCodeWeb.WorkspaceComponents`: switchboard, command dock, workbench chassis, context signal panel, and current workspace tools.
- `IexCodeWeb.RunComponents`: approved Mission Control topology and local modes.
- `WorkspaceLive`: deck/workbench state, validated view selection, summary derivation, and resume events.
- `SettingsLive`: Calibration Bench restyling and the only settings form flow.
- `app.css`: theme tokens, material surfaces, responsive deck geometry, motion, focus, and reduced-motion rules.
- `app.js`: existing theme behavior, theme-aware xterm notification, resume-state hook, and real connection-status updates.

No module is nested inside another module file. Large components should remain focused rather than moving the entire redesign into one new template.

The implementation preserves the existing Tailwind v4 `@import "tailwindcss" source(none)` and `@source` declarations, uses no `@apply`, adds no raw inline script, and keeps custom behavior in colocated or bundled hooks. Forms continue to use `to_form/2`, `<.form for={@form}>`, and the imported `<.input>` component where supported. Icons continue through `<.icon>`.

## Compatibility and Migration

- Preserve key existing IDs and LiveView event names used by tests, including workspace shell, tab, prompt, terminal, Kanban, file, command palette, run, research, and settings IDs.
- New instrument IDs use `instrument-card-<surface>` and `instrument-workbench-<surface>`.
- Existing tab event names remain stable. Where a current DOM ID has a direct semantic replacement, that ID moves to the visible instrument or local-mode control. Tests are updated when the information architecture has no one-to-one element. Hidden duplicate controls are not rendered solely to satisfy old tests.
- `toggle_workspace_menu`, `switch_project`, `toggle_project_modal`, `new_session`, `delete_session`, `open_settings_page`, and the existing logout form remain active. `workspace-switcher-search-form`, `new-session-btn`, `workspace-logout-form`, command-palette IDs, modal IDs unrelated to legacy settings, and all workbench content IDs remain stable or move to the visible replacement documented above.
- `toggle_settings_modal` becomes the navigation shim described in Settings. `show_settings_modal`, the legacy `#settings-modal`, and its duplicate workspace `#settings-form` are retired intentionally; corresponding tests move to SettingsLive.
- Preserve research links, current-scope assigns, and report downloads.
- Avoid a single all-at-once rewrite. Migrate the shell and theme tokens first, then the deck, then one workbench family at a time while keeping each step functional.

## Testing and Verification

### Automated tests

- Unit tests for each instrument-summary mapping, including standby, active, attention, error, and empty states.
- Context tests for `Kanban.summary/2`, including filtered-workspace independence, status grouping, UTC today counts, next scheduled action, and an empty project.
- LiveView tests that open every instrument, return to the deck, and verify the correct existing workbench IDs.
- Resume-state validation tests for allowed, stale, and invalid values.
- Theme-control markup and event tests.
- Direct-route tests for research and settings.
- LiveView keyboard-semantics tests for deck cards, switchboard markup, dialogs, and return controls.
- Kanban tests for the **Move task** control, valid/invalid status movement, focus target IDs, and live-region result text.
- Existing Kanban, run, research, Git, file, terminal, and settings interaction tests.
- Targeted terminal E2E tests documented in `TEST_READY.md`.

Tests should assert stable elements and outcomes with `has_element?/2` and `element/2`, not raw HTML strings.

### Browser verification

Use Ego Lite only, without wiping sessions or cookies. Verify at least:

- 1440×900 desktop in dark and light themes.
- 1024×768 tablet in dark and light themes.
- 390×844 mobile in dark and light themes.
- Project entry, resume signal, all eight instruments, expanded Mission Control, switchboard keyboard navigation, theme persistence, mobile sheets, disconnected state, and reduced motion.
- Scroll/focus: open a card below the fold, return with the explicit control, then repeat with browser Back; assert the same card receives focus and the deck scroller returns within two CSS pixels of its captured position. Remove the stored card in a fixture and assert the deck heading fallback.
- Theme: start with no cookie under mocked dark and light system preferences; verify the first screenshot has the correct theme with no dark-theme frame in a light visit. Toggle and reload to verify the cookie; reset to System; change the media preference; verify xterm recolors without remounting and its listener is removed on teardown.
- Reduced motion: emulate `prefers-reduced-motion: reduce` and assert card transforms and workbench entry animation are absent.
- Mobile: verify the switchboard and task details behave as focus-trapped sheets, the command dock forms two rows, and every essential target is at least 44px high.
- Disconnection: after the workspace loads, use the browser network/CDP offline control to sever the LiveView socket; assert the DOM `role="status"` banner and `Signal paused · reconnecting` text appear. Restore connectivity and assert both clear after reconnection.
- Kanban keyboard/touch: move a task through the explicit native status control, verify the announcement, and verify focus follows the task into its new channel.
- Close the Ego Lite space/session after smoke testing.

### Final gates

1. Targeted LiveView and terminal tests.
2. `mix assets.build` to catch Tailwind, colocated-hook, and bundle failures.
3. `mix precommit` and resolution of every pending issue.

## Non-goals

- No backend scheduler, run-state, persistence, provider, or security-model redesign.
- No OS sandboxing or worktree abstraction.
- No invented telemetry, qualitative scores, or demo data in empty workspaces.
- No external chart framework, external runtime script, or remote font stylesheet.
- No removal of current workflows merely to simplify the deck.
- No theme-specific information architecture.

## Approved Decisions

- Signal Foundry visual language: approved.
- Dark matte-black instrument theme: approved.
- Light bone-ceramic Daylight theme: approved.
- Instrument Deck architecture: approved.
- Expanded Mission Control workbench pattern: approved.
- Project entry option A—Deck first with contextual resume: approved.
- Final behavior, resilience, responsive, accessibility, compatibility, and verification contract: approved.
