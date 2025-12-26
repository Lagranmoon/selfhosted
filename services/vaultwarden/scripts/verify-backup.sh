#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

# Vaultwarden Backup Verification Script
# Verify backups via sandbox restore test

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"

# Default verify last 3 backups
VERIFY_COUNT="${1:-3}"

# Load environment variables
if [ -f "$COMPOSE_DIR/.env" ]; then
    export $(grep -v '^#' "$COMPOSE_DIR/.env" | xargs)
fi

# Verification config (from .env)
TEST_EMAIL="${VERIFY_TEST_EMAIL:-}"
TEST_PASSWORD="${VERIFY_TEST_PASSWORD:-}"
TEST_ITEM_NAME="${VERIFY_TEST_ITEM:-backup-test}"
TEST_EXPECTED_VALUE="${VERIFY_EXPECTED_VALUE:-}"

# Sandbox config
SANDBOX_PORT="${VERIFY_SANDBOX_PORT:-18080}"
SANDBOX_CONTAINER="vaultwarden-verify-sandbox"
SANDBOX_DATA_DIR="/tmp/vaultwarden-verify-$$"

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

cleanup() {
    log_info "Cleaning up sandbox..."
    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR" 2>/dev/null || true
}

trap cleanup EXIT

echo "=========================================="
echo "  Vaultwarden Backup Verification Script"
echo "  $(date)"
echo "=========================================="
echo ""

# Check dependencies
if ! command -v bw &> /dev/null; then
    log_error "Bitwarden CLI (bw) not installed"
    echo ""
    echo "Install via:"
    echo "  npm install -g @bitwarden/cli"
    echo "  or download: https://bitwarden.com/help/cli/"
    exit 1
fi

# Check verification config
if [ -z "$TEST_EMAIL" ] || [ -z "$TEST_PASSWORD" ]; then
    log_warn "Verification account not configured, will only perform basic health check"
    log_warn "For full verification, configure in .env:"
    echo "  VERIFY_TEST_EMAIL=test@example.com"
    echo "  VERIFY_TEST_PASSWORD=your_master_password"
    echo "  VERIFY_TEST_ITEM=backup-test"
    echo "  VERIFY_EXPECTED_VALUE=expected_username_or_note"
    echo ""
    FULL_VERIFY=false
else
    FULL_VERIFY=true
fi

# Get recent backup files
mapfile -t BACKUP_FILES < <(ls -1t "$BACKUP_DIR"/vaultwarden_*.tar.gz 2>/dev/null | head -n "$VERIFY_COUNT")

if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
    log_error "No backup files found"
    exit 1
fi

log_info "Will verify ${#BACKUP_FILES[@]} backups"
echo ""

# Verification results
VERIFY_RESULTS=()
FAILED_COUNT=0

# Verify single backup
verify_backup() {
    local BACKUP_FILE="$1"
    local BACKUP_NAME=$(basename "$BACKUP_FILE")
    
    log_step "Verifying backup: $BACKUP_NAME"
    
    # Clean previous sandbox
    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR"
    mkdir -p "$SANDBOX_DATA_DIR"
    
    # Extract backup
    log_info "  Extracting backup file..."
    TEMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
    
    # Find extracted directory
    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "vaultwarden_*" | head -1)
    if [ -z "$EXTRACTED_DIR" ]; then
        EXTRACTED_DIR="$TEMP_DIR"
    fi
    
    # Check required files
    if [ ! -f "$EXTRACTED_DIR/db.sqlite3" ]; then
        log_error "  Database file not found in backup"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # Copy data to sandbox directory
    cp -r "$EXTRACTED_DIR"/* "$SANDBOX_DATA_DIR/"
    rm -f "$SANDBOX_DATA_DIR/db.sqlite3-wal" "$SANDBOX_DATA_DIR/db.sqlite3-shm"
    rm -rf "$TEMP_DIR"
    
    # Set permissions
    chmod -R 777 "$SANDBOX_DATA_DIR"
    
    # Start sandbox container
    log_info "  Starting sandbox container (port: $SANDBOX_PORT)..."
    docker run -d \
        --name "$SANDBOX_CONTAINER" \
        -p "$SANDBOX_PORT:80" \
        -v "$SANDBOX_DATA_DIR:/data" \
        -e DOMAIN="http://localhost:$SANDBOX_PORT" \
        -e SIGNUPS_ALLOWED="false" \
        -e WEBSOCKET_ENABLED="false" \
        -e LOG_LEVEL="error" \
        vaultwarden/server:latest > /dev/null
    
    # Wait for service to start
    log_info "  Waiting for service to start..."
    local MAX_WAIT=30
    local WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if curl -sf "http://localhost:$SANDBOX_PORT/alive" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        ((WAIT_COUNT++))
    done
    
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        log_error "  Service start timeout"
        docker logs "$SANDBOX_CONTAINER" 2>&1 | tail -20
        return 1
    fi
    
    log_info "  Service started (${WAIT_COUNT}s)"
    
    # Basic health check
    log_info "  Running health check..."
    if ! curl -sf "http://localhost:$SANDBOX_PORT/alive" > /dev/null; then
        log_error "  Health check failed"
        return 1
    fi
    
    # Check API
    if ! curl -sf "http://localhost:$SANDBOX_PORT/api/config" > /dev/null; then
        log_error "  API check failed"
        return 1
    fi

    # Full verification: login and get password entry
    if [ "$FULL_VERIFY" = true ]; then
        log_info "  Running login verification..."
        
        # Configure Bitwarden CLI
        export BW_SESSION=""
        bw logout 2>/dev/null || true
        bw config server "http://localhost:$SANDBOX_PORT" > /dev/null 2>&1
        
        # Login
        local SESSION
        SESSION=$(bw login "$TEST_EMAIL" "$TEST_PASSWORD" --raw 2>/dev/null) || {
            log_error "  Login failed"
            return 1
        }
        export BW_SESSION="$SESSION"
        
        log_info "  Login successful, verifying data..."
        
        # Sync data
        bw sync > /dev/null 2>&1
        
        # Get specified item
        local ITEM_JSON
        ITEM_JSON=$(bw get item "$TEST_ITEM_NAME" 2>/dev/null) || {
            log_error "  Test item not found: $TEST_ITEM_NAME"
            bw logout > /dev/null 2>&1 || true
            return 1
        }
        
        # Verify content
        if [ -n "$TEST_EXPECTED_VALUE" ]; then
            local ITEM_USERNAME=$(echo "$ITEM_JSON" | jq -r '.login.username // empty')
            local ITEM_NOTES=$(echo "$ITEM_JSON" | jq -r '.notes // empty')
            
            if [[ "$ITEM_USERNAME" == *"$TEST_EXPECTED_VALUE"* ]] || \
               [[ "$ITEM_NOTES" == *"$TEST_EXPECTED_VALUE"* ]]; then
                log_info "  Data verification passed"
            else
                log_error "  Data verification failed: expected value not found"
                bw logout > /dev/null 2>&1 || true
                return 1
            fi
        else
            log_info "  Item exists, verification passed"
        fi
        
        # Logout
        bw logout > /dev/null 2>&1 || true
    fi
    
    log_info "  OK Backup verification passed"
    return 0
}

# Verify all backups
for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
    echo ""
    if verify_backup "$BACKUP_FILE"; then
        VERIFY_RESULTS+=("OK $(basename "$BACKUP_FILE")")
    else
        VERIFY_RESULTS+=("FAIL $(basename "$BACKUP_FILE")")
        ((FAILED_COUNT++))
    fi
    
    # Clean sandbox
    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR"
    mkdir -p "$SANDBOX_DATA_DIR"
done

# Output results
echo ""
echo "=========================================="
echo "  Verification Results"
echo "=========================================="
for RESULT in "${VERIFY_RESULTS[@]}"; do
    if [[ "$RESULT" == OK* ]]; then
        echo -e "${GREEN}$RESULT${NC}"
    else
        echo -e "${RED}$RESULT${NC}"
    fi
done
echo ""

if [ $FAILED_COUNT -gt 0 ]; then
    log_error "$FAILED_COUNT backup(s) failed verification"
    exit 1
else
    log_info "All backups verified successfully!"
    exit 0
fi
