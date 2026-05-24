# Phase 6: 预备队 + 终裁

**时间：** 03:00-04:00
**规模：** 8 agents（5 standby + 3 experts + 1 merger）

## 预备队

5 个方向各有一个 ready-to-go 的实现方案，意味着进入实施阶段时不需要重新调研。

## 三大关键决策

### 1. Vector 直写 ClickHouse，不加 Kafka

3 个专家 agent 独立分析 Vector vs Kafka trade-off，一致结论：
- 等待 5+ 生产者或 10+ GB/天再考虑 Kafka
- 当前量级 Vector 直写 CK 足够

### 2. cc-connect 原生 hooks

审校 C1 发现 cc-connect v1.3.2 有原生 hooks，省去自建 hook engine。

### 3. Grafana Provisioning as Code 优先

零基础设施最高 ROI。
