# cc-connect Deployment Plan

> **Generated:** 2026-05-22
> **Source research:** `/home/dev/projects/kyb/docs/infra/cc-connect-research.md`
> **GitHub:** https://github.com/chenhg5/cc-connect
> **Status:** Planning -- waiting for user-provided tokens

---

## Overview

cc-connect is a Go binary that bridges AI coding agents (Claude Code, Codex, Gemini CLI, etc.) to messaging platforms (Feishu, DingTalk, WeChat Work, Telegram, etc.). It lets developers control AI agents from their phones.

No official Docker image exists. This plan covers building a Docker image and deploying it in kyb-infra.

---

## 1. Architecture

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Messaging       │────▶│  cc-connect      │────▶│  AI Agent        │
│  Platform        │     │  (Docker)        │     │  (claude, codex) │
│  (Feishu,        │     │  :9111/:9810/    │     │  or Docker exec  │
│   DingTalk,      │     │  :9820           │     │  into sandbox    │
│   WeChat, etc.)  │     └──────────────────┘     └──────────────────┘
└──────────────────┘              │
                                  │ Mounted config.toml
                                  │ or Web UI config
                                  ▼
                         ┌──────────────────┐
                         │  Local JSON      │
                         │  session state   │
                         │  ~/.cc-connect/  │
                         └──────────────────┘
```

### Port Mapping

| Port | Purpose | Default | kyb-infra Mapping |
|------|---------|---------|-------------------|
| 9111 | Webhook receiver | 9111 | 9111 |
| 9810 | Bridge WebSocket | 9810 | 9810 |
| 9820 | HTTP REST API (Web UI) | 9820 | 9820 |

### Network

- Container joins `kyb-net` (Docker bridge network)
- Can reach all infra services by container name
- Can exec into kyb sandbox containers via Docker socket (if mounted)

---

## 2. Dockerfile

Create a multi-stage Dockerfile that downloads the prebuilt Go binary from GitHub Releases.

```dockerfile
# /home/dev/projects/kyb/docker/cc-connect/Dockerfile

# ---- Build Stage ----
FROM alpine:3.20 AS builder

ARG CC_CONNECT_VERSION=v1.3.2
ARG TARGETARCH=amd64

RUN apk add --no-cache curl ca-certificates

# Download prebuilt binary from GitHub Releases
RUN curl -fsSL \
  "https://github.com/chenhg5/cc-connect/releases/download/${CC_CONNECT_VERSION}/cc-connect-linux-${TARGETARCH}.tar.gz" \
  -o /tmp/cc-connect.tar.gz && \
  tar xzf /tmp/cc-connect.tar.gz -C /usr/local/bin/ && \
  chmod +x /usr/local/bin/cc-connect

# ---- Runtime Stage ----
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

# Copy binary
COPY --from=builder /usr/local/bin/cc-connect /usr/local/bin/cc-connect

# Create config directory
RUN mkdir -p /root/.cc-connect

# Expose ports
EXPOSE 9111 9810 9820

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD cc-connect version || exit 1

# Default command
ENTRYPOINT ["cc-connect"]

# Default: run with web UI enabled
CMD ["web"]
```

### Build Command

```bash
cd /home/dev/projects/kyb
docker build -t kyb-cc-connect:latest \
  -f docker/cc-connect/Dockerfile \
  --build-arg CC_CONNECT_VERSION=v1.3.2 \
  --build-arg TARGETARCH=arm64 \
  .
```

Note: For ARM64 (Orbstack on M-series Mac), use `TARGETARCH=arm64`. The cc-connect binary is available for both amd64 and arm64.

---

## 3. Docker Run Command

### Minimal (web UI only, configure via browser)

```bash
docker run -d \
  --name kyb-infra-cc-connect \
  --network kyb-net \
  --restart unless-stopped \
  -p 9111:9111 \
  -p 9810:9810 \
  -p 9820:9820 \
  -v cc-connect-data:/root/.cc-connect \
  kyb-cc-connect:latest
```

### With config file mount (pre-configured)

```bash
docker run -d \
  --name kyb-infra-cc-connect \
  --network kyb-net \
  --restart unless-stopped \
  -p 9111:9111 \
  -p 9810:9810 \
  -p 9820:9820 \
  -v cc-connect-data:/root/.cc-connect \
  -v /home/dev/kyb/cc-connect/config.toml:/root/.cc-connect/config.toml:ro \
  -e FEISHU_APP_ID="${FEISHU_APP_ID}" \
  -e FEISHU_APP_SECRET="${FEISHU_APP_SECRET}" \
  -e DINGTALK_APP_KEY="${DINGTALK_APP_KEY}" \
  -e DINGTALK_APP_SECRET="${DINGTALK_APP_SECRET}" \
  -e WECHAT_WORK_CORP_ID="${WECHAT_WORK_CORP_ID}" \
  -e WECHAT_WORK_AGENT_ID="${WECHAT_WORK_AGENT_ID}" \
  -e WECHAT_WORK_SECRET="${WECHAT_WORK_SECRET}" \
  -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  kyb-cc-connect:latest \
  cc-connect  # Run in server mode (no web UI)
```

### With optional Docker socket (to exec into sandboxes)

Mounting `/var/run/docker.sock` allows cc-connect to run agents inside kyb sandbox containers:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

This is optional -- cc-connect can also run agents directly in its own container if the agent binary is installed.

---

## 4. Docker Compose Definition

```yaml
# /home/dev/projects/kyb/docker-compose.infra.yml (add to existing)

  cc-connect:
    image: kyb-cc-connect:latest
    container_name: kyb-infra-cc-connect
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "9111:9111"   # Webhook receiver
      - "9810:9810"   # Bridge WebSocket
      - "9820:9820"   # Web UI / REST API
    volumes:
      - cc-connect-data:/root/.cc-connect
      - /var/run/docker.sock:/var/run/docker.sock:ro  # Optional
    environment:
      # Feishu (primary)
      FEISHU_APP_ID: "${FEISHU_APP_ID}"
      FEISHU_APP_SECRET: "${FEISHU_APP_SECRET}"

      # DingTalk
      DINGTALK_APP_KEY: "${DINGTALK_APP_KEY}"
      DINGTALK_APP_SECRET: "${DINGTALK_APP_SECRET}"

      # WeChat Work
      WECHAT_WORK_CORP_ID: "${WECHAT_WORK_CORP_ID}"
      WECHAT_WORK_AGENT_ID: "${WECHAT_WORK_AGENT_ID}"
      WECHAT_WORK_SECRET: "${WECHAT_WORK_SECRET}"

      # Telegram
      TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"

      # AI Provider (for Claude Code)
      ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"

      # cc-connect config
      TZ: Asia/Shanghai

volumes:
  cc-connect-data:
```

---

## 5. Config Template

### config.toml (for pre-configured mount)

```toml
# /home/dev/kyb/cc-connect/config.toml
# All ${ENV_VAR} values are substituted at runtime

[log]
level = "info"  # debug, info, warn, error

# ── Projects ──────────────────────────────────────────────

[[projects]]
name = "kyb-infra"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/home/dev/projects/kyb"
mode = "default"

[[projects.platforms]]
type = "feishu"
app_id = "${FEISHU_APP_ID}"
app_secret = "${FEISHU_APP_SECRET}"

# ── Provider Configuration ────────────────────────────────

[[providers]]
name = "anthropic"
api_key = "${ANTHROPIC_API_KEY}"
agent_types = ["claudecode"]

# ── Optional: DingTalk ────────────────────────────────────

# [[projects]]
# name = "kyb-infra-dingtalk"
# 
# [projects.agent]
# type = "claudecode"
# 
# [[projects.platforms]]
# type = "dingtalk"
# app_key = "${DINGTALK_APP_KEY}"
# app_secret = "${DINGTALK_APP_SECRET}"

# ── Optional: WeChat Work ─────────────────────────────────

# [[projects]]
# name = "kyb-infra-wechat"
# 
# [projects.agent]
# type = "claudecode"
#  
# [[projects.platforms]]
# type = "wechat_work"
# corp_id = "${WECHAT_WORK_CORP_ID}"
# agent_id = "${WECHAT_WORK_AGENT_ID}"
# secret = "${WECHAT_WORK_SECRET}"

# ── Optional: Telegram ────────────────────────────────────

# [[projects]]
# name = "kyb-infra-telegram"
# 
# [projects.agent]
# type = "claudecode"
# 
# [[projects.platforms]]
# type = "telegram"
# bot_token = "${TELEGRAM_BOT_TOKEN}"
```

### Alternative: Web UI Configuration

cc-connect provides a built-in web UI for visual configuration. To use it:

```bash
# Run in web mode (one-time setup)
docker run --rm -it \
  --name kyb-infra-cc-connect-web \
  --network kyb-net \
  -p 9820:9820 \
  -v cc-connect-data:/root/.cc-connect \
  kyb-cc-connect:latest \
  cc-connect web

# Access at http://localhost:9820
# Configure projects, platforms, agents via browser
# Config is saved to /root/.cc-connect/config.toml
```

After web configuration, restart in server mode:

```bash
docker start kyb-infra-cc-connect
```

---

## 6. Token / Credential Requirements

The user needs to provide these tokens. They can be passed as env vars or stored in a `config.toml`:

### Primary Platforms

| Platform | Credentials Needed | How to Obtain |
|----------|-------------------|---------------|
| **Feishu / Lark** | `FEISHU_APP_ID`, `FEISHU_APP_SECRET` | Feishu开发者后台 -> 创建应用 -> 凭证与基础信息 |
| **DingTalk** | `DINGTALK_APP_KEY`, `DINGTALK_APP_SECRET` | 钉钉开放平台 -> 创建应用 -> AppKey/AppSecret |
| **WeChat Work** | `WECHAT_WORK_CORP_ID`, `WECHAT_WORK_AGENT_ID`, `WECHAT_WORK_SECRET` | 企业微信管理后台 -> 应用管理 -> 创建应用 |
| **Telegram** | `TELEGRAM_BOT_TOKEN` | Message @BotFather on Telegram |

### Optional

| Credential | Purpose |
|------------|---------|
| `ANTHROPIC_API_KEY` | For projects using Claude Code |
| `OPENAI_API_KEY` | For projects using Codex |

---

## 7. How to Pass Tokens (Two Methods)

### Method A: Environment Variables (Recommended for Docker)

Pass tokens at container start time:

```bash
# Create .env file (DO NOT commit to git)
cat > /home/dev/kyb/cc-connect/.env << 'EOF'
FEISHU_APP_ID=cli_xxxxxxxxxxxxxx
FEISHU_APP_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxx
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxx
EOF

# Or add to systemd environment or Docker Compose .env file

# Run with env file
docker run -d \
  --name kyb-infra-cc-connect \
  --env-file /home/dev/kyb/cc-connect/.env \
  ...
```

### Method B: config.toml (Mounted)

Tokens embedded directly in the config file (with restricted file permissions):

```bash
mkdir -p /home/dev/kyb/cc-connect
cat > /home/dev/kyb/cc-connect/config.toml << 'EOF'
[log]
level = "info"

[[projects]]
name = "kyb-infra"

[projects.agent]
type = "claudecode"

[[projects.platforms]]
type = "feishu"
app_id = "cli_xxxxxxxxxxxxxx"
app_secret = "xxxxxxxxxxxxxxxxxxxxxxxxxx"
EOF

chmod 600 /home/dev/kyb/cc-connect/config.toml
```

---

## 8. Agent Integration Modes

cc-connect can run AI agents in two modes:

### Mode 1: Direct Execution (agent inside cc-connect container)

Install the AI agent binary (e.g., `claude`) inside the cc-connect container. cc-connect spawns the agent directly.

```dockerfile
# Extend the Dockerfile to include Claude Code
FROM kyb-cc-connect:latest AS with-claude
RUN npm install -g @anthropic-ai/claude-code
ENV ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ENV ANTHROPIC_MODEL=deepseek-v4-flash[1m]
```

**Pros:** Simple, self-contained.
**Cons:** Can't use kyb sandbox isolation; agent runs in same container as cc-connect.

### Mode 2: Docker Exec (agent in separate sandbox container)

cc-connect uses the Docker socket (`/var/run/docker.sock`) to exec commands into kyb sandbox containers. Each agent session gets its own sandbox.

**Pros:** Full kyb sandbox isolation; can use `kyb create` for per-project environments.
**Cons:** Requires Docker socket mount; more complex.

### Recommendation

Start with **Mode 1** (direct execution) for simplicity. If sandbox isolation is needed, switch to Mode 2.

---

## 9. Deployment Steps (When Tokens Are Ready)

### Phase 1: Build & Deploy (15 minutes)

```bash
# 1. Build Docker image
cd /home/dev/projects/kyb
docker build -t kyb-cc-connect:latest -f docker/cc-connect/Dockerfile .

# 2. Create data volume
docker volume create cc-connect-data

# 3. Run container (web mode for initial config)
docker run -d \
  --name kyb-infra-cc-connect \
  --network kyb-net \
  --restart unless-stopped \
  -p 9111:9111 \
  -p 9810:9810 \
  -p 9820:9820 \
  -v cc-connect-data:/root/.cc-connect \
  kyb-cc-connect:latest

# 4. Access web UI at http://localhost:9820
# Configure projects, platforms, and agents
```

### Phase 2: Configure Platforms (15 minutes per platform)

```bash
# 1. Open web UI
open http://localhost:9820

# 2. Create project "kyb-infra"
# 3. Add agent type "claudecode"
# 4. Add platform credentials:
#    - Feishu: app_id + app_secret
#    - DingTalk: app_key + app_secret
#    - etc.

# 5. Verify registration
#    - Send a message to the bot on each platform
#    - Check cc-connect logs: docker logs kyb-infra-cc-connect
```

### Phase 3: Test & Verify (30 minutes)

```bash
# 1. Check container is running
docker ps --filter name=kyb-infra-cc-connect

# 2. Check logs
docker logs kyb-infra-cc-connect

# 3. Test from Feishu
#    Send "ping" to the bot -> should respond "pong"
#    Send "status" -> should list available agents

# 4. Test agent execution
#    Send "run: echo hello" -> agent should execute and return result

# 5. Verify session persistence
docker exec kyb-infra-cc-connect ls -la /root/.cc-connect/
```

---

## 10. Upgrades

cc-connect supports built-in self-update:

```bash
docker exec kyb-infra-cc-connect cc-connect update
```

Or rebuild the Docker image with a new version tag:

```bash
docker build \
  -t kyb-cc-connect:v1.4.0 \
  --build-arg CC_CONNECT_VERSION=v1.4.0 \
  -f docker/cc-connect/Dockerfile .

# Stop, replace, and restart
docker stop kyb-infra-cc-connect
docker rm kyb-infra-cc-connect

# Run with new image
docker run -d \
  --name kyb-infra-cc-connect \
  --network kyb-net \
  --restart unless-stopped \
  -p 9111:9111 -p 9810:9810 -p 9820:9820 \
  -v cc-connect-data:/root/.cc-connect \
  kyb-cc-connect:v1.4.0
```

---

## 11. Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| Container exits immediately | Missing binary or architecture mismatch | Check `docker logs`; rebuild with correct TARGETARCH |
| Web UI not accessible (9820) | Port conflict | Check if another container uses 9820; change port mapping |
| Platform registration fails | Wrong credentials | Verify app_id/app_secret in platform admin console |
| Agent not responding | Agent binary not found | Install agent inside container or mount Docker socket |
| "connection refused" to platform | Network egress blocked | Check sing-box proxy config; add platform domains to direct route |
| Config lost after restart | Volume not mounted or wrong path | Verify `cc-connect-data` volume mount; check config path |
| ARM64 binary fails | Wrong arch | Use `TARGETARCH=arm64` in build args |

---

## 12. Related Documents

- Research doc: `/home/dev/projects/kyb/docs/infra/cc-connect-research.md`
- Master report: `/home/dev/projects/kyb/docs/infra/MASTER-REPORT.md`
- GitHub: https://github.com/chenhg5/cc-connect
- Config example: https://github.com/chenhg5/cc-connect/blob/main/config.example.toml
- Installation: https://github.com/chenhg5/cc-connect/blob/main/INSTALL.md

---

## What We Need From You

1. **Feishu App ID + Secret** (primary platform)
2. **DingTalk App Key + Secret** (secondary)
3. **WeChat Work credentials** (if needed)
4. **Telegram Bot Token** (if needed)
5. **Decision on agent execution mode**: Direct (in-container) or Docker exec (sandboxed)

Once tokens are provided, deployment takes ~30 minutes.

---

> Written for kyb infra-boss cc-connect deployment initiative.
> ／人◕ ‿‿ ◕人＼
