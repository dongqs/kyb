# AI 开发沙箱方案对比

kyb 与其他 AI 沙箱方案的全面对比分析。

## 方案概览

| 方案 | 隔离机制 | 定位 | 运行位置 |
|------|---------|------|---------|
| **kyb** | Docker 容器 | 个人 AI 开发工作站 | 本地 macOS |
| **Claude Code 官方沙箱** | bubblewrap (Linux) / Seatbelt (macOS) | Claude Code 内置安全层 | 本地 |
| **Zerobox** | 原生 OS 沙箱 + MITM 代理 | 进程级轻量沙箱 | 本地 |
| **Codex CLI 沙箱** | Seatbelt (macOS) / Landlock (Linux) | Codex 内置安全层 | 本地 |
| **Docker Sandboxes** | microVM | AI Agent 通用沙箱 | 本地 |
| **ClaudeBox** | Docker 容器 | Claude Code 容器化环境 | 本地 |
| **E2B** | Firecracker microVM | Agent 基础设施（云原生） | 云端 |
| **Daytona** | OCI 容器池 (K8s) | Agent 基础设施（云原生） | 云端/自建 |
| **AI-Sandbox** | Docker 容器 | 多 AI 工具通用沙箱 | 本地 |
| **TextCortex Sandbox** | Docker 容器 | Claude Code 自主 Agent | 本地 |

## 隔离强度

```
进程级沙箱 (弱)  ←——→  硬件虚拟化 (强)

Zerobox    Codex        kyb        ClaudeBox    E2B
(原生API)  (Seatbelt)   (Docker)   (Docker)     (Firecracker)
                ↓                    ↓               ↓
        Claude Code 沙箱      Docker Sandboxes   Daytona
        (bubblewrap)          (microVM)          (OCI/K8s)
```

- **Zerobox / Codex CLI**：进程级，最轻量但隔离面窄
- **kyb / ClaudeBox / Docker 类**：容器级，cgroups + namespaces，共享宿主机内核
- **Docker Sandboxes**：microVM，独立内核，更强隔离
- **E2B**：Firecracker，硬件级隔离，每个沙箱独立 kernel

## 启动速度

| 方案 | 冷启动 | 热启动/缓存 |
|------|--------|------------|
| **kyb** | 3-10s（docker run） | 依赖容器已存在 |
| **Claude Code 沙箱** | < 1s | 即时 |
| **Zerobox** | < 100ms | 即时 |
| **Codex CLI** | < 1s | 即时 |
| **Docker Sandboxes** | ~3-5s | ~1s |
| **E2B** | ~150-200ms | 即时（预建池） |
| **Daytona** | < 90ms（池化） | ~27ms（预热池） |

kyb 的启动慢是因为需要 `docker build` 镜像 + 创建 git worktree + 等待 entrypoint 初始化 Claude Code 配置。这在"每天开一次"的交互场景中不是问题，但在高频创建/销毁场景中明显不如 E2B/Daytona。

## 网络隔离

| 方案 | 网络控制 | 实现方式 |
|------|---------|---------|
| **kyb** | 全局 SOCKS5 代理 + NO_PROXY 白名单 | ALL_PROXY → host.orb.internal:2080 |
| **Claude Code 沙箱** | 代理强制 + 域名白名单，用户审批 | Unix domain socket → 外部代理 |
| **Zerobox** | MITM 代理 — 拦截 + 凭证动态注入 | TCP/IP 层拦截 |
| **Codex CLI** | 完全阻断网络（full-auto 模式） | 无网络访问 |
| **Docker Sandboxes** | iptables 规则 | 内核级 netfilter |
| **E2B** | 默认网络隔离 + 可配置出口 | Firecracker 网络栈 |
| **Daytona** | 可配置网络策略 | K8s NetworkPolicy |

kyb 的独特之处：代理策略是"分流"而非"阻断"——国内镜像直连、内网 GitLab 直连、外网走代理。这是针对中国开发者网络环境的深度定制，其他方案都没有这个考量。

Codex CLI 最激进：full-auto 模式下直接没有网络。Zerobox 的 MITM 凭证注入是最精细的方案。

## 文件系统隔离

| 方案 | 文件访问控制 | Git 集成 |
|------|------------|---------|
| **kyb** | git worktree 隔离 + 只读挂载（ssh/gitconfig） | 一等公民：自动创建 worktree、分支管理、清理 |
| **Claude Code 沙箱** | 仅允许当前目录读写 | 通过代理验证 git 操作 |
| **Zerobox** | deny-by-default，逐个路径授权 | 无内置支持 |
| **Codex CLI** | 仅当前目录 + TMPDIR 可写 | 通过 GitHub CLI 集成 |
| **E2B** | 沙箱内完整文件系统，可挂载外部 | SDK 提供 git 操作 API |
| **Daytona** | 沙箱内独立文件系统 | SDK 提供 git 操作 API |

kyb 的 git worktree 方案是独特的：每个容器获得独立的 worktree + 独立分支，不污染主工作区。这比单纯的"目录挂载"更深地融入了 git 工作流。

## AI 工具支持

| 方案 | 支持的 AI 工具 |
|------|--------------|
| **kyb** | Claude Code（主要）、Kimi CLI |
| **Claude Code 沙箱** | 仅 Claude Code |
| **Zerobox** | 通用（任意命令级沙箱） |
| **Codex CLI** | 仅 Codex |
| **Docker Sandboxes** | Claude Code、Gemini CLI、Copilot CLI、Codex、OpenCode、Kiro |
| **ClaudeBox** | Claude Code |
| **E2B** | 通用（SDK 接入） |
| **Daytona** | 通用（通过 MCP Server 接入 Claude、Cursor 等） |

kyb 目前仅深度集成 Claude Code + Kimi，缺乏多 AI 工具的通用性。Docker Sandboxes 在这方面做得最好。

## 开发环境完整度

| 方案 | 数据库 | 语言运行时 | Docker-in-Docker | 包管理器镜像 |
|------|--------|-----------|-----------------|------------|
| **kyb** | PostgreSQL 16 自动启动 | mise 管 Node/Ruby/Java/Python | 支持（挂载 socket） | apt/npm/gem/pip 国内镜像 |
| **Claude Code 沙箱** | 无 | 仅系统自带 | 不支持 | 无 |
| **Codex CLI** | 无 | 仅系统自带 | 不支持 | 无 |
| **E2B** | 无（需自行安装） | 多语言预装 | 不支持 | 标准源 |
| **Daytona** | 无（需声明依赖） | 按需构建 | 不支持 | 标准源 |

kyb 是唯一一个把 PostgreSQL、Docker-in-Docker、mise 运行时管理、国内镜像源全配齐的方案。它不是一个"空壳沙箱"，而是一个**开箱即用的开发工作站**。

## 持久化策略

| 方案 | 代码持久化 | AI 对话历史 | node_modules | 清理策略 |
|------|-----------|------------|-------------|---------|
| **kyb** | git worktree（可提交） | 命名卷 `{name}-claude` | 命名卷 `{project}-node_modules` | `kyb rm/prune` 一键清理 |
| **Claude Code 沙箱** | 当前目录直接修改 | ~/.claude 在沙箱外 | 无特殊处理 | 无 |
| **E2B** | 14 天保留 | 无持久化 | 每次重建 | 自动过期 |
| **Daytona** | 按需持久化 | 无持久化 | 无 | 按秒计费，不用即删 |

kyb 的持久化策略最贴近真实开发：代码通过 git 分支管理，Claude 对话历史和 node_modules 通过命名卷保留，避免重复安装依赖。

## 权限模型

| 方案 | AI 权限 | 用户权限 | 审批流程 |
|------|---------|---------|---------|
| **kyb** | `allow: ["*"]` + `--dangerously-skip-permissions` | dev 用户 sudo NOPASSWD | 零审批，完全自主 |
| **Claude Code 沙箱** | 沙箱内自由，越界触发审批 | 普通用户 | 边界违规时审批（减少 84%） |
| **Zerobox** | deny-by-default | 普通用户 | 每次越权需预配置 |
| **Codex CLI** | full-auto 模式无审批 | 普通用户 | 无（但网络已阻断） |

kyb 选择了**完全信任**模型——容器就是隔离边界，边界内无限制。Claude Code 沙箱选择了**边界 + 审批**模型——边界内自由但边界受控。两种哲学不同：kyb 适合"我知道我在做什么"的开发者；Claude Code 沙箱更适合安全敏感场景。

## 总结

| 方案 | 最适合场景 | 核心优势 | 核心劣势 |
|------|-----------|---------|---------|
| **kyb** | 中国开发者个人 AI 工作站 | 全栈开发环境、git worktree、国内网络优化 | 仅本地、启动慢、仅 Claude Code |
| **Claude Code 沙箱** | Claude Code 安全使用 | 零配置、OS 原生沙箱、减少 84% 审批 | 仅 Claude Code、裸环境 |
| **Zerobox** | 任意命令级沙箱 | 极轻量、凭证注入 | 需手动配置每个策略 |
| **Codex CLI** | Codex 安全使用 | 原生集成、完全断网模式 | 仅 Codex、功能受限 |
| **Docker Sandboxes** | 多 AI 工具通用 | 多工具支持、microVM 隔离 | 较新、社区小 |
| **E2B** | AI Agent 云执行 | 极速启动、大规模并发、Firecracker 隔离 | 云端依赖、按量付费 |
| **Daytona** | Agent 基础设施 | 极速池化、MCP 集成 | 需自建或云付费 |
| **ClaudeBox** | Claude Code Docker 化 | 15+ 开发配置、成熟 | 仅 Claude Code |

## kyb 的独特定位

kyb 在其他方案中找不到直接替代品，因为它解决了几个被忽略的需求：

1. **中国网络环境适配** — 国内镜像 + 外网代理分流，其他方案都假设直连全球网络
2. **完整开发工作站而非单纯沙箱** — PostgreSQL + Docker-in-Docker + mise 多语言 + git worktree，E2B/Daytona 给你空壳，kyb 给你"拎包入住"
3. **git worktree 深度集成** — 不是简单的目录隔离，而是正经的分支管理 + 多实例互不干扰
4. **持久化卷的精细设计** — Claude 历史、node_modules、项目代码三者分离，不互相污染

kyb 的弱点也很明显：**启动慢**（秒级 vs 毫秒级）、**不可扩展**（单机方案，没有云端能力）、**仅支持 Claude Code + Kimi**、**安全模型是"信任"而非"零信任"**。如果未来需要支持多用户或生产级 Agent 服务，E2B 或 Daytona 会是更合适的基础设施。

---

更多的对比文档：

- [OS 级进程沙箱深度对比](./os-sandbox.md) — Claude Code / Codex / Zerobox / mise 四种 OS 原生沙箱的底层原语、网络隔离、文件系统隔离、逃逸抵抗力详细对比
- [kyb sandbox 实现踩坑](./sandbox-pitfalls.md) — kyb sandbox 实现过程中的核心问题和解决方案

---

## kyb create (Docker) vs kyb sandbox

kyb 内部两套模式的适用边界。

### 必须用 Docker 的场景

| 能力 | 原因 |
|------|------|
| **Docker 命令**（`docker build/run/compose`） | sandbox 无 `/var/run/docker.sock`，且 Seatbelt 阻断 socket 通信 |
| **`apt-get install` 系统包** | 宿主机是 macOS，没有 apt；Docker 提供完整 Ubuntu 用户空间 |
| **PostgreSQL 自动启动** | Docker 容器内 systemd/entrypoint 管服务生命周期；sandbox 依赖宿主机已有 PG |
| **ALL_PROXY 自动注入** | Docker 容器环境变量对所有进程生效；sandbox 只是上下文告知 Claude |
| **完整 Linux 文件系统** | Docker 有独立 rootfs，容器内随便折腾；sandbox 跑在 macOS 文件系统上 |

### sandbox 足够的场景

| 能力 | 说明 |
|------|------|
| **代码编辑、跑测试** | 文件在 worktree 内，sandbox 保护不越界 |
| **npm/pip/gem 安装** | `allowedDomains` 预填 + 预安装，无提示 |
| **起 dev server** | `excludedCommands` 排除出 sandbox，`PORT` 环境变量自动设 |
| **git 操作** | 直接操作 worktree，不受 sandbox 影响 |
| **mig25 数据库迁移** | 连宿主机 PG，sandbox 允许 localhost 连接 |
| **多 Agent 并行** | git worktree 隔离代码，每个 Agent 独立 sandbox |

### 选择指南

```
需要 docker 命令或 apt-get？
  ├── 是 → kyb create (Docker)
  └── 否 → 项目需要完整 Linux 环境？
            ├── 是 → kyb create (Docker)
            └── 否 → kyb sandbox
```
