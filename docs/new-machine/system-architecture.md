# System Architecture — kyb 探索体系

## 实体地图

```
macOS 宿主机 (dongqs-mac)
  ├── OrbStack VM
  │   ├── kyb-kyb-tailscale  ← 我在这里（主容器，当前对话）
  │   ├── kyb-build
  │   ├── kyb-md
  │   └── click-mig
  │
  ├── Tailscale: 100.104.244.99
  │
  └── 能 SSH 到的机器
      └── nuc8 (100.98.29.39) ← Agent A 探索的目标
```

## 角色定义

### 👤 人 — dongqs
- **在哪**: macOS 宿主机前
- **做什么**: 发起指令、review 结果、签名确认
- **不做什么**: 不操作具体命令

### 🤖 Agent 主 — 我（当前 Claude Code）
- **在哪**: `kyb-kyb-tailscale` 容器内
- **做什么**: 接收人的指令、规划任务、审核结果
- **能力**: 读文件、写文件、跑命令、SSH、Docker exec、启动 subagent
- **不做什么**: 不直接探索远程机器

### 🤖 Agent A — Subagent（零上下文）
- **在哪**: 由主 agent 创建，运行在同一个 kyb 容器内
- **做什么**: 按 `~/.claude/CLAUDE.md` 指引探索目标机器
- **不做什么**: 
  - 不初始化 ~/.claude（那是 scp_templates.sh 的事）
  - 不装软件
  - 不改配置
  - 不走 SSH 转义（用审计脚本模式）

## 容器

| 容器 | 用途 | 状态 |
|------|------|------|
| kyb-kyb-tailscale | 主容器，当前对话所在 | 运行中 |
| kyb-test-agent | 被探索的目标容器 | 存活（subagent 正在探）|

## 探索链路

### 场景 A：探远程机器（nuc8）

```
主 agent (kyb-kyb-tailscale)
  │  ┌─────────────────────────────┐
  │  │ local: 写审计脚本           │
  │  │ scp 到 remote:~/.claude/audits/ │
  │  │ ssh user@host bash ...sh    │
  │  │ ssh user@host "cd ~/.claude && git commit" │
  │  └─────────────────────────────┘
  ▼
nuc8 (~/.claude/)
```

### 场景 B：探同宿主容器（kyb-test-agent）

```
主 agent (kyb-kyb-tailscale)
  │  ┌──────────────────────────────────────┐
  │  │ local: 写审计脚本                     │
  │  │ docker cp 到 container:/home/dev/...  │
  │  │ docker exec -u dev container bash ...sh │
  │  │ docker exec ... "cd ~/.claude && git commit" │
  │  └──────────────────────────────────────┘
  ▼
kyb-test-agent (~/.claude/)
```

### 场景 C：Subagent 探容器

```
主 agent → 启动 subagent
                │
                │  docker exec -u dev kyb-test-agent <cmd>
                ▼
           kyb-test-agent (~/.claude/)
```

## 文件流

```
templates/  (kyb 仓库, 源头)
  │ scp_templates.sh
  ▼
remote:~/.claude/  (目标机器, git 仓库)
  ├── CLAUDE.md       ← 自描述 + 规则
  ├── docs/           ← 探索记录（人/agent 共同维护）
  │   ├── 01-physical.md
  │   ├── 02-os.md
  │   ├── 03-network.md
  │   ├── 04-runtime.md
  │   └── 05-services.md
  └── audits/         ← 审计脚本（agent 写）
      ├── kyb-{ts}-first-touch.sh
      ├── kyb-{ts}-phy.sh
      ├── kyb-{ts}-os.sh
      └── ...
```

## 关键规则

1. **scp_templates.sh 只能人/自动化跑**，subagent 不管初始化
2. **Subagent 只读 CLAUDE.md**，不给额外 context
3. **所有探测走审计脚本**，不 inline SSH
4. **每步 commit**，不攒批
5. **签名确认**，每节填完手签
