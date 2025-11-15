#!/usr/bin/env bash
set -e

# On travaille depuis le dossier development du repo
cd /workspace/development

# Si le bench existe déjà, on ne refait rien (idempotent)
if [ -d "frappe-bench" ]; then
  echo "[init-bench] frappe-bench déjà présent, on ne fait rien."
  exit 0
fi

echo "[init-bench] Création du bench et du site de dev..."

# Utilise l'installeur officiel qui automatise :
# - création bench
# - création site
# - installation des apps de apps-example.json (par défaut)
#  --apps-json apps-example.json \
python installer.py \
  --bench-name frappe-bench \
  --site-name development.localhost \
  --frappe-branch version-15

cd frappe-bench

# Active le mode développeur sur le site
bench --site development.localhost set-config developer_mode 1
bench --site development.localhost clear-cache

echo "[init-bench] Terminé."
