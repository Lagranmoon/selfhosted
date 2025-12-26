#!/bin/bash
set -e

# 检测 shell 类型，必须使用 bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 此脚本需要使用 bash 运行"
    echo "请使用: bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENWEBUI_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Open WebUI 初始化脚�?==="

# 创建数据目录
echo "[1/4] 创建数据目录..."
mkdir -p "$OPENWEBUI_DIR/data/openwebui"
mkdir -p "$OPENWEBUI_DIR/data/postgres"

# 检�?.env 文件
echo "[2/4] 检查环境配�?.."
if [ ! -f "$OPENWEBUI_DIR/.env" ]; then
    echo "创建 .env 文件..."
    cp "$OPENWEBUI_DIR/.env.example" "$OPENWEBUI_DIR/.env"
    
    # 生成随机数据库密�?    DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    # 替换密码
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/change_me_to_a_secure_password/$DB_PASSWORD/" "$OPENWEBUI_DIR/.env"
    else
        # Linux
        sed -i "s/change_me_to_a_secure_password/$DB_PASSWORD/" "$OPENWEBUI_DIR/.env"
    fi
    
    echo "已生成随机数据库密码"
    echo ""
    echo "请编�?.env 文件完成以下配置:"
    echo "  - OIDC_CLIENT_ID"
    echo "  - OIDC_CLIENT_SECRET"
else
    echo ".env 文件已存�?
fi

# 检�?traefik 网络
echo "[3/4] 检�?Docker 网络..."
if ! docker network inspect traefik >/dev/null 2>&1; then
    echo "警告: traefik 网络不存�?
    echo "请先部署 Traefik 或运�? docker network create traefik"
else
    echo "traefik 网络已存�?
fi

# 显示端口信息
echo "[4/4] 端口配置..."
echo ""
echo "Open WebUI 内部端口: 8080"
echo "PostgreSQL 内部端口: 5432"
echo "（通过 Traefik 反代访问，无需暴露端口�?

echo ""
echo "=== 初始化完�?==="
echo ""
echo "下一�?"
echo "  1. 编辑 .env 文件配置域名�?OIDC"
echo "  2. 如使�?OIDC，在 Provider 创建 Client:"
echo "     - Client ID: openwebui"
echo "     - Redirect URI: https://YOUR_DOMAIN/oauth/oidc/callback"
echo "  3. 运行: docker compose up -d"
echo "  4. 首次访问创建管理员账�?
