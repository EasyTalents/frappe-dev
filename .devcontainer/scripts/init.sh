#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Frappe Dev – init.sh (mono-container, fidèle à development.md)
# - bench init --skip-redis-config-generation
# - bench set-config -g (localhost/127.0.0.1)
# - bench new-site … --mariadb-user-host-login-scope=%
# - Bench & site sous /workspaces/frappe-bench
########################################################################

# ========= Variables (surchargeables via devcontainer.json) =========
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Mot de passe root MariaDB (doit correspondre à ce que tu mets dans new-site)
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# App custom (facultatif)
CUSTOM_APP_URL="${CUSTOM_APP_URL:-}"          # vide => pas d'app
CUSTOM_APP_BRANCH="${CUSTOM_APP_BRANCH:-develop}"

# Dossier du bench
BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"

# Utilisateur non-root souhaité par le devcontainer
DEVUSER="${CONTAINER_USER:-vscode}"

# ========= Helpers =========
log()  { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

# Exécuter en tant que DEVUSER (sans dépendre de sudoers)
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

# Assure l'existence de DEVUSER (au cas où)
if ! id "$DEVUSER" >/dev/null 2>&1; then
  warn "Utilisateur $DEVUSER introuvable, utilisation de l'utilisateur courant: $(id -un)"
  DEVUSER="$(id -un)"
fi

# ========= Pré-requis système =========
log "Installation des paquets requis (MariaDB, Redis, wkhtmltopdf, fonts, Node/Yarn, cron)"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  xfonts-75dpi xfonts-base fontconfig \
  wkhtmltopdf \
  cron

# Yarn 1.x (classic) – requis pour Frappe v15
if ! command -v yarn >/dev/null 2>&1; then
  if command -v npm >/dev/null 2>&1; then
    sudo npm i -g yarn@1
  else
    warn "npm introuvable, tentative d'installation..."
    sudo apt-get install -y npm || true
    sudo npm i -g yarn@1 || true
  fi
fi

# ========= Démarrer Services =========
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# MariaDB : ajuster bind-address (sécurité dev) + restart
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# Config root MariaDB via socket (tolérant)
log "Configurer root MariaDB via socket (si possible)"
if sudo mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql --protocol=socket -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
else
  warn "Accès root via socket indisponible (environnement déjà configuré ?). On continue."
fi

# ========= pipx + frappe-bench (dans le HOME de DEVUSER) =========
log "Installer/mettre à jour pipx & frappe-bench pour ${DEVUSER} (dans \$HOME)"
as_devuser '
  set -e
  export PIPX_HOME="$HOME/.local/pipx"
  export PIPX_BIN_DIR="$HOME/.local/bin"
  export PATH="$PIPX_BIN_DIR:$HOME/.local/bin:$PATH"

  # pipx utilisateur
  python3 -m pip install --user -U pipx
  python3 -m pipx ensurepath || true
  hash -r

  # (ré)installe bench avec Python 3.11 et injecte honcho (process manager)
  pipx uninstall frappe-bench || true
  pipx install --python "$(command -v python3.11)" --force frappe-bench
  pipx inject frappe-bench honcho

  bench --version
'

# ========= bench init --skip-redis-config-generation =========
log "Préparer le bench (init) dans ${BENCH_HOME}"
sudo mkdir -p "$BENCH_HOME"
sudo chown -R "$DEVUSER:$DEVUSER" /workspaces

as_devuser "
  set -e
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"
  export BENCH_HOME='${BENCH_HOME}'

  # 1) bench init (doc) avec --skip-redis-config-generation
  if [ ! -d \"\${BENCH_HOME}/apps/frappe\" ]; then
    bench init --skip-redis-config-generation \
               --frappe-branch '${FRAPPE_BRANCH}' \
               --python \$(command -v python3.11) \
               \"\${BENCH_HOME}\"
  fi

  cd \"\${BENCH_HOME}\"

  # 2) Config mono-container: tout en local
  bench set-config -g db_host 127.0.0.1 || true
  bench set-config -g redis_cache    redis://127.0.0.1:6379 || true
  bench set-config -g redis_queue    redis://127.0.0.1:6379 || true
  bench set-config -g redis_socketio redis://127.0.0.1:6379 || true

  # 3) Créer le site si absent (avec scope %)
  if [ ! -d 'sites/${SITE_NAME}' ]; then
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password '${ADMIN_PASSWORD}' \
      --mariadb-user-host-login-scope=% \
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
as_devuser "
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"
  cd '${BENCH_HOME}' && nohup bench start >/tmp/bench.log 2>&1 &
"

log "OK → http://localhost:8000"
log "Site: ${SITE_NAME} | Bench: ${BENCH_HOME} | User: ${DEVUSER}"
log "Suivi des logs : tail -n 120 -f /tmp/bench.log"
