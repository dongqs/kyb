---
decision: 稍后做
---

# Error Budget Tracking for Infra Services

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Define SLO targets, burn rate alerting, and budget remaining tracking for all managed infra services.

---

## Table of Contents

1. [Principles](#1-principles)
2. [Service Catalog & SLOs](#2-service-catalog---slos)
3. [SLI Definitions](#3-sli-definitions)
4. [Burn Rate Alerts](#4-burn-rate-alerts)
5. [Budget Remaining Tracking](#5-budget-remaining-tracking)
6. [Multi-Window, Multi-Burn-Rate (MWMBR)](#6-multi-window-multi-burn-rate-mwmbr)
7. [Grafana Implementation](#7-grafana-implementation)
8. [Per-Cluster Budget Pools](#8-per-cluster-budget-pools)
9. [Error Budget Policy](#9-error-budget-policy)
10. [Operational Runbook](#10-operational-runbook)

---

## 1. Principles

### 1.1 Why Error Budgets

Error budgets convert service reliability into a measurable resource. Each service gets a budget: `1 - SLO`. If the budget is full, the team can deploy freely. If the budget is depleted, deployments pause until reliability recovers.

### 1.2 Budget Period

- **Rolling window:** 30 days (not calendar month)
- This avoids edge-of-month bursts and aligns with incident response horizons.

### 1.3 SLO Tier Definitions

| Tier | Target | Budget (30d) | Max daily error budget | Example services |
|------|--------|-------------|----------------------|-----------------|
| **Tier-0** | 99.99% | 4m 19s | ~8.6s/day | cc-connect (bridge core path) |
| **Tier-1** | 99.9% | 43m 12s | ~86s/day | PostgreSQL, ClickHouse, Redis, Kafka |
| **Tier-2** | 99.5% | 3h 35m | ~7.2m/day | Proxy (sing-box), ACR mirror, OSS cache |
| **Tier-3** | 99.0% | 7h 12m | ~14.4m/day | Build runner, Grafana (read-only) |

### 1.4 Choosing the Right SLO

- **Tier-0:** User-facing synchronous path. If this goes down, users notice immediately.
- **Tier-1:** Stateful infrastructure. Data loss or consensus failure is a P0 incident.
- **Tier-2:** Caching / acceleration services. Degradation is slower throughput, not data loss.
- **Tier-3:** Non-critical tooling. Failure does not block end-user messaging.

---

## 2. Service Catalog & SLOs

### 2.1 Service Registry

| Service | SLI | SLO Target | Tier | Window | Cluster(s) |
|---------|-----|-----------|------|--------|------------|
| **cc-connect** | Uptime (process health) | 99.99% | 0 | 30d | mac-orbstack |
| **feishu-bridge** | Uptime (process health) | 99.9% | 1 | 30d | mac-orbstack |
| **cc-healthcheck** | Uptime (cron success) | 99.5% | 2 | 30d | mac-orbstack |
| **PostgreSQL-16** | Uptime + query success (2xx status) | 99.9% | 1 | 30d | mac-orbstack |
| **PostgreSQL-15** | Uptime + query success | 99.9% | 1 | 30d | mac-orbstack |
| **PostgreSQL-14** | Uptime + query success | 99.9% | 1 | 30d | mac-orbstack |
| **PostgreSQL-17** | Uptime + query success | 99.9% | 1 | 30d | mac-orbstack |
| **ClickHouse** | Uptime + query success | 99.9% | 1 | 30d | mac-orbstack |
| **Redis** | Uptime + PING success | 99.9% | 1 | 30d | mac-orbstack |
| **Kafka** | Uptime + produce/consume success | 99.9% | 1 | 30d | mac-orbstack |
| **Vector** | Log ingestion success (>95% of messages delivered within 60s) | 99.5% | 2 | 30d | mac-orbstack |
| **Grafana** | Uptime + dashboard load success | 99.0% | 3 | 30d | mac-orbstack |
| **sing-box** | Proxy tunnel uptime + connection success | 99.5% | 2 | 30d | mac-orbstack |
| **ACR mirror** | Registry pull success | 99.5% | 2 | 30d | aliyun |
| **OSS cache** | Cache hit + upstream fetch success | 99.5% | 2 | 30d | aliyun |
| **Build runner** | Uptime + job dispatch success | 99.0% | 3 | 30d | aliyun |
| **feishu-bridge (sync)** | Sync job completion success | 99.5% | 2 | 30d | office |

### 2.2 Composite SLOs

Some user journeys cross multiple services. A composite SLO catches systemic degradation that individual service SLOs might miss:

| Journey | Components | Composite SLO | Budget (30d) |
|---------|-----------|---------------|-------------|
| **Send message** | cc-connect x PostgreSQL x sing-box | 99.9% | 43m 12s |
| **Receive response** | cc-connect x Claude API | 99.9% | 43m 12s |
| **View Grafana dashboard** | Grafana x ClickHouse x PostgreSQL | 99.0% | 7h 12m |
| **Docker pull via mirror** | ACR mirror x sing-box | 99.0% | 7h 12m |

Composite SLO = product of individual SLIs (latency is additive, availability is multiplicative).

---

## 3. SLI Definitions

### 3.1 Uptime-Based SLIs

For services where the primary contract is "is running":

```promql
# Good events (cc-connect)
up{job="cc-connect"}

# Total events
vector(1)  -- constant-1 for the time window

# SLI = avg_over_time(up{job="cc-connect"}[30d])
```

**Probe interval:** 15s (Prometheus scrape). An SLI event is each discrete scrape.

### 3.2 Request-Based SLIs

For services where the contract includes correctness:

```promql
# Good requests (PostgreSQL)
pg_stat_database_xact_commit{datname="postgres"}

# Total requests
pg_stat_database_xact_commit{datname="postgres"} + pg_stat_database_xact_rollback{datname="postgres"}
```

### 3.3 Latency-Based SLIs

For services where the contract includes performance:

```promql
# Good requests: p99 latency < SLO threshold
histogram_quantile(0.99, ...) < 0.5  -- 500ms for ClickHouse reads
```

### 3.4 Throughput-Based SLIs

For log ingestion:

```promql
# Vector: messages delivered within 60s
vector_delivery_delay_seconds{quantile="0.95"} < 60
```

### 3.5 SLI Summary Table

| Service | SLI Type | Good Condition | Measurement Interval |
|---------|----------|---------------|---------------------|
| cc-connect | Uptime | `up == 1` | 15s |
| feishu-bridge | Uptime | `up == 1` | 15s |
| PostgreSQL | Request success | `transactions_committed / (committed + rolled_back) > 0.99` | 1m |
| ClickHouse | Request latency | `p99_query_duration < 1s` | 1m |
| Redis | Uptime | `redis_up == 1` | 15s |
| Kafka | Uptime + produce | `kafka_broker_up == 1` | 15s |
| Vector | Throughput | `p95_delivery_delay < 60s` | 1m |
| Grafana | Uptime | `up == 1` | 15s |
| sing-box | Uptime + conn success | `up == 1 AND proxy_conn_success_rate > 0.95` | 1m |
| ACR mirror | Pull success | `registry_pull_success / total_pulls > 0.995` | 1m |
| Build runner | Job success | `runner_job_success / total_jobs > 0.99` | 1m |

---

## 4. Burn Rate Alerts

### 4.1 Burn Rate Windows

Burn rate is how fast the error budget is being consumed relative to the SLO window. We use multi-window, multi-burn-rate (MWMBR) alerts from Google SRE Workbook pattern:

| Severity | Burn Rate | Alert Window | Time to exhaust budget | When to page |
|----------|-----------|-------------|----------------------|-------------|
| **P0** | >= 14x | 1h | < 2h | Now -- critical, immediate response |
| **P1** | >= 6x | 6h | < 5h | Within 15 minutes |
| **P2** | >= 2x | 3d | < 15d | Within 1 hour (business hours) |
| **P3** | >= 1x | 30d | < 30d | Daily report, no page |

### 4.2 Alert Rule Template (Prometheus)

For a Tier-1 service (99.9% SLO, 43m 12s budget), the burn rate alert rules are:

```yaml
# Tier-1 MWMBR rules
groups:
  - name: error-budget
    rules:
      # P0: 14x burn rate, 1h window
      - alert: ErrorBudgetBurnP0
        expr: |
          (
            (1 - (sum(rate(good_events_total[1h])) / sum(rate(valid_events_total[1h]))))
            > (14 * (1 - 0.999))
          )
          and
          (
            (1 - (sum(rate(good_events_total[5m])) / sum(rate(valid_events_total[5m]))))
            > (14 * (1 - 0.999))
          )
        for: 2m
        annotations:
          severity: page
          summary: "P0: {{ $labels.job }} burning budget at 14x rate for 2 minutes"
          runbook: "docs/infra/runbooks/p0-budget-burn.md"

      # P1: 6x burn rate, 6h window
      - alert: ErrorBudgetBurnP1
        expr: |
          (
            (1 - (sum(rate(good_events_total[6h])) / sum(rate(valid_events_total[6h]))))
            > (6 * (1 - 0.999))
          )
          and
          (
            (1 - (sum(rate(good_events_total[30m])) / sum(rate(valid_events_total[30m]))))
            > (6 * (1 - 0.999))
          )
        for: 5m
        annotations:
          severity: page
          summary: "P1: {{ $labels.job }} burning budget at 6x rate for 5 minutes"

      # P2: 2x burn rate, 3d window
      - alert: ErrorBudgetBurnP2
        expr: |
          (
            (1 - (sum(rate(good_events_total[3d])) / sum(rate(valid_events_total[3d]))))
            > (2 * (1 - 0.999))
          )
          and
          (
            (1 - (sum(rate(good_events_total[6h])) / sum(rate(valid_events_total[6h]))))
            > (2 * (1 - 0.999))
          )
        for: 10m
        annotations:
          severity: ticket
          summary: "P2: {{ $labels.job }} burning budget at 2x rate"
```

### 4.3 Tier-Specific Alert Parameters

Derived from the formula `burn_rate * (1 - SLO) * window = budget_exhaustion_time`:

| Description | Tier-0 (99.99%) | Tier-1 (99.9%) | Tier-2 (99.5%) | Tier-3 (99.0%) |
|------------|----------------|----------------|----------------|----------------|
| Daily budget | ~8.6s | ~86s | ~7.2m | ~14.4m |
| P0 threshold | 1000x over 1h | 14x over 1h | 7x over 1h | 3.3x over 1h |
| P0 burn rate | 49m to exhaust | 1.7h to exhaust | 3.4h to exhaust | 7.2h to exhaust |
| P1 threshold | 200x over 6h | 6x over 6h | 3x over 6h | 2x over 6h |
| P2 threshold | 50x over 3d | 2x over 3d | 1.5x over 3d | 1.2x over 3d |

### 4.4 Alert Routing

| Severity | Channel | Target | Response Time |
|----------|---------|--------|---------------|
| P0 | 飞书群 @all + TTS | All available engineers | < 5min |
| P1 | 飞书群 @oncall | On-call engineer | < 15min |
| P2 | 飞书群 mention + ticket | Service owner | < 1h (business hours) |
| P3 | Daily report | Team lead | Next working day |

### 4.5 Alert Fatigue Prevention

- Multi-window condition (short + long window AND): prevents false positives from transient spikes.
- Short `for` duration: 2-5 minutes, enough to filter scrape blips.
- No alert if no traffic: skip evaluation when `valid_events_total == 0` for the window.
- Silence during planned maintenance: maintenance window annotation suppresses alerts.
- Daily digest for P3: aggregated, not per-event.

---

## 5. Budget Remaining Tracking

### 5.1 The Error Budget Metric

Expose budget remaining as a Prometheus metric:

```promql
# Error budget remaining (ratio, 0.0 to 1.0)
(
  1
  - (
      (1 - (sum(rate(good_events_total[30d])) / sum(rate(valid_events_total[30d]))))
      / (1 - SLO_TARGET)
    )
)
```

Clamped to `[0, 1]` so the metric never goes negative or above 100%.

### 5.2 Per-Service Recorded Metrics

For every service in the catalog, record these metrics:

```yaml
metrics:
  - name: slo_error_budget_remaining_ratio
    type: gauge
    description: "Error budget remaining as a ratio of total budget (0.0 = exhausted, 1.0 = full)"
    labels: [service, cluster, tier]

  - name: slo_error_budget_consumed_seconds
    type: gauge
    description: "Error budget consumed in seconds over the rolling 30d window"
    labels: [service, cluster, tier]

  - name: slo_error_budget_total_seconds
    type: gauge
    description: "Total error budget in seconds for the 30d window"
    labels: [service, tier]

  - name: slo_compliance_30d
    type: gauge
    description: "Actual availability over the rolling 30d window"
    labels: [service, cluster]

  - name: slo_burn_rate_current
    type: gauge
    description: "Instantaneous burn rate (1x = consuming budget at exactly the rate that exhausts it in 30d)"
    labels: [service, cluster]
```

### 5.3 Budget Remaining Chart

A single Grafana panel shows the error budget remaining for all services:

```
[0%] ████████████████████░░░░ [100%]
    cc-connect         99.99% ████████████████████████████░░ 83% remaining
    PostgreSQL-16      99.9%  ██████████████████████████████ 92% remaining
    ClickHouse         99.9%  ██████████████████████████████ 95% remaining
    Redis              99.9%  ██████████████████████████████ 97% remaining
    Kafka              99.9%  ████████████████████████████░ 78% remaining
    Vector             99.5%  ██████████████████████████████ 99% remaining
    Grafana            99.0%  ████████████████████████████░░ 81% remaining
    sing-box           99.5%  ██████████████████████████████ 90% remaining
    ACR mirror         99.5%  ██████████████████████████████ 96% remaining
    Build runner       99.0%  ██████████████████████████████ 88% remaining
```

### 5.4 Budget Spending Rate

A companion panel shows how fast each service is consuming budget over the last 1h, 6h, 24h, 7d:

```
Service       1h rate    6h rate    24h rate   7d rate    Trend
cc-connect    0.2x       0.8x       1.1x       0.9x      stable
Kafka         3.1x       2.4x       1.8x       1.2x      worsening ↑
Redis         0.0x       0.1x       0.1x       0.1x      stable
```

A `Trend` column flags `worsening ↑` if the short-window rate exceeds the long-window rate by 2x or more.

---

## 6. Multi-Window, Multi-Burn-Rate (MWMBR)

### 6.1 Why Two Windows Per Alert

A single long window misses short bursts. A single short window fires on transient blips. Two windows (short + long) AND-ed together detect sustained high burn without false positives.

Window pairs:

| Alert | Short Window | Long Window | Rationale |
|-------|-------------|-------------|-----------|
| P0 alert | 5m | 1h | Catches rapid budget depletion (e.g., cc-connect down) |
| P1 alert | 30m | 6h | Moderate sustained degradation |
| P2 alert | 6h | 3d | Slow drift (e.g., gradual latency increase) |
| P3 (report) | 1d | 30d | Whole-period compliance check |

### 6.2 AND Logic

```promql
# Fire only when BOTH windows exceed threshold
rate_short > threshold AND rate_long > threshold
```

### 6.3 The 5m / 1h P0 Rule Explained

For Tier-1 (99.9%, budget = 43m 12s):

- If the service is completely down (`error_rate = 1.0`), it consumes the full budget in 43m 12s.
- 14x burn rate means `error_rate = 14 * 0.001 = 0.014` sustained.
- At 0.014 error rate, budget exhausts in `43m 12s / 14 = ~3.1 minutes`.
- The 1h window catches it, the 5m short window confirms it's sustained (not a scrape blip).
- After `for: 2m`, alert fires -- max detection latency: ~7 minutes.

---

## 7. Grafana Implementation

### 7.1 Dashboard: Error Budget Overview

**Panel 1: Budget Remaining (Bar Gauge)**
- One bar per service, color-coded:
  - Green: > 50% remaining
  - Yellow: 20-50% remaining
  - Red: < 20% remaining
  - Black: 0% (exhausted)
- Query: `slo_error_budget_remaining_ratio`

**Panel 2: Burn Rate Heatmap**
- X-axis: time (24h)
- Y-axis: services
- Color: burn rate (1x = yellow, 6x = orange, 14x = red)
- Reveals at a glance which services are stressed.

**Panel 3: Budget Consumption Timeline**
- Stacked area chart showing cumulative budget consumed per day.
- Dashed line at 100% = budget exhausted.
- Useful for post-incident review: "How much budget did the ClickHouse outage consume?"

**Panel 4: SLO Compliance Gauge**
- Per-service gauge showing actual rolling-30d availability vs SLO target.
- Red zone below SLO target.

### 7.2 Dashboard: Per-Service Deep Dive

For each service, a dedicated row with:

- **Uptime / success rate** (1h, 6h, 24h, 7d, 30d)
- **Error budget remaining** (gauge)
- **Burn rate** (1h, 6h windows)
- **Events timeline** (good vs bad over time)
- **Incident markers** (annotations from alertmanager)

### 7.3 Dashboard Variables

```yaml
variables:
  - name: cluster
    type: custom
    options: [mac-orbstack, aliyun, office]
    default: all

  - name: tier
    type: custom
    options: [0, 1, 2, 3]
    default: all

  - name: service
    type: query
    query: label_values(slo_error_budget_remaining_ratio, service)
    multi: true
```

### 7.4 Auto-Refresh

Dashboard auto-refreshes every 30 seconds (matches scrape interval x2).

---

## 8. Per-Cluster Budget Pools

### 8.1 Cluster-Level Aggregation

Each cluster has an aggregate budget pool:

```promql
# Cluster budget remaining (weighted by service tier importance)
cluster_budget_remaining =
  avg(slo_error_budget_remaining_ratio{cluster="mac-orbstack"})
```

This gives a single-number health score for each cluster:

| Cluster | Budget Remaining | Status |
|---------|-----------------|--------|
| mac-orbstack | 87% | Healthy |
| aliyun | 92% | Healthy |
| office | 78% | At risk (feishu-bridge-sync degraded) |

### 8.2 Cross-Cluster Comparison

A dashboard row compares cluster budgets over 30 days:

```
[Cluster Budget Remaining]
mac-orbstack  ████████████████████████████████░░░░░░ 72%
aliyun        ██████████████████████████████████████░ 91%
office        ██████████████████████████████████░░░░░ 67%
```

### 8.3 Super-Boss View

The super-boss (mac-orbstack) aggregates all cluster budgets into a single global health metric. If any cluster drops below 30% remaining, the super-boss dispatches a diagnostic agent to that cluster.

---

## 9. Error Budget Policy

### 9.1 Budget Depletion Actions

| Budget Remaining | Action | Trigger |
|-----------------|--------|---------|
| < 50% | P2 ticket, schedule investigation | Burn rate alert P2 |
| < 30% | P1 incident, freeze non-critical changes | Burn rate alert P1 |
| < 10% | P0 incident, freeze all changes, daily standup | Burn rate alert P0 |
| 0% (exhausted) | Emergency bridge call, rollback recent changes | Manual escalation |
| Recovered > 50% | Lift freeze, post-incident review | Automatic via Prometheus |

### 9.2 Deployment Freeze Mechanics

When budget drops below 30%:

1. Super-boss creates a freeze issue on the infra board.
2. All deployments to that service require explicit super-boss approval.
3. Priority is incident response, not feature work.
4. Freeze lifts automatically when budget recovers above 50% for 24h.

### 9.3 Budget Refill

Budget refills at a constant rate over the 30d window. It is NOT reset on the 1st of the month -- it's a rolling window. This means:

- A bad day today affects budget for the next 30 days.
- A full month of perfect uptime is required to fully refill from exhaustion.
- This incentivizes: quick recovery (stop the bleed) AND sustained quality (keep it stable).

### 9.4 SLO Target Adjustments

SLO targets are reviewed quarterly. Adjustments are made based on:

- Historical compliance data (is the target too easy / too hard?)
- User-facing impact (did violations actually affect users?)
- Operational cost (is achieving the target worth the effort?)
- Budget consumption patterns (are we always hovering near 0% or near 100%?)

---

## 10. Operational Runbook

### 10.1 Adding a New Service

1. Identify the SLI (which metric defines "good"?).
2. Choose the SLO target (Tier 0-3).
3. Add Prometheus recording rules for `good_events_total` and `valid_events_total`.
4. Add MWMBR alert rules (one group per tier).
5. Add Grafana panels (budget gauge + burn rate + timeline).
6. Register service in this catalog (Section 2.1).
7. Test: force a failure and verify the alert fires within the expected window.

### 10.2 Deprecating a Service

1. Remove Prometheus alert rules but keep recording rules for 2x SLO window (60d).
2. Remove Grafana panels.
3. Remove from catalog.
4. Keep the history recording for reference.

### 10.3 Incident Response (Budget Context)

When a P0 alert fires:

1. Acknowledge the alert.
2. Check the error budget dashboard: how much budget remains? How fast is it burning?
3. Estimate: at this burn rate, how long until budget exhaustion?
4. Respond based on severity:
   - If budget > 50%: standard incident response.
   - If budget < 50%: escalate, freeze deploys to that service.
   - If budget < 10%: emergency bridge.
5. After resolution: calculate budget consumed by the incident. Add to post-incident review.

### 10.4 Monthly Error Budget Review

On the 1st of each month, the super-boss generates a report:

```
=== Error Budget Monthly Report (April 2026) ===

Services within SLO: 12/14 (85.7%)
Services > 50% budget: 10/14
Services < 20% budget: 1/14 (Kafka)
Services exhausted: 0/14

Biggest budget consumers:
  Kafka        -- consumed 65% of budget (3 incidents)
  cc-connect   -- consumed 22% of budget (1 incident: NodeJS upgrade)
  sing-box     -- consumed 18% of budget (intermittent DNS failure)

Budget recovery trend: Improving (last 7d better than previous 7d)

Recommendations:
  1. Kafka: investigate consumer lag spikes, consider partition rebalance tuning.
  2. cc-connect: regression from NodeJS upgrade resolved, monitor for 7 more days.
  3. Update SLO targets for Grafana (consistently >99.5%, consider moving to Tier-2).
```

---

## Appendix A: Recording Rules Example

```yaml
groups:
  - name: slo-rules
    rules:
      # Per-service good/valid event totals
      - record: job:slo_good_events:rate_5m
        expr: sum(rate(good_events_total[5m])) by (job, cluster)

      - record: job:slo_valid_events:rate_5m
        expr: sum(rate(valid_events_total[5m])) by (job, cluster)

      # Error budget remaining (ratio)
      - record: job:slo_budget_remaining:ratio_30d
        expr: |
          clamp_min(
            1 - (
              (1 - (sum(rate(good_events_total[30d])) by (job) / sum(rate(valid_events_total[30d])) by (job)))
              / on(job) group_left slo_target
              (1 - slo_target{job!=""})
            ),
            0
          )

      # Burn rate
      - record: job:slo_burn_rate:5m
        expr: |
          (1 - (sum(rate(good_events_total[5m])) by (job) / sum(rate(valid_events_total[5m])) by (job)))
          / on(job) group_left slo_target
          (1 - slo_target{job!=""})
```

## Appendix B: Prometheus Target Info

Error budget metrics are computed in `prometheus-server` (deployed per-cluster or centrally). The Prometheus instance must have:

- `--storage.tsdb.retention.time=60d` (at least 2x SLO window)
- Sufficient disk: estimate 1-2 GB per service per month for high-cardinality metrics.

For recording rules, a dedicated `slo` rule group runs every 60s.

## Appendix C: Budget Visualization Formula

Grafana query for budget remaining gauge:

```promql
# Budget remaining as percentage (0-100)
clamp_min(
  job:slo_budget_remaining:ratio_30d{job="$service"} * 100,
  0
)
```

Thresholds (in Grafana panel config):

| Color | Range | Meaning |
|-------|-------|---------|
| Green | 50 - 100 | Healthy |
| Yellow | 20 - 50 | At risk |
| Red | 0 - 20 | Critical |
| Dark red | 0 | Exhausted |
