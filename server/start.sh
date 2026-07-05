#!/usr/bin/env bash
#
# Start the Compass server as a background process.
# Safe to run repeatedly — it won't start a second copy.
#
#   ./start.sh              # starts on port 4000
#   PORT=8080 ./start.sh    # starts on a custom port
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

# Already running?
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Compass server already running (PID $(cat "$PIDFILE"))."
  exit 0
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
