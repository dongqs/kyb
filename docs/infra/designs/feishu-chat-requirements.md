# Feishu Bot — 需求记录

> 用于对照新运行时设计。2026-05-24

## 核心职责

两个功能：
1. **回消息** — 用户在 `kyb-kindergarden` 群 `@kyb-infra`，bot 回复
2. **主动发消息** — bot 主动往群里发消息（通知、报告等）

## 消息派发

- 固定写死目标：`kyb-infra-boss` 容器
- 优先级派发：`@` 艾特 → 立即唤醒回应；无艾特 → 心跳轮询（~10 分钟间隔）
- 回复发到群里

## 技术约束

- 用现有的飞书 API 凭证（`FEISHU_APP_ID` / `FEISHU_APP_SECRET`）
- 去掉现有的复杂 shell 脚本链（lark-claude-bridge / lark-watcher / feishu-monitor 等）
- 用飞书 Open API 直接发消息、收事件

## 非需求（这次不做）

- 投递追踪 / read receipt / 送达监控
- 多容器路由
- 告警 escalation
- 命令路由解析
- 私聊回复

---

参照新运行时设计时，这个 chat 层是运行时的**通知渠道**之一。运行时负责"谁在干活"的调度，chat 层只负责"怎么收发飞书消息"。

---

## 架构全景（chat → runtime → heartbeat → agent）

```
                    ┌──────────────────────────────────────────────────────┐
                    │                     Chat 层                          │
                    │  (通道层 — 只做消息收/发，不关心谁处理)                 │
                    │                                                       │
                    │  ┌─────────────────┐   ┌──────────────────────────┐   │
                    │  │ Event Receiver  │   │ Message Sender           │   │
                    │  │ 飞书事件订阅    │   │ (HTTP POST → 飞书 API)    │   │
                    │  │ WebSocket/回调  │   │                           │   │
                    │  └────────┬────────┘   └──────────┬───────────────┘   │
                    └──────────┼────────────────────────┼───────────────────┘
                               │  @消息 / 通知           │ 发消息请求
                    ┌──────────▼────────────────────────▼───────────────────┐
                    │                    Runtime 层                          │
                    │  (调度层 — 管"谁干什么")                                │
                    │                                                       │
                    │  ┌─────────────────────────────────────────────────┐   │
                    │  │              Dispatcher / Scheduler             │   │
                    │  │  消息路由 · 任务队列 · 优先级管理 · 会话分配    │   │
                    │  │  @消息 → 立即dispatch                           │   │
                    │  │  空闲 → 等heartbeat触发                         │   │
                    │  └──────┬────────────────────────────────┬─────────┘   │
                    │         │                                │             │
                    │  ┌──────▼────────┐            ┌─────────▼─────────┐   │
                    │  │ State Store   │            │ Session Manager   │   │
                    │  │ 持久化状态     │            │ tmux 会话生命周期  │   │
                    │  │ 任务/会话/消息 │            │ 创建/附加/分离/销毁 │   │
                    │  └───────────────┘            │ PID & socket 管理  │   │
                    │                               └─────────┬─────────┘   │
                    │                                         │             │
                    │  ┌───────────────────────────────────────┴──────────┐  │
                    │  │              Sandbox Manager                      │  │
                    │  │  kyb 容器生命周期：create / enter / exec / rm     │  │
                    │  │  Docker API 封装                                  │  │
                    │  └───────────────────────────────────────────────────┘  │
                    └──────────┬─────────────────────────────────────────────┘
                               │ dispatch / exec
                    ┌──────────▼─────────────────────────────────────────────┐
                    │                   Agent 抽象层                          │
                    │  (可替换的执行后端 — 跑什么由配置决定)                    │
                    │                                                       │
                    │  ┌──────────┬──────────┬──────────┬────────────────┐   │
                    │  │ Claude   │ Custom   │ Shell    │ Script         │   │
                    │  │ Code     │ Agent    │ 直跑命令  │ 定时脚本       │   │
                    │  │ (stdin→) │ (自定义)  │          │                │   │
                    │  │ ←stdout) │          │          │                │   │
                    │  └──────────┴──────────┴──────────┴────────────────┘   │
                    │                                                       │
                    │  接口: 启动(会话ID, 上下文) / 发送输入 / 读取输出      │
                    │        / 停止 / 状态查询                               │
                    └───────────────────────────────────────────────────────┘
```

### 各模块说明

| 层 | 模块 | 职责 |
|----|------|------|
| **Chat** | Event Receiver | 收飞书消息（WebSocket / webhook），解析成内部事件 |
| | Message Sender | 调飞书 API 发消息，支持群聊回复和主动推送 |
| **Runtime** | Dispatcher | 消息路由：@消息→立即dispatch，空闲→等heartbeat |
| | State Store | 持久化（SQLite/CK）：会话状态、任务队列、消息历史 |
| | Session Manager | tmux 会话管理：创建 session、attach、detach、kill |
| | Sandbox Manager | kyb 容器生命周期：create/exec/stop/rm，Docker API |
| **Agent** | Agent Interface | 统一的 agent 接口（适配器模式），可插拔 |
| | Claude Code | 默认实现：echo 消息 → `claude --print --continue` |
| | Shell | 直接执行 shell 命令，返回 stdout/stderr |
| | Custom Agent | 自定义 agent 实现，接入其他 LLM 或工具链 |

### 控制流

```
@kyb-infra 查一下 PG 状态
  │
  ▼
Chat Event Receiver ──→ Runtime Dispatcher
                          │  @消息 → 立即调度
                          │
                          ▼
                        Session Manager → Agent (Shell)
                          │  在 kyb-infra-boss 容器内执行
                          │  pg_isready -h localhost
                          │
                          ▼
                        Runtime 收集输出
                          │
                          ▼
                        Chat Message Sender → 飞书群回复
```

```
心跳触发 (10min 无活动)
  │
  ▼
Runtime Heartbeat
  ├─ 检查 agent 是否存活（tmux session? pid?）
  ├─ 存活 → 跳过
  ├─ 不存活但有等待的任务 → 重启 agent
  ├─ 不存活且无任务 → 记录日志，继续睡
  └─ 有定时报告到期 → dispatch "发日报" 到 agent
```

```
新 agent 运行时替换（以 Shell 为例）
  │
  ▼
在配置中切换 agent_type:
  config:
    agent_type: shell   # 原来: claude_code
  
  ▼
Dispatcher 启动 agent 时实例化 ShellAdapter
  输入 → exec 命令 → 收集输出 → 返回
  无需 tmux，无需 Claude Code license
```

### 与现有 kyb 的关系

- **kyb 提供**：容器创建/管理（`kyb create` / `kyb exec` / `kyb rm`）
- **Runtime 补充**：tmux 会话管理、agent 进程生命周期、飞书事件驱动
- **替换路径**：先用 ShellAdapter 跑通全链路（最小可行），再逐个替换 agent 类型
