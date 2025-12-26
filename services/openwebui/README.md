# Open WebUI

自托管 AI 聊天界面，支持多种 LLM API。

## 功能

- 多 API 供应商支持（OpenAI、Claude、Gemini 等）
- PostgreSQL 持久化存储
- OIDC 单点登录
- RAG 文档检索
- 图片生成

## 快速开始

```bash
# 1. 初始化（自动生成数据库密码）
chmod +x scripts/init.sh
./scripts/init.sh

# 2. 编辑环境变量（配置 OIDC）
nano .env

# 3. 启动服务
docker compose up -d

# 4. 访问
# https://your-domain.com
```

## 首次配置

1. 首次访问会创建管理员账号
2. 进入 Admin Settings 配置：
   - **Connections** - 添加 OpenAI API Key
   - **Models** - 配置可用模型
   - **Documents** - RAG 设置（建议用 OpenAI Embedding）
   - **Images** - 图片生成设置

## 添加 Claude / Gemini 支持

Open WebUI 原生只支持 OpenAI API 格式，添加其他供应商有两种方式：

### 方式一：Functions（推荐）

1. 进入 Workspace → Functions
2. 点击 "+" 从社区导入
3. 搜索并安装：
   - `Anthropic` - Claude 支持
   - `Google GenAI` 或 `Gemini` - Gemini 支持
4. 在 Function 设置中填入 API Key

### 方式二：API Gateway

部署 One-API 或 LiteLLM 作为统一网关，将所有 API 转换为 OpenAI 格式。

## OIDC 配置

### 1. 在 OIDC Provider 创建 Client

- **Client ID**: `openwebui`
- **Redirect URI**: `https://your-domain.com/oauth/oidc/callback`
- **Scopes**: `openid profile email`

### 2. 配置环境变量

```env
OIDC_CLIENT_ID=openwebui
OIDC_CLIENT_SECRET=your_secret
OIDC_ISSUER_URL=https://your-oidc-provider.com
```

### 3. 登录方式

- 支持 OIDC 登录
- 同时保留密码登录
- 新用户通过 OIDC 注册后需要管理员激活

## 目录结构

```
.
├── docker-compose.yml
├── .env.example
├── README.md
├── scripts/
│   └── init.sh            # 初始化脚本
└── data/
    ├── openwebui/         # Open WebUI 数据
    └── postgres/          # PostgreSQL 数据
```

## 环境变量说明

| 变量 | 说明 |
|------|------|
| OPENWEBUI_HOST | 访问域名 |
| OPENWEBUI_PORT | 内部端口（默认 8080） |
| WEBUI_NAME | 界面显示名称 |
| POSTGRES_* | 数据库配置 |
| OIDC_* | Pocket ID 配置 |

## 性能优化

当前配置针对 4C8G 服务器优化：

| 配置 | 值 | 说明 |
|------|-----|------|
| THREAD_POOL_SIZE | 50 | 线程池大小 |
| ENABLE_AUTOCOMPLETE_GENERATION | false | 禁用自动补全 |
| ENABLE_REALTIME_CHAT_SAVE | false | 禁用实时保存 |
| MODELS_CACHE_TTL | 300 | 模型列表缓存 5 分钟 |
| 语音功能 | 禁用 | 节省内存 |

## 备份

```bash
# 备份数据库
docker exec openwebui-postgres pg_dump -U openwebui openwebui > backup.sql

# 恢复数据库
cat backup.sql | docker exec -i openwebui-postgres psql -U openwebui openwebui
```

## 更新服务

Open WebUI 目前处于 v0.x 阶段，更新可能包含破坏性变更。使用更新脚本可以自动备份和回滚：

```bash
chmod +x scripts/update.sh
./scripts/update.sh
```

更新脚本会：
1. 显示当前版本和最新版本
2. 自动备份 PostgreSQL 数据库
3. 拉取最新镜像并重启服务
4. 健康检查，确认服务正常启动
5. **如果更新失败，自动回滚镜像和数据库**
6. 清理旧镜像

手动恢复数据库（如需要）：
```bash
cat scripts/backup_xxx.sql | docker compose exec -T postgres psql -U openwebui openwebui
```

---

## 常用命令

```bash
# 查看日志
docker compose logs -f openwebui

# 重启服务
docker compose restart openwebui

# 更新镜像
docker compose pull
docker compose up -d
```
