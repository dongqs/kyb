---
decision: 稍后做
---

# Observability Approaches: Cost-Benefit Analysis

> **Date:** 2026-05-23
> **Scope:** All proposed observability approaches across metrics, logs, traces, alerting, and provisioning.
> **Method:** Storage cost, compute cost, maintenance effort, and value gained are estimated per approach at current scale (~90 messages/day, 3 clusters). All costs are "bet" estimates -- actuals may vary 2x in either direction.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Approaches Analyzed](#2-approaches-analyzed)
3. [Cost Model](#3-cost-model)
4. [Approach A: Status Quo (Heartbeat Curl Loops + Ad-Hoc Scripts)](#4-approach-a-status-quo)
5. [Approach B: Vector Log Pipeline](#5-approach-b-vector-log-pipeline)
6. [Approach C: Prometheus + Exporters + Alertmanager](#6-approach-c-prometheus-stack)
7. [Approach D: Grafana Alloy Unified Collector](#7-approach-d-grafana-alloy)
8. [Approach E: OTel Traces via Tempo](#8-approach-e-otel-traces-via-tempo)
9. [Approach F: OTel Traces via Kafka + ClickHouse](#9-approach-f-otel-spans-via-kafka)
10. [Approach G: Grafana Provisioning as Code](#10-approach-g-grafana-provisioning-as-code)
11. [Approach H: Kafka Message Bus](#11-approach-h-kafka-message-bus)
12. [Cross-Cutting Concerns](#12-cross-cutting-concerns)
13. [Combined Recommendation Matrix](#13-combined-recommendation-matrix)
14. [Phased Rollout Plan](#14-phased-rollout-plan)
15. [Sensitivity Analysis](#15-sensitivity-analysis)

---

## 1. Executive Summary

The infra observability landscape has **six proposed approaches** spanning four telemetry types:

| Telemetry Type | Proposed Approaches |
|---|---|
| **Logs** | Vector pipeline (B), Grafana Alloy (D) |
| **Metrics** | Prometheus stack (C), Grafana Alloy (D) |
| **Traces** | OTel -> Tempo (E), OTel -> Kafka -> CK (F) |
| **Bus/Transport** | Kafka message bus (H) |
| **Configuration** | Grafana provisioning-as-code (G) |

Plus the **status quo** (A) as baseline.

### Key Findings

1. **The status quo is not free.** It incurs hidden maintenance costs: manual container inspection, no alerting, fragile curl loops, lost data on restart. Estimated "cost of doing nothing": ~2-4 hours/week of manual patrol + incident response delay.

2. **Vector (B) and Grafana Provisioning (G) have the best ROI.** They solve the biggest pain points (lost logs, no dashboards, no alerts) with minimal infrastructure. Combined: ~64 MB RAM, ~1 hour/week maintenance, immediate value.

3. **Prometheus stack (C) is high-value but high-cost for scale-1.** At ~1,200 time series, a full Prometheus + cadvisor + node_exporter + 5 service exporters deployment adds ~8 containers and ~700 MB RAM. On a single Mac/Orbstack host this is acceptable, but on resource-constrained Aliyun/Office it is wasteful without a matching problem.

4. **Alloy (D) is the best long-term architecture but premature today.** Replacing Vector (which works) and Prometheus (which is not deployed) with Alloy adds complexity without immediate benefit. The right time is when a second consolidation need arises (e.g., "we need traces on all three clusters").

5. **Traces (E, F) are over-engineered at current volume.** 540 spans/day at ~108 KB/day does not warrant Tempo (~256 MB RAM) or a Kafka topic + CK materialized view pipeline. Store traces as structured log lines in the existing log table until volume grows 100x.

6. **Kafka message bus (H) solves problems we don't have.** At ~90 messages/day and one log producer (Vector), there is no backpressure, no replay, no multi-producer problem. The operational cost of Kafka (one container, topic management, consumer lag monitoring) outweighs the benefit at this scale. Kafka is worth it when we have 5+ independent producers or need exactly-once semantics for billing-grade data.

### Priority Order

| Rank | Approach | ROI | When |
|------|----------|-----|------|
| 1 | G. Grafana Provisioning as Code | Highest (zero infra, immediate value) | Now |
| 2 | B. Vector Log Pipeline | High (solves data loss, minimal infra) | Now |
| 3 | C. Prometheus Stack | Medium-high (enables alerting) | Week 1-2 |
| 4 | A. Status Quo improvements | Medium (fix curl loop fragility) | Ongoing |
| 5 | D. Grafana Alloy | Low-Medium (future consolidation) | After B+C stable |
| 6 | H. Kafka Message Bus | Low (unnecessary abstraction) | Not until 5+ producers |
| 7 | E/F. Traces | Very low at current scale | Not until 100x volume |

---

## 2. Approaches Analyzed

| ID | Approach | Docs | Status |
|----|----------|------|--------|
| A | Status Quo: heartbeat curl loops + ad-hoc `docker logs` + manual Grafana | (current state) | Running |
| B | Vector container log pipeline: Docker socket -> Vector -> ClickHouse | `vector-pipeline.md` | Designed |
| C | Prometheus stack: Prometheus + cadvisor + node_exporter + Alertmanager + 5 service exporters | `prometheus-scrape.md` | Designed |
| D | Grafana Alloy unified collector: single daemon for metrics/logs/traces | `grafana-alloy.md` | Designed |
| E | OTel traces to Tempo: cc-connect OTel SDK -> Collector -> Tempo | `otel-cc-connect.md` | Designed |
| F | OTel traces via Kafka: OTel SDK -> Collector -> Kafka -> ClickHouse | `otel-kafka.md` | Designed |
| G | Grafana Provisioning as Code: datasource/dashboard/alert YAML in Git | `grafana-provisioning.md` | Designed |
| H | Kafka message bus: all events through shared topics | `kafka-message-bus.md` | Designed |

---

## 3. Cost Model

### 3.1 Units

| Cost Type | Unit | Notes |
|-----------|------|-------|
| Storage | GB/month | ClickHouse data, Prometheus TSDB, Tempo backend |
| Compute | MB RAM per container | Docker container memory (RSS) at idle |
| Compute | CPU cores (fractional) | Typical CPU usage at idle |
| Maintenance | hours/week | Human effort to operate, debug, update |
| Setup | hours one-time | First-time deployment and configuration |

### 3.2 Value Dimensions

| Value | Description |
|-------|-------------|
| Data retention | Can I query last week's data? |
| Alerting | Will I be notified when something breaks? |
| Debugging speed | How fast can I find the root cause? |
| Visibility | Can I see trends, correlations, patterns? |
| Reproducibility | Can I recreate the stack from scratch? |
| Multi-cluster | Does it work across all 3 clusters? |

### 3.3 Scale Context

All estimates at **current scale**:
- ~90 messages/day through cc-connect (bridge)
- ~3 clusters (Mac/Orbstack, Aliyun, Office)
- ~15 infra containers total
- ~5000 boss events/day
- ~540 spans/day (if traced)

Growth assumptions for sensitivity analysis (Section 15):
- **2x** within 6 months (more agents, more messages)
- **10x** within 12 months (production users, CI/CD)

---

## 4. Approach A: Status Quo

### What It Is

Current observability:
- Heartbeat curl loops from each boss to ClickHouse every 60s (3 clusters)
- cc-connect logs to stdout only (lost on container restart)
- Manually created Grafana data sources (lost on container rebuild)
- No dashboards, no alerts, no traces
- Patrol manual checks via `.kyb-diaries/` files

### Costs

| Cost Item | Value | Notes |
|-----------|-------|-------|
| **Storage** | ~5 MB/month | `boss_heartbeats` table only; tiny |
| **Compute** | 0 MB | Zero dedicated infra containers |
| **Setup effort** | 0h | Already running |
| **Maintenance** | 2-4 h/week | Manual patrol, container inspection, `docker logs --tail`, incident response |

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 2/5 | Heartbeats only. No message logs, no container metrics. |
| Alerting | 0/5 | None. Patrol is reactive, not alerting. |
| Debugging speed | 1/5 | `docker logs` if container still running. Data gone on restart. |
| Visibility | 1/5 | No dashboards, no trends, no cross-cluster view in one place. |
| Reproducibility | 0/5 | Manual setup, no version control. |
| Multi-cluster | 2/5 | Heartbeats from all 3 clusters. Nothing else. |

### Hidden Costs

- **Incident delay**: Without alerting, a crashed cc-connect is discovered at next patrol cycle (up to 5 min). Mean time to detection: ~2.5 min. Mean time to notification: manual.
- **Data loss**: Container restart destroys all logs. No way to investigate "what happened before the crash."
- **Knowledge loss**: No dashboards means tribal knowledge. Only the person who wrote the heartbeat script knows how to check health.

### Verdict

**Cost: 2-4 h/week maintenance + incident response friction.**
**Value: Minimal (heartbeat-only durability).**

The status quo is not "free." It costs time and risk. Every hour spent on observability approaches should be weighed against the status quo's 2-4 h/week hidden cost.

---

## 5. Approach B: Vector Log Pipeline

### What It Is

Deploy Vector container on each cluster. Vector reads container logs via Docker socket, parses structured logs (key=value, JSON), enriches with cluster metadata, and writes to ClickHouse tables (`cc.message_log`, `boss.agent_log`, `patrol.health_checks`, `mcp.request_log`).

### Costs

| Cost Item | Per Cluster | 3 Clusters | Notes |
|-----------|-------------|------------|-------|
| **RAM (Vector)** | 64 MB | 192 MB | Alpine-based, 64 MB idle, 128 MB peak |
| **CPU (Vector)** | 0.1 core | 0.3 core | Negligible at this log volume |
| **Disk (Vector buffer)** | 100 MB | 300 MB | Only fills when CK is down |
| **CK storage (logs)** | -- | ~200 MB/month | 90d retention, cc-connect + boss + patrol logs |
| **Vector image size** | ~50 MB | -- | Alpine, pulled once per cluster |
| **Setup effort** | 2h | 4h | First cluster: deploy, config, CK tables, labels. Remote: SSH dispatch. |
| **Maintenance** | 0.5 h/week | 1 h/week | Config updates, label management, incident debugging |

**Detailed CK storage breakdown (90d retention):**

| Table | Daily Volume | 90 Days | Notes |
|-------|-------------|---------|-------|
| `cc.message_log` | ~34 KB | ~3 MB | 90 messages/day, ~380 bytes/row |
| `boss.agent_log` | ~2 MB | ~180 MB | High-volume (Claude dialog), 7d TTL softens this |
| `patrol.health_checks` | ~50 KB | ~4.5 MB | 3 patrol instances, ~1 row/min each |
| `mcp.request_log` | -- | -- | Future, not yet applicable |
| **Total (90d)** | | **~190 MB** | Boss agent logs dominate; consider shortening TTL |

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 4/5 | All structured logs in CK with 90d TTL. No more data loss on restart. |
| Alerting | 1/5 | Data is there for alert queries, but no alerting pipeline. Requires Grafana alerting (G) or Prometheus (C). |
| Debugging speed | 4/5 | `SELECT * FROM cc.message_log WHERE msg_id = '...'` instead of guessing. |
| Visibility | 3/5 | Logs are queryable but no dashboards yet. Requires G. |
| Reproducibility | 3/5 | Container labels + Vector config in Git. Reproducible deploy. |
| Multi-cluster | 4/5 | Same Vector config per cluster, different `VECTOR_CLUSTER` env var. Central CK. |

### Interactions

- **Synergy with G**: Vector + Grafana provisioning = full log pipeline with dashboards. This combination covers 80% of debugging needs.
- **Synergy with C**: Vector logs + Prometheus metrics = both historical analysis (CK) and real-time alerting (Prometheus).
- **Redundancy with D**: Alloy can replace Vector in the future. Do not deploy Alloy now; let Vector prove itself first.

### Verdict

**Cost: ~64 MB RAM per cluster, ~200 MB CK storage, ~1 h/week maintenance.**
**Value: Solves data loss, enables log-based debugging, builds foundation for alerting.**

**ROI: High. The most impactful investment for the least infrastructure.** The Vector container is the only new piece; CK and Grafana already exist.

---

## 6. Approach C: Prometheus Stack

### What It Is

Deploy on Mac/Orbstack:
- **Prometheus** (1 container): scrape all targets, 30d retention, 10GB limit
- **Alertmanager** (1 container): route alerts to Feishu via webhook
- **cadvisor** (per cluster): Docker container resource metrics
- **node_exporter** (per host): OS-level metrics (CPU, mem, disk, net)
- **5 service exporters** (PG x4, Redis, Kafka, ClickHouse): database metrics
- **Boss exporter** (inside boss container): boss health metrics

On remote clusters (Aliyun, Office):
- **cadvisor** + **node_exporter** only (no Prometheus itself)

### Costs

| Cost Item | Mac/Orbstack | Per Remote Cluster | 3 Clusters Total |
|-----------|-------------|-------------------|-------------------|
| **RAM (Prometheus)** | 256 MB | -- | 256 MB |
| **RAM (Alertmanager)** | 64 MB | -- | 64 MB |
| **RAM (cadvisor)** | 100 MB | 100 MB | 300 MB |
| **RAM (node_exporter)** | 30 MB (brew) | 30 MB | 90 MB |
| **RAM (5 service exporters)** | 5 x 30 MB = 150 MB | -- | 150 MB |
| **RAM (Boss exporter)** | In-process | In-process | 0 (in boss container) |
| **Total RAM** | ~600 MB | ~130 MB | ~860 MB |
| **CPU (total)** | ~0.5-1.0 core | ~0.2 core | ~1.4 core |
| **Disk (Prometheus TSDB)** | 2-5 GB/30d | -- | 2-5 GB |
| **Disk (image pull)** | ~300 MB | ~200 MB | ~700 MB (one-time) |
| **Setup effort** | 4h | 1h per cluster | 6h total |
| **Maintenance** | 1 h/week | 0.5 h/week per cluster | 2 h/week |

**Time series detail:**

| Job | Series | Daily Samples (15s) | Monthly Samples |
|-----|--------|---------------------|-----------------|
| cc-connect | 30 | 172,800 | 5.2M |
| cadvisor | 200 | 576,000 (30s) | 17.3M |
| node_exporter | 500 | 1,440,000 (30s) | 43.2M |
| PG x4 | 200 | 576,000 (30s) | 17.3M |
| Redis | 50 | 144,000 (30s) | 4.3M |
| Kafka | 100 | 288,000 (30s) | 8.6M |
| ClickHouse | 80 | 230,400 (30s) | 6.9M |
| Boss | 20 | 57,600 (30s) | 1.7M |
| sing-box | 20 | 57,600 (30s) | 1.7M |
| **Total** | **~1,210** | **~3.5M/day** | **~106M/month** |

At 106M samples/month and ~1.5 bytes/sample (compressed), Prometheus TSDB storage is ~160 MB/month. With 30d retention: ~160 MB + WAL overhead = ~200-500 MB. The 10GB limit is very generous -- actual usage will be <1 GB.

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 3/5 | 30d only (Prometheus limit). Long-term in CK (heartbeats) is 90d+. |
| Alerting | 5/5 | Full PromQL-based alerting with Alertmanager -> Feishu. This is the only approach that provides real alerting. |
| Debugging speed | 3/5 | "Is container CPU pegged?" is instant. "What was the error 2 weeks ago?" requires CK logs. |
| Visibility | 4/5 | Real-time dashboards for everything: containers, hosts, databases. |
| Reproducibility | 3/5 | Config files in Git. Exporters need per-cluster deploy. |
| Multi-cluster | 4/5 | Single Prometheus scrapes all clusters via Tailscale. Central view. |

### Interactions

- **Redundancy with D**: Alloy includes Prometheus scraping. If Alloy is deployed later, Prometheus can be decommissioned. But Alloy is not ready today.
- **Synergy with B**: Prometheus (real-time) + Vector/CK (long-term) = complete coverage. The "hot/warm" architecture is standard practice.
- **Prerequisite for alerting**: Without Prometheus, there is no alert engine. Grafana's built-in alerting can work with CK, but it's less capable than PromQL.

### Verdict

**Cost: ~860 MB RAM, 2-5 GB disk, ~6h setup, ~2 h/week maintenance.**
**Value: Full real-time monitoring and alerting across all clusters and services.**

**ROI: Medium-high.** The cost is high (8+ containers, 860 MB RAM) but the value is unique -- no other approach provides alerting. The key question: **do we need alerting now?** If the answer is "yes" (we can't tolerate more than 2 min of cc-connect downtime), the Prometheus stack is justified. If "no" (manual patrol is acceptable), defer to Phase 2.

Consider a **minimal Prometheus** variant: Prometheus + Alertmanager + node_exporter only (drop cadvisor and service exporters initially). This reduces RAM to ~350 MB and provides host-level alerting (disk full, host down, high load). Container-level metrics can wait.

---

## 7. Approach D: Grafana Alloy Unified Collector

### What It Is

Replace Vector, Prometheus, and OTel Collector with a single Grafana Alloy container per cluster. Alloy handles:
- Prometheus scraping (discovery.docker -> prometheus.scrape -> prometheus.remote_write -> CK)
- Log collection (loki.source.docker -> loki.process -> CK)
- Trace collection (otelcol.receiver.otlp -> otelcol.exporter -> CK)
- Heartbeat replacement (Materialized View in CK from Prometheus metrics)

### Costs

| Cost Item | Per Cluster | 3 Clusters | Notes |
|-----------|-------------|------------|-------|
| **RAM (Alloy)** | 50 MB idle, 150 MB peak | 150-450 MB | Single daemon replaces Vector + Prometheus + OTel Collector |
| **CPU (Alloy)** | 0.1 core idle, 0.5 peak | 0.3-1.5 core | ~7,500 series scrape every 15s |
| **Disk (WAL)** | ~500 MB | 1.5 GB | Write-ahead log for CK outage buffering, in /tmp |
| **Image size** | ~50 MB | -- | Single binary |
| **Setup effort** | 4h | 8h | First cluster: River config, CK compat check, labeling. Remote: deploy. |
| **Maintenance** | 0.5 h/week | 1.5 h/week | River config is new to learn; fewer overall components to maintain |

### Comparison to Alternatives

| Dimension | Vector (B) + Prometheus (C) | Alloy (D) alone |
|-----------|---------------------------|-----------------|
| Containers | 9 (Vector + Prometheus + Alertmanager + cadvisor + 5 exporters) | 1 |
| Total RAM | ~920 MB | ~150 MB |
| Setup effort | ~6h | ~4h |
| Log pipeline | Yes (Vector) | Yes (Loki) |
| Metrics pipeline | Yes (Prometheus) | Yes (Prometheus receiver) |
| Traces pipeline | No (need E or F) | Yes (OTLP receiver) |
| Alerting | Yes (PromQL + Alertmanager) | Yes (via Grafana, less powerful) |
| Config format | TOML + YAML | River (new) |
| Heartbeat replacement | No (still uses curl) | Yes (via MV) |

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 4/5 | Everything to CK with 90d TTL. Prometheus separate (30d). |
| Alerting | 3/5 | Via Grafana, not PromQL. Less expressive for complex rules. Alloy self-monitoring is built-in. |
| Debugging speed | 4/5 | Unified logs + metrics + traces in one query. |
| Visibility | 5/5 | Complete: metrics, logs, traces, container discovery. |
| Reproducibility | 4/5 | Single River config per cluster. Dashboard JSON in Git. |
| Multi-cluster | 4/5 | Alloy per cluster, central CK. |

### Interactions

- **Direct replacement for B + C + (E or F)**: Alloy can absorb all three pipelines. But B and C are not deployed yet, so Alloy is replacing planning, not infrastructure.
- **CK Prometheus endpoint dependency**: Alloy requires ClickHouse to support `/prometheus/write`. If CK version doesn't support this, Alloy's metrics pipeline needs a Prometheus intermediary, negating the simplification benefit.
- **Vector already works**: If B is deployed first, migrating to Alloy is churn, not value.

### Verdict

**Cost: ~50-150 MB RAM per cluster, ~4h setup, ~1.5 h/week total maintenance.**
**Value: Unified pipeline with future-proof trace support.**

**ROI: Low-Medium today. High in 6 months.**

Alloy is architecturally superior -- one daemon instead of 9 containers. But deploying it now means:
1. Learning River (a new config language) for zero benefit over Vector + Prometheus.
2. Replacing systems that aren't deployed yet (Prometheus) or are just being deployed (Vector).
3. Taking a dependency on CK's Prometheus support (which may or may not work).

**Recommendation**: Deploy B and C first. When they are stable and the team is comfortable, evaluate Alloy as a Phase 3 consolidation. The migration path is clear (Alloy parallel-runs with Vector, then Vector is removed), so there is no lock-in risk.

---

## 8. Approach E: OTel Traces via Tempo

### What It Is

Instrument cc-connect (and later patrol) with OpenTelemetry Go SDK. Export spans via OTLP to an OTel Collector container, which forwards to Grafana Tempo for trace storage and query.

### Costs

| Cost Item | Value | Notes |
|-----------|-------|-------|
| **RAM (OTel Collector)** | ~64 MB | Lightweight gateway |
| **RAM (Tempo)** | ~256 MB | Trace storage backend |
| **Total RAM** | ~320 MB | Two new containers |
| **CPU** | <0.1 core | 540 spans/day is trivial |
| **Disk (Tempo backend)** | ~1 GB | 30d retention at current volume |
| **Setup effort** | 4h | OTel SDK instrumentation + Collector + Tempo + Grafana datasource |
| **Maintenance** | 0.5 h/week | Tempo upgrades, retention management |

**Detailed storage calculation:**

| Item | Value |
|------|-------|
| Spans/day | ~540 (90 messages x 6 spans) |
| Span size | ~200 bytes avg |
| Daily trace data | ~108 KB |
| Tempo retention (30d) | ~3.2 MB |
| Tempo backend overhead | ~100 MB (index, WAL, bloom filters -- fixed cost) |
| **Total Tempo storage (30d)** | **~100 MB** (overhead dominates) |

The overhead dominates because Tempo's backend (object store or filesystem) has fixed-cost structures (WAL, bloom filters) that don't shrink with data volume. Even at zero spans, Tempo uses ~100 MB.

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 3/5 | 30d in Tempo. Need CK for longer retention. |
| Alerting | 1/5 | Tempo doesn't alert. Metrics from OTel SDK go to Prometheus (needs C). |
| Debugging speed | 5/5 | This is the killer feature: "find the slow message, see every span, pinpoint the bottleneck." TraceQL search is powerful. |
| Visibility | 3/5 | Traces give depth ("why was this message slow?") but not breadth ("how many users are affected?"). Need metrics + logs for breadth. |
| Reproducibility | 3/5 | SDK instrumentation + Collector config in Git. Tempo is ephemeral (recreate from traces). |
| Multi-cluster | 1/5 | OTel Collector on Mac only (where cc-connect runs). Remote clusters have no traces. |

### Interactions

- **Requires OTel SDK changes**: cc-connect (Go) needs `go.opentelemetry.io/otel` dependencies and ~8 span creation points. This is a code change, not an infrastructure change.
- **Depends on C for metrics**: OTel SDK can also emit metrics (counters, histograms) to Prometheus via the Collector. Traces without metrics lose the alerting dimension. But metrics can also come from cc-connect's native Prometheus endpoint (C, Section 5).
- **Alternative to F**: E and F are mutually exclusive for trace storage. E (Tempo) is less complex but more storage. F (Kafka -> CK) is more complex but unified.

### Verdict

**Cost: ~320 MB RAM, ~100 MB disk, ~4h setup, ~0.5 h/week.**
**Value: End-to-end distributed tracing for message turn debugging.**

**ROI: Very low at current scale.** 540 spans/day does not justify 320 MB of dedicated trace infrastructure. The OTel SDK changes are valuable (they enable future tracing), but Tempo is overkill.

**Recommendation**: Implement the OTel SDK instrumentation in cc-connect (the code changes have standalone value: structured context propagation, latency measurement). But instead of exporting to Tempo, **write spans as structured log lines** to the existing `cc.message_log` table via the Vector pipeline (B). This gives trace-id-based correlation without any new infrastructure.

When span volume reaches >50K/day (roughly 100x current), revisit Tempo or Kafka+CK.

---

## 9. Approach F: OTel Spans via Kafka + ClickHouse

### What It Is

Same OTel SDK instrumentation as E, but instead of Tempo, route spans through Kafka topic `otel.spans`, consumed by ClickHouse Kafka Engine into `otel.span_log` MergeTree table. Query traces via Grafana's ClickHouse datasource (waterfall view).

### Costs

| Cost Item | Value | Notes |
|-----------|-------|-------|
| **RAM (OTel Collector)** | ~64 MB | Same as E |
| **RAM (Kafka)** | Already deployed | Kafka infra already exists for `cc.events` topic (see H) |
| **RAM (additional)** | 0 | No new storage backend. CK already deployed. |
| **Total RAM (new)** | ~64 MB | Only OTel Collector is new |
| **Setup effort** | 5h | OTel SDK + Collector Kafka exporter + `otel.spans` topic + CK Kafka Engine + MV + Grafana trace view config |
| **Maintenance** | 0.5 h/week | Plus Kafka consumer lag monitoring |

**CK storage (30d retention):**

| Table | Size | Notes |
|-------|------|-------|
| `otel.span_log` | ~15 MB | 540 spans/day x 800 bytes x 30d. Even with extracted columns overhead: ~15 MB. |

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 4/5 | 30d in CK, same retention as logs. Single retention policy. |
| Alerting | 1/5 | Same as E -- traces don't alert by themselves. Requires metrics (C). |
| Debugging speed | 4/5 | Trace waterfall in Grafana via ClickHouse plugin. Less polished than Tempo but functional at this volume. |
| Visibility | 4/5 | Unified with logs. Single query joins spans to log events. No Tempo-CK bridge needed. |
| Reproducibility | 4/5 | CK schema + MV are version-controlled. Kafka topic is idempotent. |
| Multi-cluster | 2/5 | All traces land in central CK. |

### Comparison: Tempo (E) vs Kafka+CK (F)

| Dimension | Tempo (E) | Kafka+CK (F) |
|-----------|-----------|--------------|
| New containers | 2 (Tempo + Collector) | 1 (Collector only) |
| New RAM | 320 MB | 64 MB |
| New storage backend | Tempo (100 MB overhead) | None (reuses CK) |
| Query experience | Excellent (TraceQL, waterfall) | Good (SQL + Grafana waterfall plugin) |
| Setup complexity | Low (standard OTel) | Medium (Kafka topic + CK MV + attribute extraction) |
| Trace-to-logs correlation | Medium (Tempo-CK bridge) | Native (same DB, same SQL) |
| Replay | None | Yes (Kafka 3d retention) |
| Scale ceiling | Very high | Medium (>1M spans/day degrades) |

### Verdict

**Cost: ~64 MB RAM, ~15 MB CK storage, ~5h setup.**
**Value: Unified traces + logs in CK, no new storage backend, replay capability.**

**ROI: Very low at current scale (same as E).** The infrastructure cost is lower than E (64 MB vs 320 MB), but the setup complexity is higher. The key advantage over E -- unified query -- is not valuable at 540 spans/day because you can just grep the logs.

Same recommendation as E: **instrument the code, store spans as log lines, revisit when volume grows.**

---

## 10. Approach G: Grafana Provisioning as Code

### What It Is

Move Grafana datasource, dashboard, alert rule, and notifier configuration from manual container-sidecar state to version-controlled YAML/JSON files in `docs/infra/grafana/`. Deploy via `deploy.sh` (docker cp + API reload) or bind-mount on container restart.

### Costs

| Cost Item | Value | Notes |
|-----------|-------|-------|
| **RAM** | 0 | No new containers. Grafana already runs. |
| **Disk** | <150 KB | YAML/JSON files in Git repository. Negligible. |
| **Setup effort** | 2h | Create directory structure, datasource YAML, deploy.sh, first dashboard. |
| **Maintenance** | 0.5 h/week | Adding/modifying dashboards, updating alert rules, reviewing diffs. |
| **Git storage** | ~150 KB | 15-20 files. Diff-friendly. Permanent. |

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 0/5 | Doesn't add data. All data sources are existing. |
| Alerting | 3/5 | Enables Grafana alerting rules from CK data. Less powerful than PromQL but functional for heartbeat monitoring. |
| Debugging speed | 3/5 | Dashboards replace handwritten SQL. "Boss Overview" shows all 3 clusters in one view. |
| Visibility | 4/5 | Dashboards for everything: boss health, container counts, disk usage. Customizable. |
| Reproducibility | 5/5 | `git clone && ./deploy.sh` = complete Grafana provisioning. Zero manual steps. |
| Multi-cluster | 3/5 | Dashboards query central CK. All 3 clusters visible. |

### Specific Value Calculations

**Without provisioning (current state):**
- Grafana container rebuilt -> all data sources lost -> recreate manually
- Adding a panel -> open UI, build SQL, no version history
- Adding an alert -> UI, no code review, no audit trail
- Change tracking -> impossible

**With provisioning:**
- `git diff` shows every dashboard change
- `deploy.sh` runs in 5 seconds
- Alert rules are peer-reviewed before deployment
- Disaster recovery: `docker run -v $(pwd)/provisioning:/etc/grafana/provisioning grafana/grafana:latest`

### Interactions

- **Force multiplier for B, C, D, E, F**: All approaches benefit from dashboards and alerting. G is the delivery mechanism for the visualization layer.
- **Prerequisite for any alerting**: Without G, alert rules cannot be version-controlled. Manual alert config is acceptable for experimentation but dangerous for production.
- **Independent of telemetry approach**: G works with CK data sources (Vector/B inputs), Prometheus data sources (C inputs), or Tempo data sources (E inputs).

### Verdict

**Cost: 0 MB RAM, <150 KB Git storage, ~2h setup, ~0.5 h/week maintenance.**
**Value: Complete reproducibility, version-controlled dashboards and alerts, audit trail.**

**ROI: Highest of all approaches. Zero infrastructure cost, immediate value, enables all downstream visualization. Do this first, before any new telemetry pipeline.**

---

## 11. Approach H: Kafka Message Bus

### What It Is

Deploy Kafka as a central event bus. Producers (cc-connect, patrol, future services) write events to Kafka topics. Consumers (ClickHouse via Kafka Engine, Vector, future consumers) read independently. Provides replay, backpressure isolation, and unified schema.

### Costs

| Cost Item | Value | Notes |
|-----------|-------|-------|
| **RAM (Kafka)** | ~512 MB | Single broker, 1 topic, ~1 partition. Kafka is JVM-based. |
| **CPU (Kafka)** | 0.2-0.5 core | At this volume, mostly idle. |
| **Disk (Kafka logs)** | ~5 GB | 7d retention. At ~400 KB/day, this is 99.9% overhead for the fixed cost of Kafka's segment files. |
| **Setup effort** | 3h | Kafka container, topic creation, CK Kafka Engine, integration testing. |
| **Maintenance** | 1 h/week | Kafka is operationally heavy: JMX monitoring, consumer lag, rebalancing, log compaction, disk management. |
| **Total RAM (with current pipeline)** | ~512 MB | Adds 512 MB on top of Vector's 64 MB. |

**At current scale, Kafka's cost breakdown is absurd:**

```
Data volume:          400 KB/day
Kafka overhead:       5 GB disk (99.9% unused)
Kafka RAM:            512 MB (to process 400 KB/day)
Cost per KB of useful data:  1.3 MB RAM / KB throughput
```

### Value

| Value Dimension | Score | Rationale |
|-----------------|-------|-----------|
| Data retention | 3/5 | 7d in Kafka for replay. But CK has 90d. Replay from Kafka is rarely needed. |
| Alerting | 0/5 | Kafka doesn't alert. It's transport. |
| Debugging speed | 2/5 | Kafka tooling (rpk, kcat) adds debugging surface. One more thing to troubleshoot. |
| Visibility | 1/5 | Kafka consumer lag is another metric to monitor. Doesn't help with application visibility. |
| Reproducibility | 2/5 | Kafka is stateful. Recreating from scratch requires replaying from producers. |
| Multi-cluster | 2/5 | Single Kafka on Mac. Remote clusters would need remote producers, adding latency and failure modes. |

### Problems Kafka Solves (And Whether We Have Them)

| Problem | Kafka solves | Do we have this? |
|---------|-------------|------------------|
| Multiple producers with different formats | Unified schema envelope | One producer (Vector). One format (Docker logs). |
| Backpressure from slow consumers | Kafka buffers, producers unaffected | Vector's memory buffer handles 10K events. CK is fast enough. |
| Replay after schema change | Kafka retains old messages | No schema changes at this scale. CK has 90d retention. |
| Exactly-once semantics | Kafka transactions + idempotent writes | Not needed for observability data (at-most-once is acceptable). |
| Multiple consumer groups | Independent read offsets | One consumer (CK Kafka Engine). No other consumers planned. |
| Cross-event correlation | Shared schema, same topic | 400 KB/day. A SQL JOIN in CK is faster and simpler. |

### Interactions

- **Redundancy with Vector**: Vector already buffers and writes to CK. Adding Kafka between them is an unnecessary hop.
- **Prerequisite for F**: OTel traces via Kafka (F) depends on Kafka. But F is not recommended at current scale.
- **Complexity multiplication**: Kafka + Vector + CK + Grafana = 4 systems to debug when a message is missing. Without Kafka: Vector -> CK -> Grafana (3 systems, simpler chain).

### Verdict

**Cost: ~512 MB RAM, ~5 GB disk, ~3h setup, ~1 h/week maintenance.**
**Value: Decouples producers from consumers with replay capability.**

**ROI: Very low at current scale.** Kafka solves enterprise-scale problems (multiple producers, high throughput, exactly-once semantics, multiple consumer groups). We have one producer (Vector), 400 KB/day, and one consumer (CK). The operational overhead of Kafka far exceeds its value.

**Recommendation**: Do not deploy Kafka now. If the infra grows to:
- 5+ independent log producers
- 10+ GB/day log volume
- Consumer lag becoming a problem
- Multiple independent consumers of the same event stream

Then Kafka becomes worthwhile. At current scale, it is unnecessary complexity.

If Kafka is already deployed for _other_ reasons (not observability), then using the existing Kafka for observability events has marginal cost and should be done. But deploying Kafka _for_ observability is not justified.

---

## 12. Cross-Cutting Concerns

### 12.1 Container Count

```
A (Status Quo):        0 containers for observability
B (Vector):            1 container  (Vector)                                = 1 total
C (Prometheus):        8 containers (Prom, Alertmgr, cadvisor, node_exp, 5 exporters) = 8 total
D (Alloy):             1 container  (Alloy)                                = 1 total
E (Tempo traces):      2 containers (OTel Collector, Tempo)                = 2 total
F (Kafka traces):      1 container  (OTel Collector)                       = 1 total
G (Grafana prov.):     0 containers (config only)                          = 0 total
H (Kafka bus):         1 container  (Kafka)                                = 1 total

B + C (recommended):   9 containers
D alone (future):      1 container
```

Every container adds:
- ~30-60 seconds to `docker ps` output scanning
- A potential failure domain
- Background noise in Grafana (another target to monitor)
- Resource overhead (even at 0% utilization, Docker's container runtime overhead is ~2-5 MB per container)

### 12.2 Team Learning Curve

| Approach | New Config Language | Existing Skills Apply |
|----------|-------------------|----------------------|
| B (Vector) | TOML + VRL | Docker, ClickHouse, Grafana |
| C (Prometheus) | PromQL, YAML | Docker, Grafana |
| D (Alloy) | River | All of B + C concepts |
| E (Tempo) | OTel Collector YAML | Grafana |
| F (Kafka+CK) | OTel Collector YAML + SQL | ClickHouse, Grafana |
| G (Provisioning) | YAML, JSON | Grafana, Git |
| H (Kafka) | Topic management, `rpk` | None transferable |

River (D) is the steepest new learning curve at ~1 hour. But the opportunity cost is higher: learning River to replace Vector (which already works) is not productive.

### 12.3 Risk of Doing Nothing

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| cc-connect crash, logs lost | High (happens) | Medium (lose debugging data) | G (dashboards) enables faster detection |
| Disk full, no alerting | Medium | High (service degradation) | C enables alerting |
| Boss rebuild, Grafana config lost | Low (rare) | Medium (recreate manually) | G prevents this entirely |
| Can't debug slow message | High (happens weekly) | Low-Medium (annoying, not critical) | B (logs in CK) solves this |
| Remote cluster goes offline, unknown for hours | Medium | Medium (cluster waste) | C + G enables cross-cluster view |

### 12.4 Vendor Lock-in

None of these approaches create significant lock-in:
- **Vector**: Open source, CNCF, TOML config. Easy to replace.
- **Prometheus**: CNCF standard. Ubiquitous.
- **Alloy**: AGPL licensed (free for internal use). Grafana-specific but uses standard OTLP.
- **ClickHouse**: Open source, Apache 2.0. Standard SQL.
- **Kafka**: Open source, Apache 2.0. Standard protocol.
- **Grafana**: Open source, AGPLv3. Dashboards can be exported.

The most portable approach: **Logs to CK + Prometheus metrics**. Both are industry standards with many alternatives at every layer.

---

## 13. Combined Recommendation Matrix

### 13.1 Priority by Approach

| Rank | Approach | Total Cost | Total Value | ROI | When |
|------|----------|-----------|-------------|-----|------|
| 1 | **G. Grafana Provisioning** | ~2h setup, 0 MB RAM | Reproducibility, dashboards, alerts | ★★★★★ | **Now** |
| 2 | **B. Vector Pipeline** | ~4h setup, 64 MB RAM/cluster | Log retention, ~1h/week savings | ★★★★☆ | **Now** |
| 3 | **C. Prometheus Stack** | ~6h setup, ~860 MB RAM, 2h/week | Alerting, real-time metrics, cross-cluster | ★★★☆☆ | **Week 1-2** |
| 4 | **A. Status Quo Fixes** | ~1h, curl loop improvements | Reduce fragility | ★★★☆☆ | **Ongoing** |
| 5 | **D. Alloy Consolidation** | ~4h, ~150 MB RAM | Unified pipeline, future-proof | ★★☆☆☆ | **Month 2+** |
| 6 | **OTel SDK (code only)** | ~2h dev, 0 MB infra | Structured spans, future-ready | ★★☆☆☆ | **When modifying cc-connect** |
| 7 | **H. Kafka Bus** | ~3h, 512 MB RAM | Decoupling, replay | ★☆☆☆☆ | **Not now** |
| 8 | **E/F. Trace Backend** | ~4h, 64-320 MB RAM | Trace waterfall | ★☆☆☆☆ | **100x volume** |

### 13.2 Phased Roadmap

```
Now (Day 0):
  G. Grafana Provisioning     [~2h]  - datasource YAML, deploy.sh, first dashboard
  B. Vector Pipeline           [~4h]  - deploy Vector, create CK tables, label containers

Week 1-2:
  C. Prometheus (minimal)     [~4h]  - Prometheus + Alertmanager + node_exporter only
  G. Dashboards               [~2h]  - Boss Overview, Cluster Health, Heartbeat Monitor
  G. Alert rules              [~1h]  - heartbeat alerts via Grafana (from CK data)

Week 3-4:
  C. Full stack               [~4h]  - cadvisor, service exporters, full dashboard suite
  B. Remote clusters          [~2h]  - Vector on Aliyun + Office
  B. Remote patrol            [~1h]  - patrol structured logging via Vector

Month 2+:
  OTel SDK in cc-connect      [~2h]  - code instrumentation, store as log lines
  Evaluate Alloy if:
    - Vector + Prometheus is stable (3+ weeks without incident)
    - Need traces on all 3 clusters
    - CK supports /prometheus/write natively
  If all three: deploy Alloy, gradually decommission Vector + Prometheus
```

### 13.3 What We Actually Get

After G + B + C (the first 3 weeks):

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

### 13.4 What We Defer (And Why)

| Capability | Deferred | Reason |
|-----------|----------|--------|
| Distributed traces (Tempo) | Until 50K+ spans/day | 540 spans/day doesn't justify infrastructure |
| Unified collector (Alloy) | Until Vector + Prometheus stable | Premature consolidation is churn |
| Kafka message bus | Until 5+ producers or 10+ GB/day | Over-engineered for single-producer 400 KB/day |
| Service exporters (PG, Redis, etc.) | Week 3+ | node_exporter first, then databases. DB metrics are nice-to-have, not P0. |
| Trace-to-logs correlation | Until traces exist | No traces = no correlation problem |

---

## 14. Phased Rollout Plan

### Phase 1 (Day 0-1): Foundation

**G. Grafana Provisioning + B. Vector Pipeline**

```
Budget: 6h total
New containers: 1 (Vector)
New RAM: 64 MB
New disk: 200 MB (CK logs + Vector buffer)
```

**Step-by-step:**

1. Create `docs/infra/grafana/` with datasource YAMLs
2. Write `deploy.sh` and execute
3. Deploy Vector container on Mac/Orbstack
4. Create CK tables: `cc.message_log`, `boss.agent_log`, `patrol.health_checks`
5. Label existing containers with `kyb.logs=true`, `kyb.service=*`
6. Write first dashboard: "Boss Overview" (from CK heartbeats)
7. Write first dashboard: "Container Log Explorer" (from CK message_log)
8. Verify end-to-end: log line from cc-connect -> Vector -> CK -> Grafana panel

**Exit criteria:**
- [ ] `deploy.sh` reproduces Grafana configuration from scratch
- [ ] Vector is running and forwarding logs
- [ ] Boss Overview dashboard shows heartbeats from all 3 clusters
- [ ] Message log queries return within 1 second

---

### Phase 2 (Week 1-2): Alerting

**C. Prometheus (Minimal) + G. Alert Rules**

```
Budget: 7h total
New containers: 4 (Prometheus, Alertmanager, node_exporter x2 remote)
New RAM: 350 MB
New disk: 500 MB (Prometheus TSDB)
```

**Step-by-step:**

1. Deploy node_exporter on Mac (brew) + Aliyun + Office (Docker)
2. Deploy Prometheus + Alertmanager on Mac/Orbstack
3. Configure Prometheus to scrape node_exporter targets (all 3 clusters)
4. Write alerting rules: host down, disk >85%, disk >90%
5. Configure Alertmanager webhook to Feishu (via cc-connect)
6. Test each alert level by simulating failures
7. Write Grafana alert rules (from CK) for boss heartbeat
8. Write "Cluster Health" dashboard (Prometheus datasource)

**Exit criteria:**
- [ ] All alert rules fire and reach Feishu within 1 minute of condition trigger
- [ ] Boss heartbeat alert: stop boss for 2 min -> Feishu notification
- [ ] Disk alert: fill disk to 86% -> Feishu notification (or mock threshold)
- [ ] Cluster Health dashboard shows CPU/mem/disk per cluster
- [ ] Rollback plan works: stop Prometheus, everything else continues

---

### Phase 3 (Week 3-4): Depth

**C. Full Stack + B. Remote Clusters + Patrol**

```
Budget: 7h total
New containers: 6 (cadvisor x3, PG x4 exporters, Redis, Kafka, CK exporters on Mac)
New RAM: ~600 MB (full stack)
New disk: ~2 GB (Prometheus TSDB + cadvisor overhead)
```

**Step-by-step:**

1. Deploy cadvisor on all 3 clusters
2. Deploy service exporters (PG, Redis, Kafka, CK) on Mac
3. Add scrape configs and alert rules for database health
4. Write full dashboards: "Infrastructure Overview", "Service Health"
5. Deploy Vector on remote clusters (Aliyun, Office)
6. Add patrol structured logging output
7. Write Grafana alert rules for cc-connect message lag (no messages in 2 min = alert)

**Exit criteria:**
- [ ] All 3 clusters have Vector forwarding logs to central CK
- [ ] Database health monitoring (PG up/down, Redis latency)
- [ ] Patrol health checks visible in Grafana panel
- [ ] Full dashboard suite deployed and viewed at least once per day
- [ ] Alert fatigue baseline measured (how many alerts per day? Tune thresholds)

---

### Phase 4 (Month 2+): Consolidation

**D. Alloy Evaluation + OTel SDK**

```
Budget: 6h total
New containers: 0-1 (Alloy, if Vector decommissioned)
```

**Step-by-step:**

1. Instrument cc-connect with OTel SDK (2h dev work)
   - Store spans as structured log lines via existing Vector pipeline
   - Add `trace_id` field to `cc.message_log` table
   - No new infrastructure
2. Evaluate Alloy:
   - Check CK version support for `/prometheus/write`
   - Run Alloy in parallel with Vector for 1 week
   - Compare: resource usage, config maintainability, feature parity
3. Decision gate: keep Vector + Prometheus, or consolidate to Alloy
4. If consolidating: migrate Vector configs to Alloy River, decommission Vector

---

## 15. Sensitivity Analysis

### 15.1 What If Volume Grows 10x?

At 10x current volume (~900 messages/day, ~15 GB/day logs, ~5,400 spans/day):

| Approach | Cost at 1x | Cost at 10x | Impact |
|----------|-----------|-------------|--------|
| B (Vector) | 64 MB RAM, 200 MB CK | 128 MB RAM, 2 GB CK | Vector scales linearly. CK storage increases. No issue. |
| C (Prometheus) | ~1.2K series, 500 MB TSDB | ~12K series, 5 GB TSDB | Prometheus handles 12K series easily. Still <10GB limit. |
| D (Alloy) | 50 MB RAM | 200 MB RAM | Alloy scales well. More WAL. |
| E (Tempo) | 100 MB overhead, 3 MB data | 100 MB overhead, 30 MB data | Tempo overhead still dominates. Still wasteful. |
| F (Kafka+CK) | 64 MB RAM, 15 MB CK | 128 MB RAM, 150 MB CK | CK handles this trivially. Kafka still unnecessary. |
| H (Kafka) | 512 MB RAM, 400 KB/day data | 512 MB RAM, 4 MB/day data | Kafka costs don't change with volume. Still wasteful. |

**Conclusion**: At 10x, the recommendations don't change. Kafka is still overkill. Traces still don't justify Tempo.

### 15.2 What If Volume Grows 100x?

At 100x (~9,000 messages/day, ~54,000 spans/day):

| Approach | Cost at 100x | Verdict |
|----------|-------------|---------|
| B (Vector) | 512 MB RAM, 20 GB CK | Vector needs disk buffer. CK fine. |
| C (Prometheus) | 120K series, 50 GB TSDB | Need a bigger disk or shorter retention. Still viable. |
| D (Alloy) | 500 MB RAM, 5 GB WAL | Alloy heavy but single daemon manageable. |
| E (Tempo) | 100 MB overhead, 300 MB data | Tempo becomes sensible. 300 MB data vs 100 MB overhead -- 3:1 ratio. |
| F (Kafka+CK) | 256 MB RAM, 1.5 GB CK | CK still fine. Kafka consumer lag might appear. |
| H (Kafka) | 512 MB RAM, 400 MB/day data | Kafka starts to make sense at this volume. |

**Breakpoints:**

| Decision | Breakpoint | Trigger |
|----------|-----------|---------|
| Deploy Kafka bus | 5+ independent producers or 10+ GB/day | Infrastructure complexity justified |
| Deploy Tempo | 50K+ spans/day | Data volume > Tempo's fixed overhead |
| Deploy Alloy | Prometheus retention becomes painful | Re-evaluate when Prometheus TSDB >5GB |
| Deploy traces | 5K+ spans/day and latency >30s is a "fire" | When debugging slowness becomes a regular pain point |

### 15.3 What If We Lose a Cluster?

The architecture is resilient by design:
- **Mac/Orbstack goes down**: Remote clusters lose central CK + Grafana. Vector buffers locally. No data loss. When Mac recovers, Vector replays.
- **Remote cluster goes down**: Mac still has its data. Remote cluster logs are lost (Vector buffer is on the cluster). Acceptable.
- **Grafana goes down**: Data keeps flowing to CK. Grafana rebuild is <5 min with provisioning (G).

### 15.4 What If We Add a 4th Cluster?

- **Vector**: Deploy with same config, different `VECTOR_CLUSTER` env var. ~10 minutes.
- **node_exporter**: Add to Prometheus scrape config. ~5 minutes.
- **cadvisor**: Deploy with same commands. ~5 minutes.
- **Grafana**: Already queries central CK. Zero changes.

---

## Appendix: Cost Summary Table

| Approach | New Containers | New RAM | New Disk | Setup Effort | Maintenance | Value Areas | Net ROI |
|----------|---------------|---------|----------|-------------|-------------|-------------|---------|
| A. Status Quo | 0 | 0 | 0 | 0h | 2-4 h/week | Minimal | Negative (hidden costs) |
| B. Vector | 1 (per cluster) | 64 MB | 200 MB CK | 4h | 1 h/week | Log retention, debugging | **High** |
| C. Prometheus (full) | 8 | 860 MB | 2-5 GB | 6h | 2 h/week | Alerting, metrics, dashboards | Medium-high |
| C. Prometheus (minimal) | 3 | 350 MB | 500 MB | 4h | 1 h/week | Host alerting, some metrics | Medium |
| D. Alloy | 1 | 150 MB | 1.5 GB WAL | 4h | 1.5 h/week | Unified pipeline, future-proof | Low-Medium |
| E. Tempo traces | 2 | 320 MB | 100 MB | 4h | 0.5 h/week | Trace debugging | Very low |
| F. Kafka+CK traces | 1 | 64 MB | 15 MB CK | 5h | 0.5 h/week | Unified trace+log | Very low |
| **G. Provisioning** | **0** | **0** | **<150 KB** | **2h** | **0.5 h/week** | **Reproducibility, alerts, dashboards** | **Highest** |
| H. Kafka bus | 1 | 512 MB | 5 GB | 3h | 1 h/week | Decoupling, replay | Very low |

---

> **Summary**: Implement Grafana Provisioning as Code (G) and Vector log pipeline (B) immediately. These two approaches cost ~64 MB RAM and ~6h setup, and solve the biggest problems: lost logs, no dashboards, no alerting, no reproducibility. Add a minimal Prometheus stack (C) in week 1-2 for host-level alerting. Defer traces (E/F) and Kafka (H) until volume grows 100x. Evaluate Alloy (D) as a future consolidation when Vector + Prometheus are stable.

> ／人◕ ‿‿ ◕人＼
