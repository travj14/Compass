#!/usr/bin/env bash
#
# ONE-TIME setup for a server already running Caddy on 80/443.
# Adds a Compass site block to your Caddyfile and reloads Caddy, which then
# fetches and auto-renews the HTTPS certificate for the domain. Idempotent.
#
#   ./setup.sh
#
# Optional overrides:
#   DOMAIN=api.payrollgm.com PORT=4000 CADDYFILE=/etc/caddy/Caddyfile ./setup.sh
#
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${DOMAIN:-payrollgm.com}"
PORT="${PORT:-4000}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

if ! command -v caddy >/dev/null 2>&1; then
  echo "Caddy not found on PATH. Is this the right server?"
  exit 1
fi
if [ ! -f "$CADDYFILE" ]; then
  echo "No Caddyfile at $CADDYFILE. Set CADDYFILE=/path/to/Caddyfile and re-run."
  exit 1
fi

if $SUDO grep -q "^[[:space:]]*$DOMAIN[[:space:]]*{" "$CADDYFILE"; then
  echo "$DOMAIN is already in $CADDYFILE — leaving your config untouched."
else
  echo "Adding a Compass block for $DOMAIN to $CADDYFILE…"
  $SUDO cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"   # backup first
  $SUDO tee -a "$CADDYFILE" >/dev/null <<EOF

$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
fi

echo "Validating Caddyfile…"
$SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile

echo "Reloading Caddy…"
$SUDO systemctl reload caddy 2>/dev/null \
  || $SUDO caddy reload --config "$CADDYFILE" 2>/dev/null \
  || { echo "Couldn't reload Caddy automatically — reload it however you normally do."; }

echo
echo "Done. Caddy will auto-provision HTTPS (may take a few seconds on first hit)."
echo "Then start the app server:  ./start.sh"
echo "Verify:  curl https://$DOMAIN/health   ->  {\"ok\":true}"
