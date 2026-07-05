# Deploying the Compass server to Contabo

> **Already running Caddy on this server?** Skip the nginx steps below. Just run
> `./setup.sh` (adds a `payrollgm.com` block to your Caddyfile and reloads Caddy
> — it auto-provisions HTTPS), then `./start.sh`. The Node server binds to
> `127.0.0.1:4000`, private behind Caddy. The nginx walkthrough below is only for
> a server that has *no* web server yet.

---


The app requires **HTTPS** (iOS blocks plain HTTP on a public domain). The Node
server itself speaks plain HTTP; we put **nginx** in front to terminate TLS,
with a free certificate from **Let's Encrypt**. One-time setup, then day-to-day
you just use `./start.sh` / `./restart.sh`.

## 0. Prerequisites
- A domain (or subdomain, e.g. `api.yourdomain.com`) with an **A record**
  pointing at your Contabo server's IP.
- SSH access to the server (Ubuntu assumed below).

## 1. Install Node
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
```

## 2. Copy the app up and start it
```bash
# from your Mac, in the Compass project root:
scp -r server user@YOUR_SERVER_IP:~/compass-server

# on the server:
cd ~/compass-server
./start.sh          # runs the Node server on http://127.0.0.1:4000
```
`data.json` (your database) lives in this folder. Back it up by copying that file.

## 3. Put nginx + HTTPS in front
```bash
sudo apt-get install -y nginx
```
Create `/etc/nginx/sites-available/compass`:
```nginx
server {
    server_name api.yourdomain.com;   # <- your domain
    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```
Enable it and add the certificate:
```bash
sudo ln -s /etc/nginx/sites-available/compass /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d api.yourdomain.com    # auto-configures HTTPS + renewal
```
Now `https://api.yourdomain.com/health` should return `{"ok":true}`.

## 4. Point the app at it
In `Compass/APIClient.swift`, set the non-Simulator `baseURL` to
`https://api.yourdomain.com`, then build to your device.

## 5. Keep it running across reboots (optional but recommended)
`start.sh` uses `nohup`, which survives your SSH session but **not a server
reboot**. For auto-start on boot, use a tiny systemd service:

`/etc/systemd/system/compass.service`:
```ini
[Unit]
Description=Compass server
After=network.target

[Service]
WorkingDirectory=/home/YOUR_USER/compass-server
ExecStart=/usr/bin/node server.js
Restart=always
Environment=PORT=4000

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl enable --now compass
```
(If you use systemd, manage it with `systemctl restart compass` instead of the
scripts. The scripts remain handy for quick manual runs / non-systemd setups.)

## Day-to-day
```bash
./start.sh      # start (no-op if already running)
./restart.sh    # restart after pushing new code
tail -f server.log
```
