#!/usr/bin/env bash
# Frappe Dev (mono-container) — init.sh
# Idempotent, verbeux, avec diagnostics. Conçu pour VS Code Devcontainer / Coder.
set -euo pipefail

#############################
# Journal & helpers
#############################
LOGFILE=${LOGFILE:-/tmp/init.log}
mkdir -p "$(dirname "$LOGFILE")"
# journaliser stdout/stderr vers le fichier et la console
exec > >(tee -a "$LOGFILE") 2>&1

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
section(){ printf "\n${BLU}==> %s${RST}\n" "$*"; }
ok(){ printf "${GRN}[OK]${RST} %s\n" "$*"; }
warn(){ printf "${YLW}[WARN]${RST} %s\n" "$*"; }
fail(){ printf "${RED}[FAIL]${RST} %s\n" "$*"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { fail "Commande manquante: $1"; return 1; }; }

#############################
# Paramètres (surchageables)
#############################
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# Bench sous /workspaces
BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"

# Utilisateur dev (devcontainer par défaut)
DEVUSER="${CONTAINER_USER:-vscode}"
id "$DEVUSER" >/dev/null 2>&1 || DEVUSER="vscode"

# Forcer pipx dans le HOME de l’utilisateur (évite /usr/local/py-utils)
export PIPX_HOME="${PIPX_HOME:-/home/${DEVUSER}/.local/pipx}"
export PIPX_BIN_DIR="${PIPX_BIN_DIR:-/home/${DEVUSER}/.local/bin}"
export PATH="$PIPX_BIN_DIR:$PATH"

section "Contexte"
echo "LOGFILE        : $LOGFILE"
echo "DEVUSER        : $DEVUSER"
echo "FRAPPE_BRANCH  : $FRAPPE_BRANCH"
echo "BENCH_HOME     : $BENCH_HOME"
echo "SITE_NAME      : $SITE_NAME"
echo "DB_ROOT_USER   : $DB_ROOT_USER"
echo "DB_ROOT_PASS   : (masqué)"

#############################
# Paquets système
#############################
section "Installation des prérequis système"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  cron mariadb-server redis-server \
  curl git build-essential \
  python3.11-venv python3.11-dev python3-pip \
  xfonts-75dpi xfonts-base fontconfig wkhtmltopdf

# Yarn classic requis par Frappe v15
if ! command -v yarn >/dev/null 2>&1; then
  sudo npm i -g yarn@1
fi
ok "Pré-requis installés"

#############################
# Services (MariaDB, Redis)
#############################
section "Démarrage des services MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# bind 127.0.0.1 (sécurisant & prévisible)
if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
  sudo sed -i 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  sudo service mariadb restart || true
fi
ok "Services démarrés (ou déjà actifs)"

#############################
# MariaDB root : fixer le mot de passe
#############################
section "Configuration root MariaDB"
set +e
# 1) essai ping sans mot de passe (nouvelle install typique)
mysqladmin ping -uroot --silent
NO_PWD_OK=$?
# 2) essai ping avec mot de passe fourni
mysqladmin ping -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" --silent
WITH_PWD_OK=$?
set -e

if [ $WITH_PWD_OK -ne 0 ]; then
  warn "mysqladmin ping avec mot de passe a échoué → tentative via socket pour définir le MDP"
  sudo mysql --protocol=socket -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
  # reteste
  if mysqladmin ping -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" --silent; then
    ok "root MariaDB authentifiable avec le mot de passe fourni"
  else
    warn "Impossible de valider l'authent root MariaDB maintenant, on continue (bench new-site demandera --db-root-password)."
  fi
else
  ok "root MariaDB accessible (sans mot de passe) — MDP sera appliqué lors du new-site si besoin"
fi

#############################
# pipx + bench (dans $DEVUSER)
#############################
section "Installation de bench via pipx (utilisateur: ${DEVUSER})"
sudo -u "$DEVUSER" -H bash -lc '
  set -euo pipefail
  export PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
  export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
  export PATH="$PIPX_BIN_DIR:$PATH"
  python3 -m pip install --user -q pipx || true
  python3 -m pipx ensurepath || true
  hash -r
  pipx install frappe-bench || pipx upgrade frappe-bench
  # bench start a besoin d’honcho
  pipx inject frappe-bench honcho >/dev/null 2>&1 || true
  bench --version
'
ok "bench installé pour ${DEVUSER}"

#############################
# Bench: détecter / corriger un dossier cassé
#############################
section "Vérification existence / validité du bench"
if [ -d "$BENCH_HOME" ]; then
  # bench valide = au minimum apps et sites existent après init
  if [ ! -d "$BENCH_HOME/apps" ] || [ ! -d "$BENCH_HOME/sites" ]; then
    warn "Bench détecté mais incomplet → déplacement de sauvegarde"
    mv -v "$BENCH_HOME" "${BENCH_HOME}.broken.$(date +%s)" || true
  fi
fi

#############################
# bench init (si absent)
#############################
if [ ! -d "$BENCH_HOME" ]; then
  section "Initialisation du bench (bench init) → $BENCH_HOME"
  sudo mkdir -p "$BENCH_HOME"
  sudo chown -R "$DEVUSER:$DEVUSER" "$(dirname "$BENCH_HOME")"

  sudo -u "$DEVUSER" -H bash -lc "
    set -euo pipefail
    export PATH=\"$PIPX_BIN_DIR:\$PATH\"
    bench init --skip-redis-config-generation \
               --frappe-branch '${FRAPPE_BRANCH}' \
               --python \$(command -v python3.11) \
               '${BENCH_HOME}'
  "
  ok "bench init terminé"
else
  ok "Bench déjà présent : $BENCH_HOME"
fi

#############################
# Config commune + création site
#############################
section "Configuration common_site_config.json et création du site"
sudo -u "$DEVUSER" -H bash -lc "
  set -euo pipefail
  export PATH=\"$PIPX_BIN_DIR:\$PATH\"
  cd '${BENCH_HOME}'
  mkdir -p sites
  [ -f sites/common_site_config.json ] || printf '{}\n' > sites/common_site_config.json

  # IMPORTANT : bench config set-common-config attend des valeurs Python (quotes nécessaires)
  bench config set-common-config -c db_host '\"127.0.0.1\"'
  bench config set-common-config -c redis_cache '\"redis://127.0.0.1:6379\"'
  bench config set-common-config -c redis_queue '\"redis://127.0.0.1:6379\"'
  bench config set-common-config -c redis_socketio '\"redis://127.0.0.1:6379\"'

  if [ ! -d 'sites/${SITE_NAME}' ]; then
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password '${ADMIN_PASSWORD}' \
      --mariadb-user-host-login-scope=% \
      --force
  fi
"
ok "Config bench + site OK"

#############################
# Démarrage background + diagnostics
#############################
section "Démarrage bench (background) et diagnostics"
sudo -u "$DEVUSER" -H bash -lc "
  set -euo pipefail
  export PATH=\"$PIPX_BIN_DIR:\$PATH\"
  cd '${BENCH_HOME}'
  if ! pgrep -f 'honcho|bench start' >/dev/null 2>&1; then
    nohup bench start >/tmp/bench.log 2>&1 &
    sleep 2
  fi
"

# Diagnostics
DIAG_OK=1

echo
echo "----- DIAGNOSTICS -----"
if sudo -u "$DEVUSER" -H bash -lc "test -d '$BENCH_HOME/apps' && test -d '$BENCH_HOME/sites'"; then
  ok "Bench structure OK ($BENCH_HOME)"
else
  DIAG_OK=0; fail "Bench structure incomplète ($BENCH_HOME)"
fi

if mysqladmin ping -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" --silent; then
  ok "MariaDB: ping avec credentials OK"
else
  warn "MariaDB: ping avec credentials NON OK (si le site est créé, ce n’est plus bloquant)"
fi

if command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
  ok "Redis: ping OK"
else
  warn "Redis: ping KO (vérifier service, mais bench peut démarrer si service redis est up)"
fi

if ss -ltn '( sport = :8000 )' 2>/dev/null | grep -q 8000; then
  ok "Port 8000 à l'écoute (bench web)"
else
  warn "Port 8000 pas encore à l'écoute (bench en cours de démarrage ?)"
fi

sudo -u "$DEVUSER" -H bash -lc "tail -n 60 /tmp/bench.log || true"

echo "-----------------------"
if [ $DIAG_OK -eq 1 ]; then
  ok "INIT terminé. Frappe sur http://localhost:8000 (site: $SITE_NAME)"
  echo "Journal complet : $LOGFILE"
else
  fail "INIT terminé avec des avertissements/erreurs. Voir $LOGFILE"
  exit 1
fi
