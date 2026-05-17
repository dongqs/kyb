# CLAUDE.md

AI 开发沙箱配置仓库。用 Docker 容器提供隔离的开发环境。

> 容器环境、DID 系统、缓存等详见 [../docs/container.md](../docs/container.md) 和 [../docs/docker-in-docker.md](../docs/docker-in-docker.md)。

## 关键文件

- `Dockerfile` — 沙箱镜像定义
- `entrypoint.sh` — 容器启动入口
- `bin/kyb` — CLI 工具
- `mise.config.toml` — mise 工具链配置
- `~/.config/kyb/config.yml` — 用户级项目配置

## 常用操作

- `kyb build` — 构建基础镜像
- `kyb create <name>` — 创建并启动沙箱
- `kyb enter <name>` — 进入沙箱
- `kyb ps` — 列出沙箱
- `kyb stop <name>` — 停止沙箱
- `kyb rm <name>` — 删除沙箱
- `kyb prune` — 删除所有沙箱
- `kyb notify <done|blocked|urgent> <msg>` — TTS 主动通知

## 修改沙箱配置

1. 编辑 `Dockerfile` / `mise.config.toml`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`：

```yaml
base:
  image: ~/kyb
  proxy: socks5://host.orb.internal:2080
  no_proxy: .leyantech.com,...
  claude_default_model: flash

projects:
  my-project:
    path: "~/path/to/project"
    base_branch: master
    ports: [3000:3000]           # 可选
    mounts_rw: [/host/path:/container/path]  # 可选
    mounts_ro: [/host/path:/container/path]  # 可选
    timezone: Asia/Shanghai      # 可选
    proxy: http://local:3128     # 可选，覆盖 base.proxy
    extra_prompt: "..."          # 可选
```

## 沙箱环境

- **PostgreSQL 16** — trust 认证，Asia/Shanghai
- **mig25** — DSN 配在项目 `.env`
- **Node LTS** — mise 管理
- **Claude Code** — npm 全局安装

## 宿主机挂载

- `~/.ssh` → `/home/dev/.ssh` (只读)
- `~/.gitconfig` → `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → `/home/dev/.claude-host-settings.json` (只读)
- `~/.claude/skills` → `/home/dev/.claude-skills-host` (只读)
- `~/projects` → `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问
- `mounts_rw` / `mounts_ro` → 项目级外部目录挂载

## TTS Server（文本转语音）

宿主机 macOS 上运行，通过 `say`/`afplay` 朗读文本。**不运行在容器内部。**

### 宿主机操作（CLI）

```bash
kyb tts start          # 启动 HTTP 服务（默认 10666）
kyb tts stop           # 停止服务
kyb tts speak 你好     # 直接说话（不经过 HTTP）
kyb tts ping           # 播放提示音
kyb tts done           # 说话 + 提示音
kyb notify done "编译完成"     # 三级通知：任务完成（一声 ping）
kyb notify blocked "服务器异常" # 三级通知：需要人工干预（两声 ping）
kyb notify urgent "准备推送"   # 三级通知：外部操作确认（三声 ping）
```

### 容器内使用（`kyb notify`）

容器内 AI 可通过 `kyb notify` 主动叫人。容器镜像已预装 kyb CLI。

```bash
# 任务完成时
kyb notify done "编译通过，测试全部绿"

# 巡检异常需人工介入
kyb notify blocked "检测到服务器 502 错误，请检查"

# 外部操作前确认
kyb notify urgent "准备推送生产环境，请确认"
```

容器内 `kyb notify` 自动通过 HTTP 调用宿主机 TTS 服务，无需手动指定端点。

### 容器内访问（HTTP API）

容器内 agent 可直接通过 `host.docker.internal` 调用 TTS 服务：

```bash
# 健康检查
curl http://host.docker.internal:10666/health

# 获取可用语音列表
curl http://host.docker.internal:10666/voices

# 英文朗读
curl "http://host.docker.internal:10666/speak?text=Hello+world"

# 中文朗读
curl -X POST http://host.docker.internal:10666/speak \
  -H "Content-Type: application/json" \
  -d '{"text":"你好世界"}'

# 完成通知（说话 + 提示音）
curl "http://host.docker.internal:10666/done?text=构建完成"

# 三级通知（带 retry_hint 返回值）
curl -X POST http://host.docker.internal:10666/notify \
  -H "Content-Type: application/json" \
  -d '{"level":"blocked","text":"服务器异常"}'
```

OpenAPI 规范：`http://host.docker.internal:10666/openapi.yml`

### 通知等级

| 等级 | 触发场景 | TTS 行为 | 提示音 |
|------|---------|---------|--------|
| `done` | 长时间任务完成 | 正常语速说消息 | 一声 Ping |
| `blocked` | 巡检发现异常需人工干预 | 稍慢语速说消息 | 两声 Ping |
| `urgent` | 影响容器外部的操作前确认 | 慢速说消息 | 三声 Ping |

blocked/urgent 通知首次后等待 60 秒，用户未回应则重试（最多 3 次）。

### 环境要求

- macOS 系统（依赖 `say` 和 `afplay` 命令）
- 端口可通过 `TTS_PORT` 环境变量修改（默认 10666）
- 仅 macOS 宿主机可用
