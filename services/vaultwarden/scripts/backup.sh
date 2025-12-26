#!/bin/bash
set -e

# 检测 shell 类型，必须使用 bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 此脚本需要使用 bash 运行"
    echo "请使用: bash $0"
    exit 1
fi

# Vaultwarden 备份脚本
# 备份策略: 最近7天全部 + 最近3个月每月第一个 + 最近3年每年第一个
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"
DATA_DIR="$COMPOSE_DIR/data"
DATE=$(date +%Y%m%d)
DATETIME=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="vaultwarden_${DATETIME}"

# 加载环境变量
if [ -f "$COMPOSE_DIR/.env" ]; then
    export $(grep -v '^#' "$COMPOSE_DIR/.env" | xargs)
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "  Vaultwarden 备份脚本"
echo "  $(date)"
echo "=========================================="
echo ""

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# ==========================================
# 1. 本地备份
# ==========================================
log_info "开始本地备�?.."

BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
mkdir -p "$BACKUP_PATH"

# 备份 SQLite 数据�?(使用内置命令)
log_info "备份数据�?.."
if docker exec vaultwarden /vaultwarden backup 2>/dev/null; then
    # 内置备份会创�?db.sqlite3.backup
    cp "$DATA_DIR/db.sqlite3.backup" "$BACKUP_PATH/db.sqlite3" 2>/dev/null || \
    docker exec vaultwarden sqlite3 /data/db.sqlite3 ".backup '/data/db_backup.sqlite3'" && \
    cp "$DATA_DIR/db_backup.sqlite3" "$BACKUP_PATH/db.sqlite3"
else
    # 回退�?sqlite3 命令
    if command -v sqlite3 &> /dev/null; then
        sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$BACKUP_PATH/db.sqlite3'"
    else
        log_warn "sqlite3 未安装，直接复制数据库文�?
        cp "$DATA_DIR/db.sqlite3" "$BACKUP_PATH/"
    fi
fi

# 备份附件
if [ -d "$DATA_DIR/attachments" ]; then
    log_info "备份附件..."
    cp -r "$DATA_DIR/attachments" "$BACKUP_PATH/"
fi

# 备份 Send 附件
if [ -d "$DATA_DIR/sends" ]; then
    log_info "备份 Send 附件..."
    cp -r "$DATA_DIR/sends" "$BACKUP_PATH/"
fi

# 备份 RSA 密钥
log_info "备份 RSA 密钥..."
cp "$DATA_DIR"/rsa_key* "$BACKUP_PATH/" 2>/dev/null || true

# 备份配置
if [ -f "$DATA_DIR/config.json" ]; then
    log_info "备份配置..."
    cp "$DATA_DIR/config.json" "$BACKUP_PATH/"
fi

# 压缩备份
log_info "压缩备份..."
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"

BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log_info "本地备份完成: ${BACKUP_NAME}.tar.gz ($BACKUP_SIZE)"

# ==========================================
# 2. 上传�?S3
# ==========================================
if [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY" ]; then
    log_info "上传�?S3..."
    
    # 检�?rclone �?aws cli
    if command -v rclone &> /dev/null; then
        # 配置 rclone (如果未配�?
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
            log_info "S3 上传完成" || log_error "S3 上传失败"
    elif command -v aws &> /dev/null; then
        AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/vaultwarden/" \
            --endpoint-url "$S3_ENDPOINT" \
            --region "$S3_REGION" && \
            log_info "S3 上传完成" || log_error "S3 上传失败"
    else
        log_warn "未安�?rclone �?aws cli，跳�?S3 上传"
    fi
else
    log_warn "未配�?S3，跳过上�?
fi

# ==========================================
# 3. 上传到远程服务器
# ==========================================
if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_USER" ]; then
    log_info "上传到远程服务器..."
    
    SSH_KEY_OPT=""
    if [ -n "$REMOTE_SSH_KEY" ]; then
        # 展开 ~ 路径
        EXPANDED_KEY="${REMOTE_SSH_KEY/#\~/$HOME}"
        if [ -f "$EXPANDED_KEY" ]; then
            SSH_KEY_OPT="-i $EXPANDED_KEY"
        fi
    fi
    
    # 创建远程目录
    ssh $SSH_KEY_OPT "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null || true
    
    # 上传备份
    scp $SSH_KEY_OPT "$BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/" && \
        log_info "远程服务器上传完�? || log_error "远程服务器上传失�?
else
    log_warn "未配置远程服务器，跳过上�?
fi

# ==========================================
# 4. 清理旧备�?(本地)
# ==========================================
log_info "清理旧备�?.."

cd "$BACKUP_DIR"

# 获取所有备份文件，按日期排�?mapfile -t ALL_BACKUPS < <(ls -1 vaultwarden_*.tar.gz 2>/dev/null | sort -r)

KEEP_FILES=()
CURRENT_MONTH=""
CURRENT_YEAR=""
MONTHS_COUNT=0
YEARS_COUNT=0

for i in "${!ALL_BACKUPS[@]}"; do
    FILE="${ALL_BACKUPS[$i]}"
    # 提取日期 vaultwarden_YYYYMMDD_HHMMSS.tar.gz
    FILE_DATE=$(echo "$FILE" | grep -oP '\d{8}' | head -1)
    FILE_YEAR="${FILE_DATE:0:4}"
    FILE_MONTH="${FILE_DATE:0:6}"
    
    # 计算文件年龄（天�?    FILE_TIMESTAMP=$(date -d "${FILE_DATE:0:4}-${FILE_DATE:4:2}-${FILE_DATE:6:2}" +%s 2>/dev/null || echo 0)
    NOW_TIMESTAMP=$(date +%s)
    AGE_DAYS=$(( (NOW_TIMESTAMP - FILE_TIMESTAMP) / 86400 ))
    
    KEEP=false
    REASON=""
    
    # 规则1: 最�?天全部保�?    if [ $AGE_DAYS -le 7 ]; then
        KEEP=true
        REASON="最�?�?
    fi
    
    # 规则2: 最�?个月每月第一�?    if [ "$FILE_MONTH" != "$CURRENT_MONTH" ] && [ $MONTHS_COUNT -lt 3 ]; then
        if [ $AGE_DAYS -gt 7 ] && [ $AGE_DAYS -le 90 ]; then
            KEEP=true
            REASON="月度备份"
            CURRENT_MONTH="$FILE_MONTH"
            ((MONTHS_COUNT++))
        fi
    fi
    
    # 规则3: 最�?年每年第一�?    if [ "$FILE_YEAR" != "$CURRENT_YEAR" ] && [ $YEARS_COUNT -lt 3 ]; then
        if [ $AGE_DAYS -gt 90 ]; then
            KEEP=true
            REASON="年度备份"
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

log_info "保留 ${#KEEP_FILES[@]} 个备份文�?

# ==========================================
# 5. 清理远程旧备�?(S3)
# ==========================================
if [ -n "$S3_BUCKET" ] && command -v rclone &> /dev/null; then
    log_info "清理 S3 旧备�?.."
    # 删除超过 3 年的备份
    rclone delete "vaultwarden-s3:$S3_BUCKET/vaultwarden/" \
        --min-age 1095d \
        --quiet 2>/dev/null || true
fi

# ==========================================
# 完成
# ==========================================
echo ""
echo "=========================================="
log_info "备份完成!"
echo "=========================================="
echo "本地备份: $BACKUP_FILE"
echo "保留策略: 7天全�?+ 3个月每月 + 3年每�?

# ==========================================
# 6. 验证备份 (可�?
# ==========================================
VERIFY_COUNT="${VERIFY_BACKUP_COUNT:-0}"
if [ "$VERIFY_COUNT" -gt 0 ]; then
    echo ""
    log_info "开始验证最�?$VERIFY_COUNT 个备�?.."
    if [ -x "$SCRIPT_DIR/verify-backup.sh" ]; then
        "$SCRIPT_DIR/verify-backup.sh" "$VERIFY_COUNT" || log_warn "备份验证失败，请检�?
    else
        log_warn "验证脚本不存在或不可执行"
    fi
fi
