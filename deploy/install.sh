#!/usr/bin/env bash
# LiveWire server install for Ubuntu 24.04 (1–2 vCPU, 2 GB RAM is plenty).
#
#   git clone <repo> && cd <repo>
#   sudo bash deploy/install.sh scanner.example.com
#
# Installs ffmpeg / python venv / caddy / espeak-ng, copies the code to
# /opt/livewire, creates a venv with the hosted-transcription requirements
# (no torch), writes /opt/livewire/.env from .env.example with a random
# API_TOKEN, installs and starts both systemd services, and configures Caddy
# for HTTPS on the given domain. Re-running is safe: code is refreshed, .env
# is kept.
set -euo pipefail

DOMAIN="${1:-${LIVEWIRE_DOMAIN:-}}"
APP_DIR=/opt/livewire
APP_USER=livewire
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo bash deploy/install.sh <domain>" >&2
  exit 1
fi

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ffmpeg python3-venv python3-pip espeak-ng rsync curl ca-certificates
if ! apt-get install -y caddy; then
  echo "    caddy not in apt; adding the official repository"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

echo "==> user + code"
id -u "$APP_USER" &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"
rsync -a --delete \
  --exclude .git --exclude .venv --exclude data --exclude ios --exclude __pycache__ --exclude .env \
  "$REPO_DIR/" "$APP_DIR/"
mkdir -p "$APP_DIR/data/audio"

echo "==> python venv (hosted transcription; no torch)"
[[ -d "$APP_DIR/.venv" ]] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip wheel
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

echo "==> .env"
if [[ ! -f "$APP_DIR/.env" ]]; then
  cp "$APP_DIR/deploy/.env.example" "$APP_DIR/.env"
  TOKEN="$(openssl rand -hex 24 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(24))')"
  sed -i "s|^API_TOKEN=.*|API_TOKEN=${TOKEN}|" "$APP_DIR/.env"
  echo "    wrote $APP_DIR/.env with a fresh API_TOKEN — fill in the remaining values"
else
  echo "    keeping existing $APP_DIR/.env"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env"

echo "==> systemd"
install -m 644 "$APP_DIR/deploy/livewire-ingest.service" /etc/systemd/system/livewire-ingest.service
install -m 644 "$APP_DIR/deploy/livewire-api.service" /etc/systemd/system/livewire-api.service
systemctl daemon-reload
systemctl enable --now livewire-api.service
systemctl enable --now livewire-ingest.service
systemctl restart livewire-api.service livewire-ingest.service

echo "==> caddy"
if [[ -n "$DOMAIN" ]]; then
  sed "s|REPLACE_ME_DOMAIN|${DOMAIN}|" "$APP_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
  echo "    https://${DOMAIN}/api/health (Caddy obtains the certificate automatically)"
else
  echo "    no domain given; copy deploy/Caddyfile to /etc/caddy/Caddyfile and set your domain"
fi

echo
echo "Done. Services: systemctl status livewire-api livewire-ingest"
echo "API token:  $(grep '^API_TOKEN=' "$APP_DIR/.env" | cut -d= -f2-)"
echo "Next:       edit $APP_DIR/.env (STREAM_URL, GROQ_API_KEY, ANTHROPIC_API_KEY, APNS_*), then"
echo "            systemctl restart livewire-ingest livewire-api"
echo "Check:      curl -H 'Authorization: Bearer <token>' https://${DOMAIN:-<host>}/api/health"
