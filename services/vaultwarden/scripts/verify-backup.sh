#!/bin/bash
set -e

# Vaultwarden 备份验证脚本
# 通过沙盒恢复测试验证备份是否可用

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"

# 默认验证最�?3 个备�?VERIFY_COUNT="${1:-3}"

# 加载环境变量
if [ -f "$COMPOSE_DIR/.env" ]; then
    export $(grep -v '^#' "$COMPOSE_DIR/.env" | xargs)
fi

# 验证配置 (�?.env 读取)
TEST_EMAIL="${VERIFY_TEST_EMAIL:-}"
TEST_PASSWORD="${VERIFY_TEST_PASSWORD:-}"
TEST_ITEM_NAME="${VERIFY_TEST_ITEM:-backup-test}"
TEST_EXPECTED_VALUE="${VERIFY_EXPECTED_VALUE:-}"

# 沙盒配置
SANDBOX_PORT="${VERIFY_SANDBOX_PORT:-18080}"
SANDBOX_CONTAINER="vaultwarden-verify-sandbox"
SANDBOX_DATA_DIR="/tmp/vaultwarden-verify-$$"

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

cleanup() {
    log_info "清理沙盒环境..."
    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR" 2>/dev/null || true
}

trap cleanup EXIT

echo "=========================================="
echo "  Vaultwarden 备份验证脚本"
echo "  $(date)"
echo "=========================================="
echo ""

# 检查依�?if ! command -v bw &> /dev/null; then
    log_error "未安�?Bitwarden CLI (bw)"
    echo ""
    echo "安装方式:"
    echo "  npm install -g @bitwarden/cli"
    echo "  或下�? https://bitwarden.com/help/cli/"
    exit 1
fi

# 检查验证配�?if [ -z "$TEST_EMAIL" ] || [ -z "$TEST_PASSWORD" ]; then
    log_warn "未配置验证账号，将只进行基础健康检�?
    log_warn "完整验证需要在 .env 中配�?"
    echo "  VERIFY_TEST_EMAIL=test@example.com"
    echo "  VERIFY_TEST_PASSWORD=your_master_password"
    echo "  VERIFY_TEST_ITEM=backup-test"
    echo "  VERIFY_EXPECTED_VALUE=expected_username_or_note"
    echo ""
    FULL_VERIFY=false
else
    FULL_VERIFY=true
fi

# 获取最近的备份文件
mapfile -t BACKUP_FILES < <(ls -1t "$BACKUP_DIR"/vaultwarden_*.tar.gz 2>/dev/null | head -n "$VERIFY_COUNT")

if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
    log_error "没有找到备份文件"
    exit 1
fi

log_info "将验证最�?${#BACKUP_FILES[@]} 个备�?
echo ""

# 验证结果
VERIFY_RESULTS=()
FAILED_COUNT=0

# 验证单个备份
verify_backup() {
    local BACKUP_FILE="$1"
    local BACKUP_NAME=$(basename "$BACKUP_FILE")
    
    log_step "验证备份: $BACKUP_NAME"
    
    # 清理之前的沙�?    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR"
    mkdir -p "$SANDBOX_DATA_DIR"
    
    # 解压备份
    log_info "  解压备份文件..."
    TEMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
    
    # 找到解压后的目录
    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "vaultwarden_*" | head -1)
    if [ -z "$EXTRACTED_DIR" ]; then
        EXTRACTED_DIR="$TEMP_DIR"
    fi
    
    # 检查必要文�?    if [ ! -f "$EXTRACTED_DIR/db.sqlite3" ]; then
        log_error "  备份中没有数据库文件"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # 复制数据到沙盒目�?    cp -r "$EXTRACTED_DIR"/* "$SANDBOX_DATA_DIR/"
    rm -f "$SANDBOX_DATA_DIR/db.sqlite3-wal" "$SANDBOX_DATA_DIR/db.sqlite3-shm"
    rm -rf "$TEMP_DIR"
    
    # 设置权限
    chmod -R 777 "$SANDBOX_DATA_DIR"
    
    # 启动沙盒容器
    log_info "  启动沙盒容器 (端口: $SANDBOX_PORT)..."
    docker run -d \
        --name "$SANDBOX_CONTAINER" \
        -p "$SANDBOX_PORT:80" \
        -v "$SANDBOX_DATA_DIR:/data" \
        -e DOMAIN="http://localhost:$SANDBOX_PORT" \
        -e SIGNUPS_ALLOWED="false" \
        -e WEBSOCKET_ENABLED="false" \
        -e LOG_LEVEL="error" \
        vaultwarden/server:latest > /dev/null
    
    # 等待服务启动
    log_info "  等待服务启动..."
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
        log_error "  服务启动超时"
        docker logs "$SANDBOX_CONTAINER" 2>&1 | tail -20
        return 1
    fi
    
    log_info "  服务启动成功 (${WAIT_COUNT}s)"
    
    # 基础健康检�?    log_info "  执行健康检�?.."
    if ! curl -sf "http://localhost:$SANDBOX_PORT/alive" > /dev/null; then
        log_error "  健康检查失�?
        return 1
    fi
    
    # 检�?API 是否正常
    if ! curl -sf "http://localhost:$SANDBOX_PORT/api/config" > /dev/null; then
        log_error "  API 检查失�?
        return 1
    fi
    
    # 完整验证：登录并获取密码条目
    if [ "$FULL_VERIFY" = true ]; then
        log_info "  执行登录验证..."
        
        # 配置 Bitwarden CLI
        export BW_SESSION=""
        bw logout 2>/dev/null || true
        bw config server "http://localhost:$SANDBOX_PORT" > /dev/null 2>&1
        
        # 登录
        local SESSION
        SESSION=$(bw login "$TEST_EMAIL" "$TEST_PASSWORD" --raw 2>/dev/null) || {
            log_error "  登录失败"
            return 1
        }
        export BW_SESSION="$SESSION"
        
        log_info "  登录成功，验证数�?.."
        
        # 同步数据
        bw sync > /dev/null 2>&1
        
        # 获取指定条目
        local ITEM_JSON
        ITEM_JSON=$(bw get item "$TEST_ITEM_NAME" 2>/dev/null) || {
            log_error "  未找到测试条�? $TEST_ITEM_NAME"
            bw logout > /dev/null 2>&1 || true
            return 1
        }
        
        # 验证内容
        if [ -n "$TEST_EXPECTED_VALUE" ]; then
            local ITEM_USERNAME=$(echo "$ITEM_JSON" | jq -r '.login.username // empty')
            local ITEM_NOTES=$(echo "$ITEM_JSON" | jq -r '.notes // empty')
            
            if [[ "$ITEM_USERNAME" == *"$TEST_EXPECTED_VALUE"* ]] || \
               [[ "$ITEM_NOTES" == *"$TEST_EXPECTED_VALUE"* ]]; then
                log_info "  数据验证通过"
            else
                log_error "  数据验证失败: 未找到预期�?
                bw logout > /dev/null 2>&1 || true
                return 1
            fi
        else
            log_info "  条目存在，验证通过"
        fi
        
        # 登出
        bw logout > /dev/null 2>&1 || true
    fi
    
    log_info "  �?备份验证通过"
    return 0
}

# 验证所有备�?for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
    echo ""
    if verify_backup "$BACKUP_FILE"; then
        VERIFY_RESULTS+=("�?$(basename "$BACKUP_FILE")")
    else
        VERIFY_RESULTS+=("�?$(basename "$BACKUP_FILE")")
        ((FAILED_COUNT++))
    fi
    
    # 清理沙盒
    docker rm -f "$SANDBOX_CONTAINER" 2>/dev/null || true
    rm -rf "$SANDBOX_DATA_DIR"
    mkdir -p "$SANDBOX_DATA_DIR"
done

# 输出结果
echo ""
echo "=========================================="
echo "  验证结果"
echo "=========================================="
for RESULT in "${VERIFY_RESULTS[@]}"; do
    if [[ "$RESULT" == �? ]]; then
        echo -e "${GREEN}$RESULT${NC}"
    else
        echo -e "${RED}$RESULT${NC}"
    fi
done
echo ""

if [ $FAILED_COUNT -gt 0 ]; then
    log_error "�?$FAILED_COUNT 个备份验证失�?"
    exit 1
else
    log_info "所有备份验证通过!"
    exit 0
fi
