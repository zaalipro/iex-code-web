# Original User Request

## 2026-08-23T08:22:54Z

Perform an exhaustive zero-gap feature audit and refinement pass across all 9 tabs and developer tools in IexCode (Kanban, Swarm, Calendar, Changes/Git, Tests/AutoFix, AST Explorer, Chat, Files/Editor, Terminal, and Settings), ensuring every button, action, view, and workflow operates end-to-end without sandboxing or git worktree isolation.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Comprehensive Tab & Tool Feature Gap Elimination
Audit every view, tab, modal, and drawer in `WorkspaceLive` and `WorkspaceComponents` to guarantee zero stubbed clicks, 100% active event handlers, and end-to-end functionality:
- **Kanban Board**: Full task creation, status transition, priority/assignee filtering, subtask management, and detail drawer editing.
- **Swarm Studio**: Start, pause, resume, cancel (with rollback/commit options), steer, live 4-column telemetry, DAG hierarchy, thinking trace inspection.
- **Visual Test Runner & AutoFix**: Full suite run, failed test run, single file run, ANSI log parsing, structured failure diffs, 1-click heuristic patch preview and apply.
- **AST Query Explorer**: Full symbol search across definitions (`def`, `defp`), macros, modules, and typespecs (`@spec`, `@type`), with jump-to-editor.
- **Git Staging & Diff Hub**: 3-tier staging rails (Staged, Unstaged, Untracked), side-by-side & inline diff viewer, granular hunk unstaging, branch switching/creation/fetch/pull, and AI commit message generation.
- **Inline File Editor & Explorer**: File tree navigation, fuzzy file search, buffer tabs, dirty tracking, saving, and jump-to-line.
- **Embedded Terminal**: Interactive command execution, quick actions (`mix test`, `mix precommit`, `git status`), ANSI formatting, command history, and process interruption.
- **AI Chat & Streaming**: Multi-model SSE streaming, prompt history, context injection, token/cost telemetry, and quick code insertion.
- **Calendar & Timeline**: Date grid navigation, scheduled task inspection, daily activity metrics, and session timeline.
- **Settings & Provider Hub**: Complete API key management, model selection (OpenAI, Anthropic, Gemini, local CLI proxy), temperature/token controls, and persistence.

### R2. Native Workspace Execution (No Sandbox, No Git Worktree)
- All tool operations (test execution, git commands, file reads/writes, terminal commands) operate directly and natively within the project's root directory (`/Users/zaali/dev/iex-code`).
- No virtual containers, sandboxes, or git worktree directories are required or created.

### R3. Adversarial Resilience, Quality & Precommit Verification
- Comprehensive unit, LiveView integration, and stress tests ensuring 100% feature coverage and edge-case handling across all tabs.
- Clean compilation (`mix compile --warnings-as-errors`), clean formatting (`mix format --check-formatted`), 0 dead assigns, and 0 compiler warnings under `mix precommit`.

## Acceptance Criteria

### Tab & Workflow Completeness
- [ ] Every interactive element (buttons, modals, inputs, drag/clicks) across all 9 tabs dispatches an active LiveView event with zero crashes or unhandled callbacks.
- [ ] Direct file editing, test execution, git staging, and terminal commands execute natively on the workspace root.

### Quality & Precommit
- [ ] `mix test` passes 100% across all suites with 0 failures.
- [ ] `mix precommit` passes with 0 compiler warnings, 0 unused deps, and 0 format errors.
