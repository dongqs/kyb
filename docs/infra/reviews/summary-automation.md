---
decision: 现在就做
---

# Automation Dimension: Cross-Cutting Summary

> Synthesized from all `docs/infra/reviews/` files.
> Date: 2026-05-23

---

## 1. Systems with Auto-Remediation Designs

### 1.1 Config Drift (`config-drift.md`)
- **Status**: Designed, Phase 3 (Day 3-4), not yet implemented
- **Mechanism**: `kyb-config-check.sh` compares SHA256 checksums against ClickHouse baseline; auto-reverts git-managed files (`entrypoint.sh`, `bin/kyb`, `lib/*.rb`, `Dockerfile`, `mise.config.toml`) via `git checkout --`. Per-boss configs (`config.yml`, `clusters.yml`) are explicitly excluded from auto-revert.
- **Escalation**: P4 (log only) -> P3 (log+diary) -> P2 (auto-revert or manual ack) -> P1 (mass drift alert). Unresolved P2 escalates to P1 after 24h.
- **Design quality**: Strong. Tiered, explicit opt-out, atomic state writes, audit trail in CK.

### 1.2 Dangling Images & Disk Waste (`dangling-images.md`)
- **Status**: Designed, Phase 3-4 (Week 2-4), not yet implemented
- **Mechanism**: Tiered auto-cleanup:
  - Green (<10% waste): No action
  - Yellow (10-20%): Soft prune (`docker container prune`, `docker image prune`, `docker volume prune`, `docker builder prune` with 24h filters)
  - Red (20-30%): Hard prune (`docker system prune --force --all --volumes`) requires boss confirmation
  - Critical (>30% or disk>85%): Emergency prune (automatic, no approval), includes `docker builder prune --force --all`, `rm -rf /var/lib/docker/tmp/*`
- **Safeguards**: Exempt images list, retention windows per resource type, prune-effectiveness verification via post-prune snapshot comparison.
- **Design quality**: Strong. Tiered approach with clear safety boundaries. Verified via post-prune CK snapshots.

### 1.3 Feishu Bot Delivery (`feishu-delivery.md`)
- **Status**: Designed, Phase 4 (Week 2-3), not yet implemented
- **Mechanism**: For P1 SilentDrop events:
  1. Check WebSocket health (`GET /health` of cc-connect) -> restart consumer process if unhealthy
  2. Re-send critical (`urgent`) messages once with new `message_id`, original marked `DROPPED(re-sent=<new>)`
  3. Escalate to human if auto-remediation fails
- **Design quality**: Good. Clear trigger (SilentDrop alert), bounded retry (one re-send), well-defined escalation path.

### 1.4 Incident Management (`incident-severity.md`, `oncall.md`)
- **Status**: Designed, not yet implemented
- **Mechanism**:
  - **Auto-creation**: Error budget burn rate thresholds auto-create P0/P1 incident records from Prometheus alerts
  - **Escalation engine**: Primary -> Secondary -> @all -> Incident, with time budgets per severity (P0: 5/5/0 min, P1: 15/15/15 min). Runs as 60s tick loop on feishu-bridge.
  - **Self-heal tracking**: Auto-resolved events logged as P3 with `detection = 'SELF'`
  - **Post-mortem automation**: MR merge triggers CK entry creation, lessons DB insertion, GitLab action item creation, Feishu notification
  - **Roadmap**: Q2 2026 baseline -> Q3 automated self-heal playbooks -> Q4 supervised auto-remediation -> Q1 2027 full auto-remediation for top-5 causes
- **Design quality**: Strong for escalation. Self-heal roadmap is well-scoped with quarterly targets.

### 1.5 Kafka Consumer Lag (`kafka-lag.md`)
- **Status**: Proposed as P3 future item, not designed in detail
- **Mechanism** (sketch):
  1. Detect stalled CK consumer via Prometheus API
  2. Restart ClickHouse container (`docker restart kyb-infra-clickhouse`)
  3. Wait 30s, verify consumer resumed
  4. Notify Feishu with action taken
- **Design quality**: Weak. Only a sketch. Manual recovery deemed acceptable at current volume (~900 events/day).

### 1.6 Crash Loop Detection (`docker-events.md`)
- **Status**: Designed, ready for implementation
- **Mechanism**: Docker event watcher captures `container:die` with exit codes. Query detects 3+ die events in 5 min -> P1 alert. Auto-recovery via Docker `--restart=unless-stopped` policy (not custom code).
- **Design quality**: Good for detection. Auto-healing relies on Docker native behavior, which is appropriate.

### 1.7 Issue Automation (`review-issue-automation-E1.md`)
- **Status**: Approved with mitigations, ready for implementation
- **Mechanism**: Cron-based `check-issues.sh` with:
  - `timeout 60` wrapping
  - State file persistence (`/data/issue-automation/last_id`) with atomic writes (write to tmp, then mv)
  - Startup delay / readiness check
  - Heartbeat monitoring: alert if script hasn't run in N cycles
- **Design quality**: Good. Pragmatic, zero-new-infra approach with proper state management.

### 1.8 Chaos Engineering (`chaos-engineering.md`)
- **Status**: Appendix B - future automation
- **Mechanism**: `chaos-run <experiment-name>` script that checks safety gates, records baselines, injects fault, waits, rolls back, verifies, records results, notifies.
- **Design quality**: Conceptual only. No implementation detail.

### 1.9 Backup Cleanup (`backup-monitor.md`)
- **Status**: P3 future item
- **Mechanism**: `find /backup/pg/ -name '*.sql.gz' -mtime +30 -delete` and equivalent for CK (30d) and config archives (90d). `cc-backup-cleanup` script with `--dry-run` flag.
- **Design quality**: Minimal. Simple retention-based cleanup, no integrity verification before deletion.

---

## 2. Systems With Monitoring/Detection Only (No Auto-Remediation)

| System | File | What's Detected | Auto-Response? |
|--------|------|-----------------|----------------|
| **Secret Rotation** | `secret-rotation.md` | Age > policy, cert expiry, compliance <90% | None. Manual rotation workflow only. |
| **Vulnerability Scan** | `vuln-scan.md` | CVEs per image, fix age | None. User owns remediation. |
| **Backup Monitoring** | `backup-monitor.md` | Freshness, size anomalies, integrity, host disk | None (except retention cleanup P3). Weekly restore tests are manual. |
| **Alert Fatigue** | `alert-fatigue.md` | Alert volume, silence rate, firing duration | None. Meta-monitoring only, no auto-tuning. |
| **Error Budget** | `error-budget.md` | Burn rate, SLO compliance | None. Creates incident records but no auto-remediation action. |
| **CI Flakiness** | `ci-flakiness.md` | Test pass rate, flaky test detection | None. |
| **Token Cost** | `token-cost.md` | Token usage, cost per model | None. |
| **User Activity** | `user-activity.md` | User session metrics | None. |
| **Heartbeat Reliability** | `heartbeat-reliability.md` | Missed/late beats, reliability score | None. |
| **Cache Hit Rate** | `cache-hit.md` | Registry cache hit/miss ratio | None. No cache warming automation. |
| **Image Pull Latency** | `image-pull.md`, `registry-latency.md` | Pull times, latency percentiles | None. |
| **Container Network Latency** | `container-network-latency.md` | Inter-container latency | None. |
| **System Load** | `system-load.md` | CPU/memory/disk | None. |
| **Boss Decision Latency** | `boss-decision-latency.md` | Time from dispatch to decision | None. |

---

## 3. Gaps Analysis

### 3.1 Critical Gaps (No Detection + No Auto-Remediation)

| Gap | Evidence | Impact |
|-----|----------|--------|
| **TLS certificate auto-renewal monitoring** | `secret-rotation.md` covers cert expiry detection but has no auto-renewal loop. Let's Encrypt certbot runs manually. | Cert expiry = HTTPS outage until manual fix. |
| **Database failover** | PostgreSQL, Redis are single-instance. No automated failover, no replica promotion. | PG/Redis outage = full service loss until manual restart or restore. |
| **Docker daemon health** | Watcher runs inside boss container -- if Docker daemon dies, boss dies too. No out-of-band monitoring. | Blind spot at infrastructure root. |
| **OOM prevention** | OOM events are detected (`docker-events.md`) but no automated memory limit adjustment. | Repeat OOM kills until manual intervention. |

### 3.2 Tier-1 Gaps (Detection Exists, No Auto-Remediation)

| Gap | Detection | Manual Fallback | Priority |
|-----|-----------|-----------------|----------|
| **Secret past rotation policy** | Prometheus alert | Manual rotation per type | P1 |
| **Critical CVEs in deployed images** | Scan results + alert | Manual rebuild/patch | P1 |
| **Backup restore not tested** | Alert if >8d since last test | Manual restore test | P1 |
| **Disk filling on backup host** | `df` check in patrol | Manual cleanup or volume expansion | P2 |
| **Stale branches accumulating** | `stale-branches.md` analysis | Manual `git push --delete` | P2 |
| **CI/CD flaky tests** | Detection only | Manual investigation | P2 |
| **Alert fatigue threshold drift** | Volume/silence rate monitoring | Manual threshold adjustment | P3 |
| **Feishu rate limit exceeded** | `feishu-rate-limit.md` detection | Manual backoff | P3 |

### 3.3 Cross-Cutting Design Deficiencies

1. **No verification step after remediation**: Dangling images design says "verify" but no concrete criteria. Config drift design says "re-run check" but not specified.
2. **No cross-system coordination**: Each auto-remediation is designed in isolation. No conflict detection (e.g., config-drift reverting a file while secret-rotation updates it).
3. **No throttling / rate limiting**: A single bug could trigger cascading auto-remediations (detect-lag -> restart-CK -> detect-restart -> re-alert loop).
4. **Runbooks assume human in loop**: Even "auto-remediation" systems escalate to human for anything beyond trivial. True "lights out" automation is rare.
5. **No chaos verification of auto-remediation**: `chaos-engineering.md` tests detection latency and alert quality but never tests whether auto-remediation actually fixes the problem.

---

## 4. Recommendations

### P0: Immediate (Within Week)

1. **Implement config drift auto-revert for git-managed files.**
   - Highest-ROI auto-remediation: addresses active pain point, low blast radius (git checkout reverts cleanly), design complete.
   - Effort: 1 session.

2. **Enable soft prune for dangling images and zombie containers.**
   - The 6GB dangling image and 13GB zombie containers are real waste. Soft prune with 24h retention windows is safe.
   - Effort: 1 session (Phase 3 from `dangling-images.md`).

3. **Deploy crash-loop detection alert from Docker events.**
   - Detection is fully designed, schema exists, watcher script is written. Closes the blind spot that allowed the 2026-05-23 3-hour invisible incident.
   - Effort: 0.5 session.

### P1: Short-Term (Within 2 Weeks)

4. **Add verification step to every auto-remediation action.**
   - After auto-revert: re-run drift check. After soft prune: query CK snapshot to confirm waste dropped. After CK restart: verify consumer lag -> 0.
   - Without verification, auto-remediation is fire-and-forget creating false confidence.

5. **Design and deploy auto-remediation for critical secrets (TLS certs, Feishu token).**
   - Certbot auto-renewal with monitoring. Feishu token auto-refresh with fallback.
   - These are the most common credential-related failure modes.

6. **Implement the incident escalation engine.**
   - Complete design exists in `oncall.md`. Ensures unacknowledged P0/P1 alerts escalate before prolonged outages.
   - Effort: 2 sessions (Phase 2 from oncall.md).

### P2: Medium-Term (Within Month)

7. **Add throttle/debounce to all auto-remediation actions.**
   - Minimum interval between auto-restarts (5 min). Maximum re-sends per hour. Cooldown after auto-revert.
   - Prevents cascading remediation storms.

8. **Implement backup restore testing automation.**
   - Weekly automated restore to temp DB + row count verification. Only way to confirm backups actually work.
   - Effort: 1 session.

9. **Build auto-remediation verification into chaos engineering suite.**
   - Add experiment steps: "trigger condition -> confirm auto-remediation fires -> confirm service recovers -> measure time-to-recovery."

10. **Add stale branch auto-cleanup.**
    - Post-merge hook in GitLab. Weekly `git fetch --prune` + merged branch deletion.
    - Effort: 30 min.

### P3: Long-Term (Within Quarter)

11. **Full auto-remediation for top-5 incident causes** (per `incident-severity.md` Q1 2027 target).
    - Current top causes: RESOURCE (35%), CONFIG (25%), DEP (15%), CODE (12%), HUMAN (8%).
    - RESOURCE: auto-scaling, auto-cleanup, OOM prevention.
    - CONFIG: drift auto-revert, config validation CI gate.

12. **Cross-system conflict detection for auto-remediation.**
    - A registry that sequences or blocks concurrent remediation actions on overlapping resources.

13. **Database failover automation.**
    - PostgreSQL replica setup + automated promotion. Redis sentinel or cluster mode.

---

## 5. Auto-Remediation Maturity Matrix

| System | Detect | Alert | Auto-Remediation | Verification | Escalation | Maturity |
|--------|--------|-------|-----------------|-------------|------------|----------|
| Config drift | Designed | Designed | Designed (Ph3) | Not designed | Designed | **3/5** |
| Dangling images | Designed | Designed | Designed (Ph3-4) | Partially | Designed | **3/5** |
| Feishu delivery | Designed | Designed | Designed (Ph4) | Not designed | Designed | **2/5** |
| Incident escalation | Designed | Designed | Designed | Not designed | Designed | **3/5** |
| Kafka consumer lag | Designed | Designed | Sketch (P3) | Not designed | Not designed | **1/5** |
| Crash loop detection | Designed | Designed | Docker native | Not designed | Partially | **2/5** |
| Issue automation | Designed | Designed | N/A (reliability) | Designed | Not needed | **3/5** |
| Backup monitoring | Designed | Designed | Cleanup only (P3) | Not designed | Not designed | **1/5** |
| Secret rotation | Designed | Designed | None | N/A | Not designed | **1/5** |
| Vulnerability scan | Designed | Designed | None | N/A | Not designed | **1/5** |
| Alert fatigue | Designed | Designed | None | N/A | Not designed | **1/5** |
| Post-mortem workflow | N/A | N/A | Designed (Sec 11) | Not designed | Designed | **2/5** |
| Chaos engineering | N/A | N/A | Sketch (future) | N/A | N/A | **0/5** |
| On-call escalation | N/A | Designed | Designed | Not designed | Designed | **3/5** |

*Maturity scale: 0=not considered, 1=detect+alert only, 2=remediation sketched, 3=fully designed, 4=implemented, 5=verified+operating.*

---

## 6. Summary

Of ~40 review files, only 7 systems have any auto-remediation design, and **none have been implemented yet**. The landscape is detection-heavy, remediation-light. The designs that exist (config drift auto-revert, tiered disk cleanup, incident escalation) are well-structured with escalation paths and safety margins, but they remain on paper.

The strongest designs:
- **Config drift auto-revert** -- comprehensive, safe (explicit opt-out for per-boss configs), verifiable
- **Tiered disk waste cleanup** -- graduated response with clear thresholds and safety checks
- **Incident escalation engine** -- complete multi-level design with time budgets, after-hours relaxation, and auto-generated handovers

The biggest gaps:
- **No implemented auto-remediation at all** in production
- **No verification step** post-remediation in most designs
- **No coordination or throttling** across automated actions
- **Database failover and TLS renewal** have zero automation
- **Chaos engineering** has no experiments for auto-remediation

The Q2/Q3/Q4 2026 roadmap from `incident-severity.md` is sound but needs implementation velocity. The three P0 recommendations (config drift auto-revert, soft prune, crash-loop alert) can be implemented in a single day and would close the highest-risk gaps immediately.

---

*Generated from `docs/infra/reviews/*.md` on 2026-05-23.*
