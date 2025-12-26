#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$COMPOSE_DIR"

echo "=========================================="
echo "  Vaultwarden Init Script"
echo "=========================================="
echo ""

# Create data directories
echo ">>> Creating data directories..."
mkdir -p data
mkdir -p backups

# Set directory permissions (uid:gid 1000:1000)
chown -R 1000:1000 data backups 2>/dev/null || echo "Note: Cannot change directory permissions, ensure uid 1000 has write access"

# Create .env file
if [ ! -f .env ]; then
    echo ">>> Creating .env file..."
    cp .env.example .env
    
    # Generate Admin Token
    ADMIN_TOKEN=$(openssl rand -base64 48)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    else
        sed -i "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    fi
    
    echo ""
    echo "=========================================="
    echo "  Admin Token Generated"
    echo "=========================================="
    echo ""
    echo "Please save this Admin Token:"
    echo "$ADMIN_TOKEN"
    echo ""
    echo "Admin page: https://your-domain/admin"
    echo ""
else
    echo ">>> .env file already exists, skipping"
fi

# Check Docker network
if ! docker network inspect traefik >/dev/null 2>&1; then
    echo ""
    echo ">>> Creating traefik network..."
    docker network create traefik
fi

echo ""
echo "=========================================="
echo "  Init Complete"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Edit .env file, configure domain and SMTP"
echo "2. Configure S3 and remote server backup info"
echo "3. Run: docker compose up -d"
echo "4. Set up cron for scheduled backup: crontab -e"
echo "   0 3 * * * $SCRIPT_DIR/backup.sh"
echo ""
