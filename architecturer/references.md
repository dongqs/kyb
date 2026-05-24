# 参考文献

这是 kyb 项目里散落的全部文档索引。正篇和专栏都是从这些原材料里长出来的。

---

## 日记（原始材料）

正篇六章的原材料。都在 `.kyb-diaries/`。

| 文件 | 对应章节 |
|------|---------|
| [2026-05-21 第一天 Boss 日记](/.kyb-diaries/2026-05-21-boss-diary-first-day.md) | 第一章 |
| [2026-05-21 Worktree 已死 Mount 当立](/.kyb-diaries/2026-05-21-worktree-已死-mount-当立.md) | 第一章 |
| [2026-05-21 古法装机](/.kyb-diaries/2026-05-21-gu-fa-zhuang-ji.md) | 番外 |
| [2026-05-22 第二天 Boss 日记](/.kyb-diaries/2026-05-22-boss-diary.md) | 第二章 |
| [2026-05-22→23 夜班](/.kyb-diaries/2026-05-23-infra-night-watch.md) | 第三章 |
| [2026-05-23 Boss 重启](/.kyb-diaries/2026-05-23-boss-reboot.md) | 第四章 |
| [2026-05-23 Infra Boss 白天](/.kyb-diaries/2026-05-23-infra-boss-day.md) | 第四章 |
| [2026-05-23 回顾](/.kyb-diaries/2026-05-23-retrospective.md) | 第五章 |
| [2026-05-23 审计报告](/.kyb-diaries/2026-05-23-review-report.md) | 第四章 |
| [2026-05-23 健壮性审计](/.kyb-diaries/2026-05-23-robustness-audit.md) | 第四章 |
| [2026-05-23 总结](/.kyb-diaries/2026-05-23-summary.md) | 第四章 |
| [2026-05-24 稳定交接](/.kyb-diaries/2026-05-24-stability-handover.md) | 第六章 |
| [事故报告：Boss 失联](/.kyb-diaries/incident-2026-05-23-unreachable-boss.md) | 第五章 Phase 3 |

---

## 基础设施手册（实操部署）

`docs/infra/handbook/` 里的部署手册，每篇都是实测可用的操作指南。

| 服务 | 文件 |
|------|------|
| PostgreSQL | [handbook/postgresql-deploy.md](/docs/infra/handbook/postgresql-deploy.md) |
| Redis | [handbook/redis-deploy.md](/docs/infra/handbook/redis-deploy.md) |
| Kafka | [handbook/kafka-deploy.md](/docs/infra/handbook/kafka-deploy.md) |
| ClickHouse | [handbook/clickhouse-deploy.md](/docs/infra/handbook/clickhouse-deploy.md) |
| Grafana | [handbook/grafana-deploy.md](/docs/infra/handbook/grafana-deploy.md) |
| Sing-Box | [handbook/sing-box-deploy.md](/docs/infra/handbook/sing-box-deploy.md) |
| nuc8 隧道 | [handbook/nuc8-tunnel-deploy.md](/docs/infra/handbook/nuc8-tunnel-deploy.md) |
| ACR | [handbook/acr-deploy.md](/docs/infra/handbook/acr-deploy.md) |

---

## 设计方案

`docs/infra/designs/` 和 `docs/superpowers/` 里的设计文档，记录了每个功能的设计决策。

### Infra 设计

| 文件 | 内容 |
|------|------|
| [designs/bridge-ck-ingestion.md](/docs/infra/designs/bridge-ck-ingestion.md) | 桥梁 CK 数据接入设计 |
| [designs/bridge-hooks-alerting.md](/docs/infra/designs/bridge-hooks-alerting.md) | 桥梁 Hook 告警设计 |
| [designs/bridge-metrics-logging.md](/docs/infra/designs/bridge-metrics-logging.md) | 桥梁监控日志设计 |
| [designs/issue-automation.md](/docs/infra/designs/issue-automation.md) | Issue 自动化设计 |
| [designs/mcp-observability.md](/docs/infra/designs/mcp-observability.md) | MCP 可观测性设计 |

### 历史方案

| 文件 | 内容 |
|------|------|
| [specs/2026-05-21-kyb-agent-runtime-design.md](/docs/superpowers/specs/2026-05-21-kyb-agent-runtime-design.md) | Agent Runtime 设计（触发第二章认知跃迁的那篇文档） |
| [specs/2026-05-21-kyb-worktree-to-mount-design.md](/docs/superpowers/specs/2026-05-21-kyb-worktree-to-mount-design.md) | Worktree→Mount 迁移设计 |
| [specs/2026-05-18-kyb-onboarding-layered-model.md](/docs/superpowers/specs/2026-05-18-kyb-onboarding-layered-model.md) | Onboarding 分层模型 |
| [specs/2026-05-17-kyb-onboarding-design.md](/docs/superpowers/specs/2026-05-17-kyb-onboarding-design.md) | Onboarding 设计 |
| [specs/2026-05-17-did-naming-unification-design.md](/docs/superpowers/specs/2026-05-17-did-naming-unification-design.md) | DID 命名统一设计 |
| [specs/2026-05-17-notify-design.md](/docs/superpowers/specs/2026-05-17-notify-design.md) | TTS Notify 设计 |
| [specs/2026-05-18-kyb-create-dind-fix-design.md](/docs/superpowers/specs/2026-05-18-kyb-create-dind-fix-design.md) | DinD 修复设计 |
| [specs/2026-05-19-kyb-enter-exit-flow-design.md](/docs/superpowers/specs/2026-05-19-kyb-enter-exit-flow-design.md) | Enter/Exit 流程设计 |

---

## 百人实验产出（~130 份）

2026-05-23 晚的百人实验产出了 100+ 篇调研和交叉验证报告。全部在 `docs/infra/` 下，已打标：

### 调研报告（127 份）

`docs/infra/reviews/` 里全部 100+ 篇文件，覆盖：

| 方向 | 内容 |
|------|------|
| 桥梁 | CC 直写 CK、Hook 拦截、WebSocket 健康、飞书速率限制 |
| 可观测 | OTel、eBPF、Prometheus、Grafana Alloy、Vector |
| 网络 | Proxy 拦截、Sidecar、SOCKS5、容器网络延迟 |
| 存储 | CK vs Kafka、Fluentd、Unified 管道 |
| 运维 | 容量规划、磁盘增长、缓存命中率、CI 波动 |
| 安全 | 凭据轮换、TLS 证书、漏洞扫描、配置漂移 |
| 成本 | 每服务成本、Token 效率、模型使用 |
| 告警 | 告警疲劳、SLO 追踪、Oncall、Error Budget |
| 自动化 | GitOps、Chaos Engineering、Self-diagnosis |

### 推荐栈

| 文件 | 决策 |
|------|------|
| [recommended-stack.md](/docs/infra/reviews/recommended-stack.md) | Grafana Alloy → Redpanda → ClickHouse |
| [decisions/vector-vs-kafka-recommendation.md](/docs/infra/decisions/vector-vs-kafka-recommendation.md) | Vector 直写 CK，暂不加 Kafka |

### 预备队（NOW 标签）

6 支预备队 ready-to-go：`cc-hooks-ready`, `ck-schema-ready`, `grafana-ready`, `issue-auto-v2-ready`, `patrol-2-ready`, `vector-ready`。都在 [standby/](/docs/infra/standby/) 下。

---

## 其他技术文档

`docs/` 根目录的散落文档：

| 文件 | 内容 |
|------|------|
| [boss-mode-design.md](/docs/boss-mode-design.md) | Boss Mode 设计 |
| [container.md](/docs/container.md) | 容器相关 |
| [kyb-did.md](/docs/kyb-did.md) | DID 系统 |
| [kyb-pitfalls.md](/docs/kyb-pitfalls.md) | 常见坑 |
| [onboarding-fix-plan.md](/docs/onboarding-fix-plan.md) | Onboarding 修复方案 |
| [onboarding-manager.md](/docs/onboarding-manager.md) | Onboarding 管理器 |
| [network/proxy.md](/docs/network/proxy.md) | 代理配置 |
| [network/sing-box.md](/docs/network/sing-box.md) | Sing-box 配置 |
| [network/issues.md](/docs/network/issues.md) | 网络问题记录 |
| [build/async-build.md](/docs/build/async-build.md) | 异步构建 |
| [build/docker-cache-optimization.md](/docs/build/docker-cache-optimization.md) | Docker 缓存优化 |
| [build/docker-pitfalls.md](/docs/build/docker-pitfalls.md) | Docker 陷阱 |
| [tailscale.md](/docs/tailscale.md) | Tailscale 配置 |

---

## 世界观系统

`lib/kyb/worldviews/` 下的 5 个世界观定义，用于 dispatch 系统的世界观多样性策略：

| 世界观 | 文件 |
|--------|------|
| 第一性原理 | [worldviews/first-principles.md](/lib/kyb/worldviews/first-principles.md) |
| 马克思主义辩证法 | [worldviews/marxist-dialectics.md](/lib/kyb/worldviews/marxist-dialectics.md) |
| 科学实证主义 | [worldviews/scientific-empiricism.md](/lib/kyb/worldviews/scientific-empiricism.md) |
| 斯多葛实用主义 | [worldviews/stoic-pragmatism.md](/lib/kyb/worldviews/stoic-pragmatism.md) |
| 系统控制论 | [worldviews/system-cybernetics.md](/lib/kyb/worldviews/system-cybernetics.md) |

---

## 故事系列

### 一人公司（6 篇）

`docs/stories/one_man_company/` — 从起步到虚拟公司治理的系列故事：

| 篇 | 文件 |
|----|------|
| 起步与基础设施 | [01_起步与基础设施.md](/docs/stories/one_man_company/01_起步与基础设施.md) |
| 大规模环境搭建 | [02_大规模环境搭建.md](/docs/stories/one_man_company/02_大规模环境搭建.md) |
| 遗留代码翻新 | [03_遗留代码翻新.md](/docs/stories/one_man_company/03_遗留代码翻新.md) |
| Onboarding 体系 | [04_Onboarding体系.md](/docs/stories/one_man_company/04_Onboarding体系.md) |
| 咒语与方法论 | [05_咒语与方法论.md](/docs/stories/one_man_company/05_咒语与方法论.md) |
| 虚拟公司治理 | [06_虚拟公司治理.md](/docs/stories/one_man_company/06_虚拟公司治理.md) |

### 零信任家族（5 篇）

`docs/stories/zero_trust/` — Agent 社会学的故事化表达：

| 篇 | 文件 |
|----|------|
| 区块链启蒙 | [01_区块链启蒙.md](/docs/stories/zero_trust/01_区块链启蒙.md) |
| 虚拟家族协作 | [02_虚拟家族协作.md](/docs/stories/zero_trust/02_虚拟家族协作.md) |
| 零信任通信 | [03_零信任通信.md](/docs/stories/zero_trust/03_零信任通信.md) |
| 治理与权限 | [04_治理与权限.md](/docs/stories/zero_trust/04_治理与权限.md) |
| 终极信任实践 | [05_终极信任实践.md](/docs/stories/zero_trust/05_终极信任实践.md) |

### Infra 故事

| 文件 | 内容 |
|------|------|
| [stories/100-agent-iteration.md](/docs/infra/stories/100-agent-iteration.md) | 百人迭代 |
| [stories/blockchain-trust.md](/docs/infra/stories/blockchain-trust.md) | 区块链信任 |
| [stories/death-spiral-to-pass.md](/docs/infra/stories/death-spiral-to-pass.md) | 死亡螺旋 |
| [stories/fizzbuzz-and-boss-mode.md](/docs/infra/stories/fizzbuzz-and-boss-mode.md) | FizzBuzz 和 Boss Mode |
| [stories/ooda-loop-and-cron.md](/docs/infra/stories/ooda-loop-and-cron.md) | OODA 循环 |

---

## 根级文档

| 文件 | 内容 |
|------|------|
| [CLAUDE.md](/CLAUDE.md) | Agent 项目配置 |
| [WISH_LIST.md](/WISH_LIST.md) | 愿望列表/路线图 |
| [.kyb.md](/.kyb.md) | kyb 项目自描述 |

---

## 统计

| 类别 | 数量 |
|------|------|
| 日记 | 19 |
| 部署手册 | 8 |
| 设计方案 | 13 |
| 调研报告 | 100+ |
| 世界观 | 5 |
| 故事 | 16 |
| 其他技术文档 | ~20 |
| **总计** | **~220** |
