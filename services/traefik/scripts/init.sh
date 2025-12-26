#!/bin/bash
set -e

# 获取脚本所在目�?(兼容 sh �?bash)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRAEFIK_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Traefik 初始化脚�?==="

# 创建 traefik 网络
echo "[1/5] 创建 Docker 网络..."
docker network create traefik 2>/dev/null || echo "网络 traefik 已存�?

# 创建必要目录
echo "[2/5] 创建目录结构..."
mkdir -p "$TRAEFIK_DIR/certs"
mkdir -p "$TRAEFIK_DIR/logs"
mkdir -p "$TRAEFIK_DIR/crowdsec/config"
mkdir -p "$TRAEFIK_DIR/crowdsec/data"

# 创建 acme.json 并设置权�?echo "[3/5] 初始化证书存�?.."
if [ ! -f "$TRAEFIK_DIR/certs/acme.json" ]; then
    touch "$TRAEFIK_DIR/certs/acme.json"
    chmod 600 "$TRAEFIK_DIR/certs/acme.json"
    echo "已创�?acme.json"
else
    echo "acme.json 已存�?
fi

# 检�?.env 文件
echo "[4/5] 检查环境配�?.."
if [ ! -f "$TRAEFIK_DIR/.env" ]; then
    echo "警告: .env 文件不存�?
    echo "请复�?.env.example �?.env 并填写配�?"
    echo "  cp .env.example .env"
    echo "  nano .env"
else
    echo ".env 文件已存�?
fi

# 生成 CrowdSec Bouncer API Key
echo "[5/5] CrowdSec 配置提示..."
echo ""
echo "首次启动后，需要生�?Bouncer API Key:"
echo "  docker exec crowdsec cscli bouncers add traefik-bouncer"
echo ""
echo "然后将生成的 key 填入 .env 文件�?CROWDSEC_BOUNCER_API_KEY"
echo ""

echo "=== 初始化完�?==="
echo ""
echo "下一�?"
echo "  1. 编辑 .env 文件填写配置"
echo "  2. 运行: docker compose up -d"
echo "  3. 生成 CrowdSec Bouncer Key (见上方说�?"
