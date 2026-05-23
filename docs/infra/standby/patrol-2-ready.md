---
decision: 稍后做
---

# Patrol v2: Unified Patrol System with OTel Traces and Reliability Scoring

**Status:** Ready for implementation
**Designer:** Boss
**File:** `docs/infra/standby/patrol-2-ready.md`
**Supersedes:** `docs/infra/reviews/otel-patrol.md`, `docs/infra/reviews/heartbeat-reliability.md`
**Integrates with:** `docs/infra/reviews/boss-decision-latency.md`

---

## 1. Why Patrol v2

The current patrol system (5-min timer, three siblings, heartbeat files, shell checks) works but has three blind spots that this redesign eliminates:

| Problem | Current State | Patrol v2 Fix |
|---------|--------------|---------------|
| **No traceability** | When patrol fails, we know _that_ it failed but not _where_. Was dispatch stuck? Check hung? Heartbeat write failed? | Full OTel trace per round, file-based context propagation through the entire pipeline |
| **No reliability signal** | Binary alive/dead on heartbeat age alone. An agent crashing every 3rd round looks alive between crashes. | Rolling reliability score (0-100) per agent per round, computed from heartbeat journal history |
| **No latency feedback** | Boss doesn't know if patrol-to-dispatch latency is degrading. A slow boss looks the same as a dead patrol timer. | Decision latency metrics embedded in patrol traces, feeding boss-decision-latency pipeline |

Patrol v2 unifies these three concerns into **one integrated system**:

```
┌─────────────────────────────────────────────────────────────┐
│                    Patrol v2 Round                          │
│                                                             │
│  OTel Trace ────── carries ──────► Reliability Score       │
│       │                                    │                │
│       └──────────── feeds ────────────────►│                │
│                                            ▼                │
│                              Decision Latency Metrics       │
│                                        │                    │
│                                        ▼                    │
│                              Alert Escalation               │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Architecture Overview

### 2.1 One Round, One Trace, One Score

Every patrol round produces:
1. **One OTel trace** (root span `patrol.round` with child spans for each phase)
2. **One reliability score** (computed at heartbeat phase, embedded as heartbeat span attribute)
3. **One decision latency record** (boss's response to any anomalies found)

The three outputs share a common `round_id` (UUID `patr_*`) for cross-referencing in ClickHouse.

### 2.2 Data Flow

```
Timer fires
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. DISPATCH                                                   │
│    ● Read trace_id from env / file                           │
│    ● Create patrol.dispatch span                             │
│    ● Record trigger (cron/manual/recovery)                   │
│    ● On failure: abort with error attributes                 │
└─────────────────────────────────┬────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. CHECK                                                      │
│    ● Create patrol.check span (child of dispatch)            │
│    ● Run docker/disk/network/health sub-checks               │
│    ● Each sub-check = child span                             │
│    ● Record pass/fail counts + detailed attributes           │
└─────────────────────────────────┬────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. HEARTBEAT + SCORE                                          │
│    ● Create patrol.heartbeat span                            │
│    ● Write timestamp file (.patrol-N-hb)                     │
│    ● Append to heartbeat journal (hb-journal-{id}.jsonl)     │
│    ● Check sibling heartbeats                                │
│    ● Compute reliability score from journal history          │
│    ● Embed score in span attributes                          │
│    ● Record sibling_dead / stale events                      │
└─────────────────────────────────┬────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. DECISION (new in v2)                                       │
│    ● If anomalies found, compute boss decision latency       │
│    ● Record trigger_time (patrol anomaly detection)          │
│    ● Record dispatch_time (if boss dispatches a fix)         │
│    ● Write to infra.decision_log                             │
└─────────────────────────────────┬────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. REPORT                                                     │
│    ● Create patrol.report span                               │
│    ● Include score + tier in anomaly report                  │
│    ● Score-based severity escalation                         │
│    ● Write diary entry                                       │
│    ● Send feishu notification if needed                      │
│    ● Close root span (patrol.round)                          │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 Trace → Score → Decision Integration Points

| Integration | Mechanism | Location |
|-------------|-----------|----------|
| Score embedded in trace | `heartbeat.score` attribute on `patrol.heartbeat` span | Step 3 |
| Score drives report severity | `report.severity` determined by score tier | Step 5 |
| Anomaly triggers decision log | `patrol.anomaly.detected` event → `infra.decision_log` write | Step 4 |
| Trace round_id links to score | `round_id` in both `otel.traces` and `otel.patrol_reliability` | Cross-cutting |
| Decision latency KPIs derive from traces | Aggregated from `infra.decision_log` joins with traces | Post-processing |

---

## 3. Span Model (v2, Unified)

The span model from `otel-patrol.md` is extended with reliability score attributes on the heartbeat span and a new decision span (optional, when anomalies are found and acted upon).

### 3.1 Root Span: `patrol.round`

Unchanged from v1. See `docs/infra/reviews/otel-patrol.md` section 2.2.

### 3.2 Span: `patrol.heartbeat` (Extended)

Addition to v1 attributes:

| Attribute | Type | Description |
|-----------|------|-------------|
| `heartbeat.score` | int | Reliability score 0-100 |
| `heartbeat.score_tier` | string | `healthy`/`degraded`/`unstable`/`critical` |
| `heartbeat.score_missed` | int | Missed beat sub-score |
| `heartbeat.score_late` | int | Late beat sub-score |
| `heartbeat.score_sibling` | int | Sibling health sub-score |
| `heartbeat.window_beats` | int | Beats in scoring window (default 6) |
| `heartbeat.window_missed` | int | Missed beats in window |
| `heartbeat.window_late` | int | Late beats in window |

### 3.3 Span: `patrol.decision` (New in v2)

Optional span. Created when the boss detects an anomaly and must decide what to do. Not present in every round (only when anomalies found AND boss acts on them within the patrol round).

```
patrol.decision (child of patrol.round, sibling of patrol.report)
```

| Attribute | Type | Description |
|-----------|------|-------------|
| `decision.trigger_type` | string | What triggered this decision |
| `decision.decision_type` | string | `dispatch` / `acknowledge` / `escalate` / `ignore` |
| `decision.trigger_time` | string | ISO timestamp of anomaly detection |
| `decision.decision_time` | string | ISO timestamp of decision |
| `decision.latency_sec` | int | decision_time - trigger_time |
| `decision.reference_type` | string | `patrol_id` / `sibling_id` |
| `decision.reference_id` | string | The specific entity |
| `decision.score_before` | int | Reliability score at decision time |
| `decision.notes` | string | Brief decision reasoning |

### 3.4 Events

New event on `patrol.decision` span:

| Event name | Attributes | Description |
|-----------|-----------|-------------|
| `patrol.decision.made` | `decision_type`, `latency_sec`, `score_before` | Boss made a decision on an anomaly |

### 3.5 Full Trace Example (v2)

```json
{
  "trace_id": "0x1234...",
  "name": "patrol.round",
  "attributes": {
    "patrol.round.id": "patr_01J2AB...",
    "patrol.round.number": 1,
    "patrol.round.status": "partial",
    "patrol.round.score_floor": 44
  },
  "child_spans": [
    {"name": "patrol.dispatch", "duration_ms": 150, "attributes": {...}},
    {
      "name": "patrol.check", "duration_ms": 15000,
      "child_spans": [
        {"name": "patrol.check.docker", "duration_ms": 2000, "attributes": {...}},
        {"name": "patrol.check.disk", "duration_ms": 500, "attributes": {
          "disk.usage_percent": 88.5,
          ...
        }}
      ]
    },
    {
      "name": "patrol.heartbeat", "duration_ms": 800,
      "attributes": {
        "heartbeat.score": 44,
        "heartbeat.score_tier": "unstable",
        "heartbeat.score_missed": 69,
        "heartbeat.score_late": 0,
        "heartbeat.score_sibling": 50,
        "heartbeat.window_beats": 6,
        "heartbeat.window_missed": 1,
        "heartbeat.window_late": 0,
        "heartbeat.siblings_alive": 1,
        "heartbeat.siblings_dead": 1,
        "heartbeat.dead_siblings": ["boss-claude-2"]
      },
      "events": [
        {
          "name": "patrol.heartbeat.dead",
          "attributes": {
            "sibling_id": "boss-claude-2",
            "last_seen": "2026-05-23T11:44:00Z"
          }
        }
      ]
    },
    {
      "name": "patrol.decision", "duration_ms": 2000,
      "attributes": {
        "decision.trigger_type": "patrol_alert",
        "decision.decision_type": "dispatch",
        "decision.trigger_time": "2026-05-23T12:00:27Z",
        "decision.decision_time": "2026-05-23T12:00:29Z",
        "decision.latency_sec": 2,
        "decision.reference_type": "sibling_id",
        "decision.reference_id": "boss-claude-2",
        "decision.score_before": 44,
        "decision.notes": "sibling-2 dead, dispatching recovery agent"
      },
      "events": [
        {
          "name": "patrol.decision.made",
          "attributes": {
            "decision_type": "dispatch",
            "latency_sec": 2,
            "score_before": 44
          }
        }
      ]
    },
    {
      "name": "patrol.report", "duration_ms": 3000,
      "attributes": {
        "report.anomaly_count": 2,
        "report.severity": "critical",
        "report.notification.success": true,
        "report.diary_written": true
      },
      "events": [
        {
          "name": "patrol.anomaly.detected",
          "attributes": {
            "severity": "critical",
            "component": "sibling",
            "message": "boss-claude-2 heartbeat expired; reliability score 44 (unstable)"
          }
        },
        {
          "name": "patrol.anomaly.detected",
          "attributes": {
            "severity": "warning",
            "component": "disk",
            "message": "disk usage 88.5%, above 85% threshold"
          }
        }
      ]
    }
  ]
}
```

---

## 4. Reliability Scoring (Integrated)

The scoring model from `heartbeat-reliability.md` sections 3.1-3.4 is adopted unchanged. See that document for the full formula. Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| Window size | 6 beats (~30 min) | Number of heartbeats in scoring window |
| Late threshold | 30s | Heartbeat written >30s after deadline = late |
| Missed weight | 50% | Weight of missed beats in composite score |
| Late weight | 25% | Weight of late beats in composite score |
| Sibling weight | 25% | Weight of sibling health in composite score |

### 4.1 Patrol v2 Changes to Scoring

Two changes from the original design:

**1. Score is computed during patrol round, not after.**

Original: score computed as step 3.5 after heartbeat write.
Patrol v2: score computed **during** the heartbeat span and embedded as span attributes. This means the trace carries the score, and the score is available for decision-making in the same round.

**2. Score feeds the decision span.**

If score < 70 (unstable or critical), the patrol automatically creates a `patrol.decision` span. The boss can then:
- Read the score from the trace
- Decide whether to dispatch a recovery agent
- Record the decision latency in the same span

This closes the loop: **score → alert → decision → latency measurement**, all in one trace.

### 4.2 Score → Round Status Mapping

| Score | Tier | `patrol.round.status` | Report severity | Notification |
|-------|------|-----------------------|----------------|-------------|
| 90-100 | healthy | `ok` | `info` | Silent (diary only) |
| 70-89 | degraded | `ok` | `info` | Silent (diary only) |
| 50-69 | unstable | `partial` | `warning` | Feishu, non-urgent |
| 0-49 | critical | `partial` | `critical` | Feishu, urgent ping |

If checks failed (disk > 90%, network unreachable, etc.), the status is always `failed` regardless of score. Score affects the `partial` threshold: a round with no check failures but a low score is `partial`.

### 4.3 Computation Script

The shell/awk implementation from `heartbeat-reliability.md` section 4.1 is used as-is. The script (`~/.kyb/bin/hb-score`) is called during the heartbeat phase, and its output is captured as span attributes.

```bash
# Pseudocode for score integration in patrol prompt
# Step 3a: Write heartbeat file
date -u +%Y-%m-%dT%H:%M:%SZ > .kyb-diaries/.patrol-${N}-hb
echo "GREEN" >> .kyb-diaries/.patrol-${N}-hb

# Step 3b: Append to journal
echo '{"t":"...","seq":...,"status":"ok",...}' >> .kyb-diaries/hb-journal-${AGENT_ID}.jsonl

# Step 3c: Compute score
SCORE_OUTPUT=$(~/.kyb/bin/hb-score)
SCORE=$(echo "$SCORE_OUTPUT" | tail -1)

# Step 3d: Check siblings
# ... existing logic ...

# Step 3e: Record span attributes
# These get written to the OTel trace JSON
echo "heartbeat.score=$SCORE"
echo "heartbeat.score_tier=$(score_to_tier $SCORE)"
```

---

## 5. Decision Latency Integration

### 5.1 When Decision Span Is Created

A `patrol.decision` span is created automatically when ALL of these conditions are true:

1. `patrol.round.status` is `failed` or `partial` (anomalies detected)
2. Score tier is `unstable` or `critical` (score < 70)
3. The boss takes an action (dispatches a fix agent, sends feishu message, etc.)

If conditions 1-2 are true but 3 is false (boss ignores the anomaly), the decision span is **not** created. The missing decision span itself becomes a signal: anomalies without decisions indicate boss inaction, which can be detected via a query against `otel.traces`:

```sql
-- Rounds with anomalies but no decision span = boss inaction
SELECT count()
FROM otel.traces
WHERE name = 'patrol.round'
  AND has(attributes, 'patrol.round.status') 
  AND attributes['patrol.round.status'] IN ('partial', 'failed')
  AND NOT has(child_spans[], 'patrol.decision')
  AND timestamp >= now() - INTERVAL 1 HOUR;
```

### 5.2 Decision Span → infra.decision_log

The decision span attributes map directly to the `infra.decision_log` table from `boss-decision-latency.md`:

| `patrol.decision` attribute | `infra.decision_log` column |
|-----------------------------|----------------------------|
| `decision.trigger_type` | `trigger_type` |
| `decision.decision_type` | `decision_type` |
| `decision.trigger_time` | `trigger_time` |
| `decision.decision_time` | `decision_time` |
| `decision.latency_sec` | `latency_sec` |
| `decision.reference_type` | `reference_type` |
| `decision.reference_id` | `reference_id` |
| `decision.score_before` | `notes` (prefixed "score=X; ...") |
| `patrol.round.id` (root span) | `reference_id` when reference_type=patrol_id |

The decision log can be populated either:
- **From the trace directly** (post-processing: Vector transforms trace JSON into decision_log insert)
- **From an explicit write** (the patrol script writes to both the trace and decision_log)

Patrol v2 prefers the **explicit write** approach for the decision log, because it captures real-time decisions. The trace provides the full context for post-hoc analysis; the decision log provides the latency metrics for dashboards.

### 5.3 Decision Latency Metrics

From the `infra.decision_log` and traces, the following metrics are available:

| Metric | Source | Definition |
|--------|--------|------------|
| PDL (Patrol → Dispatch Latency) | `infra.decision_log` where trigger_type=patrol_alert | decision_time - trigger_time |
| PDR (Patrol → Decision Rate) | `infra.decision_log` where trigger_type=patrol_alert | Count of decisions per patrol round |
| IDR (Inaction Detection Rate) | trace query (see 5.1) | Rounds with anomalies but no decision span |
| Score-Trend-Adjusted PDL | join `patrol_reliability` + `decision_log` | Decision latency grouped by score tier |

---

## 6. ClickHouse Schema Changes

### 6.1 New Column on `otel.patrol_reliability`

Add `round_trace_id` column to link reliability scores to their traces:

```sql
ALTER TABLE otel.patrol_reliability
ADD COLUMN IF NOT EXISTS round_trace_id String DEFAULT '' AFTER round_id;
```

This enables:

```sql
-- Join score with trace attributes in a single query
SELECT
    r.timestamp,
    r.agent_id,
    r.score,
    r.tier,
    t.attributes['patrol.round.status'] AS round_status,
    length(t.child_spans) AS span_count
FROM otel.patrol_reliability r
LEFT JOIN otel.traces t ON r.round_trace_id = t.trace_id
WHERE r.timestamp >= now() - INTERVAL 1 HOUR
ORDER BY r.score ASC
LIMIT 10;
```

### 6.2 New Materialized View: `otel.patrol_v2_unified`

A materialized view that joins traces, reliability scores, and decision latency into one row per round:

```sql
CREATE MATERIALIZED VIEW otel.patrol_v2_unified_mv
ENGINE = MergeTree
ORDER BY (timestamp)
POPULATE
AS SELECT
    -- Round identity
    t.trace_id AS trace_id,
    t.attributes['patrol.round.id'] AS round_id,
    t.timestamp AS timestamp,
    t.attributes['patrol.round.number'] AS round_number,
    t.attributes['patrol.round.agent_id'] AS agent_id,
    
    -- Round outcome
    t.attributes['patrol.round.status'] AS round_status,
    t.duration_ms AS round_duration_ms,
    
    -- Reliability score (from heartbeat span)
    h.attributes['heartbeat.score'] AS score,
    h.attributes['heartbeat.score_tier'] AS score_tier,
    h.attributes['heartbeat.score_missed'] AS score_missed,
    h.attributes['heartbeat.score_late'] AS score_late,
    h.attributes['heartbeat.score_sibling'] AS score_sibling,
    
    -- Check results (from check spans)
    d.attributes['disk.usage_percent'] AS disk_usage_pct,
    dc.attributes['docker.containers_running'] AS containers_running,
    dc.attributes['docker.containers_dead'] AS containers_dead,
    
    -- Decision latency (from decision span, if present)
    dec.attributes['decision.latency_sec'] AS decision_latency_sec,
    dec.attributes['decision.decision_type'] AS decision_type,
    dec.attributes['decision.trigger_type'] AS decision_trigger_type,
    
    -- Anomaly count (from report span events)
    length(arrayFilter(
        x -> x.name = 'patrol.anomaly.detected',
        r.events
    )) AS anomaly_count,
    
    -- Alert info
    r.attributes['report.severity'] AS report_severity,
    r.attributes['report.notification.success'] AS notification_sent
FROM otel.traces AS t
LEFT JOIN otel.traces AS h ON h.trace_id = t.trace_id AND h.name = 'patrol.heartbeat'
LEFT JOIN otel.traces AS d ON d.trace_id = t.trace_id AND d.name = 'patrol.check.disk'
LEFT JOIN otel.traces AS dc ON dc.trace_id = t.trace_id AND dc.name = 'patrol.check.docker'
LEFT JOIN otel.traces AS dec ON dec.trace_id = t.trace_id AND dec.name = 'patrol.decision'
LEFT JOIN otel.traces AS r ON r.trace_id = t.trace_id AND r.name = 'patrol.report'
WHERE t.name = 'patrol.round';
```

### 6.3 Indexing Strategy

For the traces table, patrol v2 queries need two access patterns:

| Query Pattern | Index | Column |
|---------------|-------|--------|
| Find rounds by status + time | Primary key | `(timestamp, name)` |
| Find rounds by score range | Skip index | `attributes['heartbeat.score']` — use `bloom_filter` or `minmax` |
| Join traces by span name | Primary key | `(trace_id, name)` — already covered |

```sql
ALTER TABLE otel.traces ADD INDEX idx_patrol_score
    attributes['heartbeat.score']
    TYPE bloom_filter(0.01)
    GRANULARITY 1;
```

---

## 7. Alert Rules (Patrol v2)

Combined rules from otel-patrol.md and heartbeat-reliability.md, with score-awareness and decision-latency awareness added.

### 7.1 Patrol Health Rules

| Rule | Expression | Level | Description |
|------|-----------|-------|-------------|
| NoPatrolCompleted | `rate(patrol_rounds_total{status=~"ok|partial"}[6m]) == 0` | P0 | Nothing completing for 6+ min |
| ConsecutiveFailures | `increase(patrol_round_failures_total[10m]) > 0 AND increase(patrol_round_failures_total[5m] offset 5m) > 0` | P1 | Two consecutive failed rounds |
| SiblingDead | `increase(patrol_sibling_deaths_total[10m]) > 0` | P1 | Sibling heartbeat lost |

### 7.2 Reliability Score Rules

| Rule | Expression | Level | Description |
|------|-----------|-------|-------------|
| ScoreCritical | `min(patrol_reliability_score) < 50` | P1 | Agent critically unreliable |
| ScoreUnstable | `avg(patrol_reliability_score) < 70` | P2 | Cluster-level instability |
| ScoreDropping | `deriv(patrol_reliability_score[30m]) < -15` | P2 | Rapid reliability degradation |
| NoScoreData | `absent(patrol_reliability_score) for 10m` | P1 | Scoring system itself is down |

### 7.3 Decision Latency Rules

| Rule | Expression | Level | Description |
|------|-----------|-------|-------------|
| PDLTooSlow | `quantile(0.90)(decision_latency_sec{trigger_type=patrol_alert}[15m]) > 30` | P2 | Boss slow to respond to patrol alerts |
| InactionDetected | `patrol_rounds_with_anomaly_no_decision[15m] > 0` | P2 | Patrolled anomalies with zero boss response |
| ScoreLatencyCorrelation | `corr(score, decision_latency_sec)[1h] > 0.5` | P3 | Correlation: low score causes slow response (or vice versa) |

### 7.4 Unified Severity Escalation

The patrol v2 alert severity is computed from **both** the check results and the reliability score:

```
severity = max(
    check_severity(disk, docker, network, health),  -- from check phase
    score_severity(score)                             -- from heartbeat phase
)
```

| Input | Map to Severity |
|-------|----------------|
| Check: 0 failures | severity = info |
| Check: 1+ failures | severity = warning |
| Score: 50-69 | severity = warning (overrides check-based info) |
| Score: 0-49 | severity = critical (overrides check-based warning) |
| Check: disk > 95% | severity = critical (hard override) |

---

## 8. Grafana Dashboard

### 8.1 Panel: Unified Patrol Overview (New)

Single table showing the latest round per agent:

| Agent | Last Round | Status | Score | Tier | Disk % | Containers | Decision | PDL (s) |
|-------|-----------|--------|-------|------|--------|------------|----------|---------|

Source: `otel.patrol_v2_unified_mv`

```sql
SELECT
    agent_id,
    timestamp,
    round_status,
    score,
    score_tier,
    disk_usage_pct,
    containers_running,
    decision_type,
    decision_latency_sec
FROM otel.patrol_v2_unified_mv
WHERE timestamp >= now() - INTERVAL 10 MINUTE
ORDER BY timestamp DESC
LIMIT 20;
```

### 8.2 Panel: Score + Status Time Series (New)

Dual-axis chart:
- Left axis: reliability score (line, 0-100)
- Right axis: round status (heatmap as colored dots: green=ok, yellow=partial, red=failed)
- X-axis: time

Source: `otel.patrol_v2_unified_mv`, one line per agent.

### 8.3 Panel: Decision Latency by Score Tier (New)

Bar chart showing P50/P90 decision latency grouped by score tier:
- X-axis: score tier (healthy, degraded, unstable, critical)
- Y-axis: latency in seconds
- Two bars per tier: P50, P90

```sql
SELECT
    score_tier,
    quantile(0.50)(decision_latency_sec) AS p50,
    quantile(0.90)(decision_latency_sec) AS p90,
    count() AS decisions
FROM otel.patrol_v2_unified_mv
WHERE decision_latency_sec IS NOT NULL
  AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY score_tier;
```

This panel is the key insight: **does the boss respond faster when scores are low?** If latency is high at low scores, there is a correlation problem (the system gets slow exactly when it needs to be fast).

### 8.4 Existing Panels (Unchanged)

- Score Overview (from heartbeat-reliability.md section 5.1)
- Component Breakdown (section 5.2)
- Missed/Late Heatmap (section 5.3)
- Decision Velocity Gauges (from boss-decision-latency.md section "Panel 1")
- Patrol Health Check table (from boss-decision-latency.md section "Panel 6")

---

## 9. Implementation Plan

### Phase 1: Merge Span Models (Day 1)

- [ ] Extend `patrol.heartbeat` span with score attributes (from heartbeat-reliability.md section 7)
- [ ] Add `patrol.decision` span definition to patrol prompt
- [ ] Update trace example docs to show v2 full trace
- [ ] Verify with one manual patrol round

### Phase 2: Scoring Integration (Day 1-2)

- [ ] Install `~/.kyb/bin/hb-score` script on all boss machines
- [ ] Modify patrol prompts to call hb-score during heartbeat phase
- [ ] Verify score output is captured in trace attributes
- [ ] Test with degraded scenario (stop one sibling, observe score drop)

### Phase 3: Decision Span Wiring (Day 2)

- [ ] Modify patrol prompt to create `patrol.decision` span when score < 70 or check failures
- [ ] Wire `patrol.decision` span output to `infra.decision_log` write
- [ ] Verify decision latency metrics appear in CK

### Phase 4: Unified View (Day 2-3)

- [ ] Deploy `otel.patrol_v2_unified_mv` materialized view
- [ ] Add skip index on traces table for score attribute
- [ ] Build unified Grafana panels (sections 8.1-8.3)
- [ ] Deploy combined alert rules (sections 7.1-7.3)

### Phase 5: Validation (Day 3-5)

- [ ] Run 24h with Patrol v2, collect data
- [ ] Verify ScoreLatencyCorrelation query returns useful data
- [ ] Adjust scoring weights if needed
- [ ] Document v2 in patrol guide

---

## 10. Migration: v1 → v2

Patrol v2 is backward-compatible with v1. The migration is a gradual rollout:

### 10.1 What Stays the Same

- Heartbeat timestamp files (`.kyb-diaries/.patrol-{1,2,3}-hb`) — unchanged format
- Sibling health check logic — unchanged
- Check commands (docker ps, df, ping) — unchanged
- Report/diary writing — unchanged

### 10.2 What Changes

| Component | v1 | v2 |
|-----------|----|----|
| Heartbeat journal | Not present | `.kyb-diaries/hb-journal-{id}.jsonl` |
| Score computation | Not present | `~/.kyb/bin/hb-score` during heartbeat phase |
| OTel trace attributes | Score attributes absent | `heartbeat.score*` attributes on heartbeat span |
| OTel span set | 4 spans (dispatch, check, heartbeat, report) | 5 spans (add `patrol.decision`) |
| Decision log | Not present | Written from `patrol.decision` span |

### 10.3 Rollback

To roll back to v1:
1. Remove journal file writes from patrol prompts
2. Remove hb-score call
3. Remove `patrol.decision` span creation
4. The timestamp files and check logic remain untouched

---

## 11. Open Questions

1. **Score recomputation window**: 6 beats = ~30 min. For the decision span, should we use the score from the current round's window, or a shorter window (e.g., last 3 beats)?
   - **Tentative**: Use the current round's window (6 beats). The extra history stabilizes the score and prevents flapping. If we need faster reaction, a separate `score_short_window` (3 beats, ~15 min) can be added as a secondary attribute.

2. **Decision span timing**: Should the decision span be a child of `patrol.round` (making the round duration include decision time) or a sibling of `patrol.report` (decision happens outside the patrol round)?
   - **Tentative**: Child of `patrol.round`, after `patrol.heartbeat` and before `patrol.report`. This keeps all patrol-related spans within one trace. The decision latency is measured from anomaly detection to decision, not from patrol start.

3. **Multiple decisions per round**: Can a single patrol round produce multiple decisions? E.g., disk alert + sibling dead → two separate dispatches.
   - **Tentative**: Yes. Multiple `patrol.decision` spans can exist per round, one per decision. Each has its own trigger_type and reference_id. The report span aggregates all anomaly events.

4. **Score in check phase**: Should the reliability score influence check behavior? E.g., skip network check if score < 50 (agent is barely alive, don't waste time on network checks).
   - **Tentative**: Not in v1. Keep checks independent of score. The score is a parallel signal. In v2.1, we may add adaptive check severity based on score.

5. **Boss decision vs automated decision**: The `patrol.decision` span records whatever decision the boss makes. If the boss is automated (a script dispatches a fix), the decision span still gets created with `decision_type: automated_dispatch`. This is unified.

---

## 12. Success Criteria

Patrol v2 is successful when:

1. **Every patrol round produces a trace** with `heartbeat.score*` attributes
2. **Score drops trigger decision spans** within the same trace
3. **Decision latency is queryable** in Grafana with <30s freshness
4. **The unified panel** shows score, status, and decision latency in one view
5. **Alert rules fire correctly** for score < 50 and PDL > 30s
6. **Zero false positives** from the ScoreCritical rule in the first 48h

---

## 13. References

- [OTel Patrol Design](docs/infra/reviews/otel-patrol.md) — base span model and trace pipeline
- [Heartbeat Reliability Scoring](docs/infra/reviews/heartbeat-reliability.md) — scoring formula and journal format
- [Boss Decision Latency](docs/infra/reviews/boss-decision-latency.md) — decision log schema and latency metrics
- [5-Min Patrol Guide](docs/infra/5min-patrol-guide.md) — current patrol system behavior
- [Multi-Cluster Boss Architecture](docs/infra/multi-cluster-boss-architecture.md) — boss dispatch mechanics
- [Hooks to CK Pipeline](docs/infra/handbook/hooks-ck-pipeline.md) — hook event pipeline

---

> ／人◕ ‿‿ ◕人＼
