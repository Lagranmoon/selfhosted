#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENWEBUI_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Open WebUI Init Script ==="

# Create data directories
echo "[1/4] Creating data directories..."
mkdir -p "$OPENWEBUI_DIR/data/openwebui"
mkdir -p "$OPENWEBUI_DIR/data/postgres"

# Check .env file
echo "[2/4] Checking environment config..."
if [ ! -f "$OPENWEBUI_DIR/.env" ]; then
    echo "Creating .env file..."
    cp "$OPENWEBUI_DIR/.env.example" "$OPENWEBUI_DIR/.env"
    
    # Generate random database password
    DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    # Replace password
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/change_me_to_a_secure_password/$DB_PASSWORD/" "$OPENWEBUI_DIR/.env"
    else
        # Linux
        sed -i "s/change_me_to_a_secure_password/$DB_PASSWORD/" "$OPENWEBUI_DIR/.env"
    fi
    
    echo "Generated random database password"
    echo ""
    echo "Please edit .env file to complete the following config:"
    echo "  - OIDC_CLIENT_ID"
    echo "  - OIDC_CLIENT_SECRET"
else
    echo ".env file already exists"
fi

# Check traefik network
echo "[3/4] Checking Docker network..."
if ! docker network inspect traefik >/dev/null 2>&1; then
    echo "Warning: traefik network does not exist"
    echo "Please deploy Traefik first or run: docker network create traefik"
else
    echo "traefik network exists"
fi

# Show port info
echo "[4/4] Port configuration..."
echo ""
echo "Open WebUI internal port: 8080"
echo "PostgreSQL internal port: 5432"
echo "(Access via Traefik reverse proxy, no need to expose ports)"

echo ""
echo "=== Init Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit .env file to configure domain and OIDC"
echo "  2. If using OIDC, create Client in Provider:"
echo "     - Client ID: openwebui"
echo "     - Redirect URI: https://YOUR_DOMAIN/oauth/oidc/callback"
echo "  3. Run: docker compose up -d"
echo "  4. Create admin account on first visit"
