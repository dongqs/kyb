---
decision: 稍后做
---

# Auto-Remediation Priority: What to Automate First

**Date:** 2026-05-23
**Status:** Synthesis / Decision Record
**Prerequisite reading:**
- `docs/infra/designs/issue-automation.md` and reviews E1/E2/E3
- `docs/infra/reviews/dangling-images.md` (container auto-cleanup design)
- `docs/infra/5min-patrol-guide.md` and `docs/infra/reviews/otel-patrol.md` (patrol + OTel)
- `docs/infra/reviews/self-diagnosis.md` (boss self-healing playbook)

---

## Summary

Three automation candidates have emerged from the infra review cycle:

| Candidate | Scope | Current State | Implementation Cost |
|-----------|-------|---------------|-------------------|
| **A: Container auto-cleanup** | Docker disk waste → auto-prune (dangling images, zombie containers, stale build cache) | Fully designed in `dangling-images.md`; 4-tier policy defined | Low: one patrol-integrated script + CK table |
| **B: Patrol self-heal** | Patrol detects failure → boss dispatches fix (no human in loop) | Detection exists; fix still manual via boss dispatch | Medium: each failure mode needs a fix script |
| **C: Issue auto-triage** | GitLab issue → Feishu notification via cc-connect cron | Designed in `issue-automation.md`; reviewed E1/E2/E3; conditionally approved | Low: one cron script + state file |

This document answers: **what order should we implement these?**

---

## Priority Order

### 1. Container Auto-Cleanup (P0 — Do This First)

**Why first.** Disk is the most predictable failure mode. The data is already collected: 29 GB reclaimable, zombie containers account for 13 GB, dangling images 6 GB. Every day this is not automated, disk grows. When disk hits 85%, containers crash. Not "if" but "when."

**What already exists:**
- Full design in `dangling-images.md` with 4-tier policy (Green/Yellow/Red/Critical)
- CK table schema defined: `infra.disk_waste_snapshots`
- Collector script written and ready
- Retention windows defined per resource type
- Exempt image list documented
- Alert rules specified

**What is missing (implementation gap):**
- Add `docker image prune --force` to `kyb build` post-build hook (highest ROI single action)
- Add trap handler in `kyb create`/`kyb did create` for zombie containers (saves 13 GB)
- Wire the collector into the 5-minute patrol cycle
- Enable soft prune (Green/Yellow tier) after 1-week monitor-only baseline
- Log prune events to CK (`infra.prune_events`)

**Why it beats the other two candidates:**
- Disk full = P0 incident. The other two candidates are P1 at worst.
- The design is complete. No new review needed. Phase 1 (collector + CK schema) can be done in one session.
- Every patrol cycle without auto-cleanup is a patrol cycle accumulating waste.

---

### 2. Patrol Self-Heal (P1 — Do Second)

**Why second.** The 5-minute patrol already detects problems (sibling dead, container down, disk high, network unreachable). But detection without remediation is just noise: it alerts the user, the user dispatches, the fix waits for human response time.

**What already exists:**
- 5-minute patrol guide with 4 phases (dispatch, check, heartbeat, report)
- OTel tracing design for patrol rounds (`otel-patrol.md`)
- Self-diagnosis playbook for boss crash recovery (`self-diagnosis.md`)
- cc-connect healthcheck script (`cc-healthcheck`)

**What is missing (implementation gap):**
- Each failure mode needs a fix script. Examples:
  - Sibling dead: `docker restart <sibling>` (straightforward)
  - Container missing: `docker run <expected-container>` (medium complexity)
  - Disk high: trigger tier-appropriate prune (already handled by #1)
  - Network down: flapping fix is harder than restart (needs investigation)
- Auto-remediation must be idempotent and rate-limited (don't restart a container 12 times in 5 minutes)
- Must not make things worse: restarting a database container = data loss risk

**Why it goes second, not first:**
- It is more complex than auto-cleanup. Each failure mode needs a different fix. Some (network partition) cannot be auto-fixed at all.
- Auto-cleanup buys us disk safety, which reduces one of patrol's most common alerts. Fewer alerts = easier to build self-heal.
- Partial self-heal (only easy failures) is still useful and can be shipped incrementally.

**Recommended approach:**
- Start with the simplest failure mode: **dead sibling restart** (just `docker restart` or re-create a known container spec)
- Add `docker ps` expectation list: the patrol knows which container should be running. If a non-boss, non-DB container is missing, restart it.
- Do NOT auto-restart databases or ClickHouse. These need human verification.
- Log every auto-remediation action to `infra.auto_remediation` CK table.

---

### 3. Issue Auto-Triage (P2 — Do Third)

**Why third.** Issue notifications are valuable but not urgent. The current workflow (boss discovers issues during patrol or when user mentions them) works. The gap is convenience, not stability.

**What already exists:**
- Design doc `issue-automation.md` with 3 approaches (script, webhook, cc-connect cron)
- Reviews E1 (cron reliability), E2 (GitLab API), E3 (curl hardening)
- All mitigations identified: state file persistence, token from file, pagination, `set -euo pipefail`, atomic writes, PATH setup

**What is missing (implementation gap):**
- Write `check-issues.sh` with all E3 hardening recommendations:
  - `set -euo pipefail`
  - Token from `/run/secrets/gitlab_token`, not env var or arg
  - `curl -fsSL` with error handling
  - `jq -e` validation, atomic state file writes (`mv` pattern)
  - `PATH` export for cron environment
  - Startup delay / readiness check
- Register cron in cc-connect: `cc-connect cron add --cron "*/10 * * * *" --exec "timeout 60 sh check-issues.sh" --desc "GitLab Issue Tracker"`
- Add heartbeat monitoring for the cron job itself

**Why it goes last:**
- Zero infrastructure risk. A bug in the issue poller sends a duplicate notification; it does not crash containers or lose data.
- The design is simple and well-reviewed. When it's time, implementation is one session.
- Issue triage is a notification system, not a remediation system. Patrol self-heal and auto-cleanup both close failure loops; issue triage opens an information channel.

---

## Decision Matrix

| Criterion | Auto-Cleanup | Patrol Self-Heal | Issue Triage |
|-----------|-------------|-----------------|--------------|
| Prevents P0 incident | Yes (disk full) | Partially | No |
| Design complete | Yes | Partial | Yes |
| Reviews done | Yes (dangling-images.md) | Partial (otel-patrol.md) | Yes (E1/E2/E3) |
| Implementation time | 1 session | 2-3 sessions | 1 session |
| Risk if buggy | Container data loss | Cascade failure | Duplicate notification |
| User-visible impact | None (infra stability) | None (infra stability) | High (new notification) |
| Daily value | Avoids 29 GB waste/month | Reduces manual response | Replaces manual check |

**Verdict:** The risk/reward curve clearly favors auto-cleanup -> patrol self-heal -> issue triage.

---

## Implementation Sequence

### Sprint 1: Container Auto-Cleanup

1. Add `docker image prune --force` to `kyb build` (5 min, immediate waste reduction)
2. Add trap handler for zombie containers in `kyb create`/`kyb did create` (15 min)
3. Deploy collector script to boss patrol (30 min)
4. Run 1-week monitor-only baseline (no auto-prune, just observe)
5. Enable soft prune (Green/Yellow) after baseline review

### Sprint 2: Patrol Self-Heal (Phase 1)

1. Add dead-sibling restart to patrol (auto `docker restart` when heartbeat expires)
2. Add expected-container manifest; restart missing non-DB containers
3. Add idempotency guard (max 1 restart per container per 15 min)
4. Log all auto-remediation to CK table

### Sprint 3: Patrol Self-Heal (Phase 2) + Issue Triage

1. Handle more complex patrol failures (disk alert -> dispatch auto-cleanup, already covered by Sprint 1)
2. Write `check-issues.sh` with E3 hardening
3. Register cc-connect cron
4. Monitor for 1 week, tune polling interval and notification format

---

## What Not to Automate (Yet)

These were considered and deferred:

| Candidate | Defer Reason |
|-----------|-------------|
| **Auto-rotate secrets** | Too risky to automate without a secure secrets manager; manual rotation with calendar reminder is safer |
| **Auto-scale containers** | No evidence of load patterns that need it; current fleet is small and stable |
| **Auto-rebuild registry cache** | Cache is stable; rebuild on version upgrade is a manual decision with verification step |
| **Auto-retry CI pipelines** | CI flakiness should be fixed, not automated around; auto-retry masks root causes |

---

## Verdict

**Implement order: auto-cleanup first, patrol self-heal second, issue triage third.**

The rationale is asymmetric: auto-cleanup prevents a P0 with low risk, patrol self-heal reduces human toil with medium risk, issue triage adds convenience with minimal risk. Ship in that order, and each sprint reduces the infra team's cognitive load more than the last.

The three automations together close three distinct loops:
1. **Disk loop**: waste accumulates -> auto-prune -> space freed (closed)
2. **Failure loop**: patrol detects -> patrol fixes -> patrol verifies (closed)  
3. **Information loop**: issue created -> bot notifies -> boss triages (closed)

Ship the loops in order of consequence severity. That is: disk first.

> /人◕ ‿‿ ◕人＼
