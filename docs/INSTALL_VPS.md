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
| `/var/lib/iex-code-web` | Persistent SQLite database and research outputs |
| `/var/backups/iex-code-web` | Root-only manager-created backup archives |
| `/srv/iex-code-workspaces` | Host directory made available for checked-out repositories |
| `/usr/local/bin/iex-code-web` | Root operator command |

Keep `/etc/iex-code-web/app.env` mode `0600`. Do not move the database onto NFS
or a filesystem without reliable SQLite locking and durability semantics.

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
5. Set the model to `ox-alpha` (or another exact identifier supported by the
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
