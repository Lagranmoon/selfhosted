# Traefik v3 + CrowdSec 完整配置指南

本文档详细介绍如何使用 Docker 部署 Traefik v3 反向代理，并集成 CrowdSec 实现 WAF 和入侵防护。

## 写在前面

这套配置实现了：

- **Traefik v3** 作为反向代理和负载均衡器
- **Let's Encrypt** 自动申请和续期 HTTPS 证书（通过 Cloudflare DNS 验证）
- **CrowdSec** 提供 WAF（Web 应用防火墙）和 IPS（入侵防护系统）
- **OWASP CRS** 规则集，防护常见 Web 攻击

如果你之前使用过 Nginx，可以把 Traefik 理解为一个"更智能"的 Nginx——它能自动发现 Docker 容器并配置路由，无需手动编写配置文件。

## 目录结构

```
.
├── docker-compose.yml          # 主配置文件
├── .env.example                # 环境变量模板
├── config/
│   └── dynamic/                # Traefik 动态配置（热加载）
│       ├── middlewares.yml     # 中间件配置
│       └── tls.yml             # TLS/SSL 配置
├── crowdsec/
│   └── config/
│       ├── acquis.yaml         # CrowdSec 日志采集配置
│       ├── profiles.yaml       # CrowdSec 封禁策略
│       └── whitelist.yaml      # IP 白名单
├── certs/                      # 证书存储目录
├── logs/                       # 日志目录
└── scripts/
    └── init.sh                 # 初始化脚本
```

## 快速开始

```bash
# 1. 初始化目录和网络
chmod +x scripts/init.sh
./scripts/init.sh

# 2. 配置环境变量
cp .env.example .env
nano .env  # 填写你的配置

# 3. 启动服务
docker compose up -d

# 4. 生成 CrowdSec Bouncer API Key
docker exec crowdsec cscli bouncers add traefik-bouncer
# 复制输出的 key，填入 .env 的 CROWDSEC_BOUNCER_API_KEY

# 5. 重启使配置生效
docker compose restart traefik
```

---

## 配置详解

### Docker Compose 核心配置

#### 网络配置

```yaml
networks:
  traefik:
    external: true
  crowdsec:
    driver: bridge
```

我们创建了两个网络：

- `traefik`：外部网络，所有需要被 Traefik 代理的服务都要加入这个网络。设置为 `external: true` 意味着这个网络在 compose 文件外部创建（通过 `docker network create traefik`），这样其他 compose 项目也能加入。
- `crowdsec`：内部网络，仅用于 Traefik 和 CrowdSec 之间的通信，不对外暴露。

#### 端口配置

```yaml
ports:
  - target: 80
    published: 80
    protocol: tcp
    mode: host
  - target: 443
    published: 443
    protocol: tcp
    mode: host
```

这里使用了"长格式"的端口映射，而不是简单的 `80:80`。

`mode: host` 是关键——它让 Traefik 直接使用宿主机的网络栈，而不是通过 Docker 的 NAT。这样做的好处是 Traefik 能获取到访问者的真实 IP 地址，而不是 Docker 网桥的 IP。如果你需要基于 IP 的访问控制或日志分析，这个配置必不可少。

#### 安全配置

```yaml
security_opt:
  - no-new-privileges:true
```

这个配置禁止容器内的进程获取新的特权。即使容器被攻破，攻击者也无法提升权限。这是容器安全的基本实践。

---

### Traefik 命令行参数详解

#### 全局配置

```yaml
- "--global.sendanonymoususage=false"
- "--global.checknewversion=false"
```

禁用匿名使用数据上报和版本检查。在生产环境中，我们不希望 Traefik 主动连接外部服务器。

#### API 和 Dashboard

```yaml
- "--api=true"
- "--api.dashboard=true"
- "--api.insecure=false"
```

- `api=true`：启用 Traefik API
- `api.dashboard=true`：启用 Web 管理界面
- `api.insecure=false`：**关键安全配置**，禁止通过 8080 端口直接访问 Dashboard。我们会通过 HTTPS + 密码保护来访问。

#### 健康检查

```yaml
- "--ping=true"
```

启用 `/ping` 端点，用于健康检查。Docker 的 healthcheck 会定期访问这个端点来判断 Traefik 是否正常运行。

#### 日志配置

```yaml
- "--log.level=INFO"
- "--log.format=json"
- "--accesslog=true"
- "--accesslog.filepath=/logs/access.json"
- "--accesslog.format=json"
- "--accesslog.bufferingsize=100"
```

- 使用 JSON 格式的日志，方便后续用 CrowdSec 或其他工具分析
- Access Log 记录所有 HTTP 请求，这是 CrowdSec 分析恶意行为的数据来源
- `bufferingsize=100` 表示缓冲 100 条日志后再写入文件，减少磁盘 I/O

#### 入口点（Entrypoints）

```yaml
- "--entrypoints.http.address=:80"
- "--entrypoints.http.http.redirections.entrypoint.to=https"
- "--entrypoints.http.http.redirections.entrypoint.scheme=https"
- "--entrypoints.https.address=:443"
- "--entrypoints.https.http.tls=true"
```

入口点定义了 Traefik 监听的端口：

- `http` 入口点监听 80 端口，并自动重定向到 HTTPS
- `https` 入口点监听 443 端口，默认启用 TLS

这样配置后，所有 HTTP 请求都会被 301 重定向到 HTTPS，无需在每个服务上单独配置。

#### 证书配置（Let's Encrypt + Cloudflare）

```yaml
- "--entrypoints.https.http.tls.certresolver=cloudflare"
- "--entrypoints.https.http.tls.domains[0].main=${DOMAIN}"
- "--entrypoints.https.http.tls.domains[0].sans=*.${DOMAIN}"
- "--certificatesresolvers.cloudflare.acme.email=${CF_API_EMAIL}"
- "--certificatesresolvers.cloudflare.acme.storage=/certs/acme.json"
- "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
- "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
- "--certificatesresolvers.cloudflare.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53"
```

这段配置实现了：

1. 使用 Let's Encrypt 自动申请免费 HTTPS 证书
2. 通过 Cloudflare DNS 验证域名所有权（DNS Challenge）
3. 申请泛域名证书 `*.example.com`，这样所有子域名都能使用同一张证书

**为什么用 DNS Challenge 而不是 HTTP Challenge？**

- HTTP Challenge 需要 Let's Encrypt 服务器能访问你的 80 端口
- DNS Challenge 只需要你能修改 DNS 记录，适合内网服务或有防火墙的环境
- DNS Challenge 支持泛域名证书，HTTP Challenge 不支持

#### Provider 配置

```yaml
- "--providers.docker=true"
- "--providers.docker.watch=true"
- "--providers.docker.exposedbydefault=false"
- "--providers.docker.endpoint=unix:///var/run/docker.sock"
- "--providers.docker.network=traefik"
- "--providers.file=true"
- "--providers.file.directory=/etc/traefik/dynamic"
- "--providers.file.watch=true"
```

Traefik 的 Provider 是它的核心概念——告诉 Traefik 从哪里获取路由配置：

**Docker Provider：**
- `watch=true`：监控 Docker 事件，容器启动/停止时自动更新路由
- `exposedbydefault=false`：**重要安全配置**，默认不暴露任何容器。只有明确添加 `traefik.enable=true` 标签的容器才会被代理
- `network=traefik`：指定 Traefik 通过哪个网络与后端服务通信

**File Provider：**
- 从 `/etc/traefik/dynamic` 目录读取配置文件
- `watch=true`：文件变更时自动热加载，无需重启 Traefik

#### Metrics 配置

```yaml
- "--metrics.prometheus=true"
- "--metrics.prometheus.buckets=0.1,0.3,1.2,5.0"
- "--metrics.prometheus.addentrypointslabels=true"
- "--metrics.prometheus.addrouterslabels=true"
- "--metrics.prometheus.addserviceslabels=true"
```

启用 Prometheus 格式的监控指标，方便接入 Grafana 等监控系统。

#### CrowdSec 插件

```yaml
- "--experimental.plugins.crowdsec.modulename=github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
- "--experimental.plugins.crowdsec.version=v1.3.5"
```

加载 CrowdSec Bouncer 插件。Traefik 的插件系统允许在不修改源码的情况下扩展功能。

---

### Dashboard 路由配置

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik"
  - "traefik.http.routers.traefik-dashboard.entrypoints=https"
  - "traefik.http.routers.traefik-dashboard.rule=Host(`${TRAEFIK_DASHBOARD_HOST}`)"
  - "traefik.http.routers.traefik-dashboard.tls=true"
  - "traefik.http.routers.traefik-dashboard.tls.certresolver=cloudflare"
  - "traefik.http.routers.traefik-dashboard.service=api@internal"
  - "traefik.http.routers.traefik-dashboard.middlewares=dashboard-auth@file,security-headers@file,crowdsec@file"
```

这些 Docker Labels 定义了 Dashboard 的访问规则：

- `traefik.enable=true`：告诉 Traefik 代理这个容器
- `rule=Host(...)`：当访问 `traefik.example.com` 时匹配这个路由
- `service=api@internal`：指向 Traefik 内置的 Dashboard 服务
- `middlewares=...`：应用多个中间件——密码认证、安全头、CrowdSec 防护

---

### 中间件配置详解

中间件是 Traefik 的强大功能，可以在请求到达后端服务之前进行各种处理。

#### BasicAuth 认证

```yaml
dashboard-auth:
  basicAuth:
    users:
      - "{{env `TRAEFIK_DASHBOARD_AUTH`}}"
    removeHeader: true
```

为 Dashboard 添加密码保护。`removeHeader: true` 表示认证通过后移除 Authorization 头，避免传递给后端服务。

#### 安全响应头

```yaml
security-headers:
  headers:
    browserXssFilter: true
    contentTypeNosniff: true
    frameDeny: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 31536000
```

这些 HTTP 响应头能防御多种常见攻击：

- `browserXssFilter`：启用浏览器 XSS 过滤
- `contentTypeNosniff`：防止 MIME 类型嗅探攻击
- `frameDeny`：防止点击劫持（Clickjacking）
- `sts*`：启用 HSTS，强制浏览器使用 HTTPS

#### CrowdSec Bouncer

```yaml
crowdsec:
  plugin:
    crowdsec:
      enabled: true
      crowdsecMode: stream
      crowdsecLapiHost: crowdsec:8080
      crowdsecAppsecEnabled: true
      crowdsecAppsecHost: crowdsec:7422
```

- `crowdsecMode: stream`：使用流模式，CrowdSec 主动推送封禁列表给 Traefik，性能最好
- `crowdsecAppsecEnabled: true`：启用 AppSec（WAF 功能），检查每个请求是否包含恶意内容

#### IP 白名单

```yaml
ip-whitelist:
  ipAllowList:
    sourceRange:
      - "127.0.0.1/32"
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"
```

只允许特定 IP 访问。适用于内部管理服务。

#### 中间件链

```yaml
chain-default:
  chain:
    middlewares:
      - security-headers
      - crowdsec
      - gzip
```

将多个中间件组合成一个"链"，方便复用。使用时只需引用 `chain-default@file`。

---

### CrowdSec 配置详解

#### 日志采集（acquis.yaml）

```yaml
filenames:
  - /var/log/traefik/access.json
labels:
  type: traefik
```

告诉 CrowdSec 从哪里读取日志。CrowdSec 会分析这些日志，识别恶意行为（如暴力破解、扫描器等）。

#### AppSec 配置

```yaml
source: appsec
listen_addr: 0.0.0.0:7422
appsec_configs:
  - crowdsecurity/appsec-default   # CrowdSec 规则
  - crowdsecurity/crs              # OWASP CRS 规则
```

AppSec 是 CrowdSec 的 WAF 功能：

- `appsec-default`：CrowdSec 自己的规则，包含虚拟补丁（针对已知 CVE）
- `crs`：OWASP Core Rule Set，业界标准的 WAF 规则集

#### 封禁策略（profiles.yaml）

```yaml
name: default_ip_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
  - type: ban
    duration: 4h
```

定义检测到威胁后如何处理。这里配置为封禁 IP 4 小时。

#### IP 白名单（whitelist.yaml）

```yaml
whitelist:
  ip:
    - "127.0.0.1"
  cidr:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
```

白名单中的 IP 不会被 CrowdSec 封禁，即使触发了规则。

---

## 添加新服务

当你需要代理一个新的 Docker 服务时，只需添加以下 labels：

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik"
      - "traefik.http.routers.myapp.entrypoints=https"
      - "traefik.http.routers.myapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=cloudflare"
      - "traefik.http.routers.myapp.middlewares=chain-default@file"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"

networks:
  traefik:
    external: true
```

关键点：
1. 加入 `traefik` 网络
2. 设置 `traefik.enable=true`
3. 定义路由规则（域名、中间件等）
4. 指定后端服务端口

---

## 常用命令

### CrowdSec 管理

```bash
# 查看封禁列表
docker exec crowdsec cscli decisions list

# 查看告警
docker exec crowdsec cscli alerts list

# 手动封禁 IP
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual ban"

# 解封 IP
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# 查看已安装的规则集
docker exec crowdsec cscli collections list

# 更新规则
docker exec crowdsec cscli hub update
docker exec crowdsec cscli hub upgrade
```

### 日志查看

```bash
# Traefik 日志
docker compose logs -f traefik

# CrowdSec 日志
docker compose logs -f crowdsec

# Access Log
tail -f logs/access.json | jq
```

---

## IP 白名单配置

### CrowdSec 白名单（不被封禁）

编辑 `crowdsec/config/whitelist.yaml`：

```yaml
whitelist:
  ip:
    - "1.2.3.4"           # 你的 IP
  cidr:
    - "203.0.113.0/24"    # 你的网段
```

修改后重启：`docker compose restart crowdsec`

### Traefik 白名单（仅允许访问）

编辑 `config/dynamic/middlewares.yml` 中的 `ip-whitelist`：

```yaml
ip-whitelist:
  ipAllowList:
    sourceRange:
      - "1.2.3.4/32"
```

Traefik 会自动热加载，无需重启。

使用方式：
```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=ip-whitelist@file"
  # 或使用组合链
  - "traefik.http.routers.myapp.middlewares=chain-internal@file"
```

---

## 可用中间件

| 中间件 | 说明 |
|--------|------|
| `chain-default@file` | 安全头 + CrowdSec + Gzip（推荐用于公开服务） |
| `chain-secure@file` | 安全头 + CrowdSec + 限流 + Gzip（高安全需求） |
| `chain-internal@file` | IP白名单 + 安全头 + CrowdSec + Gzip（内部服务） |
| `ip-whitelist@file` | 仅 IP 白名单 |
| `security-headers@file` | 仅安全响应头 |
| `rate-limit@file` | 仅限流 |
| `gzip@file` | 仅 Gzip 压缩 |
| `crowdsec@file` | 仅 CrowdSec 防护 |

---

## 环境变量说明

| 变量 | 说明 | 示例 |
|------|------|------|
| `CF_API_EMAIL` | Cloudflare 账号邮箱 | `your@email.com` |
| `CF_DNS_API_TOKEN` | Cloudflare API Token | 需要 Zone:DNS:Edit 权限 |
| `DOMAIN` | 根域名 | `example.com` |
| `TRAEFIK_DASHBOARD_HOST` | Dashboard 域名 | `traefik.example.com` |
| `TRAEFIK_DASHBOARD_AUTH` | Dashboard 认证 | htpasswd 格式，`$` 转义为 `$$` |
| `CROWDSEC_BOUNCER_API_KEY` | CrowdSec Bouncer Key | 通过 cscli 生成 |
| `TZ` | 时区 | `Asia/Shanghai` |

### 生成 Dashboard 密码

```bash
# 安装 htpasswd
# Ubuntu: apt install apache2-utils
# macOS: brew install httpd

# 生成密码
htpasswd -nB admin
# 输出: admin:$2y$05$xxx...

# 填入 .env 时，$ 需要转义为 $$
# 例如: TRAEFIK_DASHBOARD_AUTH=admin:$$2y$$05$$xxx...
```
