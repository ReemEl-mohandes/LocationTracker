#!/usr/bin/env bash
# Generates the self-signed certificate nginx serves. Run once before the first
# "docker compose up". The pair is gitignored and must never leave this machine.
set -euo pipefail

# Git Bash / MSYS rewrites any argument that looks like a POSIX path, which mangles the
# openssl -subj string into a Windows path. Both variables are ignored on Linux and macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

CERT_DIR="$(dirname "$0")/nginx/certs"
mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/server.crt" ]]; then
  echo "Certificate already exists at $CERT_DIR/server.crt - delete it to regenerate."
  exit 0
fi

# A SAN is mandatory: browsers and curl have ignored the legacy CN field for host
# matching for years, so a CN-only certificate fails verification outright.
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.crt" \
  -subj   "/C=EG/ST=Cairo/L=Cairo/O=LocationTracker/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:api,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"

echo "Wrote $CERT_DIR/server.crt and server.key (self-signed, valid 365 days)."
echo "Clients must pass -k / --insecure, or trust the certificate explicitly."
