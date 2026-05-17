# kyb 主动通知（TTS Notify）设计

容器内 AI 在有需要时主动通过 TTS 叫人回来。

## 动机

kyb 已提供 TTS 服务（macOS 宿主机），容器 CLAUDE.md 也文档化了 TTS 的 curl 调用方式。但缺少结构化引导——AI 没有明确的规则来判断*什么时候*应该通知用户。本设计让 AI 更主动地在关键节点通知用户，并定义统一的通知等级和行为。

## 通知等级

| 等级 | 触发场景 | TTS 行为 | 提示音 |
|------|---------|---------|--------|
| `done` | 长时间任务完成（编译、测试、部署等） | 正常语速（180）说消息 | 一声 Ping |
| `blocked` | 日常巡检发现异常，需要人工干预（服务器异常、账单异常等） | 稍慢语速说消息 | 两声 Ping |
| `urgent` | 影响容器外部的操作前确认（推送服务器、生产环境变更等） | 慢速+大声说消息 | 三声 Ping |

## 架构

宿主机和容器内使用同一套 `kyb notify` 命令，底层根据运行环境自动选择传输方式。

```
宿主机 (macOS):
  $ kyb notify done "编译完成"
      └─ Kyb::TTSServer.speak (直接调 say/afplay)

容器内 (Linux):
  $ kyb notify done "编译完成"
      └─ HTTP POST host.docker.internal:10666/notify
          └─ TTS 服务 → say/afplay

AI agent 在容器内统一用:
  $ kyb notify blocked "服务器响应异常，状态码 502"
  无需关心底层是 HTTP 还是本地调用。
```

### 双后端策略

`kyb notify` 子命令在 `Kyb::CLI` 中实现，运行时检测环境：

- **macOS 宿主机**: 调用 `Kyb::TTSServer.speak + ping`（现有 TTS module 复用）
- **Docker 容器内**: HTTP POST 到 `host.docker.internal:10666/notify`
- **其他 Linux**: 同容器逻辑（但需要能访问 TTS 服务，否则报错）

环境检测方式：`Kyb::Docker.running?` 或检查 `/.dockerenv` 文件。

## TTS 服务增强

### 新增 `/notify` 端点

```http
POST /notify
Content-Type: application/json

{
  "level": "blocked",
  "text": "检测到服务器 502 错误，需要人工介入"
}
```

端点行为：
1. 根据 level 选择 voice/rate：
   - `done`: Tingting, rate 180, 1x ping
   - `blocked`: Tingting, rate 160, 2x ping
   - `urgent`: Tingting, rate 140, 3x ping (升高音量)
2. 返回 JSON 响应，包含 retry_hint：

```json
{
  "status": "ok",
  "level": "blocked",
  "retry_hint": "blocked/urgent: notify again after 60s if user hasn't responded (max 3 retries)"
}
```

### 与现有端点的关系

- `/speak` — 保持现有接口不变（通用朗读）
- `/done` — 保持现有接口不变（说话+pong）
- `/notify` — 新增，封装三级通知逻辑

## `kyb notify` 命令

在 `lib/kyb/cli/tts.rb` 中扩展 notify 子命令：

```bash
kyb notify done "编译通过"
kyb notify blocked "服务器异常，需要人工介入"  
kyb notify urgent "准备向生产环境推送，请确认"
```

实现逻辑：

```
notify(level, message)
  ├─ 检测运行环境
  ├─ macOS → Kyb::TTSServer.speak(message, voice, rate)
  │          + ping 根据 level 重复 1-3 次
  └─ 其他  → HTTP POST host.docker.internal:10666/notify
              {level: level, text: message}
```

### 命令注册

在 `lib/kyb/cli.rb` 的 `dispatch` 中新增：

```ruby
when 'notify'
  level = args[0]
  message = args[1..].join(' ')
  Kyb.die("Usage: kyb notify <done|blocked|urgent> <message>") unless level && !message.empty?
  Kyb.die("level must be done/blocked/urgent") unless %w[done blocked urgent].include?(level)
  notify(level, message)
```

## 容器内安装 kyb CLI

Dockerfile 追加层，复制 kyb 源码到容器并建立 `kyb` 命令：

```dockerfile
# kyb CLI for notify command (copy lib, create symlink)
COPY --chown=dev:dev lib /home/dev/.kyb/lib
RUN mkdir -p /home/dev/.kyb/bin && \
    printf '#!/usr/bin/env ruby\n$LOAD_PATH.unshift("/home/dev/.kyb/lib")\nrequire "kyb"\nKyb::CLI.dispatch(ARGV)\n' \
    > /home/dev/.kyb/bin/kyb && \
    chmod +x /home/dev/.kyb/bin/kyb && \
    ln -s /home/dev/.kyb/bin/kyb /home/dev/.local/bin/kyb
```

这样容器内 `kyb notify` 即可工作，其他命令（build/create/enter 等）会自动报错，因为容器内没有对应能力。

## 容器 CLAUDE.md 规则

在 entrypoint.sh 生成的容器 CLAUDE.md 中追加「主动通知」章节。

### 使用 `kyb notify`

```bash
# 任务完成时
kyb notify done "编译通过，测试全部绿"

# 日常巡检发现异常，需要人工干预
kyb notify blocked "检测到服务器 502 错误，请检查"

# 涉及容器外部的操作前确认
kyb notify urgent "准备推送生产环境，请确认"
```

### 使用规则
- **done**: 任何超过 30 秒的任务完成后必通知
- **blocked**: 
  1. 日常巡检发现异常时立即通知（服务器异常、账单异常等需要人工干预的场景）
  2. 等待 60 秒，如果用户未回应则重复通知
- **urgent**:
  1. 涉及容器外部的操作前立即通知（推送服务器、生产环境变更等；本地操作不限制）
  2. 等待 60 秒，如果用户未回应则重复通知

### 重复通知机制
- blocked/urgent 首次通知后，等待约 60 秒
- 判断用户是否已回应（会话是否继续），如无则重新通知
- AI 等待约 60 秒，判断用户是否已回应，如无则重新调用 `kyb notify`
- 重复 3 次后不再打扰，改为写日志说明已尝试通知用户

## 实现清单

1. **TTS 服务**: 新增 `/notify` 端点，实现三级逻辑（`lib/kyb/tts_server.rb`）
2. **`kyb notify` CLI**: 在 `lib/kyb/cli/tts.rb` 中新增 notify 子命令（双后端：macOS 本地 + 容器 HTTP）
3. **Dockerfile**: 新增层复制 kyb 源码到容器，确保容器内 `kyb notify` 可用
4. **容器 entrypoint**: 修改 `entrypoint.sh`，CLAUDE.md 追加主动通知章节
5. **测试**: 更新测试（TTS 端点和 CLI 命令）

## 不涉及

- 不修改现有 `/speak` 和 `/done` 端点行为
- 不增加 watcher/daemon 进程（依赖 AI 自行实现重试逻辑）
- 不修改 Docker 网络配置（已有 host.docker.internal 访问能力）
- 容器内其他 kyb 命令（build/create/enter 等）保持不可用
