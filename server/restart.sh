#!/usr/bin/env bash
#
# Stop the Compass server (if running) and start it again.
#
#   ./restart.sh
#   PORT=8080 ./restart.sh
#
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE="server.pid"

if [ -f "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Stopping Compass server (PID $PID)…"
    kill "$PID" 2>/dev/null || true
    # Wait up to ~5s for a graceful exit, then force.
    for _ in $(seq 1 10); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
fi

exec ./start.sh
