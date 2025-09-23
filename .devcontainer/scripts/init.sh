#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Frappe Dev – init.sh (mono-container, bench 5.x)
#######################################################################

# ---- Paramètres (surchargeables via devcontainer.json -> containerEnv)
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"   # mets ici ton vrai mdp si différent

BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"
DEVUSER="${CONTAINER_USER:-vscode}"

# ---- Helpers
log()  { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

as_devuser() {
  local cmd="$*"
  if [ "$(id -un)" = "$DEVUSER" ]; then
    bash -lc "$cmd"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$DEVUSER" -- bash -lc "$cmd"
  else
    su -s /bin/bash "$DEVUSER" -c "$cmd"
  fi
}

# ---- Préparation de base
if ! id "$DEVUSER" >/dev/null 2>&1; then
  warn "Utilisateur $DEVUSER introuvable; utilisation de $(id -un)"
  DEVUSER="$(id -un)"
fi

sudo mkdir -p /workspaces
sudo chown -R "$DEVUSER:$DEVUSER" /workspaces || true

# ---- 1) Packages
log "Installation des paquets requis (MariaDB, Redis, wkhtmltopdf, fonts, npm/yarn, cron)"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  xfonts-75dpi xfonts-base fontconfig \
  wkhtmltopdf \
  npm \
  cron

# Yarn classic (v1)
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm i -g yarn@1
fi

# ---- 2) Services
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# Bind 127.0.0.1 pour dev
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# Fix root via socket (idempotent)
log "Configurer root MariaDB via socket (si possible)"
if sudo mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql --protocol=socket -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
else
  warn "Accès root via socket indisponible (déjà configuré ?). On continue."
fi

# ---- 3) pipx + bench (dans $HOME de $DEVUSER)
log "Installer pipx & frappe-bench (avec honcho) pour ${DEVUSER}"
as_devuser '
  set -e
  export PIPX_HOME="$HOME/.local/pipx"
  export PIPX_BIN_DIR="$HOME/.local/bin"
  export PATH="$PIPX_BIN_DIR:$HOME/.local/bin:$PATH"

  python3 -m pip install --user -U pipx
  python3 -m pipx ensurepath || true
  hash -r

  if ! pipx list | grep -q "package frappe-bench"; then
    pipx install --python "$(command -v python3.11)" frappe-bench
  fi

  # Injecter honcho (process manager) si absent
  if ! pipx runpip frappe-bench show honcho >/dev/null 2>&1; then
    pipx inject frappe-bench honcho
  fi

  bench --version
'

# ---- 4) Bench init (si absent)
log "Préparer le bench dans ${BENCH_HOME}"
sudo mkdir -p "$BENCH_HOME"
sudo chown -R "$DEVUSER:$DEVUSER" "$BENCH_HOME"

as_devuser "
  set -e
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"

  if [ ! -d '${BENCH_HOME}/apps/frappe' ]; then
    bench init --skip-redis-config-generation \
               --frappe-branch '${FRAPPE_BRANCH}' \
               --python \$(command -v python3.11) \
               '${BENCH_HOME}'
  else
    echo '[INIT] Bench déjà initialisé : ${BENCH_HOME}'
  fi
"

# ---- 5) Config + site (IMPORTANT: exécuter DANS le dossier du bench)
log "Configurer common_site_config.json et créer le site si besoin"
as_devuser "
  set -e
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"

  cd '${BENCH_HOME}'

  # Bench 5.x : passer des LITTÉRAUX PYTHON -> donc avec guillemets
  bench config set-common-config -c db_host '\"127.0.0.1\"'
  bench config set-common-config -c redis_cache '\"redis://127.0.0.1:6379\"'
  bench config set-common-config -c redis_queue '\"redis://127.0.0.1:6379\"'
  bench config set-common-config -c redis_socketio '\"redis://127.0.0.1:6379\"'

  # Si ça échoue pour une raison X, fallback JSON
  if [ \$? -ne 0 ]; then
    python3 - <<'PY'
import json, os
p = os.path.join(\"${BENCH_HOME}\", 'sites', 'common_site_config.json')
with open(p) as f: cfg=json.load(f)
cfg['db_host']='127.0.0.1'
cfg['redis_cache']='redis://127.0.0.1:6379'
cfg['redis_queue']='redis://127.0.0.1:6379'
cfg['redis_socketio']='redis://127.0.0.1:6379'
with open(p,'w') as f: json.dump(cfg,f,indent=2)
print('common_site_config.json updated (fallback)')
PY
  fi

  # Créer le site si absent (commande à lancer DANS le bench)
  if [ ! -d 'sites/${SITE_NAME}' ]; then
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password '${ADMIN_PASSWORD}' \
      --mariadb-user-host-login-scope=% \
      --force
  else
    echo '[INIT] Site déjà présent : ${SITE_NAME}'
  fi
"

# ---- 6) Start
log "Démarrage de bench (background)"
as_devuser "
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"
  cd '${BENCH_HOME}' && nohup bench start >/tmp/bench.log 2>&1 &
"

log "OK → http://localhost:8000  | Site: ${SITE_NAME}"
log "Bench : ${BENCH_HOME}       | User: ${DEVUSER}"
log "Suivi : tail -n 120 -f /tmp/bench.log"
