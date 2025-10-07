#!/usr/bin/env bash
set -euo pipefail

start_service() {
  local name="$1"
  if command -v service >/dev/null 2>&1; then
    sudo service "$name" start >/dev/null 2>&1 || true
  fi
}

start_service mariadb
start_service mysql
start_service redis-server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/ensure-bench.sh"
