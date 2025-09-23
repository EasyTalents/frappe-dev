#!/usr/bin/env bash
# init.sh - Frappe/Bench DEV robuste (DevContainers/Codespaces)
# Idempotent, verbeux, avec fallback honcho et gestion de ports.

set -Eeuo pipefail

### ---------- Paramètres modifiables ----------
BENCH_HOME="${BENCH_HOME:-/workspaces/frappe-bench}"
SITE_NAME="${SITE_NAME:-dev.localhost}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
SOCKETIO_PORT_DEFAULT="${SOCKETIO_PORT:-9000}"   # peut basculer sur 9001 si 9000 occupé

### ---------- Log global ----------
LOGFILE="/tmp/init_bench_$(date +%s).log"
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[ERREUR] Ligne $LINENO. Voir le log: $LOGFILE" >&2' ERR

log() { printf "\n=== %s ===\n" "$*"; }

### ---------- Utilitaires ----------
port_in_use() { ss -ltnp 2>/dev/null | grep -q ":$1"; }
kill_frappish() {
  log "Nettoyage des anciens process (bench/honcho/socketio)…"
  pkill -f 'honcho.*start'            || true
  pkill -f 'python.*bench start'      || true
  pkill -f 'node .*realtime/index.js' || true
  sleep 1
}
ensure_dir() { sudo mkdir -p "$1"; sudo chown -R "$(id -u)":"$(id -g)" "$1"; }

### ---------- 0) Contexte ----------
log "Contexte"
whoami; id; pwd
echo "LOG: $LOGFILE"

### ---------- 1) Services & prérequis ----------
log "Démarrage MariaDB & Redis"
sudo service mariadb start || sudo service mysql start || true
sudo service redis-server start || true

# Installer cron (pas bloquant si déjà présent)
sudo apt-get update -y
sudo apt-get install -y cron

### ---------- 2) Fix MDP root MariaDB (best-effort) ----------
log "Configurer root MariaDB via socket (best-effort)"
sudo mysql --protocol=socket -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
mysqladmin ping -uroot -p"${DB_ROOT_PASSWORD}" --silent || {
  echo "⚠️  mysqladmin ping a échoué — on continue (le new-site tentera avec --db-root-password)."
}

### ---------- 3) Installer pipx + bench + honcho ----------
log "Installer/configurer bench via pipx (+ honcho)"
export PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
export PATH="$PIPX_BIN_DIR:$PATH"

python3 -m pip install --user -q pipx || true
python3 -m pipx ensurepath || true
hash -r

# Bench
pipx install frappe-bench || pipx upgrade frappe-bench
bench --version

# S’assurer que honcho est dans le même venv que bench
pipx inject frappe-bench honcho >/dev/null 2>&1 || true
# Ajouter le venv pipx/bench au PATH pour que bench voie honcho
export PATH="$PIPX_BIN_DIR:$HOME/.local/pipx/venvs/frappe-bench/bin:$PATH"

echo "bench  : $(command -v bench || true)"
echo "honcho : $(command -v honcho || true)"
honcho --version || { echo "❌ honcho introuvable"; exit 1; }

### ---------- 4) Préparer /workspaces & BENCH_HOME ----------
log "Préparer répertoire bench"
ensure_dir "/workspaces"

# Si bench existant mais incomplet, on le remplace proprement
if [ -d "$BENCH_HOME" ] && [ ! -d "$BENCH_HOME/apps/frappe" ]; then
  if [ -z "$(ls -A "$BENCH_HOME")" ]; then
    rmdir "$BENCH_HOME"
  else
    TS="$(date +%s)"
    echo "Bench incomplet → sauvegarde: ${BENCH_HOME}.broken.${TS}"
    mv "$BENCH_HOME" "${BENCH_HOME}.broken.${TS}"
  fi
fi

# (Re)création bench si nécessaire
if [ ! -d "$BENCH_HOME/apps/frappe" ]; then
  PYBIN="$(command -v python3.11 || command -v python3)"
  log "bench init → $BENCH_HOME (branch ${FRAPPE_BRANCH}, python $PYBIN)"
  bench init --skip-redis-config-generation \
             --frappe-branch "${FRAPPE_BRANCH}" \
             --python "$PYBIN" \
             "$BENCH_HOME" | tee /tmp/bench_init.log
fi

log "Vérifs structure bench"
ls -la "$BENCH_HOME"
ls -la "$BENCH_HOME/apps" "$BENCH_HOME/sites"

### ---------- 5) Config DB/Redis ----------
log "Configurer DB/Redis (bench CLI modernes)"
cd "$BENCH_HOME"
bench set-mariadb-host 127.0.0.1 || true
bench set-redis-cache-host 127.0.0.1 || true
bench set-redis-queue-host 127.0.0.1 || true
bench set-redis-socketio-host 127.0.0.1 || true

### ---------- 6) Créer le site si absent ----------
log "Créer le site (${SITE_NAME}) si besoin"
if [ ! -d "sites/${SITE_NAME}" ]; then
  bench new-site "${SITE_NAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-user-host-login-scope=% \
    --force
fi

### ---------- 7) SocketIO port & collisions ----------
log "Configurer le port SocketIO"
# Porter le port par défaut
python3 - "$SOCKETIO_PORT_DEFAULT" <<'PY'
import json, sys, pathlib
port = int(sys.argv[1])
p = pathlib.Path("sites/common_site_config.json")
cfg = json.loads(p.read_text())
cfg.setdefault("socketio_port", port)
p.write_text(json.dumps(cfg, indent=1))
print("socketio_port (config) ->", cfg["socketio_port"])
PY

# Si 9000 déjà pris, bascule auto vers 9001
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
sed -n '1,160p' sites/common_site_config.json

### ---------- 8) Démarrage (Honcho direct, plus fiable que bench start) ----------
kill_frappish

# (re)libère 9000 si traîne
if port_in_use 9000; then
  echo "9000 encore occupé → kill node/socketio résiduels"
  pkill -9 -f 'node .*realtime/index.js' || true
  sleep 1
fi

log "Démarrage via Honcho"
nohup honcho -f Procfile start >/tmp/bench.log 2>&1 & disown || true
sleep 3

log "Extrait du log de démarrage"
tail -n 200 /tmp/bench.log || true

echo
echo "→ Bench: $BENCH_HOME"
echo "→ Site : http://localhost:8000  (Administrator / ${ADMIN_PASSWORD})"
echo "→ Log  : $LOGFILE  et /tmp/bench.log"
echo "OK ✅"
