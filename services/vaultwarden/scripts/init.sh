#!/bin/bash
set -e

# 检测 shell 类型，必须使用 bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 此脚本需要使用 bash 运行"
    echo "请使用: bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$COMPOSE_DIR"

echo "=========================================="
echo "  Vaultwarden 初始化脚本"
echo "=========================================="
echo ""

# 创建数据目录
echo ">>> 创建数据目录..."
mkdir -p data
mkdir -p backups

# 设置目录权限 (uid:gid 1000:1000)
chown -R 1000:1000 data backups 2>/dev/null || echo "注意: 无法修改目录权限，请确保 uid 1000 有写入权限"

# 创建 .env 文件
if [ ! -f .env ]; then
    echo ">>> 创建 .env 文件..."
    cp .env.example .env
    
    # 生成 Admin Token
    ADMIN_TOKEN=$(openssl rand -base64 48)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    else
        sed -i "s|ADMIN_TOKEN=change_me_to_a_secure_token|ADMIN_TOKEN=${ADMIN_TOKEN}|g" .env
    fi
    
    echo ""
    echo "=========================================="
    echo "  Admin Token 已生成"
    echo "=========================================="
    echo ""
    echo "请妥善保存以下 Admin Token:"
    echo "$ADMIN_TOKEN"
    echo ""
    echo "访问 Admin 页面: https://your-domain/admin"
    echo ""
else
    echo ">>> .env 文件已存在，跳过创建"
fi


# 检查 Docker 网络
if ! docker network inspect traefik >/dev/null 2>&1; then
    echo ""
    echo ">>> 创建 traefik 网络..."
    docker network create traefik
fi

echo ""
echo "=========================================="
echo "  初始化完成"
echo "=========================================="
echo ""
echo "下一步:"
echo "1. 编辑 .env 文件，配置域名和 SMTP"
echo "2. 配置 S3 和远程服务器备份信息"
echo "3. 运行: docker compose up -d"
echo "4. 设置 cron 定时备份: crontab -e"
echo "   0 3 * * * $SCRIPT_DIR/backup.sh"
echo ""
