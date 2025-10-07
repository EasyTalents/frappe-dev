#!/usr/bin/env bash
set -euo pipefail

echo "[codex-setup] install outils de validation"
# jq + shellcheck pour valider JSON et shell
if command -v apt-get >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq shellcheck python3
fi

# Node/Python min pour lint si besoin
if command -v npm >/dev/null 2>&1; then npm -v || true; fi
python3 -V || true

echo "[codex-setup] done"
