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

## 重点对比：四种 OS 级进程沙箱

Claude Code 沙箱、Codex 沙箱、Zerobox、mise 沙箱都是**进程级 OS 原生沙箱**，使用的底层原语高度重叠，但设计哲学和实现路线完全不同。

### 底层原语对照

| 原语 | Claude Code | Codex CLI | Zerobox | mise |
|------|------------|-----------|---------|------|
| **macOS 文件系统** | Seatbelt (`sandbox-exec`) | Seatbelt (`sandbox-exec`) | 原生 API 抽象层 | Seatbelt (`sandbox-exec`) |
| **macOS 网络** | Seatbelt profile | Seatbelt profile | MITM 代理 | Seatbelt profile |
| **Linux 文件系统** | bubblewrap (`bwrap`) | Landlock (kernel 5.13+) | bubblewrap | Landlock (kernel 5.13+) |
| **Linux 网络** | bubblewrap `--unshare-net` + socat | seccomp-bpf 过滤网络 syscall | seccomp-bpf | seccomp-bpf |
| **Windows** | ❌ 不支持 | AppContainer | 抽象层（未开源） | ❌ 不支持 |
| **运行方式** | CLI 参数 `--sandbox` | CLI 参数 `--full-auto` | 命令包装器 | CLI 参数 `--deny-*` |

**关键观察**：四个方案的底层原语几乎是一样的——Seatbelt、bubblewrap、Landlock、seccomp。差异在于**怎么组合这些原语、暴露什么策略接口、以及和 AI Agent 的协作模式**。

---

### 架构深度对比

#### 1. 网络隔离策略

这是四个方案分歧最大的维度：

```
        完全断网  ←——————————————————→  全通 + 代理过滤

        Codex        mise        Claude Code     Zerobox
        (full-auto)  (--deny-net)  (代理)         (MITM)
```

**Claude Code 沙箱** — 代理模式
```
Sandbox 内进程
    │ HTTP_PROXY / ALL_PROXY 环境变量
    ▼
Unix domain socket ──── socat ────► HTTP/SOCKS5 代理 (沙箱外)
                                        │
                                    域名白名单 / 黑名单
                                        │
                                        ▼
                                    Internet
```
- 网络不阻断，但所有流量必须经过外部代理
- 代理在沙箱**外部**运行，沙箱进程无法 kill 或绕过
- 新域名请求可触发用户审批

**Codex CLI** — 阻断模式（full-auto）
- 直接断绝网络：Landlock + seccomp-bpf 阻断所有网络 syscall
- 唯一的"通道"是 Codex 自身的 API 调用（因为那是 Codex 进程的事，不在沙箱内）
- `read-only` 和 `workspace-write` 模式下默认无网络
- `danger-full-access` 模式下全开

**Zerobox** — MITM 凭证注入模式
- **核心创新**：真实凭证从不进入沙箱进程内存
- 沙箱内进程看到的 API key 是占位符 `{{OPENAI_API_KEY}}`
- 进程向 `api.openai.com` 发请求时，MITM 代理在 TCP 层替换占位符为真实 key
- 如果进程向其他主机发请求，代理直接丢弃 TCP 包
- 这解决了 Docker/k8s 类沙箱的致命问题：容器内的 env var 可以被任意子进程读取

**mise** — 简单阻断模式
- `--deny-net`：seccomp-bpf 阻断所有 socket 相关 syscall
- `--allow-net=<host>`：仅允许到指定主机的连接
- 当前版本**不支持**按域名过滤，只支持主机名匹配
- 没有代理层，是最简单的"通/断"开关

**网络隔离评价**

| | 防护强度 | 粒度 | 易用性 | 凭证安全 |
|------|---------|------|------|------|
| **Claude Code** | 高 | 域名级白名单 | 高（自动审批） | 中（凭证仍在沙箱环境变量） |
| **Codex CLI** | 最高 | 全开/全关 | 低（断网限制了工具链） | 高（无网络 = 无泄露） |
| **Zerobox** | 最高 | 主机级 + 凭证注入 | 中（需预配置规则） | **最高**（凭证不进沙箱） |
| **mise** | 中 | 主机名匹配 | 高（CLI flag 即用） | 低（凭证在环境变量） |

---

#### 2. 文件系统隔离策略

```
        非对称 (读宽写窄)  ←——→  对称 deny-by-default

        Claude Code    Codex CLI    mise        Zerobox
```

**Claude Code 沙箱** — 非对称模型（最贴近开发者需求）

| 操作 | 默认策略 | 机制 |
|------|---------|------|
| **读取** | 全部允许 | denylist：明确屏蔽 `~/.ssh`, `~/.aws` 等敏感路径 |
| **写入** | 全部禁止 | allowlist：必须明确允许 `$PWD`, `/tmp` |

外加**强制保护列表**——即使路径落在 `allowWrite` 内也永不可写：
`.bashrc`, `.gitconfig`, `.git/hooks/`, `.vscode/`, `.idea/`, `.claude/commands/` 等

这个设计很精妙：读宽意味着 AI 可以自由浏览项目上下文；写窄意味着它只能改你明确允许的地方。

**Codex CLI** — 三档模式

| 模式 | 读 | 写 | .git 目录 |
|------|-----|-----|----------|
| `read-only` | 全部 | 仅 `/dev/null` | 只读 |
| `workspace-write` | 全部 | `$PWD` + `/tmp` + 自定义路径 | 只读 |
| `danger-full-access` | 全部 | 全部 | 可写 |

.git 目录在任何沙箱模式下都是只读——这是一个很好的防护。

**mise** — 原子化开关

```bash
# 六个独立开关，可以自由组合
--deny-all       # 全部禁止
--deny-read      # 禁止读
--deny-write     # 禁止写（保留 /tmp）
--allow-read=<path>
--allow-write=<path>
```

mise 最灵活——你可以精确到单个任务配置哪个目录可读、哪个可写。但也意味着你需要手动配置每一个约束。

**Zerobox** — 单一 deny-by-default

所有文件操作默认禁止，逐个路径授权。模型最严格，但配置成本最高。

**文件系统隔离评价**

| | 默认安全性 | 开发体验 | 配置成本 |
|------|----------|---------|---------|
| **Claude Code** | 高 | 最佳（读宽写窄） | 零配置 |
| **Codex CLI** | 高 | 好 | 零配置（workspace-write 模式） |
| **mise** | 中（取决于配置） | 配置后可很好 | 需手动配置 |
| **Zerobox** | 最高 | 差（频繁 denied） | 高（每个路径都要配） |

---

#### 3. 凭证/密钥管理

这是 Zerobox 拉开差距的地方：

```
凭证暴露风险：  Zerobox << Codex/full-auto < Claude Code < mise < Docker 类

Zerobox:    沙箱进程 never see 真实 key        ← MITM 占位符替换
Codex:      沙箱无网络，key 存在 codex 进程     ← 隔离而非防护
Claude Code: key 在沙箱环境变量中              ← 代理保护传输，不保护读取
mise:        key 在环境变量中                  ← 无特殊保护
kyb/Docker:  key 在容器 env 中                ← 任何子进程可读
```

Zerobox 的 MITM 凭证注入是唯一一个**从原理上**让沙箱进程无法接触真实密钥的方案。但这要求每个 API 提供商都配一条代理规则。

---

#### 4. 沙箱逃逸抵抗力

| 方案 | 已知逃逸 | 逃逸难度 | 内核强制 |
|------|---------|---------|---------|
| **Claude Code** | 2026.3 演示：`/proc/self/root/usr/bin/npx` 绕过 denylist，然后关闭沙箱 | 中 | 是（bubblewrap/Seatbelt） |
| **Codex CLI** | 无公开报告 | 高 | 是（Landlock/seccomp/Seatbelt） |
| **Zerobox** | 无公开报告（项目太小） | 中-高 | 是 + 应用层代理 |
| **mise** | CVE-2026-35533：配置信任绕过（非沙箱本身） | 中 | 是（Landlock/Seatbelt） |

所有四个方案都使用内核级强制执行——不是应用层检查。这意味着即便 AI 生成恶意代码，OS 内核也会拒绝越界操作。但历史表明没有完美的沙箱：

- Claude Code 的 `/proc/self/root` 逃逸说明：基于路径的 denylist 可以被 Linux 的符号链接技巧绕过，需要配合挂载命名空间才能彻底堵死
- mise 的 CVE 说明：沙箱本身可能很硬，但配置系统的漏洞可以让沙箱不被启用

Codex 在 Linux 上用 Landlock 而非 bubblewrap 是一个值得注意的选择——Landlock 是内核 5.13+ 的 LSM，不像 bubblewrap 那样依赖 namespace 和用户空间文件系统构建，理论上更难用路径技巧绕过。

---

#### 5. AI Agent 协作模式

这里是最本质的分歧——这四个沙箱对"AI 与沙箱的关系"有完全不同的假设：

**Claude Code 沙箱** — 边界协商模式

```
Claude: "我要读 /etc/hosts"
  → OS Seatbelt: 阻止
  → Claude: "我被阻止了，需要用户审批"
  → 用户: 允许/拒绝
  → Claude: 继续工作
```

- AI 知道自己在沙箱里
- AI 遇到边界时主动发起审批
- 用户参与安全决策，但只需对"越界"行为做决定

**Codex CLI** — 三档预设模式

```
read-only:      "agent 只能看，不能碰"
workspace-write: "agent 可以改项目，但不能出圈"
full-access:    "agent 可以为所欲为"（用户明确 opted in）
```

- 用户在启动时选择一个模式，之后 agent 在该模式下自主运行
- 没有运行中审批——模式固定
- 更简单，但也更僵化

**Zerobox** — 透明拦截模式

```
目标命令: npm install
  → Zerobox 包装后执行
  → npm 尝试读 ~/.npmrc → 允许（预配置）
  → npm 尝试连 registry.npmjs.org → 允许
  → npm postinstall 脚本尝试连 unknown.host → TCP RST
```

- AI 不知道沙箱存在（透明）
- 没有审批流程——全预配置
- 适合运行**不受信任**的代码，而非 AI 协作

**mise** — 任务级声明模式

```toml
# mise.toml —— 沙箱配置就是任务定义的一部分
[tasks.build]
run = "npm run build"
deny_net = true
allow_write = ["./dist"]

[tasks.test]
run = "npm test"
deny_all = true
allow_read = ["."]
allow_write = ["./coverage"]
allow_net = ["localhost"]
```

- 每个任务的沙箱配置在 `mise.toml` 中声明
- 适合团队统一开发环境的安全策略
- 但目前没有 AI Agent 的原生集成——需要自己把 mise 包装成 Claude Code/Codex 的工具

---

### 综合评分矩阵

| 维度 | Claude Code 沙箱 | Codex CLI 沙箱 | Zerobox | mise 沙箱 |
|------|:---:|:---:|:---:|:---:|
| 文件系统隔离 | ★★★★ | ★★★★ | ★★★★★ | ★★★★ |
| 网络隔离 | ★★★★ | ★★★★★ | ★★★★★ | ★★★ |
| 凭证安全 | ★★★ | ★★★★ | ★★★★★ | ★★ |
| 零配置可用 | ★★★★★ | ★★★★★ | ★ | ★★ |
| 配置粒度 | ★★★ | ★★★ | ★★★★ | ★★★★★ |
| AI Agent 集成 | ★★★★★ | ★★★★★ | ★★ | ★★ |
| 逃逸抵抗力 | ★★★ | ★★★★ | ? | ★★★ |
| 跨平台 | ★★★ | ★★★★★ | ★★★★ | ★★★ |
| 生态成熟度 | ★★★★ | ★★★★★ | ★ | ★★★ |
| 可嵌入 kyb | ★★★★ | ★★ | ★★ | ★★★★ |

---

### 对 kyb 的启示

**如果要替换 kyb 中的 Docker，这些方案分别适合什么场景？**

#### 场景 A：强化安全，保持现有体验

**推荐：Docker + Claude Code 沙箱叠加**

在现有 kyb 容器内启动 Claude Code 时加上 `--sandbox` 参数：

```
Docker 容器 (kyb)
  ├── PostgreSQL, mise, Docker socket...     ← 完整开发环境（不受沙箱影响）
  ├── 文件系统：git worktree 已隔离           ← 容器级隔离
  └── Claude Code 进程
        └── --sandbox                        ← OS 级隔离叠加
             ├── 文件：仅 $PWD + /tmp 可写
             └── 网络：经代理 + 域名审批
```

**改动**：kyb 代码加一行参数。这是投入产出比最高的方案。

#### 场景 B：极致轻量，去 Docker

**推荐：mise 沙箱作为工具执行层**

不运行完整容器，而是在宿主机上通过 mise 管理语言运行时 + mise 沙箱限制 AI 操作：

```bash
# 直接用 mise 沙箱运行 Claude Code 触发的命令
mise x --deny-all --allow-read=./src --allow-write=./dist -- node build.js
```

**代价**：丢失 PostgreSQL 自动服务、Docker-in-Docker、网络代理分流、git worktree 管理。只适合做"纯代码编辑"的轻量场景。

#### 场景 C：密钥安全为第一优先级

**推荐：Zerobox 包装敏感命令**

如果某些 kyb 内的操作涉及敏感 API（比如调用生产环境部署），可以用 Zerobox 包装该命令：

```bash
zerobox --allow-net=api.production.com --credential=DEPLOY_KEY=REAL_KEY -- ./deploy.sh
```

**代价**：不是一个整体解决方案，只能作为补充。

#### 场景 D：AI 工具无关的通用方案

**推荐：mise 沙箱（配置写在 mise.toml）**

如果团队同时使用 Claude Code、Codex、Kimi 等多个 AI 工具，在 `mise.toml` 中声明沙箱规则可以让所有工具共享同一套安全策略。

---

### 结论

**如果"替换 Docker"是目标**，目前这四种方案没有哪个能直接替代 kyb 中 Docker 承担的所有角色。它们能替代的是 Docker 的**安全隔离层**，但不能替代**环境构建层**（安装 PostgreSQL、配置镜像源、管理语言运行时）。

正确的思路是把问题拆成两层：

```
┌──────────────────────────────────────┐
│  安全隔离层 (可替换)                   │
│  Claude Code sandbox / mise / ...     │  ← 进程级，防 AI 越权
├──────────────────────────────────────┤
│  环境构建层 (仍需要)                   │
│  Docker / Dockerfile / entrypoint     │  ← 镜像级，提供完整开发环境
└──────────────────────────────────────┘
```

**短期最优策略**：kyb 保持 Docker 做环境构建，叠加 Claude Code `--sandbox` 做安全隔离。等 Docker Sandboxes (microVM) GA 后可以考虑把底层容器引擎升级，隔离能力从 namespaces 提升到独立内核。

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

---

## kyb sandbox 实战踩坑记录

实现 `kyb sandbox`（宿主机直跑 Claude Code sandbox）过程中遇到的核心问题和解决方案。

### 1. `--sandbox` CLI flag 不存在

**现象**：`claude --sandbox` 报 `unknown option`。

**原因**：Claude Code 沙箱不是通过 CLI flag 启用的，而是通过 `.claude/settings.json` 中的 `sandbox.enabled: true` 配置。项目级 settings 自动被发现并合并到全局设置。

**解决**：在 worktree 下写 `.claude/settings.json`：
```json
{
  "sandbox": { "enabled": true },
  "permissions": { "allow": ["*"] }
}
```

### 2. `--dangerously-skip-permissions` 弹出确认警告

**现象**：每次启动弹 "WARNING: Claude Code running in Bypass Permissions mode"，需要手动确认。

**原因**：Claude Code 对 bypass permissions 模式有安全提示，需要显式跳过。

**解决**：在 settings.json 中加 `"skipDangerousModePermissionPrompt": true`。

### 3. 网络域名提示

**现象**：`npm install` 触发 "Network request outside of sandbox" 提示，需要手动允许 `registry.npmjs.org`。

**原因**：Sandbox 代理默认拦截所有外部网络请求，新域名需要用户审批。这是 sandbox 层面的提示，不受 `permissions.allow: ["*"]` 控制。

**解决**：两管齐下：
- `sandbox.network.allowedDomains` 预填常用域名（npm、GitHub、内部 GitLab 等）
- `npm install` 在 Claude 启动**之前**执行（不受 sandbox 限制），避免最常见的网络提示

### 4. macOS Seatbelt 阻断端口绑定

**现象**：`vite` 启动 dev server 报 `listen EPERM: operation not permitted 0.0.0.0:3000`。

**原因**：macOS Seatbelt 在 OS 内核层面阻断所有网络操作，只放行到 sandbox 代理端口的出站连接。`bind()` 系统调用被完全禁止，dev server 无法监听任何端口——即使绑定 `127.0.0.1` 也不行。

**解决**：将 dev server 命令加入 `sandbox.excludedCommands`，让它们在 sandbox 外执行：
```json
{
  "sandbox": {
    "excludedCommands": ["npm run *", "npx *", "vite", "next", "webpack"]
  }
}
```
其他命令（文件编辑、git 操作、npm install）仍在 sandbox 保护下。

### 5. 端口分配信息未传递给 dev 工具

**现象**：Claude 启动 dev server 时从 3000 开始逐个尝试，而不是直接用分配的端口。

**原因**：端口号写在了 CLAUDE.md 上下文里，但 Claude 没有把端口号传给 vite/npm 等子进程——这些工具不会读 CLAUDE.md。

**解决**：在启动 Claude 前设置 `PORT` 环境变量（`ENV['PORT'] = ports.first.to_s`），vite 等工具自动读取。

### 6. sandbox rm 后端口残留

**现象**：`kyb sandbox rm` 杀掉了 Claude Code 进程，但 dev server（vite）作为子进程仍在运行，端口未释放。

**原因**：`Process.kill` 只杀直接 PID，管不到 fork 出的孙子进程。

**解决**：在 `rm` 中用 `lsof -ti :PORT` 找到占用分配端口的进程，一并 kill。

### 总结

Claude Code sandbox 作为 OS 级安全边界是有效的，但在实际开发场景中有几个根本性限制：

| 问题 | 根因 | 是否可绕过 |
|------|------|:--:|
| 端口绑定被阻断 | Seatbelt 禁止 `bind()` | ✅ `excludedCommands` |
| 新域名需审批 | Sandbox 代理拦截 | ✅ `allowedDomains` 预填 |
| `--sandbox` flag 不存在 | 沙箱通过 settings.json 配置 | ✅ 写项目级 settings |
| bypass permissions 警告 | 安全提示 | ✅ `skipDangerousModePermissionPrompt` |
| 孙子进程端口泄露 | `Process.kill` 不递归 | ✅ `lsof` 清理 |

关键认知：**Claude Code sandbox 最适合"纯代码编辑"场景**（文件读写都在 worktree 内，出站网络走预批准的域名）。dev server、Docker 操作等需要网络监听或特殊权限的操作，应该通过 `excludedCommands` 排除，让它们跑在 sandbox 外。
