#!/usr/bin/env bash
#
# Start the Compass server (Node) and, on a web host, make sure nginx — the
# HTTPS front-end — is running too. Safe to run repeatedly.
#
#   ./start.sh              # starts on port 4000
#   PORT=8080 ./start.sh    # custom port
#
# One-time HTTPS setup lives in ./setup.sh (run that once on the server first).
#
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE="server.pid"
LOG="server.log"
PORT="${PORT:-4000}"

# Make sure nginx is up (only on a real web host; skipped on your Mac).
ensure_nginx() {
  command -v nginx >/dev/null 2>&1 || return 0      # no nginx here → nothing to do
  command -v systemctl >/dev/null 2>&1 || return 0
  local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  if ! $SUDO systemctl is-active --quiet nginx; then
    echo "Starting nginx…"
    $SUDO systemctl start nginx || true
  fi
  $SUDO systemctl reload nginx 2>/dev/null || true
  echo "nginx (HTTPS front-end) is up."
}

start_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js is not installed. Install it first (e.g. https://nodejs.org)."
    exit 1
  fi
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Compass server already running (PID $(cat "$PIDFILE"))."
    return 0
  fi
  PORT="$PORT" nohup node server.js >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Started Compass server (PID $(cat "$PIDFILE")) on port $PORT."
    echo "Logs: $(pwd)/$LOG"
  else
    echo "Failed to start — last log lines:"
    tail -n 20 "$LOG" || true
    rm -f "$PIDFILE"
    exit 1
  fi
}

start_node
ensure_nginx
