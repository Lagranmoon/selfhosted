#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

# Vaultwarden Restore Script

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"
DATA_DIR="$COMPOSE_DIR/data"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "  Vaultwarden Restore Script"
echo "=========================================="
echo ""

# List available backups
echo "Available local backups:"
echo ""
ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk '{print NR". "$NF" ("$5")"}' || {
    log_error "No local backup files found"
    echo ""
    echo "You can download backups from S3 or remote server to $BACKUP_DIR/"
    exit 1
}

echo ""
read -p "Enter backup filename (or full path): " BACKUP_FILE

# Process input
if [[ ! "$BACKUP_FILE" == /* ]] && [[ ! "$BACKUP_FILE" == ./* ]]; then
    if [[ ! "$BACKUP_FILE" == *.tar.gz ]]; then
        BACKUP_FILE="${BACKUP_FILE}.tar.gz"
    fi
    BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo ""
log_warn "Warning: Restore will overwrite all current data"
log_warn "Current data will be backed up to ${DATA_DIR}.bak"
echo ""
read -p "Confirm restore? (type YES to continue): " confirm

if [ "$confirm" != "YES" ]; then
    echo "Restore cancelled"
    exit 0
fi

# Stop service
log_info "Stopping Vaultwarden service..."
cd "$COMPOSE_DIR"
docker compose down 2>/dev/null || true

# Backup current data
if [ -d "$DATA_DIR" ]; then
    log_info "Backing up current data to ${DATA_DIR}.bak..."
    rm -rf "${DATA_DIR}.bak"
    mv "$DATA_DIR" "${DATA_DIR}.bak"
fi

# Create new data directory
mkdir -p "$DATA_DIR"

# Extract backup
log_info "Extracting backup file..."
TEMP_DIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

# Find extracted directory
EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "vaultwarden_*" | head -1)
if [ -z "$EXTRACTED_DIR" ]; then
    EXTRACTED_DIR="$TEMP_DIR"
fi

# Restore database
if [ -f "$EXTRACTED_DIR/db.sqlite3" ]; then
    log_info "Restoring database..."
    cp "$EXTRACTED_DIR/db.sqlite3" "$DATA_DIR/"
    rm -f "$DATA_DIR/db.sqlite3-wal" "$DATA_DIR/db.sqlite3-shm"
else
    log_error "Database file not found in backup!"
    exit 1
fi

# Restore attachments
if [ -d "$EXTRACTED_DIR/attachments" ]; then
    log_info "Restoring attachments..."
    cp -r "$EXTRACTED_DIR/attachments" "$DATA_DIR/"
fi

# Restore Send attachments
if [ -d "$EXTRACTED_DIR/sends" ]; then
    log_info "Restoring Send attachments..."
    cp -r "$EXTRACTED_DIR/sends" "$DATA_DIR/"
fi

# Restore RSA keys
if ls "$EXTRACTED_DIR"/rsa_key* 1> /dev/null 2>&1; then
    log_info "Restoring RSA keys..."
    cp "$EXTRACTED_DIR"/rsa_key* "$DATA_DIR/"
fi

# Restore config
if [ -f "$EXTRACTED_DIR/config.json" ]; then
    log_info "Restoring config..."
    cp "$EXTRACTED_DIR/config.json" "$DATA_DIR/"
fi

# Clean temp directory
rm -rf "$TEMP_DIR"

# Set permissions
log_info "Setting directory permissions..."
chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

# Start service
log_info "Starting Vaultwarden service..."
docker compose up -d

# Wait for service to start
sleep 5

# Check service status
if docker compose ps | grep -q "running"; then
    echo ""
    echo "=========================================="
    log_info "Restore complete!"
    echo "=========================================="
    echo ""
    echo "Old data backed up to: ${DATA_DIR}.bak"
    echo "To rollback, restore manually"
else
    log_error "Service failed to start, check logs: docker compose logs"
    echo ""
    echo "To rollback:"
    echo "  docker compose down"
    echo "  rm -rf $DATA_DIR"
    echo "  mv ${DATA_DIR}.bak $DATA_DIR"
    echo "  docker compose up -d"
fi
