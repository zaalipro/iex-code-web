# Operations and recovery

The `/usr/local/bin/iex-code-web` command manages the installed Compose
deployment. Run administrative actions with `sudo`.

## Routine commands

```bash
sudo iex-code-web status
sudo iex-code-web logs
sudo iex-code-web restart
sudo iex-code-web stop
sudo iex-code-web start
sudo iex-code-web update
sudo iex-code-web backup [<DESTINATION>]
sudo iex-code-web restore <BACKUP_ARCHIVE>
sudo iex-code-web reset-token
sudo iex-code-web config
sudo iex-code-web uninstall [--purge]
```

Use `Ctrl-C` to leave the live log stream; it does not stop the service.
Deployment files are in `/opt/iex-code-web`, environment settings in
`/etc/iex-code-web/app.env`, persistent application data in
`/var/lib/iex-code-web`, manager backups in `/var/backups/iex-code-web`, and
repositories in `/srv/iex-code-workspaces`.

## Health checks

```bash
sudo iex-code-web status
sudo iex-code-web config
sudo iex-code-web logs
sudo ss -ltnp
df -h /var/lib/iex-code-web /srv/iex-code-workspaces
```

SQLite uses WAL mode. Short write contention is retried or bounded; persistent
`database is locked`, read-only, or disk-full errors require operator action.

`status` reports whether application work is idle or active and includes the
current container/BEAM memory and BEAM port usage when runtime inspection is
available. `idle` means there are no active or queued runs, active or paused
agents, active fleets, or active DAG attempts. Sessions and dormant terminals
are displayed but do not make the application active. Use Docker for a second,
cgroup-level view:

```bash
APP_ID=$(sudo docker ps \
  --filter label=com.docker.compose.project=iex-code-web \
  --filter label=com.docker.compose.service=app --quiet | head -n1)
sudo docker stats --no-stream "$APP_ID"
sudo docker inspect --format \
  'hard={{.HostConfig.Memory}} reservation={{.HostConfig.MemoryReservation}} pids={{.HostConfig.PidsLimit}} ulimits={{json .HostConfig.Ulimits}}' \
  "$APP_ID"
sudo docker exec "$APP_ID" sh -lc \
  'ulimit -n; cat /sys/fs/cgroup/memory.current; cat /sys/fs/cgroup/memory.max; cat /sys/fs/cgroup/memory.events'
sudo docker exec "$APP_ID" /opt/iex-code/bin/iex_code rpc \
  'IO.inspect(%{memory: :erlang.memory(:total), port_limit: :erlang.system_info(:port_limit)})'
```

With the default Balanced profile, the hard limit is `2147483648` bytes, the
reservation is `536870912` bytes, the process limit is `1024`, and `ulimit -n`
is `65536`. During a verified idle period, container memory should normally stay
below 600 MiB and BEAM memory below 300 MiB. Investigate active/queued work, terminals, and logs before
attributing higher usage to an idle baseline. Any non-zero `oom` or `oom_kill`
counter in `memory.events` needs investigation.

To verify a stable idle baseline, first use `sudo iex-code-web status` to
confirm zero active/queued work. Then sample `docker stats --no-stream` and the
release RPC above for five continuous minutes. With default limits, every idle
sample must remain below 600 MiB of container memory and 300 MiB of BEAM memory,
the reported BEAM port limit must remain `65536`, and `memory.events` must show
`oom 0` and `oom_kill 0`.

### Admission governor

The hard Docker limit is the final boundary; normal concurrency is regulated
earlier by the memory-aware governor. Its default pressure/critical thresholds
are 70%/85%. It assigns conservative weights to model calls, AST scans,
research fetches, DAG steps, native commands, and build/test work, then queues a
new producer if admitting it would consume safety headroom. Existing work is not
cancelled, and its reasoning settings, swarm topology, and research depth are
not reduced.

Interactive work is considered first and has profile-specific reserved
headroom. Background work rotates by durable run, preventing one swarm or DAG
from monopolizing capacity. **Settings → Runtime** reports the memory state,
active permits, and interactive/background queue depths. **Settings →
Resources** changes the thresholds live. Raising a Docker profile increases the
envelope but does not preallocate memory or bypass admission.

## Update

```bash
sudo iex-code-web update
```

The manager creates a consistent backup, fetches the configured source ref,
rebuilds the images, runs migrations during application startup, replaces the
containers, and checks health. Do not interrupt it during migration or container
replacement. Review release notes before upgrading across multiple versions.

If an update fails, preserve the logs and automatic backup. Do not repeatedly
restart a partially migrated deployment. Record the old source ref before
changing it; a code rollback cannot reverse a destructive database migration.

## Backup

```bash
sudo iex-code-web backup
sudo iex-code-web backup <DESTINATION>
```

A manager backup contains a transactionally consistent SQLite database, the
research outputs, and bounded command/test output artifacts below
`/var/lib/iex-code-web`. Repositories below `/srv/iex-code-workspaces`
are separate: push commits to a remote and back up uncommitted work independently.

To keep file artifacts aligned with their SQLite metadata, the manager briefly
stops only the application container while capturing the archive and starts it
again on both success and failure. The proxy remains running; expect a short
maintenance window rather than an inconsistent mixed-time backup.

Never copy only a live `.db` file: recent committed pages can still be in the
`-wal` file. Use the manager backup, an online SQLite backup, or stop all writers
before copying the entire data directory.

After creation:

1. copy the archive off the VPS to separately protected storage;
2. record the deployed application source ref/version;
3. protect the archive as a secret—it can contain provider credentials; and
4. periodically test restoration on an isolated host.

## Restore

```bash
sudo iex-code-web restore <BACKUP_ARCHIVE>
```

Restoration is destructive to current application state. The manager validates
its own archive structure, but you should still make an additional backup first
and verify version compatibility. Do not combine database files from different
snapshots.

The manager extracts into a private staging directory, stops the application
writer, creates a safety backup, and swaps the database, research data, and
output artifacts together. If the swap is interrupted it restores the previous
state before returning an error. An application that was running before restore
is restarted on success or failure; an application that was already stopped is
left stopped.

After restore, verify the operator login, Settings, research report downloads,
and one harmless workspace read before permitting autonomous work.

## Reset the operator token

```bash
sudo iex-code-web reset-token
```

The command prints a new token once and replaces the stored SHA-256 hash. The
plaintext is not stored and cannot be recovered later. Save the token immediately
in a password manager. Resetting the hash invalidates existing authenticated
sessions; use the incident-response guidance below after suspected compromise.

Never pass the token as a command argument and never copy it into logs, issues,
or chat.

## Configuration

Show a redacted configuration summary:

```bash
sudo iex-code-web config
```

The summary includes the resource profile, hard memory limit, soft reservation,
process limit, and file-descriptor/BEAM-port limit. To change them, rerun the
installed, inspected installer in update mode. Presets are the preferred path:

```bash
sudo iex-code-web update --resource-profile throughput
```

The Throughput profile raises the hard ceiling to 2,560 MiB while retaining the
512 MiB reservation and the existing port/process safety limits. It does not
reserve 2.5 GiB at idle. For custom limits, the reservation must not exceed the
hard limit:

```bash
sudo /opt/iex-code-web/source/install.sh --update-only \
  --memory-limit-mib 1024 \
  --memory-reservation-mib 512 \
  --nofile-limit 65536 \
  --pids-limit 1024
```

Do not lower the hard limit while work is active: Docker can terminate the app
and its agent subprocesses if their combined cgroup crosses the new boundary.
The deployment does not configure swap and does not automatically cancel work
before an out-of-memory event.

Edit root-owned configuration only when necessary:

```bash
sudoedit /etc/iex-code-web/app.env
sudo iex-code-web restart
sudo iex-code-web status
```

Do not print the environment file, upload it to support requests, source it into
an interactive shell, or commit it. Settings changed in the browser can also be
stored in SQLite and therefore require database-backup protection.

Common Phoenix/runtime values include:

| Variable | Purpose |
| --- | --- |
| `PHX_SERVER` | Starts the Phoenix endpoint in a release |
| `PHX_HOST` | Canonical public host |
| `PORT` | Internal application listener port |
| `DATABASE_PATH` | SQLite database path inside the runtime |
| `SECRET_KEY_BASE` | Signs/encrypts Phoenix cookies and other data |
| `POOL_SIZE` | SQLite connection pool size |
| `IEX_CODE_BIND` | Explicit listener address override |
| `IEX_CODE_ALLOW_REMOTE` | Enables non-loopback app access; not authentication by itself |
| `IEX_CODE_TERMINAL_IDLE_TIMEOUT_MS` | Reaps unattached, inactive terminal PTYs after this interval (default `1800000`, range 1 second–24 hours) |
| `IEX_CODE_HTTP_POOL_SIZE` | Per-origin HTTP/1 connection ceiling (default `8`, range `1..64`; restart required) |
| `IEX_CODE_HTTP_POOL_IDLE_MS` | Reaps an idle per-origin pool (default `60000`, range 1 second–1 hour; restart required) |
| `IEX_CODE_HTTP_CONNECTION_IDLE_MS` | Discards idle HTTP/1 connections (default `30000`, range 1 second–1 hour; restart required) |
| `OPENAI_API_KEY`, `OPENAI_BASE_URL` | Optional environment-backed OpenAI-compatible defaults |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` | Optional environment-backed Anthropic defaults |

Verbose command and test output is written to the protected `outputs/`
directory beside the SQLite database (host path
`/var/lib/iex-code-web/outputs`). Each producer is capped (256 MiB by default),
keeps only a bounded head/tail preview in BEAM memory, and exposes the complete
file through reads of at most 64 KiB. Reaching the cap fails explicitly with
`output_limit_exceeded`; it is not presented as successful truncated output.
The default spool quota is 2 GiB with seven-day retention; active-run artifacts
are not expired. Ensure at least 5 GiB of free filesystem space before starting
new artifacts. Manager backup and restore include both the artifact files and
their SQLite metadata so they remain consistent. The producer cap, quota, and
retention are configurable under **Settings → Resources**.

### Shared HTTP pool

Application-owned model and research requests use one supervised Finch instance
with bounded HTTP/1 pools. The default pool has one shard, eight connection
slots, a 60-second pool idle timeout, and a 30-second connection idle timeout.
SSRF-protected fetches use an opaque tag derived from the validated TLS hostname
and a pool keyed by the already pinned address; those per-destination pools are
also removed after the idle timeout. This prevents provider and research traffic
from leaving an unbounded pool per origin resident in the BEAM.

The checked-in application configuration is:

```elixir
config :iex_code, :http_pool,
  size: 8,
  pool_max_idle_time: 60_000,
  conn_max_idle_time: 30_000
```

The equivalent `IEX_CODE_HTTP_POOL_SIZE`, `IEX_CODE_HTTP_POOL_IDLE_MS`, and
`IEX_CODE_HTTP_CONNECTION_IDLE_MS` values can be set in the protected
`app.env`; they are validated at boot and require an application restart. Keep
the single shard and HTTP/1 protocol pinning unchanged; raise the pool size only
after observing real request queue pressure. The shared pool does not alter
model/research admission limits or response-size bounds.

Research provider variables include `TAVILY_API_KEY`, `BRAVE_SEARCH_API_KEY`,
`EXA_API_KEY`, `PERPLEXITY_API_KEY`, `FIRECRAWL_API_KEY`, `LINKUP_API_KEY`,
`SERPER_API_KEY`, `SERPAPI_API_KEY`, `GOOGLE_SEARCH_API_KEY`, and
`SEARXNG_BASE_URL`. Prefer browser Settings unless centrally managed environment
configuration is required. A blank browser secret field preserves the saved key.

## Uninstall

Preserve data and workspaces:

```bash
sudo iex-code-web uninstall
```

Remove the deployment **and** its managed persistent data only after verified
backups:

```bash
sudo iex-code-web uninstall --purge
```

Read the confirmation summary carefully. Removing containers is not the same as
securely erasing secrets from VPS snapshots, shell history, or external backups.
The manager does not delete unrelated repositories outside its configured paths.

## Troubleshooting

### The URL times out

```bash
sudo iex-code-web status
sudo ss -ltnp
sudo ufw status numbered
```

Check both UFW and the VPS provider's security group. Confirm the URL uses the
installed HTTPS port. Do not solve a timeout by opening all ports globally.

### Browser reports an untrusted certificate

This is expected for the direct-IP, Caddy-internal test endpoint. Verify the
address over your trusted SSH session. For ongoing access, configure a domain
and publicly trusted certificate; never disable TLS validation globally.

### Login token is rejected

The token may have been rotated or copied incorrectly. Generate a replacement:

```bash
sudo iex-code-web reset-token
```

Do not remove the database or rerun the installer merely to bypass login.

### LiveView repeatedly reconnects

Verify that the reverse proxy forwards WebSocket `Upgrade`/`Connection` headers,
uses HTTP/1.1 upstream, preserves the host and scheme, and has an idle timeout
long enough for interactive sessions.

### Provider returns 401, 403, or 404

- Re-enter the credential without surrounding whitespace.
- Confirm that the selected adapter matches the endpoint protocol.
- Include the provider's expected `/v1` path when required.
- Verify the exact model identifier and account access.
- Inspect application logs only after confirming they will not be shared.

Changing a durable run's secret-free provider/model/endpoint route after enqueue
causes it to fail closed. Create a newly reviewed run for the new route.

### Runs stay queued

At least one continuously running IexCode Web instance must own the dispatcher.
Check container health and logs. A short-lived Mix CLI can enqueue work but does
not start a private worker.

### Terminal does not start

The native PTY needs Python 3 and a POSIX container/host. Check container logs,
workspace permissions, and the configured shell. Do not make workspaces
world-writable as a shortcut.

### SQLite errors

Check disk space, inode availability, filesystem ownership, and whether the data
directory is on a filesystem with reliable SQLite locks. Stop accidental second
stacks pointing to the same database. Restore only from a consistent archive.

### Reverse proxy returns 502

Confirm the containers are healthy and the upstream address/port is reachable
from the proxy. Keep the upstream private; do not expose it publicly as a fix.

## Incident response

If a provider credential, operator token, or backup may be exposed:

1. restrict network access at the cloud firewall;
2. stop active runs and inspect durable controls;
3. rotate provider and Git credentials at their issuers;
4. run `sudo iex-code-web reset-token` and rotate other session secrets when
   appropriate;
5. review logs, Git changes, terminal history, native processes, and provider
   usage; and
6. replace affected backups or snapshots according to your retention policy.

Assume a compromised operator session has the same practical power over mounted
repositories as the application runtime.
