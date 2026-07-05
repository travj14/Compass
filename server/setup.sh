#!/usr/bin/env bash
#
# ONE-TIME server setup: install nginx + certbot, put nginx in front of the
# Node server, and get a free HTTPS certificate. Idempotent — safe to re-run
# (it skips anything already done; certbot won't re-issue a valid cert).
#
# Run this ONCE on your Contabo server:
#     ./setup.sh
#
# Optional overrides:
#     DOMAIN=api.payrollgm.com EMAIL=you@example.com ./setup.sh
#
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${DOMAIN:-payrollgm.com}"
PORT="${PORT:-4000}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This setup script targets Debian/Ubuntu (Contabo default). Aborting."
  exit 1
fi

echo "==> Installing nginx + certbot (if missing)…"
command -v nginx   >/dev/null 2>&1 || { $SUDO apt-get update && $SUDO apt-get install -y nginx; }
command -v certbot >/dev/null 2>&1 || $SUDO apt-get install -y certbot python3-certbot-nginx

echo "==> Writing nginx reverse-proxy config for $DOMAIN…"
CONF=/etc/nginx/sites-available/compass
$SUDO tee "$CONF" >/dev/null <<EOF
server {
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
$SUDO ln -sf "$CONF" /etc/nginx/sites-enabled/compass
$SUDO nginx -t
# Start nginx (and enable on boot); restart applies the config whether or not
# it was already running.
$SUDO systemctl enable nginx >/dev/null 2>&1 || true
$SUDO systemctl restart nginx

echo "==> Requesting HTTPS certificate (certbot)…"
if [ -n "${EMAIL:-}" ]; then EMAIL_ARG="-m $EMAIL"; else EMAIL_ARG="--register-unsafely-without-email"; fi
$SUDO certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos $EMAIL_ARG --redirect || {
  echo "certbot step didn't complete — check that DNS for $DOMAIN points here and port 80/443 are open."
}

echo
echo "Done. Now start the app server with ./start.sh"
echo "Verify: https://$DOMAIN/health   (should return {\"ok\":true})"
