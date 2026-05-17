# CLAUDE.md

AI 开发沙箱配置仓库。用 Docker 容器提供隔离的开发环境。

## 关键文件

- `Dockerfile` — 沙箱镜像定义
- `entrypoint.sh` — 容器启动入口
- `bin/kyb` — CLI 工具
- `~/.config/kyb/config.yml` — 用户级项目配置

## 常用操作

- `kyb build` — 构建基础镜像
- `kyb create <name>` — 创建并启动沙箱
- `kyb enter <name>` — 进入沙箱
- `kyb ps` — 列出沙箱
- `kyb stop <name>` — 停止沙箱
- `kyb rm <name>` — 删除沙箱
- `kyb prune` — 删除所有沙箱

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`：

```yaml
projects:
  my-project:
    path: "~/path/to/project"
    base_branch: master
    ports:                    # 可选
    - 3000:3000
    symlinks:                 # 可选
    - shared/vendor
    mounts_rw:                # 可选
    - /host/path:/container/path
    mounts_ro:                # 可选
    - /host/path:/container/path
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
```

### 容器内访问（HTTP API）

容器内 agent 可通过 `host.docker.internal` 调用：

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
```

OpenAPI 规范：`http://host.docker.internal:10666/openapi.yml`

### 环境要求

- macOS 系统（依赖 `say` 和 `afplay` 命令）
- 端口可通过 `TTS_PORT` 环境变量修改（默认 10666）
- 仅 macOS 宿主机可用
