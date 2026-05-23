# Vector vs Kafka — 最终推荐报告

> **日期:** 2026-05-23
> **来源:**
> - `docs/infra/decisions/vector-vs-kafka-local.md` — 本地 Mac/Orbstack 环境
> - `docs/infra/decisions/vector-vs-kafka-with-aliyun.md` — Aliyun 远程集群
> - `docs/infra/decisions/vector-vs-kafka-with-volcano.md` — 火山引擎 K8s 前瞻
>
> **决策框架:** kyb o11y 10 条铁律（永不阻塞、默认派人、够信就下一步、先 trace 边缘、Phase 0 零基础设施、优先用已有的、延迟复杂度、Fail-open、成本可见、写完立刻推）

---

## 1. 各范围发现汇总

### 1.1 本地 Mac/Orbstack 环境

**数据量级:** ~2.4 MB/天（现有）+ ~4 MB/天（Vector 部署后预计），约 5,500-17,500 事件/天

**核心发现:**
- Kafka 容器已在运行（`kyb-infra-kafka`，462 MB RAM，空转中），但无 topic、无生产者、无消费者
- 当前量级距离 Kafka 合理阈值（10+ GB/天）差 2,500 倍
- Vector 10K 内存缓冲可吸收 ~1.8 天 CK 停机，256 MB 磁盘缓冲可吸收 ~60 天
- 三大场景——重放、多消费者、消费者隔离——当前均无需求
- 决策框架评分: Vector 45/45 : Kafka 25/45，Vector 全线领先

**结论:** 本地不需要 Kafka。Vector 直写 CK 覆盖所有容错需求。等触发条件（5+ 生产者或 10+ GB/天）再启用。

### 1.2 Aliyun 远程集群

**现状:** Aliyun 只有 1 个 `docker-cache` 容器（ACR registry mirror），无 boss、无 Vector、无 cc-connect。未来可能部署 infra 栈。

**核心发现:**
- Tailscale 链路已通（Mac → Aliyun ~31ms，直连）
- Aliyun → Mac CK 直连写入，`curl http://100.104.244.99:8123/ping` 返回 `Ok.`
- 远程集群数据量极小（~72 KB/天心跳），Vector 256 MB 缓冲可吸收 ~2,000 天
- 两个 Kafka 设计文档（`kafka-message-bus.md`, `unified-kafka.md`）自己说了远程集群不需要 Kafka
- 唯一让 Kafka 优于 Vector 的失败模式是"CK 永久丢失需要 replay"——这是一个 P0 灾难恢复场景，概率极低

**结论:** 远程集群直写 CK。Kafka 没有任何优势；Vector 磁盘缓冲已覆盖所有失败模式。

### 1.3 火山引擎 K8s 前瞻

**核心发现:**
- K8s 环境放大了 Kafka 的每个优势（多 consumer、replay、Pod 漂移恢复、生产者/消费者解耦）—— 差距放大系数 3-10x
- Kafka 作为"持久化层"弥补了 Pod 日志文件的生命周期缺口
- 现在加 Kafka 的工时约 5h，搬 K8s 时加约 8h，但**双重风险**（环境迁移 x 架构变更）需要避免
- 推荐分步走: 搬 K8s -> 直写跑稳 -> 满足条件再加 Kafka
- K8s 场景下决策框架评分差距缩小到 5:4，但 Vector 依然胜出

**结论:** K8s 是 Kafka 的翻盘点，但不应在搬 K8s 的同时加 Kafka。K8s 稳定 3-4 周后再评估。

---

## 2. 跨范围交叉分析

### 2.1 统一数据量级视角

| 范围 | 当前流量 | 预测增长 | 距 Kafka 阈值差距 |
|------|---------|---------|-----------------|
| Mac/Orbstack | ~4 MB/天 | ~17,500 事件/天 | 2,500x |
| Aliyun | ~72 KB/天 | ~150 KB/天 | 66,000x |
| 火山引擎 K8s | 0（未部署） | ~50 MB/天 | 200x |
| **合计** | **~4.5 MB/天** | **~50 MB/天** | **200-66,000x** |

三个范围的数据量均远低于 10+ GB/天的 Kafka 阈值。即使 12 个月 10x 增长，也仅 ~500 MB/天。

### 2.2 决策框架统一评分

| 铁律 | Vector 直写 | Kafka | 决定因素 |
|------|------------|-------|---------|
| 1. 永不阻塞 | ++ | +++ | K8s 下 Kafka 优势明显，但当前 Docker + Aliyun 差距小 |
| 2. 默认派人 | + | - | Kafka 运维更重，与"默认派人"哲学冲突 |
| 3. 够信就下一步 | + | 0 | 三个范围均未达到 Kafka 触发条件 |
| 4. 先 trace 边缘 | + | - | Vector 经多轮审校，Kafka K8s 审校不足 |
| 5. Phase 0 | n/a | n/a | 不影响选型 |
| 6. 优先用已有的 | + | - | Vector 已有设计分，Kafka 容器沉没但管道不存在 |
| **7. 延迟复杂度** | **+** | **-** | **决定性铁律——三个范围都未触发的唯一因素** |
| 8. Fail-open | + | + | 两者都满足 |
| 9. 成本可见 | ++ | - | Vector ROI 高一个数量级 |
| 10. 写完立刻推 | + | + | 无差异 |

**统一评分: Vector 直写在所有三个范围胜出，本地和 Aliyun 是碾压性优势，K8s 是唯一翻盘点。**

### 2.3 唯一让 Kafka 占优的场景

三个范围的交叉分析表明，唯一让 Kafka 明确优于 Vector 直写的场景是:
1. **CK 永久丢失需要 replay**（P0 灾难恢复，概率极低）
2. **K8s Pod 漂移导致日志文件丢失**（K8s 环境特有，当前不存在）
3. **多消费者需求出现**（当前只有 CK 一个消费者）

这三个场景当前均不满足。Kafka 的成本（运维、RAM、磁盘、复杂度）在当前规模下不成立。

### 2.4 关键风险：CK 永久丢失

这是三个范围中最严肃的共同风险。Vector 直写只能恢复尚未写入 CK 的数据（磁盘缓冲中）；已写入 CK 但 CK 后崩溃的数据不可恢复。

**缓解措施:**
- Vector 256 MB 磁盘缓冲（可吸收 25-2,000 天数据，取决于范围）
- 定期 CK 备份（本决策未涉及，建议纳入未来计划）
- 从 Docker JSON 日志文件恢复（受 rotation 限制）

Kafka 的 7 天 replay 在此场景确实优于 Vector，但概率极低，不值得为此付出持续的运维成本。

---

## 3. 最终推荐

### 推荐：Vector 直写 ClickHouse

**不要在本地、Aliyun、或火山引擎 K8s 的初期阶段引入 Kafka 作为日志管道中间件。** 在所有三个范围内，Vector 直写 CK 是最优选择。

### 量化理由

| 指标 | 数值 |
|------|------|
| 当前总流量 | ~4.5 MB/天 |
| 未来预测（12 个月 10x） | ~50 MB/天 |
| Kafka 阈值 | 10+ GB/天 或 5+ 生产者 |
| 差距倍数（当前） | 2,200-66,000x |
| 差距倍数（12 个月后） | 200-6,600x |
| Vector 缓冲容量 | 256 MB 磁盘 (= 25-2,000 天) |
| 决策框架统一评分 | Vector 9 项胜出 vs Kafka 1 项胜出 |

### 分阶段路线图

```
现在（Mac/Orbstack）
  └─ Vector 直写 CK + 256 MB disk buffer
  └─ cc-connect, boss 日志 → Vector → CK
  └─ Kafka 容器保留不动（沉没成本，不增加管道）
       │
       ▼
本周（Aliyun 部署）
  └─ 部署 `kyb-infra-vector`，指向 Mac CK（Tailscale）
  └─ 远程 Vector → CK 直写（不经 Kafka）
       │
       ▼
搬 K8s 时（火山引擎）
  └─ Phase 1: Vector → DaemonSet，直写 CK
  └─ Phase 2（稳定 3-4 周后）: 满足条件时加 Kafka
       │
       ▼
未来（条件触发时）
  └─ 任意条件满足:
       • Pod > 20 个
       • 第二个消费者出现
       • CK 离线导致日志丢失
       • 需要 replay 能力
  └─ 加入 Redpanda，Vector 切到 Kafka sink
  └─ 注意: 不要搬 K8s 的同时加 Kafka
```

### 三个范围的统一决策准则

```
当前流量 < 10 GB/天?
├── 是 → Vector 直写 CK（三个范围都是）
│
└── 否 → 生产者 ≥ 5?
    ├── 是 → Kafka 总线
    └── 否 → CK 离线是否需要 replay?
        ├── 是 → Kafka 总线
        └── 否 → Vector 直写 CK
```

### 跨范围 Kafka 重新评估条件

| 条件 | 阈值 | 本地 | Aliyun | K8s |
|------|------|------|--------|-----|
| 独立生产者 | ≥ 5 | 当前 3 | 当前 1 | 未来 >20 Pod |
| 总流量 | ≥ 10 GB/天 | 差 2,500x | 差 66,000x | 差 200x |
| CK 永久丢失 | 发生过 1 次 | 未发生 | 未发生 | 未发生 |
| 多消费者需求 | ≥ 2 | 不需要 | 不需要 | 未来可能需要 |

**三个范围均不满足任何重新评估条件。**

### 历史数据连续性策略

| 范围 | 策略 | 潜在缺口 |
|------|------|---------|
| Mac/Orbstack | CK 90 天 TTL（默认覆盖所有可观测性需求） | 无 |
| Aliyun | CK 90 天 TTL，Vector 缓冲延长 | 无（极低流量） |
| 火山引擎 K8s | CK 90 天 TTL；加 Kafka 后缺口填补 | Pod 重建到 Kafka 加入之间的日志不可追溯 |

对于 K8s 场景，Phase 1 到 Phase 2 之间的 3-4 周过渡期存在日志连续性缺口。**这是可接受的风险**——在 Pipeline 刚上线时，日志采集的可用性优先于连续性。

### 一句话结论

**三个范围（本地、Aliyun、K8s）一致结论：Vector 直写 CK 是当前最优方案。Kafka 不是技术错误，而是为不存在的需求预付复杂度。等流量涨 200-2,500 倍或生产者增至 5+ 时再启用——现在部署就是超前设计。**

---

> **撰写者:** boss（基于 3 份独立决策报告合并）
> **报告来源:**
> - `docs/infra/decisions/vector-vs-kafka-local.md`
> - `docs/infra/decisions/vector-vs-kafka-with-aliyun.md`
> - `docs/infra/decisions/vector-vs-kafka-with-volcano.md`
>
> ／人◕ ‿‿ ◕人＼
