#!/bin/sh
set -eu

exec curl --fail --silent --show-error \
  --connect-timeout 2 --max-time 4 \
  http://127.0.0.1:4000/health/ready >/dev/null
