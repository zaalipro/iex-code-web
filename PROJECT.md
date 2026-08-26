# IexCode Product Architecture and Roadmap

## Product intent

IexCode is a local-first, native-workspace coding harness. Its purpose is to let a
developer delegate work to supervised agents, observe every operation, inspect and
edit artifacts, run verification, and decide what reaches Git without leaving one
Phoenix LiveView workspace.

The application includes a **durable asynchronous run system**: coding, deep-research, and
opt-in typed DAG runs are queued in SQLite, claimed with leases, and recorded in an ordered
event journal. Run-scoped controls, research evidence, citation-bearing reports, static DAG
manifests, and fenced DAG step attempts are durable. The current DAG catalog is deliberately
finite and mutation-free: project-read and fenced research-provider workflows are current, while
governed mutation and broader checkpoint contracts remain future work.

“Asynchronous” does not mean “unobservable.” A run must always expose its plan,
dependencies, current owners, tool activity, artifacts, verification, cost, and the
decisions it is waiting for.

## Non-negotiable execution boundary

IexCode operates directly in the selected project root.

- No per-run Git worktrees.
- No containers or application sandbox layer.
- No shadow copy that becomes a second source of truth.
- File, Git, test, and shell operations use the native workspace and the launching
  user's OS permissions.

The safety strategy is therefore **coordination and review**, not isolation. Current
safety mechanisms include path containment for workspace tools, patch preflight and
staleness validation, atomic multi-file patch writes with snapshots, process timeouts,
supervision, and explicit rollback/commit choices in supported workflows. They do not
make arbitrary shell commands reversible.

The current cooperative lock plane persists project, file, and Git resources with
read/write/exclusive modes, wait records, lease heartbeats, fencing generations, and
opaque capabilities. Coding runs reserve the project; guarded editor, patch, test,
terminal, hunk, and Git paths coordinate with that reservation and surface conflicts.
This does not mediate arbitrary native processes or lower-level code that bypasses the
gateway, and lease expiry alone cannot prove that an orphaned OS descendant stopped.

## Current system

### Runtime topology

```text
IexCode.Application
├── IexCode.Repo (SQLite/WAL)
├── MetricsStore + Telemetry poller (bounded operational aggregates)
├── Phoenix.PubSub
├── Session Registry
├── Agent Registry
├── Task.Supervisor
├── WorkspaceLocks (capability gateway + private delegation registry)
├── SessionSupervisor (DynamicSupervisor)
│   └── SessionServer per active coding session
├── AgentSupervisor (DynamicSupervisor)
│   ├── PlannerAgent
│   ├── ExplorerAgent
│   ├── CoderAgent
│   └── VerifierAgent
├── FleetSupervisor (DynamicSupervisor)
│   └── RunFleetSupervisor per active durable coding run
│       ├── run-local Task.Supervisor
│       ├── run-local AgentSupervisor
│       └── FleetManager
├── TerminalSupervisor (DynamicSupervisor)
│   └── TerminalSession per active terminal
├── RunDispatcher (leased durable background workers)
│   └── DagRunner per active `dag_v1` run
│       └── bounded Task.Supervisor children for ready nodes
├── Kanban.Scheduler (due/recurring task claims)
├── MultiPatch Snapshot Owner (durable SQLite + ETS cache)
└── IexCodeWeb.Endpoint
    └── WorkspaceLive
```

`SessionServer` owns the live lifecycle of an interactive coding session. Durable coding
runs additionally receive an isolated, persisted fleet with one planner, one coder, one
verifier, and bounded parallel explorers. `SwarmCoordinator` retains fixed role phases
and can iterate after failed verification; this is not an arbitrary DAG scheduler.
`OperationManager` executes supervised tasks, persists operation status,
monitors crashes, and broadcasts telemetry. LiveView subscribes to session and terminal
topics and rehydrates messages, operations, durable runs, steps, and sequenced events
when it mounts. `RunDispatcher` is independent of the socket and allows only one active
background run per project. Explicit `dag_v1` runs use `DagRunner` instead of the fixed
legacy executor; it atomically claims ready steps and runs up to four concurrently by default
(bounded to 32).

### Persisted records

| Record | What is persisted now |
| --- | --- |
| Project | Name, native root path, description, last-opened time |
| Session | Project, model/provider selection, swarm flag, lifecycle status |
| Message | Role, content, tool-call metadata, token/cost fields |
| Operation | Parent, agent, type, progress, result/error, PID string, timings |
| Kanban task | Workflow state, priority, assignee, subtasks, schedule, metadata |
| App settings | Model endpoints/keys plus twelve ranked-search adapters, provider order, fleet size, and exact research defaults for level, sources, conflict audit, cost, tokens, and time |
| Run | Changeset-immutable objective/kind/mode/engine manifest and session request key, draft/active lifecycle, typed executor, priority, progress, budgets, attempts, lease, timings |
| Run agent/control | Run-attempt identity, role/ordinal, lifecycle, desired state, fenced lease generation, task/progress/usage, ordered targeted controls, and bounded UI receipts |
| Run step | Immutable DAG handler contract plus typed legacy nodes, dependencies, logical lifecycle, bounded params/result, and timeout |
| Run step attempt | Append-only run/step attempt identity, manifest and handler snapshot, hashed owners, fenced generations, lease/heartbeat, retry, checkpoint, result digest, and outcome |
| Run event | Per-run monotonic sequence, type, source, bounded payload, occurrence time |
| Run command/control/approval/artifact | Tool command idempotency, ordered run controls, review decisions, cited reports, and artifact metadata |
| Research result | Monotonic integer ID, immutable run/project/session/level identity, lifecycle, exact Markdown/HTML paths, SHA-256 digests, source count, and bounded metadata |
| Mutation snapshot | Durable native-workspace rollback manifest, mirrored in ETS |
| Workspace lock | Canonical resource, mode, owner/run/session, batch wait state, lease, and fencing generation; capability stored only as a hash |

The activated DAG catalog is deliberately finite and static. It supports durable fan-out/fan-in
for `project_inventory`, `read_file`, `aggregate`, and all eight typed research handlers. The
dedicated exact-level launcher selects ranked-search providers and enqueues that research graph.
Arbitrary coding/mutation handlers, dynamic graph expansion, grounded-provider UI selection,
durable model-token deltas, enforced approval gates, and general resumable checkpoints remain
future work.

### Workspace surface

| Surface | Implemented today |
| --- | --- |
| Kanban | CRUD, eight states, drag/move actions, filters, assignees, priorities, subtasks, and scheduling fields |
| Swarm | Mission Control for coding/deep-research/DAG runs; coding adds persisted fleets and targeted controls, research adds provider evidence/report preview, and DAG runs add a layered durable node/attempt projection |
| Research | Dedicated exact-level ranked-provider launcher at `/research` and `/sessions/:id/research`, recent investigations, checksum-verified HTML/Markdown reports, and session-scoped attachment picker |
| Calendar | Month navigation, task editing/run-now, plus a supervised UTC cron scheduler with atomic claims, stable occurrence keys, recurrence, and stale recovery |
| Changes/Git | Status rails, inline/split diffs, stage/unstage, hunk operations, branches, fetch/pull, commit generation and commit |
| Tests/AutoFix | Async test subprocess, ANSI cleanup, structured failures, heuristic proposals, preview/apply/rollback and re-verification |
| AST | Elixir modules, functions, private functions, macros, specs, and types with editor jumps |
| Chat | Persisted messages, model switching, markdown/thinking presentation, tool-backed single-agent or swarm dispatch |
| Files/Editor | Tree/search, multiple buffers, dirty state, save/revert/close, jump-to-line, code insertion |
| Terminal | Native supervised PTY, xterm.js, input/signals/resize, scrollback/search, agent occupation, quick actions |
| Global controls | Settings, project/session selection, goal controls, usage view, and Cmd/Ctrl+K palette |

### Developer-tool layer

- `IexCode.Tools.ASTSearch`: Elixir AST symbol discovery.
- `IexCode.Tools.MultiPatch`: AST/exact/fuzzy matching, preflight validation,
  atomic writes, snapshots, and rollback.
- `IexCode.Tools.TestRunner`: native `mix test` execution and structured parsing.
- `IexCode.Tools.AutoFix`: bounded heuristic repair proposals.
- `IexCode.Tools.Git`: native status, diff, staging, branches, pull/fetch, and commit.
- `IexCode.Tools.TerminalServer`: supervised native interactive terminal facade.
- `IexCode.LLM`: OpenAI-compatible and Anthropic streaming, retry, fallback,
  circuit breaking, SSE parsing, UTF-8 boundary handling, bounded response/error
  collection, and authentication-header credential redaction on error paths.
- `IexCode.Research`: normalized Tavily/Brave/Exa/Perplexity/Firecrawl/Linkup/Serper/
  SerpApi/Google/Bing/SearxNG/DuckDuckGo federation, provider lifecycle descriptors,
  rank-interleaved results, duplicate-source provenance, hardened public fetching,
  evidence retention, and cited synthesis.
- `IexCode.Research.GroundedSearch`: a separate model-native grounded-answer contract for
  OpenAI Responses, Anthropic Messages, and Gemini Interactions, with citations, hosted
  search-call evidence, bounded transport, cooperative cancellation checkpoints, and explicit
  provider provenance. It is distinct from the ranked federation and is available to typed
  research manifests, but grounded-provider selection is not exposed by the current launchers.
- `IexCode.Research.Results` and `ResultStore`: transactional integer result allocation,
  content-addressed and symlink-rejecting report storage, checksum-verified reads, bounded
  session-scoped attachments, and self-contained HTML generation.
- `IexCode.Research.LevelPolicy`, `DagStepHandlers`, `DagRuntime`, `ProviderBudget`, and
  `ProviderEffect`: exact finite research contracts, all eight typed handler implementations,
  bounded internal fanout, fenced pre-use reservation, at-most-once external-effect intent,
  settlement, uncertainty handling, and bounded atomic response-payload replay across step
  attempts. All eight handlers are registered.
- `IexCode.Research.DagFinalizer`: direct, startup, and bounded periodic reconciliation of the final verified
  step-attempt envelope into content-addressed `Research.Results` Markdown and HTML.
- `IexCode.Runs.DagManifest`, `DagScheduler`, and `DagRunner`: canonical static graph
  validation, manifest hashing, atomic ready-node claims, bounded fan-out/fan-in, append-only
  fenced attempts, retry backoff, pause/cancel, terminal recovery, and redacted UI projection.
- `IexCode.Runs.DagStepRegistry`: closed v1 catalog containing the three bounded project-read
  handlers and eight typed research handlers.

### Current lifecycle

```text
user prompt / manual goal
        │
        ▼
SessionServer ──starts──▶ supervised task
        │                       │
        │                single agent or
        │                fixed swarm loop
        │                       │
        ├◀──── PubSub telemetry ┤
        │                       │
        └── persists messages and operation summaries
```

Interactive single-agent work survives a LiveView disconnect but not an application restart.
Interactive and durable swarm coordinators share one cluster-global session ownership key, so a
restarted `SessionServer` adopts the live owner instead of starting a second coordinator.
Durable background runs additionally survive process loss as records: on boot an expired
lease becomes `interrupted` and must be retried explicitly, preventing partial native
workspace effects from being replayed blindly.

## What is current, partial, and planned

| Capability | State | Notes |
| --- | --- | --- |
| Supervised OTP agents and operations | Current | Dynamic supervisors, registries, monitored tasks |
| Live PubSub progress | Current | Low-latency but ephemeral transport |
| Durable messages and operation summaries | Current | Rehydrated by LiveView |
| Native PTY and developer tools | Current | Execute in the real project root |
| Atomic MultiPatch rollback | Current | Applies only to writes performed through MultiPatch |
| Durable goal intake | Current | Session-scoped DB idempotency keys, full title/instruction retention, durable drafts, explicit draft start/cancel |
| Pause/resume/cancel/restart/steer | Current/partial | Attempt/generation-targeted controls have expiring claims, reconciliation, persisted receipts, and queued-versus-consumed steering; arbitrary effect replay remains conservative |
| Dynamic durable coding fleet | Current | One planner/coder/verifier plus bounded concurrent explorers, run-scoped identity, leases, heartbeats, generation-aware invocation rebinding, recovery, and Mission Control projection |
| Fixed role correction loop | Current | Role phases and mutation order remain typed legacy workflow, not a general scheduler |
| LLM streaming transport | Current | Parser/callback support plus bounded success/error collection and credential-redacted error paths |
| Token-by-token durable chat events | Partial | Normal session flow currently publishes the completed message |
| Calendar recurrence | Current | Supervised UTC polling, due claims, recurrence, stale recovery, and durable run enqueue |
| Model/search providers | Current/partial | OpenAI-compatible and Anthropic chat; twelve ranked-search adapters; three model-native grounded-search transports; direct general Gemini chat/local transports planned |
| Configurable swarm-agent count | Current | Drives the durable legacy coding fleet, bounded to 4–32 with extra capacity assigned to explorers |
| Durable run/event model | Current | Transactional run/step/event/command/approval/artifact records and bounded DAG attempt checkpoint receipts; general resumable checkpoints remain planned |
| Run budgets | Partial | Wall time and provider-reported tokens are enforced at covered active boundaries; token/cost exhaustion terminalizes the durable fleet after reported use. Registered research provider effects add fenced pre-use reservation and atomic settlement/replay; universal versioned pricing across all provider paths remains planned |
| Dependency-aware parallel DAG | Current/partial | `dag_v1` runs finite immutable graphs of closed-registry project-read and research handlers with durable attempts, readiness, leases, fencing, checkpoints, retries, and run-level controls; mutation kinds, dynamic expansion, and general resource locks remain planned |
| Deep-research result library | Current | Legacy and finite DAG research allocate integer IDs, commit checksum-addressed `result.md` and self-contained HTML, expose local open/download routes, and support bounded same-session chat attachments |
| Exact research levels | Current finite scope | Low/medium/high/ultra launch static `dag_v1` graphs with 1/2/3/4 rounds and handler-internal `Task.async_stream` query-fanout ceilings of 2/3/4/10; ranked-provider UI selection is current, while grounded-provider UI selection and durable per-query controls remain planned |
| Native workspace coordination | Current cooperative baseline | Durable batched project/file/Git resources, FIFO-oriented waits, capability checks, heartbeats, fencing, dispatcher ownership, guarded UI/tools/terminal, and Mission Control; native bypass/physical-alias hardening remain |
| Approval and durable command records | Partial | Command idempotency keys and approval records exist; policy enforcement/inbox UX remain planned |
| Restart reconciliation | Partial | Expired workers/controls become interrupted or are requeued, fleets retry through the prior lease horizon, and safe checkpoint resume remains unimplemented |
| Automatic calendar worker | Current | Supervised claims, stable occurrence keys, recurrence, stale recovery, and existing-run reuse |
| Direct Gemini/local adapters | Planned | Compatible endpoints can be used today through OpenAI adapter |

## Target asynchronous architecture

```text
                         ┌───────────────────────┐
user / calendar / API ──▶│ durable Run Command  │
                         │ inbox                 │
                         └──────────┬────────────┘
                                    ▼
                         ┌───────────────────────┐
                         │ Run Dispatcher        │
                         │ claim + lease + limits│
                         └──────────┬────────────┘
                                    ▼
                         ┌───────────────────────┐
                         │ Run Supervisor        │
                         │ dependency scheduler  │
                         └──────┬─────────┬──────┘
                         ready steps      │ events
                                ▼         ▼
                   ┌───────────────┐  ┌─────────────────┐
                   │ agent / tool  │  │ append-only Run │
                   │ workers       │  │ Event journal   │
                   └───────┬───────┘  └────────┬────────┘
                           │ artifacts          │ replay/live tail
                           ▼                    ▼
                   ┌───────────────┐  ┌─────────────────┐
                   │ native locked │  │ LiveView run    │
                   │ workspace     │  │ console         │
                   └───────────────┘  └─────────────────┘
```

PubSub remains the fast notification layer. SQLite is the source of truth. A consumer
receiving a notification reads events after its last sequence number; dropped or
duplicated notifications therefore do not lose state.

### Durable records and remaining extensions

The following describes both the implemented ledger and the fields still needed for
the target scheduler. Items explicitly marked planned are not current behavior.

#### Run

- Owns a goal across process and socket lifetimes.
- Current states are `draft`, `queued`, `running`, `paused`, `completed`, `failed`, `cancelled`,
  and `interrupted`; a distinct review-waiting state is planned.
- Stores priority, token/cost/time budgets, attempts, worker lease, and the latest event
  sequence. General execution policy and checkpoint cursors are planned.
- Application changesets do not permit lifecycle updates to rewrite its objective, kind, mode,
  or execution-engine identifier after creation. The durable create/retry boundaries validate
  the supplied manifest through that engine, claim queries select only engines advertised as
  available, and the dispatcher recomputes its canonical manifest hash after claim. `dag_v1`
  rows are claimable only when every immutable step kind exists in the closed registry;
  unsupported kinds and mutation handlers fail validation instead of falling through to
  `legacy_v1`.

#### Run step

- A typed unit of agent or tool work.
- Stores dependencies, immutable handler/version/effect/replay/resource/timeout policy,
  bounded params/result, attempts, progress, timestamps, and status. `dag_v1` adds append-only
  attempt rows with run/step generations, hashed owners, leases/heartbeats, checkpoint receipts,
  retry timing, result digests, and terminal outcomes; legacy steps retain compatibility behavior.
- Legacy coding dispatch still executes a fixed `prepare → execute` graph, and already-persisted
  legacy research rows retain their plan/search/fetch/synthesis runner. New composer,
  `/research`, and dedicated-page research launches all create exact `dag_v1` workflows. The
  `dag_v1` scheduler runs finite dependency graphs for registered project-read and research
  handlers; mutation and approval handlers remain fail-closed.
- V1 manifests are non-empty and limited to 128 nodes, 512 edges, 32 dependencies per node,
  32 topological levels, and five attempts per node. They cannot expand after creation.

#### Run agent and targeted control

- A durable coding fleet member is identified by run, run attempt, and stable key. Multiple
  explorers and two runs in one session therefore do not collide in the Registry.
- Active workers use owner/generation/expiry fencing. Heartbeats, lifecycle transitions,
  usage, and targeted-control outcomes reject stale generations; abandoned generations
  become interrupted rather than replaying native mutations.
- Targeted pause, resume, cancel, restart, and steering requests have per-agent sequences
  and idempotency keys. Mission Control is projected from these rows, not inferred from
  session operation names or PIDs.
- Agent phases resolve the current PID and generation from `FleetManager` immediately before
  invocation. A crashed agent is durably interrupted; after an explicit fenced restart
  advances its generation, a later phase can bind to the replacement rather than retaining
  the stale PID. This is invocation rebinding, not replay of the interrupted call.
- Mission Control reads a bounded newest-first receipt window per agent and control kind.
  Steering first records a durable `queued` result, then changes that receipt to `consumed`
  only at the fenced worker drain checkpoint.

#### Run event

- Append-only and monotonically sequenced within a run.
- Currently records run/step transitions, progress, command/approval/artifact creation,
  retries, and related metadata. Lock state has its own durable ledger and PubSub topic;
  model deltas and complete tool I/O remain planned.
- `(run_id, sequence)` is unique. Events do not currently have a producer idempotency key.

#### Artifact

- Stores typed artifact metadata and a URI linked to a run and optional producing step.
- Checksums and arbitrary metadata are supported; enforced workspace revision and
  lifecycle status are planned.

#### Run command, control, and approval

- Run commands have per-run idempotency keys; approval request/decision persistence APIs exist.
- Run controls have per-run monotonic sequences and idempotency keys, are claimed and
  resolved durably, and are delivered over run-isolated PubSub topics. A general replaying
  consumer for pending controls after dispatcher restart is not yet implemented.
- Reusing a command or control idempotency key succeeds only for the same semantic request;
  conflicting reuse fails closed. Run controls also reject terminal targets and recursively
  secret-shaped payloads. Orphan reconciliation and retry supersede open run controls
  transactionally so an abandoned claimant cannot leave authoritative work pending.

#### Workspace coordination ledger

- Coding runs acquire a renewable project-exclusive batch before their executor starts;
  a conflicting claim remains durably waiting and keeps its requested ordering.
- Resource batches are all held or all waiting. Project, file, and Git resources support
  read/write/exclusive conflicts, opaque capability checks, heartbeats, expiry, and
  monotonically increasing fencing values while retained history exists.
- A private, unforgeable delegation context lets nested run tools reuse the outer
  reservation without distributing the raw capability. Read APIs, PubSub, Inspect,
  LiveView assigns, run metadata, and events expose redacted rows only.
- Guarded Tools, AutoFix/MultiPatch production paths, WorkspaceLive editor/Git/hunk/test
  actions, and terminal command/input lifecycles assert ownership immediately before
  their effect and release after cleanup. Mission Control and editor/terminal banners
  show held/waiting state without exposing capability or arbitrary owner strings.
- Coordination is still cooperative in the native checkout. Direct lower-level module
  calls, external editors/processes, hard-link or mount aliases, symlink/root swaps after
  validation, and orphaned subprocess descendants are outside a database lock's physical
  enforcement. It is not isolation, a sandbox, or a worktree.

## Target scheduler invariants

1. **Database state wins.** OTP processes are executors and caches, not the sole record
   of a run.
2. **At-least-once dispatch, idempotent effects.** Claims may be retried; step effects
   must use stable keys and preconditions.
3. **One ordered event stream per run.** Every state transition has a sequence number.
4. **No guarded write without ownership.** Current production mutation entry points hold
   and reassert a compatible workspace/file/Git capability. Universal physical path
   identity and revision/digest fencing across every lower-level API remain hardening work.
5. **Review is a state.** Waiting for a human does not occupy a worker or masquerade as
   running.
6. **Cancellation is cooperative, then forceful.** Stop new dispatch, signal active
   work, terminate after a deadline, and record the final outcome.
7. **Recovery is deterministic.** Current expired run leases become `interrupted`, their
   open run controls are superseded, and they require explicit retry. A restarted agent can
   rebind later invocations to its new generation, but future checkpoints may resume an
   interrupted effect only where a tool contract permits. Within a still-current `dag_v1`
   parent lease, an expired safe read attempt is fenced, recorded, and retried with backoff;
   outer-run recovery remains explicit.
8. **History is bounded in memory, complete on disk.** The database journal is durable;
   cursor pagination and a windowed LiveView stream remain planned.

## Delivery roadmap

### A0 — Documentation and baseline

**State: current work**

- Maintain one product description covering the complete ten-tool workspace.
- Treat `mix precommit` on the current checkout as the quality gate; historical agent
  reports are supporting context, not current proof.
- Record platform and native-execution limitations explicitly.

### A1 — Durable run ledger

**State: run/step/event and DAG step-attempt ledgers implemented; broader checkpoints planned**

- Run, step, event, artifact, command, and approval persistence is implemented.
- DAG attempts persist bounded checkpoint receipts. Add effect-specific checkpoint recovery
  contracts before registering future mutation handlers or any additional effect type that lacks
  the fenced research-provider contract.
- Centralize validated state transitions.
- Append events transactionally with their corresponding state change.
- Build session-history migration/adapters without breaking existing sessions.

**Exit:** a queued run and its event history survive an application restart. Cursor-based
storage replay is implemented; cursor-driven LiveView pagination remains in A5.

### A2 — Dispatcher and recovery

**State: leasing/reconciliation, ordered controls, and safe DAG-step retry implemented; broader checkpoint resume planned**

- Claim queued runs with renewable leases.
- Reconcile expired run/step claims on boot and supersede orphaned run controls.
- Replay pending pause/resume/cancel/steer controls safely after dispatcher restart and
  add acknowledgement checkpoints inside every long provider/tool call.
- The current executor passes the run id into the run-scoped fleet coordinator, records
  agent progress/usage, resolves the live generation before phase invocation, isolates
  targeted controls, and terminalizes the fleet on reported token/cost exhaustion; extend
  the same contracts to checkpoint-safe recovery of explicitly idempotent work.
- The DAG runner supports run-wide pause/resume/cancel and explicit retry of the same static
  manifest. Steering, per-node operator control, and automatic outer-run resume are not current.

**Exit:** disconnecting the browser has no effect on execution, and restarting the app
recovers a run according to its checkpoint and tool capabilities.

### A3 — Native workspace coordination

**State: cooperative baseline current; physical enforcement/recovery hardening remains**

- Durable project/file/Git resource batches, modes, opaque capabilities, heartbeat/expiry,
  wait records, fencing, dispatcher integration, and lock UI are implemented.
- Guarded file/patch/test/Git/terminal entry points declare conservative resources and
  nested coding tools use an unforgeable delegation from the run reservation.
- Add descriptor-relative/no-follow filesystem effects, physical filesystem identity,
  directory/descendant and rename-endpoint rules, digest/revision preconditions, durable
  restart recovery for wait capabilities, and quarantine for uncertain native children.
- Extend enforcement into every lower-level mutation API so arbitrary in-process callers
  cannot bypass the gateway.
- Preserve direct native execution; do not introduce worktrees or sandboxes.

**Exit:** all application mutation paths and physical aliases are fenced, and promotion
cannot occur until an expired native holder is confirmed stopped or quarantined.

### A4 — Dependency-aware execution

**State: finite project-read and research DAG current; mutation DAG contracts fail-closed**

- The explicit `dag_v1` engine now persists immutable, cycle-validated finite graphs and
  dispatches independent ready nodes concurrently with bounded output, retries, timeouts,
  append-only attempts, leases, generation fencing, checkpoint receipts, and terminal recovery.
- The closed production registry contains `project_inventory`, `read_file`, `aggregate`, and all
  eight research handlers: plan, ranked search, grounded search, evidence merge, source fetch,
  evidence audit, report synthesis, and report verification. Mutation, coding-agent, Git/native,
  and approval kinds remain absent.
- `ProviderBudget`/`ProviderEffect` and the trusted `DagRunner` provider-effect closure establish
  fenced pre-use reservations, deterministic external intent, settlement, uncertain outcomes,
  and bounded atomic response-payload replay across step attempts without repeating the provider
  request; the replay path has passed its targeted security coverage.
- Treat each bounded `DagContracts` envelope as the canonical, digested step-attempt result.
  Intermediate research envelopes are not materialized `RunArtifact` rows.
- `DagFinalizer` now idempotently materializes the final verified DAG output through
  `Research.Results` and reconciles unfinished completed DAGs at startup and periodically. An end-to-end finite DAG test reaches
  the checksum-addressed Markdown and HTML result.
- The dedicated launcher uses `RunDispatcher.enqueue_research/3`, exact static rounds, and ranked
  provider selection. Its query fanout is bounded handler-internal `Task.async_stream` work, not
  durable `run_agents`; controls remain run-wide.
- Add manual approval gates and keep bounded dynamic expansion as a later manifest revision;
  current research adapter graphs are static.
- Grounded-provider UI selection, durable per-query identities/controls, broader versioned
  pricing, and mutation handlers remain future work. Full current-checkout precommit and Ego Lite
  desktop/mobile smoke remain the final release proof rather than a completed claim here.

**Current baseline exit:** a run proves parallel execution of independent contained reads and
waits for durable prerequisites before fan-in. Serialization of conflicting mutations and
verification prerequisites remains a later exit because v1 exposes no mutation handler.

### A5 — Event-native LiveView console

**State: partial; durable ledger and bounded journal view implemented**

- Tail and replay sequenced events with cursor pagination, LiveView streams, and bounded memory.
- Publish real response/reasoning/tool deltas instead of only completed messages.
- DAG layers, dependency/readiness state, attempts, retry timing, lease health, and checkpoint
  timing are current. Add lock ownership, queue position, approvals, tokens, cost, latency,
  and artifact review where corresponding DAG handlers record them.
- Provide artifact-centric plan, patch, test, terminal, and commit review.

**Exit:** reload/reconnect produces the same run view without fabricated metrics or
lost deltas.

### A6 — Scheduled and provider-complete operation

**State: core scheduler and twelve-provider ranked-search federation implemented; model transport expansion planned**

- Supervised due-task claims, recurrence, stale recovery, and durable run creation are implemented.
- Add explicit retry policy, notification, and dead-letter workflows.
- Maintain shared conformance tests for Tavily, Brave, Exa, Perplexity Search,
  Firecrawl Search, Linkup Search, Serper, SerpApi, Google, Bing, SearxNG, and
  DuckDuckGo; add more providers through the registry contract.
  Bing is retained as an explicitly requested retired compatibility adapter;
  Google is closed to new customers and sunsets on January 1, 2027; the
  DuckDuckGo HTML adapter is unofficial. Ranked-result APIs and model-native
  grounded-answer tools intentionally use separate contracts.
- Add first-class general-purpose Gemini chat and local-model adapters only when their
  transport, cancellation, usage, and error behavior meet the same contracts; this is
  separate from the implemented Gemini grounded-search transport.
- Add encrypted/keychain-backed secret storage before shared or remote deployment.

**Exit:** due-task outcomes are observable through retry/dead-letter UX, and each
supported provider passes a shared conformance suite.

## Deliberate non-goals for the near term

- Remote multi-tenant execution.
- Pretending native commands are harmless or reversible.
- Using Git worktrees as the concurrency model.
- Replacing OTP/PubSub with an external job system before the local durable model is
  proven.
- Claiming arbitrary autonomous code changes are safe without verification and review.

## Code map

```text
lib/iex_code/
├── application.ex              # supervision tree
├── engine/                     # sessions, agents, operations, swarm coordination
├── runs/                       # durable ledgers, dispatcher, DAG scheduler and handlers
├── research/                   # provider gateways, typed research DAG, results and reports
├── llm/                        # provider clients, SSE, UTF-8, retry/fallback
├── tools/                      # files, AST, patches, tests, Git, terminal
├── projects.ex / projects/     # native workspaces
├── sessions.ex / sessions/     # conversations and operation history
├── kanban.ex / kanban/         # tasks, schedules, workflow
└── settings.ex / settings/     # local provider/application settings

lib/iex_code_web/
├── live/workspace_live.ex
├── live/workspace_live.html.heex
├── controllers/research_report_controller.ex
├── components/workspace_components.ex
└── command_palette.ex

assets/js/hooks/terminal_hook.js # xterm.js LiveView bridge
priv/pty_shim.py                 # POSIX PTY bridge
test/                            # unit, integration, E2E, adversarial, stress, PTY
```

## Quality gate

Every implementation milestone ends with:

```bash
mix precommit
```

Feature work should add focused domain tests, LiveView interaction tests using stable
DOM IDs, restart/recovery tests for durable execution, concurrency tests for claims and
locks, and native-workspace smoke tests. Browser smoke testing is part of release
verification, but is not replaced by static template assertions.
