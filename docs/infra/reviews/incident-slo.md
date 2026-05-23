---
decision: 稍后做
---

# Incident Response SLO Compliance Tracking

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Define SLO targets for incident response lifecycle (acknowledgement and resolution), measurement methodology, and compliance tracking per severity.
> **Prerequisite reading:** `docs/infra/reviews/error-budget.md` (SLO framework, severity tiers), `docs/infra/observability-design.md` (overall observability strategy).

---

## Table of Contents

1. [Why Incident Response SLOs](#1-why-incident-response-slos)
2. [SLO Targets](#2-slo-targets)
3. [Alert Lifecycle Model](#3-alert-lifecycle-model)
4. [Measurement Methodology](#4-measurement-methodology)
5. [Instrumentation & Data Pipeline](#5-instrumentation--data-pipeline)
6. [Computation & Recording Rules](#6-computation--recording-rules)
7. [Dashboard](#7-dashboard)
8. [Alerting on SLO Risk](#8-alerting-on-slo-risk)
9. [Reporting & Review](#9-reporting--review)
10. [Operational Runbook](#10-operational-runbook)

---

## 1. Why Incident Response SLOs

### 1.1 Problem Statement

The error budget system (see `error-budget.md`) tracks _service_ reliability: was the service up or down? But it does not track _incident response_ effectiveness: how fast did the team respond?

Two scenarios with identical error budget consumption but very different operational quality:

| Scenario | Service downtime | TTA | TTR | Outcome |
|----------|----------------|-----|-----|---------|
| A | 10 minutes | 30s | 9 min | Fast catch, quick fix |
| B | 10 minutes | 25 min | 35 min | Slow detect, slow fix |

Both consume the same error budget. But Scenario A demonstrates a healthy on-call rotation; Scenario B reveals a detection/response gap that needs attention.

### 1.2 Incident Response SLOs vs. Service SLOs

| Dimension | Service SLO | Incident Response SLO |
|-----------|------------|----------------------|
| **Measures** | Uptime / request success | Human response time |
| **Window** | 30d rolling | 30d rolling |
| **Target** | Per-tier (99.99% / 99.9% / 99.5% / 99.0%) | Per-severity (see below) |
| **Who owns** | Service team | On-call rotation |
| **What it detects** | Reliability debt | Response process debt |

### 1.3 Key Metrics

Three core metrics that define incident response quality:

1. **Time to Acknowledge (TTA):** Time from alert firing to first human acknowledgement. Measures detection + notification + initial response.
2. **Time to Resolve (TTR):** Time from acknowledgement to resolution (alert returns to healthy). Measures diagnosis + mitigation.
3. **SLO Attainment Rate:** Percentage of incidents (within a severity class) that met both TTA and TTR targets over the measurement window.

---

## 2. SLO Targets

### 2.1 Severity Alignment

Severity definitions follow `error-budget.md` Section 4.4:

| Severity | Definition | Example | Response Channel |
|----------|-----------|---------|-----------------|
| **P0** | Critical, user-facing, data loss | cc-connect down, PostgreSQL crash, Kafka partition loss | 飞书群 @all + TTS |
| **P1** | High, degraded but not down | High latency, partial failure, consumer lag | 飞书群 @oncall |
| **P2** | Medium, non-urgent | Slow drift, minor degradation, single-instance failure | 飞书 mention + ticket |
| **P3** | Low, informational | Daily report anomalies, non-critical alerts | Daily digest |

### 2.2 TTA / TTR Targets

| Severity | TTA Target | TTR Target | Attainment Target | Window | Rationale |
|----------|-----------|-----------|-------------------|--------|-----------|
| **P0** | <= 5 min | <= 30 min | >= 99% | 30d rolling | User-facing outage; every second counts |
| **P1** | <= 15 min | <= 2 hr | >= 95% | 30d rolling | Significant degradation; needs fast response |
| **P2** | <= 1 hr | <= 8 hr | >= 90% | 30d rolling | Business-hours response acceptable |
| **P3** | <= 24 hr | <= 5 days | >= 90% | 30d rolling | Next-working-day is fine |

### 2.3 Attainment Calculation

```
SLO Attainment = (incidents meeting BOTH TTA and TTR targets) / (total incidents in severity)
              * 100
```

A single incident that misses either TTA or TTR counts as a non-compliant incident. This is deliberate: a fast acknowledge with slow resolution is still a failure to meet the SLO.

### 2.4 Calendar vs. Business Hours

| Severity | Clock | Notes |
|----------|-------|-------|
| P0 | 24x7 | Always counting |
| P1 | 24x7 | Always counting |
| P2 | Business hours only | Defined as 09:00-18:00 Asia/Shanghai, Mon-Sat |
| P3 | Business hours only | Same as P2 |

A P2 alert that fires at 02:00 counts TTA from 09:00 the same day (or next business day if Sunday). The clock starts from the later of: alert fire time, or next business hour start.

---

## 3. Alert Lifecycle Model

### 3.1 States

```
                    ┌──────────────┐
                    │   FIRING     │
                    │  (unacked)   │
                    └──────┬───────┘
                           │ acknowledge
                           ▼
                    ┌──────────────┐
                    │ ACKNOWLEDGED │
                    └──────┬───────┘
                           │ resolve
                           ▼
                    ┌──────────────┐
                    │  RESOLVED    │
                    │  (closed)    │
                    └──────────────┘
```

**Edge cases:**

| Scenario | How handled |
|----------|-------------|
| Alert auto-resolves before acknowledge | TTA = TTR = fire-to-resolve; marked as "never acknowledged" |
| Alert fires, ack, re-fires, ack again | Each fire-ack-resolve cycle is a separate incident instance |
| Alert fires multiple times in a cascade | Grouped by Alertmanager inhibition rules; first fire to last resolve is the incident window |
| Maintenance window silences | Alert never fires; not counted as incident |

### 3.2 Incident Record Schema

Each incident captured as a ClickHouse row:

```sql
CREATE TABLE infra.incident_response_log (
    incident_id      String,         -- UUID, unique per fire-ack-resolve cycle
    alert_name       String,         -- Prometheus alert name
    severity         Enum8('P0'=0, 'P1'=1, 'P2'=2, 'P3'=3),
    service          String,         -- affected service label
    cluster          String,         -- cluster label
    fire_time        DateTime,       -- alert first fired
    ack_time         Nullable(DateTime),  -- NULL if never acknowledged
    resolve_time     DateTime,       -- alert returned to healthy
    tta_seconds      Nullable(UInt32),    -- NULL if never acknowledged
    ttr_seconds      Nullable(UInt32),    -- NULL if never acknowledged (shouldn't happen)
    acked            UInt8,          -- 1 if acknowledged, 0 if auto-resolved
    slo_met          UInt8,          -- 1 if both TTA and TTR met for this severity
    summary          String,         -- alert annotation summary
    runbook          String,         -- link to runbook if available
    insert_time      DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(fire_time)
ORDER BY (severity, fire_time, incident_id)
```

### 3.3 Derived Views

```sql
-- Per-incident SLO compliance
CREATE MATERIALIZED VIEW infra.incident_slo_compliance_mv
ENGINE = AggregatingMergeTree()
ORDER BY (severity, date)
AS SELECT
    severity,
    toDate(fire_time) AS date,
    count(*) AS total_incidents,
    sum(slo_met) AS compliant_incidents,
    avg(tta_seconds) AS avg_tta,
    avg(ttr_seconds) AS avg_ttr,
    quantile(0.50)(tta_seconds) AS p50_tta,
    quantile(0.95)(tta_seconds) AS p95_tta,
    quantile(0.99)(tta_seconds) AS p99_tta,
    quantile(0.50)(ttr_seconds) AS p50_ttr,
    quantile(0.95)(ttr_seconds) AS p95_ttr,
    quantile(0.99)(ttr_seconds) AS p99_ttr,
    sum(if(acked=0, 1, 0)) AS auto_resolved_count
FROM infra.incident_response_log
GROUP BY severity, toDate(fire_time)
```

---

## 4. Measurement Methodology

### 4.1 TTA Definition

**Time to Acknowledge** = time from `fire_time` to the first human acknowledgement event.

**How acknowledgement is captured:**

| Method | Source | Latency | Reliability |
|--------|--------|---------|-------------|
| Alertmanager "silence created" API | Alertmanager API `POST /api/v2/silences` | Near real-time | High — requires API token |
| Feishu bot "I'm on it" button click | feishu-bridge webhook callback | Sub-second | Medium — depends on feishu-bridge uptime |
| Alertmanager webhook "ack" receiver | Custom receiver that records ack on alert | Real-time | High — built-in |
| Manual (claimed via patrol) | cc-healthcheck patrol logs | Up to 5 min | Low — delayed, manual |

**Primary method:** Alertmanager silences (or a dedicated ack annotation). When an engineer acknowledges a page (via feishu "I'm on it" or directly in Alertmanager), the system records `ack_time`.

**Fallback method:** If no explicit ack exists but the alert resolves: TTA is computed as the time from fire to the first metric that indicates intervention (e.g., a configuration change, a container restart, a `git push` to the infra repo). If no intervention detected, the incident is flagged as "auto-resolved, never acknowledged" — this counts against SLO attainment.

### 4.2 TTR Definition

**Time to Resolve** = time from `ack_time` to `resolve_time`.

**Resolution is detected as:**
- Alertmanager alert status transitions from `firing` to `resolved` (built-in)
- The PromQL expression returns to healthy for at least `for` duration + 30s grace

### 4.3 Business Hours Adjustment

For P2/P3 alerts:

```python
def effective_fire_time(fire_time, severity):
    if severity in ('P2', 'P3'):
        # Business hours: Mon-Sat 09:00-18:00 Asia/Shanghai
        next_biz_start = next_business_hour_start(fire_time)
        return max(fire_time, next_biz_start)
    return fire_time
```

TTA is computed from `effective_fire_time` to ack. If the alert fires at 02:00 and is acknowledged at 09:15, TTA = 15 minutes (not 7h15m).

### 4.4 Composite (Multi-Service) Incidents

A true incident may trigger multiple alerts. Example: a network partition on `mac-orbstack` could fire:
- `cc-connect` down (P0)
- `PostgreSQL` unreachable (P0)
- `Redis` unreachable (P1)

**Grouping rule:** Alerts that fire within 5 minutes of each other and share a common cause label (`incident_group` or inferred from cluster/topology) are grouped into a single incident. The incident severity is the **highest** severity among grouped alerts.

TTA for the group = min(TTA of all alerts in the group).  
TTR for the group = max(TTR of all alerts in the group).

### 4.5 Exclusion Criteria

The following are excluded from SLO computation:

| Exclusion | Rationale |
|-----------|-----------|
| Test alerts (alert name matches `^test`) | Not real incidents |
| Maintenance window alerts | Planned, not an incident |
| Alertmanager self-monitoring alerts | Meta — would create circular dependency |
| Repeated flapping (>5 fire-resolve cycles in 1h) | Counted as 1 incident with note |
| Silenced-before-fire alerts | Alert was known and planned |

---

## 5. Instrumentation & Data Pipeline

### 5.1 Architecture

```
Prometheus Alertmanager
       │
       ├── webhook receiver ──→ Vector (HTTP source) ──→ ClickHouse `incident_response_log`
       │                                                     │
       │                                                     ▼
  Feishu bot ──→ Ack button ──→ feishu-bridge ──→ Vector (HTTP source)
       │                                                     │
       │                                                     ▼
  Alertmanager API ──→ Ack poller ──→ Vector (HTTP source)
```

Three ingestion paths converge on the same ClickHouse table, deduplicated by `incident_id`.

### 5.2 Alertmanager Webhook

Alertmanager sends webhooks on every state transition. Configuration:

```yaml
receivers:
  - name: incident-slo-recorder
    webhook_configs:
      - url: http://vector:8686/incident-webhook
        send_resolved: true
        max_alerts: 100
```

The webhook payload includes:
```json
{
  "status": "firing",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "ErrorBudgetBurnP0",
        "severity": "page",
        "service": "cc-connect",
        "cluster": "mac-orbstack"
      },
      "annotations": {
        "summary": "P0: cc-connect burning budget at 14x rate",
        "runbook": "docs/infra/runbooks/p0-budget-burn.md"
      },
      "startsAt": "2026-05-23T10:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z"
    }
  ],
  "groupLabels": { "alertname": "ErrorBudgetBurnP0" },
  "commonLabels": { "severity": "page" }
}
```

On `status: "firing"` with `endsAt` in the past (resolved), Vector creates the incident record with both `fire_time` and `resolve_time`. On `status: "firing"` with `endsAt` in the far future, Vector creates the initial record with only `fire_time`.

### 5.3 Acknowledgement Capture

**Option A: Alertmanager Silence API (recommended)**

A polling loop (via cron or cc-connect cron) queries Alertmanager silences:

```bash
curl -s http://alertmanager:9093/api/v2/silences | jq '.data[] | {id, comment, createdBy, startsAt, endsAt, matchers}'
```

New silences that match active incident alerts are recorded as acknowledgements. The silence `createdBy` field identifies the responder.

**Option B: Feishu Bot "I'm on it" Button**

The feishu-bridge incident notification includes an "I'm on it" interactive button. When clicked:
1. feishu-bridge receives the callback
2. Creates an Alertmanager silence via API
3. Records `ack_time` in the incident log

**Option C: Manual Acknowledgment via Patrol**

Patrol system (see `5min-patrol-guide.md`) can claim incidents by acknowledging them. The patrol log entry is picked up by Vector and recorded.

### 5.4 Incident ID Assignment

`incident_id` = `SHA256(alert_name || group_key || fire_timestamp)[:16]`

This ensures idempotency: the same alert group firing at the same time always produces the same ID. Webhook retries are naturally deduplicated.

### 5.5 Vector Configuration

```toml
[sources.incident_webhook]
type = "http_server"
address = "0.0.0.0:8686"
path = "/incident-webhook"
encoding = "json"

[transforms.incident_normalize]
type = "remap"
inputs = ["incident_webhook"]
source = '''
  # Extract alert data from webhook payload
  .incident_id = encode_hex(hash_sha256(join!(.alerts, ",")))
  .alert_name = .groupLabels.alertname
  .severity = parse_severity(.commonLabels.severity)
  .service = .commonLabels.service
  .cluster = .commonLabels.cluster
  .fire_time = .alerts[0].startsAt
  .resolve_time = now() if .status == "resolved"
  
  if exists(.alerts[0].annotations.summary) {
    .summary = .alerts[0].annotations.summary
  }
  if exists(.alerts[0].annotations.runbook) {
    .runbook = .alerts[0].annotations.runbook
  }
'''

[sinks.incident_clickhouse]
type = "clickhouse"
inputs = ["incident_normalize"]
endpoint = "http://clickhouse:8123"
database = "infra"
table = "incident_response_log"
encoding = "json"
```

---

## 6. Computation & Recording Rules

### 6.1 Per-Severity Compliance (30d Rolling)

Prometheus recording rules that feed into Grafana:

```yaml
groups:
  - name: incident-slo
    interval: 60s
    rules:
      # Total incidents in last 30d per severity
      - record: incident_slo:total:30d
        expr: |
          sum(increase(incident_response_log_total{severity=~"P0|P1|P2|P3"}[30d]))
            by (severity)

      # Compliant incidents (met both TTA and TTR)
      - record: incident_slo:compliant:30d
        expr: |
          sum(increase(incident_slo_met_total{severity=~"P0|P1|P2|P3"}[30d]))
            by (severity)

      # Attainment rate (0.0 to 1.0)
      - record: incident_slo:attainment:30d
        expr: |
          clamp_min(
            incident_slo:compliant:30d / incident_slo:total:30d,
            0
          )

      # Average TTA per severity (last 30d)
      - record: incident_slo:avg_tta_seconds:30d
        expr: |
          avg(incident_response_log_tta_seconds{severity=~"P0|P1|P2|P3"})
            by (severity)

      # Average TTR per severity (last 30d)
      - record: incident_slo:avg_ttr_seconds:30d
        expr: |
          avg(incident_response_log_ttr_seconds{severity=~"P0|P1|P2|P3"})
            by (severity)

      # P95 TTA per severity (last 30d)
      - record: incident_slo:p95_tta_seconds:30d
        expr: |
          histogram_quantile(0.95,
            sum(rate(incident_response_log_tta_seconds_bucket[30d])) by (le, severity)
          )

      # Auto-resolved rate (no ack)
      - record: incident_slo:auto_resolved_ratio:30d
        expr: |
          sum(increase(incident_auto_resolved_total{severity=~"P0|P1|P2|P3"}[30d]))
            by (severity)
          /
          sum(increase(incident_response_log_total{severity=~"P0|P1|P2|P3"}[30d]))
            by (severity)
```

### 6.2 SLO Compliance Dashboard Metric

Expose a single gauge for quick at-a-glance status:

```promql
# SLO attainment vs target (negative = below target)
incident_slo:attainment_deviation:30d =
  incident_slo:attainment:30d - on(severity) group_left incident_slo_target
```

Where `incident_slo_target` is a static metric:

```yaml
- record: incident_slo_target
  expr: |
    0 * (
      label_replace(vector(0.99), "severity", "P0", "", "") or
      label_replace(vector(0.95), "severity", "P1", "", "") or
      label_replace(vector(0.90), "severity", "P2", "", "") or
      label_replace(vector(0.90), "severity", "P3", "", "")
    )
```

Then in Grafana, color-code: green if deviation >= 0, red if < 0.

### 6.3 Source Metrics (from ClickHouse to Prometheus)

Expose ClickHouse query results as Prometheus metrics via a metrics exporter (`clickhouse_exporter` or custom script):

```sql
-- Metric: total incidents per severity
SELECT
    severity,
    count(*) AS total,
    sum(slo_met) AS compliant,
    sum(if(acked=0, 1, 0)) AS auto_resolved
FROM infra.incident_response_log
WHERE fire_time >= now() - INTERVAL 30 DAY
GROUP BY severity
```

```sql
-- Metric: TTA/TTA quantiles per severity
SELECT
    severity,
    quantile(0.50)(tta_seconds) AS p50_tta,
    quantile(0.95)(tta_seconds) AS p95_tta,
    quantile(0.99)(tta_seconds) AS p99_tta,
    quantile(0.50)(ttr_seconds) AS p50_ttr,
    quantile(0.95)(ttr_seconds) AS p95_ttr,
    quantile(0.99)(ttr_seconds) AS p99_ttr
FROM infra.incident_response_log
WHERE fire_time >= now() - INTERVAL 30 DAY
GROUP BY severity
```

Alternatively, skip Prometheus and query ClickHouse directly in Grafana using the ClickHouse data source plugin.

---

## 7. Dashboard

### 7.1 Grafana Dashboard: Incident SLO Compliance

**Dashboard name:** Incident SLO Compliance
**Refresh:** 60s
**Time range default:** Last 30 days

#### Panel 1: SLO Attainment Gauge (per severity)

One gauge per severity showing current 30d attainment vs target:

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  P0         │  │  P1         │  │  P2         │  │  P3         │
│  100%       │  │  97%        │  │  85%        │  │  92%        │
│  target 99% │  │  target 95% │  │  target 90% │  │  target 90% │
│  ✓ ON TRACK │  │  ✓ ON TRACK │  │  ✗ BELOW    │  │  ✓ ON TRACK │
└─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘
```

Color thresholds:
- Green: attainment >= target
- Yellow: attainment >= target - 5%
- Red: attainment < target - 5%

#### Panel 2: TTA Distribution (Histogram)

Per-severity histogram of TTA buckets:

```
P0 Time to Acknowledge (last 30d)
  < 1 min:   ████████████ 12 incidents
  1-3 min:   ██████████   10 incidents
  3-5 min:   ███████      7 incidents
  > 5 min:   ██           2 incidents  ← SLO breach
```

TTA breaches are highlighted in red.

#### Panel 3: TTR Distribution (Histogram)

Same as Panel 2 but for resolution time.

#### Panel 4: Incident Timeline

A timeline chart showing incidents over the last 30 days:

```
  P0 │ ●            ●    ●
  P1 │    ●    ●              ●
  P2 │ ●  ●  ●  ●  ●  ●  ●
  P3 │       ●       ●
     └─────────────────────────
      May 01         May 15         May 23
```

- Marker size proportional to total downtime
- Color: red = SLO breach, green = within SLO
- Click a marker to drill into incident details

#### Panel 5: TTA/TTR Trend (7d moving average)

```
TTA 7d MA
  P0 ──╮    ╱╲
  P1 ───╲──╱─╲──
  P2 ────╲────╲─
       ┌──────────────────
       May 16     May 23
```

Shows if response is getting faster or slower. A 7d MA rising above the SLO line triggers attention.

#### Panel 6: Top SLO Breach Causes

Table showing which services/alerts contribute most to SLO breaches:

```
Alert                        Severity   Breaches   Avg TTA     Avg TTR
ErrorBudgetBurnP0            P0         2          8m 32s      45m 12s
PostgreSQLReplicaLag         P1         3          22m 10s     3h 15m
KafkaConsumerLag             P2         5          1h 45m      6h 30m
DiskUsageWarning             P2         2          2h 10m      4h 00m
```

#### Panel 7: Auto-Resolved Rate

Percentage of incidents that auto-resolved without human acknowledgement:

```
P0 auto-resolved:  0%  ✓
P1 auto-resolved:  8%  ✓
P2 auto-resolved: 25%  ⚠ Monitor
```

A high auto-resolved rate (especially for P0/P1) suggests the alert is too noisy or the service self-heals — either way, the alert rule should be tuned.

#### Panel 8: On-Call Responsiveness

Per-responder stats (requires identifying the ack user):

```
Responder       P0 incidents   Avg TTA   Avg TTR   SLO compliance
hanayo          4              2m 10s    18m       100%
yuki            3              1m 30s    22m       100%
maki            2              8m 00s    35m       50%  ⚠
```

This panel is optional and should be used for process improvement, not blame.

### 7.2 Row: Incident Details (Drill-Down Table)

A sortable/filterable table of all incidents in the selected time range:

| Time | Alert | Sev | Service | Cluster | TTA | TTR | Ack'd? | SLO Met? | Runbook |
|------|-------|-----|---------|---------|-----|-----|--------|----------|---------|
| 2026-05-23 10:00 | ErrorBudgetBurnP0 | P0 | cc-connect | mac-orbstack | 2m | 15m | Yes | Yes | link |
| 2026-05-22 14:30 | PostgresReplicaLag | P1 | postgres-16 | mac-orbstack | 25m | 3h | Yes | No | link |

### 7.3 Dashboard Variables

```yaml
variables:
  - name: severity
    type: custom
    options: [All, P0, P1, P2, P3]
    default: All

  - name: service
    type: query
    query: SELECT DISTINCT service FROM infra.incident_response_log
    multi: true

  - name: cluster
    type: custom
    options: [All, mac-orbstack, aliyun, office]
    default: All
```

---

## 8. Alerting on SLO Risk

### 8.1 When to Alert

| Condition | Severity | Action |
|-----------|----------|--------|
| P0 attainment < 99% over 7d | P1 | Page on-call — response process is broken |
| P1 attainment < 95% over 7d | P2 | Create ticket — review on-call handoff |
| P2 attainment < 90% over 30d | P3 | Monthly report mention |
| P3 attainment < 90% over 30d | None | Monthly report mention |
| Any severity TTA trending up > 20% week-over-week | P3 | Create ticket — investigate notification path |
| Auto-resolve rate > 50% for P0 (any window) | P1 | Page on-call — critical alerts likely missed |

### 8.2 Prometheus Alert Rules

```yaml
groups:
  - name: incident-slo-alerts
    interval: 60s
    rules:
      - alert: IncidentSLOAttainmentBreachP0
        expr: |
          incident_slo:attainment:30d{severity="P0"} < 0.99
            and on()
          incident_slo:total:30d{severity="P0"} > 5
        for: 10m
        annotations:
          severity: page
          summary: "P0 incident SLO attainment below target (current: {{ $value | humanizePercentage }})"
          description: "P0 incident response SLO attainment is {{ $value | humanizePercentage }} over the last 30d (target: 99%). {{ $value | humanizePercentage }} of P0 incidents missed TTA or TTR targets."

      - alert: IncidentSLOAttainmentBreachP1
        expr: |
          incident_slo:attainment:30d{severity="P1"} < 0.95
            and on()
          incident_slo:total:30d{severity="P1"} > 5
        for: 10m
        annotations:
          severity: ticket
          summary: "P1 incident SLO attainment below target (current: {{ $value | humanizePercentage }})"

      - alert: IncidentTTASpike
        expr: |
          (
            incident_slo:avg_tta_seconds:7d
              / incident_slo:avg_tta_seconds:30d
          ) > 1.2
        for: 1h
        annotations:
          severity: ticket
          summary: "TTA is trending up > 20% week-over-week for {{ $labels.severity }}"

      - alert: IncidentAutoResolveRateHigh
        expr: |
          incident_slo:auto_resolved_ratio:7d{severity=~"P0|P1"} > 0.5
        for: 10m
        annotations:
          severity: page
          summary: "High auto-resolve rate for {{ $labels.severity }} alerts ({{ $value | humanizePercentage }})"
          description: "{{ $value | humanizePercentage }} of {{ $labels.severity }} incidents auto-resolved without human acknowledgement. Alerts may be too noisy or stale."
```

### 8.3 SLO Attainment Forecast

Use a simple linear forecast to predict when attainment will drop below target:

```promql
# Weekly rate of change in attainment
incident_slo:attainment_trend:7d =
  (
    incident_slo:attainment:7d - incident_slo:attainment:14d
  ) / 7

# Days until attainment drops below target (negative = already below)
incident_slo:days_to_breach =
  (
    incident_slo_target
    - incident_slo:attainment:30d
  ) / incident_slo:attainment_trend:7d
```

If `days_to_breach < 7` and trend is negative, escalate before the breach happens.

---

## 9. Reporting & Review

### 9.1 Weekly Incident SLO Report

Automated report every Monday 09:00 Asia/Shanghai:

```
=== Incident SLO Weekly Report (May 18 - May 24, 2026) ===

SUMMARY
  Total incidents: 14
  SLO attainment:  85.7% (12/14)

PER SEVERITY
  P0: 3 incidents, 100.0% attainment  ✓
  P1: 5 incidents, 80.0% attainment   ✗ (1 breach: Kafka consumer lag, TTA 22min)
  P2: 4 incidents, 75.0% attainment   ✗ (1 breach: Disk usage, TTR exceeded)
  P3: 2 incidents, 100.0% attainment  ✓

SLO BREACHES
  May 19 14:30  P1  Kafka consumer lag    TTA 22m (target 15m)
  May 21 03:15  P2  Disk usage warning    TTR 9h (target 8h)

TTA TREND
  P0: 2m 10s avg (last week: 2m 30s)  ⇓ improving
  P1: 12m 30s avg (last week: 8m 15s) ⇑ worsening ⚠

TOP CONTRIBUTORS TO SLO BREACHES
  kafka-consumer-lag      2 breaches
  disk-usage              1 breach

RECOMMENDATIONS
  1. Review Kafka consumer lag alert threshold — may be too sensitive for P1
  2. Add disk alert runbook link — responder spent 30min finding the right page
  3. TTA for P1 is trending up — check on-call notification delivery
```

### 9.2 Monthly Incident SLO Review

Incorporated into the monthly error budget report (from `error-budget.md` Section 10.4):

```
=== Incident SLO Monthly Report (May 2026) ===

OVERALL
  Incidents: 47 (P0: 5, P1: 12, P2: 18, P3: 12)
  SLO attainment: 91.5% (43/47)
  Target: 95% → MISSED (first time this quarter)

DETAIL
  P0 compliance: 100%  ✓ (5/5 within SLO)
  P1 compliance: 91.7% ✓ (11/12 within SLO; 1 breach: 22min TTA)
  P2 compliance: 83.3% ✗ (15/18 within SLO; 3 breaches: 2 disk, 1 memory)
  P3 compliance: 100%  ✓

AUTO-RESOLVE RATE
  P0: 0%    ✓
  P1: 8.3%  ✓ (1 auto-resolved — transient Kafka rebalance)
  P2: 27.8% ⚠ (5 auto-resolved — consider tuning thresholds)

AVERAGE RESPONSE TIMES
  P0 TTA: 2m 10s (5m target)  ✓
  P1 TTA: 9m 45s (15m target) ✓
  P2 TTA: 48m (1h target)     ✓
  P0 TTR: 18m (30m target)    ✓
  P1 TTR: 1h 35m (2h target)  ✓
  P2 TTR: 6h 20m (8h target)  ✓

BIGGEST INCIDENTS (by total downtime)
  1. [P0] cc-connect crash loop                May 12  29m downtime
  2. [P1] PostgreSQL replica lag spike          May 15  3h 10m degraded
  3. [P2] Disk usage on aliyun build runner     May 18  8h 45m degraded

RECOMMENDATIONS
  1. P2 SLO attainment is below target (83.3%). Most breaches are disk-related.
     — Add proactive disk cleanup cron to reduce disk alerts.
     — Consider raising disk alert threshold from 85% to 92%.
  2. Auto-resolve rate for P2 alerts is 27.8% — tune thresholds to suppress transient alerts.
  3. P1 TTA is trending up — last week was 12m, previous was 8m. Investigate on-call notification reliability.
  4. Overall attainment missed target this month (91.5% vs 95% target). Set up a process review.
```

### 9.3 Post-Incident Review Integration

Every post-incident review (PIR) should include SLO impact:

```
=== Post-Incident Review (SLO Section) ===

Incident: Kafka consumer lag spike (May 19, 2026)
Severity: P1

SLO Impact:
  - TTA: 22m 10s (target: 15m) — BREACH
  - TTR: 3h 15m (target: 2h) — BREACH
  - Error budget consumed: 12.4% of Kafka budget
  - SLO attainment contribution: -1 (P1 target missed for May)

Root cause: Consumer group rebalance timeout after broker restart.
SLO improvement action: Add `kafka_consumer_group_rebalance` alert at P2 level
  so rebalances are detected before they cause P1-level lag.
```

---

## 10. Operational Runbook

### 10.1 Adding a New Alert to SLO Tracking

1. Ensure the alert has appropriate severity label (`P0` through `P3`).
2. Verify the alert groups correctly (shared `group_key` / `groupLabels`).
3. The incident pipeline auto-detects new alerts by `alert_name` — no manual registration needed.
4. Confirm the alert fires in Alertmanager and the webhook reaches Vector.
5. Verify the incident appears in the dashboard within 2 minutes of firing.
6. Set TTA/TTR targets are set in `error-budget.md` Section 4.4.

### 10.2 Investigating an SLO Breach

```
1. Identify the breach incident in the dashboard.
2. Check the incident details: which alert, which service, TTA vs TTR breach?
3. If TTA breach:
   a. Did the notification fire? (Check feishu bot, Alertmanager logs)
   b. Was someone on call? (Check rotation)
   c. Did they see it? (Check feishu message read receipts)
   d. Did they act? (Check Alertmanager silence logs)
4. If TTR breach:
   a. What was the root cause?
   b. Was the runbook followed?
   c. Was the fix straightforward or complex?
   d. Did we need help from outside the on-call rotation?
5. File a follow-up issue with findings.
```

### 10.3 Tuning Alert Sensitivity

Use auto-resolve rate as a signal:

| Auto-resolve rate | Meaning | Action |
|------------------|---------|--------|
| < 10% | Healthy threshold | No action |
| 10-30% | Slightly noisy | Consider small threshold adjustment |
| 30-50% | Too noisy | Review and adjust alert rules |
| > 50% | Broken | Redesign alert (likely flapping or stale) |

### 10.4 On-Call Handoff Checklist

At each on-call shift handoff:

- [ ] Review last 7 days of incident SLO dashboard
- [ ] Identify any ongoing incidents that will carry over
- [ ] Review SLO breaches from last week — any patterns?
- [ ] Confirm notification channels are working (feishu, TTS)
- [ ] Update runbook if any new incident patterns emerged

### 10.5 Quarterly SLO Target Review

Every quarter, review:

- Are TTA/TTR targets still realistic? (If we always hit 100%, targets may be too loose.)
- Are severity classifications still accurate? (Is P1 constantly hitting P0-level breach patterns?)
- Do we need new severity levels? (P0.5? P4?)
- Has the team grown enough to warrant tighter SLOs?

Targets should be challenging but achievable: if attainment is always 100%, the target is too easy. If attainment is consistently below 90%, the process (not the target) needs fixing.

---

## Appendix A: ClickHouse Schema DDL

```sql
CREATE DATABASE IF NOT EXISTS infra;

CREATE TABLE IF NOT EXISTS infra.incident_response_log (
    incident_id      String,
    alert_name       String,
    severity         Enum8('P0'=0, 'P1'=1, 'P2'=2, 'P3'=3),
    service          String,
    cluster          String DEFAULT 'mac-orbstack',
    fire_time        DateTime64(3),
    ack_time         Nullable(DateTime64(3)),
    resolve_time     DateTime64(3),
    tta_seconds      Nullable(UInt32),
    ttr_seconds      Nullable(UInt32),
    acked            UInt8 DEFAULT 0,
    slo_met          UInt8 DEFAULT 0,
    summary          String DEFAULT '',
    runbook          String DEFAULT '',
    insert_time      DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(fire_time)
ORDER BY (severity, fire_time, incident_id)
TTL fire_time + INTERVAL 1 YEAR DELETE;

-- Materialized view for daily compliance summary
CREATE MATERIALIZED VIEW IF NOT EXISTS infra.incident_slo_daily_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (severity, date)
POPULATE
AS SELECT
    severity,
    toDate(fire_time) AS date,
    count(*) AS total_incidents,
    sum(slo_met) AS compliant_incidents,
    avg(tta_seconds) AS avg_tta,
    avg(ttr_seconds) AS avg_ttr,
    quantileState(0.50)(tta_seconds) AS tta_p50_state,
    quantileState(0.95)(tta_seconds) AS tta_p95_state,
    quantileState(0.99)(tta_seconds) AS tta_p99_state,
    quantileState(0.50)(ttr_seconds) AS ttr_p50_state,
    quantileState(0.95)(ttr_seconds) AS ttr_p95_state,
    quantileState(0.99)(ttr_seconds) AS ttr_p99_state,
    sum(if(acked=0, 1, 0)) AS auto_resolved_count
FROM infra.incident_response_log
GROUP BY severity, toDate(fire_time);
```

## Appendix B: TTA/TTR Update Queries

When acknowledgement is captured (via feishu button or Alertmanager silence):

```sql
ALTER TABLE infra.incident_response_log
UPDATE
    ack_time = '<captured_ack_time>',
    tta_seconds = dateDiff('second', fire_time, '<captured_ack_time>'),
    acked = 1,
    slo_met = if(
        dateDiff('second', fire_time, '<captured_ack_time>') <= <severity_tta_target_seconds>
        AND <resolve_time_is_set>,
        1, 0
    )
WHERE incident_id = '<incident_id>';
```

When alert resolves:

```sql
ALTER TABLE infra.incident_response_log
UPDATE
    resolve_time = '<resolve_time>',
    ttr_seconds = dateDiff('second', ack_time, '<resolve_time>'),
    slo_met = if(
        tta_seconds <= <severity_tta_target_seconds>
        AND dateDiff('second', ack_time, '<resolve_time>') <= <severity_ttr_target_seconds>,
        1, 0
    )
WHERE incident_id = '<incident_id>';
```

## Appendix C: Summary of SLO Targets

| Severity | TTA | TTR | Attainment Target | Clock | Response Channel |
|----------|-----|-----|-------------------|-------|-----------------|
| P0 | <= 5 min | <= 30 min | >= 99% | 24x7 | 飞书 @all + TTS |
| P1 | <= 15 min | <= 2 hr | >= 95% | 24x7 | 飞书 @oncall |
| P2 | <= 1 hr | <= 8 hr | >= 90% | Business hrs | 飞书 mention + ticket |
| P3 | <= 24 hr | <= 5 days | >= 90% | Business hrs | Daily digest |

## Appendix D: Related Documents

| Document | Connection |
|----------|-----------|
| `error-budget.md` | Defines service SLOs that incident response SLOs complement |
| `observability-design.md` | Overall monitoring architecture |
| `alert-fatigue.md` | Alert tuning — high auto-resolve rate triggers investigation |
| `docker-events.md` | Container lifecycle events — useful for TTR root cause analysis |
| `feishu-delivery.md` | Notification delivery — TTA depends on notification reliability |
| `5min-patrol-guide.md` | Patrol system — manual incident claim via patrol |
