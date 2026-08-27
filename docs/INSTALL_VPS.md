# VPS installation

This guide installs IexCode Web as a Docker Compose deployment for one trusted
operator. Commands target a current Ubuntu or Debian VPS.

## Before you begin

Use a fresh server with:

- a non-root SSH account with `sudo` and SSH-key authentication;
- outbound HTTPS and DNS access;
- a public IPv4 address or a domain name;
- at least 2 CPU cores, 4 GB RAM, and 20 GB free disk for light use; and
- enough additional disk for repositories, Git history, reports, and backups.

The installer installs Docker Engine and the Compose plugin when absent. It does
not harden SSH or a cloud-provider firewall for you.

> [!CAUTION]
> A repository mounted under `/srv/iex-code-workspaces` is writable by agents
> and the terminal. Its commands run as the same container user as IexCode and
> can access the mounted application database, research state, and saved provider
> credentials. Never install or execute an untrusted repository. Commit valuable
> work and make independent backups first.

## One-line installation

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh | sudo bash
```

If DNS already points to a fresh VPS, install with a domain and automatic public
ACME TLS instead:

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh \
  | sudo bash -s -- --domain <YOUR_DOMAIN> --yes
```

For an auditable install, download and inspect the exact script first:

```bash
curl -fsSLo /tmp/iex-code-web-install.sh \
  https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh
less /tmp/iex-code-web-install.sh
sudo bash /tmp/iex-code-web-install.sh
rm -f /tmp/iex-code-web-install.sh
```

Do not append API keys or the login token to either command. Configure providers
after login so credentials do not enter shell history or process listings.

Advanced installer flags are available when running a downloaded script. If
you removed the inspected copy above, download and inspect it again first:

```bash
sudo bash /tmp/iex-code-web-install.sh \
  --domain <PUBLIC_DOMAIN> \
  --port <LISTEN_PORT> \
  --bind <BIND_ADDRESS> \
  --workspace-root <WORKSPACE_DIRECTORY> \
  --resource-profile balanced \
  --env-file <ENV_FILE> \
  --source-ref <GIT_REF> \
  --yes
```

Review `bash /tmp/iex-code-web-install.sh --help` before using non-default paths.
Omit `--domain` for HTTPS on `0.0.0.0:4000` with a Caddy internal
certificate. With `--domain`, the default public port is `443` and Caddy obtains
and renews a publicly trusted certificate. `--host` and `--domain` describe
alternative access modes; choose one. Replace `--domain <PUBLIC_DOMAIN>` with
`--host <PUBLIC_IPV4>` for direct-IP mode.

If an existing reverse proxy already owns ports 80/443, keep the application on
loopback and let that edge terminate TLS. Pick an unused high port:

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh \
  | sudo bash -s -- \
      --domain <PUBLIC_DOMAIN> --behind-proxy --port 49152 --yes
```

In this mode `49152` is a private HTTP upstream, not part of the public URL.
The installer binds it only to `127.0.0.1`. Configure the existing proxy for
`https://<PUBLIC_DOMAIN>` with WebSocket upgrades, the original `Host`,
`X-Forwarded-Proto: https`, and long read/send timeouts. Never publish the
upstream on `0.0.0.0`.

## Application memory guardrails

The default **Balanced** profile gives the application container a 2,048 MiB
hard memory limit, a 512 MiB soft reservation, and a 1,024-process safety
limit. It also caps both the container's open-file limit and the BEAM port table
at 65,536. The port cap prevents OTP
from sizing its port table from an excessively large host `nofile` limit, which
can otherwise consume gigabytes before any work is running.

Profiles change the hard ceiling without preallocating it: Linux lets actual
usage grow on demand and reclaim unused memory. The defaults are designed to
keep an idle application comfortably below 600 MiB while leaving room for
interactive work. The hard limit is a safety
boundary, not a guarantee that every workload will fit: large builds, many
simultaneous agents, and memory-heavy repository commands may need more RAM.

| Profile | Hard limit | Reservation | `nofile` / BEAM ports | Processes | Intended use |
| --- | ---: | ---: | ---: | ---: | --- |
| `compact` | 1,024 MiB | 512 MiB | 65,536 | 1,024 | Small VPS and light interactive use |
| `balanced` | 2,048 MiB | 512 MiB | 65,536 | 1,024 | Default general-purpose installation |
| `throughput` | 2,560 MiB | 512 MiB | 65,536 | 1,024 | Builds, swarms, and deep research on a larger VPS |
| `custom` | Explicit values | Explicit values | Explicit value | Explicit value | Operator-tuned deployment |

Select a preset during a fresh installation:

```bash
sudo bash /tmp/iex-code-web-install.sh --resource-profile throughput
```

Or change an existing managed deployment:

```bash
sudo iex-code-web update --resource-profile throughput
```

In particular, the GCP deployment is intended to run with `throughput`; verify
it afterward with `sudo iex-code-web config`. The reported values should be a
2,560 MiB hard limit, 512 MiB reservation, 1,024-process cap, and 65,536
`nofile` limit.

Do not combine a preset profile with individual limit flags. Supplying any
individual limit selects `custom`; use `--resource-profile custom` only when an
explicit label is useful. On a new installation, `custom` requires at least one
individual limit; unspecified limits retain their defaults.

| Installer option | Default | Accepted range | Persisted key |
| --- | ---: | ---: | --- |
| `--resource-profile` | `balanced` | `compact`, `balanced`, `throughput`, `custom` | `IEX_CODE_RESOURCE_PROFILE` |
| `--memory-limit-mib` | `2048` | `256..65536` | `IEX_CODE_MEMORY_LIMIT_MIB` |
| `--memory-reservation-mib` | `512` | `128..memory-limit` | `IEX_CODE_MEMORY_RESERVATION_MIB` |
| `--nofile-limit` | `65536` | `4096..1048576` | `IEX_CODE_NOFILE_LIMIT` |
| `--pids-limit` | `1024` | `128..65536` | `IEX_CODE_PIDS_LIMIT` |

Choose explicit limits during installation when necessary:

```bash
sudo bash /tmp/iex-code-web-install.sh \
  --memory-limit-mib 2048 \
  --memory-reservation-mib 768 \
  --nofile-limit 131072 \
  --pids-limit 2048
```

These values are stored in `/etc/iex-code-web/install.conf` and retained by
`sudo iex-code-web update`. An older installation receives the current defaults
on its next update unless it already has saved values. Do not put these settings
in `app.env`; the installer passes them to Compose separately.

### Memory-aware work admission

The container ceiling is complemented by an application-level governor for
expensive work. Model calls, AST scans, research fetches, DAG steps, native
commands, and build/test jobs request weighted permits. At the default 70%
pressure threshold, new heavy work waits rather than expanding concurrency. The
85% critical threshold and profile-specific safety headroom keep capacity for
already admitted work. The governor does not cancel an active job or weaken its
reasoning, fleet topology, or research level.

Interactive work has reserved capacity and is considered before background
work. Background permits rotate fairly among durable runs so a large swarm does
not monopolize admission. The thresholds can be changed live under
**Settings → Resources**; deployment ceilings, PID limits, and BEAM port limits
remain installer settings and require an update/restart.

## First login

At completion, the installer prints:

1. the installed HTTPS URL; and
2. a newly generated administrator token, printed only once.

Open the URL and enter that token. Only a SHA-256 hash of the generated token is
stored by the deployment; the plaintext cannot be recovered later. The token
authenticates the single operator and is reusable for later sign-ins until it is
reset. It is not an application API key. Save it in a password manager.

The hosted deployment is <https://iex.llmotions.com> and uses publicly trusted
TLS. A generic IP-address install uses a Caddy internal/self-signed TLS
certificate. Browsers cannot establish public trust for it, so a warning is
expected. Verify the address and certificate fingerprint from installer output
before accepting it. This is suitable only for short-lived testing on a
restricted network.

For ongoing use, point a domain at the VPS and use trusted TLS or a private
access layer. See [Domain and trusted TLS](#domain-and-trusted-tls).

## Installed layout

| Path | Ownership and contents |
| --- | --- |
| `/opt/iex-code-web/source` | Root-owned source checkout, `compose.yaml`, image metadata, and proxy configuration |
| `/etc/iex-code-web/app.env` | Root-readable runtime secrets and settings |
| `/etc/iex-code-web/install.conf` | Root-readable deployment topology and resource limits |
| `/var/lib/iex-code-web` | Persistent SQLite database, `research/` reports, and `outputs/` command/test artifacts |
| `/var/backups/iex-code-web` | Root-only manager-created backup archives |
| `/srv/iex-code-workspaces` | Host directory made available for checked-out repositories |
| `/usr/local/bin/iex-code-web` | Root operator command |

Keep `/etc/iex-code-web/app.env` mode `0600`. Do not move the database onto NFS
or a filesystem without reliable SQLite locking and durability semantics.

Verbose command and test output is file-backed below
`/var/lib/iex-code-web/outputs`. By default, each producer may write at most
256 MiB, all artifacts share a 2 GiB spool quota, and completed artifacts expire
after seven days. New artifacts require at least 5 GiB free on the state
filesystem. Active-run artifacts are not expired. Configure these bounds in
**Settings → Resources** rather than increasing them implicitly, and monitor
free space alongside memory.

## Verify the deployment

```bash
sudo iex-code-web status
sudo iex-code-web logs
sudo iex-code-web config
```

From the VPS, confirm that the HTTPS listener answers:

```bash
curl --insecure --head https://127.0.0.1:4000/
```

`--insecure` is appropriate only for this local internal-certificate check. Do
not make it the default for clients.

## Firewall and direct-IP testing

Do not expose the port to the entire Internet. Allow only the operator's stable
public address while testing:

```bash
sudo ufw allow from <TRUSTED_OPERATOR_IP>/32 to any port 4000 proto tcp
sudo ufw status numbered
```

Cloud firewalls/security groups must use the same allowlist. When direct-port
testing is finished, remove the UFW rule and the corresponding cloud rule:

```bash
sudo ufw delete allow from <TRUSTED_OPERATOR_IP>/32 to any port 4000 proto tcp
```

If SSH is protected by UFW, allow SSH from your address before enabling UFW.
Never lock yourself out of the server.

## Add a workspace

Keep repositories below the configured workspace root:

```bash
sudo mkdir -p /srv/iex-code-workspaces
sudo git clone <REPOSITORY_URL> /srv/iex-code-workspaces/<PROJECT_NAME>
```

Private repositories should use a narrowly scoped deploy key. Do not mount your
personal SSH agent or all of `$HOME` into the application. Confirm the ownership
and access model produced by `install.sh` before changing permissions.

## Configure an OpenAI-compatible provider

1. Open **Settings**.
2. Set **Default provider** to **OpenAI or compatible**.
3. Enter `https://cli.llmotions.com/v1` as the base URL (or your own
   OpenAI-compatible endpoint).
4. Enter `<YOUR_LLMOTIONS_API_KEY>` in the password field.
5. Set the model to `deepseek-v4-pro` (or another exact identifier supported by the
   provider).
6. Save and run a harmless interactive prompt.

Never put a real key in documentation, a Git remote, an issue, or a shell
command. Existing sessions retain their own provider/model selection until
changed; new durable runs snapshot a secret-free route identity. Rotating only a
credential is allowed, but changing provider, model, or endpoint can make queued
work fail closed instead of silently switching routes.

Research search providers are configured separately in Settings. Enabling a
provider does not make it ready unless its required credential and endpoint or
engine identifier are also present. Research source limits are strictly bounded
to `1..40`.

## Domain and trusted TLS

For a fresh host, create the DNS record before installation and run:

```bash
curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh \
  | sudo bash -s -- --domain <YOUR_DOMAIN> --yes
```

Caddy obtains and renews a publicly trusted ACME certificate, publishes HTTPS on
port `443`, and redirects HTTP on port `80`. Permit both `80/tcp` and `443/tcp`
at UFW and at the VPS provider so redirects and ACME validation remain reliable.
Keep the Phoenix application container private behind Caddy.

On a host that already has an edge proxy, use `--behind-proxy` as shown above.
That edge, rather than the bundled Caddy service, owns certificate issuance and
HTTP-to-HTTPS redirects.

Verify that the DNS `A` record resolves to this VPS before starting. An `AAAA`
record must also reach this deployment if present; remove stale records rather
than accepting intermittent certificate or connection failures.

LiveView requires a stable WebSocket connection. If another edge or VPN is added,
it must preserve the public host and HTTPS scheme and support WebSocket upgrades
with a sufficiently long idle timeout. Accept forwarded headers only from the
trusted edge, and do not expose both a private upstream and the public edge.

After changing topology, test token login, LiveView reconnects, research report
downloads, and a harmless terminal command before removing the old trusted-IP
rule. The built-in operator login is not tenant isolation. A VPN,
identity-aware proxy, or strict IP allowlist adds an important outer boundary.

## Next steps

- Read [Operations and recovery](OPERATIONS.md).
- Read [Security model](SECURITY.md).
- Create a first backup before mounting important repositories.
- Review execution budgets and disable tools you do not need.
