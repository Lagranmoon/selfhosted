#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRAEFIK_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Traefik Init Script ==="

# Create traefik network
echo "[1/5] Creating Docker network..."
docker network create traefik 2>/dev/null || echo "Network traefik already exists"

# Create directories
echo "[2/5] Creating directory structure..."
mkdir -p "$TRAEFIK_DIR/certs"
mkdir -p "$TRAEFIK_DIR/logs"
mkdir -p "$TRAEFIK_DIR/crowdsec/config"
mkdir -p "$TRAEFIK_DIR/crowdsec/data"

# Create acme.json with proper permissions
echo "[3/5] Initializing certificate storage..."
if [ ! -f "$TRAEFIK_DIR/certs/acme.json" ]; then
    touch "$TRAEFIK_DIR/certs/acme.json"
    chmod 600 "$TRAEFIK_DIR/certs/acme.json"
    echo "Created acme.json"
else
    echo "acme.json already exists"
fi

# Check .env file
echo "[4/5] Checking environment config..."
if [ ! -f "$TRAEFIK_DIR/.env" ]; then
    echo "Warning: .env file not found"
    echo "Please copy .env.example to .env and fill in the config:"
    echo "  cp .env.example .env"
    echo "  nano .env"
else
    echo ".env file exists"
fi

# CrowdSec Bouncer API Key
echo "[5/5] CrowdSec configuration..."
echo ""
echo "After first startup, generate Bouncer API Key:"
echo "  docker exec crowdsec cscli bouncers add traefik-bouncer"
echo ""
echo "Then add the key to .env file as CROWDSEC_BOUNCER_API_KEY"
echo ""

echo "=== Init Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit .env file"
echo "  2. Run: docker compose up -d"
echo "  3. Generate CrowdSec Bouncer Key (see above)"
