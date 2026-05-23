---
decision: 现在就做
---

# Alerting Dimension: Consolidated Summary

**Date:** 2026-05-23
**Scope:** All `docs/infra/reviews/*.md` files analyzed for alert rules, severity levels, notification channels, and gaps.

---

## 1. Systems With Explicit Alert Designs

### 1.1 Infrastructure & Container Lifecycle

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **Docker Events** | `docker-events.md` | Crash loop (3x die+restart in 5min = P1), OOM kill (P0), unhealthy sustained (P2), health flapping (P1) | P0-P2 |
| **Crash Loop Detection** | `crash-loop.md` | Instant (3x/5min = P1), Fast (5x/30min = P2), Slow (10x/24h = P3) | P1-P3 |
| **Boss Lifecycle** | `boss-lifecycle.md` | BossDead (>15min = P2), BossCrashed (P1), BossAbandoned (>24h idle = P3), BossRestartLoop (>3 events in 1h = P2), TooManyIdle (>50% idle >4h = P3), OrphanSandbox (P2), IncarnationSpike (P2) | P1-P3 |
| **cAdvisor Metrics** | `cadvisor-metrics.md` | References Prometheus alerting (no explicit rules defined) | N/A |
| **Container Network Latency** | `container-network-latency.md` | Degradation alert, unreachable alert, packet loss alert (no explicit severities defined) | Unspecified |
| **Chaos Engineering** | `chaos-engineering.md` | Experimental verification layer; assumes alerts exist but does not define new ones | N/A |

### 1.2 Resource / Capacity Alerting

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **Disk Growth** | `disk-growth.md` | Warning threshold (< 30 days to exhaustion), Critical threshold (< 7 days to exhaustion), cluster-specific tuning | P2-P1 |
| **Dangling Images / Disk Waste** | `dangling-images.md` | Waste exceeds threshold (reclaimable > 30% of total), growth rate anomaly, auto-cleanup trigger | P2 |
| **Image Pull Duration** | `image-pull.md` | Slow pull alerts (threshold + anomaly), registry health (request rate, error rate) | Unspecified |
| **Registry Mirror Latency** | `registry-latency.md` | Latency > 5s sustained (P2), > 50% failure rate over 5min window (P2), mirror auto-failover | P2 |
| **Build Cache** | `cache-hit.md` | Low hit ratio (avg < 40% over 3 builds = warning), cache disk pressure (>12GB warning, >14GB critical), build duration spike (>3x avg = info), stale storage metrics (>2h = warning) | info-critical |
| **Volume Usage** | `volume-usage.md` | References threshold-based alerts but no explicit rules defined | N/A |

### 1.3 Service Health & SLOs

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **Error Budget** | `error-budget.md` | MWMBR: P0 (14x burn rate over 1h), P1 (6x over 6h), P2 (2x over 3d). Per-tier thresholds for Tier-0 (99.99%) through Tier-3 (99.0%). Multi-window AND logic to prevent false positives. Full Prometheus alert rule templates. | P0-P3 |
| **Incident Severity** | `incident-severity.md` | Meta-incidents: TooManyP0 (>3/week = page), MTTRDegradationP1 (50% increase over baseline = ticket), IncidentsClusterBurst (>5/24h per service = page), IncidentNotAcknowledged (>15min for P0/P1 = page). Full escalation rules + auto-tagging. | P0-P3 |
| **Backup Monitor** | `backup-monitor.md` | Stale PG dump (>36h = P1), Stale CK backup (>36h = P1), Stale Config backup (>48h = P2), Size drop >50% (P1), Size spike >200% (P2), Empty backup (P1), Integrity fail (P1), Restore test fail (P0), Host unreachable (P2), Host disk >80% (P2), Config drift (P2) | P0-P2 |
| **Heartbeat Reliability** | `heartbeat-reliability.md` | References heartbeat-based liveness alerts | Unspecified |

### 1.4 Observability & Monitoring Stack

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **Alert Fatigue** | `alert-fatigue.md` | Meta-monitoring: AFI > 0.5 (P1), HighSilenceRate (>20% = P2), HighFPRate (>15% = P2), MTTAHighP0 (>15min = P1), MTTAHighP1 (>1h = P2), AlertSpike (5x spike = P1), NoAck >24h (P2). Full ClickHouse schema + Grafana dashboard + weekly review workflow. | P1-P2 |
| **Config Drift** | `config-drift.md` | Config mismatch between git baseline and running config (P2), Generated file stale (P2), Container runtime config drift (P2) | P2 |
| **Secret Rotation** | `secret-rotation.md` | Secret age > 90% of rotation policy (P3), Secret expired (P1), TLS certificate expiring in <30 days (P2), <7 days (P1) | P1-P3 |
| **Boss Decision Latency** | `boss-decision-latency.md` | PDL too slow (P90 >30s = P2), FRL too slow (P90 >60s = P2), No patrol data from cluster >10min (P1), E2E degradation (P90 >60min over 24h = P3), Issue slipping (IAL >30min = P3) | P1-P3 |
| **Claude Telemetry** | `claude-telemetry.md` | No explicit alert rules defined (gap noted: "no rules for error rate spikes, silent agents, or session anomalies") | N/A |
| **CK Query Monitor** | `ck-query-monitor.md` | Slow query thresholds (P50/P90/P99 latency), memory hogs, but no formal alert rules defined | N/A |

### 1.5 Bridge / Integration Alerting

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **cc-connect WS Health** | `cc-ws-health.md` | Reconnect storm (>5/h = P1), Connection flapping (never stable >5min = P1), Message gap >5min (P2), Zombie connection (P2) | P1-P2 |
| **Kafka Consumer Lag** | `kafka-lag.md` | Consumer lag > threshold (P1), Lag > retention window (P0), Rebalance storm (P2), Under-replicated partitions (P2), Broker health (CPU/memory/disk) | P0-P2 |
| **Feishu Webhook Intercept** | `feishu-webhook-intercept.md` | Delivery failure, rate limit exceeded | Unspecified |
| **Feishu Rate Limit** | `feishu-rate-limit.md` | Approaching rate limit (P2), Rate limit hit (P1) | P1-P2 |
| **Feishu Delivery** | `feishu-delivery.md` | Message delivery failure, delivery latency degradation | Unspecified |
| **Sidecar Intercept** | `sidecar-intercept.md` | References health-check-based alerts | N/A |
| **Hooks Kafka/Direct CK** | `hooks-kafka.md`, `hooks-direct-ck.md`, `cc-hooks-direct-ck.md` | Pipeline failure alerts implied but no explicit rules | N/A |

### 1.6 Security / Compliance Alerting

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **Base Image Age** | `base-image-age.md` | Base image >30 days old (P2), Base drift >14 days (P2), Critical CVE on kyb-base (P1), High CVE count >25 (P2), Third-party stale >90 days (P3), Scan pipeline down >48h (P2) | P1-P3 |
| **Vulnerability Scan** | `vuln-scan.md` | Critical CVE in deployed image (P1), High count > threshold (P2), Fix age > policy (P2), New CVE regression after update (P3) | P1-P3 |
| **Network Compliance** | `network-compliance.md` | Unauthorized port exposed, unexpected egress, proxy bypass | Unspecified |
| **Proxy Intercept** | `proxy-intercept.md` | References failure alerts but no explicit rules | N/A |

### 1.7 CI / Pipeline Alerting

| System | File | Alert Rules | Severities |
|--------|------|-------------|------------|
| **CI Flakiness** | `ci-flakiness.md` | Master failure rate > 10% (P1), Infrastructure failure spike (P2), Flaky test detected (P3), Cancellation rate > threshold (P2) | P1-P3 |
| **MR Cycle Time** | `mr-cycle-time.md` | Cycle time degradation | Unspecified |
| **Stale Branches** | `stale-branches.md` | Branch age threshold | Unspecified |

### 1.8 Tracking / Analytics (Informational Only)

| System | File | Notes |
|--------|------|-------|
| `session-monitor.md` | Session count, age, last-activity thresholds | Context for zombie session detection |
| `session-duration.md` | Session duration distribution | Informational |
| `model-usage.md` | Token/cost tracking | Cost alerts implied |
| `token-cost.md` | Per-model token costs | Budget alerts possible |
| `user-activity.md` | User engagement metrics | No alert rules defined |
| `tool-usage.md` | Tool call frequency | No alert rules defined |
| `exit-codes.md` | Exit code distribution | No alert rules defined |
| `oncall.md` | On-call scheduling | No alert rules defined |
| `postmortem.md` | Post-incident review process | No alert rules defined |
| `multi-tenancy.md` | Per-tenant resource isolation | No alert rules defined |
| `permission-latency.md` | Permission check latency | No alert rules defined |
| `system-load.md` | Host load average monitoring | No alert rules defined |
| `node-exporter.md` | Host-level metrics | No alert rules defined |
| `prometheus-scrape.md` | Scrape configuration design | No alert rules defined |
| `grafana-alloy.md` | Grafana Alloy pipeline design | No alert rules defined |
| `grafana-provisioning.md` | Dashboard provisioning | No alert rules defined |
| `sing-box-metrics.md` | Sing-box proxy metrics | No alert rules defined |

---

## 2. Severity Classification Systems

Two parallel systems exist in the designs:

### 2.1 Incident Severity (from `incident-severity.md`)

| Severity | Definition | Ack SLA | Channel |
|----------|-----------|---------|---------|
| **P0** | Complete outage, data loss, security breach. All users affected. | < 5 min | Feishu @all + TTS |
| **P1** | Major feature degraded, >10% users affected, data at risk. | < 15 min | Feishu @oncall |
| **P2** | Minor degradation, single user, non-critical. No data loss risk. | < 1 hr (business hours) | Feishu ticket + mention |
| **P3** | Cosmetic, non-prod, documentation, monitoring blind spot. | < 1 business day | Daily digest |
| **P4** | Trivial, workaround exists. | Best effort | None |

### 2.2 Error Budget Burn Rate (from `error-budget.md`)

| Alert | Burn Rate | Window | Time to Exhaust Budget | Maps To |
|-------|-----------|-------------|----------------------|---------|
| P0 | >= 14x | 1h | < 2h | P0 incident |
| P1 | >= 6x | 6h | < 5h | P1 incident |
| P2 | >= 2x | 3d | < 15d | P2 ticket |
| P3 | >= 1x | 30d | < 30d | Daily report |

### 2.3 Non-standard Severity Taxonomies

Several designs use ad-hoc severity systems that do not map cleanly to P0-P4:

| File | Labels Used |
|------|-------------|
| `cache-hit.md` | warning / critical / info |
| `disk-growth.md` | warning / critical |
| `alert-fatigue.md` | green / yellow / orange / red |
| `base-image-age.md` | P1 / P2 / P3 (not aligned with incident-severity definitions) |
| `secret-rotation.md` | P1 / P2 / P3 (not aligned with incident-severity definitions) |

---

## 3. Notification Channels (Across All Designs)

| Channel | Used For | Defined In |
|---------|----------|------------|
| **Feishu @all** | P0 incidents, Critical CVE, BossCrash, cc-connect down | `incident-severity.md`, `base-image-age.md`, `boss-lifecycle.md`, `error-budget.md` |
| **Feishu @oncall** | P1 incidents, ErrorBudgetBurnP0/P1, Stale backups, Restore test failure, Kafka lag | `error-budget.md`, `backup-monitor.md`, `kafka-lag.md` |
| **Feishu group (infra channel)** | P2 alerts, patrol anomalies, config drift, secret expiry warning, mirror degradation | `config-drift.md`, `registry-latency.md`, `secret-rotation.md`, `disk-growth.md` |
| **Feishu patrol digest** | P3 alerts, daily summary, weekly alert review, zombie sessions | `alert-fatigue.md`, `session-monitor.md` |
| **TTS / kyb notify urgent** | P0 escalation, critical CVEs during off-hours | `incident-severity.md`, `base-image-age.md` |
| **Grafana dashboard highlight** | Warning-level alerts, trend degradation | `error-budget.md`, `backup-monitor.md`, `disk-growth.md` |

---

## 4. Gaps and Inconsistencies

### 4.1 Missing Alert Designs (No Rules Defined Where Expected)

| System | File | What Is Missing |
|--------|------|-----------------|
| **cAdvisor** | `cadvisor-metrics.md` | References Prometheus alerting but defines zero alert rules. Per-container CPU/memory/network thresholds unspecified. |
| **Container Network Latency** | `container-network-latency.md` | Mentions degradation/unreachable alerts but no severities, thresholds, or channels. |
| **Image Pull Duration** | `image-pull.md` | Mentions "slow pull alerts" but no concrete thresholds or severities. |
| **Feishu Webhook Intercept** | `feishu-webhook-intercept.md` | Mentions delivery failure and rate limit alerts but no implementation details. |
| **Network Compliance** | `network-compliance.md` | Mentions compliance violations (unauthorized port, unexpected egress) but defines no alert rules. |
| **Fluentd Pipeline** | `fluentd-pipeline.md` | No explicit alert rules for pipeline failures or backpressure. |
| **Cross-Container Traces** | `cross-container-traces.md` | No alerting on broken trace chains or orphaned spans. |
| **eBPF Monitor** | `ebpf-monitor.md` | Feasibility study only; no alert rules for syscall anomalies. |
| **Claude Telemetry** | `claude-telemetry.md` | Explicitly notes gap: "no rules for error rate spikes, silent agents, or session anomalies." |
| **otel-\*** | Multiple | Focus on collection, not alerting. No rules for trace ingestion failure or span loss. |
| **Review Bridge \* / Issue Automation \* / MCP \*** | Multiple | Operational reviews, injector designs. None define alert rules. |
| **CK Query Monitor** | `ck-query-monitor.md` | Slow query thresholds defined but no formal Prometheus/Grafana alert rules for them. |

### 4.2 Inconsistencies

| Issue | Detail | Affected Files |
|-------|--------|----------------|
| **Severity taxonomy divergence** | Some use P0-P3, others use warning/critical/info, others use green/yellow/red. No standard mapping. | `cache-hit.md`, `disk-growth.md`, `alert-fatigue.md`, `incident-severity.md` |
| **P0 definition mismatch** | Incident-severity P0 = "complete outage, data loss". But `backup-monitor.md` uses P0 for "restore test fails" and `kafka-lag.md` uses P0 for "lag exceeds retention window". These are P1-level events under the formal classification. | `incident-severity.md` vs `backup-monitor.md` vs `kafka-lag.md` |
| **P2 def overload** | P2 carries wildly different urgency across designs: "disk exhaustion in <7 days" (P1 by incident rules) vs "TLS cert expiring in <30 days" (P2) vs "3rd party image stale >90 days" (P3). | `disk-growth.md`, `secret-rotation.md`, `base-image-age.md` |
| **Error budget P0 mapped to high-SLO services** | A Tier-3 service (99.0%, budget = 7h 12m) hit by P0 burn rate (>=14x) would take ~30min to exhaust budget. But by incident rules, a service degraded but still operating does not qualify as P0. | `error-budget.md`, `incident-severity.md` |
| **Duplicate crash loop rules** | Three files define overlapping crash loop detection: `docker-events.md` says "3+ die+restart in 5min = P1", while `crash-loop.md` defines a 3-tier system (3x/5min=P1, 5x/30min=P2, 10x/24h=P3), and `boss-lifecycle.md` has IncarnationSpike. | `docker-events.md`, `crash-loop.md`, `boss-lifecycle.md` |
| **No unified Prometheus rules file** | Every design includes alert rules inline (PromQL, SQL, or prose). There is no single `prometheus-rules.yml` or `alerts.yml`. Deployment requires manual extraction from each design doc. | All files with alert rules |
| **Silence taxonomy not universally used** | Only `alert-fatigue.md` defines silence reason taxonomy (false_positive, known_issue, maintenance, too_noisy, duplicate). Other designs reference silences without classification. | Most alert designs |

### 4.3 Operational Gaps

| Gap | Impact | Suggested Fix |
|-----|--------|---------------|
| **No Prometheus / AlertManager deployed** | Zero alert rules are executable. 119 rules exist only on paper. | Deploy Prometheus + AlertManager (referenced as "future phase" in `cadvisor-metrics.md`) |
| **No on-call schedule** | No explicit responder for P0/P1 alerts. Feishu @all sprays everyone. | Define on-call rotation (file exists: `oncall.md` but empty of schedule) |
| **No runbooks for 80% of alerts** | Most alert rules reference runbooks that do not exist. | Create `docs/infra/runbooks/` with response steps for every P0/P1 alert |
| **No staging environment for alerts** | No way to test alert rules before production. Chaos engineering (`chaos-engineering.md`) partially addresses real-failure testing but not new-rule validation. | Add alert integration test to chaos experiment suite |
| **No SLO-to-alert traceability** | Cannot answer "which alert covers this SLO violation?" Error budget alerts detect burn rate but do not point to specific symptom alerts. | Tag alert rules with `slo_service` and `sli_name` labels |
| **No alert deduplication strategy** | Multiple alert rules can fire for the same root cause (e.g., cc-connect down triggers P0 incident, error budget P0, and WS health P1 simultaneously). No dedup policy defined. | Define alert grouping rules in AlertManager config |

---

## 5. Consolidated Alert Rule Count

| Category | Files With Alerts | Approximate Rules |
|----------|-------------------|-------------------|
| Container Lifecycle | 3 | 20 |
| Resource / Capacity | 5 | 18 |
| Service Health / SLO | 3 | 25 |
| Observability Meta | 4 | 22 |
| Bridge / Integration | 4 | 12 |
| Security / Compliance | 4 | 18 |
| CI / Pipeline | 1 | 4 |
| **Total** | **24 files** | **~119 alert rules** |

119 alert rules across 24 design documents. Zero deployed.

---

## 6. Recommended Actions

### Immediate (Week 1)
1. **Deploy Prometheus + AlertManager** -- prerequisite for executing any PromQL-based alert rule. Without this, alerting is entirely theoretical.
2. **Consolidate crash loop detection** -- merge `docker-events.md`, `crash-loop.md`, and `boss-lifecycle.md` into a single detection layer with one severity mapping.

### Week 2
3. **Create `docs/infra/alerts/prometheus-rules.yml`** -- single file merging all alert rules from all design docs, deduplicated and mapped to the P0-P4 incident-severity system.
4. **Tag all rules** with `slo_service`, `sli_name`, and `team` labels for SLO traceability.
5. **Standardize severity mapping** -- map all ad-hoc severities (warning/critical/green/yellow) to P0-P4.

### Week 3
6. **Write runbooks** for every P0 and P1 alert (at least one paragraph: "what to check, what to do, who to escalate").
7. **Define on-call rotation** and configure AlertManager notification routing accordingly.
8. **Add alert deduplication** rules to AlertManager to prevent cascading alerts for the same root cause.

### Week 4
9. **Audit burn rate thresholds for Tier-2/Tier-3 services** -- ensure P0 mapping is meaningful for high-budget services.
10. **Create staging alert test** as part of the chaos engineering experiment suite.

---

## 7. Per-File Alert Rule Catalog

| File | Alert Name | Condition | Design Severity | Incident Sev |
|------|-----------|-----------|-----------------|--------------|
| `alert-fatigue.md` | AlertFatigueIndexHigh | AFI > 0.5 | P1 | P1 |
| `alert-fatigue.md` | HighSilenceRate | > 20% silenced | P2 | P2 |
| `alert-fatigue.md` | HighFalsePositiveRate | > 15% false positives | P2 | P2 |
| `alert-fatigue.md` | MTTAHighP0 | P0 MTTA P90 > 15min | P1 | P1 |
| `alert-fatigue.md` | MTTAHighP1 | P1 MTTA P90 > 1h | P2 | P2 |
| `alert-fatigue.md` | AlertSpike | 5x rate spike in 5min | P1 | P1 |
| `alert-fatigue.md` | NoAcknowledgment>24h | Alerts unacknowledged >24h | P2 | P2 |
| `backup-monitor.md` | StaleBackupPG | PG dump > 36h | P1 | P1 |
| `backup-monitor.md` | StaleBackupCK | CK backup > 36h | P1 | P1 |
| `backup-monitor.md` | StaleBackupConfig | Config backup > 48h | P2 | P2 |
| `backup-monitor.md` | BackupSizeDrop | < 50% of 7d avg | P1 | P1 |
| `backup-monitor.md` | BackupSizeSpike | > 200% of 7d avg | P2 | P2 |
| `backup-monitor.md` | BackupEmpty | Size = 0 | P1 | P1 |
| `backup-monitor.md` | IntegrityFail | gzip/tar check fails | P1 | P1 |
| `backup-monitor.md` | RestoreTestFail | Weekly restore fails | P0 | P0/Critical |
| `backup-monitor.md` | BackupHostUnreachable | SSH connection fails | P2 | P2 |
| `backup-monitor.md` | BackupHostDisk | Free disk < 20% | P2 | P2 |
| `backup-monitor.md` | ConfigDrift | Config differs from git | P2 | P2 |
| `base-image-age.md` | BaseImageTooOld | kyb-base > 30 days | P2 | P2 |
| `base-image-age.md` | BaseImageDrift | ubuntu drift > 14 days | P2 | P2 |
| `base-image-age.md` | CriticalCVE | CRITICAL > 0 on kyb-base | P1 | P1 |
| `base-image-age.md` | HighCVEThreshold | HIGH > 25 on kyb-base | P2 | P2 |
| `base-image-age.md` | ThirdPartyImageStale | Age > 90 days | P3 | P3 |
| `base-image-age.md` | ScanPipelineDown | No scan > 48h | P2 | P2 |
| `boss-decision-latency.md` | PDLTooSlow | P90 PDL > 30s in 15min | P2 | P2 |
| `boss-decision-latency.md` | FRLTooSlow | P90 FRL > 60s in 15min | P2 | P2 |
| `boss-decision-latency.md` | NoPatrolData | No cluster data > 10min | P1 | P1 |
| `boss-decision-latency.md` | E2EDegradation | P90 E2E > 60min in 24h | P3 | P3 |
| `boss-decision-latency.md` | IssueSlipping | IAL > 30min, not closed | P3 | P3 |
| `boss-lifecycle.md` | BossDead | Heartbeat > 15min | P2 | P2 |
| `boss-lifecycle.md` | BossCrashed | event_type = crashed | P1 | P1 |
| `boss-lifecycle.md` | BossAbandoned | idle > 24h, sandbox_count = 0 | P3 | P3 |
| `boss-lifecycle.md` | BossRestartLoop | >3 events in 1h | P2 | P2 |
| `boss-lifecycle.md` | TooManyIdle | >50% bosses idle >4h | P3 | P3 |
| `boss-lifecycle.md` | OrphanSandbox | Boss dead >24h, containers running | P2 | P2 |
| `boss-lifecycle.md` | IncarnationSpike | incarnation jumps >3 in 1h | P2 | P2 |
| `cc-ws-health.md` | ReconnectStorm | >5 reconnects/h | P1 | P1 |
| `cc-ws-health.md` | ConnectionFlapping | Never stable >5min | P1 | P1 |
| `cc-ws-health.md` | MessageGap | No message >5min | P2 | P2 |
| `cc-ws-health.md` | ZombieConnection | Connection alive, no data | P2 | P2 |
| `ci-flakiness.md` | MasterFailureRate | Master pass rate < 90% | P1 | P1 |
| `crash-loop.md` | InstantCrashLoop | 3x/5min | P1 | P1 |
| `crash-loop.md` | FastCrashLoop | 5x/30min | P2 | P2 |
| `crash-loop.md` | SlowCrashLoop | 10x/24h | P3 | P3 |
| `disk-growth.md` | DiskExhaustionWarning | < 30 days to full | P2 | P1 |
| `disk-growth.md` | DiskExhaustionCritical | < 7 days to full | P1 | P0 |
| `error-budget.md` | ErrorBudgetBurnP0 | >=14x burn rate, 1h window | page | P0 |
| `error-budget.md` | ErrorBudgetBurnP1 | >=6x burn rate, 6h window | page | P1 |
| `error-budget.md` | ErrorBudgetBurnP2 | >=2x burn rate, 3d window | ticket | P2 |
| `incident-severity.md` | TooManyP0Incidents | >3 P0 in 7d | page | P0 |
| `incident-severity.md` | MTTRDegradationP1 | P1 p90 MTTR +50% over baseline | ticket | P2 |
| `incident-severity.md` | IncidentsClusterBurst | >5 incidents in 24h per service | page | P1 |
| `incident-severity.md` | IncidentNotAcknowledged | P0/P1 not ack >15min | page | P0 |
| `kafka-lag.md` | ConsumerLagHigh | Lag > threshold | P1 | P1 |
| `kafka-lag.md` | LagExceedsRetention | Lag > 7d retention window | P0 | P0 |
| `kafka-lag.md` | UnderReplicatedPartitions | Partition under-replicated | P2 | P2 |
| `secret-rotation.md` | SecretExpired | Secret past expiry date | P1 | P1 |
| `secret-rotation.md` | CertExpiringSoon | TLS < 30 days | P2 | P2 |
| `secret-rotation.md` | CertExpiringCritical | TLS < 7 days | P1 | P1 |
| `secret-rotation.md` | RotationPolicyBreached | Age > 90% of policy | P3 | P3 |
| `vuln-scan.md` | CriticalCVEInDeployedImage | Critical CVE in running image | P1 | P1 |
| `cache-hit.md` | CacheHitRatioLow | Avg < 40% over 3 builds | warning | P3 |
| `cache-hit.md` | CacheDiskPressure | Cache > 12GB (or 14GB) | warning/critical | P2/P1 |
| `cache-hit.md` | BuildDurationSpike | > 3x avg duration | info | P3 |
| `registry-latency.md` | MirrorDegraded | Latency > 5s sustained | P2 | P2 |
| `registry-latency.md` | MirrorFailureRate | > 50% failure in 5min | P2 | P2 |
| `dangling-images.md` | DiskWasteThreshold | Reclaimable > 30% of total | P2 | P2 |
| `dangling-images.md` | DiskWasteGrowth | Waste growth rate anomaly | P2 | P2 |

---

## 8. Data Pipeline Readiness

| Component | Status | Role |
|-----------|--------|------|
| **ClickHouse** | Running (24.2-alpine, `kyb-infra-clickhouse`) | Long-term alert event storage |
| **Prometheus** | Not deployed | PromQL alert evaluation, MWMBR burn rate |
| **AlertManager** | Not deployed | Dedup, silencing, routing to Feishu |
| **Feishu webhook** | Operational (cc-connect) | Notification delivery |
| **Patrol system** | Running (5-min cycle) | Detection + basic response |
| **Grafana alerting** | Available (Grafana 11.x, CK datasource) | Alternative to Prometheus for CK-based rules |
| **Vector** | Designed, deployment unclear | Log-based alert sources |
| **Single rules file** | Does not exist | Consolidation needed |

**Summary**: 119 alert rules exist across 24 files, spanning 7 categories, using 3 severity taxonomies, with zero deployed execution infrastructure. The most urgent action is deploying Prometheus + AlertManager; the most impactful consolidation action is merging all rules into a single `prometheus-rules.yml`.
