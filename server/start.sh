#!/usr/bin/env bash
#
# Start the Compass Node server as a private background process on
# 127.0.0.1:PORT. Your web server (Caddy) sits in front and serves HTTPS —
# that's a one-time thing configured by ./setup.sh. Safe to run repeatedly.
#
#   ./start.sh              # starts on port 4000
#   PORT=8080 ./start.sh    # custom port (match it in the Caddyfile)
#
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE="server.pid"
LOG="server.log"
PORT="${PORT:-4000}"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed. Install it first (e.g. https://nodejs.org)."
  exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Compass server already running (PID $(cat "$PIDFILE"))."
  exit 0
fi

PORT="$PORT" nohup node server.js >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 1

if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Started Compass server (PID $(cat "$PIDFILE")) on 127.0.0.1:$PORT."
  echo "Logs: $(pwd)/$LOG"
else
  echo "Failed to start — last log lines:"
  tail -n 20 "$LOG" || true
  rm -f "$PIDFILE"
  exit 1
fi
