# kyb Infrastructure Boss — Decision Framework

## "Why did you decide what?"

### 决策铁律（按优先级）

1. **永不阻塞** — 阻塞我 1 小时的成本 > 派 1000 个 agent 跑 1 小时。任何不确定立刻派人，不自己想。
2. **默认派人** — 除非明确要求我自己看，否则一律派 subagent。3 人交叉验证，收敛到执行或拒绝。
3. **够信就下一步，不够信就派人，还不够就派十个人去吵** — 三轮还犹豫找用户。
4. **先 trace 边缘再 commit** — 每个设计先派 3 组人对照现实做交叉审校（A/B/C/D/E 系列），发现前提错误（cc-connect hooks 存在、日志格式非 JSON）立即修正设计再继续。
5. **Phase 0 = 零基础设施** — Grafana Provisioning as Code 最先做，因为它成本为零、价值最高、解锁一切下游。
6. **优先用已有的** — cc-connect 原生 hooks（已有）> 自建 hook 引擎，Vector（已有设计）> Fluentd，CK（已有）> Tempo。新增基础设施必须有明确理由。
7. **延迟复杂度** — Kafka 等到 5+ 生产者或 10+ GB/天，Tempo 等到 50K+ spans/天，Alloy 等到 Vector+Prometheus 稳定 3 周。不做超前设计。
8. **Fail-open** — 可观测性永远不阻塞生产。hook 失败不阻塞消息处理，Vector 挂了下游继续跑。
9. **成本可见** — 每个方案的 RAM/磁盘/维护成本 vs 价值做了全量对比（observability-cost-benefit.md），最高 ROI 的先做。
10. **写完立刻推** — 容器崩了=数据全丢。subagent 写完文件必须 git push。

### 技术选型标准

| 维度 | 评估方式 | 否决条件 |
|------|---------|---------|
| 基础设施成本 | 新增 RAM / 容器数 / 磁盘 / 维护小时每周 | 超过价值 2x 即否决 |
| 复杂度 | 新增学习曲线 / 配置语言 / 故障域 | 有更简单的替代方案即否决 |
| 锁定风险 | 是否开放标准 / 能否替换 | 无可替换路径即否决 |
| 实时性 | P0 告警延迟 < 30s | 延迟 > 5min 即否决（仅 patrol 级） |
| 可靠性 | fail-open / 有重试 / 不阻塞主流程 | 阻塞主流程即否决 |

### 本次 session 的关键决策

| 决策 | 选择 | 依据 |
|------|------|------|
| 日志采集 | Vector（现）→ Alloy（未来） | Vector 熟悉，Alloy 需学 River，等 Vector 稳定再迁移 |
| 消息缓冲 | 直接 CK（现）→ Redpanda（未来） | 400 KB/天不配 Kafka，等到 5+ 生产者或 10+ GB/天 |
| 链路追踪 | 存 CK 日志行，不用 Tempo | 540 spans/天，Tempo 320MB 固定开销太浪费 |
| 告警引擎 | Grafana Managed Alerting | 已有 CK 数据源，零新增基础设施 |
| 配置管理 | 代码即配置（YAML/JSON in Git） | 容器重建不丢面板，diff 可见每次变更 |
| hook 方案 | 用 cc-connect 原生 hooks | 审校发现 v1.3.2 已有，自建引擎是重复造轮子 |
| 跨集群 | 远程集群保留 HTTP-CK | 流量太小不值得 Kafka |

### 本次 session 发现的最重要的三件事

1. **cc-connect v1.3.2 有原生 hooks**（审校 C1 发现）— 设计文档前提错误，节省了自建 hook 引擎的工作量
2. **cc-connect 日志不是 JSON**（审校 A1 发现）— 是 Go slog key=value 格式，Vector 配置需要修正
3. **你不在的 3 小时我完全没收到消息** — 推动了端到端可观测性设计的根本需求：不仅要监控容器是否活着，还要监控消息链路是否通着

---

# kyb Infrastructure Observability -- Final Merged Session Summary

**Date:** 2026-05-23
**Scope:** All observability design, review, cost-security analysis, and standby documents produced across three sessions (V1/V2/V3)
**Total documents produced:** ~90 review docs + 5 design docs + 2 standby configs + 1 cost-security summary + 1 recommended stack synthesis

---

## Section 1: Executive Summary

This session produced a complete end-to-end observability architecture for kyb infrastructure across three clusters (Mac/Orbstack, Aliyun, Office NUC). The recommended stack is:

```
Service -> Grafana Alloy (unified collector) -> Redpanda (Kafka API buffer) -> ClickHouse (single telemetry lake) -> Grafana (query + visualization)
```

- **Zero new infrastructure** for Phase 0 (Grafana Provisioning as Code)
- **~64 MB RAM** for Phase 1 (Vector log pipeline)
- **~350 MB RAM** for Phase 1-2 (minimal Prometheus stack for alerting)
- **~500 MB RAM** for full vision (Alloy + Redpanda + exporters)
- **~150 MB/90 days** disk for all logs, traces, and events in ClickHouse

All costs are tiny relative to the 32 GB Mac/Orbstack host. The key question is not "can we afford it" but "what gives best ROI first."

### Priority Order

| Rank | Approach | ROI | When |
|------|----------|-----|------|
| 1 | Grafana Provisioning as Code | Highest (zero infra, immediate value) | Now |
| 2 | Vector Log Pipeline | High (solves data loss, minimal infra) | Now |
| 3 | Prometheus Stack (minimal) | Medium-high (enables alerting) | Week 1-2 |
| 4 | Grafana Alloy | Low-Medium (future consolidation) | After B+C stable |
| 5 | Kafka Message Bus | Low (unnecessary abstraction) | Not until 5+ producers |
| 6 | OTel Traces (Tempo or Kafka+CK) | Very low at current scale | Not until 100x volume |

---

## Section 2: Architecture & Technology Choices

### 2.1 Four-Layer Architecture

The observability stack is organized into four logical layers:

```
Layer 1 (Interception):
  - Docker stdout -> collection agent (all containers)
  - OTel SDK -> OTLP (cc-connect, patrol; future)
  - docker events watcher (container lifecycle)
  - Optional MITM proxy for Feishu WS deep debugging

Layer 2 (Collection):
  - Grafana Alloy (unified, 1 daemon) -- future target
  - Vector + OTel Collector (interim, 2 daemons) -- deploy now

Layer 3 (Transport/Buffer):
  - Redpanda (Kafka API, single binary) -- deferred
  - Direct write to CK -- use now

Layer 4 (Storage):
  - ClickHouse (single telemetry lake)
  - Tables: cc.message_log, patrol.event_log, otel.span_log (future),
            kyb.claude_hook_events, kyb.boss_heartbeats, infra.docker_events (future)

Layer 5 (Query/Visualize):
  - Grafana (ClickHouse datasource, Prometheus datasource for alerts)
```

### 2.2 Technology Rationale

**ClickHouse as single telemetry lake** (rejected: Elasticsearch, PostgreSQL, separate backends per signal type):
- Column-oriented storage 100-1000x faster for log queries than PostgreSQL.
- Single retention policy, single backup, single operational burden.
- Handles structured logs, traces (as flat rows with indexed trace_id), and Prometheus metrics (via remote write) in one system.

**Vector over Grafana Alloy for initial deployment** (rejected: Alloy now, Fluentd, Filebeat, Logstash):
- Vector uses familiar TOML config; Alloy requires learning River (new config language) for zero benefit at this stage.
- Vector cannot scrape Prometheus metrics or receive OTLP traces -- compensated by deploying separate Prometheus + OTel Collector.
- Migration path is clear: Alloy parallel-runs with Vector, then Vector is removed.

**Redpanda deferred** (rejected: Apache Kafka, NATS, no buffer):
- Kafka solves problems we don't have: multiple producers, backpressure from slow consumers, replay.
- At ~400 KB/day with one producer (Vector), the operational cost (512 MB RAM, 5 GB disk, 1 h/week) exceeds the benefit.
- Deploy when 5+ independent producers or 10+ GB/day.

**Traces as log lines, not Tempo** (rejected: Grafana Tempo, Jaeger):
- 540 spans/day does not justify 320 MB of dedicated trace infrastructure.
- Trace-ID-based correlation works via SQL JOINs at this volume.
- Revisit Tempo at 50K+ spans/day.

**Grafana Provisioning as Code first** (before any telemetry pipeline):
- Zero infrastructure cost, immediate value, enables all downstream visualization.
- `deploy.sh` reproduces Grafana configuration from scratch.
- Dashboards and alert rules are peer-reviewed before deployment.

### 2.3 Key Design Principles

1. **Fail-open by design**: Hook failure never blocks message processing. Observability is always secondary to production.
2. **Phased rollout with exit criteria**: Each phase has explicit gate checks before proceeding.
3. **Config in Git from day 1**: All YAML/TOML/River configs version-controlled, never manual UI.
4. **Defer until needed**: Kafka, Alloy, Tempo all deferred until volume or complexity justifies them.
5. **Blameless culture**: Post-mortems identify system gaps, not human errors.

### 2.4 Rejected Alternatives Summary

#### Interception Layer

| Approach | Rejection Reason |
|----------|-----------------|
| tcpdump for WS capture | TLS encryption makes payload invisible |
| SOCKS5 proxy | Tunnels TLS, does not terminate it |
| eBPF/sockmap | Requires kernel 5.3+, fragile, overkill for ~540 frames/day |
| iptables TPROXY | IP-based redirection fragile, needs NET_ADMIN |
| Modify cc-connect natively | Tight coupling to cc-connect release cycle |
| cAdvisor for container metrics | Another container; Docker events simpler for lifecycle |

#### Collection Layer

| Approach | Rejection Reason |
|----------|-----------------|
| Vector as sole collector | Cannot scrape Prometheus metrics or receive OTLP traces |
| Fluentd as sole collector | Higher memory, community CK sink, weaker than Alloy for unified |
| Filebeat | No ClickHouse sink, limited transforms |
| Logstash | 300-600 MB RAM, JRuby, overkill |
| Per-service sidecar Vector | ~225 MB total for 15 sidecars vs ~50 MB for single Alloy |
| Docker log driver (fluentd/syslog) | Limited transform, global impact on failure |

#### Transport Layer

| Approach | Rejection Reason |
|----------|-----------------|
| Apache Kafka | JVM-based, ~500 MB image, slow start, overkill for < 1 MB/day |
| NATS | No Kafka API compatibility; would need different client libraries |
| No buffer (direct Vector -> CK) | Acceptable now; revisit on CK downtime |
| Vector disk buffer only | Single-consumer; adding Kafka consumers requires republishing |

#### Storage Layer

| Approach | Rejection Reason |
|----------|-----------------|
| Grafana Tempo for traces | Second storage backend; extra operational cost |
| Jaeger for traces | Unmaintained (archived); no Grafana-native integration |
| Elasticsearch for logs | Heavy (1+ GB RAM), schema-on-write, slow bulk ingest vs CK |
| Mimir/VictoriaMetrics for metrics | Extra backend; CK already our long-term store |
| PostgreSQL for logs | Row-oriented; log queries scan too many rows |

### 2.5 Migration Phases

#### Phase 0: Foundation (Day 0) -- NOW

- [x] ClickHouse running on Mac/Orbstack (existing)
- [x] Grafana running on Mac/Orbstack (existing)
- [x] Vector parsing cc-connect logs to `cc.message_log` (existing)
- [x] Boss heartbeats via shell loop (existing)
- [x] Boss claude_hook_events via emit-ck.sh (existing)

#### Phase 1: Buffer & Reliability (Week 1-2)

- [ ] Deploy Redpanda container (`kyb-infra-redpanda`)
- [ ] Create topics: `cc.events`, `patrol.events`, `otel.spans`, `docker.events`
- [ ] Add Kafka sink to Vector (dual-write: direct CK + Kafka)
- [ ] Create CK Kafka Engine tables + Materialized Views
- [ ] Verify row counts match between direct Vector and Kafka-sourced ingestion
- [ ] Remove Vector direct CK sink; Kafka becomes primary path
- [ ] Deploy docker-event-watcher inside kyb-infra-boss

#### Phase 2: Unify Collection (Week 2-3)

- [ ] Deploy Grafana Alloy on Mac/Orbstack
- [ ] Configure Alloy: `docker_logs` source, Prometheus scrape, OTLP receive
- [ ] Migrate Vector configs to Alloy River syntax
- [ ] Remove Vector; Alloy becomes primary collector
- [ ] Deploy OTel Collector for traces (or test Alloy's OTLP receiver)
- [ ] Add OTel SDK to cc-connect (instrument key functions)

#### Phase 3: Metrics & Tracing (Week 3-4)

- [ ] Deploy Prometheus exporters: PG, Redis, Kafka, ClickHouse, Node
- [ ] Configure Alloy to scrape all exporters
- [ ] Configure Prometheus remote write -> ClickHouse
- [ ] Verify traces land in `otel.span_log` via Kafka
- [ ] Add trace_id correlation to cc-connect logs

#### Phase 4: Remote Clusters (Week 4-5)

- [ ] Deploy Fluentd (or Alloy) on Aliyun
- [ ] Configure log shipping over Tailscale to central Kafka
- [ ] Deploy Fluentd (or Alloy) on Office
- [ ] Deploy docker-event-watcher on both remote bosses
- [ ] Verify multi-cluster queries in Grafana

#### Phase 5: Grafana Dashboards (Ongoing)

- [ ] Infra Overview (ClickHouse datasource)
- [ ] cc-connect Messages (throughput, latency, tokens)
- [ ] Patrol Health (heartbeat timeline, anomaly count)
- [ ] Docker Events (crash loop detection, OOM watch)
- [ ] Trace Explorer (trace waterfall via ClickHouse datasource)
- [ ] Token Cost (input/output tokens per session, per day)

### 2.6 Key Numbers

| Metric | Value |
|--------|-------|
| Messages through cc-connect | ~90/day |
| Clusters | 3 (Mac/Orbstack, Aliyun, Office NUC) |
| Infra containers total | ~15 |
| Boss events | ~5,000/day |
| Spans if traced | ~540/day |
| Current log volume | ~400 KB/day |
| Heartbeat volume | 4,320 events/day (3 clusters, 60s interval) |
| Hook events | ~200/day (Claude tool calls) |
| Growth assumption (6mo) | 2x |
| Growth assumption (12mo) | 10x |

---

## Section 3: Implementation Priorities

### Phase 0 (Day 0) -- NOW -- Zero Infrastructure

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P0 | **Grafana Provisioning as Code** -- datasource YAML, deploy.sh, version-controlled dashboards | 2h | Manual config loss on Grafana rebuild |
| P0 | **cc-connect Hooks Direct-to-CK** -- native cc-connect hooks POST to ClickHouse (6 lifecycle events + heartbeat) | 1h | Message data loss on container restart |

The cc-connect hooks config is already written and tested (cc-hooks-ready.md). Deploy: add hooks block to config.toml, run DDL, restart cc-connect.

### Phase 1 (Day 1-2) -- Log Retention

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P1 | **Vector log pipeline** -- deploy Vector container, create CK tables (cc.message_log, boss.agent_log, patrol.health_checks), label containers | 4h | All structured log data lost on restart |
| P1 | **Create CK tables** for cc-hooks events (cc.hook_events), message log, patrol health, boss agent log, MCP request log | 1h | (prerequisite for pipelines) |
| P1 | **Boss Overview dashboard** -- heartbeat status from all 3 clusters in one view | 1h | No cross-cluster visibility |

### Phase 2 (Week 1-2) -- Alerting & Metrics

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P2 | **Minimal Prometheus stack** -- Prometheus + Alertmanager + node_exporter only (skip service exporters initially) | 4h | No host-level alerting (disk full, host down) |
| P2 | **Alert rules** -- heartbeat alerts via Grafana (from CK data), disk >85% alerts | 1h | Incidents discovered only at patrol cycle |
| P2 | **Cluster Health dashboard** -- CPU/mem/disk per cluster via Prometheus | 1h | No real-time infrastructure overview |
| P2 | **Deploy Vector on remote clusters** (Aliyun, Office) | 2h | Logs from remote clusters not persisted |

### Phase 3 (Week 3-4) -- Depth

| # | Action | Effort | Value |
|---|--------|--------|-------|
| P2 | Full Prometheus stack: cadvisor + service exporters (PG, Redis, Kafka, CK) | 4h | Container-level resource metrics |
| P2 | Patrol structured logging via Vector | 1h | Patrol health queryable in Grafana |
| P2 | Full dashboard suite (Infra Overview, Service Health, cc-connect Messages) | 2h | Complete visibility |

### Phase 4 (Month 2+) -- Future

| Item | Deferred Until | Reason |
|------|---------------|--------|
| Grafana Alloy (unified collector) | Vector + Prometheus stable 3+ weeks | Premature consolidation is churn |
| OTel SDK in cc-connect (traces as log lines) | When modifying cc-connect anyway | Code change, not infra; store as log lines, no new backend |
| Redpanda (Kafka API buffer) | 5+ independent producers or 10+ GB/day | At 400 KB/day, over-engineered |
| Grafana Tempo (trace backend) | 50K+ spans/day (100x current) | Fixed overhead of ~100 MB for 540 spans/day is wasteful |
| Docker events watcher | Phase 3 | Container lifecycle is low-churn |

---

## Section 4: Cross-Review Findings

The observability design was cross-reviewed across five domains (A through E), with three reviewers per domain (except B which had two). Key findings across all reviews:

### A Series: bridge-ck-ingestion (3 reviews)

**Reviewed:** `review-bridge-ck-ingestion-A1.md`, A2, A3

**Critical finding:** The original design assumed cc-connect emits JSON logs. In reality, cc-connect outputs **Go `log/slog` key=value format** (not JSON) plus unstructured `[Debug]` prefixed lines. Vector therefore needs a key-value parser or regex transform, not a JSON parser.

**Field mapping discrepancies:**
- `trace_id` only appears in Debug lines, not structured INFO lines -- missing from primary log pipeline.
- `chat_id` is embedded in `session=feishu:oc_...:ou_...` as a colon-delimited segment -- needs extraction transform.
- Some fields in the design (`event_type`) are not explicit fields but derivable from `msg=` values.

**Recommendation:** Document actual cc-connect log format, update Vector transform config, add trace_id extraction from Debug lines as a secondary pipeline.

### B Series: bridge-metrics-logging (2 reviews)

**Reviewed:** `review-bridge-metrics-B2.md`, B3

**Critical finding:** The metrics spec declared Prometheus histogram types but annotated them with Summary semantics (pre-computed P50/P90/P99). Histograms expose `_bucket`, `_count`, `_sum`; percentiles must be computed via `histogram_quantile()` in PromQL.

**Specific issues:**
- `turn_duration_seconds` declared as histogram but expected to emit percentiles server-side -- should be Summary if pre-computed quantiles are desired.
- `tokens_per_turn` ambiguous on whether input/output are separate metrics or labels on one metric.
- Bucket boundaries for histograms were unspecified -- consumers cannot know quantile resolution.

**Recommendation:** Replace ambiguous metrics table with unambiguous YAML declarations specifying type, bucket boundaries, and dimension layout.

### C Series: bridge-hooks-alerting (3 reviews)

**Reviewed:** `review-bridge-hooks-C1.md`, C2, C3

**Critical finding (C1):** The design doc opened with "cc-connect has no native hook mechanism, need to build standalone hook engine." This is **incorrect** -- cc-connect v1.3.2 ships with a built-in hooks system supporting all the same trigger points (`message.received`, `response.complete`, `session.timeout`, `session.crashed`, `session.resumed`, `permission.requested`).

**Impact:** The standalone hook engine proposed would be redundant, fragile, and add maintenance burden. The correct approach is:
1. Audit cc-connect v1.3.2 native hooks -- map each alert trigger to a native event.
2. Configure hooks to POST to ClickHouse directly (or an alert pipeline endpoint).
3. Remove the self-healing section -- cc-connect's native health check supersedes the proposed `cc-healthcheck` daemon.

### D Series: MCP Observability (3 reviews)

**Reviewed:** `review-mcp-D1.md`, D2, D3

**Critical finding:** Zero MCP servers are currently running. All defined metrics produce zero values. The document is a forward-looking sketch.

**Verdict:** Accept as forward-looking design -- the metrics schema and alert thresholds are well-chosen and will not need rework when implementation starts.

**Gaps to close at implementation time:**
- No specific MCP server types defined (filesystem, fetch, DB, custom?) -- each has different failure modes.
- No transport security documented (stdio vs HTTP-SSE).
- No auth/credential model for MCP servers.
- No `.mcp.json` config example.
- No deployment detail (container image, port mapping, restart policy).

### E Series: Issue Automation (3 reviews)

**Reviewed:** `review-issue-automation-E1.md`, E2, E3

**Critical finding:** The cc-connect cron approach (方案 C) is the recommended approach -- zero new infrastructure. But operational risks need mitigation.

**Key risks identified:**
1. **Cron job reliability:** Hanging scripts can crash cc-connect. **Mitigation:** Wrap with `timeout 60`.
2. **State persistence:** `last_issue_id` must survive container restarts. **Mitigation:** Store on mounted volume.
3. **Duplicate notifications:** If state write fails after notification, same issue re-notified. **Mitigation:** Write `last_issue_id` _before_ sending notification.
4. **Silent failures:** Script exits with error, no alert raised. **Mitigation:** Pipe errors to cc-connect logging, add heartbeat mechanism.

### Cross-Cutting Recommendation

Across all five review series, a consistent pattern emerged: **start with what exists, add minimal infrastructure, defer complexity until volume justifies it.** The cc-connect native hooks (C series finding) and Docker log key=value parsing (A series finding) are the two most impactful corrections to the original designs.

---

## Section 5: Incident Post-Mortem Framework

### 5.1 Principles

Post-mortems convert incidents into organizational learning. Every incident is a free test of the system under failure conditions. The framework is **blameless by design** -- the root cause is never "a person made a mistake" but always a process, tool, or system gap.

### 5.2 Post-Mortem Lifecycle

```
Incident occurs
    |
    v
Severity assessment --> No post-mortem needed (tier 3)
    |
    v
Post-mortem drafted (within timeline per tier)
    |
    v
Peer review (at least one other engineer reads it)
    |
    v
Action items created (tracked to closure)
    |
    v
Lessons learned entered into DB
    |
    v
Review at next retro / review meeting
    |
    v
Action items closed --> verified
```

### 5.3 Severity and Response Tiers

| Severity | Definition | Post-Mortem | Draft Deadline | Review Deadline |
|----------|-----------|-------------|----------------|-----------------|
| P0 | Complete service outage, data loss, or security breach | Mandatory | 48h | 72h |
| P1 | Severe degradation for subset of users or dependencies | Mandatory | 72h | 5d |
| P2 | Partial degradation, single component, no user impact | Mandatory if user-facing; discretionary otherwise | 5d | 7d |
| P3 | Minor issue, cosmetic, self-resolving | None (log to diary only) | N/A | N/A |

### 5.4 Action Item Tracking

Action items follow lifecycle: Open -> In Progress -> Resolved -> Verified -> Closed.

State management:
- Open > 14d past deadline: auto-ping in Feishu daily.
- Open > 30d past deadline: escalate to team lead.
- Open > 60d past deadline: move to Won't Do or justify extension.
- Won't Do count per-incident > 3: flag in quarterly audit.

Action items tracked as GitLab issues with label `postmortem-action`.

### 5.5 Lessons Learned DB

Stored in ClickHouse (`infra.lessons_learned` table) for queryability:

```sql
CREATE TABLE infra.lessons_learned (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    incident_date   Date,
    incident_id     String,
    postmortem_path String,
    severity        LowCardinality(String),
    service         LowCardinality(String),
    cluster         LowCardinality(String),
    failure_class   LowCardinality(String),
    lesson          String,
    context         String,
    tags            Array(String),
    has_action_item Bool DEFAULT true,
    action_item_ids Array(String),
    action_item_status String DEFAULT 'open',
    author          LowCardinality(String),
    reviewer        LowCardinality(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(incident_date)
ORDER BY (incident_date, service, failure_class)
TTL incident_date + INTERVAL 3 YEAR DELETE;
```

### 5.6 Review Cadence

- **Weekly** (Monday, 30 min): New post-mortems, open action items, trend identification.
- **Monthly** (last Friday, 60 min): Incident summary, top impacts, action item completion rate, systemic issue identification.
- **Quarterly** (90 min): Quarter-over-quarter trends, error budget consumption, recurring failure classes, process improvements.
- **Annual**: Full audit of coverage, quality, closure rate, repeats.

### 5.7 Post-Mortem ClickHouse Schema

Additional tables:
- `infra.post_mortems` -- post-mortem metadata, severity, timeline, action item counts.
- `infra.action_items` -- individual action items with owner, priority, deadline, status.
- Materialized views for monthly summaries and action item aging.

### 5.8 CLI Integration

```bash
kyb lesson add --incident-date YYYY-MM-DD --incident-id "INC-XXX" \
  --postmortem "docs/infra/postmortems/YYYY-MM-DD-desc.md" \
  --severity P1 --service <service> --cluster <cluster> \
  --failure-class <class> --lesson "<lesson text>" --tags "tag1,tag2"
kyb lesson list --limit 10
kyb lesson search --keyword "<term>"
kyb lesson stats --by failure-class
```

---

## Section 6: Cost & Security

### 6.1 Cost Findings

**Token Cost Tracking** (`token-cost.md`):
- Claude Code API token spend has no aggregated visibility today.
- Solution: `token-tracker.sh` daemon captures end-of-turn token summaries, stores in `infra.token_usage`.
- Volume: ~4,800 records/day, ~60 MB/year compressed.
- Budget alerts at 80% (warning) and 100% (exceeded) of target.
- Anomaly detection at 3x trailing 7-day average.

**Model Usage Tracking** (`model-usage.md`):
- Opus costs ~18.75x Haiku for the same output -- #1 source of wasted spend.
- Patrol agents should always use Haiku ($0.50-$1.00/day each).
- Anti-patterns: model drift in subagents, Opus for trivial reads, forgotten global model overrides.

**Monthly Cost Targets:**

| Category | Target | Alert At |
|----------|--------|----------|
| Patrol agents | $90/mo | $150/mo |
| Boss sessions | $200/mo | $400/mo |
| Bridge agents | $100/mo | $200/mo |
| Sandbox agents | $100/mo | $200/mo |
| Review agents | $150/mo | $300/mo |
| **Total infra** | **$640/mo** | **$1,250/mo** |

**Docker Build Cache** (`cache-hit.md`):
- Total build cache: ~23 GB, of which 2.41 GB immediately reclaimable.
- Cache budget: 15 GB per host. Warning at 12 GB, auto-GC at 14 GB.

**Dangling Image Waste** (`dangling-images.md`):
- Docker disk: 181.5 GB total, ~28 GB (16%) reclaimable.
- Breakdown: dangling images (6.07 GB), zombie containers (13 GB), stale tagged images (~6.7 GB), build cache rot (2.41 GB).
- Auto-cleanup tiers: Green (<10%), Yellow (10-20%), Red (20-30%), Critical (>30% or disk >85%).

**Volume Disk Usage** (`volume-usage.md`):
- Docker volumes: ~15.1 GB across 25 volumes.
- 96% is build cache (gradle, maven, swift) expected to plateau.
- Boss container writable layers: ~22.5 GB cumulative (~4.5 GB transient data per boss).

**Disk Growth Monitoring** (`disk-growth.md`):

| Cluster | Warning | Critical |
|---------|---------|----------|
| Mac/Orbstack (260 GiB) | <20 GiB or <30 days | <5 GiB or <7 days |
| Aliyun (40 GiB) | <5 GiB or <14 days | <2 GiB or <3 days |
| Office NUC (256 GiB) | <20 GiB or <30 days | <5 GiB or <7 days |

### 6.2 Security Findings

**Secret Rotation** (`secret-rotation.md`):
- No secret rotation tracking exists today.
- Policies: API tokens 90d, TLS certs 90d (auto-renew), CI/CD tokens 180d, DB credentials 180d, SSH keys 365d, cloud keys 90d.
- Solution: `secret-rotation-exporter` Prometheus endpoint reading `~/.kyb/secrets/registry.yml`.
- Alert severity: expired = P0 (@all + TTS), >90% of policy = P1, compliance <90% = P2.

**Container Vulnerability Scanning** (`vuln-scan.md`):
- ~30 container images across 3 clusters, zero automated scanning.
- Solution: Trivy as primary scanner (offline-capable, ~5-15s/image), Grype as weekly cross-check.
- Fix age SLOs: CRITICAL CVEs in sandbox/infra images within 72h, HIGH within 7d.

**Network Policy Compliance** (`network-compliance.md`):
- All infra containers share a flat Docker bridge network (`kyb-net`) with zero isolation.
- No iptables/nftables on Orbstack -- monitoring is the only enforcement mechanism.
- Solution: `kyb-net-monitor` with conntrack events + periodic port scanning against allowlist.

**Multi-Tenancy Isolation** (`multi-tenancy.md`):
- No per-project resource tracking, isolation verification, or access audit logging.
- Solution: Docker labels (`kyb.project`, `kyb.user`) as tenancy source of truth.

**Config Drift Detection** (`config-drift.md`):
- SHA256 checksums of tracked config files, stored in ClickHouse as baselines.
- Detection script runs every 5 minutes (patrol cycle).
- Auto-revert for git-managed files; per-boss configs require manual acknowledgment.

### 6.3 Cost-Security Implementation Priorities

**Phase 0 (do now -- high severity):**
- Deploy `token-tracker.sh` Mode B in boss container (token-cost.md)
- Deploy Trivy, create CK tables, run baseline scan (vuln-scan.md)
- Deploy `secret-rotation-exporter`, seed registry (secret-rotation.md)
- Deploy `kyb-net-monitor` with conntrack + port scan (network-compliance.md)

**Phase 1 (this week -- medium severity):**
- Add `docker image prune --force` to `kyb build` (dangling-images.md)
- Collect disk metrics every 5 min, compute exhaustion prediction (disk-growth.md)
- Deploy `kyb-config-snapshot.sh` + `kyb-config-check.sh` (config-drift.md)

**Phase 2 (next week):**
- Model usage tracking (model-usage.md)
- Build cache monitoring (cache-hit.md)
- Multi-tenancy audit labeling (multi-tenancy.md)

**Total Phase 0-1 effort: ~24 hours**
**Annual cost at risk without Phase 0:** Unbounded LLM spend (target $640/mo) + disk exhaustion incidents + credential expiry outages + undetected CVEs + invisible lateral movement.

---

## Section 7: Risks & Next Steps

### 7.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| cc-connect crash, all logs lost | High (happens) | Medium | Vector pipeline persists logs to CK |
| Disk full on Aliyun (40 GiB), no alert | Medium | High | Prometheus + node_exporter disk alerting |
| Grafana rebuild, all dashboards/configs lost | Low (rare) | Medium | Grafana provisioning as code in Git |
| Can't debug slow message | High (weekly) | Low-Medium | Logs in CK enable SQL queries |
| Remote cluster offline, unknown for hours | Medium | Medium | Cross-cluster alerts via Prometheus |
| cc-connect hooks TOML may strip URL query params | Unknown | Medium | nginx shim documented as fallback |

### 7.2 Execution Risks

| Risk | Mitigation |
|------|-----------|
| "Just deploy everything" syndrome leading to alert fatigue | Phased rollout with exit criteria per phase |
| Config files not version-controlled | All YAML/TOML/River configs in Git from day 1 |
| Remote cluster deployment failure | Documented SSH + docker run commands per cluster |
| Learning curve (River for Alloy, PromQL for Prometheus) | Defer Alloy; use TOML/YAML first, learn PromQL later |

### 7.3 Decision that Changes Everything

The biggest architectural fork: deploy **Redpanda (Kafka API)** or not.

- **Without Kafka:** Vector -> CK (direct). Simpler, fewer containers, zero additional failure modes. Works at current volume (400 KB/day).
- **With Kafka:** Vector -> Redpanda -> CK. Resilient to CK downtime, enables replay, supports future multi-consumer. Adds 256 MB RAM, one more container to monitor.

**Recommendation (from cost-benefit analysis):** Defer Kafka until 5+ independent producers or 10+ GB/day. At current volume, the cost (512 MB RAM, 5 GB disk, 1 h/week maintenance) exceeds the benefit. Start with direct Vector -> CK. If CK downtime causes data loss, add Kafka as a point fix.

### 7.4 Standby Teams Ready to Deploy

Two complete, reviewed, ready-to-deploy configurations exist:

**Team 1: cc-connect Hooks Direct-to-ClickHouse**

**File:** `docs/infra/standby/cc-hooks-ready.md`
**Status:** READY -- config TOML block, CK schema, and deployment steps fully documented.

- Native cc-connect v1.3.2 hooks, no Vector, no Kafka
- ~90 messages/day, ~34 KB/day -- zero additional infrastructure justified
- 6 lifecycle events subscribed + optional heartbeat
- Direct HTTP POST to ClickHouse endpoint
- Fail-open by design: hook failure never blocks message processing
- 2 retries with exponential backoff (500ms-5000ms total window ~1.5s)
- TTL: 90 days on MergeTree table

**Team 2: Vector Log Pipeline**

**File:** `docs/infra/standby/vector-ready.md`
**Status:** READY -- three designs fully reviewed, no open questions.

| Document | Scope |
|----------|-------|
| `vector-pipeline.md` (~1310 lines) | Vector for infra containers. Docker log API + label discovery. Full config, transforms, CK schemas, deployment. |
| `unified-vector.md` (~1285 lines) | Expanded: ALL containers via file tail, single `infra.message_log` canonical table, remote cluster forwarding, migration strategy. |
| `otel-vector.md` (~1065 lines) | OTel Collector + Vector combined pipeline for traces/metrics/logs. Two-stage: Collector terminates OTLP, Vector enriches/routes to CK. |

**Team 3: Grafana Provisioning as Code**

**File:** `docs/infra/standby/grafana-ready.md`
**Status:** READY -- datasource YAMLs, dashboard JSONs, deploy.sh, and alert rule YAMLs all in `docs/infra/grafana/provisioning/`.

### 7.5 Immediate Next Steps (< 1 day)

1. **Deploy cc-connect hooks direct-to-CK** -- add hooks block to `/root/.cc-connect/config.toml`, create `cc.hook_events` table, restart cc-connect.
2. **Create Grafana provisioning** -- `docs/infra/grafana/` with datasource YAMLs, deploy.sh.
3. **Write `vector.toml` config file** -- the last missing piece before Vector can be deployed.

### 7.6 Short-term (this week)

4. Deploy Vector container on Mac/Orbstack.
5. Create CK tables for all log types.
6. Label infra containers with `kyb.logs=true`.
7. Create first dashboards: Boss Overview, Container Log Explorer.
8. Deploy Prometheus + node_exporter for host-level alerting.
9. Wire Alertmanager to Feishu via cc-connect.

### 7.7 Medium-term (next 1-2 weeks)

10. Deploy remote cluster Vector (Aliyun, Office).
11. Add service exporters (PG, Redis, Kafka, CK).
12. Full dashboard suite: Infra Overview, Service Health, cc-connect Messages.
13. Tune alert thresholds -- measure fatigue baseline.

### 7.8 Long-term (Month 2+)

14. OTel SDK instrumentation in cc-connect.
15. Evaluate Grafana Alloy as unified collector.
16. Evaluate Redpanda if multi-producer need arises.

### 7.9 Blockers

- `vector.toml` config file and SQL schema files need to be created in `docs/infra/vector/`.
- cc-connect hooks TOML URL query param handling needs verification (nginx shim fallback documented).
- Grafana provisioning `deploy.sh` needs implementation.

---

## Section 8: Complete Document Index

### 8.1 Design Docs

| File | Purpose |
|------|---------|
| `docs/infra/observability-design.md` | Chinese-language design summary of 3 approaches |
| `docs/infra/designs/bridge-ck-ingestion.md` | cc-connect message log table + Grafana panels |
| `docs/infra/designs/bridge-hooks-alerting.md` | Hook trigger points + alert rules |
| `docs/infra/designs/bridge-metrics-logging.md` | Metrics logging approach |
| `docs/infra/designs/mcp-observability.md` | MCP observability (future) |
| `docs/infra/designs/issue-automation.md` | Issue auto-detection (cc-connect cron recommended) |

### 8.2 Key Review Documents

| File | Lines | Scope |
|------|-------|-------|
| `docs/infra/reviews/observability-cost-benefit.md` | ~939 | Complete cost-benefit analysis of 8 approaches (A-H) with phased rollout plan and sensitivity analysis |
| `docs/infra/reviews/recommended-stack.md` | ~596 | Single source of truth: recommended stack with 4-layer architecture and migration path |
| `docs/infra/reviews/summary-cost-security.md` | ~292 | Cost + security priorities from all 90 review docs |
| `docs/infra/reviews/cross-cluster-metrics.md` | ~750+ | Cross-cluster aggregation design across 3+ clusters |
| `docs/infra/reviews/vector-pipeline.md` | ~1310 | Vector pipeline detailed design |
| `docs/infra/reviews/unified-vector.md` | ~1285 | Expanded vector scope (all containers, multi-cluster) |
| `docs/infra/reviews/otel-vector.md` | ~1065 | OTel + Vector combined pipeline |
| `docs/infra/reviews/hooks-direct-ck.md` | ~1300 | cc-connect hooks direct-to-CK detailed review |
| `docs/infra/reviews/hooks-kafka.md` | ~1350 | Kafka pipeline alternative review |

### 8.3 Review Series (Cross-Review Findings)

| File | Domain | Highlight |
|------|--------|----------|
| `docs/infra/reviews/review-bridge-ck-ingestion-A1.md` | Bridge CK ingestion | Key finding: log format is key=value not JSON |
| `docs/infra/reviews/review-bridge-ck-ingestion-A2.md` | Bridge CK ingestion | Consistency review |
| `docs/infra/reviews/review-bridge-ck-ingestion-A3.md` | Bridge CK ingestion | Consistency review |
| `docs/infra/reviews/review-bridge-metrics-B2.md` | Bridge metrics | Key finding: histogram vs summary confusion |
| `docs/infra/reviews/review-bridge-metrics-B3.md` | Bridge metrics | Consistency review |
| `docs/infra/reviews/review-bridge-hooks-C1.md` | Bridge hooks/alerting | Key finding: cc-connect v1.3.2 has native hooks |
| `docs/infra/reviews/review-bridge-hooks-C2.md` | Bridge hooks/alerting | Consistency review |
| `docs/infra/reviews/review-bridge-hooks-C3.md` | Bridge hooks/alerting | Consistency review |
| `docs/infra/reviews/review-mcp-D1.md` | MCP observability | Key finding: zero MCP servers running |
| `docs/infra/reviews/review-mcp-D2.md` | MCP observability | Consistency review |
| `docs/infra/reviews/review-mcp-D3.md` | MCP observability | Consistency review |
| `docs/infra/reviews/review-issue-automation-E1.md` | Issue automation | Key finding: cron reliability, persistence risks |
| `docs/infra/reviews/review-issue-automation-E2.md` | Issue automation | Consistency review |
| `docs/infra/reviews/review-issue-automation-E3.md` | Issue automation | Consistency review |

### 8.4 Recommendation Summaries

| File | Scope |
|------|-------|
| `docs/infra/reviews/recommend-alerting.md` | Alerting recommendations |
| `docs/infra/reviews/recommend-automation.md` | Automation recommendations |
| `docs/infra/reviews/recommend-cost-security.md` | Cost-security recommendations |
| `docs/infra/reviews/recommend-logs.md` | Log pipeline recommendations |
| `docs/infra/reviews/recommend-metrics.md` | Metrics recommendations |
| `docs/infra/reviews/recommend-traces.md` | Traces recommendations |

### 8.5 Summary Documents

| File | Scope |
|------|-------|
| `docs/infra/reviews/summary-alerting.md` | Alerting summary |
| `docs/infra/reviews/summary-automation.md` | Automation summary |
| `docs/infra/reviews/summary-cost-security.md` | Cost + security summary |
| `docs/infra/reviews/summary-logs.md` | Logs summary |
| `docs/infra/reviews/summary-metrics.md` | Metrics summary |
| `docs/infra/reviews/summary-traces.md` | Traces summary |

### 8.6 Standby Configs (Ready to Deploy)

| File | Purpose |
|------|---------|
| `docs/infra/standby/cc-hooks-ready.md` | cc-connect direct-to-CK hooks config + CK schema |
| `docs/infra/standby/vector-ready.md` | Vector pipeline deployment plan (3 designs reviewed) |
| `docs/infra/standby/grafana-ready.md` | Grafana provisioning as code: datasource YAML, dashboards, deploy.sh |
| `docs/infra/standby/issue-auto-v2-ready.md` | Issue automation v2 ready config |
| `docs/infra/standby/patrol-2-ready.md` | Patrol v2 ready config |

### 8.7 Cost and Security Documents

| File | Cost Relevance | Security Relevance |
|------|---------------|-------------------|
| `docs/infra/reviews/token-cost.md` | Primary (LLM spend tracking) | None |
| `docs/infra/reviews/model-usage.md` | Primary (model cost optimization) | None |
| `docs/infra/reviews/cache-hit.md` | Secondary (build time = compute cost) | None |
| `docs/infra/reviews/dangling-images.md` | Secondary (disk waste = storage cost) | None |
| `docs/infra/reviews/volume-usage.md` | Secondary (volume sizing) | None |
| `docs/infra/reviews/disk-growth.md` | Secondary (disk exhaustion prevention) | None |
| `docs/infra/reviews/base-image-age.md` | Secondary (rebuild cost) | Secondary (vuln drift) |
| `docs/infra/reviews/secret-rotation.md` | None | Primary (credential lifecycle) |
| `docs/infra/reviews/vuln-scan.md` | None | Primary (CVE management) |
| `docs/infra/reviews/network-compliance.md` | None | Primary (isolation + detection) |
| `docs/infra/reviews/multi-tenancy.md` | Secondary (per-project billing data) | Primary (isolation audit) |
| `docs/infra/reviews/config-drift.md` | None | Primary (integrity monitoring) |

### 8.8 Cross-Cutting Documents

| File | Purpose |
|------|---------|
| `docs/infra/reviews/alert-fatigue.md` | Alert fatigue monitoring and threshold design |
| `docs/infra/reviews/postmortem.md` | Post-mortem process, template, action item tracking |
| `docs/infra/reviews/oncall.md` | Oncall scope and triage path |
| `docs/infra/reviews/error-budget.md` | Error budget tracking across cost and security |
| `docs/infra/reviews/incident-severity.md` | Incident severity definitions and response tiers |
| `docs/infra/reviews/incident-slo.md` | Incident SLO tracking |

### 8.9 Technical Review Documents

| File | Scope |
|------|-------|
| `docs/infra/reviews/grafana-provisioning.md` | Grafana provisioning as code |
| `docs/infra/reviews/grafana-alloy.md` | Alloy unified collector evaluation |
| `docs/infra/reviews/grafana-usage.md` | Grafana usage patterns |
| `docs/infra/reviews/prometheus-scrape.md` | Prometheus scrape configuration |
| `docs/infra/reviews/node-exporter.md` | Node exporter deployment |
| `docs/infra/reviews/cadvisor-metrics.md` | cAdvisor container metrics |
| `docs/infra/reviews/docker-events.md` | Docker events watcher design |
| `docs/infra/reviews/kafka-message-bus.md` | Kafka message bus evaluation |
| `docs/infra/reviews/kafka-lag.md` | Kafka consumer lag monitoring |
| `docs/infra/reviews/fluentd-pipeline.md` | Fluentd pipeline evaluation |
| `docs/infra/reviews/otel-cc-connect.md` | OTel instrumentation for cc-connect |
| `docs/infra/reviews/otel-patrol.md` | OTel instrumentation for patrol |
| `docs/infra/reviews/otel-mcp.md` | OTel instrumentation for MCP |
| `docs/infra/reviews/otel-kafka.md` | OTel traces via Kafka |
| `docs/infra/reviews/otel-kafka-vector.md` | OTel + Kafka + Vector combined |
| `docs/infra/reviews/otel-sidecar.md` | OTel sidecar pattern |
| `docs/infra/reviews/otel-proxy.md` | OTel proxy pattern |
| `docs/infra/reviews/unified-otel.md` | Unified OTel strategy |
| `docs/infra/reviews/unified-kafka.md` | Unified Kafka strategy |
| `docs/infra/reviews/intercept-comparison.md` | Interception method comparison |
| `docs/infra/reviews/proxy-intercept.md` | Proxy interception methods |
| `docs/infra/reviews/socks5-intercept.md` | SOCKS5 interception |
| `docs/infra/reviews/sidecar-intercept.md` | Sidecar interception |
| `docs/infra/reviews/sidecar-pattern.md` | Sidecar pattern evaluation |
| `docs/infra/reviews/http-hook-intercept.md` | HTTP hook interception |
| `docs/infra/reviews/docker-net-intercept.md` | Docker network interception |
| `docs/infra/reviews/feishu-webhook-intercept.md` | Feishu webhook interception |
| `docs/infra/reviews/feishu-delivery.md` | Feishu message delivery |
| `docs/infra/reviews/feishu-rate-limit.md` | Feishu rate limit handling |
| `docs/infra/reviews/storage-comparison.md` | Storage backend comparison |
| `docs/infra/reviews/stdout-parse.md` | Stdout log parsing |
| `docs/infra/reviews/cc-ws-health.md` | cc-connect WebSocket health |
| `docs/infra/reviews/cc-hooks-direct-ck.md` | cc-connect hooks direct to CK |

### 8.10 Operational & Infrastructure Documents

| File | Purpose |
|------|---------|
| `docs/infra/5min-patrol-guide.md` | 5-minute patrol checklist with heartbeat files |
| `docs/infra/chat.md` | Session chat log |
| `docs/infra/multi-cluster-boss-architecture.md` | Multi-cluster boss architecture |
| `docs/infra/handbook/hooks-ck-pipeline.md` | Hooks-to-CK pipeline handbook |
| `docs/infra/handbook/registry-cache-deploy.md` | Registry cache deployment handbook |

### 8.11 Grafana Provisioning Files

| File | Purpose |
|------|---------|
| `docs/infra/grafana/deploy.sh` | Deployment script for Grafana provisioning |
| `docs/infra/grafana/provisioning/datasources/clickhouse.yaml` | ClickHouse datasource config |
| `docs/infra/grafana/provisioning/datasources/postgres.yaml` | PostgreSQL datasource config |
| `docs/infra/grafana/provisioning/datasources/prometheus.yaml` | Prometheus datasource config |
| `docs/infra/grafana/provisioning/notifiers/feishu.yaml` | Feishu notifier config |
| `docs/infra/grafana/provisioning/dashboards/dashboard_providers.yaml` | Dashboard providers config |
| `docs/infra/grafana/provisioning/dashboards/json/boss-overview.json` | Boss overview dashboard JSON |
| `docs/infra/grafana/provisioning/dashboards/json/cc-connect-health.json` | cc-connect health dashboard JSON |
| `docs/infra/grafana/provisioning/dashboards/json/cluster-health.json` | Cluster health dashboard JSON |
| `docs/infra/grafana/provisioning/dashboards/json/heartbeat-monitor.json` | Heartbeat monitor dashboard JSON |
| `docs/infra/grafana/provisioning/dashboards/json/pg-replication.json` | PG replication dashboard JSON |
| `docs/infra/grafana/provisioning/alerting/resources/bridge-alerts.yaml` | Bridge alert rules |
| `docs/infra/grafana/provisioning/alerting/resources/heartbeat-alerts.yaml` | Heartbeat alert rules |
| `docs/infra/grafana/provisioning/alerting/policies/default-policy.yaml` | Default alert policy |

### 8.12 Deployment Matrix per Cluster

| Component | Mac/Orbstack (central) | Aliyun (remote) | Office NUC (remote) |
|-----------|----------------------|-----------------|---------------------|
| Vector (log pipeline) | P0 deploy | Phase 2 | Phase 2 |
| CK tables | P0 create | N/A (central) | N/A (central) |
| Prometheus + Alertmanager | Phase 1 | N/A (scraped via Tailscale) | N/A |
| node_exporter | Phase 1 | Phase 1 | Phase 1 |
| Grafana provisioning | P0 create | N/A (central) | N/A (central) |
| Redpanda | Deferred | Deferred | Deferred |
| cadvisor + service exporters | Phase 3 | Phase 3 | Phase 3 |
| OTel SDK + Collector | Month 2+ | N/A | N/A |

---

## Appendix: What We Actually Get (After G + B + C)

| Capability | Before | After |
|-----------|--------|-------|
| Log retention | None (lost on restart) | 90 days in CK |
| Dashboard | None | Boss Overview, Cluster Health, Heartbeat Monitor |
| Alerting | None (manual patrol) | Heartbeat, disk, host down alerts via Feishu |
| Container metrics | `docker stats` | Prometheus + Grafana panels |
| Host metrics | `df -h` manually | node_exporter + Prometheus |
| Multi-cluster view | None | Single Grafana shows all 3 clusters |
| Debugging | `docker logs` (if container alive) | `SELECT * FROM cc.message_log` |
| Reproducibility | Lost on container rebuild | Git + deploy.sh restores everything |
| Response time | 2-5 min (patrol cycle) | <30s (alert notification) |

---

## Appendix: Cost Summary Table

| Approach | New Containers | New RAM | New Disk | Setup Effort | Maintenance | Net ROI |
|----------|---------------|---------|----------|-------------|-------------|---------|
| Status Quo | 0 | 0 | 0 | 0h | 2-4 h/week | Negative (hidden costs) |
| Vector | 1 (per cluster) | 64 MB | 200 MB CK | 4h | 1 h/week | **High** |
| Prometheus (full) | 8 | 860 MB | 2-5 GB | 6h | 2 h/week | Medium-high |
| Prometheus (minimal) | 3 | 350 MB | 500 MB | 4h | 1 h/week | Medium |
| Alloy | 1 | 150 MB | 1.5 GB WAL | 4h | 1.5 h/week | Low-Medium |
| Tempo traces | 2 | 320 MB | 100 MB | 4h | 0.5 h/week | Very low |
| Kafka+CK traces | 1 | 64 MB | 15 MB CK | 5h | 0.5 h/week | Very low |
| **Grafana Provisioning** | **0** | **0** | **<150 KB** | **2h** | **0.5 h/week** | **Highest** |
| Kafka bus | 1 | 512 MB | 5 GB | 3h | 1 h/week | Very low |

---

> **Total documents in session:** ~90 review docs, 5 design docs, 2 standby configs, 1 cost-security summary, 1 recommended stack synthesis.
> **Implementation effort for Phase 0-1:** ~8 hours. For full vision: ~24 hours.
> **Annual cost at risk without Phase 0:** Unbounded LLM spend + disk exhaustion + credential expiry.
> **Total estimated implementation effort for Phase 0-1 (cost+security):** ~24 hours across all cost and security reviews.

## 工具简介

| 工具 | 一句话说明 |
|------|-----------|
| ClickHouse | 列式数据库，专为大规模日志/指标/ traces 的存储和分析设计，SQL 接口，压缩比 5-8x |
| Vector | Rust 写的日志采集器，~15MB 二进制，自带 ClickHouse sink，可做解析/过滤/路由 |
| Grafana | 可观测性面板，支持 ClickHouse/Prometheus 等数据源，统一查看日志、指标、链路 |
| Alloy | Grafana 出的统一采集器（替代 Vector + Prometheus + OTel Collector 三个），配置语言叫 River |
| Prometheus | 监控告警系统，定时拉取指标，支持 PromQL 查询和告警规则 |
| Alertmanager | Prometheus 的告警引擎，处理告警去重/分组/路由/静默，发飞书/PagerDuty 等 |
| Node Exporter | Prometheus 的宿主机指标采集器（CPU/内存/磁盘/网络），一行命令部署 |
| cAdvisor | Google 出的容器指标采集器，暴露每个容器的 CPU/内存/网络/磁盘 |
| Redpanda | Kafka API 兼容的消息队列，单二进制无 JVM 依赖，2 秒启动，适合单节点开发环境 |
| Apache Kafka | 分布式消息队列（Java/JVM），高吞吐/持久化/多消费者，但重量级 |
| Fluentd | Ruby 写的日志采集器，插件生态丰富（1000+），但内存较高（80-200MB） |
| Grafana Tempo | Grafana 出的分布式链路追踪后端，存 traces 用，适合大规模场景 |
| Jaeger | 链路追踪工具（已归档不再维护），Tempo 是它的替代品 |
| OTel Collector | OpenTelemetry 的采集器，接收 OTLP 格式的 traces/metrics/logs，转发到后端 |
| OTel SDK | OpenTelemetry 的语言级 SDK，在代码中埋点产生 spans，支持 Go/Python/Ruby 等 |
| cc-connect | 飞书/Lark 消息桥接程序（Go 写），连接飞书 WebSocket 到 Claude Code |
| sing-box | 通用代理工具（Go 写），kyb 用做 SOCKS5 代理，管理出站路由 |
| Trivy | 容器镜像漏洞扫描器（Aqua Security），离线可用，单二进制，5-15 秒扫一个镜像 |
| GITLAB_TOKEN | GitLab Personal Access Token，用于 API 认证，权限最小化原则 |
| Tailscale | 基于 WireGuard 的 Mesh VPN，跨集群容器通信用，零配置组网 |
| PromQL | Prometheus 的查询语言（类似 SQL 但针对时间序列），用来查指标和写告警规则 |
| Grafana Alloy River | Grafana Alloy 的配置语言，类似 HCL，用来定义采集/处理/输出管道 |
| Docker | 容器运行时，kyb 用做沙箱和基础设施服务的底层容器引擎 |
| Feishu/Lark | 飞书即时通讯平台，kyb 的告警通知和消息流转目的地 |
| Git | 分布式版本控制系统，所有配置和代码的单一事实来源 |

> /人◕ ‿‿ ◕人＼
