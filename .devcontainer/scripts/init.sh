#!/usr/bin/env bash
set -euo pipefail

# === Variables depuis devcontainer.json ===
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"
PHARMTEK_APP_URL="${PHARMTEK_APP_URL:-}"
PHARMTEK_APP_BRANCH="${PHARMTEK_APP_BRANCH:-develop}"

# === Helpers ===
log() { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }

# === Pré-requis système ===
log "Install des paquets requis (MariaDB, Redis, wkhtmltopdf, build-essential, pipx, etc.)"
sudo apt-get update -y
sudo apt-get install -y \
  mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  wkhtmltopdf ttf-dejavu-core fontconfig

# pipx (pour installer frappe-bench isolé)
if ! command -v pipx >/dev/null 2>&1; then
  python3 -m pip install --user pipx
  python3 -m pipx ensurepath || true
  export PATH="$HOME/.local/bin:$PATH"
fi

# === Démarrer services DB/Redis ===
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# === Sécuriser/initialiser le root MariaDB ===
log "Configuration du root MariaDB"
# Tente de setter le mot de passe root; ignore les erreurs si déjà configuré
sudo mysql -u root -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'" || true
sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES" || true

# Assurer le bind sur 127.0.0.1 (optionnel)
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# === Installer frappe-bench ===
log "Installation de frappe-bench via pipx"
pipx install frappe-bench || pipx upgrade frappe-bench
export PATH="$HOME/.local/bin:$PATH"

# === Initialiser le bench (dans ~/frappe-bench) ===
if [ ! -d "$HOME/frappe-bench" ]; then
  log "bench init (branch ${FRAPPE_BRANCH})"
  bench init --frappe-branch "${FRAPPE_BRANCH}" --python "$(command -v python3.11)" "$HOME/frappe-bench"
fi

cd "$HOME/frappe-bench"

# Ajouter creds DB root au common_site_config pour éviter les prompts
log "Mise à jour common_site_config.json"
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/frappe-bench/sites/common_site_config.json')
with open(p) as f: cfg=json.load(f)
cfg.setdefault("db_host","127.0.0.1")
cfg.setdefault("db_port",3306)
cfg["root_login"]=os.environ.get("DB_ROOT_USER","root")
cfg["root_password"]=os.environ.get("DB_ROOT_PASSWORD","root")
with open(p,"w") as f: json.dump(cfg,f,indent=2)
print("common_site_config.json updated")
PY

# === Créer le site s'il n'existe pas ===
if [ ! -d "sites/${SITE_NAME}" ]; then
  log "Création du site ${SITE_NAME}"
  bench new-site "${SITE_NAME}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-root-username "${DB_ROOT_USER}" \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --no-mariadb-socket \
    --force
fi

# === (Optionnel) Installer une app custom si URL fournie ===
if [ -n "${PHARMTEK_APP_URL}" ]; then
  log "Installation app custom depuis ${PHARMTEK_APP_URL} (branch: ${PHARMTEK_APP_BRANCH})"
  app_name="$(basename -s .git "${PHARMTEK_APP_URL}")"
  if [ ! -d "apps/${app_name}" ]; then
    bench get-app --branch "${PHARMTEK_APP_BRANCH}" "${PHARMTEK_APP_URL}"
  fi
  bench --site "${SITE_NAME}" install-app "${app_name}" || true
fi

# === Lancer le bench en arrière-plan au premier run ===
log "Démarrage de bench (background)"
nohup bench start >/tmp/bench.log 2>&1 &

log "Provision terminé. Ouvre http://localhost:8000 (port forward) → site: ${SITE_NAME}"
