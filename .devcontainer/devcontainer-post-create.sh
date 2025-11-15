#!/usr/bin/env bash
set -euo pipefail

echo "[post-create] Démarrage postCreate..."

# 1) Démarrer les services (sans planter si déjà lancés)
if command -v sudo >/dev/null 2>&1; then
  echo "[post-create] Démarrage MariaDB..."
  sudo service mariadb start || echo "[post-create] MariaDB déjà démarré ou non disponible"

  echo "[post-create] Démarrage Redis..."
  sudo service redis-server start || echo "[post-create] Redis déjà démarré ou non disponible"
fi

# 2) Si un bench existe déjà, on ne tente pas de le recréer
if [ -d "$HOME/frappe-bench" ]; then
  echo "[post-create] Bench existant détecté dans $HOME/frappe-bench, on ne relance pas init-bench.sh."
  exit 0
fi

# 3) Sinon, on tente de lancer init-bench.sh (mais sans casser le workspace si ça échoue)
if [ -x "/workspaces/frappe-dev/development/init-bench.sh" ]; then
  echo "[post-create] Aucun bench détecté, lancement de init-bench.sh..."
  bash /workspaces/frappe-dev/development/init-bench.sh || {
    echo "[post-create] ⚠ init-bench.sh a échoué, mais on laisse le workspace démarrer."
  }
else
  echo "[post-create] init-bench.sh introuvable ou non exécutable, on passe."
fi

echo "[post-create] Terminé."
