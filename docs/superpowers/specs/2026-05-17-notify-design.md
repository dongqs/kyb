# kyb 主动通知（TTS Notify）设计

容器内 AI 在有需要时主动通过 TTS 叫人回来。

## 动机

kyb 已提供 TTS 服务（macOS 宿主机），容器 CLAUDE.md 也文档化了 TTS 的 curl 调用方式。但缺少结构化引导——AI 没有明确的规则来判断*什么时候*应该通知用户。本设计让 AI 更主动地在关键节点通知用户，并定义统一的通知等级和行为。

## 通知等级

| 等级 | 触发场景 | TTS 行为 | 提示音 |
|------|---------|---------|--------|
| `done` | 长时间任务完成（编译、测试、部署等） | 正常语速（180）说消息 | 一声 Ping |
| `blocked` | 遇到错误、缺信息、需要用户决策 | 稍慢语速说消息 | 两声 Ping |
| `urgent` | 高风险操作前确认（删除、覆盖、push 等） | 慢速+大声说消息 | 三声 Ping |

## 架构

```
┌─────────────────────────┐      HTTP POST /notify       ┌──────────────────┐
│  Docker 容器内 AI        │ ──────────────────────────▶  │  macOS TTS 服务   │
│  (Ruby Net::HTTP / curl) │                              │  localhost:10666  │
│                          │ ◀────────────────────────── │  (say + afplay)   │
│  CLAUDE.md 指导行为规则   │      返回: retry_hint        │                   │
└─────────────────────────┘                              └──────────────────┘
                                                                │
                                                         ┌──────┴──────┐
                                                         │ kyb notify  │
                                                         │ (宿主快捷命令) │
                                                         └─────────────┘
```

### 触发链路

- **容器 AI → TTS 服务**: AI 用 Ruby `Net::HTTP` 或 curl 直接调 `host.docker.internal:10666/notify`
- **宿主机用户**: `kyb notify <level> <message>` 作为平行快捷命令

## TTS 服务增强

### 新增 `/notify` 端点

```http
POST /notify
Content-Type: application/json

{
  "level": "blocked",
  "text": "缺少数据库连接信息"
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

宿主机 CLI 扩展，在 `lib/kyb/cli/tts.rb` 中新增：

```bash
kyb notify done "编译通过"
kyb notify blocked "缺少数据库连接信息"  
kyb notify urgent "准备删除生产分支，请确认"
```

实现：直接调 `Kyb::TTSServer.speak` + 对应 ping 次数，复用现有 module。

## 容器 CLAUDE.md 规则

在 entrypoint.sh 生成的容器 CLAUDE.md 中追加「主动通知」章节。

### 通知等级
- **done** — 任务完成（一声提示音）
- **blocked** — 需要用户决策/帮忙（两声提示音）
- **urgent** — 高风险操作前确认（三声提示音）

### 调用方式

Ruby (推荐):
```ruby
require 'net/http'
Net::HTTP.post(
  URI('http://host.docker.internal:10666/notify'),
  {level: 'done', text: '编译完成'}.to_json,
  {'Content-Type' => 'application/json'}
)
```

curl:
```bash
curl -X POST http://host.docker.internal:10666/notify \
  -H 'Content-Type: application/json' \
  -d '{"level":"done","text":"编译完成"}'
```

### 使用规则
- **done**: 任何超过 30 秒的任务完成后必通知
- **blocked**: 
  1. 遇到无法自行解决的错误或需要用户输入时立即通知
  2. 等待 60 秒，如果用户未回应则重复通知
- **urgent**:
  1. 执行破坏性操作前立即通知 (git push --force, 删除文件, 覆写配置等)
  2. 等待 60 秒，如果用户未回应则重复通知

### 重复通知机制
- blocked/urgent 首次通知后，TTS `/notify` 返回值包含 `retry_hint`
- AI 等待约 60 秒，判断用户是否已回应（会话是否继续），如无则重新通知
- 重复 3 次后不再打扰，改为写日志说明已尝试通知用户

## 实现清单

1. **TTS 服务**: 新增 `/notify` 端点，实现三级逻辑
2. **`kyb notify` CLI**: 在 `lib/kyb/cli/tts.rb` 中新增 notify 子命令
3. **容器 entrypoint**: 修改 `entrypoint.sh`，CLAUDE.md 追加主动通知章节
4. **测试**: 更新测试（TTS 端点和 CLI 命令）

## 不涉及

- 不修改现有 `/speak` 和 `/done` 端点行为
- 不增加 watcher/daemon 进程（依赖 AI 自行实现重试逻辑）
- 不修改 Docker 网络配置（已有 host.docker.internal 访问能力）
