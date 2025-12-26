#!/bin/bash
set -e

# Open WebUI 更新脚本
# 注意：Open WebUI 目前处于 v0.x 阶段，更新可能包含破坏性变更

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$COMPOSE_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Open WebUI 更新脚本"
echo "=========================================="
echo ""

# 获取当前镜像 ID（用于回滚）
CURRENT_IMAGE_ID=$(docker compose images openwebui -q 2>/dev/null || echo "")
CURRENT_TAG=$(docker compose images openwebui --format json 2>/dev/null | jq -r '.[0].Tag // "unknown"')
echo "当前版本: $CURRENT_TAG"
echo ""

# 检查远程最新版本
echo "检查最新版本..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/open-webui/open-webui/releases/latest" | jq -r '.tag_name // "unknown"')
echo "最新版本: $LATEST_TAG"
echo ""

# 警告提示
echo -e "${YELLOW}⚠️  注意事项：${NC}"
echo "   - Open WebUI 处于 v0.x 阶段，更新可能包含破坏性变更"
echo "   - 更新前会自动备份数据库"
echo "   - 如更新后出现问题，脚本会自动回滚"
echo "   - 查看更新日志: https://github.com/open-webui/open-webui/releases"
echo ""

read -p "是否继续更新? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "已取消更新"
    exit 0
fi

# 备份数据库
echo ""
echo ">>> 备份数据库..."
BACKUP_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"
BACKUP_PATH="$SCRIPT_DIR/$BACKUP_FILE"

if docker compose exec -T postgres pg_dump -U openwebui openwebui > "$BACKUP_PATH" 2>/dev/null; then
    echo -e "${GREEN}✓ 数据库已备份到: scripts/$BACKUP_FILE${NC}"
else
    echo -e "${RED}✗ 数据库备份失败${NC}"
    read -p "是否继续更新（不推荐）? (y/N): " force_continue
    if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
        echo "已取消更新"
        exit 1
    fi
    BACKUP_PATH=""
fi

# 拉取最新镜像
echo ""
echo ">>> 拉取最新镜像..."
docker compose pull openwebui

# 重启服务
echo ""
echo ">>> 重启服务..."
docker compose up -d openwebui

# 等待服务启动
echo ""
echo ">>> 等待服务启动..."
sleep 5

# 健康检查
echo ">>> 检查服务状态..."
MAX_RETRIES=12
RETRY_COUNT=0
HEALTH_OK=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker compose ps openwebui --format json 2>/dev/null | jq -e '.[0].State == "running"' > /dev/null 2>&1; then
        # 检查是否能响应请求
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
    echo "   等待服务就绪... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

if [ "$HEALTH_OK" = true ]; then
    echo -e "${GREEN}✓ 服务启动成功${NC}"
    
    # 清理旧镜像
    echo ""
    echo ">>> 清理旧镜像..."
    docker image prune -f
    
    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}  更新完成！${NC}"
    echo -e "${GREEN}==========================================${NC}"
    
    NEW_TAG=$(docker compose images openwebui --format json 2>/dev/null | jq -r '.[0].Tag // "unknown"')
    echo "更新后版本: $NEW_TAG"
    echo ""
    echo "备份文件: scripts/$BACKUP_FILE"
else
    # 更新失败，执行回滚
    echo ""
    echo -e "${RED}✗ 服务启动失败，开始回滚...${NC}"
    
    # 回滚镜像
    if [ -n "$CURRENT_IMAGE_ID" ]; then
        echo ">>> 回滚到之前的镜像..."
        docker compose down openwebui 2>/dev/null || true
        
        # 使用之前的镜像重新启动
        docker tag "$CURRENT_IMAGE_ID" ghcr.io/open-webui/open-webui:rollback 2>/dev/null || true
        docker compose up -d openwebui
    fi
    
    # 恢复数据库
    if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
        echo ">>> 恢复数据库..."
        sleep 3
        if cat "$BACKUP_PATH" | docker compose exec -T postgres psql -U openwebui openwebui > /dev/null 2>&1; then
            echo -e "${GREEN}✓ 数据库已恢复${NC}"
        else
            echo -e "${YELLOW}⚠ 数据库恢复失败，请手动恢复：${NC}"
            echo "   cat scripts/$BACKUP_FILE | docker compose exec -T postgres psql -U openwebui openwebui"
        fi
    fi
    
    echo ""
    echo -e "${RED}==========================================${NC}"
    echo -e "${RED}  更新失败，已回滚到之前版本${NC}"
    echo -e "${RED}==========================================${NC}"
    echo ""
    echo "请检查日志: docker compose logs openwebui"
    echo "更新日志: https://github.com/open-webui/open-webui/releases"
    exit 1
fi
