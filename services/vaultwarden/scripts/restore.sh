#!/bin/bash
set -e

# Vaultwarden 恢复脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"
DATA_DIR="$COMPOSE_DIR/data"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "  Vaultwarden 恢复脚本"
echo "=========================================="
echo ""

# 列出可用备份
echo "可用的本地备�?"
echo ""
ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk '{print NR". "$NF" ("$5")"}' || {
    log_error "没有找到本地备份文件"
    echo ""
    echo "你可以从 S3 或远程服务器下载备份�?$BACKUP_DIR/"
    exit 1
}

echo ""
read -p "请输入要恢复的备份文件名 (或输入完整路�?: " BACKUP_FILE

# 处理输入
if [[ ! "$BACKUP_FILE" == /* ]] && [[ ! "$BACKUP_FILE" == ./* ]]; then
    # 如果只输入了文件名，添加备份目录路径
    if [[ ! "$BACKUP_FILE" == *.tar.gz ]]; then
        BACKUP_FILE="${BACKUP_FILE}.tar.gz"
    fi
    BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "备份文件不存�? $BACKUP_FILE"
    exit 1
fi

echo ""
log_warn "警告: 恢复操作将覆盖当前所有数�?"
log_warn "当前数据将备份到 ${DATA_DIR}.bak"
echo ""
read -p "确认恢复? (输入 YES 继续): " confirm

if [ "$confirm" != "YES" ]; then
    echo "已取消恢�?
    exit 0
fi

# 停止服务
log_info "停止 Vaultwarden 服务..."
cd "$COMPOSE_DIR"
docker compose down 2>/dev/null || true

# 备份当前数据
if [ -d "$DATA_DIR" ]; then
    log_info "备份当前数据�?${DATA_DIR}.bak..."
    rm -rf "${DATA_DIR}.bak"
    mv "$DATA_DIR" "${DATA_DIR}.bak"
fi

# 创建新数据目�?mkdir -p "$DATA_DIR"

# 解压备份
log_info "解压备份文件..."
TEMP_DIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

# 找到解压后的目录
EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "vaultwarden_*" | head -1)
if [ -z "$EXTRACTED_DIR" ]; then
    EXTRACTED_DIR="$TEMP_DIR"
fi

# 恢复数据�?if [ -f "$EXTRACTED_DIR/db.sqlite3" ]; then
    log_info "恢复数据�?.."
    cp "$EXTRACTED_DIR/db.sqlite3" "$DATA_DIR/"
    # 删除可能存在�?WAL 文件（防止数据库损坏�?    rm -f "$DATA_DIR/db.sqlite3-wal" "$DATA_DIR/db.sqlite3-shm"
else
    log_error "备份中没有找到数据库文件!"
    exit 1
fi

# 恢复附件
if [ -d "$EXTRACTED_DIR/attachments" ]; then
    log_info "恢复附件..."
    cp -r "$EXTRACTED_DIR/attachments" "$DATA_DIR/"
fi

# 恢复 Send 附件
if [ -d "$EXTRACTED_DIR/sends" ]; then
    log_info "恢复 Send 附件..."
    cp -r "$EXTRACTED_DIR/sends" "$DATA_DIR/"
fi

# 恢复 RSA 密钥
if ls "$EXTRACTED_DIR"/rsa_key* 1> /dev/null 2>&1; then
    log_info "恢复 RSA 密钥..."
    cp "$EXTRACTED_DIR"/rsa_key* "$DATA_DIR/"
fi

# 恢复配置
if [ -f "$EXTRACTED_DIR/config.json" ]; then
    log_info "恢复配置..."
    cp "$EXTRACTED_DIR/config.json" "$DATA_DIR/"
fi

# 清理临时目录
rm -rf "$TEMP_DIR"

# 设置权限
log_info "设置目录权限..."
chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

# 启动服务
log_info "启动 Vaultwarden 服务..."
docker compose up -d

# 等待服务启动
sleep 5

# 检查服务状�?if docker compose ps | grep -q "running"; then
    echo ""
    echo "=========================================="
    log_info "恢复完成!"
    echo "=========================================="
    echo ""
    echo "旧数据已备份�? ${DATA_DIR}.bak"
    echo "如需回滚，可以手动恢�?
else
    log_error "服务启动失败，请检查日�? docker compose logs"
    echo ""
    echo "如需回滚:"
    echo "  docker compose down"
    echo "  rm -rf $DATA_DIR"
    echo "  mv ${DATA_DIR}.bak $DATA_DIR"
    echo "  docker compose up -d"
fi
