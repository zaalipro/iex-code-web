# `dag_v1` exact finite research integration

## Status

The finite, immutable `dag_v1` core is available. Its closed registry executes
`project_inventory`, `read_file`, `aggregate`, and all eight typed research handlers. The durable scheduler owns
ready-node claims, bounded concurrency, append-only attempts, leases, generation fencing,
checkpoint receipts, retry backoff, pause/resume/cancel handling, and terminal recovery.

The dedicated exact-level Research launcher now creates durable static `dag_v1` runs through
`RunDispatcher.enqueue_research/3`. The eight registered kinds cover plan, ranked search,
grounded search, evidence merge, source fetch, evidence audit, report synthesis, and report
verification. Existing `legacy_v1` coding and research rows are never reinterpreted as DAGs.

The typed handler modules now exist under `IexCode.Research.DagStepHandlers`, together with
`DagRuntime`, `DagContracts`, and the exact `LevelPolicy`. They validate the adapter's finite node
params, use the existing ranked/grounded/fetch/model abstractions, return bounded secret-rejecting
contract envelopes, and choose conservative replay policies. Their bounded `DagFanout` tasks are
linked, ephemeral work inside the already supervised step task; they are not durable `run_agents`,
do not receive fleet identity, and must not be presented as independently recoverable agents.

`ProviderBudget` and `ProviderEffect` now provide fenced pre-use reservation, at-most-once
intent, settlement, uncertainty handling, and bounded response-payload replay. `DagRunner` binds
a trusted `provider_effect` closure into the handler context with the authoritative run/step
generations, owner, cancellation callback, and checkpoint callback. A crash after provider
settlement can therefore replay the verified payload without issuing the external request again;
this bounded replay path has passed its targeted security coverage.

Per-node `RunArtifact` rows are not required for the first finite activation. Each bounded
`DagContracts` envelope is durably stored with a SHA-256 data checksum in the append-only step
attempt result, and the scheduler separately digests that whole result while generation-fencing
completion. Those attempt results are the canonical intermediate plan/query/evidence/claim/draft
records. `artifact.kind` remains a typed projection label, not a claim that a `RunArtifact` row or
external file exists. The final verified Markdown must still pass through the content-addressed
`Research.Results` commit before the integer-addressed result is marked ready. `DagFinalizer`
performs that idempotent materialization directly and reconciles unfinished completed DAGs at
startup and on a bounded periodic cadence.

## Durable result delivery

This activation work does not remove the working asynchronous `legacy_v1` research runner.
Creation of any legacy or DAG deep-research run transactionally allocates a monotonically
increasing integer `research_results.id`. A successful legacy runner or `DagFinalizer` writes
content-addressed immutable bodies and materializes `_APP_DIR/research/<id>/result.md` plus the
self-contained, script-free `_APP_DIR/research/<id>/report.html` before marking the result ready.
Recorded SHA-256 values are verified on every open, download, and attachment read.

The loopback-guarded browser routes are:

- `/research` — open the dedicated Research workspace for the current session;
- `/sessions/:id/research` — open Research for a specific session;
- `/research/:id/report` — open verified HTML with restrictive response headers;
- `/research/:id/report/download` — download HTML;
- `/research/:id/result/download` — download Markdown.

The dedicated Research tab lists recent investigations and ready integer-addressed
reports. `/deep_research` opens the same-session attachment picker, and `/deep_research N`
selects one ready result. Attached Markdown is bounded, checksum-verified, escaped into a JSON
evidence envelope, explicitly labeled untrusted, and added server-side to the next ordinary
prompt. A follow-up Research launch snapshots only same-session result ID/checksum references in
its immutable synthesis node; the original objective remains the sole input to external search
queries, and checksum-verified report bodies are reloaded only for final synthesis as untrusted,
non-citation prior context. Both paths enforce the 12-result and 90 KB aggregate ceilings. This is
context attachment, not a durable research-agent identity.

The tab launches the exact `LevelPolicy` with one or more selected ranked-search providers. The level's
`async_subagents` value is the persisted name for a bounded handler-internal `Task.async_stream`
query-fanout ceiling; those tasks are not durable agents and do not have independent identity or
controls. Grounded-search handlers are registered for typed manifests, but grounded-provider
selection is not exposed by this launcher.
Persistent Research settings include the default exact level, maximum sources, conflict-audit
requirement, maximum cost in cents, maximum tokens, and time budget in minutes, alongside the
ranked-provider configuration and order. The launcher requires at least one selected,
automatically selectable ranked provider and fails before inserting a run when that selection is
empty or not launch-ready. Launch readiness requires an enabled, non-retired provider and its
required key; SearxNG additionally requires its instance URL and Google Programmable Search its
engine ID. Credentials are never copied into the manifest and are resolved again from live
settings at effect time.

The canonical launch boundary is shared by the dedicated page, workspace `/research` command,
Run setup Research mode, and local `mix iex_code.run /research ...`. New launchers use the exact
`low`, `medium`, `high`, and `ultra` names. The legacy quick/standard/deep setting remains for
already-persisted `legacy_v1` compatibility and does not reinterpret new DAG rows. All launchers
enforce `max_sources` in `1..40`; values above 40 fail validation rather than being truncated, and
the same limit is enforced by evidence envelopes and final materialization.

## Domain-neutral scheduler boundary

The scheduler knows only allowlisted step kinds, dependencies, attempts, leases, checkpoints,
and bounded outputs. It must not branch on `deep_research`, a provider name, or a research step
kind. The active scheduler is deliberately static. Resource declarations are descriptor-bound
metadata, not yet a general lock manager. Research provider budget/effect primitives, bounded
atomic response-payload replay, and final verified-output reconciliation through
`Research.Results` exist. Dynamic graph expansion is not part of the static adapter and remains a
later feature.

1. A workflow adapter creates immutable plain nodes using the canonical `DagManifest` fields:
   key, kind, title, dependencies, JSON params, and maximum attempts.
2. Persisted kind strings resolve through the closed `DagStepRegistry`. A persisted module name
   is never executable configuration. The core persists and validates each registered research
   handler's reviewed versioned descriptor.
3. The active core atomically claims ready nodes only when dependencies completed and the parent
   run lease is authoritative. The research provider handlers additionally use the runner-bound
   resource policy and pre-use budget reservation before external dispatch.
4. The active core fences transitions, checkpoint receipts, and result settlement by run/step
   attempt plus lease generation. Research adds fenced provider usage/payload settlement; its
   bounded contract envelopes are canonical step-attempt results, not `RunArtifact` rows.
5. A handler returns bounded JSON; only the scheduler validates and commits it. A future dynamic
   manifest revision may permit proposed children only after validating the parent's immutable
   expansion allowlist, total-node and per-parent limits, known registry kinds, resource policy,
   remaining budget, duplicate keys, and cycles in one transaction.
6. Terminal run state stops new claims and the runner cooperatively cancels active work. Research
   handlers checkpoint cancellation immediately before provider requests and effects; forceful
   cancellation must not pretend an external provider call was reversed.

`IexCode.Runs.DagManifest`, `DagStepRegistry`, and `DagStepHandler` define the current closed
core. `IexCode.Research.DagAdapter` emits their plain node shape, and its eight kinds resolve
through that registry. Unknown kinds and mutation handlers still fail closed.

## Final-result persistence

The active core already persists immutable handler version/effect/replay/resource/timeout fields,
a manifest digest, and append-only step attempts with parent-run and step lease generations,
checkpoint receipts, retry timing, result digests, and terminal history. Research handler
envelopes and fenced provider intent/settlement rows now provide versioned output and usage
foundations. Bounded provider response payloads are committed atomically with their completed
effect receipt and can be verified and replayed across step attempts. Each bounded
`DagContracts` envelope is then stored as the canonical, digested step-attempt result.

Legacy and DAG deep research use the immutable content-addressed `ResultStore` for final Markdown
and self-contained HTML. `DagFinalizer` reads the final verified step-attempt envelope, commits it
through `Research.Results`, and repairs the case where the DAG completed before its
integer-addressed result became ready. This final public materialization does not require
converting intermediate envelopes into `RunArtifact` rows.

Any future dynamic child insertion needs a unique
`(run_id, expansion_parent_attempt, expansion_key)` and
the transaction must append the child nodes, dependency edges, expansion event, and parent
result/checkpoint together. Recovery can replay that transaction idempotently, not rerun an
unknown external effect.

## Exact finite research workflow

`IexCode.Research.DagAdapter` uses the exact named `LevelPolicy`: `low` is one multistep round
with a bounded asynchronous query-fanout ceiling of two, `medium` is two rounds with three, `high`
is three rounds with four, and `ultra` is four rounds with ten. Every step records one logical
lead plus the same immutable level policy. Ranked and grounded search implement that ceiling with
handler-internal `Task.async_stream`; the ephemeral query tasks are not durable fleet members. A
mismatched manual round override fails validation rather than silently reverting to legacy
quick/standard/deep semantics.

The adapter emits every requested round statically. Each later plan depends on the prior audit and
uses its recorded gaps to shape the next bounded query batch. A sufficient-coverage value is
durable evidence metadata; it does not skip or remove a preallocated round. Low, medium, high, and
ultra therefore execute exactly 1, 2, 3, and 4 research rounds unless the run fails or is
cancelled. All emitted kinds are registered. A future manifest revision can replace preallocated
rounds with bounded dynamic expansion after that protocol is available:

```text
plan(round N)
  ├─ search.ranked(query × provider) ─┐
  ├─ search.grounded(query × model) ──┼─ evidence.merge
  └───────────────────────────────────┘       │
                                      source.fetch(URL × policy)
                                               │
                                        evidence.audit
                                          /          \
                            unresolved gaps            sufficient coverage
                                  plan(N+1)             report.synthesize
                                                             │
                                                       report.verify
```

Ranked and grounded outputs remain different contracts. `search.ranked` yields provider-ranked
rows. `search.grounded` yields an answer bundle with URL citations, hosted search-call proof,
provider identity, and usage. `evidence.merge` may normalize both into evidence records but must
not invent a rank for a grounded answer or discard its answer-level provenance.

The static adapter gives each provider/plane/round batch its own node, so concurrency,
cancellation, retries, health, and costs are visible at that boundary. Its query-ledger envelope
must retain each request separately. A future bounded-expansion revision should use one node per
request with deterministic keys derived from round, normalized query, plane, and provider.
Provider credentials are resolved from application settings immediately before execution and do
not enter step params, results, events, or artifacts. New manifests retain a v2 SHA-256 reference
over the selected providers' non-secret effective order, endpoints, engines/options, grounded
models, and synthesis route. Credential-only rotation is allowed because credentials are omitted
from that digest. Any non-secret routing change is detected against live settings before the next
provider effect and fails the run for a newly reviewed launch rather than silently rerouting it;
legacy current-settings references remain executable for persisted-manifest compatibility.

## Evidence and citation boundaries

The implemented handlers return bounded, versioned contract envelopes for these logical commit
points. The envelopes are canonical digested step-attempt results; their `artifact.kind` fields
are typed projection labels and do not imply materialized `RunArtifact` rows:

- **research plan** — objective, round, bounded queries, selected providers, coverage policy, and
  prior recorded gaps;
- **query ledger** — provider, round, per-query status, bounded normalized results or error code,
  plus bounded batch usage. The separate fenced provider-effect receipt retains the verified
  response payload and digest used for replay;
- **evidence set** — canonical URL, source/provider plane and provenance, bounded passages,
  content hash and fetch status when a public fetch succeeds;
- **claim ledger** — evidence-candidate IDs linked to evidence IDs, coverage counts and gaps, and
  the bounded deterministic conflict-candidate audit;
- **verified report** — Markdown with a verified positional source index, plus separate bounded
  source identities, evidence-candidate links, gaps, and verification metadata. This final
  envelope is the input to the required idempotent `Research.Results` materializer.

The synthesis handler produces a draft, not the final report. `research.report.verify` rejects
out-of-range positional citations, uncited prose sentences, URLs outside the fetched evidence,
missing or inconsistent evidence identities/hashes, and incomplete conflict-audit structure. It
does not prove semantic claim entailment and records that limitation in the verified envelope.
Verification is the final node after every configured round; after its bounded attempts are
exhausted, failure fails the DAG rather than activating a repair round or marking a report ready.
Any future repair expansion needs the separate bounded-expansion protocol.

The current deterministic audit records evidence candidates and source/domain/fetch coverage. It
does not pretend URL heuristics prove source primacy or that string processing proves semantic
conflict resolution. When conflict review is required it records that semantic review remains a
gap, and the verified-report envelope labels claim entailment as not automatically proven.

## Budgets and stopping

The executable typed registry includes research provider nodes backed by the fenced
`ProviderBudget` reservation/settlement plane and `ProviderEffect` intent boundary.
Provider handlers use those primitives through the runner-bound context. Broader versioned pricing
across every provider path remains future work.
Current manifests provide explicit conservative ceilings, and missing usage is settled
conservatively rather than treated as zero. There is no DAG operator-approval gate. The
coordinator receives only remaining-budget summaries, never keys.

The named level fixes the exact round count; current coverage metadata does not stop the graph
early. Source and manifest bounds cap durable data and nodes. A failed pre-use request/token/cost
reservation fails the affected attempt, and normal DAG retry/exhaustion semantics eventually fail
the node and skip its descendants. Dispatcher wall-time exhaustion fails the parent run. The
current result lifecycle does not publish a best-effort partial report: only a completed final
verified envelope can become a ready `ResearchResult`; failed or cancelled work remains
terminal without report files. A future adaptive-expansion protocol must not bypass the original
run ceilings.

At launch, the adapter totals the conservative token and cost reservations declared by every
provider-effect node. An explicit whole-run token or cost cap below those totals is rejected
before the run is inserted; when absent, the run defaults to the calculated requirement. This
does not promise universal pricing accuracy: provider-effect receipts reserve and settle the
declared dimensions, while broader versioned price catalogs remain future work.

## Control and recovery semantics

The active runner already prevents new claims while paused, propagates cancellation through
supervised control tokens, and fences step retry attempts. Exact research rows set
`max_attempts: 1` and persist a manual-review/non-replayable whole-run policy, so an interrupted,
failed, or cancelled research run is not requeued as a second paid run attempt. Start a new
research launch after review instead. Replay-safe steps and verified provider response receipts
can still support bounded step attempts while the same parent run lease/generation remains
authoritative. Process/application loss interrupts the outer run; it never resumes arbitrary
code at an instruction checkpoint.

Research steering and targeted
query/provider controls are not implemented. Their future contract is append-only: steering is
consumed by a specific planning attempt and may influence a later round but cannot rewrite
completed evidence. Targeted cancel affects one query/provider node and lets merge/audit decide
whether evidence remains sufficient. Restart creates a new step attempt and fences the old one.

Completed provider effects atomically retain a bounded response payload with its digest and usage.
A later step attempt verifies and replays that payload rather than repeating the external request.
If the verified DAG step completes before the public integer-addressed result becomes ready,
`DagFinalizer` repairs that state idempotently during direct completion, startup reconciliation,
or the bounded periodic reconciliation pass.

## Current activation scope and remaining proof

- All eight typed `research_*` handlers are registered; unknown kinds and versions still fail
  closed.
- Treat append-only, digested step-attempt envelopes as canonical intermediate research records;
  do not label their artifact proposals as materialized `RunArtifact` rows.
- The finalizer commits verified Markdown through `Research.Results` and startup/periodic reconciliation
  repairs a completed DAG whose integer-addressed result is not ready.
- An end-to-end finite DAG test covers final checksum-addressed Markdown and HTML materialization.
- Run full current-checkout precommit plus Ego Lite desktop/mobile smoke for final release proof.
  Close the Ego task space without clearing the user's browser sessions.

Dynamic expansion, per-subagent durable identity/control, grounded-provider UI selection, broader
versioned pricing, mutation handlers, richer query/provider controls, and materialized intermediate
`RunArtifact` projections remain later enhancements outside the current finite static activation.
