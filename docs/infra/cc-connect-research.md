# cc-connect Research

**Date:** 2026-05-22
**Source:** https://github.com/chenhg5/cc-connect

---

## 1. What is cc-connect?

cc-connect is a **Go binary** that bridges local AI coding agents to messaging platforms. It lets you control AI agents (Claude Code, Codex, Gemini CLI, Cursor Agent, Kimi CLI, Qoder CLI, OpenCode, iFlow CLI, etc.) from chat apps on your phone or any device.

### Supported Platforms (12)

| Platform | Connection | Public IP Needed? |
|----------|-----------|-------------------|
| Feishu / Lark | WebSocket | No |
| DingTalk | Stream | No |
| WPS Xiezuo | WebSocket | No |
| Telegram | Long Polling | No |
| Slack | Socket Mode | No |
| Discord | Gateway | No |
| Weibo | WebSocket | No |
| WeChat Work | WebSocket / Webhook | No (WS) |
| Weixin (personal) | HTTP long polling (ilink) | No |
| LINE | Webhook | Yes |
| QQ (NapCat/OneBot) | WebSocket | No |
| QQ Bot (Official) | WebSocket | No |

### Key Features

- Multi-agent orchestration (relay between bots in one group chat)
- Session management with auto-reset on idle (default 30 min)
- Scheduled tasks via natural language cron
- Voice (STT/TTS) and image support
- Web admin UI (built-in, no extra deps)
- OS-user isolation via `run_as_user`
- Built-in i18n (en/zh/zh-TW/ja/es)

---

## 2. Can It Run in Docker?

**No official Docker image exists.** The CI pipeline only builds native binaries (linux/darwin/windows amd64 + arm64) and publishes them as GitHub release tarballs. There is:

- No Dockerfile in the repository
- No Docker Hub image under `chenhg5/cc-connect`
- No ghcr.io image under `ghcr.io/chenhg5/cc-connect`
- No `docker` targets in the Makefile or goreleaser config
- Zero mentions of Docker in the codebase

**However, it can trivially run in Docker** — it is a single static Go binary with no external runtime dependencies. One would need to:

1. Download the prebuilt Linux binary from GitHub Releases
2. Bundle it into a minimal `scratch` or `alpine` image
3. Mount a config directory and the Docker socket (if running agents in containers)

---

## 3. Infrastructure Dependencies

| Dependency | Required? | Details |
|-----------|-----------|---------|
| **Database** | **No** | Stores session state as local JSON files in `~/.cc-connect/` (or configurable `data_dir`). No PostgreSQL/MySQL/Redis needed. |
| **AI Agent binary** | **Yes** | At least one of: Claude Code, Codex, Gemini CLI, etc. Must be installed and available on PATH. |
| **Messaging platform credentials** | **Yes** | App ID/Secret, Bot Tokens per platform (Feishu, Telegram, etc.) |
| **Config file** | **Yes** | `config.toml` in `~/.cc-connect/` or current directory |
| **Public IP** | **Mostly No** | LINE webhook needs public URL; WeChat Work webhook mode needs public URL. All other platforms use WebSocket/long-polling. |

---

## 4. Ports

| Port | Purpose | Default | Configurable? |
|------|---------|---------|---------------|
| 9111 | Webhook receiver | 9111 | Yes (via `[webhook]` config) |
| 9810 | Bridge WebSocket (external adapters) | 9810 | Yes |
| 9820 | HTTP REST API (web UI, TUI, etc.) | 9820 | Yes (`[api]` config) |

---

## 5. Configuration

Configuration is via TOML (`config.toml`). Three lookup locations (first wins):
1. `-config <path>` CLI flag
2. `./config.toml` (current directory)
3. `~/.cc-connect/config.toml` (recommended global location)

**Alternatively**, the Web UI (`cc-connect web`) provides visual configuration and is the recommended approach.

### Config Structure

```toml
[log]
level = "info"  # debug, info, warn, error

[[projects]]
name = "my-project"

[projects.agent]
type = "claudecode"  # or codex, cursor, gemini, qoder, opencode, iflow

[projects.agent.options]
work_dir = "/path/to/project"
mode = "default"

# Platform configs per project
[[projects.platforms]]
type = "feishu"
app_id = "${FEISHU_APP_ID}"
app_secret = "${FEISHU_APP_SECRET}"
```

Global providers can be defined once and referenced by name:

```toml
[[providers]]
name = "anthropic"
api_key = "${ANTHROPIC_API_KEY}"
agent_types = ["claudecode"]
```

All string values support `${ENV_VAR}` substitution.

---

## 6. How to Deploy in kyb-infra

### Option A: Docker container (recommended — needs Dockerfile creation)

1. Create a Dockerfile that:
   - Uses `golang:1.22-alpine` as build stage
   - Builds cc-connect from source (or downloads prebuilt binary)
   - Copies binary to minimal runtime image
2. Mount `/path/to/config.toml` at runtime
3. Mount the Docker socket if running agents inside sibling containers
4. Expose ports 9111/9810/9820

### Option B: Direct binary on a kyb container

```bash
# Install binary
curl -L -o /usr/local/bin/cc-connect \
  https://github.com/chenhg5/cc-connect/releases/latest/download/cc-connect-linux-amd64
chmod +x /usr/local/bin/cc-connect

# Configure
mkdir -p ~/.cc-connect
# Create config.toml with desired projects/platforms

# Run
cc-connect web  # one-time: configure via browser
cc-connect      # start service
```

### Integration Points with kyb-infra

- **Agent Execution**: cc-connect needs access to the AI agent binary (e.g., `claude`, `codex`). In kyb-infra, agents live inside kyb sandbox containers. cc-connect could either run inside the sandbox container or use the Docker CLI to exec into sandboxes.
- **No Database**: Fits well with kyb-infra's PostgreSQL-centric stack — no additional DB provisioning needed.
- **Config Management**: Config could be injected via Docker Compose env vars + init container, or stored as a mounted `config.toml`.
- **Port Mapping**: If multiple instances are needed, port assignments must not conflict.

---

## 7. Recommendation

cc-connect is a **well-designed, low-dependency bridge** that fits the kyb ecosystem well because:

- **No DB dependency** aligns with kyb-infra's preference for minimal external services
- **Go binary** means easy containerization and low resource usage
- **Platform diversity** (Feishu, DingTalk, Telegram, etc.) matches the team's communication needs
- **Multi-project support** means one process can serve multiple teams/projects

However, since there is no official Docker image, the kyb-infra team would need to:

1. Create and maintain a Dockerfile
2. Publish to a private registry
3. Handle upgrades manually (the binary supports `cc-connect update`)

**Next steps:**
- Create a `docker/cc-connect/Dockerfile` in kyb-infra
- Add a `docker-compose.yml` service definition
- Wire up with env vars for credentials
- Test with Feishu (primary platform for the team)
- Benchmark to see if running inside kyb sandbox or as a sidecar makes more sense

---

## References

- GitHub: https://github.com/chenhg5/cc-connect
- Config example: https://github.com/chenhg5/cc-connect/blob/main/config.example.toml
- Installation guide: https://github.com/chenhg5/cc-connect/blob/main/INSTALL.md
- Latest release (v1.3.2): https://github.com/chenhg5/cc-connect/releases/tag/v1.3.2
