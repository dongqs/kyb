# Infrastructure Decision Flow

A visual decision framework for kyb infrastructure choices. Based on the 10 decision rules from [summary-session-final.md](summary-session-final.md).

## Mermaid Flowchart

```text
 .------------------.
 | Decision Needed  |
 '--------+---------'
          |
          v
    .-----------.
    | 知道怎么做? |
    '-----+-----'
          |
     +----+----+
     |         |
  不确定     有方向
     |         |
     v         v
 .--------.  .--------.
 | 派3个   |  | 查决策  |
 | agent  |  | 框架    |
 | 分头调研|  | 10条铁律|
 '---+----'  '----+---'
     |             |
     v             v
 .--------.  .-----------.
 | 意见    |  | 新增基础  |
 | 收敛?   |  | 设施?     |
 '---+----'  '-----+-----'
     |              |     |
    / \           是|     |否
   /   \            |     |
  是    否          v     v
   |     |     .--------+.  |
   |     v     |ROI >   |  |
   |  .-----.  |成本2x? |  |
   |  |派10 |  '---+----+  |
   |  |个   |      |   |    |
   |  |agent|      |   |    |
   |  |辩论  |     是|   |否  |
   |  '--+--'      |   |    |
   |     |         v   v    |
   |     v     .---.  .---. |
   |  .----.  |优  |  |拒 | |
   |  |3个  |  |先  |  |绝 | |
   |  |agent|  |用  |  '---' |
   |  |交叉  |  |已  |        |
   |  |验证  |  |有的|        |
   |  '--+--'  '---+--'      |
   |     |         |          |
   |     v         |          |
   |  .----.      / \         |
   |  |3轮  |     /   \       |
   |  |内   |   是/     \否    |
   |  |收敛?|   /       \     |
   |  '--+--'   v         v   |
   |    / \   .---.     .--.  |
   |   /   \  |好,|     |做|  |
   |  是    否|继续|     '--'  |
   |   |     |'---'      |    |
   |   |     v           |    |
   |   |  .--------.     |    |
   |   |  |升级到   |     |    |
   |   |  |用户决策  |     |    |
   |   |  '--------'     |    |
   |   |                 |    |
   +---+-----+-----------+----+
             |
             v
    .-------------------.
    |    定 Phase       |
    '--------+----------'
             |
     +-------+-------+-------+
     |       |       |       |
     v       v       v       v
 .-------. .-------. .-------. .-------.
 |Phase 0| |Phase 1| |Phase 2| |Phase 3|
 |零基础  | |Vector | |Prom   | |深度:  |
 |设施    | |日志管道| |etheus | |export-|
 |Grafana | |日志    | |告警   | |ers    |
 |Provi-  | |持久化  | |指标采集| |容器   |
 |sioning | |       | |       | |指标   |
 |最高ROI | |       | |       | |       |
 '----+---' '----+--' '---+---' '---+---'
      |          |         |         |
      +----+-----+---------+---------+
           |
           v
      .----------.
      | Phase 4  |
      | 未来:    |
      | Alloy /  |
      | Kafka    |
      | 链路追踪  |
      '----+-----'
           |
           v
     .-----------.
     |  打标签    |
     '-----+-----'
           |
     +-----+----+--------+-------+
     |          |        |       |
     v          v        v       v
 .--------. .--------. .------. .----------------.
 |现在就做  | |稍后做  | |不应  | |稍微有点不确定  |
 |立即执行  | |排期跟进 | |该做  | |等专家再审一轮  |
 '--------' '--------' |关闭并 | '----------------'
                        |说明   |
                        |理由   |
                        '------'
```

## Decision Gates

### Gate 1: Know what to do? (Path: Unsure)

When you don't know the answer, follow this escalation chain:

| Step | Action | Rule |
|------|--------|------|
| 1 | Dispatch 3 agents to investigate independently | Rule 2: 默认派人 |
| 2 | Check if opinions converge | — |
| 3 | If yes: execute. If no: dispatch 10 agents to debate | Rule 3: 不够信就派人，还不够就派十个人去吵 |
| 4 | 3 agents cross-verify the debate outcome | Rule 4: 先 trace 边缘再 commit |
| 5 | If still unsure after 3 rounds: escalate to user | Rule 3: 三轮还犹豫找用户 |

**Key principle:** Never block. The cost of waiting 1 hour exceeds the cost of dispatching 1000 agents for 1 hour. (Rule 1: 永不阻塞)

### Gate 2: New Technology Choice

Before adopting any new technology, run through these checks:

| Gate | Question | Rule |
|------|----------|------|
| Decision framework | Have you checked all 10 rules? | Rules 1-10 |
| Adds infrastructure? | Does this require a new container/service? | — |
| ROI vs cost? | Is the ROI at least 2x the total cost (RAM, disk, maintenance)? | Rule 9: 成本可见 |
| Existing tools? | Can an existing tool do this? | Rule 6: 优先用已有的 |
| Premature? | Are we solving a problem we actually have at current scale? | Rule 7: 延迟复杂度 |
| Fail-open? | If this component fails, does production continue? | Rule 8: Fail-open |

### Gate 3: Phase Priority

Always follow this phase order. Do not skip phases.

| Phase | Focus | Cost Profile | Gate Criteria |
|-------|-------|--------------|---------------|
| **Phase 0** | Zero infrastructure (Grafana provisioning as code) | Zero cost, highest ROI | Always do first |
| **Phase 1** | Vector log pipeline, log retention | ~64 MB RAM | P0 complete |
| **Phase 2** | Prometheus, Alertmanager, host alerting | ~350 MB RAM | P1 stable |
| **Phase 3** | Depth: service exporters, container metrics | ~500 MB RAM | P2 stable 1 week |
| **Phase 4** | Future: Alloy, Kafka, OTel traces | Deferred | Volume 100x current |

(Rule 5: Phase 0 = 零基础设施)

### Gate 4: File Decision Tags

Every design review file gets one of four tags:

| Tag | Meaning | Action |
|-----|---------|--------|
| **现在就做** | Ready to deploy, no blockers | Execute immediately |
| **稍后做** | Valid but lower priority | Schedule for next phase |
| **不应该做** | Rejected with clear rationale | Close and document why |
| **稍微有点不确定等专家再审一轮** | Needs more review before decision | Assign reviewer, set deadline |

## Reference: The 10 Decision Rules

From [summary-session-final.md](summary-session-final.md#决策铁律按优先级):

1. **永不阻塞** — 阻塞 1 小时的成本 > 派 1000 个 agent 跑 1 小时
2. **默认派人** — 除非明确要求，否则一律派 subagent
3. **够信就下一步，不够信就派人，还不够就派十个人去吵** — 三轮还犹豫找用户
4. **先 trace 边缘再 commit** — 每个设计先派 3 组人对照现实做交叉审校
5. **Phase 0 = 零基础设施** — Grafana Provisioning as Code 最先做
6. **优先用已有的** — 已有工具 > 自建新工具
7. **延迟复杂度** — 不做超前设计，不到阈值不加 Kafka/Tempo
8. **Fail-open** — 可观测性永远不阻塞生产
9. **成本可见** — 每个方案的 RAM/磁盘/维护成本 vs 价值做全量对比
10. **写完立刻推** — 容器崩了 = 数据全丢

## Technology Selection Matrix

| Dimension | Evaluation | Veto Condition |
|-----------|-----------|----------------|
| Infrastructure cost | RAM / containers / disk / maintenance hours per week | > 2x value = veto |
| Complexity | Learning curve / config language / failure domains | Simpler alternative exists = veto |
| Lock-in risk | Open standard? Replaceable? | No migration path = veto |
| Latency | P0 alert delay < 30s | Delay > 5 min = veto (patrol only) |
| Reliability | Fail-open / retry / non-blocking | Blocks main flow = veto |

---

> Derived from 90+ review documents and 3 infrastructure sessions.
> See [summary-session-final.md](summary-session-final.md) for full context.
