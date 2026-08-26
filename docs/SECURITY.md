# Security model

IexCode Web is a high-trust host-control application. It intentionally combines
an LLM, a native terminal, Git credentials, tests, and writable source trees.
That makes its security boundary different from a normal content website.

## Supported trust model

- One trusted human operator controls one deployment.
- The operator trusts the repositories mounted into the deployment.
- The operator reviews enabled tools, budgets, goals, and model providers.
- Network access is restricted with TLS plus a firewall, VPN, or authenticated
  reverse proxy.
- The host and application containers are maintained as privileged infrastructure.

IexCode Web does **not** provide multi-tenant isolation. Do not share a deployment
between mutually untrusted users or expose it as a public coding service.

## What access means

The terminal and coding tools can run commands and modify mounted workspaces.
Processes inherit the permissions and mount access of the runtime user. A model
or repository instruction may invoke compilers, package managers, Git hooks, or
other native programs.

The application and those workspace processes run as the same container UID.
Because the application state directory is also mounted into that container,
executed workspace code can read or change the SQLite database, research
artifacts, and provider credentials stored there. File modes protect this data
from other host users; they do **not** isolate it from terminal commands, tests,
Git hooks, packages, or agent tools executed by IexCode. Do not open, build, or
run repositories you do not trust.

Durable workspace locks, file/Git resource admission, generation fencing, and
atomic patch paths coordinate IexCode operations. They are cooperative controls,
not an OS sandbox:

- an external editor or process can bypass them;
- filesystem aliases outside canonical paths may not be represented;
- arbitrary shell commands are not transactional; and
- tool-spawned descendants can outlive forced run cancellation.

Use a dedicated VPS. Do not mount `/`, `/root`, Docker's control socket, your
personal home directory, or unrelated secrets. Prefer narrowly scoped repository
deploy keys and minimal runtime permissions.

## Authentication and network boundaries

The installer generates a random operator token and stores only its SHA-256 hash.
Treat the login token and session material as secrets. Do not place tokens in
URLs, command-line arguments, shell history, logs, screenshots, or support
bundles. Rotate a lost token with `sudo iex-code-web reset-token`.

Authentication does not make the application safe for untrusted tenants. Add an
outer network boundary:

1. best: a private VPN or identity-aware proxy;
2. good: trusted TLS with a strict source-IP firewall allowlist; or
3. temporary testing only: direct IP and port, internal TLS, one trusted IP.

`IEX_CODE_ALLOW_REMOTE=true` only disables the original loopback access guard. It
is not authentication by itself. The container/proxy configuration must keep raw
upstreams private and accept trusted forwarded headers only from the proxy.

Phoenix LiveView uses WebSockets and CSRF-protected browser sessions. A reverse
proxy must preserve the public host and scheme and forward WebSocket upgrades.
Use TLS for every non-loopback connection.

## Secrets and data at rest

Secrets can exist in two places:

- `/etc/iex-code-web/app.env`, which must remain root-readable only; and
- the SQLite Settings row below `/var/lib/iex-code-web`.

Settings structs redact known credentials when inspected and credential writes
avoid SQL bind logging, but stored API keys are not encrypted with an OS keychain
or envelope-encryption service. Database copies and backups therefore contain
secrets. The shared runtime UID also means workspace code can access that
database. Encrypt backup storage, restrict host readers, run only trusted code,
and rotate provider keys after suspected exposure.

`SECRET_KEY_BASE` protects Phoenix cookie/session cryptography; it is not a
replacement for database encryption. Rotating it invalidates existing browser
sessions and must be coordinated through supported operations.

Never commit `.env` files, database files, generated certificates, access tokens,
or real provider keys. Documentation and tests must use placeholders.

## Provider and model risks

Prompts, selected files, tool results, and research content may be sent to the
configured external provider. Review its retention, training, geographic, and
account policies before using private code.

Durable coding and research work snapshots a secret-free hash of its effective
provider/model/base-URL route. Credential rotation can proceed without changing
that route. Endpoint, provider, or model drift fails closed before the next
transport rather than sending queued data somewhere newly configured.

Model responses, repository files, webpages, and prior research reports are
untrusted inputs. Prompt-injection resistance is not a complete authorization
boundary. Disable unnecessary tools, cap turns/tokens/time/cost, review diffs,
and do not give the runtime cloud-instance credentials.

Public research fetches reject local, private, link-local, reserved, and unsafe
redirect destinations and use bounded types, bytes, and time. These SSRF controls
do not make arbitrary terminal network commands safe.

## Durable execution controls

Runs persist their objective, execution policy, events, attempts, controls, and
usage in SQLite. Lease owner, attempt, generation, and expiry fence settlement.
Pause/cancel checks occur at integrated model and tool checkpoints; they cannot
undo already completed external effects.

Important operational behavior:

- Browser disconnect does not cancel a durable run.
- At least one server process must remain alive to claim queued work.
- Server loss interrupts the outer active run; it is not silently resumed.
- Explicit retry starts a new generation only when policy permits.
- Exact research permits one whole-run paid attempt to avoid replaying ambiguous
  external effects.
- A forced stop may leave native descendants requiring OS-level cleanup.

Before an autonomous goal or swarm, commit the checkout, take a backup, set
budgets, and know how to cancel both the run and any remaining OS process.

## Deployment hardening checklist

- [ ] Use a dedicated, fully patched VPS.
- [ ] Disable SSH password and direct root login; use keys and MFA where offered.
- [ ] Permit the application port only from a trusted IP, or keep it behind a
      VPN/authenticated reverse proxy.
- [ ] Use trusted TLS for ongoing use; retire the internal direct-IP endpoint.
- [ ] Keep `/etc/iex-code-web/app.env` mode `0600` and restrict
      `/var/lib/iex-code-web` and backup readers.
- [ ] Do not mount the Docker socket, host root, or broad home directories.
- [ ] Use narrow Git deploy keys and provider keys with spending/rate limits.
- [ ] Disable unused agent tools and research providers.
- [ ] Set bounded turns, cost, token, time, attempt, and fleet limits.
- [ ] Push commits and store encrypted backups away from the VPS.
- [ ] Test restore and operator recovery on an isolated host.
- [ ] Review application/provider logs and usage regularly.

## Incident response

For suspected account or agent compromise:

1. block external access at the cloud firewall;
2. stop the deployment without destroying `/var/lib/iex-code-web`;
3. revoke provider, Git, SSH, proxy, and operator credentials;
4. snapshot disks/logs if forensic retention is required;
5. inspect workspace changes and native descendants from outside the container;
6. restore onto a clean host from a known-good backup; and
7. rotate secrets that were present in any retained database or backup.

Do not assume cancelling a LiveView run reverses filesystem, Git, provider, or
network effects that already occurred.

## Reporting security issues

Use a private repository security advisory or another private channel maintained
by the repository owner. Do not open a public issue containing an exploit, access
token, provider key, private source, database, or backup.

For deeper control-plane invariants, read
[Run fleet security](RUN_FLEET_SECURITY.md).
