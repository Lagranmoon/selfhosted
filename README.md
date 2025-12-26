# Self-Hosted Services

个人自部署服务的配置文件、脚本和文档集合。

## 服务列表

| 服务 | 说明 | 文档 |
|------|------|------|
| Traefik + CrowdSec | 反向代理 + WAF + IPS | [详细文档](services/traefik/README.md) |
| Open WebUI | AI 聊天界面 | [详细文档](services/openwebui/README.md) |
| Vaultwarden | 密码管理器 (Bitwarden 兼容) | [详细文档](services/vaultwarden/README.md) |

## 目录结构

```
.
├── services/                   # 服务配置 (Git 管理)
│   ├── traefik/               # Traefik v3 + CrowdSec
│   ├── openwebui/             # Open WebUI + PostgreSQL
│   └── vaultwarden/           # Vaultwarden 密码管理器
└── scripts/
    ├── init/
    └── backup/
```

## 设计原则

- **配置即代码**：所有配置文件通过 Git 版本管理
- **数据分离**：运行时数据（`data/`、`backups/`、`logs/`）不纳入 Git
- **敏感信息隔离**：`.env` 文件存储敏感配置，不提交到仓库

## 快速开始

### 环境要求

- Docker & Docker Compose v2+
- Linux 服务器 (推荐 Ubuntu 22.04+ / Debian 12+)

### 部署 Traefik

```bash
cd services/traefik

# 初始化
chmod +x scripts/init.sh
./scripts/init.sh

# 配置环境变量
cp .env.example .env
nano .env

# 启动
docker compose up -d
```

详细配置说明请参考 [Traefik 文档](services/traefik/README.md)。

## 功能特性

### Traefik v3

- 自动服务发现 (Docker Provider)
- Let's Encrypt 自动证书 (Cloudflare DNS Challenge)
- 泛域名证书支持
- Prometheus Metrics
- JSON Access Log

### CrowdSec

- IP 信誉检查
- 社区威胁情报
- AppSec WAF (OWASP CRS)
- 自动封禁恶意 IP

### 安全中间件

- Security Headers (HSTS, XSS Protection, etc.)
- Rate Limiting
- IP Whitelist
- Gzip Compression

## 注意事项

- 敏感配置使用 `.env` 文件管理，已添加到 `.gitignore`
- 运行时数据目录（`data/`、`backups/`）不纳入版本管理
- 定期更新镜像版本和 CrowdSec 规则
- 备份 `acme.json` 证书文件

## License

MIT
