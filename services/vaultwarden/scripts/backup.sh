#!/bin/bash
set -e

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    echo "Usage: bash $0"
    exit 1
fi

# Vaultwarden Backup Script
# Retention: 7 days all + 3 months monthly + 3 years yearly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"
DATA_DIR="$COMPOSE_DIR/data"
DATE=$(date +%Y%m%d)
DATETIME=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="vaultwarden_${DATETIME}"

# Load environment variables
if [ -f "$COMPOSE_DIR/.env" ]; then
    export $(grep -v '^#' "$COMPOSE_DIR/.env" | xargs)
fi

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "  Vaultwarden Backup Script"
echo "  $(date)"
echo "=========================================="
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# ==========================================
# 1. Local Backup
# ==========================================
log_info "Starting local backup..."

BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
mkdir -p "$BACKUP_PATH"

# Backup SQLite database
log_info "Backing up database..."
if docker exec vaultwarden /vaultwarden backup 2>/dev/null; then
    cp "$DATA_DIR/db.sqlite3.backup" "$BACKUP_PATH/db.sqlite3" 2>/dev/null || \
    docker exec vaultwarden sqlite3 /data/db.sqlite3 ".backup '/data/db_backup.sqlite3'" && \
    cp "$DATA_DIR/db_backup.sqlite3" "$BACKUP_PATH/db.sqlite3"
else
    if command -v sqlite3 &> /dev/null; then
        sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$BACKUP_PATH/db.sqlite3'"
    else
        log_warn "sqlite3 not installed, copying database file directly"
        cp "$DATA_DIR/db.sqlite3" "$BACKUP_PATH/"
    fi
fi

# Backup attachments
if [ -d "$DATA_DIR/attachments" ]; then
    log_info "Backing up attachments..."
    cp -r "$DATA_DIR/attachments" "$BACKUP_PATH/"
fi

# Backup Send attachments
if [ -d "$DATA_DIR/sends" ]; then
    log_info "Backing up Send attachments..."
    cp -r "$DATA_DIR/sends" "$BACKUP_PATH/"
fi

# Backup RSA keys
log_info "Backing up RSA keys..."
cp "$DATA_DIR"/rsa_key* "$BACKUP_PATH/" 2>/dev/null || true

# Backup config
if [ -f "$DATA_DIR/config.json" ]; then
    log_info "Backing up config..."
    cp "$DATA_DIR/config.json" "$BACKUP_PATH/"
fi

# Compress backup
log_info "Compressing backup..."
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"

BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log_info "Local backup complete: ${BACKUP_NAME}.tar.gz ($BACKUP_SIZE)"

# ==========================================
# 2. Upload to S3
# ==========================================
if [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY" ]; then
    log_info "Uploading to S3..."
    
    if command -v rclone &> /dev/null; then
        if ! rclone listremotes | grep -q "vaultwarden-s3:"; then
            rclone config create vaultwarden-s3 s3 \
                provider "Other" \
                env_auth "false" \
                access_key_id "$S3_ACCESS_KEY" \
                secret_access_key "$S3_SECRET_KEY" \
                endpoint "$S3_ENDPOINT" \
                region "$S3_REGION" \
                --quiet
        fi
        rclone copy "$BACKUP_FILE" "vaultwarden-s3:$S3_BUCKET/vaultwarden/" --quiet && \
            log_info "S3 upload complete" || log_error "S3 upload failed"
    elif command -v aws &> /dev/null; then
        AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/vaultwarden/" \
            --endpoint-url "$S3_ENDPOINT" \
            --region "$S3_REGION" && \
            log_info "S3 upload complete" || log_error "S3 upload failed"
    else
        log_warn "rclone or aws cli not installed, skipping S3 upload"
    fi
else
    log_warn "S3 not configured, skipping upload"
fi

# ==========================================
# 3. Upload to Remote Server
# ==========================================
if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_USER" ]; then
    log_info "Uploading to remote server..."
    
    SSH_KEY_OPT=""
    if [ -n "$REMOTE_SSH_KEY" ]; then
        EXPANDED_KEY="${REMOTE_SSH_KEY/#\~/$HOME}"
        if [ -f "$EXPANDED_KEY" ]; then
            SSH_KEY_OPT="-i $EXPANDED_KEY"
        fi
    fi
    
    ssh $SSH_KEY_OPT "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null || true
    
    scp $SSH_KEY_OPT "$BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/" && \
        log_info "Remote server upload complete" || log_error "Remote server upload failed"
else
    log_warn "Remote server not configured, skipping upload"
fi

# ==========================================
# 4. Clean Old Backups (Local)
# ==========================================
log_info "Cleaning old backups..."

cd "$BACKUP_DIR"

# Get all backup files sorted by date
mapfile -t ALL_BACKUPS < <(ls -1 vaultwarden_*.tar.gz 2>/dev/null | sort -r)

KEEP_FILES=()
CURRENT_MONTH=""
CURRENT_YEAR=""
MONTHS_COUNT=0
YEARS_COUNT=0

for i in "${!ALL_BACKUPS[@]}"; do
    FILE="${ALL_BACKUPS[$i]}"
    FILE_DATE=$(echo "$FILE" | grep -oP '\d{8}' | head -1)
    FILE_YEAR="${FILE_DATE:0:4}"
    FILE_MONTH="${FILE_DATE:0:6}"
    
    FILE_TIMESTAMP=$(date -d "${FILE_DATE:0:4}-${FILE_DATE:4:2}-${FILE_DATE:6:2}" +%s 2>/dev/null || echo 0)
    NOW_TIMESTAMP=$(date +%s)
    AGE_DAYS=$(( (NOW_TIMESTAMP - FILE_TIMESTAMP) / 86400 ))
    
    KEEP=false
    
    # Rule 1: Keep all from last 7 days
    if [ $AGE_DAYS -le 7 ]; then
        KEEP=true
    fi
    
    # Rule 2: Keep first of each month for last 3 months
    if [ "$FILE_MONTH" != "$CURRENT_MONTH" ] && [ $MONTHS_COUNT -lt 3 ]; then
        if [ $AGE_DAYS -gt 7 ] && [ $AGE_DAYS -le 90 ]; then
            KEEP=true
            CURRENT_MONTH="$FILE_MONTH"
            ((MONTHS_COUNT++))
        fi
    fi
    
    # Rule 3: Keep first of each year for last 3 years
    if [ "$FILE_YEAR" != "$CURRENT_YEAR" ] && [ $YEARS_COUNT -lt 3 ]; then
        if [ $AGE_DAYS -gt 90 ]; then
            KEEP=true
            CURRENT_YEAR="$FILE_YEAR"
            ((YEARS_COUNT++))
        fi
    fi
    
    if [ "$KEEP" = true ]; then
        KEEP_FILES+=("$FILE")
    else
        rm -f "$FILE"
    fi
done

log_info "Keeping ${#KEEP_FILES[@]} backup files"

# ==========================================
# 5. Clean Remote Old Backups (S3)
# ==========================================
if [ -n "$S3_BUCKET" ] && command -v rclone &> /dev/null; then
    log_info "Cleaning S3 old backups..."
    rclone delete "vaultwarden-s3:$S3_BUCKET/vaultwarden/" \
        --min-age 1095d \
        --quiet 2>/dev/null || true
fi

# ==========================================
# Complete
# ==========================================
echo ""
echo "=========================================="
log_info "Backup complete!"
echo "=========================================="
echo "Local backup: $BACKUP_FILE"
echo "Retention: 7 days all + 3 months monthly + 3 years yearly"

# ==========================================
# 6. Verify Backup (Optional)
# ==========================================
VERIFY_COUNT="${VERIFY_BACKUP_COUNT:-0}"
if [ "$VERIFY_COUNT" -gt 0 ]; then
    echo ""
    log_info "Verifying last $VERIFY_COUNT backups..."
    if [ -x "$SCRIPT_DIR/verify-backup.sh" ]; then
        "$SCRIPT_DIR/verify-backup.sh" "$VERIFY_COUNT" || log_warn "Backup verification failed"
    else
        log_warn "Verify script not found or not executable"
    fi
fi
