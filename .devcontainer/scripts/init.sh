#!/usr/bin/env bash
# init.sh - Setup Frappe Bench (robuste, idempotent, logs)
set -Eeuo pipefail

### ---- Paramètres ----
DEVELOPMENT_ROOT="${DEVELOPMENT_ROOT:-/workspace/development}"
BENCH_NAME="${BENCH_NAME:-frappe-bench}"
BENCH_HOME="${BENCH_HOME:-${DEVELOPMENT_ROOT}/${BENCH_NAME}}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
SOCKETIO_PORT_DEFAULT="${SOCKETIO_PORT:-9000}"  # auto-bascule vers 9001 si 9000 occupé

### ---- Logs ----
LOGFILE="/tmp/init_bench_$(date +%s).log"
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[ERREUR] Ligne $LINENO. Voir le log: $LOGFILE" >&2' ERR
log(){ printf "\n=== %s ===\n" "$*"; }

### ---- Utils ----
ensure_dir(){ sudo mkdir -p "$1"; sudo chown -R "$(id -u)":"$(id -g)" "$1"; }
port_in_use(){ ss -ltnp 2>/dev/null | grep -q ":$1"; }
kill_frappish(){ 
  log "Nettoyage processus (bench/honcho/socketio)…"
  pkill -f 'honcho.*start'            || true
  pkill -f 'python.*bench start'      || true
  pkill -f 'node .*realtime/index.js' || true
  sleep 1
}

### ---- 0) Contexte ----
log "Contexte"
whoami; id; pwd
echo "LOG: $LOGFILE"

### ---- 1) OS & prérequis (MariaDB/Redis si absents) ----
log "Packages & services (MariaDB/Redis)"
sudo apt-get update -y
# Installe si nécessaire (sans forcer si déjà là)
if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client
fi
if ! command -v redis-server >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
fi
sudo apt-get install -y cron

# Démarrage services (best-effort)
sudo service mariadb start  || true
sudo service mysql start    || true
sudo service redis-server start || true

### ---- 2) Fix MDP root MariaDB (best-effort, auto-détection client) ----
log "Configurer root MariaDB (best-effort)"
MYSQL_CLI="$(command -v mysql || command -v mariadb || true)"
MYSQLADMIN_CLI="$(command -v mysqladmin || command -v mariadb-admin || true)"
if [ -n "${MYSQL_CLI}" ]; then
  sudo "${MYSQL_CLI}" --protocol=socket -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
fi
if [ -n "${MYSQLADMIN_CLI}" ]; then
  "${MYSQLADMIN_CLI}" ping -uroot -p"${DB_ROOT_PASSWORD}" --silent || echo "⚠️  ping root KO (on passera --db-root-password au new-site)"
fi

### ---- 3) pipx utilisateur + bench + honcho ----
log "pipx utilisateur + bench + honcho"
export PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
export PATH="$PIPX_BIN_DIR:$PATH"

python3 -m pip install --user -q --upgrade pipx || true
python3 -m pipx ensurepath || true
hash -r

# IMPORTANT : utiliser le pipx UTILISATEUR, pas celui de /usr/local/py-utils
USER_PIpx="$HOME/.local/bin/pipx"
if [ ! -x "$USER_PIpx" ]; then
  echo "❌ pipx utilisateur introuvable à $USER_PIpx"
  exit 1
fi

"$USER_PIpx" install frappe-bench || "$USER_PIpx" upgrade frappe-bench
"$USER_PIpx" inject frappe-bench honcho >/dev/null 2>&1 || true

# Ajouter le venv bench pipx au PATH (pour honcho & bench)
export PATH="$HOME/.local/pipx/venvs/frappe-bench/bin:$PATH"

echo "bench  -> $(command -v bench || echo 'absent')"
echo "honcho -> $(command -v honcho || echo 'absent')"
honcho --version >/dev/null || { echo "❌ honcho indisponible"; exit 1; }
bench --version >/dev/null  || { echo "❌ bench indisponible";  exit 1; }

### ---- 4) Préparer répertoires ----
log "Préparer development & BENCH_HOME"
ensure_dir "$DEVELOPMENT_ROOT"

# Si BENCH_HOME existe mais incomplet → backup & recrée
if [ -d "$BENCH_HOME" ] && [ ! -d "$BENCH_HOME/apps/frappe" ]; then
  if [ -z "$(ls -A "$BENCH_HOME")" ]; then
    rmdir "$BENCH_HOME"
  else
    TS="$(date +%s)"
    mv "$BENCH_HOME" "${BENCH_HOME}.broken.${TS}"
  fi
fi

# bench init si nécessaire
if [ ! -d "$BENCH_HOME/apps/frappe" ]; then
  PYBIN="$(command -v python3.11 || command -v python3)"
  log "bench init → $BENCH_HOME (branch ${FRAPPE_BRANCH}, python $PYBIN)"
  (cd "$DEVELOPMENT_ROOT" && \
    bench init --skip-redis-config-generation \
               --frappe-branch "${FRAPPE_BRANCH}" \
               --python "$PYBIN" \
               "$BENCH_NAME") | tee /tmp/bench_init.log
fi

log "Vérifs structure bench"
ls -la "$BENCH_HOME"
ls -la "$BENCH_HOME/apps" "$BENCH_HOME/sites"

### ---- 5) Config DB/Redis ----
log "Configurer DB/Redis (bench set-config -g)"
cd "$BENCH_HOME"
bench set-config -g db_host mariadb || true
bench set-config -g redis_cache redis://redis-cache:6379 || true
bench set-config -g redis_queue redis://redis-queue:6379 || true
bench set-config -g redis_socketio redis://redis-queue:6379 || true

### ---- 5 bis) Procfile sans Redis ----
log "Nettoyer Procfile (suppression entrées Redis)"
sed -i '/redis/d' Procfile || true

### ---- 6) Créer le site si absent ----
log "Créer le site ${SITE_NAME} si besoin"
if [ ! -d "sites/${SITE_NAME}" ]; then
  bench new-site "${SITE_NAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-user-host-login-scope=% \
    --force
fi

### ---- 7) Port SocketIO & bascule auto 9000→9001 si occupé ----
log "Configurer SocketIO port"
python3 - "$SOCKETIO_PORT_DEFAULT" <<'PY'
import json, sys, pathlib
port = int(sys.argv[1])
p = pathlib.Path("sites/common_site_config.json")
cfg = json.loads(p.read_text())
cfg.setdefault("socketio_port", port)
p.write_text(json.dumps(cfg, indent=1))
print("socketio_port (config) ->", cfg["socketio_port"])
PY

if port_in_use 9000; then
  echo "Port 9000 occupé → bascule sur 9001"
  python3 - <<'PY'
import json, pathlib
p = pathlib.Path("sites/common_site_config.json")
cfg = json.loads(p.read_text())
cfg["socketio_port"] = 9001
p.write_text(json.dumps(cfg, indent=1))
print("socketio_port ->", cfg["socketio_port"])
PY
fi

log "common_site_config.json (aperçu)"
sed -n '1,160p' sites/common_site_config.json || true

### ---- 8) Démarrage via honcho (plus fiable que bench start) ----
kill_frappish
# tente de libérer 9000 s'il traîne encore
if port_in_use 9000; then pkill -9 -f 'node .*realtime/index.js' || true; fi

log "Démarrage via honcho"
nohup honcho -f Procfile start >/tmp/bench.log 2>&1 & disown || true
sleep 3

log "Extrait /tmp/bench.log"
tail -n 200 /tmp/bench.log || true

echo
echo "→ Bench: $BENCH_HOME"
echo "→ Site : http://localhost:8000  (Administrator / ${ADMIN_PASSWORD})"
echo "→ Logs : $LOGFILE  et /tmp/bench.log"
echo "OK ✅"
