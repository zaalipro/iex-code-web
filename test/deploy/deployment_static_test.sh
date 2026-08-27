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
grep -q 'mem_limit: "${IEX_CODE_MEMORY_LIMIT_MIB:-1024}m"' compose.yaml || \
  fail "app hard memory limit missing"
grep -q 'mem_reservation: "${IEX_CODE_MEMORY_RESERVATION_MIB:-512}m"' compose.yaml || \
  fail "app memory reservation missing"
grep -q 'soft: ${IEX_CODE_NOFILE_LIMIT:-65536}' compose.yaml || \
  fail "app soft nofile limit missing"
grep -q 'hard: ${IEX_CODE_NOFILE_LIMIT:-65536}' compose.yaml || \
  fail "app hard nofile limit missing"
grep -q 'ERL_AFLAGS: "+Q ${IEX_CODE_NOFILE_LIMIT:-65536}"' compose.yaml || \
  fail "direct Erlang BEAM port limit missing"
grep -q 'ELIXIR_ERL_OPTIONS: "+Q ${IEX_CODE_NOFILE_LIMIT:-65536}"' compose.yaml || \
  fail "BEAM port limit missing"
! grep -q 'memswap_limit:' compose.yaml || fail "app must not configure a swap limit"
grep -q 'restart: unless-stopped' compose.yaml || fail "restart policy changed"
grep -q 'stop_grace_period: 60s' compose.yaml || fail "stop grace period changed"
grep -q 'IEX_CODE_MEMORY_LIMIT_MIB=%q' install.sh || \
  fail "memory limit is not persisted"
grep -q 'IEX_CODE_MEMORY_RESERVATION_MIB=%q' install.sh || \
  fail "memory reservation is not persisted"
grep -q 'IEX_CODE_NOFILE_LIMIT=%q' install.sh || fail "nofile limit is not persisted"
grep -q 'IEX_CODE_MEMORY_LIMIT_MIB=${IEX_CODE_MEMORY_LIMIT_MIB:-1024}' \
  deploy/iex-code-web || fail "manager legacy memory limit default missing"
grep -q 'IEX_CODE_MEMORY_RESERVATION_MIB=${IEX_CODE_MEMORY_RESERVATION_MIB:-512}' \
  deploy/iex-code-web || fail "manager legacy memory reservation default missing"
grep -q 'IEX_CODE_NOFILE_LIMIT=${IEX_CODE_NOFILE_LIMIT:-65536}' deploy/iex-code-web || \
  fail "manager legacy nofile default missing"

if grep -R -E 'sk-[A-Za-z0-9_-]{12,}' \
    Dockerfile compose.yaml install.sh deploy test/deploy >/dev/null; then
  fail "possible API key committed in deployment files"
fi

help_file=$(mktemp)
/bin/bash install.sh --help >"$help_file"
grep -q -- '--behind-proxy' "$help_file" || fail "behind proxy option not documented"
grep -q -- '--domain' "$help_file" || fail "domain option not documented"
grep -q -- '--memory-limit-mib' "$help_file" || fail "memory limit option not documented"
grep -q -- '--memory-reservation-mib' "$help_file" || \
  fail "memory reservation option not documented"
grep -q -- '--nofile-limit' "$help_file" || fail "nofile limit option not documented"
rm -f -- "$help_file"

valid_install_args() {
  /bin/bash -c 'source ./install.sh; parse_args "$@"; validate_args' _ "$@"
}

invalid_install_args() {
  if valid_install_args "$@" >/dev/null 2>&1; then
    fail "installer unexpectedly accepted invalid arguments: $*"
  fi
}

assert_invalid_message() {
  local expected=$1
  shift
  local output status=0
  output=$(valid_install_args "$@" 2>&1) || status=$?
  [[ $status -eq 1 ]] || fail "invalid installer arguments returned status $status: $*"
  [[ $output == "$expected" ]] || \
    fail "invalid installer error differed for $*: $output"
}

valid_install_args --memory-limit-mib 256 --memory-reservation-mib 128 --nofile-limit 4096
valid_install_args --memory-limit-mib 65536 --memory-reservation-mib 65536 \
  --nofile-limit 1048576
invalid_install_args --memory-limit-mib 255 --memory-reservation-mib 128
invalid_install_args --memory-limit-mib 65537
invalid_install_args --memory-reservation-mib 127
invalid_install_args --memory-limit-mib 512 --memory-reservation-mib 513
invalid_install_args --nofile-limit 4095
invalid_install_args --nofile-limit 1048577
invalid_install_args --memory-limit-mib 1GiB
invalid_install_args --memory-limit-mib +1024
invalid_install_args --memory-limit-mib -1
invalid_install_args --memory-limit-mib 1.5
invalid_install_args --memory-limit-mib ' 1024'
invalid_install_args --memory-limit-mib ''
invalid_install_args --memory-limit-mib ١٠٢٤
invalid_install_args --memory-limit-mib 00000001024

assert_invalid_message \
  'ERROR: --memory-limit-mib requires a value' \
  --memory-limit-mib
assert_invalid_message \
  'ERROR: --memory-limit-mib must be an integer between 256 and 65536' \
  --memory-limit-mib invalid
assert_invalid_message \
  'ERROR: --memory-reservation-mib must be an integer between 128 and --memory-limit-mib' \
  --memory-limit-mib 512 --memory-reservation-mib 513
assert_invalid_message \
  'ERROR: --nofile-limit must be an integer between 4096 and 1048576' \
  --nofile-limit 4095

restored_resources=$(
  /bin/bash -c '
    source ./install.sh
    IEX_CODE_MEMORY_LIMIT_MIB=2048
    IEX_CODE_MEMORY_RESERVATION_MIB=768
    IEX_CODE_NOFILE_LIMIT=131072
    restore_resource_config
    printf "%s|%s|%s\n" "$MEMORY_LIMIT_MIB" "$MEMORY_RESERVATION_MIB" "$NOFILE_LIMIT"
  '
)
[[ $restored_resources == '2048|768|131072' ]] || \
  fail "persisted resource values were not restored"

overridden_resources=$(
  /bin/bash -c '
    source ./install.sh
    IEX_CODE_MEMORY_LIMIT_MIB=2048
    IEX_CODE_MEMORY_RESERVATION_MIB=768
    IEX_CODE_NOFILE_LIMIT=131072
    parse_args --memory-limit-mib 3072
    restore_resource_config
    printf "%s|%s|%s\n" "$MEMORY_LIMIT_MIB" "$MEMORY_RESERVATION_MIB" "$NOFILE_LIMIT"
  '
)
[[ $overridden_resources == '3072|768|131072' ]] || \
  fail "explicit resource override did not preserve unrelated persisted values"

printf 'deployment static test: ok\n'
