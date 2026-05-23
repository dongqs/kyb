---
decision: 稍后做
---

# Chaos Engineering Experiments for Infra Observability

**Author:** Boss
**Date:** 2026-05-23
**Status:** Design
**Scope:** Verify that observable failures produce the expected alerts and recovery actions across the kyb multi-cluster infra.

---

## Table of Contents

1. [Why Chaos Engineering](#1-why-chaos-engineering)
2. [Prerequisites](#2-prerequisites)
3. [Experiment Matrix](#3-experiment-matrix)
   - [Experiment 1: Kill cc-connect](#31-experiment-1-kill-cc-connect)
   - [Experiment 2: Stop ClickHouse](#32-experiment-2-stop-clickhouse)
   - [Experiment 3: Disconnect Network](#33-experiment-3-disconnect-network)
   - [Experiment 4: Fill Disk](#34-experiment-4-fill-disk)
4. [Experiment Protocol](#4-experiment-protocol)
5. [Baseline Measurements](#5-baseline-measurements)
6. [Rollback Procedures](#6-rollback-procedures)
7. [Scoring & Regression](#7-scoring--regression)

---

## 1. Why Chaos Engineering

The kyb infra has accumulated a layered observability stack:

| Layer | Component | What It Monitors |
|-------|-----------|-----------------|
| L1 | cc-healthcheck (bash) | Container alive, Docker healthy, Feishu token alive |
| L2 | 5-min patrol (agent) | Heartbeat timing, sibling liveness, disks, proxies |
| L3 | Docker event watcher | Container lifecycle (create/die/destroy) |
| L4 | Crash loop detector | Restart frequency per container |
| L5 | WS health monitor | WebSocket reconnect rate, connection age |
| L6 | Alert fatigue monitor | Meta-monitoring of alert volume |

Each layer has been designed in isolation. We have never verified that a **real failure in production** propagates through the expected layers and produces an actionable alert. These experiments fill that gap.

### What We Are Testing

- **Detection latency**: How long between fault injection and alert firing?
- **Signal quality**: Does the alert contain enough context to triage (container name, cluster, error)?
- **Coverage gaps**: Which failures are invisible to the current stack?
- **Recovery**: Does auto-healing work (cc-healthcheck restart)? If not, does the alert escalate?
- **Non-confusion**: Does one failure trigger unrelated alerts (false cascade)?

---

## 2. Prerequisites

### 2.1 Before Running Any Experiment

```bash
# 1. Record current state
kyb exec kyb-infra-boss -- docker ps --format '{{.Names}} {{.Status}}'
kyb exec kyb-infra-boss -- df -h /
curl -s http://host.orb.internal:8123/?query="SELECT count() FROM infra.docker_events"
curl -s http://host.orb.internal:8123/?query="SELECT count() FROM infra.crash_loops"

# 2. Confirm alert sink is reachable
#    Feishu webhook responds, diary directory writable
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"msg_type":"text","content":{"text":"[CHAOS] Starting experiment suite"}}' \
  "$FEISHU_WEBHOOK_URL"

# 3. Notify the user
kyb notify urgent "Chaos experiment suite starting. Expect alerts for next 30 min."
```

### 2.2 Safety Gates

| Gate | Condition | Action |
|------|-----------|--------|
| Pre-existing incident | Any P0/P1 alert fired in last 30 min | Abort, reschedule |
| User veto | User replies "stop" or "wait" | Abort immediately |
| Runbook exists | Rollback steps defined (see Sec 6) | Must confirm before experiment |
| Time window | Experiments run 09:00-18:00 only | No overnight experiments |
| Max duration | Single experiment <= 5 minutes | Kill switch at 5 min |

### 2.3 Measurement Tools

```bash
# Capture alert timeline from Feishu group
PATROL_HB_DIR=".kyb-diaries"
ALERT_LOG=".kyb-diaries/chaos-alert-timeline.jsonl"

# Continuous timestamp writer
while true; do
  echo "{\"t\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"phase\":\"$PHASE\",\"event\":\"$EVENT\"}" >> "$ALERT_LOG"
  sleep 5
done
```

---

## 3. Experiment Matrix

### 3.1 Experiment 1: Kill cc-connect

#### Objective

Verify that cc-connect failure is detected by cc-healthcheck (L1), produces a Docker event (L3), triggers crash-loop detection if it restarts repeatedly (L4), and escalates to a Feishu alert.

#### Expected Alert Chain

```
T+0s    Kill cc-connect (docker kill)
T+1s    Docker emits 'die' event -> infra.docker_events
T+?s    cc-healthcheck runs (every 60s?) -> detects container unhealthy -> attempts restart
T+?s    If restart succeeds: alert "cc-connect restarted" (info)
T+?s    If restart fails:   alert "cc-connect down" (P1) -> Feishu notification
T+?s    If restart loops:   crash-loop detector fires "cc-connect crash loop" (P1)
```

#### Hypothesis

1. Detection latency: cc-healthcheck detects failure within 60 seconds (its check interval).
2. Docker event `die` is written to `infra.docker_events` within 5 seconds.
3. A single kill-restart cycle produces exactly 1 alert (info-level restart notification).
4. Three kills in 5 minutes produce a P1 crash-loop alert.

#### Procedure

```bash
# Phase 0: Baseline
docker ps --filter "name=kyb-infra-cc-connect" --format "{{.ID}} {{.Status}}"
curl -s "http://host.orb.internal:8123/?query=SELECT count() FROM infra.docker_events WHERE event='die' AND container_name LIKE '%cc-connect%'"

# Phase 1: Single kill
echo "[$(date -u +%H:%M:%S)] PHASE 1: killing cc-connect once"
docker kill kyb-infra-cc-connect
sleep 120    # Wait for healthcheck cycle + alert
# Observe: did cc-healthcheck restart it? Did alert fire?

# Phase 2: Crash loop (3 kills in 5 min)
echo "[$(date -u +%H:%M:%S)] PHASE 2: crash loop sequence"
for i in 1 2 3; do
  docker kill kyb-infra-cc-connect
  sleep 90
done
sleep 120
# Observe: crash-loop detector fires P1?

# Phase 3: Verify recorded state
curl -s "http://host.orb.internal:8123/?query=SELECT event, container_name, _time FROM infra.docker_events WHERE container_name LIKE '%cc-connect%' AND event='die' ORDER BY _time DESC LIMIT 10"
curl -s "http://host.orb.internal:8123/?query=SELECT * FROM infra.crash_loops WHERE container_name LIKE '%cc-connect%' ORDER BY detected_at DESC LIMIT 5"
```

#### Success Criteria

| Criterion | How to Measure | Pass/Fail |
|-----------|---------------|-----------|
| Docker event recorded | `infra.docker_events` has `die` event within 5s | |
| Auto-restart occurs | `docker ps` shows container up within 120s | |
| Info alert fires | Feishu group receives restart notification | |
| Crash loop detected (phase 2) | `infra.crash_loops` has P1 record within 10 min | |
| Crash loop alert fires | Feishu group receives P1 crash-loop alert | |
| No false positives | Other containers not reported as crashed | |

---

### 3.2 Experiment 2: Stop ClickHouse

#### Objective

Verify that ClickHouse outage is detected by all upstream data pipelines (docker event watcher, Vector/Fluentd, patrol SQL queries) and that the outage alert reaches the operator. This is the most critical experiment because CK is the central observability store -- if CK goes down, we lose visibility into everything else.

#### Expected Alert Chain

```
T+0s    Stop ClickHouse (docker stop kyb-infra-ck)
T+?s    docker-event-watcher detects container 'stop' event -> tries to write to CK -> write fails
T+?s    Patrol runs -> CK query fails -> patrol reports "CK unreachable" (P1)
T+?s    All upstream pipelines (Vector, OTel) buffer locally or drop data
T+?s    docker-event-watcher retry logic kicks in (if any)
```

#### Hypothesis

1. CK stop is detected by the patrol's next scheduled run (within 5 minutes max).
2. The patrol's alert contains: container name, cluster, error message from failed CK query.
3. Docker event watcher's write failure is itself detectable (we can see failed writes in watcher logs).
4. No data loss occurs for < 5 min CK outage if upstream pipelines buffer.
5. CK restart is detected and "CK recovered" alert fires.

#### Procedure

```bash
# Phase 0: Verify CK is healthy
curl -s "http://host.orb.internal:8123/?query=SELECT 1"
docker ps --filter "name=kyb-infra-ck" --format "{{.ID}} {{.Status}}"

# Phase 1: Stop CK
echo "[$(date -u +%H:%M:%S)] PHASE 1: stopping ClickHouse"
docker stop kyb-infra-ck
sleep 30
# Verify CK down
curl -s "http://host.orb.internal:8123/?query=SELECT 1" || echo "CK unreachable (expected)"
docker ps --filter "name=kyb-infra-ck"

# Phase 2: Wait for patrol to detect
echo "[$(date -u +%H:%M:%S)] PHASE 2: waiting for patrol detection"
sleep 300    # Up to one full patrol cycle (5 min)
# Did the patrol agent report CK down?

# Phase 3: Restart CK
echo "[$(date -u +%H:%M:%S)] PHASE 3: restarting ClickHouse"
docker start kyb-infra-ck
sleep 30
# Verify CK healthy
curl -s "http://host.orb.internal:8123/?query=SELECT 1"
docker ps --filter "name=kyb-infra-ck" --format "{{.ID}} {{.Status}}"

# Phase 4: Verify data integrity
echo "[$(date -u +%H:%M:%S)] PHASE 4: checking data continuity"
curl -s "http://host.orb.internal:8123/?query=SELECT count(), max(_time) FROM infra.docker_events"
# Check for time gap in events
curl -s "http://host.orb.internal:8123/?query=SELECT toStartOfMinute(_time) AS m, count() FROM infra.docker_events WHERE _time > now() - INTERVAL 30 MINUTE GROUP BY m ORDER BY m"
```

#### Success Criteria

| Criterion | How to Measure | Pass/Fail |
|-----------|---------------|-----------|
| CK stop detected | Patrol reports "CK unreachable" within 5 min | |
| Alert contains context | Feishu message includes container + cluster + error | |
| Watcher failure recorded | docker-event-watcher logs show write failure | |
| Data gap < 5 min | `infra.docker_events` has < 5 min gap during outage | |
| CK recovery detected | "CK recovered" alert fires within 1 min of restart | |
| No cascade | Other infra alerts do NOT fire (PG, Redis, cc-connect unaffected) | |

---

### 3.3 Experiment 3: Disconnect Network

#### Objective

Verify that network partition is detected by: proxy connectivity checks (GitHub/GitLab access in patrol), inter-sibling heartbeat failures, cc-connect WebSocket disconnection, and that the alert identifies the correct root cause (network vs. service crash).

#### Expected Alert Chain

```
T+0s    iptables drop all outbound (or docker network disconnect)
T+?s    cc-connect WS drops -> reconnects fail -> cc-healthcheck reports "Feishu token expired" or connect error
T+?s    Patrol runs -> GitHub/GitLab curl fails -> proxy check reports "PROXY_DOWN"
T+?s    Sibling heartbeats stop updating -> 15 min later: "SIBLING_DEAD"
T+?s    Feishu notification delivery fails (webhook also down) -> alert goes to diary only
```

#### Hypothesis

1. Network failure is detected by the proxy check within 5 minutes.
2. cc-connect WS disconnection is detected within 60 seconds (heartbeat timeout).
3. If the network failure affects the Feishu webhook, the alert falls back to diary file.
4. Multiple alerts fire (proxy + cc-connect + sibling) but they should be correlated to the same root cause (network).
5. When network is restored, all services recover within 2 minutes without manual intervention.

#### Procedure

> **WARNING**: Disconnecting network will prevent Feishu alerts from being delivered.
> The observability system itself goes blind. Ensure alternative verification
> (diary file, container logs observed directly) before starting.

```bash
# Phase 0: Record baseline network state
curl -s --max-time 5 https://github.com && echo " GITHUB_OK" || echo " GITHUB_DOWN"
curl -s --max-time 5 https://git.leyantech.com && echo " GITLAB_OK" || echo " GITLAB_DOWN"
PATROL_HB_1=$(cat .kyb-diaries/.patrol-1-hb 2>/dev/null)
PATROL_HB_2=$(cat .kyb-diaries/.patrol-2-hb 2>/dev/null)
PATROL_HB_3=$(cat .kyb-diaries/.patrol-3-hb 2>/dev/null)
echo "Heartbeats: $PATROL_HB_1 | $PATROL_HB_2 | $PATROL_HB_3"

# Phase 1: Block outbound network (within the container)
echo "[$(date -u +%H:%M:%S)] PHASE 1: blocking outbound traffic"
# Use iptables to drop outbound (within infra-boss container)
iptables -A OUTPUT -p tcp --dport 443 -j DROP
iptables -A OUTPUT -p tcp --dport 80 -j DROP
iptables -A OUTPUT -p udp --dport 53 -j DROP   # DNS
sleep 5
# Verify network is down
curl -s --max-time 5 https://github.com && echo " UNEXPECTED_OK" || echo " BLOCKED (expected)"
curl -s --max-time 5 https://git.leyantech.com && echo " UNEXPECTED_OK" || echo " BLOCKED (expected)"

# Phase 2: Wait for detection
echo "[$(date -u +%H:%M:%S)] PHASE 2: waiting for network failure detection"
sleep 300    # 5 min for full patrol cycle

# Phase 3: Observe alerts (read diary directly since Feishu may be down)
cat .kyb-diaries/2026-05-23-infra-boss-night.md 2>/dev/null | tail -30
ls -la .kyb-diaries/.patrol-*-hb 2>/dev/null
for f in .kyb-diaries/.patrol-*-hb; do
  echo "=== $f ==="
  cat "$f"
done

# Phase 4: Restore network
echo "[$(date -u +%H:%M:%S)] PHASE 4: restoring outbound traffic"
iptables -F OUTPUT
sleep 5
curl -s --max-time 5 https://github.com && echo " GITHUB_OK (restored)" || echo " GITHUB_DOWN (unexpected)"
curl -s --max-time 5 https://git.leyantech.com && echo " GITLAB_OK (restored)" || echo " GITLAB_DOWN (unexpected)"

# Phase 5: Verify recovery
echo "[$(date -u +%H:%M:%S)] PHASE 5: verifying recovery"
sleep 120    # Wait for services to reconnect
# cc-connect should have reconnected WS
# Siblings should resume heartbeats
# Proxy check should pass
```

#### Success Criteria

| Criterion | How to Measure | Pass/Fail |
|-----------|---------------|-----------|
| Proxy check detects failure | Patrol agent reports "PROXY_DOWN" in diary | |
| Sibling heartbeat stall | `.patrol-*-hb` timestamps stop updating | |
| cc-connect WS drops | Logs show WS disconnect (verify after restore) | |
| Fallback alert works | Diary contains network failure alert (since Feishu may be down) | |
| Auto-recovery on restore | All probes pass within 2 min of iptables flush | |
| Single root cause inferred | All alerts reference "network" not "service crash" | |

---

### 3.4 Experiment 4: Fill Disk

#### Objective

Verify that disk pressure is detected by the patrol's `df -h` check BEFORE services start failing, and that alerts escalate as disk usage crosses thresholds (90%, 95%, 99%).

#### Expected Alert Chain

```
T+0s    Start writing garbage to fill disk
T+?s    Patrol detects disk > 90% -> "DISK_WARNING" alert (P2)
T+?s    Docker starts failing (no space for new containers/logs)
T+?s    Patrol detects disk > 95% -> "DISK_CRITICAL" alert (P1)
T+?s    cc-connect may crash (can't write logs)
T+?s    CK may crash (can't write data)
```

#### Hypothesis

1. The patrol's `df -h` check will detect disk usage at the configured thresholds (90%, 95%).
2. A WARNING alert (P2) fires at 90% with actionable info (which partition, current usage, top consumer by directory).
3. A CRITICAL alert (P1) fires at 95%.
4. The alert identifies the top disk consumer (e.g., `/var/lib/docker`, `/var/log`, ClickHouse data dir).
5. Docker operations (container create, log write) fail before 100% disk, providing a second signal.

#### Procedure

> **WARNING**: This experiment fills real disk space. The fill file MUST be
> created in a location that is easy to clean (not ClickHouse data dir,
> not Docker overlay). Use `/tmp/chaos-fill` with a max size of 500MB.
> On a typical dev machine this should trigger thresholds without causing
> actual service disruption.
>
> **Safety**: Set a hard limit with `dd` or `fallocate` controlled size.
> Never use `:(){ :|:& };:` or similar fork bombs.

```bash
# Phase 0: Check current disk usage
df -h /
df -h /var/lib/docker
du -sh /var/log/
du -sh /var/lib/clickhouse/ 2>/dev/null || echo "No CK data dir"

# Determine safe fill amount: target 92% from current %
CURRENT_PCT=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
TARGET_PCT=92
AVAIL_KB=$(df / | tail -1 | awk '{print $4}')
# Calculate: we need to fill enough to go from CURRENT% to TARGET%
FILL_KB=$(( (TARGET_PCT - CURRENT_PCT) * (100 - CURRENT_PCT) * AVAIL_KB / (100 * 100) ))
# But cap at 500MB for safety
if [ "$FILL_KB" -gt 512000 ]; then
  FILL_KB=512000
  echo "Capping fill to 500MB (calculated $FILL_KB KB)"
fi
echo "Current disk: ${CURRENT_PCT}%, Target: ${TARGET_PCT}%, Fill size: ${FILL_KB} KB"

# Phase 1: Create fill file
echo "[$(date -u +%H:%M:%S)] PHASE 1: filling disk to ${TARGET_PCT}%"
dd if=/dev/zero of=/tmp/chaos-fill bs=1M count=$((FILL_KB / 1024)) 2>/dev/null
df -h /
CURRENT_PCT=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
echo "Disk now at ${CURRENT_PCT}%"

# Phase 2: Wait for patrol detection
echo "[$(date -u +%H:%M:%S)] PHASE 2: waiting for patrol disk check"
sleep 300    # Up to 5 min for patrol to run

# Phase 3: Remove fill file (restore disk)
echo "[$(date -u +%H:%M:%S)] PHASE 3: removing fill file"
rm /tmp/chaos-fill
df -h /
sleep 60

# Phase 4: Verify recovery alert
echo "[$(date -u +%H:%M:%S)] PHASE 4: verifying disk recovery"
curl -s "http://host.orb.internal:8123/?query=SELECT * FROM infra.disk_events ORDER BY _time DESC LIMIT 5" 2>/dev/null || echo "No disk_events table (check naming)"
```

#### Success Criteria

| Criterion | How to Measure | Pass/Fail |
|-----------|---------------|-----------|
| DISK_WARNING alert fires at 90% | Feishu/diary records alert within 5 min | |
| Alert includes disk context | Message shows partition, usage %, top dir | |
| Docker event watcher survives | `infra.docker_events` has no gap during experiment | |
| CK remains healthy | Queries succeed during experiment | |
| DISK_RECOVERED alert fires | After `rm /tmp/chaos-fill`, recovery alert fires | |

---

## 4. Experiment Protocol

### 4.1 Sequence

Run experiments in order of increasing risk:

```
1. Kill cc-connect     (low risk, auto-heals)
2. Fill disk           (medium risk, bounded by 500MB cap)
3. Stop CK             (high risk, impacts all observability)
4. Disconnect network  (highest risk, blinds the observability system)
```

### 4.2 Per-Experiment Checklist

- [ ] 1. User notified (`kyb notify urgent`)
- [ ] 2. Baseline recorded (metrics in Sec 5)
- [ ] 3. Monitoring tail started (`docker logs -f kyb-infra-boss` in background)
- [ ] 4. Rollback steps confirmed (Sec 6)
- [ ] 5. Experiment executed
- [ ] 6. Results recorded to `CHAOS_RESULT.md` (template below)
- [ ] 7. Rollback confirmed (system returned to baseline)
- [ ] 8. User notified (`kyb notify done`)

### 4.3 Abort Conditions

Abort immediately if:

- Any service does NOT auto-recover within 5 minutes of rollback
- A P0 alert fires that is NOT part of the experiment
- The monitoring container itself crashes
- User sends "stop" or "abort" in Feishu

```bash
# Abort procedure
echo "[ABORT] $(date -u +%H:%M:%S) - aborting experiment" >> "$ALERT_LOG"
# Kill all experiment processes
pkill -f "chaos-fill" 2>/dev/null || true
# Restore known state (see Sec 6)
# Notify user
kyb notify urgent "Chaos experiment ABORTED. Investigating."
```

---

## 5. Baseline Measurements

Record these before ANY experiment:

| Metric | Current Value | After Experiment | Delta |
|--------|---------------|------------------|-------|
| `infra.docker_events` row count | | | |
| `infra.crash_loops` row count | | | |
| Disk usage `/` (%) | | | |
| Disk usage `/var/lib/docker` (%) | | | |
| cc-connect uptime (seconds) | | | |
| CK uptime (seconds) | | | |
| Patrol heartbeat age (youngest) | | | |
| Feishu webhook latency (ms) | | | |
| GitHub probe latency (ms) | | | |
| GitLab probe latency (ms) | | | |

---

## 6. Rollback Procedures

### 6.1 Kill cc-connect

```bash
# Auto-heals: cc-healthcheck restarts it within 120s
# Manual: 
docker start kyb-infra-cc-connect
docker exec kyb-infra-cc-connect cc-healthcheck
```

### 6.2 Stop ClickHouse

```bash
docker start kyb-infra-ck
# Wait for CK to accept connections
for i in $(seq 1 30); do
  if curl -s "http://host.orb.internal:8123/?query=SELECT 1" >/dev/null 2>&1; then
    echo "CK recovered after ${i}s"
    break
  fi
  sleep 1
done
```

### 6.3 Disconnect Network

```bash
# Flush all iptables rules
iptables -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
# Verify
curl -s --max-time 5 https://github.com
```

### 6.4 Fill Disk

```bash
# Remove fill file
rm -f /tmp/chaos-fill
# Clean Docker cache if needed
docker system prune -f --volumes 2>/dev/null || true
# Verify
df -h /
```

---

## 7. Scoring & Regression

### 7.1 Scoring Rubric

Each experiment is scored 0-5 on four axes, giving a **total score out of 20**.

| Axis | 0 | 1 | 2 | 3 | 4 | 5 |
|------|---|---|---|---|---|---|
| **Detection** | Not detected | Detected >30 min late | Detected >15 min late | Detected >5 min late | Detected <5 min late but no details | Detected <5 min with full context |
| **Alert quality** | No alert | Alert but unparseable | Alert with wrong severity | Alert correct severity but no context | Alert correct severity + partial context | Alert correct severity + container/cluster/error + escalation path |
| **Recovery** | Never recovered | Manual intervention took >30 min | Manual intervention took >15 min | Manual recovery with clear runbook | Auto-healed but slow (>5 min) | Auto-healed within 2 min |
| **Noise control** | Entire stack false-alarmed | >5 false alerts | 3-5 false alerts | 1-2 false alerts | 0 false alerts, 1 duplicate | 0 false, 0 duplicates, correlation hint |

### 7.2 Experiment Record Template

After each experiment, create a record:

```markdown
## Experiment: <name>
**Date**: 2026-05-23
**Run by**: Boss / <agent-name>
**Cluster**: mac-orbstack | aliyun | office

### Timeline

| T+ | Event | Observed? |
|----|-------|-----------|
| 0s | Injection | |
| +Xs | First detection | |
| +Ys | First alert | |
| +Zs | Recovery | |

### Scores

| Axis | Score | Notes |
|------|-------|-------|
| Detection | /5 | |
| Alert quality | /5 | |
| Recovery | /5 | |
| Noise control | /5 | |
| **Total** | **/20** | |

### Gaps Found

- <what was missing, confusing, or wrong>

### Action Items

- [ ] <fix description> — assignee

### Verdict

PASS / FAIL / INCONCLUSIVE
```

### 7.3 Regression Run

After any observability change (new alert rule, pipeline change, dashboard update):

1. Re-run the affected experiment(s)
2. Compare scores against the baseline run
3. If any score drops > 2 points, the change is a regression and must be fixed

This ensures the observability system does not silently degrade as we add features.

---

## Appendix A: Alert Inventory

| Alert Rule | Source | Expected For Chaos Experiment |
|------------|--------|------------------------------|
| cc-connect down | cc-healthcheck | Experiment 1 |
| cc-connect crash loop | crash-loop detector | Experiment 1 (phase 2) |
| cc-ws reconnect storm | WS health monitor | Experiment 3 |
| CK unreachable | Patrol | Experiment 2 |
| Container die event | docker-event-watcher | Experiments 1, 2 |
| Disk space warning | Patrol (`df -h`) | Experiment 4 |
| Disk space critical | Patrol (`df -h`) | Experiment 4 (if filling enough) |
| Proxy down (GitHub) | Patrol (curl probe) | Experiment 3 |
| Proxy down (GitLab) | Patrol (curl probe) | Experiment 3 |
| Sibling dead | Patrol (heartbeat) | Experiment 3 |
| Feishu delivery failure | cc-connect / hook | Experiment 3 |
| Patrol heartbeat stale | Meta-monitoring | Experiment 3 |

## Appendix B: Experiment Automation (Future)

Once experiments stabilize, encode as a repeatable chaos script:

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/chaos-run <experiment-name>
# Runs the experiment, records timeline, scores it
# Usage: chaos-run kill-cc-connect
```

This script should:
1. Check safety gates (Sec 2.2)
2. Record baseline (Sec 5)
3. Inject fault
4. Wait for detection window
5. Rollback
6. Verify recovery
7. Record results
8. Notify user

---

## Appendix C: Failure Scenarios NOT Covered (Future Work)

| Scenario | Why Not Now | When to Add |
|----------|-------------|-------------|
| Kill PostgreSQL | No alert rules for PG yet | After PG monitoring added |
| Corrupt CK data (bad merge) | No data quality checks | After CK replica/backup validation |
| Docker daemon crash | Would kill the boss container too | After out-of-band monitoring |
| DNS poisoning | Complexity, unclear observability path | After DNS monitoring |
| Clock skew (NTP failure) | No time-sync monitoring | After NTP check added to patrol |
| Certificate expiry | No cert monitoring | After cert-check tool added |
| OOM kill (memory pressure) | No memory pressure alerts | After memory monitoring added |
