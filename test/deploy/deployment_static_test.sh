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
grep -q 'mem_limit: "${IEX_CODE_MEMORY_LIMIT_MIB:-2048}m"' compose.yaml || \
  fail "app hard memory limit missing"
grep -q 'mem_reservation: "${IEX_CODE_MEMORY_RESERVATION_MIB:-512}m"' compose.yaml || \
  fail "app memory reservation missing"
grep -q 'pids_limit: ${IEX_CODE_PIDS_LIMIT:-1024}' compose.yaml || \
  fail "app process limit missing"
grep -q 'soft: ${IEX_CODE_NOFILE_LIMIT:-65536}' compose.yaml || \
  fail "app soft nofile limit missing"
grep -q 'hard: ${IEX_CODE_NOFILE_LIMIT:-65536}' compose.yaml || \
  fail "app hard nofile limit missing"
grep -q 'ERL_AFLAGS: "+Q ${IEX_CODE_NOFILE_LIMIT:-65536}"' compose.yaml || \
  fail "BEAM port limit missing"
! grep -q 'ELIXIR_ERL_OPTIONS:' compose.yaml || fail "BEAM port limit is injected twice"
! grep -q 'memswap_limit:' compose.yaml || fail "app must not configure a swap limit"
grep -q 'restart: unless-stopped' compose.yaml || fail "restart policy changed"
grep -q 'stop_grace_period: 60s' compose.yaml || fail "stop grace period changed"
grep -q 'IEX_CODE_MEMORY_LIMIT_MIB=%q' install.sh || \
  fail "memory limit is not persisted"
grep -q 'IEX_CODE_MEMORY_RESERVATION_MIB=%q' install.sh || \
  fail "memory reservation is not persisted"
grep -q 'IEX_CODE_NOFILE_LIMIT=%q' install.sh || fail "nofile limit is not persisted"
grep -q 'IEX_CODE_RESOURCE_PROFILE=%q' install.sh || fail "resource profile is not persisted"
grep -q 'IEX_CODE_PIDS_LIMIT=%q' install.sh || fail "process limit is not persisted"
grep -q 'IEX_CODE_MEMORY_LIMIT_MIB=${IEX_CODE_MEMORY_LIMIT_MIB:-2048}' \
  deploy/iex-code-web || fail "manager legacy memory limit default missing"
grep -q 'IEX_CODE_MEMORY_RESERVATION_MIB=${IEX_CODE_MEMORY_RESERVATION_MIB:-512}' \
  deploy/iex-code-web || fail "manager legacy memory reservation default missing"
grep -q 'IEX_CODE_NOFILE_LIMIT=${IEX_CODE_NOFILE_LIMIT:-65536}' deploy/iex-code-web || \
  fail "manager legacy nofile default missing"
grep -q 'IEX_CODE_PIDS_LIMIT=${IEX_CODE_PIDS_LIMIT:-1024}' deploy/iex-code-web || \
  fail "manager legacy process limit default missing"
grep -q 'update) exec "$IEX_CODE_SOURCE_DIR/install.sh" --update-only "$@"' \
  deploy/iex-code-web || fail "manager update does not forward profile options"

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
grep -q -- '--resource-profile' "$help_file" || fail "resource profile option not documented"
grep -q -- '--pids-limit' "$help_file" || fail "process limit option not documented"
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
  --nofile-limit 1048576 --pids-limit 65536
valid_install_args --resource-profile compact
valid_install_args --resource-profile balanced
valid_install_args --resource-profile throughput
valid_install_args --resource-profile custom --memory-limit-mib 2048
invalid_install_args --resource-profile tiny
invalid_install_args --resource-profile custom
invalid_install_args --resource-profile balanced --memory-limit-mib 2048
invalid_install_args --memory-limit-mib 255 --memory-reservation-mib 128
invalid_install_args --memory-limit-mib 65537
invalid_install_args --memory-reservation-mib 127
invalid_install_args --memory-limit-mib 512 --memory-reservation-mib 513
invalid_install_args --nofile-limit 4095
invalid_install_args --nofile-limit 1048577
invalid_install_args --pids-limit 127
invalid_install_args --pids-limit 65537
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
assert_invalid_message \
  'ERROR: --pids-limit must be an integer between 128 and 65536' \
  --pids-limit 127
assert_invalid_message \
  'ERROR: --resource-profile must be compact, balanced, throughput, or custom' \
  --resource-profile tiny
assert_invalid_message \
  'ERROR: preset --resource-profile cannot be combined with custom resource limits' \
  --resource-profile throughput --pids-limit 2048
assert_invalid_message \
  'ERROR: --resource-profile custom requires at least one explicit resource limit' \
  --resource-profile custom

profile_values() {
  /bin/bash -c '
    source ./install.sh
    parse_args --resource-profile "$1"
    resolve_resource_config
    validate_args
    printf "%s|%s|%s|%s|%s\n" "$RESOURCE_PROFILE" "$MEMORY_LIMIT_MIB" \
      "$MEMORY_RESERVATION_MIB" "$NOFILE_LIMIT" "$PIDS_LIMIT"
  ' _ "$1"
}

[[ $(profile_values compact) == 'compact|1024|512|65536|1024' ]] || \
  fail "compact profile values differ"
[[ $(profile_values balanced) == 'balanced|2048|512|65536|1024' ]] || \
  fail "balanced profile values differ"
[[ $(profile_values throughput) == 'throughput|2560|512|65536|1024' ]] || \
  fail "throughput profile values differ"

drifted_profile=$(
  /bin/bash -c '
    source ./install.sh
    EXISTING_CONFIG=true
    IEX_CODE_RESOURCE_PROFILE=throughput
    IEX_CODE_MEMORY_LIMIT_MIB=2048
    IEX_CODE_MEMORY_RESERVATION_MIB=512
    IEX_CODE_NOFILE_LIMIT=65536
    IEX_CODE_PIDS_LIMIT=1024
    resolve_resource_config
    validate_args
    printf "%s|%s\n" "$RESOURCE_PROFILE" "$MEMORY_LIMIT_MIB"
  '
)
[[ $drifted_profile == 'custom|2048' ]] || fail "drifted preset was not classified custom"

restored_resources=$(
  /bin/bash -c '
    source ./install.sh
    IEX_CODE_MEMORY_LIMIT_MIB=2048
    IEX_CODE_MEMORY_RESERVATION_MIB=768
    IEX_CODE_NOFILE_LIMIT=131072
    IEX_CODE_PIDS_LIMIT=2048
    restore_resource_config
    printf "%s|%s|%s|%s\n" "$MEMORY_LIMIT_MIB" "$MEMORY_RESERVATION_MIB" "$NOFILE_LIMIT" "$PIDS_LIMIT"
  '
)
[[ $restored_resources == '2048|768|131072|2048' ]] || \
  fail "persisted resource values were not restored"

overridden_resources=$(
  /bin/bash -c '
    source ./install.sh
    IEX_CODE_MEMORY_LIMIT_MIB=2048
    IEX_CODE_MEMORY_RESERVATION_MIB=768
    IEX_CODE_NOFILE_LIMIT=131072
    IEX_CODE_PIDS_LIMIT=2048
    parse_args --memory-limit-mib 3072
    restore_resource_config
    printf "%s|%s|%s|%s\n" "$MEMORY_LIMIT_MIB" "$MEMORY_RESERVATION_MIB" "$NOFILE_LIMIT" "$PIDS_LIMIT"
  '
)
[[ $overridden_resources == '3072|768|131072|2048' ]] || \
  fail "explicit resource override did not preserve unrelated persisted values"

printf 'deployment static test: ok\n'
