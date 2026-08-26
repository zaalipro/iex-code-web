# Durable Run Fleet and DAG Security Model

This document describes the security properties implemented by the durable, run-scoped agent
fleet and static `dag_v1` scheduler, plus the limits that still apply. SQLite is the durable
authority. OTP processes execute that state; they are not durable identity or authorization by
themselves.

## Trust boundaries

IexCode is a native host-control application. It can call model providers, execute commands,
and modify the selected checkout.

- Phoenix applies CSRF protection and local-host access checks. If
  `IEX_CODE_ALLOW_REMOTE=true` is set, the operator must provide authentication at the reverse
  proxy. Fleet APIs do not implement independent multi-user authorization.
- Model output, repository content, tool arguments, command output, and imported metadata are
  untrusted. The server derives the run's session, project, and root from persisted records;
  they are not selected by model/tool data.
- SQLite is the source of truth for fleet and DAG-attempt identity, generations, leases,
  controls, outcomes, manifest hashes, usage, and event order.
- Registry names, PIDs, monitors, atomics, task links, and PubSub are node-local runtime
  mechanisms. They can disappear, duplicate, or become stale.
- Workspace locks coordinate cooperating IexCode paths. They do not create operating-system
  isolation.

## Implemented guarantees

### Durable identity and topology

Each logical worker is a `run_agents` row identified by its run, stable agent id/key, run
attempt, and lease generation. Parent relationships are checked against the same run and run
attempt by the manifest API. Immutable manifest drift is rejected rather than silently reusing
a row with a different role, adapter, parent, capability list, or configuration.

Fleet attachment refetches the run, checks its session/project relationship, loads the session
and project from storage, and uses the persisted project root. The runtime topology is bounded
to 32 workers and role-to-module selection is a closed allowlist of planner, explorer, coder,
and verifier agents.

Registry keys are run-scoped:

```text
{:run_agent, run_id, agent_id}
{:run_fleet, run_id, component}
```

There is no fallback from a durable agent lookup to a session-scoped worker. Registration is
validated against the expected PID, role, and generation after startup. A conflicting Registry
occupant fails closed. PIDs are runtime routing values only and are not persisted in fleet
control results.

The run's objective, kind, mode, execution-engine identifier, and DAG manifest hash are accepted
through the create changeset only. Application lifecycle changesets reject later changes to
those fields. Durable creation and retry validate the supplied manifest through its selected
engine; claim queries filter to available engines, and the dispatcher recomputes and compares
the canonical hash after claim. `dag_v1` is dispatchable for explicit static workflows and
cannot fall through to `legacy_v1`. Generic post-creation step insertion cannot mutate its
persisted manifest.

### Shared intake and durable single-agent work

The workspace composer and local Mix launcher pass exact parsed intents through the same
execution router. The router verifies the persisted project/session relationship, resolves a
bounded policy once, strips credential/endpoint-shaped caller metadata, and stores only the
secret-free effective policy with the run. Every durable submission carries a session-scoped
request key. Reusing the key returns the same run only when its immutable request fingerprint
matches; semantic conflicts fail rather than aliasing new work onto an old run.
The policy includes only a SHA-256 digest of the effective provider/model/base-URL route, never
the endpoint or credential itself. Before each durable single-agent or swarm model effect, the
live non-secret route must reproduce that digest; credential-only rotation is allowed, while
provider/model/endpoint drift fails before transport. Interactive session chat remains a
process-local live-settings path by design.

`coding_agent` / `single` runs use a bounded model/tool loop rather than the process-local
one-request chat path. Each tool request receives an attempt-scoped idempotency key and a
`run_commands` lifecycle. Command creation, transition, usage, steering consumption, and final
message persistence require the current parent lease owner, run attempt, and lease generation.
Pause waits at explicit model/tool checkpoints; cancel and lost authority fail the checkpoint.

These records do not make native tool effects transactional. A completed or failed command can
be replayed from its recorded result only when the same logical command is revisited in the same
run attempt. An ambiguous in-flight command is not silently declared successful. Process or
application loss interrupts the outer run, and an explicit whole-run retry advances the run
attempt when allowed; a new attempt may execute tool effects again. There is no instruction-level
resume of arbitrary code.

### Static DAG manifest and handler authority

`dag_v1` accepts a non-empty plain JSON graph with no executable closure or persisted MFA/module
configuration. Literal strings in bounded params may name paths or resemble modules, but they
never select executable code. The validator rejects unknown fields or handlers, ambiguous
atom/string aliases, missing/self/duplicate/cyclic dependencies, secret-shaped params,
oversized JSON, and graphs above 128 nodes, 512 edges, 32 dependencies per node, or 32 levels.
Each node permits at most five attempts. Canonical ordering includes the handler descriptor and
produces a SHA-256 manifest hash stored on the run; handler version, effect class, replay policy,
resource contract, timeout, and graph fields become changeset-immutable step data.

The closed production registry contains version-one `project_inventory`, `read_file`, and
`aggregate`, plus all eight finite `research_*` handlers. Inventory returns at most 2,000
immediate entries; file reads require a contained, regular, valid UTF-8 file no larger than
256 KB; aggregation packages bounded completed dependency results. Research handlers use exact
level policies, bounded contract envelopes, pre-use provider reservations, and tamper-checked
response replay. Unknown handlers or descriptor drift fail before claim or settlement.

### DAG step-attempt fencing

Every claim appends a `run_step_attempts` row bound to the run attempt and generation, manifest
hash, logical step, step attempt/generation, execution key, and a snapshot of its handler
contract. Run, claim, and live lease owners are stored as redacted SHA-256 hashes. Database
constraints and triggers enforce lifecycle shape, immutable authority fields, unique attempt
identity/execution keys, and same-run step scope.

Ready-node selection and claim occur in one SQLite transaction. Heartbeat, checkpoint,
completion, failure, pause, and terminalization require the current unexpired parent lease,
parent generation, step lease owner/generation, manifest hash, and handler descriptor. Params,
checkpoint-callback values, results, and error details use bounded, secret-rejecting JSON
contracts; completed results receive a durable digest. A stale or foreign worker cannot complete
an attempt, and PubSub remains notification only.

Independent ready nodes run concurrently through a per-run task supervisor (four by default,
bounded to 32). A dependent is promoted only after every declared predecessor is durably
completed. Safe failures and expired step leases use exponential backoff from 250 ms up to 30
seconds while attempts remain; exhaustion fails the node and skips descendants. Run-wide pause
prevents new claims, marks attempts paused, and pauses cooperative tokens; a short built-in read
may still settle before observing a checkpoint. Resume reopens tokens, and cancel closes active
attempts before the parent becomes terminal. `dag_v1` steering is rejected.

### Hashed lease credentials and generation fencing

Each run fleet receives a cryptographically random bearer credential. The raw value remains in
the run-fleet supervision/runtime context. `run_agents.lease_owner` and
`run_agent_controls.claim_owner` store only its SHA-256 hash; both schema fields are redacted
from `Inspect`, and database checks require the 64-character lowercase hexadecimal form.
Comparisons hash the presented credential and use constant-time comparison.

Claiming an agent increments its generation. Heartbeat, transition, usage, control claim,
control resolution, and steering consumption verify the current credential, generation,
active lifecycle, and unexpired lease at the durable boundary. Expired generations cannot be
renewed. Reconciliation uses conditional owner/generation/status/expiry predicates so a fresh
heartbeat cannot be overwritten by a stale reconciliation read.

The runtime owner passed to agent and operation code contains only `run_id`, `agent_id`, and
generation. It does not contain the raw bearer credential. Fleet runtime calls route through
the owning `FleetManager`, which supplies the credential privately and refreshes the durable
row before accepting progress, completion, or usage.

### Scoped, ordered controls

Targeted controls bind:

```text
run_id + run_agent_id + target_generation + sequence + idempotency_key
```

The selected agent is fetched within the selected run, and the manager rejects controls from a
different run. Enqueue requires an active run and controllable agent. It allocates a monotonic
per-agent sequence transactionally. Reusing an idempotency key returns the existing control
only when kind, generation, payload, and requester match; conflicting reuse is rejected.

Only the oldest open control may be claimed. Claim and resolution are fenced by the current
hashed fleet credential, generation, live lease, target, and control lifecycle. A claimed
control acts as an ordering barrier. Claims older than the bounded claim timeout can be
reclaimed; stale-generation controls are superseded or rolled forward during a fenced
generation change. Restart has a dedicated transaction that advances the agent generation and
claims the head restart control together.

The manager replays open controls after rehydration and after heartbeats. Rejected controls
reconcile the desired state to the actual agent state. PubSub is not used to authorize or order
these actions.

Run-wide controls and durable tool commands also treat idempotency keys as semantic identities,
not aliases for arbitrary later requests. Reuse returns the canonical row only when the
requested kind/tool, payload or arguments, target step, retry policy, scheduling value, and
requester fields covered by that record agree; conflicting reuse returns an idempotency error.
Run-wide control payloads reject recursively secret-shaped keys; completed, failed, and cancelled
runs reject new controls. When an orphaned run is reconciled, or a terminal run is explicitly
retried, its open run controls are superseded in the same durable transaction as the lifecycle
change.

### Durable, exactly-once steering consumption

A steering control is durably resolved as queued after validation. Consumption is a separate,
fenced database transaction. It selects queued steering in sequence order, changes the durable
result to `consumed`, and appends one `run.agent_steering_consumed` event. Later consumers no
longer match that row, so each control performs that durable queued-to-consumed transition
exactly once. Limits bound each drain, and consumption requires the live target generation.

Mission Control reads a bounded newest-first receipt window partitioned per agent and control
kind, so a noisy worker cannot starve other workers out of receipt retrieval. Each card renders
its newest receipt overall; that lifecycle distinguishes pending, claimed, rejected,
superseded, steering `queued`, and steering `consumed`. Submission or PubSub delivery alone is
never displayed as consumption. Duplicate open actions are disabled from the bounded receipt
projection, but the database rules above remain the authority.

This guarantee ends at the durable consumption checkpoint. A crash after that commit can stop
the coordinator before a downstream model observes the directive. It does not make downstream
model or native effects exactly once.

### Runtime ownership, pausing, and cancellation

Each run has a `RunFleetSupervisor` with a run-local task supervisor, dynamic agent supervisor,
and fleet manager. Fleet agents are started as temporary children, so an abnormal exit cannot
be automatically restarted under the old generation. The manager monitors the selected PID,
cancels its token, stops any registered child, and interrupts the fenced durable generation.

The primary planner, explorer, coder, and verifier work calls run through `FleetRuntime`. A
paused control token blocks new primary work until resume; a cancelled token rejects it.
Operation tasks inherit the fleet owner/control context, use the run-local task supervisor,
checkpoint the control token before the callback and progress effects, and are linked to their
owning agent. Run-wide stop enumerates only that run's fleet. Targeted pause, resume, restart,
and cancel do not enumerate other runs sharing the session.

Role-phase invocations retain the durable agent id rather than treating the PID captured during
initial attachment as permanent. Immediately before a call, `FleetManager` refetches the live
row and accepts only a PID whose stored generation matches the active leased generation. If an
agent crashes it becomes interrupted; an explicit restart fences the old incarnation, advances
the generation, and permits a later phase to resolve the replacement. The interrupted call is
not automatically replayed.

### Recovery policy

The run-fleet supervision tree uses `:one_for_all`, and fleet agents themselves are temporary
children. A supervised manager-child restart tears down its sibling runtime children and
run-local operation tasks together while retaining the tree's private credential. The manager
rehydrates the manifest from SQLite, interrupts the prior incarnation through the credential
check, claims a higher generation, and replays recoverable controls. Persisted paused agents
restart paused. Old generations cannot report progress, usage, completion, or control outcomes
after replacement. Application/process loss still follows the outer run dispatcher's
interruption-and-explicit-retry policy; it does not silently resume the fleet.

Recovery does not replay arbitrary in-flight agent code. An uncheckpointed operation is
interrupted, and an explicit control/retry is required where the durable contract permits it.

For `dag_v1`, an expired replay-safe step may be interrupted and scheduled as a new attempt only
while the same parent run attempt/generation, manifest, owner, and lease remain current. A stale
reconciliation cutoff cannot overwrite a renewed step lease. Completed results are immutable
within their attempt. Process/application loss still interrupts the outer run; explicit run
retry advances its generation, retains append-only attempt history, and resets the same static
logical graph. There is no automatic checkpoint resume: a bounded checkpoint receipt does not
resume arbitrary code at the instruction where it stopped.

### Redaction and notification boundaries

Fleet config, metadata, results, errors, and control payloads/results are size bounded and
reject recursively secret-shaped keys such as tokens, credentials, passwords, private keys,
and capabilities. Durable event sources and payloads do not contain the raw fleet bearer.
Workspace-lock read APIs and `Inspect` output redact their capability.

PubSub is a notification/projection channel, never authority. Consumers use durable ids and
sequences, and must tolerate dropped, duplicated, reordered, or stale messages. A PubSub tuple,
Registry entry, or live PID alone cannot authorize a fleet mutation.

The shared LLM `StreamClient` bounds a successful streamed response at 2 MB and collected HTTP
error bodies at 64 KB. Structured error collections and nesting are also bounded. Values from
recognized authentication headers—including bearer authorization and common API-key headers—
are extracted as redaction secrets and removed from HTTP, network, request-exception, catch,
and callback-exception results before they are returned. This protects exact supplied
credentials on those transport error paths; it is not a general sensitive-data classifier for
arbitrary model content or repository data.

### Usage accounting

Agent token, reported cost, latency, and request counts are recorded under the live generation
fence. Agent and parent-run totals update in one transaction. Provider-reported token usage can
fail the run and append budget/status events when the run token limit is exceeded; reported
cost does the same when `cost_budget_cents` is exceeded. The run dispatcher separately
enforces its configured worker wall-time limit. When a fleet usage settlement crosses either
reported threshold, the manager cancels the sibling control tokens, stops the run-local agent
children, and terminalizes every remaining fleet row as failed so the durable projection does
not show a live sibling after its parent run has failed.

Registered research DAG handlers call models/providers only through the runner-bound
`ProviderEffect`, which reserves declared request/token/cost ceilings before dispatch and settles
actual or conservative usage under run/step generation fencing. Coding and legacy research
accounting remains post-use rather than a shared reserve-before-dispatch hard ceiling.

## Remaining limitations

### No OS sandbox

Fleet and workspace fencing coordinate IexCode code paths; they are not a sandbox, container,
or worktree boundary. External editors, direct lower-level calls, independently launched
processes, hard links, mount/bind aliases, symlink/root swaps, and other physical path aliases
can bypass cooperative coordination.

### Workspace delegation is not agent-generation bound

The workspace gateway validates the outer run's private delegation reference, project, run,
session, covered resource, and live workspace capability immediately before cooperating
effects. The same run-level delegation is currently shared with fleet members. It does not yet
encode the individual agent id, generation, or cancellation epoch. A future subdelegation must
be revoked on agent pause/cancel/restart/expiry without revoking unrelated siblings.

### Native descendants may outlive cooperative cancellation

Run-local BEAM tasks and agent processes are supervised and linked, but a native command may
spawn descendants outside that process tree. Killing an owner or closing a port does not prove
that every OS descendant has stopped. Terminal ownership and workspace release therefore must
not be described as process isolation or proof of native cleanup.

### Coding and legacy-research budgets are accounted after use

Coding and legacy-research provider usage is settled after a response. Those paths have no
atomic pre-use reservation shared across the run, agent subtree, and parallel agents. Crossing
either `token_budget` or `cost_budget_cents` fails the run when that reported usage is recorded,
but neither value is a pre-use hard ceiling: concurrent calls can overshoot by work already in
flight. Registered research DAG effects are the bounded exception: they reserve declared
request/token/cost ceilings before dispatch and settle actual or conservative usage under the
current run and step generations. Hierarchical reservations and versioned pricing shared by
coding, legacy research, and every provider path remain to be implemented.

### General mutation replay is not checkpoint-safe

Control replay is durable and bounded, and steering consumption is exactly once. General LLM,
tool, filesystem, Git, terminal, and native effects do not yet have a universal checkpoint and
idempotency contract. Recovery must continue to interrupt rather than automatically replay an
uncertain mutation.

### DAG v1 is static and mutation-free

The project handlers' `project_read_v1` resource contract is immutable handler metadata, not a
per-step workspace-lock acquisition or OS capability. Those handlers are contained reads or pure
aggregation. The eight registered research handlers instead declare descriptor-bound evidence,
provider, fetch, or model resource contracts and route external calls through the fenced
`ProviderBudget` and `ProviderEffect` boundary. No coding-agent, filesystem-mutation, Git,
terminal/native-command, or approval handler is registered. Such mutation handlers require real
resource admission, generation-bound delegation, effect idempotency, approvals, and terminal
cleanup before activation.

Graphs cannot expand after creation. There is no automatic checkpoint resume, per-node operator
control, manual approval-gate handler, or DAG steering. Pause/resume/cancel and retry are
run-wide. The exact finite research adapter resolves all eight of its typed kinds through the
closed registry; unknown kinds and mutation handlers still fail closed.

### Actor authorization remains local-user scoped

`requested_by` is audit data, not authentication. The current product assumes its protected
local operator boundary. Remote/multi-user deployments require an authenticated principal and
authorization policy before exposing fleet controls.

## Security verification checklist

- [x] Two runs in one session use disjoint Registry identities and stopping one leaves the
      other alive.
- [x] Unknown roles and conflicting Registry occupants fail closed.
- [x] Manifest bounds, parent scope, immutable-field equality, enums, lifecycle, and numeric
      invariants are checked.
- [x] Fleet bearer credentials are stored only as redacted hashes; the raw bearer is absent
      from durable events, public control results, and PubSub projections.
- [x] Heartbeats, transitions, usage, controls, and steering reject stale credentials or
      generations.
- [x] Duplicate controls are canonicalized by idempotency key; sequence order is enforced and
      abandoned claims can be reclaimed.
- [x] Restart advances generation atomically with its head control; stale workers are rejected.
- [x] Steering is consumed in order, under a live lease, at most once.
- [x] Paused/cancelled tokens gate new fleet work and run-local operation callbacks.
- [x] Abnormal fleet-agent exits do not auto-restart stale generations.
- [x] Manager-tree restart tears down old children and rehydrates higher generations.
- [x] Crafted run/session/project attachment scope is rejected.
- [x] Application changesets reject execution-engine changes, unavailable engines cannot be
      claimed, and claimed manifests are revalidated before execution.
- [x] Later phase invocation resolves the live fenced generation after explicit agent restart.
- [x] Mission Control receipts distinguish persisted/claimed/queued/consumed outcomes without
      using PubSub as authority.
- [x] Conflicting command/control idempotency reuse fails closed and orphaned controls are
      superseded with their run lifecycle transition.
- [x] Reported token or cost exhaustion gates new runtime work and terminalizes the run fleet.
- [x] Streaming success/error collection is bounded and supplied auth-header credentials are
      redacted from returned transport errors.
- [x] DAG manifests are bounded, acyclic, canonical-hashed, changeset-immutable, and restricted
      to a closed typed, mutation-free registry of project-read and research handlers.
- [x] DAG claims, heartbeats, checkpoints, settlement, and terminalization reject foreign or
      stale parent/step owners and generations.
- [x] Concurrent claims create one attempt; dependency fan-in waits for completed predecessors;
      retry exhaustion fails the node and skips descendants.
- [x] Expired safe attempts retry only under current parent authority; terminal parents leave no
      active DAG attempt.
- [x] DAG params/checkpoints/results reject secret-shaped or oversized JSON, and public
      projections omit owners, results, checkpoint bodies, and execution keys.
- [ ] Add agent-generation-bound workspace subdelegation and revocation.
- [ ] Prove or quarantine uncertain native descendants before declaring cleanup complete.
- [x] Add fenced request/token/cost reservations before research provider dispatch.
- [ ] Extend hierarchical reservations and versioned pricing to coding and every tool/provider.
- [ ] Add explicit checkpoint/idempotency contracts before replaying general mutations.
- [ ] Add authenticated actor authorization before supporting remote multi-user control.
- [x] Add finite research DAG handlers with provider idempotency, usage, recovery, and final
      checksum-addressed report contracts.
- [ ] Add DAG mutation handlers only with real workspace resources, approvals, and cleanup.
- [ ] Add authorized manual gates, per-node controls, and bounded dynamic graph expansion.
