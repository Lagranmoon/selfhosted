#!/bin/bash
set -e

# Vaultwarden 迁移脚本
# 从现有部署迁移到新配置，保留所有数据

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
NEW_DATA_DIR="$COMPOSE_DIR/data"

# 颜色定义
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
echo "  Vaultwarden 迁移脚本"
echo "=========================================="
echo ""
echo "此脚本将帮助你从现有 Vaultwarden 部署迁移到新配置"
echo "迁移过程会保留所有数据（密码、附件、配置等）"
echo ""

# 获取旧数据目录
read -p "请输入旧 Vaultwarden 数据目录的完整路径: " OLD_DATA_DIR

# 验证路径
if [ ! -d "$OLD_DATA_DIR" ]; then
    log_error "目录不存在: $OLD_DATA_DIR"
    exit 1
fi

if [ ! -f "$OLD_DATA_DIR/db.sqlite3" ]; then
    log_error "未找到数据库文件: $OLD_DATA_DIR/db.sqlite3"
    log_error "请确认这是正确的 Vaultwarden 数据目录"
    exit 1
fi

# 显示数据目录内容
echo ""
log_info "找到以下数据文件:"
ls -la "$OLD_DATA_DIR"
echo ""

# 获取旧容器名称
read -p "请输入旧 Vaultwarden 容器名称 [vaultwarden]: " OLD_CONTAINER
OLD_CONTAINER="${OLD_CONTAINER:-vaultwarden}"

# 检查旧容器状态
if docker ps -a --format '{{.Names}}' | grep -q "^${OLD_CONTAINER}$"; then
    OLD_CONTAINER_RUNNING=$(docker inspect -f '{{.State.Running}}' "$OLD_CONTAINER" 2>/dev/null || echo "false")
    log_info "找到旧容器: $OLD_CONTAINER (运行中: $OLD_CONTAINER_RUNNING)"
else
    log_warn "未找到容器: $OLD_CONTAINER"
    OLD_CONTAINER_RUNNING="false"
fi

# 确认迁移
echo ""
echo "=========================================="
echo "  迁移计划"
echo "=========================================="
echo ""
echo "源数据目录: $OLD_DATA_DIR"
echo "目标数据目录: $NEW_DATA_DIR"
echo "旧容器: $OLD_CONTAINER"
echo ""
log_warn "迁移步骤:"
echo "  1. 停止旧 Vaultwarden 容器"
echo "  2. 备份旧数据"
echo "  3. 复制数据到新目录"
echo "  4. 初始化新配置"
echo "  5. 启动新 Vaultwarden"
echo "  6. 验证迁移结果"
echo ""
log_warn "注意: 迁移期间服务将短暂不可用"
echo ""

read -p "确认开始迁移? (输入 YES 继续): " confirm
if [ "$confirm" != "YES" ]; then
    echo "已取消迁移"
    exit 0
fi

echo ""

# Step 1: 停止旧容器
log_step "1/6 停止旧容器..."
if [ "$OLD_CONTAINER_RUNNING" = "true" ]; then
    docker stop "$OLD_CONTAINER"
    log_info "旧容器已停止"
    sleep 2
else
    log_info "旧容器未运行，跳过"
fi

# Step 2: 备份旧数据
log_step "2/6 备份旧数据..."
BACKUP_NAME="pre_migration_$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="$COMPOSE_DIR/backups/$BACKUP_NAME"
mkdir -p "$BACKUP_PATH"

# 使用 sqlite3 备份数据库（如果可用）
if command -v sqlite3 &> /dev/null; then
    sqlite3 "$OLD_DATA_DIR/db.sqlite3" ".backup '$BACKUP_PATH/db.sqlite3'"
else
    cp "$OLD_DATA_DIR/db.sqlite3" "$BACKUP_PATH/"
    # 同时复制 WAL 文件（如果存在）
    cp "$OLD_DATA_DIR/db.sqlite3-wal" "$BACKUP_PATH/" 2>/dev/null || true
    cp "$OLD_DATA_DIR/db.sqlite3-shm" "$BACKUP_PATH/" 2>/dev/null || true
fi

# 备份其他文件
cp "$OLD_DATA_DIR"/rsa_key* "$BACKUP_PATH/" 2>/dev/null || true
cp "$OLD_DATA_DIR/config.json" "$BACKUP_PATH/" 2>/dev/null || true
[ -d "$OLD_DATA_DIR/attachments" ] && cp -r "$OLD_DATA_DIR/attachments" "$BACKUP_PATH/"
[ -d "$OLD_DATA_DIR/sends" ] && cp -r "$OLD_DATA_DIR/sends" "$BACKUP_PATH/"

# 压缩备份
cd "$COMPOSE_DIR/backups"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"
log_info "备份已保存到: backups/${BACKUP_NAME}.tar.gz"

# Step 3: 复制数据到新目录
log_step "3/6 复制数据到新目录..."
mkdir -p "$NEW_DATA_DIR"

# 复制数据库
if command -v sqlite3 &> /dev/null; then
    sqlite3 "$OLD_DATA_DIR/db.sqlite3" ".backup '$NEW_DATA_DIR/db.sqlite3'"
else
    cp "$OLD_DATA_DIR/db.sqlite3" "$NEW_DATA_DIR/"
fi
# 不复制 WAL 文件，让新实例重新创建
rm -f "$NEW_DATA_DIR/db.sqlite3-wal" "$NEW_DATA_DIR/db.sqlite3-shm"

# 复制 RSA 密钥（重要：保持登录状态）
cp "$OLD_DATA_DIR"/rsa_key* "$NEW_DATA_DIR/" 2>/dev/null || true

# 复制配置
cp "$OLD_DATA_DIR/config.json" "$NEW_DATA_DIR/" 2>/dev/null || true

# 复制附件
if [ -d "$OLD_DATA_DIR/attachments" ]; then
    cp -r "$OLD_DATA_DIR/attachments" "$NEW_DATA_DIR/"
    log_info "已复制附件目录"
fi

# 复制 Send 附件
if [ -d "$OLD_DATA_DIR/sends" ]; then
    cp -r "$OLD_DATA_DIR/sends" "$NEW_DATA_DIR/"
    log_info "已复制 Send 目录"
fi

# 设置权限
chown -R 1000:1000 "$NEW_DATA_DIR" 2>/dev/null || log_warn "无法修改权限，请确保 uid 1000 有写入权限"

log_info "数据复制完成"

# Step 4: 初始化新配置
log_step "4/6 初始化新配置..."
cd "$COMPOSE_DIR"

# 创建 .env 文件
if [ ! -f .env ]; then
    cp .env.example .env
    
    # 生成 Admin Token
    ADMIN_TOKEN=$(openssl rand -base64 48)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    else
        sed -i "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    fi
    
    log_info "已生成新的 Admin Token"
    echo ""
    echo "=========================================="
    echo "  请保存 Admin Token"
    echo "=========================================="
    echo "$ADMIN_TOKEN"
    echo "=========================================="
    echo ""
fi

# 创建备份目录
mkdir -p backups

# 检查 Docker 网络
if ! docker network inspect traefik >/dev/null 2>&1; then
    log_info "创建 traefik 网络..."
    docker network create traefik
fi

# Step 5: 启动新容器
log_step "5/6 启动新 Vaultwarden..."

# 提示用户配置域名
echo ""
log_warn "请先编辑 .env 文件配置域名和 SMTP:"
echo "  nano .env"
echo ""
echo "必须配置:"
echo "  - VAULTWARDEN_HOST (你的域名)"
echo "  - SMTP 相关配置 (如需邮件功能)"
echo ""

read -p "是否已配置完成? (y/N): " configured
if [[ ! "$configured" =~ ^[Yy]$ ]]; then
    echo ""
    log_warn "请配置完成后手动启动:"
    echo "  cd $COMPOSE_DIR"
    echo "  docker compose up -d"
    echo ""
    log_info "迁移数据已准备就绪，等待手动启动"
    exit 0
fi

docker compose up -d

# 等待服务启动
log_info "等待服务启动..."
sleep 5

# Step 6: 验证迁移
log_step "6/6 验证迁移结果..."

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
    log_info "新容器启动成功"
    
    # 检查健康状态
    CONTAINER_PORT=$(docker compose port vaultwarden 80 2>/dev/null | cut -d: -f2 || echo "")
    if [ -n "$CONTAINER_PORT" ]; then
        if curl -sf "http://localhost:$CONTAINER_PORT/alive" > /dev/null 2>&1; then
            log_info "健康检查通过"
        fi
    fi
else
    log_error "容器启动失败"
    docker compose logs
    exit 1
fi

# 完成
echo ""
echo "=========================================="
echo -e "${GREEN}  迁移完成!${NC}"
echo "=========================================="
echo ""
echo "迁移前备份: backups/${BACKUP_NAME}.tar.gz"
echo ""
echo "下一步:"
echo "  1. 访问你的 Vaultwarden 域名，验证登录正常"
echo "  2. 检查密码、附件是否完整"
echo "  3. 如一切正常，可以删除旧容器:"
echo "     docker rm $OLD_CONTAINER"
echo ""
echo "如需回滚:"
echo "  docker compose down"
echo "  rm -rf $NEW_DATA_DIR"
echo "  docker start $OLD_CONTAINER"
echo ""
