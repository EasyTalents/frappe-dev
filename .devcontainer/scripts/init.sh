#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Frappe Dev – init.sh (mono-container, fidèle à development.md)
# - bench init --skip-redis-config-generation
# - bench set-config -g (adapté: localhost/127.0.0.1)
# - bench new-site … --mariadb-user-host-login-scope=%
# - Bench et site sous /workspaces/frappe-bench
########################################################################

# ========= Variables (via devcontainer.json ou défauts) =========
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# La doc d’origine utilise 123 en dev ; garde ton choix si tu veux
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# App custom (facultatif)
CUSTOM_APP_URL="${CUSTOM_APP_URL:-}"          # vide => pas d'app installée
CUSTOM_APP_BRANCH="${CUSTOM_APP_BRANCH:-develop}"

# Dossier cible du bench (tu as demandé /workspaces)
BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"

# ========= Helpers =========
log() { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

# Déterminer l’utilisateur “dev” (non-root)
DEVUSER="${CONTAINER_USER:-vscode}"
if ! id "$DEVUSER" >/dev/null 2>&1; then DEVUSER="vscode"; fi

# ========= Pré-requis système =========
log "Install des paquets requis (MariaDB, Redis, wkhtmltopdf, fonts, Node/Yarn)"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  xfonts-75dpi xfonts-base fontconfig \
  wkhtmltopdf

# Yarn 1.x (classic) – conforme v15
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm i -g yarn@1
fi

# ========= Services DB/Redis =========
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# Config root MariaDB (tolérant si déjà configuré)
log "Configurer l’utilisateur root MariaDB (si nécessaire)"
if sudo mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql -u root -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'" || true
  sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES" || true
else
  sudo mysql -u "${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES" || true
fi

# bind 127.0.0.1 (sécurisant pour devcontainer)
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# ========= pipx + frappe-bench (toujours pour DEVUSER) =========
log "Installer/mettre à jour pipx et frappe-bench pour l’utilisateur ${DEVUSER}"

# Tenter pipx via apt, sinon fallback user-local
if ! command -v pipx >/dev/null 2>&1; then
  if sudo apt-get install -y pipx; then
    :
  else
    sudo -u "$DEVUSER" -H bash -lc "python3 -m pip install --user pipx || true"
  fi
fi

# Assurer PATH et installer frappe-bench via pipx (DEVUSER)
sudo -u "$DEVUSER" -H bash -lc '
  set -e
  export PATH="$HOME/.local/bin:$PATH"
  python3 -m pipx ensurepath || true
  pipx install frappe-bench || pipx upgrade frappe-bench
  bench --version >/dev/null
'

# ========= bench init --skip-redis-config-generation =========
log "Préparer le bench (init) dans ${BENCH_HOME}"
sudo mkdir -p "$BENCH_HOME"
sudo chown -R "$DEVUSER:$DEVUSER" /workspaces

sudo -u "$DEVUSER" -H bash -lc "
  set -e
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  export BENCH_HOME='${BENCH_HOME}'

  # 1) bench init (comme dans la doc, avec --skip-redis-config-generation)
  if [ ! -d \"\${BENCH_HOME}/apps/frappe\" ]; then
    bench init --skip-redis-config-generation \
               --frappe-branch '${FRAPPE_BRANCH}' \
               --python \$(command -v python3.11) \
               \"\${BENCH_HOME}\"
  fi

  cd \"\${BENCH_HOME}\"

  # 2) bench set-config -g … (adaptation mono-container: localhost)
  #    La doc le fait pour des services externes (mariadb, redis-cache, redis-queue).
  #    Ici, tout est local, donc on pointe vers 127.0.0.1:6379
  if bench set-config -g db_host 127.0.0.1; then
    bench set-config -g redis_cache   redis://127.0.0.1:6379 || true
    bench set-config -g redis_queue   redis://127.0.0.1:6379 || true
    bench set-config -g redis_socketio redis://127.0.0.1:6379 || true
  else
    # fallback: éditer common_site_config.json
    python3 - <<'PY'
import json, os
p = os.path.expanduser('sites/common_site_config.json')
with open(p) as f: cfg=json.load(f)
cfg['db_host']='127.0.0.1'
cfg['redis_cache']='redis://127.0.0.1:6379'
cfg['redis_queue']='redis://127.0.0.1:6379'
cfg['redis_socketio']='redis://127.0.0.1:6379'
with open(p,'w') as f: json.dump(cfg,f,indent=2)
print('common_site_config.json updated (fallback)')
PY
  fi

  # 3) Créer le site (doc: --mariadb-user-host-login-scope=%)
  if [ ! -d 'sites/${SITE_NAME}' ]; then
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password '${ADMIN_PASSWORD}' \
      --mariadb-user-host-login-scope=% \
      --no-mariadb-socket \
      --force
  fi

  # 4) (Optionnel) App custom
  if [ -n '${CUSTOM_APP_URL}' ]; then
    app_name=\$(basename -s .git '${CUSTOM_APP_URL}')
    if [ ! -d \"apps/\${app_name}\" ]; then
      bench get-app --branch '${CUSTOM_APP_BRANCH}' '${CUSTOM_APP_URL}'
    fi
    bench --site '${SITE_NAME}' install-app \"\${app_name}\" || true
  fi
"

# ========= Démarrage bench en arrière-plan =========
log "Démarrage de bench (background)"
sudo -u "$DEVUSER" -H bash -lc "
  cd '${BENCH_HOME}' && nohup bench start >/tmp/bench.log 2>&1 &
"

log "OK → http://localhost:8000 | site: ${SITE_NAME} | bench: ${BENCH_HOME} | user: ${DEVUSER}"
warn "Si tu veux PostgreSQL à la place de MariaDB: adapte bench new-site (--db-type postgres) + set-config db_host, et installe le serveur Postgres dans l’image."
