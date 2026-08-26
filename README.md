# IexCode Web

IexCode Web is a self-hosted coding workspace and durable agent control plane.
It brings chat, files, Git, tests, a native terminal, long-running goals, coding
swarms, and cited research into one Phoenix LiveView application.

> [!WARNING]
> IexCode Web can run shell commands and modify every workspace mounted into it.
> It is designed for one trusted operator on infrastructure they control. It is
> not a multi-tenant service or an OS sandbox. Workspace commands run as the
> same container user as the application and can read the mounted SQLite state,
> including saved provider credentials. Never run an untrusted repository or
> untrusted code in this deployment.

## Install on a VPS

The installer supports current Ubuntu and Debian hosts with Docker Engine and
the Compose plugin available (it installs them when needed).

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh | sudo bash
```

For a fresh VPS with a domain and automatic public TLS:

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh \
  | sudo bash -s -- --domain <YOUR_DOMAIN> --yes
```

The final installer output contains the HTTPS URL and a newly generated
administrator token. It is printed only once. Open the URL and enter the token.
Store it in a password manager; do not paste it into shell history, screenshots,
issues, or chat.

The hosted deployment is <https://iex.llmotions.com> and uses publicly trusted
TLS. A generic IP-only installation instead uses Caddy's internal certificate
and produces an expected browser trust warning until a domain and trusted
certificate are configured. If the VPS already has Nginx, Caddy, or another
edge on ports 80/443, use the documented `--behind-proxy` topology rather than
competing for those ports.

Prefer to inspect remote scripts before running them:

```bash
curl -fsSLo /tmp/iex-code-web-install.sh \
  https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh
less /tmp/iex-code-web-install.sh
sudo bash /tmp/iex-code-web-install.sh
rm -f /tmp/iex-code-web-install.sh
```

The install creates:

| Path | Purpose |
| --- | --- |
| `/opt/iex-code-web/source` | Installed source, `compose.yaml`, and deployment files |
| `/etc/iex-code-web/app.env` | Root-owned runtime configuration and secrets |
| `/var/lib/iex-code-web` | SQLite data and research reports |
| `/var/backups/iex-code-web` | Manager-created backup archives |
| `/srv/iex-code-workspaces` | Repositories exposed to the application |
| `/usr/local/bin/iex-code-web` | Operator command |

See the [complete VPS installation guide](docs/INSTALL_VPS.md) before exposing
the service beyond a trusted test host.

## Configure a model

After signing in, open **Settings → Model providers** and configure:

| Field | Example |
| --- | --- |
| Provider | `OpenAI or compatible` |
| Base URL | `https://cli.llmotions.com/v1` |
| API key | `<YOUR_LLMOTIONS_API_KEY>` |
| Model | `deepseek-v4-pro` |

Model identifiers are passed through unchanged. Blank credential fields preserve
the saved secret; **Remove credential** clears it. Credentials entered in Settings
are stored in the local SQLite database, not an encrypted secret manager. Protect
both `/etc/iex-code-web` and `/var/lib/iex-code-web`.

Start with a harmless chat request. Then review the execution budgets, enabled
tools, maximum turns, swarm size, goal auto-start policy, and research providers
before launching autonomous work.

## What is included

| Area | Capability |
| --- | --- |
| Chat | Persistent conversations, model selection, tool-backed runs, rich responses |
| Goals | Durable queued or draft goals with pause, resume, cancel, retry, and steering |
| Swarm | Persistent planner, coder, verifier, and explorer fleets with per-agent control |
| Research | Exact low/medium/high/ultra workflows, ranked sources, cited Markdown and HTML reports |
| Files and AST | Searchable tree, editor buffers, safe save/revert, Elixir symbol search |
| Changes | Staged/unstaged diffs, hunk actions, branches, and commits |
| Tests | Asynchronous ExUnit runs, parsed failures, and reversible AutoFix proposals |
| Terminal | Supervised native PTY, ANSI output, resize, signals, history, and quick actions |
| Planning | Kanban, schedules, subtasks, priorities, and a monthly calendar |
| Settings | Models, credentials, budgets, dispatch, fleets, research, editor, and usage |

The composer and local Mix CLI share a strict command vocabulary:

| Input | Result |
| --- | --- |
| Ordinary text | Uses the configured interactive or durable dispatch policy |
| `/chat OBJECTIVE` or `/ask OBJECTIVE` | Interactive conversation |
| `/run OBJECTIVE` | Durable bounded single-agent run |
| `/goal OBJECTIVE` | Durable swarm goal using the configured draft/queue policy |
| `/goal --draft OBJECTIVE` | Durable goal saved for review |
| `/swarm OBJECTIVE` | Durable coding fleet |
| `/research --level LEVEL OBJECTIVE` | Static, durable research DAG |
| `/deep_research` | Selects a ready report for conversation context |

Work is journaled in SQLite and claimed by leased OTP workers. A connected
browser is not required after submission, but one continuously running
application instance is required to claim queued work.

## Operate the service

```bash
sudo iex-code-web status
sudo iex-code-web logs
sudo iex-code-web update
sudo iex-code-web backup
```

Updates create a backup before changing the deployment. Backup SQLite together
with report artifacts; copying only a live `.db` file is not a valid backup when
WAL mode is active. For restore, token rotation, firewall, reverse-proxy, and
uninstall instructions, see:

- [VPS installation](docs/INSTALL_VPS.md)
- [Operations and recovery](docs/OPERATIONS.md)
- [Security model](docs/SECURITY.md)
- [Fleet and control-plane security](docs/RUN_FLEET_SECURITY.md)
- [Research DAG architecture](docs/DAG_V1_RESEARCH_INTEGRATION.md)

## Development

Requirements for source development:

- Elixir `~> 1.15` and a compatible Erlang/OTP release
- Node.js and npm
- Git and SQLite
- Python 3 and a POSIX environment for the native PTY shim

```bash
git clone https://github.com/zaalipro/iex-code-web.git
cd iex-code-web
mix setup
mix phx.server
```

Open <http://localhost:4000>. Development binds to loopback by default.

Run the required gate before submitting changes:

```bash
mix precommit
```

The alias compiles with warnings as errors, removes unused dependency locks,
formats the project, migrates the test database, and runs the test suite.

### Local Mix CLI

A source checkout can enqueue and control the same durable records as the web
composer. Keep an IexCode Web application process connected to the same database;
the short-lived Mix command deliberately starts no private worker.

```bash
mix iex_code.run /run "inspect and fix the failing boundary"
mix iex_code.run /goal --draft "prepare the release checklist"
mix iex_code.run /swarm "audit and harden the control plane"
mix iex_code.run /research --level high "compare queue designs"
mix iex_code.runs --limit 20
mix iex_code.control <RUN_ID> status
mix iex_code.control <RUN_ID> pause
mix iex_code.control <RUN_ID> resume
mix iex_code.control <RUN_ID> cancel
```

Use `mix help iex_code.run`, `mix help iex_code.runs`, and
`mix help iex_code.control` for strict options, idempotency keys, waiting, JSON,
budgets, project/session selection, retry, draft start, and steering.

## Architecture at a glance

IexCode Web uses Elixir/OTP, Phoenix 1.8, LiveView, SQLite, and xterm.js.
Durable runs have immutable execution-policy snapshots, ordered events, leases,
generation fencing, idempotent controls, bounded model/tool loops, and cooperative
workspace reservations. Static `dag_v1` workflows persist node attempts and
checkpoints. Research results become checksum-addressed Markdown and script-free
HTML artifacts.

Execution is deliberately **in place**: commands and tools run in the mounted
repository with the permissions of the application container and its mounted
paths. Cooperative locks reduce collisions between IexCode operations, but do
not contain arbitrary native processes or external editors.

## Important limitations

- This release is for one trusted operator; it has no tenant isolation.
- Tool execution is not an OS security boundary or transaction.
- Workspace commands share the application's container UID and mounted state.
  They can read the SQLite database, research output, and saved provider keys;
  only mount repositories and execute code you trust.
- API keys stored through Settings are not protected by a keychain or vault.
- An application/process loss interrupts the outer active run; explicit retry
  starts a new generation when policy permits.
- Exact research intentionally allows one whole-run paid attempt. Review and
  launch a new run after interruption or terminal failure.
- Tool-spawned external descendants may outlive forced cancellation.
- Direct IP access uses a self-signed certificate. Use a domain with trusted TLS,
  a VPN, or a private firewall allowlist for ongoing use.

Read [SECURITY.md](docs/SECURITY.md) before mounting valuable repositories or
making the service network-accessible.
