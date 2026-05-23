---
decision: 稍后做
---

# Incident Severity Tracking for Infra Services

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Define incident severity levels, tracking methodology, frequency aggregation, and MTTR per class for all managed infra services.

---

## Table of Contents

1. [Principles](#1-principles)
2. [Severity Classification](#2-severity-classification)
3. [Incident Taxonomy](#3-incident-taxonomy)
4. [Tracking Infrastructure](#4-tracking-infrastructure)
5. [Frequency Tracking](#5-frequency-tracking)
6. [MTTR Tracking](#6-mttr-tracking)
7. [Grafana Dashboards](#7-grafana-dashboards)
8. [Review Cadence](#8-review-cadence)
9. [Operational Runbook](#9-operational-runbook)

---

## 1. Principles

### 1.1 Why Severity Tracking

Incident severity tracking converts subjective "this feels bad" judgments into objective, measurable classifications. Without consistent severity labels, incident reviews produce noise, trend analysis is meaningless, and resource allocation for reliability work becomes guesswork.

### 1.2 Design Goals

1. **Consistent classification** -- same incident type gets same severity every time, regardless of who is on call.
2. **Actionable thresholds** -- severity dictates response SLA, escalation path, and post-incortem requirements.
3. **Trendable data** -- severity-tagged incidents feed frequency and MTTR dashboards over rolling windows.
4. **Low friction** -- tagging takes <30 seconds at incident declaration, not a paperwork exercise.

### 1.3 Data Flow

```
Incident declared → severity tag assigned → timer starts
    ↓
Incident resolved → severity tag confirmed → timer stops
    ↓
Post-incident → tag reviewed (maybe adjusted) → stored in ClickHouse
    ↓
Dashboards → frequency per severity / MTTR per class
```

### 1.4 Severity vs Priority vs Impact

| Concept | Definition | Who Sets It |
|---------|-----------|-------------|
| **Severity** | Technical impact class (P0-P4) | On-call engineer at declaration |
| **Priority** | Business urgency (Urgent/High/Medium/Low) | determined from severity + blast radius |
| **Impact** | Specific user-facing or data consequence | Assessed during response, feeds severity calibration |

Severity drives everything downstream: response SLA, escalation, notification channel, post-incortem requirement, and tracking aggregation.

---

## 2. Severity Classification

### 2.1 Severity Levels

| Severity | Label | Definition | Response SLA | Notification |
|----------|-------|-----------|-------------|--------------|
| **P0** | Critical | Complete service outage, data loss in progress, or security breach. All users affected. | < 5 min acknowledge | 飞书群 @all + TTS phone call |
| **P1** | High | Major feature degraded, partial outage affecting >10% of users, or data at risk. | < 15 min acknowledge | 飞书群 @oncall |
| **P2** | Medium | Minor degradation, single-user issue, non-critical feature broken. No data loss risk. | < 1 hr (business hours) | 飞书 ticket + service owner mention |
| **P3** | Low | Cosmetic issue, non-prod environment, documentation gap, monitoring blind spot. | < 1 business day | Daily digest report |
| **P4** | Trivial | Self-service fix, known workaround exists, informational. | Best effort | None |

### 2.2 Decision Matrix

Use this matrix to determine severity at incident declaration time:

| | All users affected | >10% of users affected | Single user / edge case | No users affected |
|---|---|---|---|---|
| **Data loss / corruption** | P0 | P0 | P1 | P2 |
| **Service fully down** | P0 | P1 | P2 | P3 |
| **Feature degraded (slow)** | P1 | P2 | P2 | P3 |
| **Feature degraded (cosmetic)** | P2 | P2 | P3 | P3 |
| **Monitoring gap / docs** | P3 | P3 | P3 | P4 |

### 2.3 Escalation Rules

| Condition | Action |
|-----------|--------|
| P0 not acknowledged in 5 min | Auto-escalate to team lead via TTS |
| P1 not acknowledged in 15 min | Auto-escalate to on-call backup |
| P0 duration exceeds 30 min | Super-boss dispatches diagnostic agent + schedules bridge call |
| Same service has 3+ P1 incidents in 7 days | Auto-escalate service to P0 monitoring tier |
| Incident misclassified >2 tiers | Retroactive review, severity calibration session |

### 2.4 De-escalation (Severity Reduction)

An incident may be de-escalated during response if initial assessment was too conservative:

- P0 → P1: when data loss is confirmed prevented, but service is still degraded.
- P1 → P2: when a workaround is deployed and <10% of users are affected.
- P2 → P3: when root cause is identified as non-critical (e.g., cosmetic bug).

De-escalation must be approved by the on-call engineer + one peer. All severity changes are logged with timestamp and reason.

### 2.5 Severity Examples from Our Stack

| Incident | Severity | Rationale |
|----------|----------|-----------|
| cc-connect process crash, no messages delivered for 10+ min | P0 | Complete service outage, all users affected |
| PostgreSQL-16 replication lag > 5 min | P1 | Data at risk, partial read degradation |
| sing-box proxy tunnel down, 15% of users affected | P1 | >10% users affected, core feature degraded |
| Grafana dashboard fails to load | P2 | Non-critical tooling, no user-facing impact |
| ClickHouse query latency p99 > 5s for 1 user | P2 | Single user affected, no data loss |
| Build runner job queue backlog > 30 min | P2 | Non-critical, CI pipeline delay |
| ACR mirror pull fails for 1 image tag | P3 | Known workaround (pull from upstream), edge case |
| Error budget burn rate > 14x for 2 min (auto-resolved) | P3 | No user impact, monitoring detection only |
| Documentation outdated in runbook | P4 | No operational impact |

---

## 3. Incident Taxonomy

### 3.1 Classification Dimensions

Every incident is tagged with four dimensions:

1. **Severity** (P0-P4) -- from section 2
2. **Service** -- which infra component failed
3. **Cause** -- root cause category
4. **Detection** -- how the incident was discovered

### 3.2 Cause Categories

| Category | Code | Examples |
|----------|------|----------|
| Resource Exhaustion | RESOURCE | Disk full, OOM, EPHEMERAL_PORT_EXHAUSTION, inode exhaustion |
| Configuration | CONFIG | Wrong env var, misplaced YAML, incorrect ACL, typo in config |
| Dependency Failure | DEP | Upstream API down, Docker Hub rate limit, DNS failure, TLS expiry |
| Code/Deploy Bug | CODE | Regression from deploy, unhandled exception, race condition |
| Network Partition | NET | BGP issue, firewall rule change, Tailscale flake, MTU mismatch |
| Data Corruption | DATA | Corrupt WAL, index rebuild failure, partial write on crash |
| Human Error | HUMAN | Accidental rm -rf, wrong kubectl context, fat-finger SQL |
| Capacity | CAP | Traffic spike exceeding provisioned capacity, slow growth accumulation |
| Security | SEC | CVE exploit attempt, unauthorized access, token leak |
| Monitoring Gap | MON | Incident detected by user before monitoring, false negative |

### 3.3 Detection Methods

| Method | Code | Notes |
|--------|------|-------|
| Alert | ALERT | Prometheus alert fired |
| User Report | USER | User reported issue via 飞书 |
| Patrol | PATROL | kyb patrol script detected |
| Automated Self-Heal | SELF | Healthcheck auto-restarted, resolved before human saw |
| Manual | MANUAL | Engineer noticed during routine work |

### 3.4 Severity Weight for Trend Calculations

For trend analysis, each severity level has a numeric weight:

| Severity | Weight | Rationale |
|----------|--------|-----------|
| P0 | 1000 | Complete outage, escalates everything |
| P1 | 100 | Major degradation |
| P2 | 10 | Minor degradation |
| P3 | 1 | Low impact |
| P4 | 0.1 | Trivial |

Weighted incident count = `sum(weight per incident)` over the window. This prevents one P0 from drowning in a sea of P3s while still making trends visible.

---

## 4. Tracking Infrastructure

### 4.1 Incident Record Schema (ClickHouse)

```sql
CREATE TABLE infra.incident_log (
    event_time     DateTime64(3)   DEFAULT now64(),
    incident_id    String,          -- unique ID, e.g. "INC-20260523-001"
    severity       Enum8('P0'=0, 'P1'=1, 'P2'=2, 'P3'=3, 'P4'=4),
    service        LowCardinality(String),  -- from service catalog
    cluster        LowCardinality(String),  -- mac-orbstack, aliyun, office
    cause          LowCardinality(String),  -- from cause categories
    detection      LowCardinality(String),  -- from detection methods
    title          String,                  -- brief description
    declared_at    DateTime64(3),           -- when incident was declared
    resolved_at    DateTime64(3),           -- when resolution confirmed
    duration_sec   Int32,                   -- resolved_at - declared_at
    acknowledged_at DateTime64(3),          -- first human ack
    mtta_sec       Int32,                   -- acknowledged_at - declared_at
    resolved_by    String,                  -- engineer / system that resolved
    tag_changes    Array(Tuple(DateTime64(3), String, String)),  -- severity changes log
    notes          String                   -- free text post-incident notes
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, incident_id);
```

### 4.2 Prometheus Metrics

For real-time dashboards, expose incident state as Prometheus metrics:

```yaml
metrics:
  - name: infra_incident_active
    type: gauge
    description: "1 if an incident is currently active for this service, 0 otherwise"
    labels: [incident_id, severity, service, cluster]

  - name: infra_incident_total
    type: counter
    description: "Total incidents declared (accumulates per severity)"
    labels: [severity, service, cluster]

  - name: infra_incident_duration_seconds
    type: histogram
    description: "Incident duration in seconds"
    labels: [severity, service]
    buckets: [60, 300, 900, 1800, 3600, 7200, 14400, 28800, 86400]

  - name: infra_incident_mtta_seconds
    type: histogram
    description: "Mean time to acknowledge in seconds"
    labels: [severity, service]
    buckets: [60, 300, 900, 1800, 3600]
```

### 4.3 Recording Rules

```promql
# P0 incident frequency (last 30 days) per service
- record: service:p0_incidents:count_30d
  expr: sum(increase(infra_incident_total{severity="P0"}[30d])) by (service, cluster)

# MTTR per severity (rolling 30d average)
- record: service:mttr_seconds:p50_30d
  expr: histogram_quantile(0.50, sum(rate(infra_incident_duration_seconds_bucket[30d])) by (le, severity, service))

- record: service:mttr_seconds:p90_30d
  expr: histogram_quantile(0.90, sum(rate(infra_incident_duration_seconds_bucket[30d])) by (le, severity, service))

- record: service:mttr_seconds:p99_30d
  expr: histogram_quantile(0.99, sum(rate(infra_incident_duration_seconds_bucket[30d])) by (le, severity, service))
```

### 4.4 Alert Rules (Meta-Incidents)

Alert when incident patterns cross thresholds:

```yaml
groups:
  - name: incident-meta
    rules:
      # Too many P0s in a week
      - alert: TooManyP0Incidents
        expr: sum(increase(infra_incident_total{severity="P0"}[7d])) > 3
        for: 1h
        annotations:
          severity: page
          summary: "3+ P0 incidents in the last 7 days — reliability review required"

      # MTTR for P1 creeping up
      - alert: MTTRDegradationP1
        expr: |
          histogram_quantile(0.90, sum(rate(infra_incident_duration_seconds_bucket{severity="P1"}[7d])) by (le))
          > histogram_quantile(0.90, sum(rate(infra_incident_duration_seconds_bucket{severity="P1"}[30d])) by (le)) * 1.5
        for: 6h
        annotations:
          severity: ticket
          summary: "P1 p90 MTTR increased 50% over 7-day window vs 30-day baseline"

      # Single service having multiple incidents
      - alert: IncidentsClusterBurst
        expr: sum(increase(infra_incident_total[24h])) by (service) > 5
        for: 5m
        annotations:
          severity: page
          summary: "Service {{ $labels.service }} had 5+ incidents in 24h"

      # Incident without acknowledgement for too long
      - alert: IncidentNotAcknowledged
        expr: time() - infra_incident_declared_timestamp{severity=~"P0|P1"} > 900
        annotations:
          severity: page
          summary: "P0/P1 incident {{ $labels.incident_id }} not acknowledged for 15+ minutes"
```

### 4.5 Tagging Automation

To reduce manual effort, automate severity assignment where possible:

| Signal | Auto-Assigned Severity | Condition |
|--------|----------------------|-----------|
| Error budget burn rate > 14x for 5 min | P0 | Auto-create incident record |
| Error budget burn rate > 6x for 10 min | P1 | Auto-create incident record |
| cc-connect process down | P0 | Alert → incident creation |
| Service `up == 0` for > 2 min | P1 → P0 if not resolved in 5 min | Escalate automatically |
| Disk > 90% | P2 | Auto-create, no page |
| Self-heal action triggered | P3 | Logged as informational |
| User report via 飞书 bot | P2 (may escalate) | Human must confirm severity |

Automation creates the record with a default severity. On-call engineer must confirm or adjust within 2 minutes of acknowledgement.

---

## 5. Frequency Tracking

### 5.1 Key Metrics

| Metric | Definition | Window | Display |
|--------|-----------|--------|---------|
| Incident Count | Raw count of incidents per severity | 7d, 30d, 90d | Bar chart |
| Incident Rate | Incidents per day | 30d rolling | Line chart |
| Mean Time Between Incidents (MTBI) | `window_duration / count` | 30d | Single stat |
| Severity Distribution | % breakdown by severity | 30d | Pie chart |
| Cause Distribution | % breakdown by cause category | 30d | Bar chart |

### 5.2 Target Thresholds

| Severity | Max per 30 days | Max per 7 days | Action if exceeded |
|----------|-----------------|----------------|--------------------|
| P0 | 2 | 1 | Mandatory post-incident review + root cause analysis |
| P1 | 8 | 3 | Service-specific reliability review |
| P2 | 20 | 8 | Monthly trend review, watch for escalation |
| P3 | No limit (informational) | - | Weekly digest only |
| P4 | No limit | - | Monthly summary only |

### 5.3 Frequency Dashboard

```
=== Incident Frequency (Last 30 Days) ===

P0: ████░░░░░░░░░░░░░░░░  2 incidents  (0.07/day)
P1: ██████████████░░░░░░  8 incidents  (0.27/day)
P2: ████████████████████  20 incidents (0.67/day)
P3: ████████████████████  45 incidents (1.50/day)

MTBI (all severities): 14.3 hours
MTBI (P0+P1 only):     2.7 days

Most frequent causes:
  RESOURCE ██████████████████████ 35%
  CONFIG   ██████████████░░░░░░░░ 25%
  DEP      ████████░░░░░░░░░░░░░░ 15%
  CODE     ██████░░░░░░░░░░░░░░░░ 12%
  HUMAN    ████░░░░░░░░░░░░░░░░░░ 8%
  Other    ██░░░░░░░░░░░░░░░░░░░░ 5%

Most affected services:
  PostgreSQL      █████████████████████ 5 incidents
  sing-box        ██████████████░░░░░░░░ 4 incidents
  cc-connect       ██████████░░░░░░░░░░░░ 3 incidents
```

### 5.4 Cause vs Severity Heatmap

```
Cause \ Severity     P0    P1    P2    P3    Total
─────────────────────────────────────────────────
RESOURCE             -     2     5     8      15
CONFIG               -     1     4     6      11
DEP                  1     1     3     4       9
CODE                 1     2     2     3       8
HUMAN                -     1     2     2       5
NET                  -     1     1     2       4
DATA                 1     -     -     1       2
SEC                  -     -     -     1       1

Monthly scorecard:
  RESOURCE incidents: 15 (HIGHEST) → action: audit disk/memory provisioning
  MTBI improving: 12h → 14h over last 2 weeks ✓
```

### 5.5 Burn Rate Integration

Connect incident frequency to error budget consumption:

- Each P0 incident should map to an error budget consumption entry.
- After incident resolution, calculate `budget_consumed_ratio = duration_sec / total_budget_sec`.
- If budget consumed > 10% per incident, flag for review.
- If budget consumed > 50% cumulative in a month, trigger incident prevention work.

---

## 6. MTTR Tracking

### 6.1 MTTR Decomposition

MTTR is not a single number. Break it down into actionable sub-metrics:

| Phase | Metric | Definition | Target |
|-------|--------|-----------|--------|
| **Detection** | TTD (Time to Detect) | Incident start → first alert or report | < 1 min for P0, < 5 min for P1 |
| **Acknowledgment** | MTTA (Mean Time to Acknowledge) | Incident declared → first human ack | < 5 min for P0, < 15 min for P1 |
| **Diagnosis** | TTDx (Time to Diagnose) | Acknowledged → root cause identified | < 15 min for P0 |
| **Resolution** | TTR (Time to Resolve) | Root cause identified → service restored | < 30 min for P0 |
| **Total** | MTTR (Mean Time to Recover) | Incident start → service fully restored | Varies by severity |

```
Timeline:

[DETECTION WINDOW]   [ACK WINDOW]    [DIAGNOSIS WINDOW]   [RESOLUTION WINDOW]
├─────────────────────┼───────────────┼─────────────────────┼─────────────────┤
incident start     first alert    acknowledged       root cause found     resolved
    TTD ──────────►│  MTTA ──────►│   TTDx ──────────►│    TTR ──────────►│
    ◄────────────────────────── MTTR ────────────────────────────────────►│
```

### 6.2 MTTR Targets by Severity

| Severity | MTTA | TTDx | TTR | Total MTTR |
|----------|------|------|-----|-----------|
| P0 | < 5 min | < 15 min | < 30 min | < 50 min |
| P1 | < 15 min | < 30 min | < 60 min | < 105 min |
| P2 | < 1 hr | < 2 hr | < 4 hr | < 7 hr |
| P3 | < 1 day | < 2 days | < 3 days | < 6 days |

### 6.3 MTTR Dashboard

```
=== MTTR by Severity (Last 30 Days) ===

P0:  MTTA  3m ┤████████░░░░   p50: 2m   p90: 5m   p99: 12m
     TTDx 11m ┤█████████████████░░  p50: 8m   p90: 18m  p99: 32m
     TTR  22m ┤███████████████████░  p50: 15m  p90: 35m  p99: 55m
     Total 36m ┤█████████████████████ p50: 25m  p90: 58m  p99: 99m
     ✓ Below target (50m)

P1:  MTTA 12m ┤█████████████░░   p50: 8m   p90: 22m  p99: 45m
     TTDx 25m ┤█████████████████░  p50: 18m  p90: 40m  p99: 75m
     TTR  45m ┤███████████████████  p50: 35m  p90: 75m  p99: 120m
     Total 82m ┤██████████████████  p50: 61m  p90: 137m p99: 240m
     ✓ Below target (105m)

P2:  Total 4.2h ┤███████████░░░░   p50: 3.1h  p90: 6.5h  p99: 12h
     ✓ Below target (7h)

=== MTTR Trend (Rolling 30d) ===

Period        P0 MTTR    P1 MTTR    P2 MTTR    P3 MTTR
────────────  ─────────  ─────────  ─────────  ─────────
Apr 24-30     45m        90m        5.2h       3.1d
May 1-7       38m        85m        4.8h       2.9d
May 8-14      42m        78m        4.1h       2.5d
May 15-21     36m        82m        4.2h       2.2d
────────────  ─────────  ─────────  ─────────  ─────────
Trend          ↓ -20%     ↓ -9%      ↓ -19%     ↓ -29%   ✓ All improving

=== MTTR by Service (P0+P1 only, Last 30d) ===

Service          Count   Avg MTTR     p90 MTTR   Trend
cc-connect       2       28m          35m        stable
PostgreSQL-16    2       45m          52m        stable
sing-box         2       112m         180m       worsening ↑
feishu-bridge    1       15m          15m        stable
```

### 6.4 MTTR by Cause Category

```
=== MTTR by Cause (All Severities, Last 30d) ===

Cause         Avg MTTR   Count   Notes
──────        ─────────  ─────   ─────
CONFIG        22m        11      Fastest to fix — config push or rollback
SELF-HEAL     5m          8      Auto-resolved, almost zero human time
RESOURCE      45m        15      Requires manual intervention (disk cleanup, scale up)
CODE          120m        8      Requires rollback + deploy, potentially hotfix
DEP           35m         9      Dependent on upstream, limited control
HUMAN         15m         5      Undo and apologize
NET           60m         4      Often requires network team or Tailscale debug
DATA          180m        2      Slowest — recovery, validation, re-replication
```

### 6.5 MTTR Improvement Targets

| Quarter | P0 MTTR Target | P1 MTTR Target | Key Initiative |
|---------|---------------|---------------|----------------|
| Q2 2026 (current) | < 50 min | < 105 min | Baseline measurement |
| Q3 2026 | < 35 min | < 75 min | Automated self-heal playbooks |
| Q4 2026 | < 25 min | < 60 min | Runbook automation + supervised auto-remediation |
| Q1 2027 | < 15 min | < 45 min | Full auto-remediation for top-5 incident causes |

---

## 7. Grafana Dashboards

### 7.1 Dashboard: Incident Overview

**Panel 1: Active Incidents**
- Current active incidents by severity (table or stat)
- Color-coded: red for P0, orange for P1, yellow for P2, gray for P3/P4
- Auto-refresh every 15s

**Panel 2: Incident Frequency (30d)**
- Stacked bar chart: incidents per day, stacked by severity
- Horizontal threshold lines for target limits (P0 ≤ 2/month, P1 ≤ 8/month)

**Panel 3: Severity Distribution (30d)**
- Pie chart: incident count by severity
- Secondary pie: incident count by cause (for selected severity)

**Panel 4: MTTR Gauges**
- Per-severity gauge showing current 30d rolling MTTR vs target
- Green zone: below target
- Yellow zone: within 25% of target
- Red zone: exceeding target

**Panel 5: MTTR Trend (30d)**
- Multi-line chart: p50/p90/p99 MTTR per severity over 30 days
- Annotations for significant changes (new runbook deployed, new team member)

**Panel 6: MTTR by Service**
- Horizontal bar chart: services sorted by MTTR (descending)
- Color by severity mix

**Panel 7: Cause Heatmap**
- Cause category × severity level heatmap
- Cell color intensity = incident count

**Panel 8: Service Reliability Score**
- Composite score per service based on:
  - `score = 100 - (p0_weighted_count * 5 + p1_weighted_count * 2 + p2_count * 0.5)`
  - Clamped to [0, 100]
  - Color: green > 80, yellow 50-80, red < 50

### 7.2 Dashboard: Post-Incident Review Feed

A chronological list of recent incidents (last 7 days) with:

```
┌──────────────────────────────────────────────────────┐
│ INC-20260523-001 │ P0 │ cc-connect │ RESOURCE         │
│ 2026-05-23 14:32 - 15:08 (36m)                        │
│ Summary: OOM kill caused by memory leak in queue      │
│ Action: Added memory limit, set up OOM alert          │
│ [Review Doc] [Grafana Link]                           │
├──────────────────────────────────────────────────────┤
│ INC-20260522-003 │ P1 │ PostgreSQL-16 │ CONFIG         │
│ 2026-05-22 09:15 - 09:45 (30m)                        │
│ Summary: max_connections too low for batch job spike  │
│ Action: Increased max_connections, added PGBouncer    │
│ [Review Doc] [Grafana Link]                           │
└──────────────────────────────────────────────────────┘
```

### 7.3 Dashboard Variables

```yaml
variables:
  - name: severity
    type: custom
    options: [All, P0, P1, P2, P3, P4]
    default: All

  - name: service
    type: query
    query: label_values(infra_incident_total, service)
    multi: true

  - name: cluster
    type: custom
    options: [All, mac-orbstack, aliyun, office]
    default: All

  - name: cause
    type: custom
    options: [All, RESOURCE, CONFIG, DEP, CODE, NET, DATA, HUMAN, CAP, SEC, MON]
    default: All

  - name: window
    type: custom
    options: [7d, 30d, 90d]
    default: 30d
```

### 7.4 Scheduled Report

A monthly email / 飞书 post with summary:

```
=== Incident Report: April 2026 ===

Highlights:
- Total incidents: 45 (vs 52 last month, ↓13%)
- P0 incidents: 2 (vs 3 last month, ↓33%)
- P1 incidents: 8 (vs 10 last month, ↓20%)
- MTTR improved: P0 36m (↓20% MoM), P1 82m (↓9% MoM)

Top causes:
1. RESOURCE -- 15 incidents (33%)
2. CONFIG -- 11 incidents (24%)
3. DEP -- 9 incidents (20%)

Worst performers:
1. sing-box -- MTTR 112m, 2 P0 incidents
2. PostgreSQL-16 -- 5 incidents, 2 P1

Recommendations:
1. sing-box: investigate DNS fallback, add redundant tunnel
2. RESOURCE: audit disk provisioning across all clusters
3. CONFIG: add config validation CI gate
```

---

## 8. Review Cadence

### 8.1 Post-Incident Review Requirements

| Severity | Review Required | Deadline | Review Type |
|----------|----------------|----------|-------------|
| P0 | Mandatory | Within 48 hours | Full post-mortem with written report |
| P1 | Mandatory | Within 5 business days | Written report or structured review doc |
| P2 | Optional | Within 10 business days | Brief notes in incident record |
| P3 | Not required | - | Logged in monthly summary only |
| P4 | Not required | - | None |

### 8.2 Post-Mortem Template

For P0 and selected P1 incidents:

```markdown
## Post-Mortem: INC-XXXXXX

### Incident Summary
- **Title:** <one-line description>
- **Date:** <date>
- **Duration:** <X hours X minutes>
- **Severity:** P0 → (list any severity changes) → P0
- **Services affected:** <list>
- **Users affected:** <estimated count or percentage>

### Timeline
| Time (UTC+8) | Event |
|-------------|-------|
| HH:MM | Incident started |
| HH:MM | First alert fired |
| HH:MM | Incident acknowledged |
| HH:MM | Root cause identified |
| HH:MM | Mitigation applied |
| HH:MM | Service restored |
| HH:MM | Monitoring confirmed green |

### Root Cause
<2-3 sentence description of what went wrong>

### Contributing Factors
- Factor 1 (e.g., no alert for this condition)
- Factor 2 (e.g., runbook was outdated)

### Impact
- **Error budget consumed:** X% of service budget
- **Data loss:** None / <description>
- **User-visible effect:** <description>

### Action Items
| Action | Owner | Deadline | Tracking |
|--------|-------|----------|----------|
| Add alert for <condition> | @name | YYYY-MM-DD | Issue # |
| Update runbook for <procedure> | @name | YYYY-MM-DD | Issue # |

### Lessons Learned
- What went well:
- What went wrong:
- What we will do differently:
```

### 8.3 Weekly Review

Every Monday, the patrol agent produces a weekly incident digest:

```
=== Weekly Incident Digest (May 18 - May 24) ===

New incidents: 12 (P0: 1, P1: 2, P2: 4, P3: 5)
Pending reviews: 1 (INC-20260523-001, due May 25)
Open action items: 7 (3 overdue ⚠)

MTTR this week vs last 4 weeks:
  P0: 42m vs 38m (baseline) → ⚠ slight increase
  P1: 90m vs 85m (baseline) → stable

Focus for this week:
  1. Complete P0 review for INC-20260523-001
  2. Clear overdue action items
  3. Investigate sing-box MTTR worsening
```

### 8.4 Monthly Review

On the 1st of each month, the super-boss generates:

1. **Severity distribution** report (frequency, MTTR, causes)
2. **Error budget impact** from incidents (budget consumed per service)
3. **Reliability score** per service (trend over 3 months)
4. **Top-3 improvement initiatives** for the coming month
5. **Quarterly SLO/severity target** adjustment recommendations

### 8.5 Quarterly Calibration

Every quarter (or when classification drift is suspected):

1. Audit last 30 incidents for severity classification correctness.
2. If >20% are misclassified by 1+ tiers, retrain the team with calibration session.
3. Review severity thresholds: are they still appropriate?
4. Adjust cause categories if new patterns emerge.
5. Update this document with any changes.

---

## 9. Operational Runbook

### 9.1 Declaring an Incident

1. Identify the issue and assess against the decision matrix (Section 2.2).
2. Assign a severity (P0-P4). When in doubt, start higher and de-escalate.
3. Create the incident record:
   - Via alert auto-creation (if automated)
   - Via 飞书 bot: `/incident declare P1 cc-connect "API latency spike"`
   - Via manual ClickHouse insert (fallback)
4. Start the timer: `declared_at = now()`.
5. Notify the appropriate channel (Section 2.1).
6. Begin response.

### 9.2 Resolving an Incident

1. Confirm service is restored (monitoring shows green, test passes).
2. Set `resolved_at = now()`.
3. Confirm severity classification (adjust if needed).
4. Calculate `duration_sec = resolved_at - declared_at`.
5. Add brief notes about resolution.
6. Trigger post-incident review if required (Section 8.1).

### 9.3 Managing Severity Changes

If severity changes during the incident:

1. Log the change: `tag_changes = [(now(), "P1", "P0", "disk full detected, data at risk")]`.
2. The `severity` field always reflects the **final** classification.
3. The `tag_changes` array preserves the history for accurate MTTR per initial-severity analysis.

### 9.4 Adding a New Service

1. Register service in the service catalog (see `error-budget.md` Section 2.1).
2. Add the service to Prometheus `infra_incident_total` metric label set.
3. Add Grafana dashboard panels (or they auto-populate via label discovery).
4. Define service-specific severity thresholds if default matrix doesn't apply.
5. Add the service to weekly/monthly report generation.

### 9.5 Handling False Positives

If an incident record was created but it was a false positive:

1. Set `severity = 'P4'` and `notes = 'false positive'`.
2. Do not delete the record — false positive rate is a useful metric.
3. In dashboards, filter P4 false positives separately from real incidents.

### 9.6 Self-Heal Events

Events resolved by automated self-heal (healthcheck restart, etc.):

- Logged as P3 incidents with `detection = 'SELF'`.
- The `duration_sec` is typically very short (< 60s).
- Tracked separately in dashboards: count of self-heal events vs human-required incidents.
- Target: self-heal rate > 90% of all automated-detectable failure modes.
- If self-heal rate drops below 80%, investigate why automated recovery is failing.

### 9.7 Incident Record Lifecycle

```
STATE:   Declared → Acknowledged → Diagnosed → Resolved → Reviewed → Closed
         │              │              │           │           │
         │ set          │ set          │ set       │ set       │ post-mortem
         │ declared_at  │ acknowledged │ cause     │ resolved  │ completed
         │ severity     │ _at          │ _at       │ _at       │
         │              │              │           │           │
         ▼              ▼              ▼           ▼           ▼
METRIC:  count++       mtta_calc      ttdx_calc   mttr_calc   action_items
```

---

## Appendix A: SQL for ClickHouse Incident Queries

```sql
-- Incident count per severity (last 30 days)
SELECT
    severity,
    count() AS incident_count
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY severity
ORDER BY severity;

-- MTTR per severity (last 30 days)
SELECT
    severity,
    avg(duration_sec) AS avg_mttr_sec,
    quantile(0.50)(duration_sec) AS p50_mttr_sec,
    quantile(0.90)(duration_sec) AS p90_mttr_sec,
    quantile(0.99)(duration_sec) AS p99_mttr_sec
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND resolved_at IS NOT NULL
GROUP BY severity
ORDER BY severity;

-- MTTR by cause (last 30 days)
SELECT
    cause,
    count() AS incident_count,
    avg(duration_sec) AS avg_mttr_sec
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND resolved_at IS NOT NULL
GROUP BY cause
ORDER BY avg_mttr_sec DESC;

-- Most affected services (last 30 days)
SELECT
    service,
    count() AS incident_count,
    countIf(severity = 'P0') AS p0_count,
    countIf(severity = 'P1') AS p1_count,
    avg(duration_sec) AS avg_mttr_sec
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY service
ORDER BY incident_count DESC;

-- Detection method distribution
SELECT
    detection,
    count() AS incident_count
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY detection
ORDER BY incident_count DESC;

-- Incident count trend (daily)
SELECT
    toDate(event_time) AS day,
    severity,
    count() AS incident_count
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day, severity
ORDER BY day, severity;

-- Self-heal rate
SELECT
    countIf(detection = 'SELF') AS self_healed,
    count() AS total,
    round(countIf(detection = 'SELF') / count() * 100, 1) AS self_heal_pct
FROM infra.incident_log
WHERE event_time >= now() - INTERVAL 30 DAY;
```

## Appendix B: Prometheus Alert Rule for Incident Record Automation

```yaml
groups:
  - name: incident-auto-create
    rules:
      - alert: AutoCreateP0Incident
        expr: |
          # cc-connect down for > 30s
          absent(up{job="cc-connect"} == 1) for 30s
        labels:
          severity: P0
          service: cc-connect
          detection: ALERT
        annotations:
          summary: "Auto-created P0 incident: cc-connect is down"

      - alert: AutoCreateP1Incident
        expr: |
          # Error budget burning fast
          (
            (1 - (sum(rate(good_events_total{job="postgresql-16"}[1h])) / sum(rate(valid_events_total{job="postgresql-16"}[1h]))))
            > (6 * (1 - 0.999))
          )
          and
          (
            (1 - (sum(rate(good_events_total{job="postgresql-16"}[5m])) / sum(rate(valid_events_total{job="postgresql-16"}[5m]))))
            > (6 * (1 - 0.999))
          )
        labels:
          severity: P1
          service: postgresql-16
          detection: ALERT
        annotations:
          summary: "Auto-created P1 incident: postgresql-16 error budget burning at 6x"
```

## Appendix C: ClickHouse Materialized View for MTTR Rollups

```sql
CREATE MATERIALIZED VIEW infra.incident_mttr_hourly
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, severity, service)
AS SELECT
    toStartOfHour(event_time) AS hour,
    severity,
    service,
    count() AS incident_count,
    avgState(duration_sec) AS avg_mttr_sec,
    quantileState(0.50)(duration_sec) AS p50_mttr_sec,
    quantileState(0.90)(duration_sec) AS p90_mttr_sec,
    quantileState(0.99)(duration_sec) AS p99_mttr_sec
FROM infra.incident_log
WHERE resolved_at IS NOT NULL
GROUP BY hour, severity, service;
```

Query the rollup:

```sql
SELECT
    hour,
    severity,
    incident_count,
    avgMerge(avg_mttr_sec) AS avg_mttr,
    quantileMerge(p50_mttr_sec) AS p50,
    quantileMerge(p90_mttr_sec) AS p90,
    quantileMerge(p99_mttr_sec) AS p99
FROM infra.incident_mttr_hourly
WHERE hour >= now() - INTERVAL 30 DAY
GROUP BY hour, severity
ORDER BY hour, severity;
```

---

## Appendix D: 飞书 Bot Integration

For low-friction incident declaration:

```
/incident declare <severity> <service> "<title>"
  → Creates incident record in ClickHouse
  → Posts to incident channel
  → Starts timer

/incident resolve <incident_id> "<resolution notes>"
  → Sets resolved_at
  → Stops timer
  → Posts summary to incident channel

/incident status <incident_id>
  → Shows current state, duration, severity

/incident escalate <incident_id>
  → Escalates one severity level
  → Posts to @all channel if now P0
```

The 飞书 bot webhook handler writes directly to ClickHouse and posts responses to the incident management channel.

---

## Appendix E: Service Reliability Score Formula

Used in dashboard Panel 8 and monthly reports:

```
weighted_incidents =
    P0_count * 100 +
    P1_count * 10 +
    P2_count * 1 +
    P3_count * 0.1

mttr_penalty =
    if (P0_avg_mttr > P0_target) then (P0_avg_mttr / P0_target - 1) * 20 else 0

base_score = max(0, 100 - weighted_incidents * 2 - mttr_penalty)

reliability_score = clamp(base_score, 0, 100)
```

| Score Range | Label |
|-------------|-------|
| 90-100 | Excellent |
| 70-89 | Good |
| 50-69 | Fair |
| 30-49 | Poor |
| 0-29 | Critical |

A service scoring below 50 for two consecutive months triggers a dedicated reliability improvement project.
