# E2E Test Infra: Interactive PTY Terminal

## Test Philosophy
- Opaque-box, requirement-driven. No dependency on implementation design.
- Methodology: Category-Partition + BVA + Pairwise + Workload Testing.

## Feature Inventory
| # | Feature | Source (requirement) | Tier 1 | Tier 2 | Tier 3 |
|---|---------|---------------------|:------:|:------:|:------:|
| 1 | Supervised PTY Process Spawner | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 2 | Bidirectional Stdin / Keystroke Forwarding | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 3 | PubSub Raw Output Streaming | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 4 | Dynamic Window Resizing (SIGWINCH) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 5 | Shell Lifecycle & Clean Termination | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| 6 | Sliding Ring Buffer Memory Storage | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 7 | Agent Command Execution Dispatch | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 8 | Live Agent Execution Streaming & Telemetry | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 9 | Visual Terminal Occupation Indicator | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 10 | Searchable Terminal History API | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| 11 | xterm.js Terminal Canvas & Hook | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 12 | Terminal Dimension Auto-Fitting (`fitAddon`) | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 13 | Quick Action Toolbar | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 14 | Terminal Clear & History Reset | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| 15 | LiveView Workspace Integration | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |

## Test Architecture
- Test Runner: `mix test test/iex_code/tools/ test/iex_code_web/live/workspace_live_terminal_test.exs test/iex_code/e2e_terminal/`
- Pass/Fail Semantics: 100% test pass rate with exit code 0, 0 compiler warnings.
- Test Layout:
  - `test/iex_code/tools/terminal_session_test.exs` (Tier 1 & 2 Backend)
  - `test/iex_code/tools/terminal_server_test.exs` (Tier 1 & 2 Facade & Buffer)
  - `test/iex_code/engine/agent_terminal_execution_test.exs` (Tier 1 & 2 Agent & Telemetry)
  - `test/iex_code_web/live/workspace_live_terminal_test.exs` (Tier 1, 2, 3 LiveView & UI)
  - `test/iex_code/tools/terminal_stress_test.exs` (Tier 4 & 5 Workload, Floods, Crashes, Zombies)
  - `test/iex_code/e2e_terminal/e2e_pty_terminal_test.exs` (Tier 3 & 4 End-to-End Scenarios)

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Full Interactive REPL Workflow (`iex -S mix`) | F1, F2, F3, F4, F6, F11, F15 | High |
| 2 | Automated Agent Verifier Execution with User Monitor | F7, F8, F9, F3, F6, F15 | High |
| 3 | Quick Action Execution & Clear (`mix test` -> `clear` -> `git status`) | F2, F3, F13, F14, F15 | Medium |
| 4 | Terminal Dimension Resizing under Active Output Stream | F3, F4, F12, F15 | Medium |
| 5 | Process Crash Recovery & Respawn without Zombie Leaks | F1, F5, F6, F15 | High |

## Coverage Thresholds
- Tier 1: ≥5 per feature
- Tier 2: ≥5 per feature (boundary and error conditions)
- Tier 3: Pairwise coverage of major feature interactions
- Tier 4: ≥5 realistic application scenarios
- Tier 5: Adversarial hardening and stress resistance
