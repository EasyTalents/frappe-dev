#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# Frappe Dev – init.sh (mono-container, bench 5.x)
# - Installe paquets requis (dont cron), démarre MariaDB/Redis
# - Fixe le mot de passe root MariaDB via socket si possible
# - Installe pipx dans $HOME, installe 'frappe-bench' + injecte 'honcho'
# - Crée/initialise le bench dans /workspaces/frappe-bench
# - Configure common_site_config.json (localhost + redis 127.0.0.1)
# - Crée le site dev.localhost si absent
# - Démarre 'bench start' en arrière-plan
#
#   Idempotent : si relancé, il ne casse pas l'existant.
#######################################################################

### Paramètres (surchargeables via devcontainer.json -> "containerEnv")
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"           # garde 123 si tu l'as appliqué via socket

BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"
DEVUSER="${CONTAINER_USER:-vscode}"                    # utilisateur non-root du conteneur

### Helpers
log()  { printf "\n\033[1;32m[INIT]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

# Exécute une commande en tant que $DEVUSER (et évite sudo -u quand on est déjà $DEVUSER)
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

### Vérifications de base
if ! id "$DEVUSER" >/dev/null 2>&1; then
  warn "Utilisateur $DEVUSER introuvable; utilisation de l'utilisateur courant: $(id -un)"
  DEVUSER="$(id -un)"
fi

sudo mkdir -p /workspaces
sudo chown -R "$DEVUSER:$DEVUSER" /workspaces || true

### 1) Paquets système
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

### 2) Services
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# Sécurise le bind 127.0.0.1 (dev)
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi

# Fix root MariaDB via socket si possible (idempotent)
log "Configurer root MariaDB via socket (si possible)"
if sudo mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql --protocol=socket -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
else
  warn "Accès root via socket indisponible (déjà configuré ?). On continue."
fi

### 3) pipx + frappe-bench (dans le HOME de $DEVUSER)
log "Installation pipx & frappe-bench dans le HOME de ${DEVUSER} (avec honcho)"
as_devuser '
  set -e
  export PIPX_HOME="$HOME/.local/pipx"
  export PIPX_BIN_DIR="$HOME/.local/bin"
  export PATH="$PIPX_BIN_DIR:$HOME/.local/bin:$PATH"

  python3 -m pip install --user -U pipx
  python3 -m pipx ensurepath || true
  hash -r

  # (Ré)installe bench avec Python 3.11 et injecte honcho (process manager)
  if pipx list | grep -q "package frappe-bench"; then
    : # laissé tel quel; on garde l’install existante
  else
    pipx install --python "$(command -v python3.11)" --force frappe-bench
  fi
  # inject honcho si pas déjà présent
  if ! pipx runpip frappe-bench show honcho >/dev/null 2>&1; then
    pipx inject frappe-bench honcho
  fi

  bench --version
'

### 4) Bench init
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

### 5) Config mono-conteneur + création du site (bench 5.x)
log "Configurer common_site_config.json et créer le site si besoin"
as_devuser "
  set -e
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"

  cd '${BENCH_HOME}'

  # bench 5.x : set-common-config
  bench config set-common-config -c db_host 127.0.0.1 || true
  bench config set-common-config -c redis_cache    'redis://127.0.0.1:6379' || true
  bench config set-common-config -c redis_queue    'redis://127.0.0.1:6379' || true
  bench config set-common-config -c redis_socketio 'redis://127.0.0.1:6379' || true

  # Créer le site si absent
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

### 6) Démarrage bench
log "Démarrage de bench (background)"
as_devuser "
  export PIPX_HOME=\"\$HOME/.local/pipx\"
  export PIPX_BIN_DIR=\"\$HOME/.local/bin\"
  export PATH=\"\$PIPX_BIN_DIR:\$HOME/.local/bin:\$PATH\"
  cd '${BENCH_HOME}' && nohup bench start >/tmp/bench.log 2>&1 &
"

log "OK → http://localhost:8000"
log "Site : ${SITE_NAME} | Bench : ${BENCH_HOME} | User : ${DEVUSER}"
log "Suivi : tail -n 120 -f /tmp/bench.log"
