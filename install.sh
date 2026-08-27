#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly DEFAULT_REPO=https://github.com/zaalipro/iex-code-web.git
readonly INSTALL_ROOT=/opt/iex-code-web
readonly SOURCE_DIR=$INSTALL_ROOT/source
readonly CONFIG_DIR=/etc/iex-code-web
readonly APP_ENV_FILE=$CONFIG_DIR/app.env
readonly INSTALL_CONFIG=$CONFIG_DIR/install.conf
readonly STATE_DIR=/var/lib/iex-code-web
WORKSPACE_DIR=/srv/iex-code-workspaces
RESOURCE_PROFILE=balanced
MEMORY_LIMIT_MIB=2048
MEMORY_RESERVATION_MIB=512
NOFILE_LIMIT=65536
PIDS_LIMIT=1024
readonly BACKUP_DIR=/var/backups/iex-code-web
readonly APP_UID=10001
readonly APP_GID=10001
readonly LOCK_FILE=/run/lock/iex-code-web-install.lock

REPO=$DEFAULT_REPO
REF=main
PUBLIC_IP=
PUBLIC_DOMAIN=
PUBLIC_HOST=
PUBLIC_BIND=0.0.0.0
PUBLIC_PORT=4000
MODEL_ENV_FILE=
WORKSPACE_ROOT_OVERRIDE=
UPDATE_ONLY=false
ROTATE_TOKEN=false
BEHIND_PROXY=false
COMPOSE=()
NEW_TOKEN=
HOST_SET=false
DOMAIN_SET=false
BIND_SET=false
PORT_SET=false
REPO_SET=false
REF_SET=false
WORKSPACE_SET=false
RESOURCE_PROFILE_SET=false
MEMORY_LIMIT_SET=false
MEMORY_RESERVATION_SET=false
NOFILE_SET=false
PIDS_SET=false
EXISTING_CONFIG=false

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install IexCode Web on a Docker-capable Linux VPS.

Usage:
  curl -fsSL https://raw.githubusercontent.com/zaalipro/iex-code-web/main/install.sh \
    | sudo bash -s -- [OPTIONS]

Options:
  --host IP             Public IPv4 address to bind/advertise (auto-detected)
  --domain DOMAIN       Use a domain and public ACME TLS instead of IP/internal TLS
  --behind-proxy        Bind app to 127.0.0.1:PORT; an existing proxy owns TLS
  --port PORT           Public HTTPS port (default: 4000)
  --bind IP             Address on which Docker publishes the port (default: 0.0.0.0)
  --workspace-root DIR  Host directory mounted as /workspaces
  --resource-profile P  Resource preset: compact, balanced, throughput, or custom
                        (default: balanced)
  --memory-limit-mib N  App hard memory limit in MiB (default: 2048; 256..65536)
  --memory-reservation-mib N
                        App soft memory reservation in MiB (default: 512; 128..limit)
  --nofile-limit N      App file descriptor and BEAM port limit (default: 65536)
  --pids-limit N        App container process limit (default: 1024; 128..65536)
  --env-file FILE       Import allowlisted model/search settings once via protected JSON
  --repo URL            Git repository (default: official repository)
  --source-ref REF      Git branch/tag/commit (default: main)
  --yes                 Accept noninteractive installation defaults
  --rotate-token        Generate a new app admin token
  --update-only         Preserve configuration and perform backup/update/rebuild
  -h, --help            Show this help

The env file is for noninteractive provider configuration. Example keys:
OPENAI_API_KEY, OPENAI_BASE_URL, IEX_CODE_DEFAULT_MODEL_PROVIDER,
IEX_CODE_DEFAULT_MODEL, and TAVILY_API_KEY. Never put secrets on the command line.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --host) (($# >= 2)) || die "--host requires a value"; PUBLIC_IP=$2; HOST_SET=true; shift 2 ;;
      --domain) (($# >= 2)) || die "--domain requires a value"; PUBLIC_DOMAIN=$2; DOMAIN_SET=true; shift 2 ;;
      --behind-proxy) BEHIND_PROXY=true; shift ;;
      --bind) (($# >= 2)) || die "--bind requires a value"; PUBLIC_BIND=$2; BIND_SET=true; shift 2 ;;
      --port) (($# >= 2)) || die "--port requires a value"; PUBLIC_PORT=$2; PORT_SET=true; shift 2 ;;
      --workspace-root) (($# >= 2)) || die "--workspace-root requires a value"; WORKSPACE_ROOT_OVERRIDE=$2; WORKSPACE_SET=true; shift 2 ;;
      --resource-profile) (($# >= 2)) || die "--resource-profile requires a value"; RESOURCE_PROFILE=$2; RESOURCE_PROFILE_SET=true; shift 2 ;;
      --memory-limit-mib) (($# >= 2)) || die "--memory-limit-mib requires a value"; MEMORY_LIMIT_MIB=$2; MEMORY_LIMIT_SET=true; shift 2 ;;
      --memory-reservation-mib) (($# >= 2)) || die "--memory-reservation-mib requires a value"; MEMORY_RESERVATION_MIB=$2; MEMORY_RESERVATION_SET=true; shift 2 ;;
      --nofile-limit) (($# >= 2)) || die "--nofile-limit requires a value"; NOFILE_LIMIT=$2; NOFILE_SET=true; shift 2 ;;
      --pids-limit) (($# >= 2)) || die "--pids-limit requires a value"; PIDS_LIMIT=$2; PIDS_SET=true; shift 2 ;;
      --env-file) (($# >= 2)) || die "--env-file requires a value"; MODEL_ENV_FILE=$2; shift 2 ;;
      --repo) (($# >= 2)) || die "--repo requires a value"; REPO=$2; REPO_SET=true; shift 2 ;;
      --ref|--source-ref) (($# >= 2)) || die "$1 requires a value"; REF=$2; REF_SET=true; shift 2 ;;
      --yes) shift ;;
      --rotate-token) ROTATE_TOKEN=true; shift ;;
      --update-only) UPDATE_ONLY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_args() {
  [[ $PUBLIC_PORT =~ ^[0-9]+$ ]] || die "port must be numeric"
  ((PUBLIC_PORT >= 1 && PUBLIC_PORT <= 65535)) || die "port must be between 1 and 65535"
  [[ -z "$PUBLIC_IP" ]] || valid_ipv4 "$PUBLIC_IP" || die "--host must be a valid IPv4 address"
  [[ -z "$PUBLIC_DOMAIN" || $PUBLIC_DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
    die "--domain is invalid"
  valid_ipv4 "$PUBLIC_BIND" || die "--bind must be a valid IPv4 address"
  [[ $REF =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid Git ref"
  [[ $REF != -* ]] || die "Git ref must not begin with a dash"
  [[ $REPO =~ ^https://[A-Za-z0-9._~:/@%+,-]+$ || \
     $REPO =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._~/%+,-]+$ ]] || \
    die "--repo must be a safe HTTPS or git@ SSH URL"
  [[ $WORKSPACE_DIR == /* && $WORKSPACE_DIR != *$'\n'* ]] || \
    die "--workspace-root must be an absolute path without newlines"
  [[ $RESOURCE_PROFILE =~ ^(compact|balanced|throughput|custom)$ ]] || \
    die "--resource-profile must be compact, balanced, throughput, or custom"
  if [[ $RESOURCE_PROFILE_SET == true && $RESOURCE_PROFILE != custom ]] && \
      resource_override_set; then
    die "preset --resource-profile cannot be combined with custom resource limits"
  fi
  if [[ $RESOURCE_PROFILE_SET == true && $RESOURCE_PROFILE == custom && \
        $EXISTING_CONFIG == false ]] && ! resource_override_set; then
    die "--resource-profile custom requires at least one explicit resource limit"
  fi
  valid_bounded_integer "$MEMORY_LIMIT_MIB" 256 65536 || \
    die "--memory-limit-mib must be an integer between 256 and 65536"
  valid_bounded_integer "$MEMORY_RESERVATION_MIB" 128 "$MEMORY_LIMIT_MIB" || \
    die "--memory-reservation-mib must be an integer between 128 and --memory-limit-mib"
  valid_bounded_integer "$NOFILE_LIMIT" 4096 1048576 || \
    die "--nofile-limit must be an integer between 4096 and 1048576"
  valid_bounded_integer "$PIDS_LIMIT" 128 65536 || \
    die "--pids-limit must be an integer between 128 and 65536"
  [[ $REPO != *$'\n'* ]] || die "repository URL must not contain newlines"
  [[ -z "$MODEL_ENV_FILE" || -r "$MODEL_ENV_FILE" ]] || die "cannot read --env-file"
  if [[ -n "$MODEL_ENV_FILE" ]]; then
    [[ $(stat -c %u "$MODEL_ENV_FILE") == 0 ]] || die "--env-file must be owned by root"
    local mode
    mode=$(stat -c %a "$MODEL_ENV_FILE")
    ((10#$mode % 100 == 0)) || die "--env-file must not be accessible by group or other users"
  fi
}

resource_override_set() {
  [[ $MEMORY_LIMIT_SET == true || $MEMORY_RESERVATION_SET == true || \
     $NOFILE_SET == true || $PIDS_SET == true ]]
}

valid_bounded_integer() {
  local value=$1 minimum=$2 maximum=$3
  [[ $value =~ ^[0-9]+$ && ${#value} -le 10 ]] || return 1
  ((10#$value >= minimum && 10#$value <= maximum))
}

valid_ipv4() {
  local value=$1 a b c d extra octet
  IFS=. read -r a b c d extra <<<"$value"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

public_ipv4() {
  local candidate
  candidate=$(curl --fail --silent --show-error --proto '=https' \
    --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if valid_ipv4 "$candidate"; then printf '%s\n' "$candidate"; fi
}

install_host_requirements() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "the installer must run as root"
  [[ $(uname -s) == Linux ]] || die "only Linux VPS hosts are supported"

  if ! command -v git >/dev/null || ! command -v curl >/dev/null || \
      ! command -v docker >/dev/null || ! command -v python3 >/dev/null || \
      ! command -v flock >/dev/null; then
    command -v apt-get >/dev/null || \
      die "install git, curl, CA certificates, Docker, and Compose before continuing"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl git docker.io python3 util-linux
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null; then
    if ! apt-get install -y --no-install-recommends docker-compose-v2; then
      apt-get install -y --no-install-recommends docker-compose
    fi
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

require_host() {
  docker info >/dev/null 2>&1 || die "the Docker daemon is not available"

  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "Docker Compose is required (plugin or docker-compose executable)"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another install or update is already running"
}

load_existing_config() {
  if [[ -r "$INSTALL_CONFIG" ]]; then
    EXISTING_CONFIG=true
    # Generated by this installer using validated scalar values.
    # shellcheck disable=SC1090
    source "$INSTALL_CONFIG"
    [[ $HOST_SET == true ]] || PUBLIC_IP=${IEX_CODE_PUBLIC_IP:-}
    [[ $DOMAIN_SET == true ]] || PUBLIC_DOMAIN=${IEX_CODE_PUBLIC_DOMAIN:-}
    [[ $BEHIND_PROXY == true ]] || BEHIND_PROXY=${IEX_CODE_BEHIND_PROXY:-false}
    [[ $BIND_SET == true ]] || PUBLIC_BIND=${IEX_CODE_PUBLIC_BIND:-0.0.0.0}
    [[ $PORT_SET == true ]] || PUBLIC_PORT=${IEX_CODE_PUBLIC_PORT:-4000}
    [[ $REPO_SET == true ]] || REPO=${IEX_CODE_REPO:-$REPO}
    [[ $REF_SET == true ]] || REF=${IEX_CODE_REF:-$REF}
    [[ $WORKSPACE_SET == true ]] || WORKSPACE_DIR=${IEX_CODE_WORKSPACE_DIR:-$WORKSPACE_DIR}
  fi
  [[ -z "$WORKSPACE_ROOT_OVERRIDE" ]] || WORKSPACE_DIR=$WORKSPACE_ROOT_OVERRIDE
  resolve_resource_config
}

resolve_resource_config() {
  if [[ $RESOURCE_PROFILE_SET == true ]]; then
    if [[ $RESOURCE_PROFILE == custom ]]; then
      if [[ $EXISTING_CONFIG == true ]]; then restore_resource_config; fi
    else
      apply_resource_profile "$RESOURCE_PROFILE"
    fi
  elif [[ $EXISTING_CONFIG == true && -n ${IEX_CODE_RESOURCE_PROFILE:-} ]]; then
    RESOURCE_PROFILE=$IEX_CODE_RESOURCE_PROFILE
    restore_resource_config
    if [[ $RESOURCE_PROFILE != custom && $(infer_resource_profile) != "$RESOURCE_PROFILE" ]]; then
      RESOURCE_PROFILE=custom
    fi
  elif [[ $EXISTING_CONFIG == true ]]; then
    restore_resource_config
    RESOURCE_PROFILE=$(infer_resource_profile)
  fi

  if resource_override_set && \
      [[ $RESOURCE_PROFILE_SET == false || $RESOURCE_PROFILE == custom ]]; then
    RESOURCE_PROFILE=custom
  fi
}

apply_resource_profile() {
  case "$1" in
    compact) MEMORY_LIMIT_MIB=1024 ;;
    balanced) MEMORY_LIMIT_MIB=2048 ;;
    throughput) MEMORY_LIMIT_MIB=2560 ;;
    custom) return 0 ;;
    *) die "--resource-profile must be compact, balanced, throughput, or custom" ;;
  esac
  MEMORY_RESERVATION_MIB=512
  NOFILE_LIMIT=65536
  PIDS_LIMIT=1024
}

infer_resource_profile() {
  if [[ $MEMORY_RESERVATION_MIB == 512 && $NOFILE_LIMIT == 65536 && \
        $PIDS_LIMIT == 1024 ]]; then
    case "$MEMORY_LIMIT_MIB" in
      1024) printf 'compact\n'; return ;;
      2048) printf 'balanced\n'; return ;;
      2560) printf 'throughput\n'; return ;;
    esac
  fi
  printf 'custom\n'
}

restore_resource_config() {
  [[ $MEMORY_LIMIT_SET == true ]] || \
    MEMORY_LIMIT_MIB=${IEX_CODE_MEMORY_LIMIT_MIB:-$MEMORY_LIMIT_MIB}
  [[ $MEMORY_RESERVATION_SET == true ]] || \
    MEMORY_RESERVATION_MIB=${IEX_CODE_MEMORY_RESERVATION_MIB:-$MEMORY_RESERVATION_MIB}
  [[ $NOFILE_SET == true ]] || NOFILE_LIMIT=${IEX_CODE_NOFILE_LIMIT:-$NOFILE_LIMIT}
  [[ $PIDS_SET == true ]] || PIDS_LIMIT=${IEX_CODE_PIDS_LIMIT:-$PIDS_LIMIT}
}

detect_public_ip() {
  if [[ -n "$PUBLIC_DOMAIN" ]]; then
    PUBLIC_HOST=$PUBLIC_DOMAIN
    if [[ $BEHIND_PROXY == false ]]; then
      [[ $PORT_SET == false || $PUBLIC_PORT == 443 ]] || \
        die "domain/Caddy mode owns standard ports 80/443; omit --port or use --behind-proxy"
      PUBLIC_PORT=443
    fi
    return 0
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(public_ipv4)
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')
  fi
  valid_ipv4 "$PUBLIC_IP" || die "could not detect a valid IPv4 address; pass --host"
  if [[ $PUBLIC_IP =~ ^10\. || $PUBLIC_IP =~ ^192\.168\. || \
        $PUBLIC_IP =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
    die "only a private IPv4 address was detected; pass the public address with --host"
  fi
  PUBLIC_HOST=$PUBLIC_IP
}

compose() {
  local -a topology=()
  if [[ $BEHIND_PROXY == true ]]; then
    topology=(-f "$SOURCE_DIR/deploy/compose.behind-proxy.yaml")
  elif [[ -n "$PUBLIC_DOMAIN" ]]; then
    topology=(-f "$SOURCE_DIR/deploy/compose.caddy-domain.yaml" --profile caddy)
  else
    topology=(-f "$SOURCE_DIR/deploy/compose.caddy-ip.yaml" --profile caddy)
  fi
  IEX_CODE_APP_ENV_FILE="$APP_ENV_FILE" \
  IEX_CODE_STATE_DIR="$STATE_DIR" \
  IEX_CODE_WORKSPACE_DIR="$WORKSPACE_DIR" \
  IEX_CODE_PUBLIC_IP="$PUBLIC_IP" \
  IEX_CODE_PUBLIC_HOST="$PUBLIC_HOST" \
  IEX_CODE_CADDYFILE="$(if [[ -n "$PUBLIC_DOMAIN" ]]; then printf '%s/deploy/Caddyfile' "$SOURCE_DIR"; else printf '%s/deploy/Caddyfile.ip' "$SOURCE_DIR"; fi)" \
  IEX_CODE_PUBLIC_BIND="$PUBLIC_BIND" \
  IEX_CODE_PUBLIC_PORT="$PUBLIC_PORT" \
  IEX_CODE_APP_UID="$APP_UID" \
  IEX_CODE_APP_GID="$APP_GID" \
  IEX_CODE_RESOURCE_PROFILE="$RESOURCE_PROFILE" \
  IEX_CODE_MEMORY_LIMIT_MIB="$MEMORY_LIMIT_MIB" \
  IEX_CODE_MEMORY_RESERVATION_MIB="$MEMORY_RESERVATION_MIB" \
  IEX_CODE_NOFILE_LIMIT="$NOFILE_LIMIT" \
  IEX_CODE_PIDS_LIMIT="$PIDS_LIMIT" \
    "${COMPOSE[@]}" --project-directory "$SOURCE_DIR" \
      -f "$SOURCE_DIR/compose.yaml" "${topology[@]}" "$@"
}

random_hex() {
  od -An -N"${1:-32}" -tx1 /dev/urandom | tr -d ' \n'
}

sha256_text() {
  local value=$1
  printf %s "$value" | sha256sum | awk '{print $1}'
}

allowed_env_key() {
  case "$1" in
    OPENAI_API_KEY|OPENAI_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|\
    IEX_CODE_DEFAULT_MODEL|IEX_CODE_DEFAULT_MODEL_PROVIDER|TEMPERATURE|MAX_TOKENS|\
    TAVILY_API_KEY) return 0 ;;
    *) return 1 ;;
  esac
}

remove_importable_keys() {
  local source=$1 target=$2 line key
  [[ -f "$source" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line%%=*}
    if ! allowed_env_key "$key"; then printf '%s\n' "$line" >>"$target"; fi
  done <"$source"
}

create_bootstrap_settings() {
  [[ -n "$MODEL_ENV_FILE" ]] || return 0
  local temp destination=$STATE_DIR/bootstrap-settings.json
  temp=$(mktemp "$CONFIG_DIR/.bootstrap-settings.XXXXXX")
  if ! python3 - "$MODEL_ENV_FILE" "$temp" <<'PY'
import json, sys

source, destination = sys.argv[1:]
mapping = {
    "OPENAI_API_KEY": "openai_api_key",
    "OPENAI_BASE_URL": "openai_base_url",
    "ANTHROPIC_API_KEY": "anthropic_api_key",
    "ANTHROPIC_BASE_URL": "anthropic_base_url",
    "IEX_CODE_DEFAULT_MODEL_PROVIDER": "default_model_provider",
    "IEX_CODE_DEFAULT_MODEL": "default_model",
    "TEMPERATURE": "temperature",
    "MAX_TOKENS": "max_tokens",
    "TAVILY_API_KEY": "tavily_api_key",
}
settings = {}
with open(source, "r", encoding="utf-8") as stream:
    for number, raw in enumerate(stream, 1):
        line = raw.rstrip("\r\n")
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"invalid env line {number}")
        key, value = line.split("=", 1)
        if key not in mapping:
            raise SystemExit(f"unsupported env key on line {number}: {key}")
        if "\x00" in value:
            raise SystemExit(f"invalid NUL byte on line {number}")
        mapped = mapping[key]
        if key == "TEMPERATURE":
            try: value = float(value)
            except ValueError: raise SystemExit("TEMPERATURE must be numeric")
            if not 0 <= value <= 2: raise SystemExit("TEMPERATURE must be between 0 and 2")
        elif key == "MAX_TOKENS":
            try: value = int(value)
            except ValueError: raise SystemExit("MAX_TOKENS must be an integer")
            if not 1 <= value <= 128_000: raise SystemExit("MAX_TOKENS is out of range")
        settings[mapped] = value
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(settings, stream, ensure_ascii=False, separators=(",", ":"))
    stream.write("\n")
PY
  then
    rm -f -- "$temp"
    return 1
  fi
  chmod 0600 "$temp"
  if [[ -d "$SOURCE_DIR/.git" && -n "$(compose ps -q app 2>/dev/null || true)" ]]; then
    info "Stopping the app before installing bootstrap credentials"
    compose stop app >/dev/null
  fi
  rm -f -- "$destination"
  install -o "$APP_UID" -g "$APP_GID" -m 0600 "$temp" "$destination"
  rm -f -- "$temp"
}

prepare_directories() {
  install -d -m 0700 "$INSTALL_ROOT" "$CONFIG_DIR" "$BACKUP_DIR"
  install -d -o "$APP_UID" -g "$APP_GID" -m 0700 "$STATE_DIR" "$WORKSPACE_DIR"
  install -d -o "$APP_UID" -g "$APP_GID" -m 0700 \
    "$STATE_DIR/home" "$WORKSPACE_DIR/default"
}

prepare_token() {
  local token token_sha
  token_sha=$(sed -n 's/^IEX_CODE_ADMIN_TOKEN_SHA256=//p' "$APP_ENV_FILE" 2>/dev/null | head -n1 || true)
  if [[ $ROTATE_TOKEN == false && $token_sha =~ ^[0-9a-f]{64}$ ]]; then
    :
  else
    token=$(random_hex 32)
    NEW_TOKEN=$token
    token_sha=$(sha256_text "$token")
  fi
  [[ $token_sha =~ ^[0-9a-f]{64}$ ]] || die "could not hash the admin token"
  TOKEN_SHA=$token_sha
  rm -f -- "$CONFIG_DIR/admin.token" "$CONFIG_DIR/proxy.env"
}

write_environment() {
  local secret_key temp
  secret_key=$(sed -n 's/^SECRET_KEY_BASE=//p' "$APP_ENV_FILE" 2>/dev/null | head -n1 || true)
  [[ -n "$secret_key" ]] || secret_key=$(random_hex 64)

  temp=$(mktemp "$CONFIG_DIR/.app.env.XXXXXX")
  if [[ -f "$APP_ENV_FILE" ]]; then remove_importable_keys "$APP_ENV_FILE" "$temp"; fi
  # Remove values whose authoritative copies are regenerated below.
  sed -i '/^SECRET_KEY_BASE=/d;/^IEX_CODE_ADMIN_TOKEN_SHA256=/d;/^PHX_HOST=/d;/^PHX_SCHEME=/d;/^PHX_PORT=/d' "$temp"
  {
    printf 'SECRET_KEY_BASE=%s\n' "$secret_key"
    printf 'IEX_CODE_ADMIN_TOKEN_SHA256=%s\n' "$TOKEN_SHA"
    printf 'PHX_HOST=%s\n' "$PUBLIC_HOST"
    printf 'PHX_SCHEME=https\n'
    if [[ -n "$PUBLIC_DOMAIN" ]]; then printf 'PHX_PORT=443\n'; else printf 'PHX_PORT=%s\n' "$PUBLIC_PORT"; fi
  } >>"$temp"
  printf 'IEX_CODE_BOOTSTRAP_SETTINGS_FILE=/var/lib/iex-code/bootstrap-settings.json\n' >>"$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$APP_ENV_FILE"

  temp=$(mktemp "$CONFIG_DIR/.install.conf.XXXXXX")
  {
    printf 'IEX_CODE_SOURCE_DIR=%q\n' "$SOURCE_DIR"
    printf 'IEX_CODE_APP_ENV_FILE=%q\n' "$APP_ENV_FILE"
    printf 'IEX_CODE_STATE_DIR=%q\n' "$STATE_DIR"
    printf 'IEX_CODE_WORKSPACE_DIR=%q\n' "$WORKSPACE_DIR"
    printf 'IEX_CODE_BACKUP_DIR=%q\n' "$BACKUP_DIR"
    printf 'IEX_CODE_PUBLIC_IP=%q\n' "$PUBLIC_IP"
    printf 'IEX_CODE_PUBLIC_DOMAIN=%q\n' "$PUBLIC_DOMAIN"
    printf 'IEX_CODE_PUBLIC_HOST=%q\n' "$PUBLIC_HOST"
    printf 'IEX_CODE_BEHIND_PROXY=%q\n' "$BEHIND_PROXY"
    printf 'IEX_CODE_CADDYFILE=%q\n' "$(if [[ -n "$PUBLIC_DOMAIN" ]]; then printf '%s/deploy/Caddyfile' "$SOURCE_DIR"; else printf '%s/deploy/Caddyfile.ip' "$SOURCE_DIR"; fi)"
    printf 'IEX_CODE_PUBLIC_BIND=%q\n' "$PUBLIC_BIND"
    printf 'IEX_CODE_PUBLIC_PORT=%q\n' "$PUBLIC_PORT"
    printf 'IEX_CODE_APP_UID=%q\n' "$APP_UID"
    printf 'IEX_CODE_APP_GID=%q\n' "$APP_GID"
    printf 'IEX_CODE_RESOURCE_PROFILE=%q\n' "$RESOURCE_PROFILE"
    printf 'IEX_CODE_MEMORY_LIMIT_MIB=%q\n' "$MEMORY_LIMIT_MIB"
    printf 'IEX_CODE_MEMORY_RESERVATION_MIB=%q\n' "$MEMORY_RESERVATION_MIB"
    printf 'IEX_CODE_NOFILE_LIMIT=%q\n' "$NOFILE_LIMIT"
    printf 'IEX_CODE_PIDS_LIMIT=%q\n' "$PIDS_LIMIT"
    printf 'IEX_CODE_REPO=%q\n' "$REPO"
    printf 'IEX_CODE_REF=%q\n' "$REF"
  } >"$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$INSTALL_CONFIG"
}

check_port() {
  [[ -d "$SOURCE_DIR/.git" ]] && return 0
  command -v ss >/dev/null || return 0
  local -a ports=("$PUBLIC_PORT")
  if [[ -n "$PUBLIC_DOMAIN" && $BEHIND_PROXY == false ]]; then ports=(80 443); fi
  local port
  for port in "${ports[@]}"; do
    if ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
      die "TCP port $port is already in use"
    fi
  done
}

backup_before_update() {
  if [[ -f "$STATE_DIR/iex_code.db" && -x /usr/local/bin/iex-code-web ]]; then
    info "Creating pre-update backup"
    /usr/local/bin/iex-code-web backup >/dev/null
  fi
}

checkout_source() {
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    [[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] || die "source checkout has local changes"
    git -C "$SOURCE_DIR" fetch --prune --tags origin
    git -C "$SOURCE_DIR" checkout --detach "origin/$REF" 2>/dev/null || \
      git -C "$SOURCE_DIR" checkout --detach "$REF"
  else
    rm -rf -- "$SOURCE_DIR"
    git clone -- "$REPO" "$SOURCE_DIR"
    git -C "$SOURCE_DIR" checkout --detach "origin/$REF" 2>/dev/null || \
      git -C "$SOURCE_DIR" checkout --detach "$REF"
  fi
}

install_manager() {
  install -o root -g root -m 0755 "$SOURCE_DIR/deploy/iex-code-web" \
    /usr/local/bin/iex-code-web
}

wait_for_health() {
  local id status attempt
  for attempt in $(seq 1 90); do
    id=$(compose ps -q app 2>/dev/null || true)
    if [[ -n "$id" ]]; then
      status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$id" 2>/dev/null || true)
      [[ $status == healthy ]] && return 0
      [[ $status == unhealthy ]] && break
    fi
    sleep 2
  done
  compose ps >&2 || true
  compose logs --tail=100 app >&2 || true
  die "application did not become healthy"
}

smoke_proxy() {
  if [[ $BEHIND_PROXY == true ]]; then
    curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
      "http://127.0.0.1:$PUBLIC_PORT/health/ready" >/dev/null || \
      die "loopback upstream smoke check failed"
    return 0
  fi
  local attempt
  for attempt in $(seq 1 90); do
    if curl --fail --silent --show-error --insecure \
        --connect-timeout 5 --max-time 10 "https://$PUBLIC_HOST:$PUBLIC_PORT/health/live" \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  compose logs --tail=100 proxy >&2 || true
  die "TLS proxy smoke check failed"
}

main() {
  parse_args "$@"
  install_host_requirements
  require_host
  acquire_lock
  load_existing_config
  validate_args
  detect_public_ip
  prepare_directories
  check_port
  backup_before_update
  checkout_source
  prepare_token
  write_environment
  create_bootstrap_settings
  install_manager

  info "Validating Compose configuration"
  compose config --quiet
  info "Building application image"
  compose build --pull
  info "Starting IexCode Web"
  compose up -d --remove-orphans
  wait_for_health
  smoke_proxy

  if [[ $BEHIND_PROXY == true ]]; then
    info "IexCode Web upstream is ready at http://127.0.0.1:$PUBLIC_PORT"
    info "Configure the external proxy for https://$PUBLIC_HOST before browser access."
  elif [[ -n "$PUBLIC_DOMAIN" ]]; then
    info "IexCode Web is ready at https://$PUBLIC_HOST"
  else
    info "IexCode Web is ready at https://$PUBLIC_HOST:$PUBLIC_PORT"
  fi
  if [[ -z "$PUBLIC_DOMAIN" ]]; then
    warn "Caddy uses an internal CA for IP testing; the browser will show a certificate warning."
  fi
  if [[ -n "$NEW_TOKEN" ]]; then
    printf '\nAdmin token (shown once): %s\n' "$NEW_TOKEN"
    printf 'Use this token on the IexCode Web login page. It is not stored in plaintext.\n'
  else
    printf 'Existing admin token hash preserved. Use `iex-code-web reset-token` if it was lost.\n'
  fi
  printf 'Manage the service with: iex-code-web status|logs|update|backup|restore\n'
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  main "$@"
fi
