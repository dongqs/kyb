# OS 级进程沙箱深度对比

Claude Code 沙箱、Codex 沙箱、Zerobox、mise 沙箱都是**进程级 OS 原生沙箱**，使用的底层原语高度重叠，但设计哲学和实现路线完全不同。

## 底层原语对照

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

## 架构深度对比

### 1. 网络隔离策略

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

### 2. 文件系统隔离策略

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

### 3. 凭证/密钥管理

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

### 4. 沙箱逃逸抵抗力

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

### 5. AI Agent 协作模式

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

## 综合评分矩阵

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

## 对 kyb 的启示

### 如果要替换 kyb 中的 Docker，这些方案分别适合什么场景？

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

## 结论

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
