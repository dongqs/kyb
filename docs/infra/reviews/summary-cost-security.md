---
decision: 现在就做
---

# Cost & Security Review Summary

**Date:** 2026-05-23
**Scope:** All `docs/infra/reviews/` files analyzed along cost and security dimensions.

---

## Overview

Of the ~90 review documents in `docs/infra/reviews/`, the following have direct cost or security significance:

| Dimension | Primary Documents | Supporting Documents |
|-----------|------------------|---------------------|
| **Cost** | `token-cost.md`, `model-usage.md`, `cache-hit.md`, `dangling-images.md`, `volume-usage.md`, `disk-growth.md`, `base-image-age.md` | `ci-flakiness.md`, `session-duration.md`, `stale-branches.md`, `image-pull.md` |
| **Security** | `secret-rotation.md`, `vuln-scan.md`, `network-compliance.md`, `multi-tenancy.md`, `config-drift.md` | `proxy-intercept.md`, `sidecar-intercept.md`, `permission-latency.md`, `incident-severity.md` |
| **Cross-cutting** | `alert-fatigue.md`, `postmortem.md`, `oncall.md`, `error-budget.md` | `crash-loop.md`, `registry-latency.md` |

---

## COST DIMENSION

### 1. Token Cost Tracking (`token-cost.md`)

**Problem:** Claude Code (and other LLM agents) consume API tokens with no aggregated visibility. Total spend, per-agent breakdown, and budget alerting are absent.

**Design:** A `token-tracker.sh` daemon captures Claude Code end-of-turn token summaries (`Tokens: Input: X Output: Y Cache Read: Z`), enriches with session metadata, and flushes to ClickHouse every 30 seconds.

**Key Decisions:**
- Data stored in `infra.token_usage` (raw) + `infra.token_usage_daily` (MV).
- Cost estimation uses a `infra.model_pricing` lookup table with published API rates.
- Estimation is deliberately conservative (slightly over) to avoid surprise bills.
- Budget table `infra.token_budgets` supports per-project daily/weekly/monthly limits.
- Alerts at 80% (warning) and 100% (exceeded) of budget; anomaly detection at 3x trailing 7-day average.

**Volume:** ~4,800 records/day at current scale (~10 concurrent sessions). Storage: ~60 MB/year compressed. Negligible.

### 2. Model Usage Tracking (`model-usage.md`)

**Problem:** Model selection per agent is invisible. Boss dispatches with no knowledge of whether subagents used Opus ($15/Mtok) or Haiku ($0.80/Mtok).

**Design:** Uses the existing `kyb.claude_hook_events` table (model field on every hook event) + cost mapping via `kyb.model_pricing`.

**Key Findings:**
- Opus costs ~18.75x Haiku for the same output. Using Opus for trivial tasks is the #1 source of wasted spend.
- Patrol agents should always use Haiku ($0.50-$1.00/day each; total patrol budget ~$90/mo).
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

### 3. Docker Build Cache Monitoring (`cache-hit.md`)

**Problem:** No visibility into Docker BuildKit cache hit ratio, layer churn, or cache storage waste. Build optimization is done blind.

**Design:** A BuildKit output parser (`lib/kyb/build_monitor.rb`) wraps `docker build`, extracts per-layer cache hit/miss, and emits metrics to `infra.build_cache_metrics`.

**Cost Implications:**
- Total build cache: ~23 GB, of which 2.41 GB is immediately reclaimable.
- Cache budget: 15 GB per host. Warning at 12 GB, auto-GC at 14 GB.
- Layer churn score = % of layers rebuilt in last 30 days.
- ROI formula for optimization: `(rebuild_duration * rebuilds_per_month * lifetime) / engineering_cost`.
- Estimated storage: ~22.5 MB over 180 days.

### 4. Dangling Image & Disk Waste (`dangling-images.md`)

**Problem:** Docker disk usage is 181.5 GB total. ~28 GB (16%) is reclaimable: dangling images (6.07 GB), zombie containers (13 GB), stale tagged images (~6.7 GB), build cache rot (2.41 GB).

**Design:** A `disk-waste-collector.sh` script runs every 5 minutes in the patrol cycle, snapshots waste categories, and writes to `infra.disk_waste_snapshots`.

**Key Metrics:**
- Total waste tracked daily with per-category breakdown.
- Auto-cleanup tiers: Green (<10% waste), Yellow (10-20%, soft prune), Red (20-30%, hard prune), Critical (>30% or disk >85%, emergency prune).
- Highest ROI actions: (1) `docker image prune --force` in `kyb build`, (2) zombie container trap handler.

### 5. Volume Disk Usage (`volume-usage.md`)

**Problem:** Docker volumes consume ~15.1 GB across 25 volumes. 96% is build cache (gradle, maven, swift) which is expected to plateau.

**Key Findings:**
- Infrastructure data volumes: ~570 MB across 10 services (ClickHouse 275 MB, PG databases 38-81 MB each).
- Dangling sandbox volumes: 5 volumes totaling ~21 MB (negligible but clutter).
- Boss container writable layers: ~22.5 GB cumulative (the real cost concern: each boss writes ~4.5 GB transient data).
- Cache volumes safe to remove but expensive to rebuild (gradle: 10-20 min, swift: 15-30 min).

### 6. Disk Growth Monitoring (`disk-growth.md`)

**Problem:** No trend tracking or exhaustion prediction across clusters with different disk sizes (Mac 260 GiB, Aliyun 40 GiB, NUC 256 GiB).

**Design:** Collect `cluster_disk_metrics` every 5 minutes into ClickHouse. Compute daily rollups and linear regression to predict exhaustion dates.

**Thresholds:**
| Cluster | Warning | Critical |
|---------|---------|----------|
| Mac/Orbstack | <20 GiB or <30 days | <5 GiB or <7 days |
| Aliyun (sim) | <5 GiB or <14 days | <2 GiB or <3 days |
| Office (nuc8) | <20 GiB or <30 days | <5 GiB or <7 days |

### 7. Base Image Age (`base-image-age.md`)

**Problem:** Base images (ubuntu:24.04, postgres:16, etc.) accumulate CVEs between builds with no visibility into age vs. vulnerability posture.

**Cost Angle:** Older base images mean more CVEs to fix, more rebuilds, longer CI cycles. Image drift cost: a `latest` tag silently introduces new packages and potential regressions with no change in Dockerfile.

---

## SECURITY DIMENSION

### 1. Secret Rotation Monitoring (`secret-rotation.md`)

**Problem:** Secrets are provisioned once and rarely revisited. Failure modes: API token expiry, TLS cert expiry, stale service account credentials, database passwords never rotated.

**Scope:** API tokens, TLS certificates, CI/CD tokens, database credentials, SSH keys, cloud provider keys, service-to-service tokens.

**Rotation Policies:**
| Category | Policy |
|----------|--------|
| API tokens | 90 days |
| TLS certificates | 90 days (auto-renewed) |
| CI/CD tokens | 180 days |
| Database credentials | 180 days |
| SSH keys | 365 days |
| Cloud provider keys | 90 days |

**Design:** A `secret-rotation-exporter` (Prometheus metric endpoint) reads `~/.kyb/secrets/registry.yml` and exposes `secret_age_days`, `secret_expiry_days_remaining`, and `secret_rotation_info`. Alert thresholds at 50%/75%/90%/100%+/expired of policy window.

**Alert Severity:**
- Secret past rotation policy / Certificate expired: **P0** (Feishu @all + TTS)
- Secret >90% of policy / Certificate <14 days: **P1** (Feishu group)
- Compliance <90%: **P2** (daily digest)

### 2. Container Vulnerability Scanning (`vuln-scan.md`)

**Problem:** ~30 container images across 3 clusters with no automated scanning, no CVE database, no fix age tracking, no alerting.

**Design:** Trivy as primary scanner (offline-capable, ~5-15s per image), Grype as weekly cross-check. Scan triggers: build-time (kyb-sandbox), scheduled daily (all Tier 2 infra images), on-deploy.

**Data Model:**
- `image_vulnerabilities`: One row per (scan_id, image, CVE) with severity, CVSS score, fix version, package info.
- `image_fix_age`: Tracks time from CVE publication to remediation per image.

**Fix Age SLOs:**
| Image Tier | CRITICAL SLO | HIGH SLO |
|------------|-------------|----------|
| Sandbox | 72 hours | 7 days |
| Infra | 72 hours | 7 days |
| Sidecar | 7 days | 14 days |

**Alert Rules:**
- **P1:** Critical CVE in production image (unresolved >1h)
- **P2:** Fix age SLO breached (>72h for fixable CRITICAL); new CRITICAL CVE introduced by build
- **P3:** Scanner DB too old (>48h); image not scanned in 48h

### 3. Network Policy Compliance (`network-compliance.md`)

**Problem:** All infra containers share a flat Docker bridge network (`kyb-net`) with zero isolation. Any container can reach any other: lateral movement, unauthorized service access, and stale exposure are invisible.

**Design:** A `kyb-net-monitor` container uses conntrack events for real-time connection tracking, plus periodic port scanning (every 5 min). All connections matched against an allowlist (`net.allowlist`).

**Detection Rules:**
- **P1:** Unauthorized connection (not in allowlist); rogue container on kyb-net
- **P2:** Unexpected open port on management/data service; compliance scanner down
- **Latent movement detection:** First-seen connection pattern between two containers

**Key Risk:** No iptables/nftables on Orbstack. Monitoring is the only enforcement mechanism. Future clusters (Aliyun, NUC) will have firewall logging.

### 4. Multi-Tenancy Isolation (`multi-tenancy.md`)

**Problem:** Sandbox containers for multiple projects/users on shared infrastructure. No per-project resource tracking, no isolation verification, no access audit logging.

**Design:** Docker container labels (`kyb.project`, `kyb.sandbox`, `kyb.cluster`, `kyb.user`) as the tenancy source of truth. Vector collects `docker stats` (15s), `docker events` (stream), `docker inspect` (1h) and enriches with tenancy labels.

**Alert Rules:**
- **Critical:** Cross-project network communication detected; privileged container detected
- **High:** Shared Docker socket mounted; host volume mount outside project directory
- **Warning:** Container memory >85% of limit; untagged container; CPU >80% for 5min

**Storage:** ~2.9 GB total for 100 containers (stats 30d, events 90d, access logs 1yr, network snapshots 30d).

### 5. Config Drift Detection (`config-drift.md`)

**Problem:** Manual `docker exec` edits, emergency hotfixes without commits, stale generated files: config drifts silently across 3 clusters with no detection.

**Design:** SHA256 checksums of tracked config files, stored in ClickHouse as baselines. Detection script runs every 5 minutes (patrol cycle). Comparison against latest baseline triggers drift events.

**Drift Severity:**
- **P2:** config.yml, entrypoint.sh, bin/kyb, lib/*.rb, Dockerfile drift
- **P1 escalation:** 3+ P2 drifts on same boss in 24h (possible compromise)
- **P3:** Missing tracked file, stale generated file

**Remediation:** Auto-revert for git-managed files (entrypoint.sh, lib/*.rb, Dockerfile). Per-boss configs (config.yml) require manual acknowledgment. Snapshot rollback via `kyb config rollback`.

---

## CROSS-CUTTING CONCERNS

### Alert Fatigue (`alert-fatigue.md`)

Both cost and security alerts must be designed against fatigue:
- Secret rotation alerts: 1d grace (Prometheus `for: 1d`), staged WARN at 14d, CRIT at 0d for certs
- Vulnerability alerts: `for: 1h` before P1, daily compliance digest
- Disk alerts: After manual cleanup, alerts auto-reset on next prediction cycle
- Config drift: P3/P4 are diary-only, no immediate notification

### Error Budget (`error-budget.md`)

Cost and security issues affect error budgets:
- Disk waste >20%: Tier-2 SLO violation for host service
- Emergency prune triggered: Tier-1 incident (disruption risk from cache loss)
- Critical CVE unresolved >SLO: Tier-2 security SLO breach

### Oncall (`oncall.md`)

Oncall scope includes both cost anomalies and security incidents:
- Cost runaways (agent stuck in loop, token blowout)
- Security alerts (unauthorized access, stale secrets, new critical CVEs)
- Oncall triage path: patrol detects, Feishu notifies, oncall investigates

### Postmortem (`postmortem.md`)

Postmortem process captures both cost and security dimensions:
- Cost incidents: why spend spiked, what guardrail was missing
- Security incidents: exposure window, containment time, fix age

---

## GAPS & RECOMMENDATIONS

### Cost Gaps
| Gap | Severity | Recommended Action | Reference |
|-----|----------|-------------------|-----------|
| No real-time token tracking deployed | High | Deploy `token-tracker.sh` Mode B in boss container | `token-cost.md` |
| No budget alerts wired | High | Seed `infra.token_budgets` and connect to patrol | `token-cost.md` |
| Build cache not monitored | Medium | Implement `lib/kyb/build_monitor.rb` parser | `cache-hit.md` |
| No auto-cleanup for dangling images | Medium | Add `docker image prune --force` to `kyb build` | `dangling-images.md` |
| Boss containers leave zombie sessions | Medium | Add trap handler in `kyb create`/`kyb did create` | `dangling-images.md` |

### Security Gaps
| Gap | Severity | Recommended Action | Reference |
|-----|----------|-------------------|-----------|
| No secret rotation tracking | High | Deploy `secret-rotation-exporter` and seed registry | `secret-rotation.md` |
| No vulnerability scanning | High | Deploy Trivy, create CK tables, run baseline scan | `vuln-scan.md` |
| No network isolation monitoring | High | Deploy `kyb-net-monitor` with conntrack + port scan | `network-compliance.md` |
| No config drift detection | Medium | Deploy `kyb-config-snapshot.sh` + `kyb-config-check.sh` | `config-drift.md` |
| No multi-tenancy audit | Medium | Add `kyb.project`/`kyb.user` labels to all containers | `multi-tenancy.md` |

### Implementation Priority Matrix

**Phase 0 (do now):** token-cost, vuln-scan, secret-rotation, network-compliance
**Phase 1 (this week):** dangling-images, disk-growth, config-drift
**Phase 2 (next week):** model-usage, cache-hit, multi-tenancy
**Phase 3 (backlog):** volume-usage, base-image-age

---

## File Index

| File | Cost Relevance | Security Relevance |
|------|---------------|-------------------|
| `token-cost.md` | Primary (LLM spend tracking) | None |
| `model-usage.md` | Primary (model cost optimization) | None |
| `cache-hit.md` | Secondary (build time = compute cost) | None |
| `dangling-images.md` | Secondary (disk waste = storage cost) | None |
| `volume-usage.md` | Secondary (volume sizing) | None |
| `disk-growth.md` | Secondary (disk exhaustion prevention) | None |
| `base-image-age.md` | Secondary (rebuild cost) | Secondary (vuln drift) |
| `secret-rotation.md` | None | Primary (credential lifecycle) |
| `vuln-scan.md` | None | Primary (CVE management) |
| `network-compliance.md` | None | Primary (isolation + detection) |
| `multi-tenancy.md` | Secondary (per-project billing data) | Primary (isolation audit) |
| `config-drift.md` | None | Primary (integrity monitoring) |
| `proxy-intercept.md` | None | Secondary (traffic inspection) |
| `sidecar-intercept.md` | None | Secondary (traffic inspection) |
| `permission-latency.md` | None | Secondary (access control) |
| `incident-severity.md` | Both (cost incident classification) | Both (security incident classification) |
| `alert-fatigue.md` | Both | Both |
| `oncall.md` | Both (cost runaways) | Both (security response) |
| `postmortem.md` | Both | Both |
| `error-budget.md` | Both (cost SLOs) | Both (security SLOs) |

---

**Total estimated implementation effort for Phase 0-1:** ~24 hours across all cost and security reviews.
**Annual cost at risk without Phase 0:** Unmonitored LLM spend (est. $640/mo target, unbounded without tracking) + disk exhaustion incidents + credential expiry outages.
**Annual security risk without Phase 0:** Undetected CVEs in production images + invisible lateral movement + no secret rotation + unmonitored config drift.
