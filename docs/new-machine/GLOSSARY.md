# 术语表

本文定义 new-machine 模板系统中所有术语的标准含义，确保跨文档一致性。

## 角色

| 术语 | 含义 | 别名 (禁止) |
|------|------|------------|
| 人 | 发起指令的开发者 dongqs | 用户、管理员 |
| 主 agent | 接收人指令的 Claude Code 实例 | AI、助手 |
| subagent | 主 agent 生成的零上下文子 agent | 子任务、worker |

## 位置

| 术语 | 含义 | 路径示例 |
|------|------|---------|
| local | subagent 所在的容器 | /tmp/ |
| remote | 被探索的目标机器 | ssh user@host:~/.claude/ |
| target | 同 remote | |
| workspace | subagent 的操作环境，通常是 local | |

## 动作

| 术语 | 含义 | 必须包含 |
|------|------|---------|
| 探测 | 一次独立的机器信息采集 | 写审计脚本 → scp → ssh 执行 → commit |
| 审计脚本 | 记录探测命令的 .sh 文件 | kyb-{ts}-{desc}.sh 格式 |
| 审计 commit | 每次探测后的 git commit | git add audits/ && git commit |
| 文档 commit | 写完 docs/ 后的 git commit | git add docs/ && git commit |

## 命名规范

| 模式 | 示例 | 适用 |
|------|------|------|
| kyb-{ts}-{desc}.sh | kyb-20260520-120000-phy.sh | 审计脚本文件名 |
| {seq}-{layer}.md | 01-physical.md | 文档文件名 |
| kyb-{hostname} | kyb-nuc8 | 签名 |

## 时间戳

| 格式 | 示例 | 精度 |
|------|------|------|
| YYYYMMDD-HHMMSS | 20260520-120000 | 秒，每次探测不同 |

## 协议步骤

| 步骤 | 位置 | 操作 | commit 要求 |
|------|------|------|------------|
| 1 | local | 写审计脚本 | — |
| 2 | → | scp 到 remote:~/.claude/audits/ | — |
| 3 | remote | bash 执行审计脚本 | — |
| 4 | remote | git add audits/ && git commit | 必须 |
| 5 | remote | 写结果到 docs/{layer}.md | — |
| 6 | remote | git add docs/ && git commit | 必须 |

## 目录结构

```
remote:~/.claude/
├── CLAUDE.md          # 自描述 + 规则（唯一入口文档）
├── docs/              # 探测结果文档（人/agent 共同维护）
│   ├── 01-physical.md
│   ├── 02-os.md
│   ├── 03-network.md
│   ├── 04-runtime.md
│   └── 05-services.md
└── audits/            # 审计脚本（agent 写）
    └── kyb-{ts}-{desc}.sh
```

## 禁止的术语

| 术语 | 原因 | 替换 |
|------|------|------|
| ~/.claude/ 不加 remote | 歧义：不知道是本机还是远程 | remote:~/.claude/ |
| docker exec | 导致 agent 写错位置 | ssh new-machine |
| wrapper | 同上 | ssh new-machine |
| 子任务、子进程 | 歧义 | subagent |
