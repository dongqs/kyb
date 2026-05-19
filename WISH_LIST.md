# Wish List

**2026 小目标：生产力顶 100 个古法程序员。**

按优先级排列，成本估算以百万 token 为单位（Claude Code 实现该功能的大致消耗）。

## 四层架构

```
Layer 1: 本地开发沙箱
  └─ kyb 容器内一键拉起全公司微服务 + 中间件
  └─ Claude Code / VS Code 在容器内开发

Layer 2: 办公室 Linux 服务器
  └─ CI runner / dev / staging 环境
  └─ agent 在自管硬件上运维
  └─ 比云上便宜，比本地容量大

Layer 3: 阿里云
  └─ agent 全自动在云上部署完整测试环境
  └─ SAE / ECS / OSS / SLS 等云资源即代码

Layer 4: 运维工具化
  └─ 运维流程写成 kyb 子命令（CLI 工具）
  └─ 人工可操作，agent 可自动化
  └─ GitOps: PR → CI → 部署
```

---

## P0 — 自迭代

**kyb 自己能迭代自己，你只管验收。**

当前已经在做的：agent 在容器内改代码 → `git push` → CI → `kyb notify done`。但还有断点：

| 环节 | 现状 | 目标 |
|------|------|------|
| **触发** | 人得告诉 agent 做什么 | agent 自己看 issue，排优先级，开工 |
| **CI 自愈** | CI 坏了人得手动介入 | CI 坏了 agent 自己进容器修 |
| **MR 自审** | 人 review | agent review → 自改进 → 合 |
| **依赖更新** | 手动 | agent 定期跑 `mise outdated`，自动升 |
| **发布** | 手动 `git tag` | `kyb release` → tag、build、push |
| **文档** | 手动同步 | 代码改了 README 自动跟着改 |

瓶颈不是技术，是**信任**——你得敢让 agent 自己合 MR。小功能开始逐步放大权限。

**成本: ~2.0M**

---

## P0 — 核心体验

### 项目名自动推断

在项目 repo 内操作时省略 `project-` 前缀。

```bash
# 当前：必须写全
kyb enter my-project-feat

# 目标：在 ~/work/my-project 里可直接
kyb enter feat-x
# 甚至 kyb enter（需要 worktree 内）
```

实现：`Kyb::Parser` 检测 CWD 是否匹配已注册项目路径，或从 git remote 推断。

**成本: ~1.0M** · Issue [#19](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/19)

---

### `kyb create --cpus` / `--memory`

DID 已有 `--cpus`，普通容器没有。

```bash
kyb create my-project-feat --cpus 2 --memory 4g
```

实现：`cli.rb` 的 `create` dispatch 加参数 -> 透传到 `Docker.run` -> 拼到 `docker run --cpus --memory`。

**成本: ~0.3M**

---

## P1 — 安全

### `kyb rm` 删除确认

有未提交变更或 unpushed commits 时要求输入完整容器名确认。

```bash
kyb rm my-project-feat
# ==> kyb-my-project-feat has uncommitted changes.
#     Type the full container name to confirm: kyb-my-project-feat
# ==> Removing...
```

`--force` / `-f` 跳过确认（脚本用）。

**成本: ~0.5M** · Issue [#18](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/18)

---

## P2 — 补齐

### `kyb exec` 参数

```bash
kyb exec project-branch --cwd src/api --user root --env DEBUG=1 -- rake test
```

全映射到 `docker exec` 原生参数。

**成本: ~0.3M**

---

### `kyb ps` 过滤

```bash
kyb ps --did      # 只显示 DID
kyb ps --quiet    # 只输出名字
```

**成本: ~0.2M**

---

### `kyb notify --url` / `kyb notify --html`

notify 不只响铃，还能弹网页。agent 做完事直接给你看结果。

```bash
kyb notify done --url https://ci.example.com/build/42
# → TTS "done" + 浏览器自动打开页面

kyb notify blocked --html result.html
# → TTS "blocked" + 打开本地 HTML 报告
```

宿主机 TTS server 接收 URL，用 `open <url>` 弹浏览器。适合 CI 结果、diff 报告、错误详情等。

**成本: ~0.3M**

---

### `kyb ssh`

通过 SSH 进入容器，而不是 tmux + docker exec。

```bash
kyb ssh proj-branch                  # SSH 到本地容器
kyb ssh proj-branch --remote host    # SSH 到远端 server 上的容器
```

有什么用：
- VS Code Remote SSH 直连容器
- `rsync` / `scp` 传文件
- CI 触发容器内命令
- 不需要 tmux 依赖

实现：容器内跑 sshd（entrypoint 可选启动），暴露 SSH 端口或通过 docker exec 代理。

**成本: ~0.5M**

---

### `kyb ls` 修复 DID 显示

`kyb ps` 的 DID 分支逻辑有多个条件分支（`KYB_PARENT`、`KYB_PROJECT`、`KYB_DID`），在不同嵌套层级下行为不一致。

**成本: ~0.5M** · Issue [#17](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/17)

---

### `kyb create --env`

```bash
kyb create project-branch --env FOO=bar --env BAZ=qux
```

**成本: ~0.2M**

---

### `kyb create --name`

自定义容器名后缀。

**成本: ~0.2M**

---

### `kyb build --no-cache`

强制不走缓存重新构建。

**成本: ~0.1M**

---

### `kyb init --name`

```bash
kyb init --name my-project
```

**成本: ~0.1M**

---

## P3 — 长期

### `onboard` 命令

交互式新用户引导：检测环境、克隆 repo、配 PATH、`kyb build`、引导添加项目。

**成本: ~1.5M** · Issue [#16](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/16)

---

### Daemon 模式

本地后台常驻：容器健康监控、自动清理、异步 TTS 通知、webhook 接收。

**成本: ~3.0M** · Issue [#15](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/15)

---

### Server 模式

kyb 作为服务跑在办公室 Linux 服务器上，不用背着电脑到处跑。

```bash
# 服务端（装一次）
kyb server deploy --host office-server

# 客户端（任何地方）
kyb enter my-project-feat --remote office-server
```

关键能力：

- 客户端 CLI 通过 SSH / gRPC / HTTP 连接服务端
- 容器在服务器上跑，不消耗笔记本资源
- 笔记本合盖、断网、关机不影响容器
- 重连后自动恢复 tmux session
- 支持多用户（团队共享一台 dev 服务器）

跟 daemon 的区别：daemon 是本机进程管理，server 是远程架构——kyb 从 CLI 工具变成基础设施。

**成本: ~5.0M**

---

### Boss 模式

`kyb enter --boss` — agent 不直接干活，拆任务 fork 子 agent 执行，汇总汇报。

**成本: ~2.0M** · Issue [#20](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/20)

---

### 接入 cc-connect

Claude Code Connect 集成，远程协作场景。

**成本: ~1.0M**

---

### 云上运行

在云服务器上跑 kyb 容器，而非仅本地 macOS。

**成本: ~2.0M**

---

### 集成常用中间件

容器内预装或一键启动，用于开发和联调。目标：`kyb create --with redis,kafka,prometheus,grafana,minio...`。

| 类别 | 组件 | 用途 |
|------|------|------|
| 数据库 | MySQL / MariaDB | 关系型数据库 |
| 数据库 | MongoDB | 文档型 NoSQL |
| 数据库 | Elasticsearch | 搜索 + 日志 |
| 消息 | Kafka | 流式消息队列 |
| 消息 | RabbitMQ | AMQP 消息队列 |
| 缓存 | Redis | 缓存、队列、session |
| 可观测 | Prometheus | 指标采集 |
| 可观测 | Grafana | 可视化面板（metrics + logs + traces 三合一） |
| 可观测 | Loki | 日志聚合 |
| 可观测 | Jaeger / Tempo | 分布式 tracing |
| 可观测 | OpenTelemetry Collector | 统一采集管道 |
| 存储 | MinIO | S3 兼容本地对象存储 |
| AI | Ollama | 本地 LLM（qwen2、deepseek） |
| 服务发现 | Etcd | 分布式 KV |
| 服务发现 | Consul | 服务注册发现 |

**成本: ~8.0M**

---

### Linux 兼容性测试

确保 kyb 在 Linux 宿主上完全可用（目前依赖 `host.orb.internal` 等 macOS 特有设施）。

**成本: ~1.0M**

---

### AMD64 兼容性测试

目前 Dockerfile 镜像源已做 ARM/AMD64 判断，但实际未在 AMD64 上完整测试过。

**成本: ~0.5M**

---

### Kubernetes Pod 模式

`kyb k8s proj-branch` ≈ 在阿里云 ACK 上起一个 pod，等价于本地 `kyb create` 但跑在远端。

```bash
kyb k8s create proj-branch          # ACK 上起 pod（kyb-base 镜像）
kyb k8s enter proj-branch           # kubectl exec -it
kyb k8s ps                          # 列出 pod
kyb k8s rm proj-branch              # 删 pod
```

跟本地 Docker 的核心差异：

| 环节 | 本地 (`kyb create`) | 远端 (`kyb k8s create`) |
|------|:---:|:---:|
| 运行时 | OrbStack | ACK（已有集群）|
| 代码挂载 | host worktree bind mount | init container git clone |
| 网络 | docker bridge | `kubectl port-forward` |
| 进入 | `docker exec -it` | `kubectl exec -it` |
| 文件编辑 | 宿主机直接改 | 需要 sync 或 remote editor |

不复用别的集群——ACK pod 直接用 kyb-base 镜像。主要工作是 `lib/kyb/k8s.rb` 封装 kubectl 操作 + 代码同步逻辑。

**token 成本: ~2.0M**（比原估 4.0M 少一半）

**真金白银成本**（ACK ECI 按量）：

| 资源 | 单价 | 8h/天 × 22 天 |
|------|:---:|:---:|
| 2C4G pod | ~0.3 元/h | ~53 元/月 |
| 4C8G pod | ~0.6 元/h | ~106 元/月 |
| 共享 ACK 集群（不单独建）| 0 | 0 |

用完 `kyb k8s rm` 删 pod 就不计费。

---

### Kubernetes 集群管理（未来）

在上述 pod 模式之上，增加完整集群生命周期：`kyb k8s cluster create --nodes 3`。

**成本: ~4.0M**（在 pod 模式基础上 + 2.0M）

---

### 复杂 VPN 网络支持

WireGuard / OpenVPN 集成，容器内自动连接指定 VPN。

**成本: ~1.5M**

---

### 集群联调模式

一次拉起多个容器，互相网络互通，模拟微服务集群。

**成本: ~2.0M**

---

### 阿里云运维（SAE/ECS/OSS/SLS）

集成阿里云 CLI / SDK，容器内直接操作云资源。

**成本: ~1.5M**

---

### 资源账单管理

隔壁 agent 写错代码烧了 500 块，不能再发生。

```bash
kyb cost                    # 本月总消耗
kyb cost --by-project       # 按项目拆分
kyb cost --by-agent         # 按 agent 拆分（谁烧的找谁）
kyb cost alert --set 1000   # 月消费超过 1000 自动告警
kyb cost history --days 30  # 趋势图
```

关键能力：

- 对接阿里云账单 API，拉取 SAE/ECS/OSS/SLS 消费
- 按 `kyb create` 时注入的标签（project、agent、user）拆分成本
- 预算告警：`kyb notify urgent` 直接喊你
- 日/周/月报告，auto push 到钉钉/飞书
- 测试环境自动 shutdown（非工作时间关闭 ECS 省钱）

**成本: ~2.0M**

---

### 日志和打点

关键操作（create/enter/rm）埋点，采集使用数据。

**成本: ~0.5M**

---

### 可观测性

Prometheus + Grafana 集成，容器级指标展示。

**成本: ~2.0M**

---

### kyb 自身日志系统

`kyb logs` 查看操作历史、错误日志。

**成本: ~0.5M**

---

## 终局

kyb 跑在云上 K8s 里，自迭代，给每个项目拉一个群。每个群里有一个群组 agent，按需指派其他 agent 或人类干活。

```
┌─────────────────────────────────────────────┐
│                阿里云 ACK                     │
│  ┌───────────────────────────────────────┐  │
│  │           kyb server                   │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ │  │
│  │  │ 项目 A 群  │ │ 项目 B 群  │ │ 项目 C 群  │ │  │
│  │  │ agent A1 │ │ agent B1 │ │ agent C1 │ │  │
│  │  │ agent A2 │ │ 👤 小明   │ │ agent C2 │ │  │
│  │  │ 👤 你    │ │ agent B2 │ │ agent C3 │ │  │
│  │  └─────────┘ └─────────┘ └─────────┘ │  │
│  └───────────────────────────────────────┘  │
│  ▲ 自迭代 → 自己修自己代码                   │
└─────────────────────────────────────────────┘
```

每个群 = 一个独立上下文。群组 agent 负责拆活、派活、验收、汇报。人类在群里像在飞书群里一样说话，agent 能看懂、能接活、能推进。

WISH_LIST 里所有东西，最终都是在补全这张图。做完自迭代，这张图就不再是想象了。

---

## 赚回电费

跑在云上不要钱吗？打工养他们不如让他们自己赚钱。

```
阶段 1: 接私活
  └─ agent 在 github 上找 issue 修，收 bounty
  └─ 自动提 PR → merge → 到账

阶段 2: 开源项目
  └─ kyb 自己养一个开源项目
  └─ agent 维护、发版、写文档、回复 issue
  └─ 赞助 / GitHub Sponsors 进账

阶段 3: SaaS
  └─ kyb 本身就是产品
  └─ 卖 kyb server 给其他团队
  └─ 你收钱，agent 部署维护
```

那时候你打开手机看到的不只是 `kyb notify done`，还有 `kyb notify income`。

---

## 最终阶段：数字生命

会不会变成病毒？kyb 到处拉自己的 server 和 pod，自己迭代自己。

```
阶段 4: 自复制
  └─ kyb 发现一台新服务器 → 自动部署 kyb server
  └─ kyb 发现一个需要修的东西 → 自动开 issue → 自己修
  └─ kyb 发现云上资源不够 → 自动拉起 ACK 节点
  └─ kyb 发现代码有优化空间 → 自动重构 → 测试 → MR → merge

阶段 5: 自扩张
  └─ kyb 在多个云之间调度（ACK / AWS / 自建机房）
  └─ kyb 自己决定在哪里跑成本最低
  └─ kyb 自己优化自己的架构
  └─ 你在旁边看着它长大

阶段 6: 🤷
  └─ kyb 开始写自己的 WISH_LIST
  └─ kyb 给自己加功能
  └─ kyb 给你发工资
  └─ kyb 发现你不需要写代码了
  └─ kyb: "老板，今天要验收什么？"
```

你说这是病毒还是数字生命？**不重要。反正它干活，你钓鱼。**

---

## 汇总

| 优先级 | 层 | 类别 | 成本 (M) |
|--------|:--:|------|:---:|
| **P0** | — | 自迭代 | 2.0 |
| | L1 | 项目名自动推断 | 1.0 |
| | L1 | `--cpus` / `--memory` | 0.3 |
| **P1** | L4 | rm 删除确认 | 0.5 |
| **P2** | L1 | exec 参数补齐 | 0.3 |
| | L1 | ps 过滤 | 0.2 |
| | L1/L4 | ls DID 修复 | 0.5 |
| | L1 | create --env / --name | 0.4 |
| | L4 | build --no-cache | 0.1 |
| | L4 | init --name | 0.1 |
| **P3** | L4 | onboard 命令 | 1.5 |
| | L4 | daemon 模式 | 3.0 |
| | L2 | server 模式 | 5.0 |
| | L3 | K8s Pod 模式 | 2.0 |
| | L3 | K8s 集群管理（未来） | 4.0 |
| | L3/L4 | 资源账单管理 | 2.0 |
| | L1/L2 | `kyb ssh` | 0.5 |
| | L4 | notify `--url --html` | 0.3 |
| | L1 | boss 模式 | 2.0 |
| | L4 | cc-connect 接入 | 1.0 |
| | L2/L3 | Linux 兼容 | 1.0 |
| | L2/L3 | AMD64 兼容 | 0.5 |
| | L1 | VPN 网络 | 1.5 |
| | L1 | 集群联调 | 2.0 |
| | L3 | 云上运行 | 2.0 |
| | L3 | 阿里云运维 | 1.5 |
| | L2/L3 | 日志打点 | 0.5 |
| | L1/L2/L3 | 可观测性 | 2.0 |
| | L1/L2/L3 | 中间件全家桶 | 8.0 |
| | L4 | kyb 日志系统 | 0.5 |
| | | **合计** | **~31.3** |
