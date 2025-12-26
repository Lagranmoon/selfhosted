#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

# Vaultwarden Migration Script
# Migrate from existing deployment to new config, preserving all data
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
NEW_DATA_DIR="$COMPOSE_DIR/data"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Vaultwarden Migration Script"
echo "=========================================="
echo ""
echo "This script helps migrate from existing Vaultwarden deployment to new config"
echo "All data (passwords, attachments, config) will be preserved"
echo ""

# Get old data directory
read -p "Enter full path to old Vaultwarden data directory: " OLD_DATA_DIR

# Validate path
if [ ! -d "$OLD_DATA_DIR" ]; then
    log_error "Directory not found: $OLD_DATA_DIR"
    exit 1
fi

if [ ! -f "$OLD_DATA_DIR/db.sqlite3" ]; then
    log_error "Database file not found: $OLD_DATA_DIR/db.sqlite3"
    log_error "Please confirm this is the correct Vaultwarden data directory"
    exit 1
fi

# Show data directory contents
echo ""
log_info "Found the following data files:"
ls -la "$OLD_DATA_DIR"
echo ""

# Get old container name
read -p "Enter old Vaultwarden container name [vaultwarden]: " OLD_CONTAINER
OLD_CONTAINER="${OLD_CONTAINER:-vaultwarden}"

# Check old container status
if docker ps -a --format '{{.Names}}' | grep -q "^${OLD_CONTAINER}$"; then
    OLD_CONTAINER_RUNNING=$(docker inspect -f '{{.State.Running}}' "$OLD_CONTAINER" 2>/dev/null || echo "false")
    log_info "Found old container: $OLD_CONTAINER (running: $OLD_CONTAINER_RUNNING)"
else
    log_warn "Container not found: $OLD_CONTAINER"
    OLD_CONTAINER_RUNNING="false"
fi

# Confirm migration
echo ""
echo "=========================================="
echo "  Migration Plan"
echo "=========================================="
echo ""
echo "Source data directory: $OLD_DATA_DIR"
echo "Target data directory: $NEW_DATA_DIR"
echo "Old container: $OLD_CONTAINER"
echo ""
log_warn "Migration steps:"
echo "  1. Stop old Vaultwarden container"
echo "  2. Backup old data"
echo "  3. Copy data to new directory"
echo "  4. Initialize new config"
echo "  5. Start new Vaultwarden"
echo "  6. Verify migration"
echo ""
log_warn "Note: Service will be briefly unavailable during migration"
echo ""

read -p "Confirm start migration? (type YES to continue): " confirm
if [ "$confirm" != "YES" ]; then
    echo "Migration cancelled"
    exit 0
fi

echo ""

# Step 1: Stop old container
log_step "1/6 Stopping old container..."
if [ "$OLD_CONTAINER_RUNNING" = "true" ]; then
    docker stop "$OLD_CONTAINER"
    log_info "Old container stopped"
    sleep 2
else
    log_info "Old container not running, skipping"
fi

# Step 2: Backup old data
log_step "2/6 Backing up old data..."
BACKUP_NAME="pre_migration_$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="$COMPOSE_DIR/backups/$BACKUP_NAME"
mkdir -p "$BACKUP_PATH"

if command -v sqlite3 &> /dev/null; then
    sqlite3 "$OLD_DATA_DIR/db.sqlite3" ".backup '$BACKUP_PATH/db.sqlite3'"
else
    cp "$OLD_DATA_DIR/db.sqlite3" "$BACKUP_PATH/"
    cp "$OLD_DATA_DIR/db.sqlite3-wal" "$BACKUP_PATH/" 2>/dev/null || true
    cp "$OLD_DATA_DIR/db.sqlite3-shm" "$BACKUP_PATH/" 2>/dev/null || true
fi

cp "$OLD_DATA_DIR"/rsa_key* "$BACKUP_PATH/" 2>/dev/null || true
cp "$OLD_DATA_DIR/config.json" "$BACKUP_PATH/" 2>/dev/null || true
[ -d "$OLD_DATA_DIR/attachments" ] && cp -r "$OLD_DATA_DIR/attachments" "$BACKUP_PATH/"
[ -d "$OLD_DATA_DIR/sends" ] && cp -r "$OLD_DATA_DIR/sends" "$BACKUP_PATH/"

cd "$COMPOSE_DIR/backups"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"
log_info "Backup saved to: backups/${BACKUP_NAME}.tar.gz"

# Step 3: Copy data to new directory
log_step "3/6 Copying data to new directory..."
mkdir -p "$NEW_DATA_DIR"

if command -v sqlite3 &> /dev/null; then
    sqlite3 "$OLD_DATA_DIR/db.sqlite3" ".backup '$NEW_DATA_DIR/db.sqlite3'"
else
    cp "$OLD_DATA_DIR/db.sqlite3" "$NEW_DATA_DIR/"
fi
rm -f "$NEW_DATA_DIR/db.sqlite3-wal" "$NEW_DATA_DIR/db.sqlite3-shm"

cp "$OLD_DATA_DIR"/rsa_key* "$NEW_DATA_DIR/" 2>/dev/null || true
cp "$OLD_DATA_DIR/config.json" "$NEW_DATA_DIR/" 2>/dev/null || true

if [ -d "$OLD_DATA_DIR/attachments" ]; then
    cp -r "$OLD_DATA_DIR/attachments" "$NEW_DATA_DIR/"
    log_info "Copied attachments directory"
fi

if [ -d "$OLD_DATA_DIR/sends" ]; then
    cp -r "$OLD_DATA_DIR/sends" "$NEW_DATA_DIR/"
    log_info "Copied Send directory"
fi

chown -R 1000:1000 "$NEW_DATA_DIR" 2>/dev/null || log_warn "Cannot change permissions, ensure uid 1000 has write access"

log_info "Data copy complete"

# Step 4: Initialize new config
log_step "4/6 Initializing new config..."
cd "$COMPOSE_DIR"

if [ ! -f .env ]; then
    cp .env.example .env
    
    ADMIN_TOKEN=$(openssl rand -base64 48)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    else
        sed -i "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    fi
    
    log_info "Generated new Admin Token"
    echo ""
    echo "=========================================="
    echo "  Save Admin Token"
    echo "=========================================="
    echo "$ADMIN_TOKEN"
    echo "=========================================="
    echo ""
fi

mkdir -p backups

if ! docker network inspect traefik >/dev/null 2>&1; then
    log_info "Creating traefik network..."
    docker network create traefik
fi

# Step 5: Start new container
log_step "5/6 Starting new Vaultwarden..."

echo ""
log_warn "Please edit .env file to configure domain and SMTP first:"
echo "  nano .env"
echo ""
echo "Required config:"
echo "  - VAULTWARDEN_HOST (your domain)"
echo "  - SMTP settings (if email needed)"
echo ""

read -p "Configuration complete? (y/N): " configured
if [[ ! "$configured" =~ ^[Yy]$ ]]; then
    echo ""
    log_warn "Please start manually after configuration:"
    echo "  cd $COMPOSE_DIR"
    echo "  docker compose up -d"
    echo ""
    log_info "Migration data ready, waiting for manual start"
    exit 0
fi

docker compose up -d

log_info "Waiting for service to start..."
sleep 5

# Step 6: Verify migration
log_step "6/6 Verifying migration..."

MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if docker compose ps | grep -q "running"; then
        break
    fi
    sleep 1
    ((WAIT_COUNT++))
done

if docker compose ps | grep -q "running"; then
    log_info "New container started successfully"
    
    CONTAINER_PORT=$(docker compose port vaultwarden 80 2>/dev/null | cut -d: -f2 || echo "")
    if [ -n "$CONTAINER_PORT" ]; then
        if curl -sf "http://localhost:$CONTAINER_PORT/alive" > /dev/null 2>&1; then
            log_info "Health check passed"
        fi
    fi
else
    log_error "Container failed to start"
    docker compose logs
    exit 1
fi

# Complete
echo ""
echo "=========================================="
echo -e "${GREEN}  Migration Complete!${NC}"
echo "=========================================="
echo ""
echo "Pre-migration backup: backups/${BACKUP_NAME}.tar.gz"
echo ""
echo "Next steps:"
echo "  1. Visit your Vaultwarden domain, verify login works"
echo "  2. Check passwords and attachments are complete"
echo "  3. If all good, remove old container:"
echo "     docker rm $OLD_CONTAINER"
echo ""
echo "To rollback:"
echo "  docker compose down"
echo "  rm -rf $NEW_DATA_DIR"
echo "  docker start $OLD_CONTAINER"
echo ""
