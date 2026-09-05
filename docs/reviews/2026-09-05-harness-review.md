# Harness review — 2026-09-05

Reviewed the desktop repository (`iex-code`) and web repository (`iex-code-web`).
The review concentrated on model/tool transcripts, agent cancellation, durable
workflow execution, and workflow creation. It included independent subagent
reviews, regression tests, and Ego Lite interaction with disposable local data.

## Confirmed defects addressed

| Scope | Trigger and previous behavior | Change |
| --- | --- | --- |
| Both | A coder invokes tools, then sends replies without the assistant's `tool_calls`; subsequent provider requests contain orphan tool results. | Preserve the complete assistant request, including when model text is empty or nil. |
| Both | Compaction cuts through parallel tool replies and discards their assistant request. | Both history strategies use one boundary helper that preserves the complete exchange. |
| Both | A planner receives `{:error, :cancelled}` but reports a successful fallback plan. | Propagate explicit cancellation; retain the established fallback contract for other provider errors. |
| Both | A workflow task dies without sending its result, leaving a running step forever. | Supervise, link, and monitor tasks; correlate results by task reference and persist task exits as failures. |
| Both | An engine restarts with persisted running steps and no tasks that can finish them. | Mark interrupted execution failed and require explicit retry. Linked tasks terminate when the engine dies. |
| Both | Changing workflow metadata discards the generated DAG, preventing save. | Preserve the server-generated blueprint through form validation and submission. |
| Web | An operation worker exits normally before recording a result; the monitor ignores its DOWN message. | Finalize every still-registered exit. Successful workers unregister only after recording their terminal result. |

The workflow changes retain the existing public execution and retry APIs. No
schema migration, provider dependency, or full execution-plane rewrite is needed.

## Remaining architecture priorities

1. **Unify workflow execution ownership.** `Workflows.Engine` is a second execution
   state machine beside `Runs.RunDispatcher` and the durable DAG runner. It does
   not inherit their lease generations and effect receipts, and
   `update_run_record/2` can return stale state after persistence fails. Compile
   workflow definitions into durable run steps and make the existing run plane
   the single owner of execution, retry, cancellation, and event persistence.
   This is a larger migration, not part of the local lifecycle fixes.
2. **Move legacy cancellation off the busy agent mailbox.** Legacy agents perform
   provider/tool work synchronously inside `handle_call`; their own `handle_info`
   callbacks cannot update cancellation while that work blocks. A separate
   cancellation owner or asynchronous agent state machine should update the
   cooperative token promptly. Durable fleet control already uses a separate path.
3. **Reconcile shared-core drift.** Web has `AgentStateRetention`, atomics-based
   cancellation, session passivation, and `OperationMonitor`; desktop has differing
   implementations, including unbounded agent result histories. Define shared
   lifecycle contracts and run the same contract tests in both repos before
   extracting a shared OTP application. Keep desktop shell and web auth separate.
4. **Harden lease-heartbeat database failure handling.** `Runs.renew_lease/4` uses
   direct repository calls from the dispatcher's heartbeat callback. A database
   exception can escape that callback. Add fault-injection coverage and bounded,
   fail-closed handling for each run without blocking renewal of all other runs.
   This finding is from code inspection, not a reproduced database outage.
5. **Extend transcript and external-process guarantees.** The durable
   `AgentLoop.bounded_context/1` still trims individual messages by size; it should
   eventually share exchange-aware truncation. Workflow owner-kill tests establish
   Elixir task termination, not termination of all descendant OS processes launched
   through `System.cmd`. Validate process-group cleanup separately.

## Verification scope

Regression cases were first observed failing, then rerun after the fixes. Full
`mix precommit` checks cover compilation with warnings as errors, formatting,
dependency-lock hygiene, and tests. Web verification uses the versions pinned in
`.tool-versions` (Elixir 1.18.4 / OTP 28), rather than the shell's newer global runtime.

Browser checks use Ego Lite with disposable SQLite databases and local fixtures.
They cover desktop workspace/workflow navigation and web sign-in, workspace,
workflow creation, and settings. They do not exercise paid model calls or a
packaged native window. The task space is closed after verification; existing
browser sessions and cookies are preserved.

Some existing terminal stress tests inspect all PTY shims on the host. Running
both full suites or smoke servers concurrently can produce false leak findings;
rerun those checks with the other harness and smoke servers stopped.

## Recorded results

- Desktop full `mix precommit`: 3,248 tests; one outdated cancellation fixture failed.
  The corrected fixture passed in `mix precommit --failed` (1 test, 0 failures).
- Web full `mix precommit`: 2,616 tests; the same fixture plus three host-wide
  PTY-count assertions failed during concurrent execution. With the fixture fixed
  and other harnesses stopped, `mix precommit --failed` passed (4 tests, 0 failures).
- Both asset builds passed. Targeted workflow editor suites passed (15 tests each),
  and workflow engine suites passed (17 tests each).
- Final Ego Lite checks saved the edited workflow with five steps preserved in
  both variants; web sign-in and settings navigation also succeeded.
