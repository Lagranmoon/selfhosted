# Self-Hosted Services 项目规范

这是一个个人自托管服务集合，用于管理和维护各种 Docker 化的服务。

## 项目结构

```
services/<service>/
├── docker-compose.yml    # 服务编排
├── .env.example          # 环境变量模板（不含真实值）
├── README.md             # 详细配置说明
├── scripts/
│   └── init.sh           # 初始化脚本
└── config/               # 配置文件（如需要）
```

**数据分离原则**：
- `services/` 目录：配置文件，通过 Git 版本管理
- `data/`、`backups/`、`logs/`：运行时数据，不纳入 Git

## 技术栈

- **容器化**: Docker + Docker Compose
- **反向代理**: Traefik v3（已配置 CrowdSec WAF/IPS）
- **数据库**: PostgreSQL（使用最新稳定版，当前 17）
- **证书**: Let's Encrypt via Cloudflare DNS Challenge
- **安全**: CrowdSec + OWASP CRS 规则

## 核心原则

### 1. 敏感信息处理
- **绝不**在任何文件中包含真实的域名、IP、密码、API Key
- 使用占位符：`example.com`、`your@email.com`、`change_me_to_a_secure_password`
- 密码等敏感信息在 `init.sh` 中通过 `openssl rand -base64 32` 运行时生成
- 用户需要手动填写的信息在 `.env.example` 中用注释说明

### 2. 配置优先级
- 能在服务 UI 中配置的选项，**不要**写在 docker-compose.yml 里
- 只在 docker-compose 中配置：网络、存储、端口、必要的启动参数
- 示例：Open WebUI 的 API Provider 配置应在界面中完成，而非环境变量

### 3. 文档规范
- 每个服务的 README.md 必须解释**每个配置项的用途**
- 参考风格：像写博客一样，对新手友好，解释"为什么"而不只是"怎么做"
- 包含：快速开始、配置详解、常用命令、故障排查

### 4. Git 提交规范
使用 Conventional Commits 格式：
- `feat(service): 添加新功能`
- `fix(service): 修复问题`
- `docs(service): 更新文档`
- `chore: 杂项维护`

### 5. 文件编码规范
- **所有文件必须使用 UTF-8 编码，无 BOM**
- Shell 脚本必须使用 LF 换行符（已通过 `.gitattributes` 强制）
- 在 Windows 上编辑文件时注意编码问题，确保保存为 UTF-8 无 BOM

## 新服务开发流程

**重要**：需求是否明确由用户判断。用户没有明确说"开始写"之前，**禁止**编写任何代码。

可以主动询问以下问题帮助明确需求：

1. **基础需求**
   - 服务用途和预期用户数
   - 是否需要持久化存储
   - 是否需要外部访问（域名）

2. **安全需求**
   - 认证方式（密码、OIDC、无）
   - 是否需要 IP 白名单
   - 是否开放注册

3. **资源约束**
   - 服务器配置（CPU/内存）
   - 是否需要性能优化

4. **集成需求**
   - 是否需要 Traefik 反代
   - 是否需要连接其他服务

## 安全最佳实践

- 所有容器添加 `security_opt: [no-new-privileges:true]`
- 使用非 root 用户运行（如服务支持）
- 网络隔离：只有需要被 Traefik 代理的服务才加入 `traefik` 网络
- 内部服务使用独立的 bridge 网络
- 定期更新镜像版本

## 现有服务

| 服务 | 用途 | 端口 |
|------|------|------|
| Traefik | 反向代理 + WAF | 80, 443 |
| CrowdSec | 入侵防护 | - |
| Open WebUI | AI 聊天界面 | 配置文件指定 |
| Vaultwarden | 密码管理器 | - |
