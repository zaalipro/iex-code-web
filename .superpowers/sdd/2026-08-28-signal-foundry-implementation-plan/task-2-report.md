# Task 2 — Signal Foundry materials and vendored Doto

## Scope

Implemented the approved Signal Foundry material foundation in the isolated
`feat/signal-foundry` worktree. The change is additive: the disconnected
pseudo-banner and all legacy rainbow, glow, Kanban, workspace, and settings
selectors remain in place for templates that have not migrated yet.

## TDD record

### RED

Created `test/iex_code_web/signal_foundry_material_test.exs` before the CSS or
font assets. The contract names the production break each case catches:

- loss of the exact Tailwind v4 source declarations or introduction of a
  remote runtime font;
- replacement/corruption of the approved Doto WOFF2 and OFL bytes;
- missing explicit-theme or no-cookie media token branches;
- gradients leaking onto solid instrument faces, loss of tactile geometry,
  readable type floors, focus, overflow, or safe-area handling;
- wrong one/two/three/four deck geometry or featured-card span;
- excessive optical movement, all-card entrance motion, or incomplete
  reduced-motion handling;
- undersized coarse-pointer targets.

After fixing two test-file delimiter mistakes so the test itself compiled, the
required pre-implementation run was:

```text
mix test test/iex_code_web/signal_foundry_material_test.exs
Result: 0/7 passed; 7 failures
```

The failures were the intended absent-production-contract failures: no Doto
files or `@font-face`, no theme tokens, no `.sf-*` materials/grid/motion, and
no coarse-pointer rule.

### GREEN

Added the minimal approved implementation:

- local Doto variable `@font-face` (`100 900`, swap) with no remote stylesheet;
- exact dark, daylight, and system media-default `--sf-*` tokens, including
  AA light-mode status/text variants;
- public display, instrument, chassis, pill, command-dock, and focus-surface
  materials plus reusable body/metadata/status/control/code helpers;
- one warm ambient radial field while keeping instrument/workbench faces
  solid;
- 22px instruments, 28–30px workbench surfaces, 14–18px controls, pill
  geometry, diffuse neutral shadows, and inset highlights;
- 1/2/3/4 responsive grid units, a two-unit featured instrument from 640px,
  and full mobile transform/perspective removal;
- <=1px/0.15deg optical offsets at 1280px, <=3px hover lift, a dedicated
  180ms workbench entry, and no initial instrument-card animation;
- explicit reduced-motion cancellation for tilt/lift, workbench entry,
  waveform travel, and smooth scrolling;
- visible focus, code overflow/readability, dock/sheet safe-area handling,
  and 44px coarse-pointer targets.

Focused green evidence:

```text
mix test test/iex_code_web/signal_foundry_material_test.exs
Result: 7 passed
```

## Font provenance

Downloaded the exact plan-pinned Google Fonts assets and verified them before
placement:

```text
doto-variable.woff2
1c7d9f9c86f929fb4469b8a93510a65936d3bdc49e0a1a6878ae2b0f3f47c7c2
Web Open Font Format (Version 2), TrueType, length 5360

OFL.txt
26a7b58bdba6cda8a78ca6e8b3791d8013b8abc6d5e6519f84193893aee02020
Copyright 2024 The Doto Project Authors (https://github.com/oliverlalan/Doto)
```

## Verification

- `mix format test/iex_code_web/signal_foundry_material_test.exs`: passed.
- `mix test test/iex_code_web/signal_foundry_material_test.exs`: 7 passed.
- `mix assets.build`: passed; Tailwind v4 and esbuild completed successfully.
- Tailwind/source grep: exact required import plus all required sources present.
- Remote asset / `@apply` static audit: no matches in `assets` or
  `lib/iex_code_web`.
- Font listing/digest/type/license checks: passed.
- `git diff --check`: passed.
- No browser test was run, per the Task 2 brief. `mix precommit` was also not
  run because this task owns only the focused test/build/static gates.

The focused test and asset build still emit the repository's known unrelated
compile/type warnings recorded by earlier task reports; neither command reports
a Task 2 warning or failure.

## Self-review

- Re-read the Task 2 brief, reconnaissance, approved Visual System,
  Responsive Behavior, Accessibility, compatibility, and non-goal sections.
- Confirmed all six public class interfaces and the responsive featured-card
  contract are stable for later tasks.
- Confirmed the Doto display helper is not applied globally; body copy stays
  system sans and code stays system monospace.
- Confirmed solid faces contain no gradients or colored shadows and the only
  new radial gradient is `.sf-ambient-field`.
- Confirmed the disconnected pseudo-banner, `.rainbow-box-wrapper`,
  `.card-running-glow`, and all other legacy selectors remain unchanged.
- Confirmed no `@apply`, library dependency, remote runtime asset, raw script,
  Phoenix route/template behavior, or database surface was introduced.
- Added a path-scoped `.gitattributes` rule so Git's whitespace audit accepts
  the single trailing space in the checksum-pinned upstream OFL text without
  changing the licensed bytes.

## Files changed

- `assets/css/app.css`
- `.gitattributes`
- `priv/static/fonts/doto-variable.woff2`
- `priv/static/fonts/OFL.txt`
- `test/iex_code_web/signal_foundry_material_test.exs`
- `.superpowers/sdd/2026-08-28-signal-foundry-implementation-plan/task-2-report.md`
