#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

# Open WebUI Update Script
# Note: Open WebUI is currently in v0.x stage, updates may contain breaking changes
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$COMPOSE_DIR"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Open WebUI Update Script"
echo "=========================================="
echo ""

# Get current image ID (for rollback)
CURRENT_IMAGE_ID=$(docker compose images openwebui -q 2>/dev/null || echo "")
CURRENT_TAG=$(docker compose images openwebui --format json 2>/dev/null | jq -r '.[0].Tag // "unknown"')
echo "Current version: $CURRENT_TAG"
echo ""

# Check latest version
echo "Checking latest version..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/open-webui/open-webui/releases/latest" | jq -r '.tag_name // "unknown"')
echo "Latest version: $LATEST_TAG"
echo ""

# Warning
echo -e "${YELLOW}Warning:${NC}"
echo "   - Open WebUI is in v0.x stage, updates may contain breaking changes"
echo "   - Database will be backed up before update"
echo "   - Script will auto-rollback if update fails"
echo "   - Release notes: https://github.com/open-webui/open-webui/releases"
echo ""

read -p "Continue with update? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Update cancelled"
    exit 0
fi

# Backup database
echo ""
echo ">>> Backing up database..."
BACKUP_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"
BACKUP_PATH="$SCRIPT_DIR/$BACKUP_FILE"

if docker compose exec -T postgres pg_dump -U openwebui openwebui > "$BACKUP_PATH" 2>/dev/null; then
    echo -e "${GREEN}OK${NC} Database backed up to: scripts/$BACKUP_FILE"
else
    echo -e "${RED}FAIL${NC} Database backup failed"
    read -p "Continue anyway (not recommended)? (y/N): " force_continue
    if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
        echo "Update cancelled"
        exit 1
    fi
    BACKUP_PATH=""
fi

# Pull latest image
echo ""
echo ">>> Pulling latest image..."
docker compose pull openwebui

# Restart service
echo ""
echo ">>> Restarting service..."
docker compose up -d openwebui

# Wait for service to start
echo ""
echo ">>> Waiting for service to start..."
sleep 5

# Health check
echo ">>> Checking service status..."
MAX_RETRIES=12
RETRY_COUNT=0
HEALTH_OK=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker compose ps openwebui --format json 2>/dev/null | jq -e '.[0].State == "running"' > /dev/null 2>&1; then
        # Check if service responds
        CONTAINER_PORT=$(docker compose port openwebui 8080 2>/dev/null | cut -d: -f2 || echo "")
        if [ -n "$CONTAINER_PORT" ]; then
            if curl -sf "http://localhost:$CONTAINER_PORT/health" > /dev/null 2>&1 || \
               curl -sf "http://localhost:$CONTAINER_PORT" > /dev/null 2>&1; then
                HEALTH_OK=true
                break
            fi
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "   Waiting for service... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

if [ "$HEALTH_OK" = true ]; then
    echo -e "${GREEN}OK${NC} Service started successfully"
    
    # Clean old images
    echo ""
    echo ">>> Cleaning old images..."
    docker image prune -f
    
    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}  Update Complete!${NC}"
    echo -e "${GREEN}==========================================${NC}"
    
    NEW_TAG=$(docker compose images openwebui --format json 2>/dev/null | jq -r '.[0].Tag // "unknown"')
    echo "New version: $NEW_TAG"
    echo ""
    echo "Backup file: scripts/$BACKUP_FILE"
else
    # Update failed, rollback
    echo ""
    echo -e "${RED}FAIL${NC} Service failed to start, rolling back..."
    
    # Rollback image
    if [ -n "$CURRENT_IMAGE_ID" ]; then
        echo ">>> Rolling back to previous image..."
        docker compose down openwebui 2>/dev/null || true
        
        # Restart with previous image
        docker tag "$CURRENT_IMAGE_ID" ghcr.io/open-webui/open-webui:rollback 2>/dev/null || true
        docker compose up -d openwebui
    fi
    
    # Restore database
    if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
        echo ">>> Restoring database..."
        sleep 3
        if cat "$BACKUP_PATH" | docker compose exec -T postgres psql -U openwebui openwebui > /dev/null 2>&1; then
            echo -e "${GREEN}OK${NC} Database restored"
        else
            echo -e "${YELLOW}WARN${NC} Database restore failed, manual restore required:"
            echo "   cat scripts/$BACKUP_FILE | docker compose exec -T postgres psql -U openwebui openwebui"
        fi
    fi
    
    echo ""
    echo -e "${RED}==========================================${NC}"
    echo -e "${RED}  Update Failed, Rolled Back${NC}"
    echo -e "${RED}==========================================${NC}"
    echo ""
    echo "Check logs: docker compose logs openwebui"
    echo "Release notes: https://github.com/open-webui/open-webui/releases"
    exit 1
fi
