# Task 20 report — static design/accessibility audit

Base: `8bacaf5acbaa186969226ad2de69bbbe9fdac6ee`

## RED

Command:

```bash
mix test test/iex_code_web/signal_foundry_static_contract_test.exs
```

First executable contract run: 5/7 passed, 2 failed. The focused failures were:

1. the shared Signal Foundry `@media (pointer: coarse)` selector did not cover native controls under `.sf-chassis` / `[id^="instrument-workbench-"]`;
2. every rendered `CodeCopy` host replaced child DOM without the required `phx-update="ignore"` boundary.

A scanner-only false positive for expression-valued hook IDs was corrected before treating the output as a production finding; the fixed reader accepts nonblank literal/expression IDs without weakening the hook ownership matrix.

## GREEN repairs

- Created `IexCodeWeb.SignalFoundryStaticContractTest` with the exact eight-source map, exact remote matcher, local font/license existence checks, one generated root bundle exception, colocated-hook exception, scoped leaf-rule visual parser, additive hook registration, light token/contrast assertions, coarse-pointer assertions, and Resume class-list assertion.
- Extended the one shared coarse-pointer rule to `.sf-chassis` and literal/prefix-family workbench descendants with both 44px minima.
- Added `phx-update="ignore"` to all five source families of `CodeCopy` hosts while preserving LiveView attribute merging.
- Normalized `#resume-instrument` to HEEx list-form classes.
- Strengthened rendered owners for deck/workbench ID uniqueness, scoped class tokens, one chassis status region, quiet deck live semantics, nested interaction/form rejection, canonical workbench traversal, label/reference integrity, and hook ID/ownership rules.
- Hardened the material test helpers to select the authoritative SF token/coarse blocks rather than earlier unrelated light/coarse blocks.

GREEN command:

```bash
mise exec -- mix test \
  test/iex_code_web/signal_foundry_static_contract_test.exs \
  test/iex_code_web/components/instrument_components_test.exs \
  test/iex_code_web/components/workspace_components_workbench_test.exs \
  test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs \
  --seed 0
```

Result: `33 tests, 0 failures`.

Additional focused owner gate:

```bash
mix test test/iex_code_web/signal_foundry_material_test.exs --seed 0
```

Result: `10 tests, 0 failures`.

## Source/build verification

- Exact remote-asset/`@apply` inventory: no matches.
- Legacy inventory: only the pre-existing `Active neon top line` comment in a code-rendering component and unrelated admin-login linear-gradient artwork; neither is a migrated selector violation.
- Fonts present: `priv/static/fonts/doto-variable.woff2`, `priv/static/fonts/OFL.txt`.
- `mise exec -- mix assets.build`: exit 0 (Tailwind and esbuild completed).
- `mise exec -- mix format --check-formatted` on changed Elixir tests/components: exit 0.
- The already-unformatted 4,300-line `workspace_live.html.heex` remains intentionally unformatted as a whole; formatting it produces thousands of unrelated lines. The Task 20 diff retains only the Resume and two CodeCopy ownership hunks.
- `git diff --check`: exit 0.

## Task 15 parked disposition

No low-level Task 15 production owner was changed. Strict HunkOps capability sealing, cooperative index publish/error atomicity, strict producer/env caps, full-context `:apply_to_file`, and linked-worktree scratch-index resolution are outside Task 20's approved application-source list and could not be safely repaired in this focused static/a11y pass. The existing ledger rulings remain in force and these limitations must remain visible in final review. The lifecycle Cartesian proof debt likewise remains for Task 22/browser acceptance.

Task 20 did not run `mix precommit` or a browser; Tasks 21 and 22 own those gates.

## Fix Round 1

Base: `c2cbbb973ba81ec44c2599d5baf0df4003a1f8f0`

### RED

- Added a rendered Mission Control contract that rejects legacy hard-coded surfaces, rings/glows, `transition-all`, and 10–11px chrome beneath canonical workbench roots. The contract failed against the existing Swarm role cards and operation tree.
- Added a repeated-identical fenced-code render with two caller namespaces. The CodeCopy assertion failed because both blocks rendered `copy-code-85237184`.

### GREEN

- Recomposed `subagent_cards/1` and `operation_tree/1` with `sf-*` classes backed by `--sf-*` tokens, matte/light parity, readable 12px minimum metadata, restrained transitions, and preserved IDs/events/state. Connector lines now use `--sf-hairline`.
- Extended the rendered integrity audit across canonical `#instrument-workbench-*` roots, allowing code/diff/xterm-owned subtrees to retain their specialized treatment.
- Added a required caller namespace and occurrence index to Markdown CodeCopy IDs; updated chat and expanded-message call sites while preserving `CodeCopy`, `data-code`, and `insert_code_to_editor` behavior.

### Verification

```text
35 tests, 0 failures
```

Command:

```bash
mise exec -- mix test test/iex_code_web/signal_foundry_static_contract_test.exs \
  test/iex_code_web/components/instrument_components_test.exs \
  test/iex_code_web/components/workspace_components_workbench_test.exs \
  test/iex_code_web/live/workspace_live_keyboard_semantics_test.exs --seed 0
```

Additional source/build gates passed: `mix assets.build`, `mix compile`, scoped `mix format --check-formatted`, and `git diff --check`. The pre-existing failures in legacy assertions for diff/file component text remain outside this focused round.

Task 15 low-level limitations remain parked and unchanged. Task 20 still does not run `mix precommit` or Ego Lite/browser checks; those gates remain with Tasks 21–22.
