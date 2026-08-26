#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

fail() { printf 'deployment static test: %s\n' "$*" >&2; exit 1; }

bash -n install.sh deploy/iex-code-web
sh -n deploy/entrypoint.sh deploy/healthcheck.sh

grep -q 'IEX_CODE_ADMIN_TOKEN_SHA256' install.sh || fail "admin digest is not configured"
! grep -q '/var/run/docker.sock' compose.yaml || fail "Docker socket must never be mounted"
grep -q '127.0.0.1:${IEX_CODE_PUBLIC_PORT' deploy/compose.behind-proxy.yaml || \
  fail "behind-proxy upstream is not loopback-only"
grep -q 'profiles: \["caddy"\]' compose.yaml || fail "Caddy must be optional in proxy mode"
grep -q 'IEX_CODE_BOOTSTRAP_SETTINGS_FILE' install.sh || fail "bootstrap secret file missing"
grep -q 'rm -f -- "$CONFIG_DIR/admin.token"' install.sh || \
  fail "legacy plaintext token cleanup missing"

if grep -R -E 'sk-[A-Za-z0-9_-]{12,}' \
    Dockerfile compose.yaml install.sh deploy test/deploy >/dev/null; then
  fail "possible API key committed in deployment files"
fi

help_file=$(mktemp)
/bin/bash install.sh --help >"$help_file"
grep -q -- '--behind-proxy' "$help_file" || fail "behind proxy option not documented"
grep -q -- '--domain' "$help_file" || fail "domain option not documented"
rm -f -- "$help_file"

printf 'deployment static test: ok\n'
