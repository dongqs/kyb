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
| **Work** | tmux + Claude Code，手动 fork sub-agent | 内置 sub-agent 调度（boss mode），所有操作自动打点 |
| **Observe** | 无 | 生产数据接入（SLS / CK / Grafana）+ 翻其他 agent 上下文 |
| **Iterate** | 手动改代码、手动 cp 同步 | agent 直接改 kyb 代码 → 测试 → MR |
| **Converge** | 人工验收 | agent 自验证，生产数据确认，交叉引用其他 agent 结论 |
| **Cleanup** | `kyb rm` | 自动，跑完即销毁 |

## 架构

```
┌──────────────────────────────────────────────────────┐
│                    Agent Runtime                       │
│  ┌─────────┐ ┌──────────┐ ┌──────────────────┐      │
│  │  CLI    │ │  HTTP    │ │  (未来)           │      │
│  │ (cobra) │ │ (daemon) │ │  gRPC/message    │      │
│  └────┬────┘ └────┬─────┘ └────────┬─────────┘      │
│       └───────────┴────────────────┘                 │
│                        │                             │
│  ┌─────────────────────┴──────────────────────────┐  │
│  │              Core Services                      │  │
│  │  ┌──────────┐ ┌────────┐ ┌────────────────┐   │  │
│  │  │ Config   │ │ Parser │ │ Container      │   │  │
│  │  │ (YAML)   │ │ (proj- │ │ (value obj)    │   │  │
│  │  │          │ │ branch) │ │                │   │  │
│  │  └──────────┘ └────────┘ └────────────────┘   │  │
│  └─────────────────────┬──────────────────────────┘  │
│                        │                             │
│  ┌─────────────────────┴──────────────────────────┐  │
│  │              Provider (interface)               │  │
│  │  ┌──────────┐ ┌────────────┐ ┌──────────────┐  │  │
│  │  │ Local    │ │ Cloud      │ │ Channel      │  │  │
│  │  │ (Docker) │ │ (火山云)    │ │ (WeChat/...) │  │  │
│  │  └──────────┘ └────────────┘ └──────────────┘  │  │
│  └─────────────────────┬──────────────────────────┘  │
│                        │                             │
│  ┌─────────────────────┴──────────────────────────┐  │
│  │           External Integrations                 │  │
│  │  ┌──────┐ ┌──────────┐ ┌──────────────────┐   │  │
│  │  │ SLS  │ │ Grafana  │ │ Toolchain        │   │  │
│  │  │      │ │          │ │ (mvn/mise/…)     │   │  │
│  │  └──────┘ └──────────┘ └──────────────────┘   │  │
│  └─────────────────────────────────────────────────┘  │
│                                                        │
│  CK (ClickHouse): agent_events 表 ←→ kyb prod ck      │
└──────────────────────────────────────────────────────────┘
```

## Agent Collective Memory

CK 集群里建一张表，所有 agent 打点到这里。不是新功能——只是用已有的 `kyb prod ck` 多查一张表。

```sql
CREATE TABLE kyb.agent_events (
    timestamp DateTime,
    agent_id String,
    session_id String,
    task_id String,
    project String,
    world_view String,
    event_type String,              -- observation / decision / action / result / error
    content String,
    parent_agent_id String,
    tags Map(String, String)
) ENGINE = MergeTree()
ORDER BY (project, timestamp);
```

入口注入 prompt（entrypoint.sh 里加几行）：

```
集群内 CK 地址: clickhouse://ck.kyb:9000/kyb
所有 agent 共享此库。每步关键结论写入 `agent_events`。
遇到不熟悉的问题，先查 `agent_events` 看有没有其他 agent 处理过。

写入: INSERT INTO kyb.agent_events (...) FORMAT TabSeparated
查询: SELECT content FROM kyb.agent_events WHERE project = '...' AND event_type = 'result'
```

就这么多。不需要新接口、不需要新 CLI——agent 写 SQL 自己管自己。

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

## Agent 世界观

Prompt 注入时附带一份世界观文件，影响 agent 的思考框架而非具体知识。

```
kyb create project-branch --worldview system-cybernetics    # 系统论+控制论
kyb create project-branch --worldview scientific-empiricism  # 科学实证主义
kyb create project-branch --worldview marxist-dialectics     # 实践论+矛盾论
kyb create --diversity 3 project-branch                      # 随机3种世界观并行
```

每个世界观文件在 `~/.kyb/worldviews/` 下，3-5 段话。通过 entrypoint 注入 CLAUDE.md 或启动 prompt。

```go
type Worldview struct {
    Name        string
    Path        string  // ~/.kyb/worldviews/<name>.md
    Description string
}

// 生成 prompt 片段
func (w *Worldview) Prompt() string {
    content, _ := os.ReadFile(w.Path)
    return fmt.Sprintf("\n## 世界观\n%s\n", content)
}
```

世界观只改变思维框架，不改变工具能力和项目知识（在 `.kyb.md` 中）。两者正交：
- `.kyb.md` = agent 知道什么（绕 Nexus 403、冷/热启动缓存）
- 世界观 = agent 怎么想问题（大胆假设小心求证、整体涌现 vs 还原论）

### 世界观库（初始）

| 文件名 | 来源 | 效果 |
|--------|------|------|
| `system-cybernetics.md` | 系统论+控制论 | 整体视角、反馈环、涌现、分层 |
| `scientific-empiricism.md` | 科学实证主义 | 假设→实验→数据→结论，大胆假设小心求证 |
| `practical-stoicism.md` | 实践论+矛盾论 | 抓住主要矛盾、实践检验真理、动态发展 |
| `first-principles.md` | 第一性原理 | 拆到不可分再重建、质疑所有默认假设 |
| `stoic-pragmatism.md` | 斯多葛实用主义 | 可控/不可控二分、最小可行、渐进 |

### Boss 模式的多样性策略

```bash
kyb issue fix #42 --diversity 5
# → boss 创建 5 个容器，每人不同世界观
# → 各自独立去查 SLS、复现、定位、修复
# → 最先收敛的提交 MR
# → 其他人看到有人完成了，自动销毁
```

不同世界观 = 不同盲点。同一个 prompt 派 N 个 agent 只是碰运气，不同世界观才是真并行探索。

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

## 通讯渠道

agent 在云上跑，人在手机上接收结果和下达指令。通讯渠道是 agent 与人之间的异步接口。

```
kyb prod sls "status >= 500"                  # 查生产日志
  → agent 发现异常 → 修复
  → 通过微信发你："issue #42 已修复，MR 已提交"
  → 你回："合并"
  → agent 合并 MR → 更新版本 → 通知你："已上线"
```

二层抽象：

```go
type Channel interface {
    Send(ctx context.Context, msg *Message) error
    Listen(ctx context.Context, handler func(*Message)) error  // 接收回复
}

type Message struct {
    From    string    // 渠道 ID
    Content string    // 文本
    Attachments []string  // 图片/文件
}
```

```bash
kyb channel bind wechat                  # 绑定微信
kyb channel bind dingtalk                # 绑定钉钉
kyb channel list                         # 当前绑定渠道
kyb send "all issues fixed, ready to review"  # 通过已绑定渠道发送
```

### 集成模式

kyb 不封装 WeChat/DingTalk SDK——太重了。kyb 只提供**认证隧道 + 消息转发**：

```
火山云 VKE pod
  └─ kyb channel（小的 HTTP server）
       ├─ 微信 webhook → 转发到你手机
       └─ 接收消息 → 注入 agent prompt

你手机
  └─ 微信 → 收到 agent 消息
       └─ 回复 → 转发到 kyb → agent 处理
```

实现上可以是：
- **推送方向**：企业微信机器人 webhook / 个人微信桥（wechaty 等）/ 钉钉机器人
- **接收方向**：企业微信回调 / 轮询微信消息 / 钉钉回调
- 初期只做推送（agent → 人），不做接收（人 → agent），降低复杂度

### 与 notify 的关系

| 命令 | 场景 | 渠道 |
|------|------|------|
| `kyb notify done` | 本地开发，agent 在容器里 | macOS say + afplay |
| `kyb send` | 云上生产，agent 在云上 | 微信/钉钉推送 |
| `kyb channel bind` | 配置绑定 | 初始化 |

`notify` 保持本地（扬声器），`send` 走向远程（通讯 App）。两套不冲突。

```
         ┌─────────────────────────────────────────────┐
         │  火山云 VKE                                  │
         │                                             │
         │  共享 CK: agent_events 表                     │
         │  (所有 agent 读写，查生产数据也走同一个 CK)    │
         │                                             │
         │  kyb server（boss agent）                   │
         │    ├── subagent A: issue #42 查 SLS + CK    │
         │    ├── subagent B: 搭 Grafana 定位           │
         │    ├── subagent C: 查 agent_events 找绕法   │
         │    ├── subagent D-N: 修复方案评估            │
         │    └── 收敛 → 结论写入 agent_events → MR    │
         │                                             │
         │  kyb 自身也在容器里                          │
         │  agent 可以改 kyb 代码                      │
         │  go build → test → MR → merge              │
         │  = kyb 自己迭代了自己                       │
         └─────────────────────────────────────────────┘
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
| 2 | Agent Memory：CK 表结构，打点 CLI，查询接口 | CK 集群（火山云已有） |
| 3 | Provider 接口：实现 CloudProvider（VKE/ECS）| 火山云账号 |
| 4 | 生产数据接入：SLS / CK / Grafana 认证和查询 | SLS/CK/Grafana 权限 |
| 5 | 通讯渠道：WeChat/DingTalk 等推送和异步回复 | 微信/钉钉凭证 |
| 6 | 工具集成：从 agent 踩坑记录固化 kyb fix/* 命令 | 持续积累 |
| 7 | 自迭代：agent 改自己代码 → 测试 → MR merge | 信任 + CI 自动化 |

## 不涉及（明确的非目标）

- 不做 kyb server daemon（有云 provider 后不需要，直接 VKE pod）
- 不做 K8s 集群管理（VKE 管了）
- 不做资源账单管理（火山云自己有）
- 不做中间件全家桶（按需 `--with` / agent 自己起）
- 不做 kyb 自身日志系统（SLS）
- 不做 AMQP/gRPC 接入层（没必要）
- 不自行实现 WeChat/DingTalk SDK（走 webhook + 轻量桥接）
- agent memory CK 不是 kyb 日志——前者存 agent 决策上下文，后者是 kyb 自身运维日志（走 SLS）
