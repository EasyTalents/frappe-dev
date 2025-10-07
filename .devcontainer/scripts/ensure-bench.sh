#!/usr/bin/env bash
set -euo pipefail

BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"
BENCH_LOG_PATH="${BENCH_LOG_PATH:-/tmp/bench.log}"

if [ ! -d "$BENCH_HOME" ]; then
  exit 0
fi

if ! command -v bench >/dev/null 2>&1; then
  exit 0
fi

if pgrep -f "bench start" >/dev/null 2>&1; then
  exit 0
fi

mkdir -p "$(dirname "$BENCH_LOG_PATH")"
nohup bench start >"$BENCH_LOG_PATH" 2>&1 & disown
