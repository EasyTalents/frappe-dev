#!/usr/bin/env bash
set -euo pipefail

echo "[init-bench] Démarrage du script"

########################################
# 0) Chemins
########################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DEV_DIR="$SCRIPT_DIR"          # /workspaces/frappe-dev/development
TARGET_DIR="$HOME"                  # /home/coder
BENCH_DIR="$HOME/frappe-bench"      # /home/coder/frappe-bench

echo "[init-bench] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[init-bench] TARGET_DIR  = $TARGET_DIR"
echo "[init-bench] BENCH_DIR   = $BENCH_DIR"

# Copier installer.py et apps-example.json dans $HOME (si nécessaires)
for f in installer.py apps-example.json; do
  if [ ! -f "$REPO_DEV_DIR/$f" ]; then
    echo "[init-bench] ERREUR : $f introuvable dans $REPO_DEV_DIR"
    exit 1
  fi
  cp -u "$REPO_DEV_DIR/$f" "$TARGET_DIR/$f"
done

cd "$TARGET_DIR"
echo "[init-bench] Répertoire courant : $(pwd)"

########################################
# 1) Python
########################################

PYTHON_BIN="$(command -v python || command -v python3 || true)"

if [ -z "$PYTHON_BIN" ]; then
  echo "[init-bench] ERREUR : aucun binaire python ou python3 trouvé."
  exit 1
fi

echo "[init-bench] Utilisation de Python : $PYTHON_BIN"

# ~/.local/bin pour uv & bench
export PATH="$HOME/.local/bin:$PATH"
echo "[init-bench] PATH = $PATH"

########################################
# 2) uv
########################################

if ! command -v uv >/dev/null 2>&1; then
  echo "[init-bench] uv non trouvé, installation…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if command -v uv >/dev/null 2>&1; then
  echo "[init-bench] uv détecté : $(command -v uv)"
  UV_AVAILABLE=1
else
  echo "[init-bench] ATTENTION : uv non disponible, fallback pip."
  UV_AVAILABLE=0
fi

########################################
# 3) bench via uv (ou pip en secours)
########################################

if ! command -v bench >/dev/null 2>&1; then
  echo "[init-bench] bench non trouvé, installation…"

  if [ "$UV_AVAILABLE" -eq 1 ]; then
    echo "[init-bench] Installation de frappe-bench via uv tool…"
    uv tool install frappe-bench
  else
    echo "[init-bench] Installation de frappe-bench via pip --user…"
    "$PYTHON_BIN" -m pip install --user frappe-bench --break-system-packages || \
    "$PYTHON_BIN" -m pip install --user frappe-bench
  fi

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v bench >/dev/null 2>&1; then
    echo "[init-bench] ERREUR : bench introuvable après installation."
    exit 1
  fi
  echo "[init-bench] bench installé : $(command -v bench)"
else
  echo "[init-bench] bench déjà installé : $(command -v bench)"
fi

########################################
# 4) Création du bench + site
########################################

if [ -d "$BENCH_DIR" ]; then
  echo "[init-bench] frappe-bench existe déjà dans $BENCH_DIR, on ne fait rien."
  exit 0
fi

echo "[init-bench] Création du bench et du site via installer.py dans $TARGET_DIR..."

"$PYTHON_BIN" installer.py \
  --bench-name frappe-bench \
  --site-name development.localhost \
  --frappe-branch version-15

cd "$BENCH_DIR"

echo "[init-bench] Configuration du site en mode développeur..."
bench --site development.localhost set-config developer_mode 1
bench --site development.localhost clear-cache

echo "[init-bench] Terminé."
