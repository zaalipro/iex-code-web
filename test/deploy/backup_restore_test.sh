#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/deploy/iex-code-web"

fail() {
  printf 'backup/restore test: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ $actual == "$expected" ]] || \
    fail "$message (expected $(printf %q "$expected"), got $(printf %q "$actual"))"
}

write_tree() {
  local root=$1 marker=$2
  mkdir -p "$root/research/report dir" "$root/outputs/run dir"
  printf 'db-%s\n' "$marker" >"$root/iex_code.db"
  printf 'research-%s\n' "$marker" >"$root/research/report dir/report file.html"
  printf 'output-%s\n' "$marker" >"$root/outputs/run dir/output file.log"
}

install_test_context() {
  local root=$1 calls=$2
  IEX_CODE_STATE_DIR="$root/state dir"
  IEX_CODE_BACKUP_DIR="$root/backup dir"
  IEX_CODE_APP_UID=$(id -u)
  IEX_CODE_APP_GID=$(id -g)
  mkdir -p "$IEX_CODE_STATE_DIR" "$IEX_CODE_BACKUP_DIR"
  TEST_CALLS=$calls
  TEST_RUNNING=false
  TEST_FAIL_SQLITE=false
  TEST_FAIL_START=false

  compose() {
    printf '%s\n' "$*" >>"$TEST_CALLS"
    case "$*" in
      'ps -q app')
        [[ $TEST_RUNNING == true ]] && printf 'container-id\n'
        ;;
      'stop app') TEST_RUNNING=false ;;
      'start app')
        [[ $TEST_FAIL_START == false ]] || return 41
        TEST_RUNNING=true
        ;;
      'run --rm --no-deps app sqlite3 '*'.backup '*)
        [[ $TEST_FAIL_SQLITE == false ]] || return 42
        # The manager chooses a host staging directory under the state bind.
        local staging
        staging=$(find "$IEX_CODE_STATE_DIR" -maxdepth 1 -type d \
          -name '.backup-*' -print -quit)
        cp -- "$IEX_CODE_STATE_DIR/iex_code.db" "$staging/iex_code.db"
        ;;
      *) fail "unexpected compose call: $*" ;;
    esac
  }
}

test_backup_captures_all_state_and_restarts_running_app() (
  local root calls archive listing
  root=$(mktemp -d)
  calls="$root/calls"
  : >"$calls"
  install_test_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" original
  ln "$IEX_CODE_STATE_DIR/research/report dir/report file.html" \
    "$IEX_CODE_STATE_DIR/research/report dir/hardlinked report.html"
  TEST_RUNNING=true

  archive=$(backup "$root/destination with spaces/archive with spaces.tar.gz")
  [[ -f "$archive" && -f "$archive.sha256" ]] || fail "backup files are missing"
  listing=$(tar -tzf "$archive" | LC_ALL=C sort)
  assert_eq $'iex_code.db\noutputs/\noutputs/run dir/\noutputs/run dir/output file.log\nresearch/\nresearch/report dir/\nresearch/report dir/hardlinked report.html\nresearch/report dir/report file.html' \
    "$listing" "backup members differ"
  python3 - "$archive" <<'PY' || fail "backup retained an unsafe link member"
import sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as bundle:
    assert all(member.isfile() or member.isdir() for member in bundle.getmembers())
PY
  assert_eq 'ps -q app' "$(head -n1 "$calls")" "backup did not inspect app state first"
  assert_eq 'stop app' "$(sed -n '2p' "$calls")" "backup did not stop the writer"
  grep -Eq '^run --rm --no-deps app sqlite3 /var/lib/iex-code/iex_code.db \.backup .*/iex_code\.db' \
    "$calls" || fail "backup did not create its SQLite snapshot through the app image"
  [[ $(tail -n1 "$calls") == 'start app' ]] || fail "running app was not restarted"
  [[ $TEST_RUNNING == true ]] || fail "running state was not restored"
)

test_backup_failure_restarts_running_app_and_preserves_exit() (
  local root calls status_file
  root=$(mktemp -d)
  calls="$root/calls"
  status_file="$root/status"
  : >"$calls"
  install_test_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" original
  TEST_RUNNING=true
  TEST_FAIL_SQLITE=true

  set +e
  (set -e; backup "$root/failed.tar.gz" >/dev/null 2>&1) &
  local backup_pid=$!
  wait "$backup_pid"
  printf '%s\n' "$?" >"$status_file"
  set -e
  assert_eq 42 "$(cat "$status_file")" "backup failure exit status differs"
  [[ $(tail -n1 "$calls") == 'start app' ]] || fail "failed backup did not restart app"
  [[ $TEST_RUNNING == true ]] || fail "failed backup changed running state"
)

test_backup_failure_reports_restart_failure() (
  local root calls status_file stderr
  root=$(mktemp -d)
  calls="$root/calls"
  status_file="$root/status"
  stderr="$root/stderr"
  : >"$calls"
  install_test_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" original
  TEST_RUNNING=true
  TEST_FAIL_SQLITE=true
  TEST_FAIL_START=true

  set +e
  (set -e; backup "$root/failed.tar.gz") > /dev/null 2>"$stderr" &
  local backup_pid=$!
  wait "$backup_pid"
  printf '%s\n' "$?" >"$status_file"
  set -e
  assert_eq 42 "$(cat "$status_file")" "restart failure masked the backup failure"
  grep -q 'failed to restart the application after backup' "$stderr" || \
    fail "backup restart failure was hidden"
)

test_stopped_backup_never_starts_app() (
  local root calls
  root=$(mktemp -d)
  calls="$root/calls"
  : >"$calls"
  install_test_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" original

  backup "$root/stopped.tar.gz" >/dev/null
  ! grep -Eq '^(stop|start) app$' "$calls" || fail "stopped backup changed app state"
  [[ $TEST_RUNNING == false ]] || fail "stopped app became running"
)

make_archive() {
  local archive=$1 marker=$2
  local content
  content=$(mktemp -d)
  write_tree "$content" "$marker"
  COPYFILE_DISABLE=1 tar -czf "$archive" -C "$content" iex_code.db research outputs
}

install_restore_context() {
  local root=$1 calls=$2
  install_test_context "$root" "$calls"
  backup() { printf '%s\n' safety-backup >>"$TEST_CALLS"; }
}

test_nested_backup_preserves_restore_exit_trap() (
  local root calls outer_staging marker
  root=$(mktemp -d)
  calls="$root/calls"
  outer_staging="$root/outer staging"
  marker="$root/outer trap ran"
  : >"$calls"
  mkdir -p "$outer_staging"
  install_test_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" original
  TEST_RUNNING=false
  restore() (
    finish_restore() {
      printf 'yes\n' >"$marker"
      trap - EXIT
    }
    trap finish_restore EXIT
    backup "$root/nested.tar.gz" >/dev/null
    return 17
  )

  restore >/dev/null 2>&1 || true
  [[ -f "$marker" ]] || fail "nested safety backup replaced restore's EXIT trap"
)

test_restore_replaces_all_state_and_preserves_stopped_app() (
  local root calls archive
  root=$(mktemp -d)
  calls="$root/calls"
  archive="$root/archive with spaces.tar.gz"
  : >"$calls"
  install_restore_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" old
  make_archive "$archive" restored

  restore "$archive" >/dev/null
  grep -q '^db-restored$' "$IEX_CODE_STATE_DIR/iex_code.db" || fail "database was not restored"
  grep -q '^research-restored$' "$IEX_CODE_STATE_DIR/research/report dir/report file.html" || \
    fail "research was not restored"
  grep -q '^output-restored$' "$IEX_CODE_STATE_DIR/outputs/run dir/output file.log" || \
    fail "output artifact was not restored"
  ! grep -Eq '^(stop|start) app$' "$calls" || fail "stopped restore changed app state"
  [[ $TEST_RUNNING == false ]] || fail "stopped restore started app"
)

test_restore_restarts_originally_running_app() (
  local root calls archive
  root=$(mktemp -d)
  calls="$root/calls"
  archive="$root/restore.tar.gz"
  : >"$calls"
  install_restore_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" old
  make_archive "$archive" restored
  TEST_RUNNING=true

  restore "$archive" >/dev/null
  [[ $(tail -n1 "$calls") == 'start app' ]] || fail "restore did not restart running app"
  [[ $TEST_RUNNING == true ]] || fail "restore did not preserve running state"
)

test_failed_restore_rolls_back_and_restarts_running_app() (
  local root calls archive stderr status_file
  root=$(mktemp -d)
  calls="$root/calls"
  archive="$root/restore.tar.gz"
  stderr="$root/stderr"
  status_file="$root/status"
  : >"$calls"
  install_restore_context "$root" "$calls"
  write_tree "$IEX_CODE_STATE_DIR" old
  make_archive "$archive" restored
  TEST_RUNNING=true
  local real_mv
  real_mv=$(command -v mv)
  mv() {
    if [[ ${1:-} == -- && ${2:-} == */incoming/research ]]; then
      return 44
    fi
    "$real_mv" "$@"
  }

  set +e
  (set -e; restore "$archive") > /dev/null 2>"$stderr" &
  local restore_pid=$!
  wait "$restore_pid"
  printf '%s\n' "$?" >"$status_file"
  set -e

  assert_eq 44 "$(cat "$status_file")" "restore replacement failure was hidden"
  grep -q '^db-old$' "$IEX_CODE_STATE_DIR/iex_code.db" || fail "failed restore lost database"
  grep -q '^research-old$' "$IEX_CODE_STATE_DIR/research/report dir/report file.html" || \
    fail "failed restore lost research"
  grep -q '^output-old$' "$IEX_CODE_STATE_DIR/outputs/run dir/output file.log" || \
    fail "failed restore lost output artifact"
  [[ $(tail -n1 "$calls") == 'start app' ]] || fail "failed restore did not restart app"
)

assert_unsafe_archive() (
  local kind=$1
  local root archive status_file
  root=$(mktemp -d)
  archive="$root/unsafe.tar.gz"
  status_file="$root/status"

  python3 - "$archive" "$kind" <<'PY'
import io, sys, tarfile

archive, kind = sys.argv[1:]
with tarfile.open(archive, "w:gz") as bundle:
    if kind == "traversal":
        info = tarfile.TarInfo("outputs/../../escape")
        body = b"escape"
    elif kind == "absolute":
        info = tarfile.TarInfo("/outputs/escape")
        body = b"escape"
    elif kind == "symlink":
        info = tarfile.TarInfo("outputs/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        body = b""
    elif kind == "hardlink_escape":
        info = tarfile.TarInfo("outputs/link")
        info.type = tarfile.LNKTYPE
        info.linkname = "/etc/passwd"
        body = b""
    elif kind == "duplicate":
        for body in (b"first", b"second"):
            info = tarfile.TarInfo("outputs/duplicate")
            info.size = len(body)
            bundle.addfile(info, io.BytesIO(body))
        raise SystemExit(0)
    elif kind == "file_parent":
        info = tarfile.TarInfo("outputs")
        body = b"file"
        info.size = len(body)
        bundle.addfile(info, io.BytesIO(body))
        info = tarfile.TarInfo("outputs/child")
        body = b"child"
    else:
        raise SystemExit("unknown fixture")
    info.size = len(body)
    bundle.addfile(info, io.BytesIO(body))
PY

  mkdir "$root/extracted"
  if extract_archive "$archive" "$root/extracted/incoming" >/dev/null 2>&1; then
    printf '0\n' >"$status_file"
  else
    printf '%s\n' "$?" >"$status_file"
  fi
  assert_eq 1 "$(cat "$status_file")" "unsafe $kind archive was accepted"
  [[ ! -e "$root/escape" ]] || fail "unsafe $kind archive escaped extraction root"
)

test_backup_captures_all_state_and_restarts_running_app
test_backup_failure_restarts_running_app_and_preserves_exit
test_backup_failure_reports_restart_failure
test_stopped_backup_never_starts_app
test_nested_backup_preserves_restore_exit_trap
test_restore_replaces_all_state_and_preserves_stopped_app
test_restore_restarts_originally_running_app
test_failed_restore_rolls_back_and_restarts_running_app
assert_unsafe_archive traversal
assert_unsafe_archive absolute
assert_unsafe_archive symlink
assert_unsafe_archive hardlink_escape
assert_unsafe_archive duplicate
assert_unsafe_archive file_parent

printf 'backup/restore test: ok\n'
