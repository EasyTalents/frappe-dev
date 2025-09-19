#!/usr/bin/env bash
set -euo pipefail

# === Variables depuis devcontainer.json ===
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"
CUSTOM_APP_URL="${CUSTOM_APP_URL:-}"
CUSTOM_APP_BRANCH="${CUSTOM_APP_BRANCH:-develop}"

# === Helpers ===
log() { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

# === Pré-requis système ===
log "Install paquets requis (MariaDB, Redis, wkhtmltopdf, build-essential, pipx, etc.)"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  xfonts-75dpi xfonts-base fontconfig \
  wkhtmltopdf

# Yarn (Frappe v15 attend yarn classic 1.x)
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm i -g yarn@1
fi

# pipx pour isoler frappe-bench
if ! command -v pipx >/dev/null 2>&1; then
  python3 -m pip install --user pipx
  python3 -m pipx ensurepath || true
fi
export PATH="$HOME/.local/bin:$PATH"

# === Démarrer services DB/Redis ===
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# === Init root MariaDB ===
log "Configuration root MariaDB (si nécessaire)"
# Essaye sans mot de passe (fresh) puis avec mot de passe (si déjà configuré)
if sudo mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql -u root -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'" || true
  sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES" || true
else
  sudo mysql -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES" || true
fi

# Assurer bind 127.0.0.1 (optionnel, plus sûr pour devcontainer)
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# === Installer frappe-bench ===
log "Installation frappe-bench via pipx"
pipx install frappe-bench || pipx upgrade frappe-bench
command -v bench >/dev/null 2>&1 || { err "bench introuvable dans PATH"; exit 1; }

# === bench init ===
if [ ! -d "$HOME/frappe-bench" ]; then
  log "bench init (branch ${FRAPPE_BRANCH})"
  bench init --frappe-branch "${FRAPPE_BRANCH}" --python "$(command -v python3.11)" "$HOME/frappe-bench"
fi

cd "$HOME/frappe-bench"

# === Configure common_site_config.json (DB root creds) ===
log "Mise à jour sites/common_site_config.json"
python3 - <<'PY'
import json, os, sys
p = os.path.expanduser('~/frappe-bench/sites/common_site_config.json')
with open(p) as f: cfg=json.load(f)
cfg.setdefault("db_host","127.0.0.1")
cfg.setdefault("db_port",3306)
cfg["root_login"]=os.environ.get("DB_ROOT_USER","root")
cfg["root_password"]=os.environ.get("DB_ROOT_PASSWORD","root")
with open(p,"w") as f: json.dump(cfg,f,indent=2)
print("common_site_config.json updated")
PY

# === Créer le site si absent ===
if [ ! -d "sites/${SITE_NAME}" ]; then
  log "Création du site ${SITE_NAME}"
  bench new-site "${SITE_NAME}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-root-username "${DB_ROOT_USER}" \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --no-mariadb-socket \
    --force
fi

# === App custom (facultatif, générique par défaut) ===
if [ -n "${CUSTOM_APP_URL}" ]; then
  log "Installation app custom depuis ${CUSTOM_APP_URL} (branch: ${CUSTOM_APP_BRANCH})"
  app_name="$(basename -s .git "${CUSTOM_APP_URL}")"
  if [ ! -d "apps/${app_name}" ]; then
    bench get-app --branch "${CUSTOM_APP_BRANCH}" "${CUSTOM_APP_URL}"
  fi
  bench --site "${SITE_NAME}" install-app "${app_name}" || true
else
  log "Aucune app custom (mode générique)."
fi

# === Démarrer bench en background (1er run) ===
log "Démarrage de bench (background)"
nohup bench start >/tmp/bench.log 2>&1 &

log "OK. Ouvre http://localhost:8000 (port forwarding) → site: ${SITE_NAME}, admin: ${ADMIN_PASSWORD}"
