---
decision: 稍后做
---

# Dashboard of Dashboards — Infra Meta-Dashboard Design

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Single-pane-of-glass overview showing health of all infrastructure subsystems, with drill-down links to existing Grafana panels, review docs, and runbooks. The "landing page" for infra operations.

---

## Table of Contents

1. [Why a Meta-Dashboard](#1-why-a-meta-dashboard)
2. [Layout Philosophy](#2-layout-philosophy)
3. [The Meta-Dashboard Panel](#3-the-meta-dashboard-panel)
4. [Subsystem Registration](#4-subsystem-registration)
5. [Drill-Down Index](#5-drill-down-index)
6. [Alerting Integration](#6-alerting-integration)
7. [Implementation Plan](#7-implementation-plan)
8. [Operational Runbook](#8-operational-runbook)

---

## 1. Why a Meta-Dashboard

### 1.1 The Problem

We have **48 review documents**, **6 design documents**, **3 clusters**, **16+ managed services**, and **4+ observability pipelines**. When something goes wrong, the operator needs to answer:

1. **What is the scope?** — Is this a single-container issue, a cluster issue, or a global issue?
2. **Which subsystem?** — Is it cc-connect, ClickHouse, Grafana, or the network?
3. **Where do I look?** — Which Grafana panel, which review doc, which runbook?

Without a meta-dashboard, the operator spends minutes navigating between tools while an incident burns.

### 1.2 The Solution

A single Grafana panel (or static HTML page, or TUI) that aggregates:

- **Cluster health** — heartbeat status per boss
- **Service health** — up/down per managed service, grouped by cluster
- **Observability pipeline health** — OTel, Vector, Prometheus, ClickHouse ingestion
- **Error budget remaining** — per SLO tier, per service
- **Active alerts** — hook-triggered, patrol-detected, burn-rate
- **Drill-down links** — one click to the right Grafana panel, review doc, or SSH command

### 1.3 Design Goals

| Goal | Priority | How |
|------|----------|-----|
| **Single glance** | P0 | Health summaries all visible above the fold |
| **One-click drill-down** | P0 | Every widget links to its detailed view |
| **Cluster-aware** | P0 | Show mac-orbstack, aliyun, office side by side |
| **10-second triage** | P1 | Red/yellow/green at a glance, know where to click |
| **Self-documenting** | P1 | Each health widget links to the relevant design/review doc |
| **Extensible** | P1 | Register a new subsystem without editing the meta-dashboard layout |
| **Works offline** | P2 | Static snapshot works without Grafana (for SSH-only scenarios) |

---

## 2. Layout Philosophy

### 2.1 Information Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│  [P0] CLUSTER STATUS ROW  (3 columns, one per cluster)     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                    │
│  │ Mac/     │ │ Aliyun   │ │ Office   │                    │
│  │ Orbstack │ │ (sim)    │ │ (nuc8)   │                    │
│  └──────────┘ └──────────┘ └──────────┘                    │
├─────────────────────────────────────────────────────────────┤
│  [P1] SERVICE HEALTH GRID  (rows = services, cols = cls)   │
│  ┌─────────┬──────┬──────┬──────┐                          │
│  │ Service │ Mac  │ Ali  │ Off  │                          │
│  ├─────────┼──────┼──────┼──────┤                          │
│  │cc-conn..│  🟢  │  -   │  -   │                          │
│  │PG-16    │  🟢  │  -   │  -   │                          │
│  │CK       │  🟢  │  -   │  -   │                          │
│  │...      │      │      │      │                          │
│  └─────────┴──────┴──────┴──────┘                          │
├─────────────────────────────────────────────────────────────┤
│  [P1] OBSERVABILITY PIPELINE STATUS                         │
│  ┌────────────┬──────────┬──────────┬──────────┐           │
│  │ Pipeline   │ Status   │ Latency  │ Throughput│          │
│  ├────────────┼──────────┼──────────┼──────────┤           │
│  │ OTel spans │ 🟢 0 err │  <100ms  │ 12/s     │           │
│  │ Vector logs│ 🟢 0 err │  <1s     │ 50/s     │           │
│  │ Heartbeats │ 🟢 3/3   │  60s     │ 3/min    │           │
│  └────────────┴──────────┴──────────┴──────────┘           │
├─────────────────────────────────────────────────────────────┤
│  [P2] ERROR BUDGET REMAINING  /  ACTIVE ALERTS             │
│  ┌──────┬──────┬──────┐  ┌─────────────────────────────┐   │
│  │Tier-0│Tier-1│Tier-2│  │ 🔴 P1: CK disk >80%        │   │
│  │ 98%  │ 85%  │ 72%  │  │ 🟡 P2: PG-14 lag >500ms   │   │
│  └──────┴──────┴──────┘  └─────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│  [P3] TRENDS  /  QUICK LINKS                               │
│  ┌──────────┐ ┌──────────────────────────────────────┐     │
│  │ 24h      │ │ 🔗 Review docs  🔗 Runbooks  🔗 SSH  │     │
│  │ timeline │ │ 🔗 Patrol log  🔗 Feishu alerts      │     │
│  └──────────┘ └──────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Reading Order

1. **Top row: cluster health** — if any cluster is red, investigate there first
2. **Service grid** — which specific service is failing within that cluster
3. **Pipeline status** — is the observability stack itself healthy (trust the data)?
4. **Error budget + alerts** — is this a known ongoing issue or new?
5. **Trends + links** — navigate to detailed investigation

### 2.3 Color Semantics

| Color | Meaning | Action |
|-------|---------|--------|
| 🟢 Green | All OK | No action needed |
| 🟡 Yellow | Degraded (1+ warning) | Look during office hours |
| 🔴 Red | Down / Critical (1+ down) | Investigate now |
| ⚪ Gray | Not deployed in this cluster | N/A |
| 🔵 Blue | Maintenance mode | Acknowledged, ignore |

---

## 3. The Meta-Dashboard Panel

This section defines the Grafana panel JSON model for the meta-dashboard. It is implemented as a **single dashboard** in Grafana with multiple rows, each row being a different panel type.

### 3.1 Cluster Status Row (Repeat for Each Cluster)

**Panel type:** Stat (single stat with background coloring) or custom HTML

**Data source:** ClickHouse — `boss_heartbeats` table

**Query (per cluster):**

```sql
SELECT
  cluster,
  count(*)                                           AS beats_24h,
  countIf(timestamp > now() - INTERVAL 5 MINUTE)     AS beats_5m,
  max(timestamp)                                     AS last_beat,
  argMax(docker_running, timestamp)                  AS current_running,
  argMax(disk_used_pct, timestamp)                   AS disk_pct,
  argMax(agent_alive, timestamp)                     AS alive,
  CASE
    WHEN max(timestamp) < now() - INTERVAL 5 MINUTE THEN '🔴 DEAD'
    WHEN argMax(disk_used_pct, timestamp) > 85       THEN '🟡 FULL'
    WHEN argMax(agent_alive, timestamp) = 0          THEN '🔴 DOWN'
    ELSE '🟢 OK'
  END AS status
FROM boss_heartbeats
WHERE cluster IN ('mac-orbstack', 'aliyun', 'office')
  AND timestamp > now() - INTERVAL 24 HOUR
GROUP BY cluster
```

**Drill-down links:**
- Click cluster name → open that cluster's detailed dashboard
- Click heartbeat count → [`heartbeat-reliability.md`](../reviews/heartbeat-reliability.md)
- Click disk_pct → [`disk-growth.md`](../reviews/disk-growth.md)

### 3.2 Service Health Grid

**Panel type:** Table (service rows, cluster columns, colored cells)

**Data source:** ClickHouse — `boss_heartbeats` + container health checks

**Sources:**

| Service | Health Signal | Collection Method |
|---------|--------------|-------------------|
| **cc-connect** | `up{job="cc-connect"}` (Prometheus) | Prometheus → ClickHouse via remote write |
| **feishu-bridge** | Container uptime (`docker ps`) | Heartbeat loop |
| **PostgreSQL-16** | Query success (`pg_isready` or SQL probe) | Prometheus (postgres_exporter) |
| **PostgreSQL-15** | Same | Prometheus |
| **PostgreSQL-14** | Same | Prometheus |
| **PostgreSQL-17** | Same | Prometheus |
| **ClickHouse** | Query success | Prometheus (clickhouse_exporter) |
| **Redis** | PING success | Prometheus (redis_exporter) |
| **Kafka** | Broker reachable + produce/consume | Prometheus (kafka_exporter) + custom probe |
| **Grafana** | HTTP 200 on `/api/health` | Prometheus (blackbox_exporter) |
| **sing-box** | SOCKS5 proxy handshake success | Custom probe |
| **Vector** | Log ingestion rate > threshold | Prometheus (vector self-metrics) |
| **Prometheus** | Target up count / total | Prometheus itself (itself) |
| **cAdvisor** | Container metrics reachable | Prometheus (cadvisor) |
| **node_exporter** | Host metrics reachable | Prometheus (node_exporter) |
| **ACR mirror** | Registry pull test | Cron probe |
| **OSS cache** | Cache hit ratio | Cron probe |
| **Build runner** | Job dispatch test | Cron probe |

**Display:**

```
                        Mac/Orbstack  Aliyun     Office
cc-connect              🟢 running    ⚪ N/A     ⚪ N/A
feishu-bridge           🟢 running    ⚪ N/A     ⚪ N/A
PostgreSQL-16           🟢 uptime     ⚪ N/A     ⚪ N/A
ClickHouse              🟢 uptime     ⚪ N/A     ⚪ N/A
Redis                   🟢 uptime     ⚪ N/A     ⚪ N/A
Kafka                   🟢 uptime     ⚪ N/A     ⚪ N/A
Grafana                 🟢 uptime     ⚪ N/A     ⚪ N/A
sing-box                🟢 uptime     ⚪ N/A     ⚪ N/A
ACR mirror              ⚪ N/A        🟢 OK      ⚪ N/A
OSS cache               ⚪ N/A        🟢 OK      ⚪ N/A
Build runner            ⚪ N/A        🔴 DOWN    ⚪ N/A
GitLab mirror           ⚪ N/A        ⚪ N/A     🟢 OK
Nexus cache             ⚪ N/A        ⚪ N/A     🟢 OK
Office proxy exit       ⚪ N/A        ⚪ N/A     🟢 OK
```

**Drill-down links:**
- Each cell → service-specific dashboard (see [Section 5](#5-drill-down-index))
- Row header → design doc for that service
- Cluster column header → per-cluster dashboard

### 3.3 Observability Pipeline Status

**Panel type:** Table or Stat list

**Pipelines to monitor:**

| Pipeline | Latency SLI | Throughput SLI | Error SLI |
|----------|-------------|----------------|-----------|
| **Heartbeat ingestion** | Time since last beat per cluster | Beats/min per cluster | Missing beats count |
| **Vector log pipeline** | Max delivery time (p99) | Events/sec | Dropped events count |
| **Fluentd pipeline** | Max delivery time (p99) | Events/sec | Retry count |
| **OTel traces** | Span e2e delay | Spans/min | Failed exports |
| **Prometheus scrape** | Scrape duration (p99) | Targets scraped | Scrape errors |
| **ClickHouse writes** | Insert latency (p99) | Rows/sec | Failed inserts |
| **Feishu delivery** | Message delivery time | Messages/min | Delivery failures |

**Key drill-down links:**

| Pipeline | Review Doc |
|----------|-----------|
| Heartbeat | [`heartbeat-reliability.md`](../reviews/heartbeat-reliability.md) |
| Vector | [`vector-pipeline.md`](../reviews/vector-pipeline.md) |
| Fluentd | [`fluentd-pipeline.md`](../reviews/fluentd-pipeline.md) |
| OTel traces | [`otel-cc-connect.md`](../reviews/otel-cc-connect.md), [`otel-kafka.md`](../reviews/otel-kafka.md), [`otel-mcp.md`](../reviews/otel-mcp.md), [`cross-container-traces.md`](../reviews/cross-container-traces.md) |
| Prometheus | [`prometheus-scrape.md`](../reviews/prometheus-scrape.md) |
| Grafana clickhouse | [`grafana-provisioning.md`](../reviews/grafana-provisioning.md) |
| Feishu delivery | [`feishu-delivery.md`](../reviews/feishu-delivery.md) |

### 3.4 Error Budget Row

**Panel type:** Gauge or Stat with thresholds

**Data source:** Prometheus (recorded rules) → ClickHouse

**Budget remaining per tier:**

```sql
SELECT
  tier,
  service,
  budget_remaining_pct,
  budget_remaining_seconds,
  CASE
    WHEN budget_remaining_pct < 20  THEN '🔴 CRITICAL'
    WHEN budget_remaining_pct < 50  THEN '🟡 WARNING'
    ELSE '🟢 OK'
  END AS status
FROM error_budget_state
WHERE window_end > now() - INTERVAL 1 HOUR
ORDER BY tier, service
```

**Drill-down:** [`error-budget.md`](../reviews/error-budget.md)

### 3.5 Active Alerts Row

**Panel type:** Alert list

**Sources:**
- Prometheus Alertmanager (if deployed)
- Hook system alerts (from `bridge-hooks-alerting.md`)
- Patrol-detected anomalies (from `5min-patrol-guide.md`)
- Burn rate alerts (from `error-budget.md`)

**Drill-down:** [`bridge-hooks-alerting.md`](../designs/bridge-hooks-alerting.md), [`alert-fatigue.md`](../reviews/alert-fatigue.md)

### 3.6 Quick Links Row

**Panel type:** Text / Markdown panel

Links to everything an operator needs in one place.

---

## 4. Subsystem Registration

Every subsystem that appears on the meta-dashboard should register itself via a **metadata file** or a **naming convention**. This prevents manual drift when new services come online.

### 4.1 Registration Format

Each review doc or design doc should include a front-matter block (or structured section) that declares:

```yaml
---
meta_dashboard:
  category: Infrastructure Service | Observability Pipeline | Review | Alerting
  cluster: mac-orbstack | aliyun | office | all
  panel: service-grid | pipeline-status | error-budget | alerts
  health_signal: prometheus | heartbeat | custom-probe
  docs:
    design: docs/infra/designs/<name>.md
    review: docs/infra/reviews/<name>.md
    runbook: docs/infra/<name>.md
  grafana_dashboard_url: http://grafana:3000/d/<uid>/<name>
---
```

### 4.2 Auto-Discovery Script

A script at `bin/scan-infra-subsystems` (future) would:

1. Scan `docs/infra/designs/` and `docs/infra/reviews/` for front-matter tags
2. Validate that `grafana_dashboard_url` is reachable
3. Output a JSON manifest that the meta-dashboard panel can consume
4. Alert if a subsystem exists in `docs/` but not in the meta-dashboard

### 4.3 Current Subsystem Inventory

This is the complete register of everything that should appear on the meta-dashboard:

| # | Subsystem | Category | Cluster | Panel | Health Signal | Docs |
|---|-----------|----------|---------|-------|---------------|------|
| 1 | cc-connect | Service | mac-orbstack | service-grid | prometheus/uptime | [`error-budget`](../reviews/error-budget.md) |
| 2 | feishu-bridge | Service | mac-orbstack | service-grid | heartbeat | [`feishu-delivery`](../reviews/feishu-delivery.md) |
| 3 | cc-healthcheck | Service | mac-orbstack | service-grid | cron status | [`bridge-hooks-alerting`](../designs/bridge-hooks-alerting.md) |
| 4 | PostgreSQL-16 | Service | mac-orbstack | service-grid | prometheus | [`pg-replication`](../reviews/review-pg-replication.md) |
| 5 | PostgreSQL-15 | Service | mac-orbstack | service-grid | prometheus | |
| 6 | PostgreSQL-14 | Service | mac-orbstack | service-grid | prometheus | |
| 7 | PostgreSQL-17 | Service | mac-orbstack | service-grid | prometheus | |
| 8 | ClickHouse | Service | mac-orbstack | service-grid | prometheus | [`ck-query-monitor`](../reviews/ck-query-monitor.md) |
| 9 | Redis | Service | mac-orbstack | service-grid | prometheus | |
| 10 | Kafka | Service | mac-orbstack | service-grid | prometheus | [`kafka-lag`](../reviews/kafka-lag.md), [`kafka-message-bus`](../reviews/kafka-message-bus.md) |
| 11 | Grafana | Service | mac-orbstack | service-grid | prometheus | [`grafana-provisioning`](../reviews/grafana-provisioning.md) |
| 12 | sing-box | Service | mac-orbstack | service-grid | custom probe | [`sing-box-metrics`](../reviews/sing-box-metrics.md) |
| 13 | Prometheus | Service | mac-orbstack | service-grid | itself | [`prometheus-scrape`](../reviews/prometheus-scrape.md) |
| 14 | Vector | Service | mac-orbstack | service-grid | self-metrics | [`vector-pipeline`](../reviews/vector-pipeline.md) |
| 15 | Fluentd | Service | mac-orbstack | pipeline-status | self-metrics | [`fluentd-pipeline`](../reviews/fluentd-pipeline.md) |
| 16 | cAdvisor | Service | mac-orbstack | service-grid | prometheus | [`cc-ws-health`](../reviews/cc-ws-health.md) |
| 17 | node_exporter | Service | mac-orbstack | service-grid | prometheus | [`node-exporter`](../reviews/node-exporter.md) |
| 18 | ACR mirror | Service | aliyun | service-grid | cron probe | |
| 19 | OSS cache | Service | aliyun | service-grid | cron probe | |
| 20 | Build runner | Service | aliyun | service-grid | cron probe | |
| 21 | GitLab mirror | Service | office | service-grid | cron probe | |
| 22 | Nexus cache | Service | office | service-grid | cron probe | |
| 23 | Office proxy exit | Service | office | service-grid | custom probe | [`proxy-intercept`](../reviews/proxy-intercept.md) |
| 24 | OTel traces | Pipeline | all | pipeline-status | prometheus | [`otel-cc-connect`](../reviews/otel-cc-connect.md), [`otel-kafka`](../reviews/otel-kafka.md), [`otel-mcp`](../reviews/otel-mcp.md), [`otel-patrol`](../reviews/otel-patrol.md), [`cross-container-traces`](../reviews/cross-container-traces.md) |
| 25 | Heartbeat system | Pipeline | all | pipeline-status | heartbeat | [`heartbeat-reliability`](../reviews/heartbeat-reliability.md) |
| 26 | Patrol agents | Pipeline | all | pipeline-status | heartbeat | [`5min-patrol-guide`](../5min-patrol-guide.md) |
| 27 | Error budget | Pipeline | all | error-budget | prometheus | [`error-budget`](../reviews/error-budget.md) |
| 28 | Hook alerting | Pipeline | all | alerts | hook system | [`bridge-hooks-alerting`](../designs/bridge-hooks-alerting.md) |
| 29 | Burn rate alerts | Pipeline | all | alerts | prometheus | [`error-budget`](../reviews/error-budget.md) |
| 30 | Docker events | Pipeline | all | alerts | prometheus | [`docker-events`](../reviews/docker-events.md) |

---

## 5. Drill-Down Index

Every item on the meta-dashboard should drill down to:
1. A **Grafana dashboard** (where available)
2. A **review doc** (design details, known issues)
3. A **runbook** (operational procedures)
4. An **SSH command** (emergency access)

### 5.1 By Cluster

| Cluster | Grafana Tag | Review Docs | SSH Command |
|---------|------------|-------------|-------------|
| **Mac/Orbstack** | `cluster=mac-orbstack` | N/A (all reviews cover this) | `docker exec infra-boss` |
| **Aliyun (sim)** | `cluster=aliyun` | N/A | `ssh sim "docker exec kyb-infra-boss"` |
| **Office (nuc8)** | `cluster=office` | N/A | `ssh nuc8 "docker exec kyb-infra-boss"` |

### 5.2 By Service

| Service | Grafana Dashboard (UID) | Review Doc | Runbook |
|---------|------------------------|------------|---------|
| cc-connect | `cc-connect-overview` (TBD) | [`cc-ws-health.md`](../reviews/cc-ws-health.md), [`cc-hooks-direct-ck.md`](../reviews/cc-hooks-direct-ck.md) | `docker restart kyb-infra-cc-connect` |
| feishu-bridge | `feishu-delivery` (TBD) | [`feishu-delivery.md`](../reviews/feishu-delivery.md) | [`chat.md`](../chat.md) (troubleshooting) |
| ClickHouse | `ck-query-monitor` (TBD) | [`ck-query-monitor.md`](../reviews/ck-query-monitor.md) | `docker restart kyb-infra-clickhouse` |
| PostgreSQL | `pg-overview` (TBD) | [`review-pg-replication.md`](../reviews/review-pg-replication.md) | `docker restart kyb-infra-pg-16` |
| Kafka | `kafka-overview` (TBD) | [`kafka-lag.md`](../reviews/kafka-lag.md), [`kafka-message-bus.md`](../reviews/kafka-message-bus.md), [`hooks-kafka.md`](../reviews/hooks-kafka.md) | `docker restart kyb-infra-kafka` |
| Grafana | `grafana-overview` (built-in) | [`grafana-provisioning.md`](../reviews/grafana-provisioning.md) | `docker restart kyb-infra-grafana` |
| sing-box | `sing-box-traffic` (TBD) | [`sing-box-metrics.md`](../reviews/sing-box-metrics.md) | `docker restart kyb-infra-sing-box` |
| Redis | N/A | N/A | `docker restart kyb-infra-redis` |
| Prometheus | `prometheus-overview` (built-in) | [`prometheus-scrape.md`](../reviews/prometheus-scrape.md) | `docker restart kyb-infra-prometheus` |
| Vector | `vector-pipeline` (TBD) | [`vector-pipeline.md`](../reviews/vector-pipeline.md) | `docker restart kyb-infra-vector` |
| Fluentd | `fluentd-pipeline` (TBD) | [`fluentd-pipeline.md`](../reviews/fluentd-pipeline.md) | `docker restart kyb-infra-fluentd` |

### 5.3 By Observability Dimension

| Dimension | Grafana Dashboard | Review Doc | Design Doc |
|-----------|------------------|------------|------------|
| Container health | N/A | [`crash-loop.md`](../reviews/crash-loop.md), [`docker-events.md`](../reviews/docker-events.md) | |
| Disk growth | `disk-growth` (TBD) | [`disk-growth.md`](../reviews/disk-growth.md) | |
| Session monitoring | `session-monitor` (TBD) | [`session-monitor.md`](../reviews/session-monitor.md), [`session-duration.md`](../reviews/session-duration.md) | |
| Token cost | `token-cost` (TBD) | [`token-cost.md`](../reviews/token-cost.md) | |
| User activity | `user-activity` (TBD) | [`user-activity.md`](../reviews/user-activity.md) | |
| Permission latency | N/A | [`permission-latency.md`](../reviews/permission-latency.md) | |
| Boss decision latency | N/A | [`boss-decision-latency.md`](../reviews/boss-decision-latency.md) | |
| Proxy interception | N/A | [`proxy-intercept.md`](../reviews/proxy-intercept.md), [`proxy-kafka.md`](../reviews/proxy-kafka.md) | |
| Backup verification | N/A | [`backup-monitor.md`](../reviews/backup-monitor.md) | |
| Alert fatigue | N/A | [`alert-fatigue.md`](../reviews/alert-fatigue.md) | |
| Claude telemetry | `claude-telemetry` (TBD) | [`claude-telemetry.md`](../reviews/claude-telemetry.md) | |
| Sidecar pattern | N/A | [`sidecar-pattern.md`](../reviews/sidecar-pattern.md) | |
| OTel patrol trace | N/A | [`otel-patrol.md`](../reviews/otel-patrol.md) | |

### 5.4 Top-Level Architecture Docs

| Doc | Purpose |
|-----|---------|
| [`observability-design.md`](../observability-design.md) | Overall observability architecture, bridge observability, MCP tracing |
| [`multi-cluster-boss-architecture.md`](../multi-cluster-boss-architecture.md) | Multi-cluster boss hierarchy, inter-boss communication, bootstrap |
| [`5min-patrol-guide.md`](../5min-patrol-guide.md) | Patrol system operation, sibling health checking |
| [`chat.md`](../chat.md) | IM integration troubleshooting (Feishu, DingTalk) |

### 5.5 Theme: Bridge Observability (A/B/C/D/E)

The bridge observability reviews are organized as design → multiple reviews per design:

| Design | Reviews A1/A2/A3 | Topic |
|--------|-----------------|-------|
| **A**: bridge-ck-ingestion | [`A1`](../reviews/review-bridge-ck-ingestion-A1.md), [`A2`](../reviews/review-bridge-ck-ingestion-A2.md), [`A3`](../reviews/review-bridge-ck-ingestion-A3.md) | cc-connect messages full ingestion to ClickHouse |
| **B**: bridge-metrics-logging | [`B2`](../reviews/review-bridge-metrics-B2.md), [`B3`](../reviews/review-bridge-metrics-B3.md) | Metrics and logging for bridge services |
| **C**: bridge-hooks-alerting | [`C1`](../reviews/review-bridge-hooks-C1.md), [`C2`](../reviews/review-bridge-hooks-C2.md), [`C3`](../reviews/review-bridge-hooks-C3.md) | Hook system + alerting |
| **D**: MCP observability | [`D1`](../reviews/review-mcp-D1.md), [`D2`](../reviews/review-mcp-D2.md), [`D3`](../reviews/review-mcp-D3.md) | MCP distributed tracing |
| **E**: issue-automation | [`E1`](../reviews/review-issue-automation-E1.md), [`E2`](../reviews/review-issue-automation-E2.md), [`E3`](../reviews/review-issue-automation-E3.md) | GitLab issue automation |

---

## 6. Alerting Integration

The meta-dashboard must not just show current health — it must also show **what is currently alerting** and **what has recently resolved**.

### 6.1 Alert Sources

| Source | How it feeds the meta-dashboard | Latency |
|--------|--------------------------------|---------|
| Prometheus Alertmanager | Alertmanager API → meta-dashboard panel | 15s |
| Hook system alerts | Hook writes to ClickHouse → meta-dashboard reads | 30s |
| Patrol anomalies | Patrol writes to ClickHouse → meta-dashboard reads | 5min |
| Burn rate alerts | Prometheus recording rules → meta-dashboard | 1min |
| Sibling death detection | Patrol sibling check → meta-dashboard | 15min |

### 6.2 Alert Deduplication

Same failure may trigger multiple sources (e.g., cc-connect crash triggers Prometheus alert, hook alert, and patrol anomaly). The meta-dashboard shows them as **one alert** with **N sources** indicator.

```sql
SELECT
  alert_key,
  max(severity) AS severity,
  groupArray(source) AS sources,
  min(first_seen) AS first_seen,
  max(last_seen) AS last_seen
FROM active_alerts
WHERE resolved = 0
GROUP BY alert_key
```

### 6.3 Notification Channels

| Channel | When |
|---------|------|
| Feishu group `kyb-kindergarden` | P0/P1 alerts, burn rate depletion |
| DingTalk webhook | P0 alerts only (noisy channel) |
| Meta-dashboard panel | All alerts (visible to operator) |
| Patrol agent (on next cycle) | Summarizes unresolved alerts |

---

## 7. Implementation Plan

### Phase 1: Grafana Provisioning (Week 1)

| Step | Output | Depends On |
|------|--------|-----------|
| 1.1 | Set up Grafana provisioning as code (dashboards dir) | [`grafana-provisioning.md`](../reviews/grafana-provisioning.md) |
| 1.2 | Create ClickHouse datasource YAML (env-agnostic) | Phase 1.1 |
| 1.3 | Create Prometheus datasource YAML | Phase 1.1 |
| 1.4 | Create "Cluster Status" row panel (Stat) | Phase 1.2 |
| 1.5 | Create "Service Health" row panel (Table) | Phase 1.2 |
| 1.6 | Create "Pipeline Status" row panel (Table) | Phase 1.2 |

### Phase 2: Error Budget + Alerts (Week 2)

| Step | Output | Depends On |
|------|--------|-----------|
| 2.1 | Deploy Prometheus with alerting rules | [`prometheus-scrape.md`](../reviews/prometheus-scrape.md) |
| 2.2 | Implement error budget recording rules | [`error-budget.md`](../reviews/error-budget.md) |
| 2.3 | Add "Error Budget" row panel | Phase 2.2 |
| 2.4 | Add "Active Alerts" row panel (Alertmanager datasource) | Phase 2.1 |
| 2.5 | Wire hook system alerts into ClickHouse alert table | Phase 1.2 |

### Phase 3: Drill-Down Dashboards (Week 3)

| Step | Output | Depends On |
|------|--------|-----------|
| 3.1 | Create per-service dashboards (cc-connect, PG, CK, Kafka, Redis) | Phase 1.1 |
| 3.2 | Create per-cluster dashboards (Aliyun, Office) | Phase 1.1 |
| 3.3 | Add drill-down links from meta-dashboard to per-service dashboards | Phase 3.1 |

### Phase 4: Automation + Registration (Week 4)

| Step | Output | Depends On |
|------|--------|-----------|
| 4.1 | Create `bin/scan-infra-subsystems` auto-discovery script | Phase 3 |
| 4.2 | Front-matter tag standard in all design/review docs | Phase 4.1 |
| 4.3 | Auto-generated JSON manifest for meta-dashboard | Phase 4.1 |
| 4.4 | Snapshot mode (static HTML for SSH-only access) | Phase 4.3 |

### 7.1 Grafana Dashboard UID Conventions

To make drill-down links predictable, use these UID conventions:

```
infra-meta                    # The meta-dashboard itself
infra-cluster-mac-orbstack    # Per-cluster: Mac
infra-cluster-aliyun          # Per-cluster: Aliyun
infra-cluster-office          # Per-cluster: Office
infra-cc-connect              # cc-connect detail
infra-feishu-bridge           # Feishu bridge detail
infra-clickhouse              # ClickHouse detail
infra-postgresql               # PostgreSQL detail (shows all versions)
infra-kafka                   # Kafka detail
infra-redis                   # Redis detail
infra-grafana                 # Grafana (self)
infra-sing-box                # sing-box detail
infra-heartbeat               # Heartbeat detail
infra-error-budget            # Error budget detail
infra-prometheus              # Prometheus detail (scrape targets)
infra-vector                  # Vector pipeline detail
infra-session-monitor         # Session monitoring
infra-token-cost              # Token cost tracking
infra-user-activity           # User activity heatmap
```

### 7.2 Standard Drill-Down Link Format

Each meta-dashboard cell that is clickable should follow:

```
[META] Service Health → cell
  ├── 🖥️ Grafana dashboard:  http://grafana:3000/d/infra-{service}?var-cluster={cluster}
  ├── 📄 Review doc:         open docs/infra/reviews/{name}.md
  ├── 📘 Design doc:         open docs/infra/designs/{name}.md
  ├── 📗 Runbook:            open docs/infra/handbook/{name}.md
  └── 🚀 SSH quick command:  dispatch {cluster} docker logs kyb-infra-{service} --tail 50
```

For the unavailability case (no Grafana yet), the link defaults to the review doc or runbook. This ensures the meta-dashboard is useful even before all Grafana dashboards exist.

---

## 8. Operational Runbook

### 8.1 Daily Use

```bash
# Open the meta-dashboard in browser
open http://grafana:3000/d/infra-meta

# Or from SSH (no browser):
# Run the snapshot script (Phase 4)
dispatch mac bash -c "curl -s http://grafana:3000/d/infra-meta/snapshot"
```

### 8.2 What to Check on Each Patrol

Refer to the [5-minute patrol guide](../5min-patrol-guide.md). The meta-dashboard replaces manual `SELECT * FROM boss_heartbeats` queries:

```
Patrol step 1: glance at meta-dashboard
  ├── All clusters green?                                → OK, move on
  ├── One cluster red?                                   → SSH into that cluster, check services
  ├── Multiple clusters red?                             → Global issue (network, proxy, CK down)
  └── Pipeline status shows red?                         → Observability data may be stale, trust SSH
```

### 8.3 Incident Triage Flow

```
Incident detected (alert or patrol)
  │
  ├─ Open meta-dashboard
  │   ├─ Which cluster?     → Click cluster column header
  │   ├─ Which service?     → Click service cell
  │   ├─ Which pipeline?    → Check pipeline status row
  │   └─ Budget remaining?  → Check error budget row
  │
  ├─ Identify scope
  │   ├─ Single service     → Service-specific runbook
  │   ├─ Single cluster     → Cluster-specific SSH + investigation
  │   └─ Global             → Check network, proxy, ClickHouse (central dependency)
  │
  ├─ Deep dive
  │   ├─ Grafana panel      → Linked from meta-dashboard cell
  │   ├─ Review doc         → Linked from meta-dashboard (design context, known issues)
  │   └─ Runbook            → Linked from meta-dashboard (recovery steps)
  │
  └─ Resolve + verify
      ├─ Fix (restart, rollback, scale)
      ├─ Verify on meta-dashboard (cell turns green)
      └─ Document (update review doc or write postmortem)
```

### 8.4 Adding a New Subsystem

```bash
# Step 1: Create the review/design doc with front-matter
cat > docs/infra/reviews/new-thing.md << 'EOF'
---
meta_dashboard:
  category: Service
  cluster: mac-orbstack
  panel: service-grid
  health_signal: prometheus
  grafana_dashboard_url: http://grafana:3000/d/infra-new-thing
---
# New Thing Monitoring

...
EOF

# Step 2: Add health probe
# (add to heartbeats, Prometheus scrape target, or custom probe)

# Step 3: Register in the inventory table
# (edit Section 4.3 of this document)

# Step 4: Create Grafana detail dashboard with UID infra-new-thing

# Step 5: Add drill-down entry in Section 5.2

# Step 6: Add error budget SLO in error-budget.md Section 2.1

# Step 7: Verify it appears on the meta-dashboard
```

### 8.5 Maintenance Operations

| Operation | How |
|-----------|-----|
| **Restart all services on a cluster** | `docker restart $(docker ps -q --filter name=kyb-infra)` (order matters: data before app) |
| **Rebuild meta-dashboard after provisioning change** | `touch provisioning/dashboards/infra-meta.json` triggers Grafana reload |
| **Temporarily silence a subsystem alert** | Add annotation in meta-dashboard: `kubectl annotate --overwrite` or add to maintenance window |
| **Export snapshot for SSH-only use** | `curl -s http://grafana:3000/api/dashboards/uid/infra-meta > meta-snapshot.json` |
| **Verify all drill-down links work** | `bin/scan-infra-subsystems --validate-links` |
| **Migrate meta-dashboard to new Grafana instance** | Copy `provisioning/dashboards/infra-meta.json` (all config is in this one file) |

---

## Appendix A: Dashboard Relationship Diagram

```
                               ┌──────────────────┐
                               │  INFRA META      │
                               │  (Entry point)    │
                               └────────┬─────────┘
                                        │
          ┌─────────────────────────────┼─────────────────────────────┐
          │                             │                             │
          ▼                             ▼                             ▼
┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
│  Per-Cluster     │        │  Per-Service     │        │  Per-Pipeline    │
│  Dashboards      │        │  Dashboards      │        │  Dashboards      │
├──────────────────┤        ├──────────────────┤        ├──────────────────┤
│ mac-orbstack     │        │ cc-connect       │        │ vector           │
│ aliyun           │        │ PostgreSQL       │        │ fluentd          │
│ office           │        │ ClickHouse       │        │ OTel traces      │
└──────────────────┘        │ Kafka            │        │ heartbeats       │
                            │ Redis            │        │ error budget     │
                            │ Grafana          │        │ alerts           │
                            │ sing-box         │        └──────────────────┘
                            └──────────────────┘
                                        │
                                        ▼
                            ┌──────────────────────┐
                            │  Review / Design     │
                            │  Documents           │
                            │  (Deep context)      │
                            └──────────────────────┘
```

## Appendix B: Grafana JSON Model Skeleton

An minimal Grafana dashboard JSON for the meta-dashboard would have this structure:

```json
{
  "dashboard": {
    "uid": "infra-meta",
    "title": "Infra Meta-Dashboard",
    "tags": ["infra", "meta", "boss"],
    "timezone": "browser",
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "Cluster Status",
        "type": "stat",
        "datasource": "ClickHouse",
        "targets": [],
        "gridPos": {"h": 4, "w": 24, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "Service Health",
        "type": "table",
        "datasource": "ClickHouse",
        "targets": [],
        "gridPos": {"h": 12, "w": 24, "x": 0, "y": 4}
      },
      {
        "id": 3,
        "title": "Observability Pipelines",
        "type": "table",
        "datasource": "ClickHouse",
        "targets": [],
        "gridPos": {"h": 6, "w": 12, "x": 0, "y": 16}
      },
      {
        "id": 4,
        "title": "Error Budget Remaining",
        "type": "gauge",
        "datasource": "Prometheus",
        "targets": [],
        "gridPos": {"h": 6, "w": 6, "x": 12, "y": 16}
      },
      {
        "id": 5,
        "title": "Active Alerts",
        "type": "alertlist",
        "datasource": "Alertmanager",
        "targets": [],
        "gridPos": {"h": 6, "w": 6, "x": 18, "y": 16}
      },
      {
        "id": 6,
        "title": "Quick Links",
        "type": "text",
        "content": "",
        "gridPos": {"h": 4, "w": 24, "x": 0, "y": 22}
      }
    ]
  }
}
```

## Appendix C: Metric Reliability Commitment

For the meta-dashboard to be trustworthy, we need **observability of observability**:

| Commitment | Why | How |
|-----------|-----|-----|
| Heartbeat data ≥ 95% availability | Without heartbeats, meta-dashboard shows stale data | Prometheus blackbox probe on CK HTTP port |
| Panel load time < 2s | Operator won't wait | Pre-aggregated materialized views in CK |
| Drill-down links always valid | Broken links destroy trust | CI checks all `grafana_dashboard_url` values resolve |
| Alert deduplication working | Double alerts desensitize operators | Integration test: fire same alert from 2 sources → 1 alert shown |
| Snapshot mode works without CK | CK outage should not blind operator | Last-known-good state cached in panel JSON |

> **Summary:** The meta-dashboard is a single Grafana dashboard with 6 rows covering cluster status, service health, pipeline health, error budgets, active alerts, and quick links. Every cell links to a detailed per-service Grafana panel, review doc, or runbook. New subsystems register themselves via front-matter tags. Implementation is phased over 4 weeks, starting with Grafana provisioning as code.

> ／人◕ ‿‿ ◕人＼
