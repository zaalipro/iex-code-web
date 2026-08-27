#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/deploy/iex-code-web"

# The status path is tested without root or Docker. These replace only the
# setup functions after sourcing the production manager; `compose` is replaced
# per scenario below so its arguments and output remain deterministic.
require_root() { :; }
load_config() { :; }
detect_compose() { :; }

fail() {
  printf 'status command test: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ $actual == "$expected" ]] || \
    fail "$message (expected $(printf %q "$expected"), got $(printf %q "$actual"))"
}

warning='iex-code-web: warning: runtime status unavailable; service status is shown above'

test_stopped_app_only_prints_compose_status() (
  calls=$(mktemp)
  trap 'rm -f -- "$calls"' EXIT

  compose() {
    printf '%s\n' "$*" >>"$calls"
    case "$*" in
      ps) printf 'NAME STATUS\napp exited\n' ;;
      'ps -q app') return 0 ;;
      *) fail "unexpected compose call: $*" ;;
    esac
  }

  output=$(main status 2>&1)
  assert_eq $'NAME STATUS\napp exited' "$output" "stopped status output differs"
  assert_eq $'ps\nps -q app' "$(cat "$calls")" "stopped status calls differ"
)

test_running_app_prints_runtime_status_after_compose_status() (
  calls=$(mktemp)
  trap 'rm -f -- "$calls"' EXIT

  compose() {
    printf '%s\n' "$*" >>"$calls"
    case "$*" in
      ps) printf 'NAME STATUS\napp running\n' ;;
      'ps -q app') printf 'opaque-container-id\n' ;;
      'exec -T app /opt/iex-code/bin/iex_code rpc IexCode.Observability.RuntimeStatus.print_cli()')
        printf 'Runtime: idle\nMemory: 120 MiB / 1 GiB\n'
        ;;
      *) fail "unexpected compose call: $*" ;;
    esac
  }

  output=$(main status 2>&1)
  assert_eq $'NAME STATUS\napp running\nRuntime: idle\nMemory: 120 MiB / 1 GiB' \
    "$output" "running status output differs"
  assert_eq $'ps\nps -q app\nexec -T app /opt/iex-code/bin/iex_code rpc IexCode.Observability.RuntimeStatus.print_cli()' \
    "$(cat "$calls")" "running status calls differ"
  [[ $output != *opaque-container-id* ]] || fail "status exposed a container ID"
)

test_rpc_failure_warns_but_succeeds() (
  calls=$(mktemp)
  stdout=$(mktemp)
  stderr=$(mktemp)
  trap 'rm -f -- "$calls" "$stdout" "$stderr"' EXIT

  compose() {
    printf '%s\n' "$*" >>"$calls"
    case "$*" in
      ps) printf 'NAME STATUS\napp running\n' ;;
      'ps -q app') printf 'opaque-container-id\n' ;;
      'exec -T app /opt/iex-code/bin/iex_code rpc IexCode.Observability.RuntimeStatus.print_cli()')
        printf 'remote failure for secret-node-id\n' >&2
        return 17
        ;;
      *) fail "unexpected compose call: $*" ;;
    esac
  }

  main status >"$stdout" 2>"$stderr" || fail "RPC failure changed successful status exit"
  assert_eq $'NAME STATUS\napp running' "$(cat "$stdout")" "RPC failure stdout differs"
  assert_eq "$warning" "$(cat "$stderr")" "RPC failure warning differs"
)

test_compose_failure_is_preserved() (
  compose() {
    [[ $* == ps ]] || fail "unexpected compose call after failed ps: $*"
    return 23
  }

  local status=0
  main status >/dev/null 2>&1 || status=$?
  assert_eq 23 "$status" "compose ps failure was not preserved"
)

test_stopped_app_only_prints_compose_status
test_running_app_prints_runtime_status_after_compose_status
test_rpc_failure_warns_but_succeeds
test_compose_failure_is_preserved

printf 'status command test: ok\n'
