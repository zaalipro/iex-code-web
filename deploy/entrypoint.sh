#!/bin/sh
set -eu

umask 077

mkdir -p "$HOME" "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR" /workspaces/default

if [ ! -d "$MIX_HOME/archives" ]; then
  cp -R /opt/mix-seed/. "$MIX_HOME/"
fi

if [ "$#" -eq 0 ]; then
  set -- /opt/iex-code/bin/iex_code start
fi

exec "$@"
