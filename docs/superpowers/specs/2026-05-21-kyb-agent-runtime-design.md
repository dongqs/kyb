# kyb 2.0: Agent Runtime Design

## Core Shift

kyb 不是 CLI 工具。kyb 是一个 agent 运行时。

> 之前所有的设计文档都把 kyb 当作"管理 Docker 容器的 CLI 工具"来写，这是错的。
> 每一行的真正意图是管理 agent 生命周期——容器只是实现。
> 这份文档以正确的视角重新设计 kyb。

## Agent Lifecycle

```
     Create ──→ Prompt ──→ Work ──→ Observe ──→ Iterate ──→ Converge
       │                                                    │
       └────────────────── Cleanup ←─────────────────────────┘
```

| 阶段 | 当前实现 | 2.0 目标 |
|------|---------|---------|
| **Create** | `kyb create` → Docker run | provider 抽象 → Docker / 火山云 |
| **Prompt** | entrypoint.sh 写 CLAUDE.md + 注入启动 prompt | 标准化的 agent self-description 协议 |
| **Work** | tmux + Claude Code，手动 fork sub-agent | 内置 sub-agent 调度（boss mode） |
| **Observe** | 无 | 生产数据接入（SLS / CK / Grafana） |
| **Iterate** | 手动改代码、手动 cp 同步 | agent 直接改 kyb 代码 → 测试 → MR |
| **Converge** | 人工验收 | agent 自验证，生产数据确认 |
| **Cleanup** | `kyb rm` | 自动，跑完即销毁 |

## 架构

```
┌──────────────────────────────────────────────────┐
│                    Agent Runtime                  │
│  ┌─────────┐ ┌──────────┐ ┌──────────────────┐  │
│  │  CLI    │ │  HTTP    │ │  (未来)           │  │
│  │ (cobra) │ │ (daemon) │ │  gRPC/message    │  │
│  └────┬────┘ └────┬─────┘ └────────┬─────────┘  │
│       └───────────┴────────────────┘             │
│                        │                         │
│  ┌─────────────────────┴──────────────────────┐  │
│  │              Core Services                  │  │
│  │  ┌──────────┐ ┌────────┐ ┌──────────────┐  │  │
│  │  │ Config   │ │ Parser │ │ Container    │  │  │
│  │  │ (YAML)   │ │ (proj- │ │ (value obj)  │  │  │
│  │  │          │ │ branch) │ │              │  │  │
│  │  └──────────┘ └────────┘ └──────────────┘  │  │
│  └─────────────────────┬──────────────────────┘  │
│                        │                         │
│  ┌─────────────────────┴──────────────────────┐  │
│  │              Provider (interface)           │  │
│  │  ┌──────────┐ ┌────────────┐ ┌──────────┐  │  │
│  │  │ Local    │ │ Cloud      │ │ (test    │  │  │
│  │  │ (Docker) │ │ (火山云)    │ │  mock)  │  │  │
│  │  └──────────┘ └────────────┘ └──────────┘  │  │
│  └─────────────────────┬──────────────────────┘  │
│                        │                         │
│  ┌─────────────────────┴──────────────────────┐  │
│  │           External Integrations             │  │
│  │  ┌──────┐ ┌────┐ ┌──────┐ ┌──────────┐   │  │
│  │  │ SLS  │ │ CK │ │Grafana│ │ Toolchain│   │  │
│  │  │      │ │    │ │       │ │ (mvn/    │   │  │
│  │  │      │ │    │ │       │ │ mise/…)  │   │  │
│  │  └──────┘ └────┘ └──────┘ └──────────┘   │  │
│  └───────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

## Provider 接口

核心抽象。kyb 不关心容器跑在哪，只关心接口。

```go
type Provider interface {
    // 生命周期
    Create(ctx context.Context, spec *ContainerSpec) (*Container, error)
    Exec(ctx context.Context, id string, cmd []string) (Result, error)
    Enter(ctx context.Context, id string) error      // TTY attach
    Stop(ctx context.Context, id string) error
    Remove(ctx context.Context, id string) error

    // 查询
    List(ctx context.Context, filter *Filter) ([]Container, error)
    Logs(ctx context.Context, id string) (string, error)

    // 镜像
    Build(ctx context.Context, spec *BuildSpec) error
}
```

```go
type ContainerSpec struct {
    Project     string
    Branch      string
    Image       string
    Env         map[string]string
    Ports       []string
    Mounts      []Mount
    Cpus        int
    Memory      string
    Clone       bool       // --clone 模式
    Model       string     // flash / pro
}
```

**LocalDockerProvider** — 当前实现，调 `docker run/exec/stop/rm`。

**CloudProvider** — 火山云 VKE/ECS。`Create` → 调 VKE API 起 Pod。`Exec` → `kubectl exec`。`Enter` → `kubectl exec -it`。`Remove` → 删 Pod / 释放 ECS。

```go
func (p *CloudProvider) Create(ctx context.Context, spec *ContainerSpec) (*Container, error) {
    // 1. 选集群 / 创建 ECS
    // 2. 拉 kyb-base 镜像
    // 3. 起 Pod / 启动容器
    // 4. 等 ready
    // 5. 返回 Container{ID, Address, Provider: "cloud"}
}
```

## CLI 层不变

```bash
kyb create project-branch                    # 默认本地 Docker
kyb create --cloud project-branch            # 云上
kyb create --cloud --cpus 4 project-branch   # 云上 4 核
kyb enter project-branch                     # 本地或云上（自动识别）
kyb ps --cloud                               # 只看云上
kyb rm project-branch                        # 哪的都行
kyb build                                    # 本地 build 镜像是 provider 专属
kyb build --cloud                            # 云上 build（buildkit on VKE）
```

CLI 从 `cli.rb` dispatch 到 `cmd/root.go`（cobra），逻辑相同只是换语言。

## 工具集成（Agent 经验编码层）

kyb 从"编排工具"变成"agent 工具集"。每个命令固化一种 agent 的绕路经验。

| 命令 | 来源（agent 踩过的坑） | 做什么 |
|------|----------------------|--------|
| `kyb assert java` | `.kyb.md` 模板里的标准步骤 | 检查/安装 JDK，设 JAVA_HOME |
| `kyb assert pg` | DID 容器不自启 PG | 启动 PG 16 |
| `kyb tool jbang` | agent 每次手装 JVM 工具 | `mise install jbang` → 检查 → 激活 |
| `kyb tool java 21` | agent 每次在 DID 里切版本 | 自动切换并设环境变量 |
| `kyb fix maven-403` | Nexus 403 绕路经验 | 尝试凭证→换源→降版本→跳过 |
| `kyb fix perms` | DID 容器权限污染 | `chown -R dev:dev` 共享缓存 |
| `kyb cache warm` | 冷启动编译慢 | 预测常用依赖预下载 |
| `kyb proxy detect` | 宿主机代理配置混乱 | 端口探测 + 配置导出 |

这些命令的本质是 **agent 少走一次弯路**。每次 agent 发现一个"又卡在这了"的问题，就固化一个命令。

### 工具集成契约

```
遇到新卡点 → agent 手动绕过去 → 在 .kyb.md 里记下绕法
          → 下次又遇到 → 说明是系统性问题
          → 提 issue / 提 PR → 加 `kyb fix/assert/tool` 命令
          → 以后所有 agent 直接调用
```

## 生产数据接入

```go
type ProdQuery interface {
    QuerySLS(ctx context.Context, query string) (Result, error)
    QueryCK(ctx context.Context, query string) (Result, error)
    ProvisionGrafana(ctx context.Context, project string) error
}
```

CLI:

```bash
kyb prod sls "status >= 500 | limit 100"          # SLS 日志查询
kyb prod ck "SELECT count() FROM orders"           # CK 查询
kyb prod grafana <project>                         # 自动搭看板
kyb prod trace <trace-id>                          # 链路追踪
```

实现层：SLS SDK / CK HTTP API / Grafana API，通过认证隧道包装。agent 不关心凭证管理，`kyb prod` 统一处理。

## 自迭代闭环

```
         ┌─────────────────────────────────────┐
         │  火山云 VKE                          │
         │                                     │
         │  kyb server（boss agent）            │
         │    ├── subagent A: issue #42 不复现  │
         │    ├── subagent B: 查 SLS 日志       │
         │    ├── subagent C: 搭 Grafana 定位   │
         │    ├── subagent D-N: 修复方案评估    │
         │    └── 收敛 → 生成 patch → MR        │
         │                                     │
         │  kyb 自身也在容器里                   │
         │  agent 可以改 kyb 代码               │
         │  go build → test → MR → merge       │
         │  = kyb 自己迭代了自己                │
         └─────────────────────────────────────┘
```

关键突破点不在技术。在**信任**——让 agent 自己提交 MR、自己合并、自己发布。

## Go 迁移策略

当前 Ruby 版持续运行，Go 版从头写起，不逐文件翻译。

| 对比 | Ruby（v0.x） | Go（v2.0） |
|------|-------------|-----------|
| 状态 | 线上运行，agent 日常用 | 从头新建 |
| 模块 | 扁平文件，按功能混排 | 按接口分包 |
| 测试 | Minitest，部分集成测试需要 Docker | Go test + table-driven + mock provider |
| Provider | 只支持 Docker | interface → 本地 Docker + VKE |

Go 版第一版目标：**CLI 命令全集 + LocalDockerProvider + 测试通过**。完成后驻留分支，agent 可以开始双版本并行试用。

## 实施顺序

| 阶段 | 内容 | 关键依赖 |
|------|------|---------|
| 1 | Go 迁移：翻译现有 Ruby 到 Go，provider 先只实现 local Docker | 无 |
| 2 | Provider 接口：实现 CloudProvider（VKE/ECS）| 火山云账号 |
| 3 | 生产数据接入：SLS / CK / Grafana 认证和查询 | SLS/CK/Grafana 权限 |
| 4 | 工具集成：从 agent 踩坑记录固化 kyb fix/* 命令 | 持续积累 |
| 5 | 自迭代：agent 改自己代码 → 测试 → MR merge | 信任 + CI 自动化 |

## 不涉及（明确的非目标）

- 不做 kyb server daemon（有云 provider 后不需要，直接 VKE pod）
- 不做 K8s 集群管理（VKE 管了）
- 不做资源账单管理（火山云自己有）
- 不做中间件全家桶（按需 `--with` / agent 自己起）
- 不做 kyb 自身日志系统（SLS）
- 不做 AMQP/gRPC 接入层（没必要）
