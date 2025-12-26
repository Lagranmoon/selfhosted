# Vaultwarden 密码管理器

Vaultwarden 是 Bitwarden 的轻量级自托管实现，兼容所有 Bitwarden 官方客户端。

## 为什么选择 Vaultwarden

- **轻量级**：相比官方 Bitwarden 服务器，资源占用极低
- **完全兼容**：支持所有 Bitwarden 官方客户端（浏览器扩展、桌面、移动端）
- **功能完整**：支持组织、共享、2FA、Send、附件等功能
- **自主可控**：数据完全存储在你自己的服务器上

## 目录结构

```
.
├── docker-compose.yml    # 服务编排
├── .env.example          # 环境变量模板
├── data/                 # 数据目录（SQLite + 附件）
├── backups/              # 本地备份目录
└── scripts/
    ├── init.sh           # 初始化脚本
    ├── backup.sh         # 备份脚本
    └── restore.sh        # 恢复脚本
```

## 快速开始

### 全新安装

```bash
# 1. 初始化
chmod +x scripts/*.sh
./scripts/init.sh

# 2. 配置环境变量
nano .env
# 必须配置: VAULTWARDEN_HOST, SMTP 相关配置
# 可选配置: S3 和远程服务器备份

# 3. 启动服务
docker compose up -d

# 4. 设置定时备份 (每天凌晨 3 点)
crontab -e
# 添加: 0 3 * * * /path/to/scripts/backup.sh >> /var/log/vaultwarden-backup.log 2>&1
```

### 从现有部署迁移

如果你已有 Vaultwarden 部署，使用迁移脚本可以安全地迁移数据：

```bash
chmod +x scripts/*.sh
./scripts/migrate.sh
```

迁移脚本会：
1. 停止旧容器
2. 备份旧数据（保存到 `backups/` 目录）
3. 复制数据到新目录（数据库、RSA 密钥、附件等）
4. 初始化新配置
5. 启动新容器
6. 验证迁移结果

**注意**：迁移会保留所有数据，包括：
- 所有用户和密码
- 文件附件
- RSA 密钥（保持现有登录会话有效）
- Admin 页面配置

首次启动后，访问 `https://your-domain` 注册第一个账户，然后立即在 `.env` 中将 `SIGNUPS_ALLOWED` 设为 `false` 并重启服务。

---

## 配置详解

### Docker Compose 配置

#### 非 root 用户运行

```yaml
user: "1000:1000"
security_opt:
  - no-new-privileges:true
```

Vaultwarden 默认以 root 运行，但这不是最佳实践。我们配置为 uid/gid 1000 运行，并禁止提权。这样即使容器被攻破，攻击者也无法获得 root 权限。

#### 环境变量

```yaml
environment:
  DOMAIN: "https://${VAULTWARDEN_HOST}"
```

`DOMAIN` 必须设置为完整的 HTTPS URL。Vaultwarden 需要知道自己的域名才能正确处理附件下载、邮件链接等功能。

```yaml
  SIGNUPS_ALLOWED: "false"
  INVITATIONS_ALLOWED: "true"
```

- `SIGNUPS_ALLOWED`：禁止公开注册。创建第一个账户后应立即设为 `false`
- `INVITATIONS_ALLOWED`：允许已有用户邀请新用户加入组织

```yaml
  ADMIN_TOKEN: "${ADMIN_TOKEN}"
```

Admin 页面的访问令牌。通过 `https://your-domain/admin` 访问管理页面，可以：
- 查看所有用户
- 删除用户
- 邀请用户
- 查看服务器配置

**重要**：Admin Token 非常敏感，请妥善保管。

```yaml
  WEBSOCKET_ENABLED: "true"
```

启用 WebSocket 实时同步。当你在一个客户端修改密码后，其他客户端会立即收到更新通知，无需手动刷新。

```yaml
  SHOW_PASSWORD_HINT: "false"
```

禁用密码提示显示。密码提示可能被攻击者利用来猜测密码。

#### 健康检查

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:80/alive"]
  interval: 30s
```

每 30 秒检查一次服务是否正常运行。如果连续 3 次失败，Docker 会将容器标记为 unhealthy。

---

### SMTP 邮件配置

邮件功能用于：
- 邮箱验证
- 邀请新用户
- 两步验证（邮件方式）
- 紧急访问通知

```bash
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_SECURITY=starttls    # 可选: starttls, force_tls, off
SMTP_USERNAME=your@email.com
SMTP_PASSWORD=your_smtp_password
SMTP_FROM=vault@example.com
```

常见邮件服务配置：

| 服务 | SMTP_HOST | SMTP_PORT | SMTP_SECURITY |
|------|-----------|-----------|---------------|
| Gmail | smtp.gmail.com | 587 | starttls |
| Outlook | smtp.office365.com | 587 | starttls |
| 阿里云 | smtp.aliyun.com | 465 | force_tls |
| 腾讯企业邮 | smtp.exmail.qq.com | 465 | force_tls |

---

### 备份策略

备份是密码管理器最重要的功能之一。我们的备份策略：

- **最近 7 天**：保留所有备份（每天一个）
- **最近 3 个月**：每月保留第一个备份
- **最近 3 年**：每年保留第一个备份

备份内容包括：
- `db.sqlite3`：数据库（用户、密码、组织等所有数据）
- `attachments/`：文件附件
- `sends/`：Send 附件
- `rsa_key.*`：JWT 签名密钥
- `config.json`：Admin 页面配置

#### 备份存储位置

1. **本地**：`./backups/` 目录
2. **S3**：支持 AWS S3、Cloudflare R2、MinIO 等兼容存储
3. **远程服务器**：通过 SSH/SCP 上传

#### 手动备份

```bash
./scripts/backup.sh
```

#### 自动备份

```bash
# 编辑 crontab
crontab -e

# 每天凌晨 3 点备份
0 3 * * * /path/to/vaultwarden/scripts/backup.sh >> /var/log/vaultwarden-backup.log 2>&1
```

---

### 备份验证

备份验证通过沙盒恢复测试确保备份可用。验证流程：

1. 启动临时 Vaultwarden 容器
2. 恢复备份数据
3. 检查服务健康状态
4. （可选）使用测试账号登录，验证密码条目是否存在

#### 配置验证账号

为了完整验证，建议在 Vaultwarden 中创建一个测试账号和测试密码条目：

1. 创建测试账号（如 `test@example.com`）
2. 在该账号中创建一个密码条目，名称为 `backup-test`
3. 在 `.env` 中配置验证信息：

```bash
VERIFY_TEST_EMAIL=test@example.com
VERIFY_TEST_PASSWORD=your_test_master_password
VERIFY_TEST_ITEM=backup-test
VERIFY_EXPECTED_VALUE=expected_username  # 可选，用于验证内容
VERIFY_BACKUP_COUNT=3  # 每次备份后验证最近 3 个备份
```

#### 依赖

验证脚本需要 Bitwarden CLI：

```bash
npm install -g @bitwarden/cli
```

#### 手动验证

```bash
# 验证最近 3 个备份
./scripts/verify-backup.sh 3

# 验证最近 1 个备份
./scripts/verify-backup.sh 1
```

#### 自动验证

在 `.env` 中设置 `VERIFY_BACKUP_COUNT=3`，每次备份完成后会自动验证最近 3 个备份。

---

### 恢复数据

```bash
./scripts/restore.sh
```

恢复脚本会：
1. 列出所有可用备份
2. 停止 Vaultwarden 服务
3. 备份当前数据到 `data.bak`
4. 解压并恢复选定的备份
5. 重启服务

**从远程恢复**：

```bash
# 从 S3 下载
rclone copy vaultwarden-s3:your-bucket/vaultwarden/vaultwarden_20250101_030000.tar.gz ./backups/

# 从远程服务器下载
scp user@remote:/path/to/backup/vaultwarden_20250101_030000.tar.gz ./backups/

# 然后运行恢复脚本
./scripts/restore.sh
```

---

## 客户端配置

### 浏览器扩展 / 桌面客户端

1. 安装 Bitwarden 官方扩展或客户端
2. 点击设置图标
3. 在"自托管环境"中填入服务器 URL：`https://vault.example.com`
4. 保存并登录

### 移动客户端

1. 安装 Bitwarden 官方 App
2. 登录前点击设置图标
3. 填入服务器 URL
4. 登录

---

## 安全建议

### 1. 启用两步验证

强烈建议为所有用户启用两步验证。支持的方式：
- TOTP（推荐：Google Authenticator、Authy）
- 邮件验证码
- YubiKey
- FIDO2 WebAuthn

### 2. 定期备份验证

定期测试恢复流程，确保备份可用：

```bash
# 在测试环境恢复
./scripts/restore.sh
# 验证数据完整性
```

### 3. 监控备份状态

检查备份日志，确保备份正常执行：

```bash
tail -f /var/log/vaultwarden-backup.log
```

### 4. 保护 Admin Token

- 不要在公共场合暴露 Admin Token
- 定期更换 Admin Token
- 考虑在不需要时禁用 Admin 页面

---

## 常用命令

```bash
# 查看日志
docker compose logs -f vaultwarden

# 重启服务
docker compose restart vaultwarden

# 停止服务
docker compose down

# 更新镜像
docker compose pull && docker compose up -d

# 进入容器
docker exec -it vaultwarden /bin/sh

# 手动备份数据库
docker exec vaultwarden /vaultwarden backup
```

---

## 故障排查

### 无法访问服务

1. 检查容器状态：`docker compose ps`
2. 检查日志：`docker compose logs vaultwarden`
3. 检查 Traefik 路由：访问 Traefik Dashboard 确认路由配置

### 邮件发送失败

1. 检查 SMTP 配置是否正确
2. 查看日志中的邮件错误：`docker compose logs vaultwarden | grep -i smtp`
3. 测试 SMTP 连接：
   ```bash
   # 在容器内测试
   docker exec -it vaultwarden /bin/sh
   # 然后尝试 telnet 或 curl 测试 SMTP 端口
   ```

### WebSocket 不工作

1. 确认 `WEBSOCKET_ENABLED=true`
2. 检查 Traefik 是否正确代理 WebSocket
3. 检查浏览器控制台是否有 WebSocket 错误

### 备份失败

1. 检查磁盘空间：`df -h`
2. 检查 S3 凭证是否正确
3. 检查 SSH 密钥权限：`chmod 600 ~/.ssh/id_rsa`
4. 手动运行备份脚本查看详细错误

---

## 环境变量说明

| 变量 | 说明 | 示例 |
|------|------|------|
| `VAULTWARDEN_HOST` | 服务域名 | `vault.example.com` |
| `ADMIN_TOKEN` | Admin 页面令牌 | 由 init.sh 生成 |
| `SMTP_HOST` | SMTP 服务器 | `smtp.gmail.com` |
| `SMTP_PORT` | SMTP 端口 | `587` |
| `SMTP_SECURITY` | SMTP 安全方式 | `starttls` |
| `SMTP_USERNAME` | SMTP 用户名 | `your@email.com` |
| `SMTP_PASSWORD` | SMTP 密码 | - |
| `SMTP_FROM` | 发件人地址 | `vault@example.com` |
| `S3_ENDPOINT` | S3 端点 | `https://s3.amazonaws.com` |
| `S3_BUCKET` | S3 存储桶 | `my-backup-bucket` |
| `S3_ACCESS_KEY` | S3 访问密钥 | - |
| `S3_SECRET_KEY` | S3 密钥 | - |
| `REMOTE_HOST` | 远程备份服务器 | `backup.example.com` |
| `REMOTE_USER` | SSH 用户名 | `backup` |
| `REMOTE_PATH` | 远程备份路径 | `/home/backup/vaultwarden` |
| `REMOTE_SSH_KEY` | SSH 密钥路径 | `~/.ssh/id_rsa` |
