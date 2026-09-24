#!/usr/bin/env bash
# One-time preparation of a fresh Ubuntu 24.04 EC2 instance, run on the instance from the
# unpacked repo:   PUBLIC_IP=<elastic ip> ./deploy/ec2-setup.sh
#
# Installs Docker, adds swap (the .NET SDK build needs more RAM than a t3 micro or small has), writes a
# production .env with freshly generated secrets, and creates a self-signed certificate that
# names the public IP. Safe to re-run: existing .env, certificate and swap are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PUBLIC_IP:?Set PUBLIC_IP to the Elastic IP of the instance}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@locationtracker.local}"

if ! command -v docker >/dev/null; then
  sudo apt-get update -q
  sudo apt-get install -y -q docker.io docker-compose-v2 openssl
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
fi

if ! swapon --show | grep -q /swapfile; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

rand() { openssl rand -base64 "$1" | tr -d '\n/+='; }

if [[ ! -f .env ]]; then
  # The admin password must satisfy the policy: 12+ chars, upper, lower, digit, symbol.
  ADMIN_PASSWORD="Adm-$(rand 12)-9x!"
  DB_PASSWORD="$(rand 32)"
  JWT_KEY="$(rand 48)"
  umask 077
  cat > .env <<ENV
POSTGRES_DB=locationtracker
POSTGRES_USER=locationtracker
POSTGRES_PASSWORD=$DB_PASSWORD

JWT_SIGNING_KEY=$JWT_KEY
JWT_ISSUER=LocationTracker
JWT_AUDIENCE=LocationTracker

SEED_ADMIN_EMAIL=$ADMIN_EMAIL
SEED_ADMIN_PASSWORD=$ADMIN_PASSWORD

CORS_ORIGIN=https://$PUBLIC_IP
ASPNETCORE_ENVIRONMENT=Production

# Public server: keep the API surface undocumented.
SWAGGER_ENABLED=false
ENV
  echo "Wrote .env (admin: $ADMIN_EMAIL / $ADMIN_PASSWORD)"
fi

CERT_EXTRA_SAN="IP:$PUBLIC_IP" ./generate-certs.sh
openssl x509 -in nginx/certs/server.crt -noout -fingerprint -sha256
