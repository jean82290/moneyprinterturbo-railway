#!/bin/bash
# Adapts MoneyPrinterTurbo to Railway, then supervises its processes.
#
#   1. Makes the volume writable for the unprivileged "mpt" user and drops root.
#   2. Resolves the web UI login and the API key (from variables, or generated
#      once and kept on the volume).
#   3. bootstrap.py writes config.toml from your variables.
#   4. Starts the web UI (Streamlit) and the API (FastAPI) on 127.0.0.1 only.
#   5. Starts Caddy on $PORT, the port Railway routes to (see the Caddyfile).
#
# If any process stops, the container stops and Railway restarts it.
#
# Variables (all optional):
#   WEBUI_USERNAME            login name for the web UI (default: admin)
#   WEBUI_PASSWORD            login password; generated and logged once if empty
#   MPT_API_KEY               API key (x-api-key header); generated and logged once if empty
#   LLM_PROVIDER, LLM_API_KEY, LLM_MODEL, LLM_BASE_URL, PEXELS_API_KEYS,
#   PIXABAY_API_KEYS          see bootstrap.py
#   MPT_TASK_RETENTION_DAYS   delete generated videos and cached footage older
#                             than this many days (default 0 = keep everything)
#   MPT_SELFTEST              1 = make one test video after start-up and report
#                             in the logs (see selftest.py)
#   PORT                      public port Railway routes to (default 8080)
#   MPT_DATA_DIR              volume mount path (default /data)
set -euo pipefail

log() { echo "mpt-railway: $*"; }
die() { echo "mpt-railway: ERROR: $*" >&2; exit 1; }

APP_DIR="${MPT_APP_DIR:-/app}"
RAILWAY_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${MPT_DATA_DIR:-/data}"
RUN_USER="${MPT_RUN_USER:-mpt}"

# --- 1. volume ownership, then drop root ------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$DATA_DIR"
  # A Railway volume shows up as a mount point. Without one, every redeploy
  # starts from scratch: settings, uploads and videos are gone.
  if ! awk -v d="$DATA_DIR" '$2 == d { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null; then
    log "WARNING: $DATA_DIR is not a mounted volume. Settings and videos will be LOST on every redeploy."
    log "WARNING: attach a Railway volume with mount path $DATA_DIR."
  fi
  run_uid="$(id -u "$RUN_USER")" || die "user $RUN_USER does not exist in the image"
  # Railway mounts volumes owned by root. Fix it once; skip the walk when the
  # volume is already ours (it can hold many gigabytes of video).
  if [ "$(stat -c %u "$DATA_DIR")" != "$run_uid" ]; then
    log "making $DATA_DIR writable for user $RUN_USER"
    chown -R "$RUN_USER:$RUN_USER" "$DATA_DIR"
  fi
  exec setpriv --reuid "$RUN_USER" --regid "$RUN_USER" --init-groups "$0" "$@"
fi

umask 077
PORT="${PORT:-8080}"
case "$PORT" in
  ''|*[!0-9]*) die "PORT must be a number, got '$PORT'" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "PORT must be between 1 and 65535, got '$PORT'"

# Internal ports, moved out of the way if Railway picked one of them as PORT.
WEBUI_PORT=8501
API_PORT=8502
[ "$WEBUI_PORT" != "$PORT" ] || WEBUI_PORT=18501
[ "$API_PORT" != "$PORT" ] || API_PORT=18502

STATE_DIR="$DATA_DIR/.railway"
mkdir -p "$STATE_DIR" "$DATA_DIR/.home"
[ -w "$DATA_DIR" ] || die "$DATA_DIR is not writable"
export HOME="$DATA_DIR/.home"
export MPT_HOME="$DATA_DIR"
export PYTHONPATH="$APP_DIR"

random_secret() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# --- 2. web UI login and API key --------------------------------------------
WEBUI_USERNAME="${WEBUI_USERNAME:-admin}"
case "$WEBUI_USERNAME" in
  *[!A-Za-z0-9._@-]*) die "WEBUI_USERNAME may only contain letters, digits and . _ @ -" ;;
esac

# stored_secret <file> <label> <length> <hint>: print the secret kept in
# <file>, creating it (and logging it once) on the first boot.
stored_secret() {
  if [ ! -s "$1" ]; then
    random_secret "$3" > "$1"
    chmod 600 "$1"
    {
      echo "mpt-railway: ============================================================"
      echo "mpt-railway: $2 was not set, so one was generated:"
      echo "mpt-railway:     $(cat "$1")"
      echo "mpt-railway: $4"
      echo "mpt-railway: It is shown only this once. It is kept in $1."
      echo "mpt-railway: ============================================================"
    } >&2
  fi
  cat "$1"
}

if [ -z "${WEBUI_PASSWORD:-}" ]; then
  WEBUI_PASSWORD="$(stored_secret "$STATE_DIR/webui-password" "WEBUI_PASSWORD" 24 \
    "Log in to the web UI as '$WEBUI_USERNAME' with it, or set the WEBUI_PASSWORD variable.")"
fi
if [ -z "${MPT_API_KEY:-}" ]; then
  MPT_API_KEY="$(stored_secret "$STATE_DIR/api-key" "MPT_API_KEY" 48 \
    "Send it as the x-api-key header to the API, or set the MPT_API_KEY variable.")"
fi
[ "${#WEBUI_PASSWORD}" -ge 8 ] || log "WARNING: WEBUI_PASSWORD is shorter than 8 characters. Anyone who guesses it can spend your API credits."

MPT_WEBUI_PASSWORD_HASH="$(printf '%s\n' "$WEBUI_PASSWORD" | caddy hash-password --algorithm bcrypt --bcrypt-cost 11)" \
  || die "could not hash WEBUI_PASSWORD"

# Session cookie value: changes whenever the login changes, survives restarts.
if [ ! -s "$STATE_DIR/session-salt" ]; then
  random_secret 48 > "$STATE_DIR/session-salt"
  chmod 600 "$STATE_DIR/session-salt"
fi
MPT_SESSION_TOKEN="$(printf '%s:%s:%s' "$(cat "$STATE_DIR/session-salt")" "$WEBUI_USERNAME" "$WEBUI_PASSWORD" | sha256sum | cut -d' ' -f1)"

# On Railway visitors always arrive over HTTPS. Elsewhere (docker run on a
# laptop) the cookie must also work over plain HTTP.
if [ -n "${RAILWAY_ENVIRONMENT_ID:-}${RAILWAY_PUBLIC_DOMAIN:-}" ] || [ "${MPT_PUBLIC_SCHEME:-}" = "https" ]; then
  MPT_PUBLIC_SCHEME=https
  MPT_COOKIE_SECURE="; Secure"
else
  MPT_PUBLIC_SCHEME=http
  MPT_COOKIE_SECURE=""
fi

export PORT MPT_API_KEY MPT_API_PORT="$API_PORT" MPT_WEBUI_PORT="$WEBUI_PORT" \
  MPT_WEBUI_USERNAME="$WEBUI_USERNAME" MPT_WEBUI_PASSWORD_HASH MPT_SESSION_TOKEN \
  MPT_PUBLIC_SCHEME MPT_COOKIE_SECURE

# --- 3. config.toml ----------------------------------------------------------
python -I "$RAILWAY_DIR/bootstrap.py" || die "could not prepare config.toml (see the messages above)"

# The apps do not need the login or the raw variables; keep them out of reach
# of anything the apps start.
unset WEBUI_PASSWORD MPT_API_KEY LLM_API_KEY PEXELS_API_KEYS PIXABAY_API_KEYS

# --- optional clean-up of old output ----------------------------------------
RETENTION_DAYS="${MPT_TASK_RETENTION_DAYS:-0}"
case "$RETENTION_DAYS" in
  ''|*[!0-9]*) die "MPT_TASK_RETENTION_DAYS must be a whole number of days, got '$RETENTION_DAYS'" ;;
esac
cleanup_old_output() {
  local dir
  for dir in "$DATA_DIR/storage/tasks" "$DATA_DIR/storage/cache_videos"; do
    [ -d "$dir" ] || continue
    find "$dir" -mindepth 1 -maxdepth 1 -mtime "+$((RETENTION_DAYS - 1))" -exec rm -rf {} + 2>/dev/null || true
  done
}

# --- 4. and 5. start everything ---------------------------------------------
pids=()
stopping=0
stop() {
  stopping=1
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap stop TERM INT

cd "$APP_DIR"
log "starting MoneyPrinterTurbo ${MPT_VERSION:-} (web UI on 127.0.0.1:$WEBUI_PORT, API on 127.0.0.1:$API_PORT, public port $PORT)"

# The apps get neither the login hash nor the session token. (exec: the
# background job must be the app itself, so the stop signal reaches it.)
run_app() { exec env -u MPT_WEBUI_PASSWORD_HASH -u MPT_SESSION_TOKEN "$@"; }

run_app python main.py &
api_pid=$!
pids+=("$api_pid")

run_app streamlit run ./webui/Main.py \
  --server.address=127.0.0.1 \
  --server.port="$WEBUI_PORT" \
  --server.headless=true \
  --server.fileWatcherType=none \
  --browser.gatherUsageStats=false \
  --client.toolbarMode=minimal \
  --logger.hideWelcomeMessage=true \
  --server.showEmailPrompt=false &
webui_pid=$!
pids+=("$webui_pid")

if [ "$RETENTION_DAYS" -gt 0 ]; then
  log "generated videos and cached footage older than $RETENTION_DAYS day(s) are deleted automatically"
  (
    trap 'exit 0' TERM INT
    while true; do
      cleanup_old_output
      sleep 3600 &
      wait $!
    done
  ) &
  pids+=("$!")
fi

# Open the public port only once both apps accept connections, so Railway's
# health check does not see proxy errors while they import their libraries.
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for _ in $(seq 1 360); do
  [ "$stopping" -eq 0 ] || break
  kill -0 "$api_pid" 2>/dev/null || die "the API stopped during start-up (see its messages above)"
  kill -0 "$webui_pid" 2>/dev/null || die "the web UI stopped during start-up (see its messages above)"
  if port_open "$WEBUI_PORT" && port_open "$API_PORT"; then
    break
  fi
  sleep 0.5
done
if [ "$stopping" -eq 1 ]; then
  wait 2>/dev/null || true
  exit 0
fi
port_open "$WEBUI_PORT" && port_open "$API_PORT" || die "the apps did not start listening within 3 minutes"

caddy run --config "$RAILWAY_DIR/Caddyfile" --adapter caddyfile &
caddy_pid=$!
pids+=("$caddy_pid")
log "ready: web UI login is '$WEBUI_USERNAME'; API docs at /docs (x-api-key header)"

# Optional end-to-end check (see selftest.py). Its result does not stop the service.
case "${MPT_SELFTEST:-}" in
  1|true|TRUE|True|yes|on)
    log "MPT_SELFTEST is set: making one test video (remove the variable afterwards)"
    (run_app python -I "$RAILWAY_DIR/selftest.py" || true) &
    ;;
esac

status=0
wait -n "$api_pid" "$webui_pid" "$caddy_pid" || status=$?
if [ "$stopping" -eq 1 ]; then
  log "stop signal received, shutting down"
else
  log "ERROR: a process exited on its own (status $status), stopping the container"
fi
stop
wait 2>/dev/null || true
if [ "$stopping" -eq 1 ]; then
  exit 0
fi
exit 1
