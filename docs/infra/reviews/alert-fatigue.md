---
decision: 稍后做
---

# Alert Fatigue Monitoring Design

**Author:** Boss
**Status:** Draft
**PR:** TBD

## 1. Problem Statement

As the kyb infra fleet grows (cc-connect, patrol, issue automation, MCP, bridge, CK ingestion), the number of alerting rules and notification channels multiplies. Left unchecked, this leads to **alert fatigue**:

- Operators ignore or silence alerts that fire too frequently
- Real incidents are buried in noise
- MTTA degrades as operators triage low-signal alerts
- False positives erode trust in the alerting system

This document defines a monitoring system for the alerting system itself -- **meta-monitoring** that tracks alert health and drives continuous improvement of alert quality.

### 1.1 Scope

| Included | Not included |
|----------|-------------|
| Alert rules defined in Prometheus/AlertManager | Uptime of monitoring infrastructure itself |
| Patrol-generated anomaly reports | Business-level metrics (DAU, message count) |
| cc-connect healthcheck restarts | Cost analysis of alerting infrastructure |
| Silences (manual and auto) | Incident response runbooks |
| Notification delivery (Feishu, diary) | On-call scheduling |

## 2. Core Metrics

### 2.1 Alert Volume

Track the raw volume of alert firings to detect spikes and trends.

**Metric: `alerts.fired_total`**

| Label | Type | Values |
|-------|------|--------|
| `alertname` | string | Name of the alert rule |
| `severity` | string | `P0` / `P1` / `P2` / `info` |
| `team` | string | Owner team (`kyb-infra`, `bridge`, `mcp`) |
| `source` | string | Alert source (`prometheus`, `patrol`, `hook`) |

Query (PromQL):
```promql
# Raw firing rate per alert
rate(alerts_fired_total[1h])

# Top-10 most frequent alerts (7d sum)
topk(10, sum_over_time(alerts_fired_total[7d]))
```

**Derived: `alerts.firing_duration_seconds`**

Time from first firing to resolution (histogram). Short-duration alerts that fire frequently are the most fatiguing -- they resolve before operators finish triaging.

**Thresholds:**

| Level | Alert firing rate | Action |
|-------|-------------------|--------|
| Green | < 10 / day | Normal |
| Yellow | 10-50 / day | Review alert threshold or dedup |
| Red | > 50 / day | Must fix: too noisy for any operator to trust |

### 2.2 Silence Rate

Manual silences are the strongest signal of alert fatigue -- an operator explicitly said "I don't want to see this."

**Metric: `alerts.silenced_total`**

| Label | Type | Values |
|-------|------|--------|
| `alertname` | string | Silenced alert rule |
| `silence_reason` | string | Reason label (see 2.2.1) |
| `silence_duration_seconds` | float | How long the silence lasts |
| `created_by` | string | Who created the silence |

**2.2.1 Silence Reason Taxonomy**

Every silence MUST carry a `silence_reason` label. No unlabeled silences permitted.

| Reason | Meaning | Expiry |
|--------|---------|--------|
| `false_positive` | Alert fired but no real issue existed | Must document root cause |
| `known_issue` | Alert is a known, accepted condition | Must link to tracking issue |
| `maintenance` | Planned maintenance window | Auto-expires after window |
| `too_noisy` | Alert fires too often, needs re-tuning | Max 7 days; must create re-tuning ticket |
| `duplicate` | Same condition covered by another alert | Max 24h; must dedup or drop |

**Silence Rate Thresholds:**

| Level | Rate (silenced / total fired) | Action |
|-------|------------------------------|--------|
| Green | < 5% | Normal |
| Yellow | 5-20% | Review individual high-silence alerts |
| Red | > 20% | Alert fatigue in progress; must act |

### 2.3 False Positive Rate

The most destructive category of noise. A false positive is an alert that fired but required no operator action because the underlying condition was benign.

**Instrumentation:**

Each alert acknowledgment MUST record:
- Did this alert require operator action? (`true` / `false`)
- If `true`: what action was taken (restart, config change, investigate)
- If `false`: why was it a false positive?

**Metric: `alerts.acknowledged_total`**

| Label | Type | Values |
|-------|------|--------|
| `alertname` | string | Alert rule |
| `action_required` | bool | Did the operator take action? |
| `action_taken` | string | `restart` / `config_change` / `investigation` / `none` |
| `false_reason` | string | Reason if `action_required=false` |

**False Positive taxonomy:**

| Reason | Example | Fix |
|--------|---------|-----|
| `threshold_too_sensitive` | Disk alert at 80% but auto-cleanup runs at 85% | Raise threshold |
| `transient_condition` | Network blip that resolved in < 30s | Add `for: 1m` to rule |
| `duplicate_alert` | Same node triggers two equivalent rules | Dedup |
| `expected_behavior` | Container restart is expected during deploy | Exclude deploy window |
| `stale_metric` | Alert fired but metric source was already dead | Fix staleness handling |

**False Positive Rate Thresholds:**

| Level | Rate | Action |
|-------|------|--------|
| Green | < 5% | Healthy |
| Yellow | 5-15% | Flagged for next alert review |
| Red | > 15% | Immediate alert rule triage required |

### 2.4 MTTA (Mean Time to Acknowledge)

Time from alert first firing to first human acknowledgment (silence, snooze, or action).

**Metric: `alerts.mtta_seconds`**

Computed per alert instance:
```
mtta = first_ack_timestamp - first_firing_timestamp
```

| Label | Type | Values |
|-------|------|--------|
| `alertname` | string | Alert rule |
| `severity` | string | P0 / P1 / P2 |
| `time_of_day` | string | `business_hours` / `after_hours` |
| `day_of_week` | string | `weekday` / `weekend` |

**Derived: `alerts.mtta_by_severity`** (P50, P90, P99 per severity level)

**Thresholds:**

| Severity | Target MTTA (P50) | Target MTTA (P90) |
|----------|-------------------|-------------------|
| P0 | < 5 min | < 15 min |
| P1 | < 15 min | < 1 hr |
| P2 | < 1 hr | < 4 hr |

**Degradation signal:** If any severity's MTTA P90 exceeds target by 2x for 3 consecutive days, that is an alert fatigue indicator -- operators may be ignoring alerts.

### 2.5 Composite Alert Fatigue Index (AFI)

Single score that summarizes alert health. Components weighted by impact:

```
AFI = (silence_rate * 0.3) + (fp_rate * 0.4) + (mtta_degradation * 0.3)

where:
  silence_rate    = silences / total_fired (rolling 7d)
  fp_rate         = false_positives / total_acknowledged (rolling 7d)
  mtta_degradation = max(0, (mtta_p90_actual / mtta_p90_target) - 1)
```

| Score | Status | Color |
|-------|--------|-------|
| 0 - 0.2 | Healthy | Green |
| 0.2 - 0.5 | Deteriorating | Yellow |
| 0.5 - 1.0 | Fatigued | Orange |
| > 1.0 | Critical | Red |

The AFI itself is a metric: `alert_fatigue.index`. Alert when > 0.5.

## 3. Data Model

### 3.1 ClickHouse Tables

Each alert firing event is recorded in a central table. Sources (Prometheus AlertManager webhook, patrol diary, manual entry) all write to the same schema.

```sql
CREATE TABLE infra.alerts (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    alert_id           String               -- Unique firing ID (hash of alertname + fingerprint + time)
    alertname          LowCardinality(String),
    severity           LowCardinality(String),
    source             LowCardinality(String),
    team               LowCardinality(String),
    labels             Map(String, String),  -- All alert labels (JSON)
    annotations        Map(String, String),  -- Alert annotations (summary, description, runbook)
    fingerprint        String,               -- AlertManager dedup fingerprint

    -- Lifecycle timestamps (null until they happen)
    fired_at           DateTime64(3),
    acknowledged_at    Nullable(DateTime64(3)),
    silenced_at        Nullable(DateTime64(3)),
    resolved_at        Nullable(DateTime64(3)),

    -- Acknowledgment detail
    action_required    Nullable(Bool),       -- Did the alert require real action?
    action_taken       Nullable(String),     -- What action was taken?
    false_reason       Nullable(String),     -- Why false positive?
    silence_reason     Nullable(String),     -- Why silenced?

    -- Derived
    mtta_seconds       Nullable(Int32),      -- acknowledged_at - fired_at
    duration_seconds   Nullable(Int32)       -- resolved_at - fired_at
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, alertname, severity)
TTL timestamp + INTERVAL 365 DAY DELETE
```

**Materialized views:**

```sql
-- Daily alert summary
CREATE MATERIALIZED VIEW infra.alerts_daily_mv
ENGINE = AggregatingMergeTree
ORDER BY (date, alertname)
AS SELECT
    toDate(timestamp) AS date,
    alertname,
    severity,
    team,
    source,
    count() AS total_fired,
    countIf(acknowledged_at IS NOT NULL) AS total_acknowledged,
    countIf(silenced_at IS NOT NULL) AS total_silenced,
    countIf(action_required = 0) AS total_false_positive,
    avgIf(mtta_seconds, mtta_seconds IS NOT NULL) AS avg_mtta,
    quantileIfState(0.5)(mtta_seconds, mtta_seconds IS NOT NULL) AS p50_mtta,
    quantileIfState(0.9)(mtta_seconds, mtta_seconds IS NOT NULL) AS p90_mtta
FROM infra.alerts
GROUP BY date, alertname, severity, team, source;
```

### 3.2 AlertManager Webhook Receiver

AlertManager must forward all alert events (firing, resolved) to a webhook endpoint. The endpoint writes to `infra.alerts`.

**AlertManager config:**

```yaml
receivers:
  - name: 'alert-fatigue-webhook'
    webhook_configs:
      - url: 'http://alert-fatigue-collector:8080/webhook'
        send_resolved: true
```

**Patrol integration:**

Patrol-generated anomalies write to the same table directly:
```bash
# In patrol report phase
clickhouse-client --query "
  INSERT INTO infra.alerts (timestamp, alertname, severity, source, team, labels, fired_at)
  VALUES (now(), 'SiblingDead', 'P1', 'patrol', 'kyb-infra', {sibling: 'boss-claude-2'}, now())
"
```

## 4. Visualization

### 4.1 Grafana Dashboard: Alert Fatigue

A single dashboard with four rows:

**Row 1: Volume Overview**
- Time series: `rate(alerts_fired_total[1h])` by severity (stacked)
- Stat panel: Total alerts (last 24h), MTTA P50 (overall), AFI score
- Table: Top-10 most frequent alerts (last 7d)

**Row 2: Silence Analysis**
- Time series: `rate(alerts_silenced_total[1h])` by `silence_reason`
- Stat panel: Silence rate %
- Table: Active silences with remaining duration

**Row 3: False Positives**
- Time series: `rate(alerts_acknowledged_total{action_required=false}[1h])` by `false_reason`
- Stat panel: FP rate %
- Table: Worst offenders by FP count (last 7d)

**Row 4: MTTA**
- Heatmap: MTTA buckets by hour of day (identify after-hours degradation)
- Stat panel: MTTA P50/P90 by severity
- Table: Alerts with MTTA > 2x target (not resolved)

### 4.2 Alert Rules for Alert Fatigue

| Rule | Expression | Severity | Description |
|------|-----------|----------|-------------|
| AlertFatigueIndexHigh | `alert_fatigue_index > 0.5` | P1 | Composite fatigue score elevated |
| HighSilenceRate | `(alerts_silenced_total / alerts_fired_total) > 0.2` | P2 | Over 20% of alerts are silenced |
| HighFalsePositiveRate | `(alerts_false_positive_total / alerts_acknowledged_total) > 0.15` | P2 | Over 15% of alerts are false positives |
| MTTAHighP0 | `histogram_quantile(0.9, rate(alerts_mtta_seconds_bucket{severity="P0"}[1h])) > 900` | P1 | P0 MTTA P90 exceeds 15 minutes |
| MTTAHighP1 | `histogram_quantile(0.9, rate(alerts_mtta_seconds_bucket{severity="P1"}[1h])) > 3600` | P2 | P1 MTTA P90 exceeds 1 hour |
| AlertSpike | `rate(alerts_fired_total[5m]) / rate(alerts_fired_total[1h]) > 3` | P1 | 5x spike in alert rate over last 5 minutes |
| NoAcknowledgment > 24h | `(alerts_fired_total offset 24h) - (alerts_acknowledged_total offset 24h) > 0` | P2 | Alerts from 24h ago still unacknowledged |

## 5. Data Collection Pipeline

```
┌─────────────────────┐     ┌─────────────────┐     ┌──────────────┐
│  Prometheus          │     │  AlertManager    │     │  Webhook     │
│  Alert rules         │────▶│  Silence/Group   │────▶│  Receiver    │
└─────────────────────┘     └─────────────────┘     └──────┬───────┘
                                                            │
┌─────────────────────┐                                     │
│  Patrol              │─────────────────────────────────────┤
│  Anomaly reports     │                                     │
└─────────────────────┘                                     │
                                                            │
┌─────────────────────┐                                     │
│  Manual entry        │─────────────────────────────────────┤
│  (operators)         │                                     │
└─────────────────────┘                                     ▼
                                                    ┌──────────────┐
                                                    │  Vector or   │
                                                    │  Direct SQL  │
                                                    └──────┬───────┘
                                                            │
                                                            ▼
                                                    ┌──────────────┐
                                                    │  ClickHouse  │
                                                    │  infra.alerts│
                                                    └──────┬───────┘
                                                            │
                                                    ┌──────────────┐
                                                    │  Grafana     │
                                                    │  Dashboard   │
                                                    └──────────────┘
```

### 5.1 AlertManager Webhook Format

AlertManager sends POST to the webhook collector with JSON body:

```json
{
  "version": "4",
  "groupKey": "...",
  "status": "firing",
  "receiver": "alert-fatigue-webhook",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "DiskNearFull",
      "severity": "P2",
      "instance": "boss-01"
    },
    "annotations": {
      "summary": "Disk usage at 87%",
      "runbook": "docs/infra/runbooks/disk-full.md"
    },
    "startsAt": "2026-05-23T12:00:00Z",
    "endsAt": "0001-01-01T00:00:00Z",
    "fingerprint": "abc123"
  }]
}
```

### 5.2 Manual Entry via CLI

Operators can log false positives and actions manually:

```bash
# Mark an alert as false positive
kyb alert-fatigue annotate --alert-id <id> --false-reason threshold_too_sensitive

# Log action taken
kyb alert-fatigue annotate --alert-id <id> --action restarted-cc-connect

# Create silence with reason
kyb alert-fatigue silence --alert DiskNearFull --reason maintenance --duration 2h
```

## 6. Workflow

### 6.1 Weekly Alert Review

Every Monday, the on-call operator reviews the Alert Fatigue dashboard and:

1. **Top 5 most frequent alerts** -- decide if threshold needs adjustment
2. **Top 5 most silenced alerts** -- decide if the alert rule should be removed or reworked
3. **Top 5 false positives** -- identify root cause pattern
4. **MTTA outliers** -- alerts that took > 2x target to acknowledge

Actions from review are tracked as issues with label `alert-fatigue`.

### 6.2 Alert Lifecycle Gate

New alert rules MUST pass a quality gate before deployment:

| Gate | Criteria |
|------|----------|
| Expected firing rate | Documented: < 5/day in steady state |
| False positive analysis | Known edge cases documented |
| Runbook exists | Link to runbook with actionable steps |
| Tested with actual data | Fired in staging, confirmed correct |
| `for` duration set | At least 30s (no instant alerts except P0) |

### 6.3 Quarterly Alert Audit

Every quarter, run a full audit:

1. **Drop unused rules**: alerts that fired < 5 times in 90 days _and_ never prompted operator action
2. **Merge duplicates**: alerts that fire on the same condition from different sources
3. **Re-evaluate severity**: demote alerts that consistently produce no action
4. **Review silence patterns**: silences > 7 days with `too_noisy` reason must be resolved

### 6.4 MTTA Degradation Response

When MTTA exceeds target for a given severity:

| Step | Action | Owner | Timeline |
|------|--------|-------|----------|
| 1 | Identify the specific alerts dragging MTTA up | Dashboard review | < 1 hr |
| 2 | Check if they are noisy/ignored or genuinely missed | Slack poll operators | < 2 hr |
| 3 | If noisy: silence + create re-tuning ticket | Operator | < 1 hr |
| 4 | If missed: review notification channel reliability | Infra team | < 4 hr |
| 5 | Post-mortem if P0 MTTA exceeded target for > 1 hr | On-call | < 24 hr |

## 7. Implementation Phases

### Phase 1: Foundation (Week 1)

- [ ] Create `infra.alerts` table in ClickHouse
- [ ] Deploy AlertManager webhook receiver (lightweight HTTP server, writes to CK)
- [ ] Configure AlertManager to forward all alerts to webhook
- [ ] Validate: alerts appear in CK within 30s of firing
- [ ] Basic Grafana dashboard: alert volume over time

### Phase 2: Enrichment (Week 2)

- [ ] Add patrol anomaly reports to `infra.alerts` (write from `patrol.report` phase)
- [ ] Implement silence tracking: parse AlertManager silence API to log silences
- [ ] Deploy simple CLI (`kyb alert-fatigue annotate`) for manual entries
- [ ] Create Grafana dashboard rows: silence analysis, FP tracking

### Phase 3: MTTA & Automation (Week 3)

- [ ] Implement `acknowledged_at` tracking (webhook collector listens for alert ack)
- [ ] Compute MTTA in materialized view
- [ ] Deploy alert rules for alert fatigue (Section 4.2)
- [ ] Create weekly alert review template in Feishu/Notion

### Phase 4: Gate & Culture (Week 4)

- [ ] Add alert quality gate to alert deployment process
- [ ] First quarterly alert audit
- [ ] Automate alert fatigue score in Grafana stat panel
- [ ] Document in onboarding: how to classify silences and false positives

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Operators don't classify alerts | Medium | High | Default classification = "unknown". Degrade gracefully by treating unknown as "not actionable". Gamify classification rate. |
| AlertManager webhook goes down | Low | Medium | Queue-based retry or direct Prometheus alert API polling as fallback |
| False positive self-reporting bias | High | Medium | Cross-reference silence rate vs. FP rate. If both are low but MTTA is high, operators may be ignoring alerts without silencing them. |
| Table grows too fast | Low | Low | TTL = 365 days. Partition by month. ~10k alerts/day = ~300MB/year. Trivial. |
| Parallel alerting infra becomes a distraction | Medium | Low | The alert fatigue dashboard is itself checked by the weekly review. Don't create alerts for the alerts of the alerts. Single level of meta-alerting only (Section 4.2). |

## 9. Success Criteria

| Criterion | Current (estimated) | Target (90 days) |
|-----------|--------------------|--------------------|
| Alert volume | Unknown | < 20 / day per active rule |
| Silence rate | Unknown | < 5% |
| False positive rate | Unknown | < 5% |
| P0 MTTA P50 | Unknown | < 5 min |
| P1 MTTA P50 | Unknown | < 15 min |
| Alert fatigue index | Unknown | < 0.2 |

## 10. Related Documents

- `docs/infra/reviews/otel-patrol.md` -- patrol observability (tracing + alert sources)
- `docs/infra/observability-design.md` -- overall observability architecture
- `docs/infra/reviews/review-bridge-metrics-B2.md` -- bridge metrics design review
- `docs/infra/5min-patrol-guide.md` -- patrol system
