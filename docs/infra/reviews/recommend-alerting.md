---
decision: 稍后做
---

# Recommended Alerting Stack for kyb Infra

**Date**: 2026-05-23
**Status**: Single Recommendation
**Scope**: Unified alerting strategy across all kyb infra: cc-connect, patrol, Docker events, backups, disk, and incident SLOs.

---

After reviewing 10+ design documents covering alert rules, hook systems, incident severity, SLO compliance, alert fatigue, and notification routing, this doc consolidates every alerting decision into a single recommendation.

**Prerequisite reading**: `docs/infra/reviews/recommended-stack.md` (the underlying observability stack -- ClickHouse + Alloy + Redpanda + Grafana -- is assumed throughout).

---

## Table of Contents

1. [Stack Decision: Grafana Alerting](#1-stack-decision-grafana-alerting)
2. [Rejected Alternatives](#2-rejected-alternatives)
3. [Consolidated Alert Rule Catalog](#3-consolidated-alert-rule-catalog)
4. [Notification Routing](#4-notification-routing)
5. [Alert Lifecycle & Fatigue Prevention](#5-alert-lifecycle--fatigue-prevention)
6. [Implementation Phases](#6-implementation-phases)
7. [Cost-Benefit Summary](#7-cost-benefit-summary)

---

## 1. Stack Decision: Grafana Alerting

The recommendation is **Grafana Managed Alerting** as the single alerting engine, with **Prometheus recording rules** feeding metrics to the Grafana evaluator.

### Architecture

```
                     DATA SOURCES
    ┌──────────────────────────────────────────────────────┐
    │  ClickHouse  │  Prometheus  │  Patrol (diary)  │ ... │
    └──────┬───────┴──────┬───────┴──────┬──────────────┘
           │              │              │
           ▼              ▼              ▼
    ┌──────────────────────────────────────────────────────┐
    │              Grafana Managed Alerting                 │
    │                                                      │
    │  - Queries ClickHouse directly (P0/P1 infra alerts)   │
    │  - Queries Prometheus (metric-based alerts)           │
    │  - Handles evaluation interval, `for` duration,       │
    │    silences, grouping, and routing                    │
    └──────────────────────┬───────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌──────────┐   ┌────────────┐   ┌──────────────┐
    │ Feishu   │   │ Diary log │   │ TTS (P0)     │
    │ Group    │   │ (patrol)  │   │ phone call   │
    └──────────┘   └────────────┘   └──────────────┘
```

### Why Grafana Managed Alerting

| Criterion | Grafana Alerting | Prometheus + AlertManager | cc-connect hooks + patrol |
|-----------|-----------------|--------------------------|---------------------------|
| **Data source support** | ClickHouse + Prometheus + any other | Prometheus only | None (hook-only) |
| **Evaluation engine** | Built-in, per-rule configurable interval | Built-in, PromQL only | Custom shell scripts |
| **Multi-cluster alerts** | Native (ClickHouse datasource sees all clusters) | Per-cluster Prometheus only (unless federated) | Per-cluster heartbeats only |
| **`for` duration** | Yes, natively | Yes, natively | Manual implementation |
| **Silences** | Built-in with expiry | AlertManager built-in | None |
| **Notification routing** | Contact points + policies | AlertManager routes + receivers | Ad-hoc feishu webhooks |
| **Alert history** | `grafana_alerting` internal state | AlertManager silences API | None (no history) |
| **Operational cost** | Already running (Grafana is deployed) | Already running (Prometheus is deployed for metrics) | Would need new hook engine |
| **Configuration as code** | Terraform provider or Grafana HTTP API | YAML files in git | Bash scripts in git |

### Decision Rationale

**Grafana Managed Alerting wins on three decisive factors:**

1. **Direct ClickHouse queries** -- The recommended observability stack stores all telemetry in ClickHouse. Grafana Alerting can query ClickHouse directly via the Grafana ClickHouse datasource. Prometheus + AlertManager cannot query ClickHouse without a separate bridge. This means infra alerts (crash loops, backup stale, disk exhaustion, heartbeat reliability) evaluate from their native storage without replicating data to Prometheus.

2. **Single engine** -- With both Prometheus and ClickHouse as data sources, there is one alerting engine, one notification routing policy, one silence management interface, and one alert history view. Prometheus + AlertManager + Grafana Alerting would be two engines with separate configs, separate histories, and potential for routing conflicts.

3. **Already deployed** -- Grafana is already running on the central cluster. Adding alert rules requires no new containers, no new YAML pipeline, and no new credential management.

### Where Prometheus Recording Rules Still Apply

Prometheus is retained for **metric-level recording rules** that feed into Grafana alerts:

```promql
# Recording rule (Prometheus): compute MTTR from ClickHouse via prometheus metrics exporter
- record: incident_slo:attainment:30d
  expr: sum(increase(incident_slo_met_total[30d])) by (severity) / sum(increase(incident_response_log_total[30d])) by (severity)
```

But the **alert evaluation** itself (threshold check, `for` duration, notification routing) lives in Grafana, not in Prometheus `groups.rules`. This keeps the alerting configuration in one place (Grafana) while using Prometheus for what it does best (fast metric computation from Prometheus-native data).

---

## 2. Rejected Alternatives

### Rejected: Prometheus + AlertManager as sole engine

| Factor | Why Rejected |
|--------|-------------|
| ClickHouse data | Cannot query ClickHouse natively. Would need a `clickhouse_exporter` or custom metrics bridge for every alert rule that targets infra data. Doubles the data path: CK -> exporter -> Prometheus -> AlertManager vs. CK -> Grafana. |
| Multi-cluster view | Prometheus is per-cluster. Cross-cluster alerts require either Prometheus federation (extra infra) or a global AlertManager (extra complexity). Grafana queries ClickHouse which already has all clusters. |
| Rule duplication rules | Alert rules that trigger on Prometheus metrics (CPU, memory) would be in AlertManager. Rules that trigger on ClickHouse data (crash loops, backup age) would need a bridge. Result: two separate rule sets with no unified view. |

### Rejected: cc-connect hooks + patrol as alerting engine

| Factor | Why Rejected |
|--------|-------------|
| No evaluation engine | cc-connect native hooks fire events but do not evaluate conditions across time. "turn_duration > 30s for 5 minutes" requires a sliding window evaluator -- patrol can approximate this (5min polling) but lacks sub-minute resolution and `for` duration semantics. |
| No alert history | No built-in way to see "how many times did this alert fire last week?" or "what was the MTTA for P0 alerts?" Without history, trend analysis and fatigue detection are impossible. |
| No routing policy | Each hook script independently decides where to send notifications. No centralized escalation, grouping, or silence management. |
| Patrol cycle is too slow | Patrol runs every 5 minutes. P0 alerts (crash loop, cc-connect down) need sub-minute detection. Grafana evaluates ClickHouse queries every 10-30s. |

cc-connect hooks remain useful as **alert triggers** (the hook fires, writes to ClickHouse, Grafana evaluates the stored data) but not as the alert evaluator itself.

---

## 3. Consolidated Alert Rule Catalog

Every proposed alert rule from every review document is consolidated below. Rules are grouped by **domain** (the service or concern they monitor), with severity, evaluation interval, `for` duration, data source, and originating document.

### 3.1 cc-connect & Bridge Health

| Rule | Severity | Condition | Eval | For | Source | Notes |
|------|----------|-----------|------|-----|--------|-------|
| ContainerDown | **P0** | cc-connect container `status != running` for > 30s | 15s | 30s | bridge-hooks C2 | Docker event watcher + ClickHouse, not healthcheck ping |
| ClaudeNoResponse | **P1** | 3 consecutive messages received with no response | 30s | 1m | bridge-hooks C3 | cc-connect hook event `response.complete` missing after `message.received` |
| MessageLatencyHigh | **P1** (was P2 in original) | turn_duration > 30s for 5 consecutive minutes | 30s | 5m | bridge-hooks C3 review | Upgraded from P2 per review: 30s latency makes the bot unusable |
| MessageReceivedNoResponse | **P1** | message received but Claude never replies (per-message counter, not the 3-count aggregate) | 30s | 2m | bridge-hooks C3 | Different from ClaudeNoResponse: this fires on every timed-out message, not a 3-count threshold |
| TokenExpired | **P1** | Feishu API token refresh fails | 1m | 1m | bridge-hooks original | Auto-retry logic should run before alert fires; alert only if retry also fails |
| PermissionStuck | **P2** | Permission request 10 min unresponded | 1m | 10m | bridge-hooks original | After 10m, escalate to P1 and auto-deny |
| ccHeartbeatStale | **P1** | cc-connect heartbeat missing for 2 consecutive cycles | 30s | 2m | bridge-hooks C3 | cc-connect should emit periodic heartbeat; if missing for 2 cycles, assume dead |
| SessionTimeout | **P2** | Session exceeds 30min without completion | 1m | 5m | bridge-hooks C3 | Catches stuck sessions that haven't crashed |

### 3.2 Crash Loop Detection

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| CrashLoopInstant | **P1** | >= 3 container `die` events with exit code > 0 in 5 min | 1m | 0s | crash-loop.md |
| CrashLoopFast | **P2** | >= 5 container `die` events in 30 min | 1m | 0s | crash-loop.md |
| CrashLoopSlow | **P3** | >= 10 container `die` events in 24 h | 5m | 0s | crash-loop.md |
| DetectorDown | **P1** | crash-loop detector heartbeat not seen in > 10 min | 1m | 5m | crash-loop.md |

### 3.3 Heartbeat & Patrol Reliability

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| ScoreCritical | **P1** | `heartbeat_reliability_score < 50` for any patrol agent | 1m | 5m | heartbeat-reliability.md |
| ScoreUnstable | **P2** | `heartbeat_reliability_score < 70` for any patrol agent | 1m | 5m | heartbeat-reliability.md |
| ScoreDropping | **P2** | Score dropping > 10 points per 30 min (derivative alert) | 1m | 15m | heartbeat-reliability.md |
| ClusterUnstable | **P1** | Average score across all agents < 70 | 1m | 5m | heartbeat-reliability.md |
| NoScoreData | **P1** | `absent(heartbeat_reliability_score[10m])` | 1m | 5m | heartbeat-reliability.md |
| PatrolBrotherDead | **P2** | One patrol brother heartbeat > 15 min stale | 5m | 5m | bridge-hooks C3 |
| HookSilence | **P2** | No hook events received from cc-connect for > 15 min | 5m | 5m | bridge-hooks C3 |

### 3.4 Disk & Resource Monitoring

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| DiskWarning | **P2** | `avail_bytes < cluster_specific_warning` OR `days_until_full < 30` | 5m | 15m | disk-growth.md |
| DiskCritical | **P1** | `avail_bytes < cluster_specific_critical` OR `days_until_full < 7` | 5m | 5m | disk-growth.md |
| DiskHardCap | **P1** | `used_pct > 95` (bypasses prediction) | 5m | 0s | disk-growth.md |

Cluster-specific thresholds:

| Cluster | Warning | Critical |
|---------|---------|----------|
| Mac/Orbstack (260 GiB) | < 20 GiB OR < 30 days | < 5 GiB OR < 7 days |
| Aliyun/sim (40 GiB) | < 5 GiB OR < 14 days | < 2 GiB OR < 3 days |
| Office/nuc8 (256 GiB) | < 20 GiB OR < 30 days | < 5 GiB OR < 7 days |

### 3.5 Backup Monitoring

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| StaleBackupPG | **P1** | PG dump age > 36h (daily schedule + 50% buffer) | 1h | 1h | backup-monitor.md |
| StaleBackupCK | **P1** | CK backup age > 36h | 1h | 1h | backup-monitor.md |
| StaleBackupConfig | **P2** | Host config backup age > 48h | 1h | 1h | backup-monitor.md |
| BackupSizeDrop | **P1** | Backup size < 50% of 7-day rolling average | 1h | 2h | backup-monitor.md |
| BackupSizeSpike | **P2** | Backup size > 200% of 7-day rolling average | 1h | 2h | backup-monitor.md |
| BackupEmpty | **P1** | Backup file size = 0 | 1h | 0s | backup-monitor.md |
| IntegrityFail | **P1** | `gzip -t` or `tar -tzf` fails | 5m | 0s | backup-monitor.md |
| RestoreTestFail | **P0** | Weekly restore test fails or no result in 8 days | 1h | 1h | backup-monitor.md |
| BackupHostUnreachable | **P2** | Backup host SSH connection fails | 5m | 5m | backup-monitor.md |
| BackupHostDiskLow | **P2** | Free disk on backup host < 20% | 5m | 1h | backup-monitor.md |

### 3.6 Alert Fatigue Meta-Monitoring

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| AlertFatigueIndexHigh | **P1** | Composite AFI score > 0.5 | 1h | 1h | alert-fatigue.md |
| HighSilenceRate | **P2** | > 20% of alerts silenced over 7-day rolling window | 1h | 1h | alert-fatigue.md |
| HighFalsePositiveRate | **P2** | > 15% of acknowledged alerts are false positives over 7-day window | 1h | 1h | alert-fatigue.md |
| MTTAHighP0 | **P1** | P0 MTTA P90 > 15 min over 7-day window | 1h | 1h | alert-fatigue.md |
| MTTAHighP1 | **P2** | P1 MTTA P90 > 1 hr over 7-day window | 1h | 1h | alert-fatigue.md |
| AlertSpike | **P1** | Alert rate in last 5 min > 3x the rate of last hour | 1m | 2m | alert-fatigue.md |
| NoAcknowledgment | **P2** | Alerts from 24h ago still unacknowledged | 1h | 1h | alert-fatigue.md |

### 3.7 Incident SLO Compliance

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| SLOP0Breach | **P1** (pages) | P0 SLO attainment < 99% over 30d (min 5 incidents) | 1h | 10m | incident-slo.md |
| SLOP1Breach | **P2** (ticket) | P1 SLO attainment < 95% over 30d (min 5 incidents) | 1h | 10m | incident-slo.md |
| TTASpike | **P2** (ticket) | Any severity TTA trending up > 20% week-over-week | 1h | 1h | incident-slo.md |
| AutoResolveRateHigh | **P1** (pages) | Auto-resolve rate > 50% for P0/P1 (any window) | 1h | 10m | incident-slo.md |

### 3.8 Incident Pattern Meta-Alerts

| Rule | Severity | Condition | Eval | For | Source |
|------|----------|-----------|------|-----|--------|
| TooManyP0Incidents | **P1** | > 3 P0 incidents in 7 days | 1h | 1h | incident-severity.md |
| MTTRDegradationP1 | **P3** | P1 p90 MTTR increased 50% over 7d vs 30d baseline | 1h | 6h | incident-severity.md |
| IncidentsClusterBurst | **P1** | Single service has > 5 incidents in 24h | 5m | 5m | incident-severity.md |

### 3.9 Summary by Severity

| Severity | Count | Escalation |
|----------|-------|------------|
| **P0** | 2 | Immediate: Feishu @all + TTS phone + diary critical |
| **P1** | 17 | Feishu @oncall + diary warning; page within 5 min |
| **P2** | 13 | Feishu ticket + service owner mention; acknowledge within 1 hr |
| **P3** | 3 | Daily digest; no immediate notification |

Total: **35 alert rules** across 8 domains.

### 3.10 Evaluation Interval Guidelines

| Alert domain | Typical interval | Rationale |
|-------------|------------------|-----------|
| cc-connect health (P0/P1) | 15-30s | Service is user-facing; sub-minute detection required |
| Crash loop (P1/P2) | 60s | Docker event ingestion lag + aggregation window |
| Heartbeat reliability (P1/P2) | 60s | Patrol runs every 5 min; evaluation faster to catch late beats |
| Disk (P1/P2) | 5m | Disk changes slowly; 5-min evaluation is sufficient |
| Backup (P0/P1/P2) | 1h | Backup runs nightly; minute-level evaluation is wasteful |
| SLO compliance (P1/P2) | 1h | 30d rolling window; hourly evaluation is sufficient |
| Alert fatigue meta (P1/P2) | 1h | Also 7d rolling window; hourly evaluation is sufficient |

---

## 4. Notification Routing

### 4.1 Routing Policy

```
SEVERITY:  P0                P1                P2                P3
           │                 │                 │                 │
           ▼                 ▼                 ▼                 ▼
CHANNEL:  Feishu @all    Feishu @oncall    Feishu group      Daily digest
          TTS phone       Diary warning     Diary info        (no page)
          Diary critical
```

### 4.2 Contact Points

| Channel | Type | Destination | Use |
|---------|------|-------------|-----|
| **Feishu Infra Group** | Feishu webhook | Infra ops group | All P0/P1/P2 alerts |
| **TTS Phone** | Custom (kyb notify urgent) | On-call phone | P0 alerts only |
| **Diary** | ClickHouse insert | `infra.incident_log` | All alerts (logged) |
| **Daily Digest** | Patrol-generated report | Feishu group + diary | P3 + daily summary |

### 4.3 Escalation

| Condition | Action |
|-----------|--------|
| P0 not acknowledged in 5 min | Re-notify Feishu @all + escalate to team lead |
| P1 not acknowledged in 15 min | Escalate to on-call backup |
| P0 duration exceeds 30 min | Super-boss dispatches diagnostic agent + schedules bridge call |
| Same service has 3+ P1 in 7 days | Escalate service to P0 monitoring tier |

### 4.4 Silence & Maintenance

- **Maintenance windows**: Support silencing per-cluster or per-service during planned maintenance. Silences auto-expire.
- **Silence reason required**: Every silence must carry a `silence_reason` label (one of: `false_positive`, `known_issue`, `maintenance`, `too_noisy`, `duplicate`).
- **Silence max duration**: 7 days for `too_noisy`; must create re-tuning ticket.

---

## 5. Alert Lifecycle & Fatigue Prevention

### 5.1 Every Alert Must Have

| Attribute | Required | Example |
|-----------|----------|---------|
| Runbook URL | Yes (link to actionable steps) | `docs/infra/runbooks/disk-full.md` |
| Expected firing rate | Yes (< 5/day in steady state) | ~1-2/day per cluster |
| `for` duration | Yes (>= 30s except P0) | 5m |
| False positive analysis | Yes (known edge cases documented) | "May fire during Docker restart after config change" |
| Severity justification | Yes (why P1 not P2) | "Container down = complete service outage" |

Grafana enforces these via alert rule annotations (`runbook`, `summary`, `description`).

### 5.2 New Alert Quality Gate

Before deploying any new alert rule:

1. Document expected firing rate (< 5/day in steady state).
2. Document known false positive edge cases.
3. Link to runbook with actionable steps.
4. Test with actual data (fire in staging, confirm correct).
5. Set `for` duration (>= 30s except P0).

### 5.3 Quarterly Audit

Every quarter:

1. Drop unused rules: alerts that fired < 5 times in 90 days and never prompted operator action.
2. Merge duplicates: alerts that fire on the same condition from different sources.
3. Re-evaluate severity: demote alerts that consistently produce no action.
4. Review silence patterns: silences > 7 days with `too_noisy` reason must be resolved.

### 5.4 Alert Fatigue Index

Composite score computed weekly:

```
AFI = (silence_rate * 0.3) + (fp_rate * 0.4) + (mtta_degradation * 0.3)

silence_rate    = silences / total_fired (rolling 7d)
fp_rate         = false_positives / total_acknowledged (rolling 7d)
mtta_degradation = max(0, (mtta_p90_actual / mtta_p90_target) - 1)
```

| Score | Status | Action |
|-------|--------|--------|
| 0 - 0.2 | Healthy | None |
| 0.2 - 0.5 | Deteriorating | Review top offenders |
| 0.5 - 1.0 | Fatigued | Mandatory tuning session |
| > 1.0 | Critical | Alerting system is broken; triage immediately |

---

## 6. Implementation Phases

### Phase 0: Foundation -- NOW (done)

- [x] Grafana running on Mac/Orbstack
- [x] ClickHouse running on Mac/Orbstack
- [x] Prometheus running (for recording rules)

### Phase 1: Core Service Alerts (Week 1)

- [x] Configure Grafana ClickHouse datasource (existing)
- [ ] Define Grafana alert rules for: ContainerDown, ClaudeNoResponse, MessageLatencyHigh, TokenExpired, PermissionStuck (cc-connect bridge group)
- [ ] Set up Feishu webhook contact point in Grafana
- [ ] Create initial notification routing policy (per severity)
- [ ] Create `infra.incident_log` table for alert history
- [ ] Verify: inject a test alert, confirm Feishu delivery within 30s

### Phase 2: Crash Loop + Heartbeat (Week 1-2)

- [ ] Define Grafana alert rules for: CrashLoopInstant, CrashLoopFast, CrashLoopSlow, DetectorDown
- [ ] Define Grafana alert rules for: ScoreCritical, ScoreUnstable, ClusterUnstable, PatrolBrotherDead, HookSilence
- [ ] Connect crash loop and heartbeat source tables (CK queries) to Grafana alerts
- [ ] Create Grafana dashboard row: "Active Alerts" (shows currently-firing rules)
- [ ] Test with synthetic data: insert crash events, verify P1 fires

### Phase 3: Disk + Backup (Week 2-3)

- [ ] Define Grafana alert rules for: DiskWarning, DiskCritical, DiskHardCap
- [ ] Define Grafana alert rules for: StaleBackupPG, StaleBackupCK, IntegrityFail, RestoreTestFail
- [ ] Set up cluster-specific threshold config (per-cluster labels or separate alert rules)
- [ ] Build `cluster_disk_exhaustion` prediction pipeline
- [ ] Deploy backup monitor script on patrol cycle
- [ ] Verify backup alerts fire correctly after 36h of no backup

### Phase 4: SLO + Meta-Monitoring (Week 3-4)

- [ ] Define Grafana alert rules for: SLOP0Breach, SLOP1Breach, TTASpike, AutoResolveRateHigh
- [ ] Define Grafana alert rules for: TooManyP0Incidents, IncidentsClusterBurst
- [ ] Define Grafana alert rules for: AlertFatigueIndexHigh, HighSilenceRate, HighFalsePositiveRate, AlertSpike
- [ ] Configure AlertManager webhook forwarding to `infra.incident_log`
- [ ] Build "Alert Fatigue" meta-dashboard
- [ ] Run first weekly alert review

### Phase 5: Tuning (Ongoing)

- [ ] Validate alert firing rates against targets (< 5/day per rule steady state)
- [ ] Tune `for` durations based on false positive observations
- [ ] Adjust severity classifications if any rule consistently produces no action
- [ ] Run first quarterly alert audit
- [ ] Create "New Alert Rule" checklist for future rule additions

---

## 7. Cost-Benefit Summary

### What We Gain

| Capability | Before | After |
|------------|--------|-------|
| Alert evaluation | Patrol polling (5-min granularity, ClickHouse-only) | Grafana Managed Alerting (15s-1h granularity, any datasource) |
| Notification routing | Ad-hoc Feishu webhooks per script | Centralized routing policy with escalation |
| Alert history | None | All alerts logged to `infra.incident_log` |
| Silence management | Manual (disable script) | Grafana silences with expiry + reason labels |
| Multi-cluster view | Per-cluster patrol silos | Single Grafana alert rules querying ClickHouse |
| Alert fatigue detection | None | AFI score + meta-alerts |
| SLO compliance | None | Per-severity TTA/TTR attainment tracking |
| Disk prediction | None (reactive df -h) | Linear regression + exhaustion date prediction |
| Backup integrity | None (blind trust) | Freshness + size + integrity + restore testing |

### Cost

| Resource | Value |
|----------|-------|
| New infrastructure | **None** -- Grafana, Prometheus, and ClickHouse are already running. All alert rules are configuration, not deployment. |
| Alert rule count | 35 initial rules (17 P1, 13 P2, 3 P3, 2 P0) |
| ClickHouse storage: alert history | `infra.incident_log`: at < 500 alerts/day x 1 KB each = ~55 MB/year. Trivial. |
| ClickHouse storage: alert fatigue | `infra.alerts` (from alert-fatigue.md): ~10k alerts/day x 500 B = ~1.8 GB/year. Still small. |
| Maintenance | Weekly alert review (30 min/week), quarterly audit (2 hrs/quarter) |

### Risk

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Grafana alerting configuration drift | Medium | Git-backed provisioning (Grafana HTTP API or Terraform) |
| Too many P1 alerts cause fatigue | Medium | Quality gate for new rules + monthly audit + AFI monitoring |
| ClickHouse query latency causes missed evaluation | Low | Set `for` duration >= 2x evaluation interval; CK queries on indexed columns are sub-second |
| Feishu webhook rate limited | Low | P0 alerts are < 5/day; well within Feishu's limit |
| Alert rule misconfiguration | Medium | Test with synthetic data before production deployment |

---

## Appendix: Rule Origins by Document

| Document | Source | Rules Contributed |
|----------|--------|------------------|
| `designs/bridge-hooks-alerting.md` | Raw design | TokenExpired, PermissionStuck |
| `reviews/review-bridge-hooks-C2.md` | Grafana gap review | ContainerDown + evaluation intervals + notification routing |
| `reviews/review-bridge-hooks-C3.md` | Coverage gap review | MessageLatencyHigh (P1 upgrade), MessageReceivedNoResponse, ccHeartbeatStale, SessionTimeout, HookSilence, PatrolBrotherDead |
| `reviews/crash-loop.md` | Crash loop detection | CrashLoopInstant, CrashLoopFast, CrashLoopSlow, DetectorDown |
| `reviews/heartbeat-reliability.md` | Patrol reliability | ScoreCritical, ScoreUnstable, ScoreDropping, ClusterUnstable, NoScoreData |
| `reviews/alert-fatigue.md` | Meta-monitoring | AlertFatigueIndexHigh, HighSilenceRate, HighFalsePositiveRate, MTTAHighP0, MTTAHighP1, AlertSpike, NoAcknowledgment |
| `reviews/disk-growth.md` | Disk monitoring | DiskWarning, DiskCritical, DiskHardCap |
| `reviews/backup-monitor.md` | Backup monitoring | StaleBackupPG, StaleBackupCK, StaleBackupConfig, BackupSizeDrop, BackupSizeSpike, BackupEmpty, IntegrityFail, RestoreTestFail, BackupHostUnreachable, BackupHostDiskLow |
| `reviews/incident-severity.md` | Incident tracking | TooManyP0Incidents, MTTRDegradationP1, IncidentsClusterBurst |
| `reviews/incident-slo.md` | SLO compliance | SLOP0Breach, SLOP1Breach, TTASpike, AutoResolveRateHigh |

---

## Appendix: Grafana Alert Rule Template

Use this template for every new Grafana alert rule:

```yaml
# Grafana managed alert rule (via provisioning API or Terraform)
# Domain: cc-connect / bridge
# Source: review-bridge-hooks-C2.md

alert: ContainerDown
severity: P0
for: 30s
evaluate_every: 15s

# ClickHouse query
query: |
  SELECT count() AS down
  FROM infra.docker_events
  WHERE event_type = 'container:die'
    AND container_name = 'kyb-infra-cc-connect'
    AND event_time >= now() - INTERVAL 30 SECOND

condition: down > 0

annotations:
  summary: "cc-connect container down or crashed"
  description: "cc-connect container has been down for {{ $value }} seconds"
  runbook: "docs/infra/runbooks/cc-connect-down.md"
  expected_firing_rate: "< 1/week"
  severity_justification: "P0: complete service outage, all users affected"
  alert_owner: "kyb-infra"

labels:
  team: kyb-infra
  service: cc-connect
  cluster: mac-orbstack

notification_channel: feishu-infra-group
escalation: escalate-after=5m, escalate-to=team-lead
```

---

## Summary

**One engine: Grafana Managed Alerting.** All 35 alert rules across 8 domains are evaluated by Grafana, querying ClickHouse for infra events (crash loops, disk, backups, heartbeats, alert history) and Prometheus for metric-derived values (SLO attainment, MTTA quantiles). Notification routing is centralized with per-severity escalation. Alert fatigue is detected and prevented by the Alert Fatigue Index, a quality gate for new rules, and a quarterly audit cycle.

The entire alerting system requires **zero new infrastructure** -- Grafana, Prometheus, and ClickHouse are already running. Implementation is 3-4 weeks phased, starting with core service health (Phase 1) and ending with SLO compliance and meta-monitoring (Phase 4).

> ／人◕ ‿‿ ◕人＼
