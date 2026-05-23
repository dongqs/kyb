---
decision: 稍后做
---

# Heartbeat Reliability Scoring

**Author:** Boss
**File:** `docs/infra/reviews/heartbeat-reliability.md`
**Status:** Draft

## 1. Why

The 5-minute patrol system (see `docs/infra/5min-patrol-guide.md`) relies on three parallel agents writing heartbeats every ~5 minutes. Currently the system knows:

- Is a sibling **dead**? (heartbeat >15min old)
- Is a sibling **alive**? (heartbeat <5min old)

But between "alive" and "dead" is a spectrum of **degraded health**:

- Agent missing 1 of every 3 beats (crashed and recovered by cron)
- Agent writing beats consistently late (slow dispatch, overloaded)
- Agent alive but crashing silently every few rounds (memory leak, OTel exporter error)
- Two siblings dying alternately (shared resource contention)

These patterns don't trigger the "sibling dead" alarm but erode overall system reliability. We need a **heartbeat reliability score** that surfaces these slow declines before they become outages.

### What we track

| Signal | What it measures | Why |
|--------|-----------------|-----|
| **Missed beats** | Heartbeats expected but not written | Agent crashed, cron skipped, clock drift |
| **Late beats** | Heartbeats written after deadline | Agent slow, overloaded, resource contention |
| **Sibling health** | Fraction of siblings alive this round | Cluster-wide failure, shared infra problem |
| **Score per patrol** | Composite of above per round | Single number to trend over time |

## 2. Data Model

### 2.1 Enhanced Heartbeat Record

Current file-based heartbeat (`.kyb-diaries/.patrol-{1,2,3}-hb`):

```
2026-05-23T12:00:00Z    # timestamp line
GREEN                   # status line
```

We expand to structured JSON logs appended to a **rotating heartbeat journal** at `.kyb-diaries/hb-journal-{agent_id}.jsonl`. The simple timestamp file is kept for sibling liveness checks; the journal provides the history needed for scoring.

```jsonl
{"t":"2026-05-23T12:00:00Z","seq":142,"status":"ok","round_ms":35000,"latency_seconds":0,"siblings_alive":2,"siblings_total":2}
{"t":"2026-05-23T12:05:10Z","seq":143,"status":"ok","round_ms":45000,"latency_seconds":10,"siblings_alive":1,"siblings_total":2}
{"t":"2026-05-23T12:11:05Z","seq":144,"status":"late","round_ms":62000,"latency_seconds":65,"siblings_alive":1,"siblings_total":2}
{"t":"2026-05-23T12:15:12Z","seq":145,"status":"ok","round_ms":38000,"latency_seconds":0,"siblings_alive":1,"siblings_total":2}
```

| Field | Type | Description |
|-------|------|-------------|
| `t` | ISO8601 timestamp | When heartbeat was written |
| `seq` | int | Monotonic sequence number per agent (resets on journal rotation) |
| `status` | string | `ok` / `late` / `missed` (missed = inferred, never written) |
| `round_ms` | int | Duration of the full patrol round in ms |
| `latency_seconds` | int | How late this beat was (0 = on time) |
| `siblings_alive` | int | Number of siblings alive at this round |
| `siblings_total` | int | Total siblings (always 2 for the 3-agent setup) |
| `prev_beat_delay` | int | Actual seconds since previous beat from same agent |

### 2.2 ClickHouse Tables

For historical analysis and querying, heartbeat records land in ClickHouse via the OTel pipeline (see `docs/infra/reviews/otel-patrol.md`):

```sql
CREATE TABLE otel.heartbeat_log
(
    `timestamp`   DateTime64(3) CODEC(Delta, ZSTD),
    `agent_id`    LowCardinality(String),
    `seq`         UInt32 CODEC(ZSTD),
    `status`      LowCardinality(String),          -- ok / late / missed
    `round_ms`    UInt32,
    `latency_s`   Int32,                            -- -1 for missed
    `siblings_alive` UInt8,
    `siblings_total` UInt8,
    `prev_beat_delay_s` UInt16,
    `score`       UInt8,                            -- computed post-hoc, nullable in raw
    `round_id`    String,                           -- links to patrol.round trace
    `_inserted_at` DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (agent_id, timestamp);
```

Materialized view for per-agent hourly rollup:

```sql
CREATE MATERIALIZED VIEW otel.heartbeat_hourly_mv
ENGINE = AggregatingMergeTree
ORDER BY (agent_id, hour)
AS SELECT
    agent_id,
    toStartOfHour(timestamp) AS hour,
    count(*) AS beats_expected,
    countIf(status = 'ok') AS beats_ok,
    countIf(status = 'late') AS beats_late,
    countIf(status = 'missed') AS beats_missed,
    avgIf(latency_s, status = 'late') AS avg_late_seconds,
    maxIf(latency_s, status = 'late') AS max_late_seconds,
    avg(prev_beat_delay_s) AS avg_beat_interval,
    avg(siblings_alive) AS avg_siblings_alive,
    min(score) AS min_score,
    avg(score) AS avg_score
FROM otel.heartbeat_log
GROUP BY agent_id, hour;
```

### 2.3 Patrol Reliability Score Table

Denormalized score per patrol round — one row per `patrol.round` trace:

```sql
CREATE TABLE otel.patrol_reliability
(
    `round_id`            String,                    -- FK to patrol.round
    `timestamp`           DateTime64(3),
    `agent_id`            LowCardinality(String),
    `round_number`        UInt8,                     -- 1, 2, or 3
    `score`               UInt8,                     -- 0-100
    `score_missed`        UInt8,                     -- sub-score for missed beats
    `score_late`          UInt8,                     -- sub-score for late beats
    `score_sibling`       UInt8,                     -- sub-score for sibling health
    `missed_count`        UInt8,                     -- beats missed in window
    `late_count`          UInt8,                     -- beats late in window
    `late_max_seconds`    UInt16,                    -- worst lateness in window
    `siblings_alive`      UInt8,
    `siblings_total`      UInt8,
    `tier`                LowCardinality(String),    -- healthy/degraded/unstable/critical
    `_inserted_at`        DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (agent_id, timestamp);
```

## 3. Scoring Formula

### 3.1 Scoring Window

Each patrol round scores based on the last **N beats** (configurable, default N=6 = ~30 min history for a 5-min interval). This gives a rolling window that reacts quickly to degradation without being noisy on single misses.

For agents with fewer than N beats of history (startup, journal rotation), use all available beats and treat missing beats as neutral.

### 3.2 Raw Counts

From the scoring window (last N heartbeats, including the current one):

| Metric | Definition |
|--------|-----------|
| `expected_beats` | `N` (window size) or `count(beats)` if < N history |
| `missed_beats` | `expected_beats - count(beats_with_timestamp)` in the window |
| `late_beats` | `count(beats WHERE latency_s > DEADLINE)` where DEADLINE = 30s |
| `siblings_alive` | `count(alive_siblings_at_check_time)` out of `siblings_total` |

### 3.3 Score Components

Each component is scored 0-100. A higher score is better.

#### Missed Beat Score

```
missed_ratio = missed_beats / expected_beats

score_missed = round(100 * (1 - missed_ratio)^2)
```

Quadratic penalty: a single miss (1/6) = 69, two misses (2/6) = 44, three misses = 25.

| Missed | Score |
|--------|-------|
| 0/6    | 100   |
| 1/6    | 69    |
| 2/6    | 44    |
| 3/6    | 25    |
| 4/6    | 11    |
| 5/6    | 3     |
| 6/6    | 0     |

Rationale: a single intermittent miss is tolerable (agent crashed and cron restarted it), but >2/6 indicates a systemic problem.

#### Late Beat Score

```
late_ratio = late_beats / expected_beats
max_late_weight = min(late_max_seconds / 300, 1)    -- 5 min = full penalty

score_late = round(100 * (1 - late_ratio) * (1 - 0.5 * max_late_weight))
```

Penalty scales with both frequency and severity. A beat 10 minutes late is worse than one 30s late.

| Scenario | late_ratio | max_late_weight | score_late |
|----------|-----------|-----------------|------------|
| All on time | 0 | 0 | 100 |
| 1/6 beat 30s late | 0.17 | 0.1 | 74 |
| 1/6 beat 5min late | 0.17 | 1.0 | 42 |
| 3/6 beats 2min late | 0.5 | 0.4 | 30 |

#### Sibling Health Score

```
sibling_ratio = siblings_alive / siblings_total

score_sibling = round(100 * sibling_ratio)
```

Simple linear score: all alive = 100, one dead = 50, both dead = 0.

#### Composite Score

```
score = round(
    0.50 * score_missed +
    0.25 * score_late +
    0.25 * score_sibling
)
```

Weights reflect relative severity: missing a beat is worse than being late (you might actually be dead), and sibling health is a leading indicator of cluster-wide problems.

| Component | Weight | Rationale |
|-----------|--------|-----------|
| Missed beats | 50% | Most direct signal of agent death |
| Late beats | 25% | Performance degradation, early warning |
| Sibling health | 25% | Cluster / shared-infra problems |

### 3.4 Reliability Tiers

| Score | Tier | Meaning | Action |
|-------|------|---------|--------|
| 90-100 | `healthy` | Normal operation | None |
| 70-89 | `degraded` | Intermittent issues, likely transient | Log, no alert |
| 50-69 | `unstable` | Consistent problems, needs investigation | P3 alert, diary entry |
| 0-49 | `critical` | Agent near death or cluster failing | P1 alert, feishu notification |

### 3.5 Examples

**Healthy agent, steady state:**
- Expected beats: 6, Missed: 0, Late: 0, Siblings: 2/2
- `score_missed=100`, `score_late=100`, `score_sibling=100`
- **Final: 100** -- tier `healthy`

**Agent with 1 crash-recovery in window:**
- Expected: 6, Missed: 1, Late: 0, Siblings: 2/2
- `score_missed=69`, `score_late=100`, `score_sibling=100`
- **Final: 84** -- tier `degraded`

**Agent chronically slow (every beat late by 2min):**
- Expected: 6, Missed: 0, Late: 6, Max late: 120s, Siblings: 2/2
- `score_missed=100`, `score_late=round(100*0*0.8)=0`, `score_sibling=100`
- Wait, that's too harsh. Let me recalculate.

For all 6 beats late with max_late=120s:
- `late_ratio = 6/6 = 1`
- `max_late_weight = min(120/300, 1) = 0.4`
- `score_late = 100 * (1-1) * (1-0.5*0.4) = 100 * 0 * 0.8 = 0`

That is indeed the correct behavior: consistently missing every deadline means the agent is systematically slow and should be flagged.

- **Final: 50** -- tier `unstable`

**One sibling dead for full window:**
- Expected: 6, Missed: 0, Late: 0, Siblings: 1/2
- `score_missed=100`, `score_late=100`, `score_sibling=50`
- **Final: 87** -- tier `degraded`

**Cluster-wide failure (both siblings dead, self barely alive):**
- Expected: 6, Missed: 3, Late: 2, Max late: 300s, Siblings: 0/2
- `score_missed=25`, `score_late=0`, `score_sibling=0`
- **Final: 13** -- tier `critical`

## 4. Computation

### 4.1 Live Computation (during patrol round)

Each patrol round computes its own score as a shell function:

```bash
# ~/.kyb/bin/hb-score
# Reads hb-journal, computes score, writes to patrol_reliability CK table

JOURNAL="$HOME/.kyb-diaries/hb-journal-${AGENT_ID}.jsonl"
WINDOW=${HB_SCORE_WINDOW:-6}

# Count expected vs actual in window
EXPECTED=$WINDOW
ACTUAL=$(tail -n "$WINDOW" "$JOURNAL" 2>/dev/null | wc -l)
MISSED=$(( EXPECTED - ACTUAL ))

# Count late beats (latency_seconds > 30)
LATE=$(tail -n "$WINDOW" "$JOURNAL" 2>/dev/null | \
  awk -F'"' '{for(i=1;i<=NF;i++) if($i ~ /latency_seconds/) {n=substr($(i+1),2); if(n+0>30) c++}} END {print c+0}')
MAX_LATE=$(tail -n "$WINDOW" "$JOURNAL" 2>/dev/null | \
  awk -F'"' '{for(i=1;i<=NF;i++) if($i ~ /latency_seconds/) {n=substr($(i+1),2); if(n+0>m) m=n+0}} END {print m+0}')

# Sibling counts from latest beat
SIBLINGS_ALIVE=$(tail -1 "$JOURNAL" 2>/dev/null | \
  awk -F'"' '{for(i=1;i<=NF;i++) if($i ~ /siblings_alive/) print $(i+1)+0}')
SIBLINGS_TOTAL=$(tail -1 "$JOURNAL" 2>/dev/null | \
  awk -F'"' '{for(i=1;i<=NF;i++) if($i ~ /siblings_total/) print $(i+1)+0}')

# Compute component scores (awk for floating point)
SCORE=$(awk -v e="$EXPECTED" -v m="$MISSED" -v l="$LATE" -v ml="$MAX_LATE" \
  -v sa="$SIBLINGS_ALIVE" -v st="$SIBLINGS_TOTAL" '
  BEGIN {
    # safety div by zero
    if (e == 0) e = 1
    if (st == 0) st = 1

    # missed score: quadratic
    missed_ratio = m / e
    score_missed = 100 * (1 - missed_ratio) ^ 2

    # late score: frequency * severity
    late_ratio = l / e
    max_late_w = (ml > 300 ? 1 : ml / 300)
    score_late = 100 * (1 - late_ratio) * (1 - 0.5 * max_late_w)
    if (score_late < 0) score_late = 0

    # sibling score: linear
    score_sibling = 100 * sa / st

    # composite
    score = 0.5 * score_missed + 0.25 * score_late + 0.25 * score_sibling
    printf "%d\n%d\n%d\n%d\n%.1f\n", score_missed, score_late, score_sibling, score, score
  }')

# Parse score
SCORE=$(echo "$SCORE" | tail -1 | cut -d. -f1)

# Determine tier
if [ "$SCORE" -ge 90 ]; then TIER="healthy"
elif [ "$SCORE" -ge 70 ]; then TIER="degraded"
elif [ "$SCORE" -ge 50 ]; then TIER="unstable"
else TIER="critical"
fi

# Write to CK (via clickhouse-client)
clickhouse-client --query "
  INSERT INTO otel.patrol_reliability
  (round_id, timestamp, agent_id, round_number, score, tier, ...)
  FORMAT TabSeparated
  ...
"
```

This runs as step 3.5 of the patrol round, after heartbeat write and before report.

### 4.2 Batch Backfill (every 1h)

For historical consistency and to catch races (two patrols writing simultaneously), a cron job recomputes scores for the last hour:

```bash
# ~/.kyb/bin/hb-score-backfill
# Recompute scores for last 2 hours where score is NULL in patrol_reliability

clickhouse-client --query "
  INSERT INTO otel.patrol_reliability
  SELECT
    round_id, timestamp, agent_id, round_number,
    compute_score(missed_count, late_count, late_max_seconds, siblings_alive, siblings_total) AS score,
    ...
  FROM otel.heartbeat_log
  WHERE timestamp > now() - INTERVAL 2 HOUR
    AND score IS NULL
  "
```

### 4.3 Incremental Score Over Time

The score is stored per-round but also rolled up:

**Per-agent hourly rollup** (via `otel.heartbeat_hourly_mv`):

| agent_id | hour | avg_score | min_score | beats_missed | beats_late |
|----------|------|-----------|-----------|-------------|------------|
| boss-1 | 12:00 | 97 | 84 | 1 | 0 |
| boss-1 | 13:00 | 72 | 50 | 4 | 3 |
| boss-2 | 12:00 | 100 | 100 | 0 | 0 |

**Per-cluster hourly rollup** (average of all agents):

| hour | avg_score | min_score | agents_degraded | agents_unstable | agents_critical |
|------|-----------|-----------|----------------|----------------|-----------------|
| 12:00 | 99 | 97 | 0 | 0 | 0 |
| 13:00 | 74 | 50 | 1 | 1 | 0 |

## 5. Grafana Dashboard

### 5.1 Score Overview Panel

```
Time series: patrol_reliability{agent_id=~"boss-.*"}
  - One line per agent (boss-1, boss-2, boss-3)
  - Y-axis: 0-100
  - Threshold lines at 90 (healthy/degraded), 70 (degraded/unstable), 50 (unstable/critical)
  - Color: green (healthy), yellow (degraded), orange (unstable), red (critical)
```

PromQL:

```promql
# Per-agent score over time
avg by (agent_id) (patrol_reliability_score)

# Cluster average
avg(patrol_reliability_score)
```

### 5.2 Component Breakdown Panel

```
Stacked bar: score_missed, score_late, score_sibling per agent per hour
  - Shows which dimension is dragging the score down
  - Easy to see "this agent is missing beats" vs "sibling is dead"
```

### 5.3 Missed/Late Heatmap

```
Heatmap: agent_id x hour, cell = count(missed + late)
  - Quick scan for temporal patterns
  - E.g., agent consistently misses beats around :00-:05 every hour
```

### 5.4 Reliability Tier Distribution

```
Pie chart or stacked area:
  - healthy / degraded / unstable / critical
  - Per hour, shows how much of the time the system was in each tier
```

## 6. Alerting Rules

Based on the reliability score, complementing the existing OTel patrol alerts:

| Rule | Expression | Level | Description |
|------|-----------|-------|-------------|
| ScoreCritical | `patrol_reliability_score < 50` | P1 | Single agent critically unreliable |
| ScoreUnstable | `patrol_reliability_score < 70` | P2 | Agent or cluster unstable |
| ScoreDropping | `deriv(patrol_reliability_score[30m]) < -10` | P2 | Score dropping >10 per 30min (trend alert) |
| ClusterUnstable | `avg(patrol_reliability_score) < 70` | P1 | Cluster-wide reliability crisis |
| NoScoreData | `absent(patrol_reliability_score[10m])` | P1 | No scoring data at all (scoring itself may be dead) |

### Alert fatigue prevention

- **Escalation delay**: ScoreCritical fires only after 2 consecutive rounds scoring <50 (configurable via `score_critical_window: 2`).
- **Silence during known maintenance**: Check a maintenance window flag file (`.kyb-diaries/.maintenance-mode`) before firing.
- **Tier transitions only**: Alert on transition to `critical` or `unstable`, not on every data point. Grafana `on` / `for: 5m` handles this.

## 7. Integration with Existing Patrol Flow

The scoring step fits into the existing patrol pipeline as follows:

```
patrol.round (root span)
├── patrol.dispatch
├── patrol.check
│   ├── patrol.check.docker
│   ├── patrol.check.disk
│   ├── patrol.check.network
│   └── patrol.check.health
├── patrol.heartbeat
│   ├── Write own heartbeat + journal entry   ← enhanced
│   ├── Check siblings                         ← existing
│   └── Compute reliability score              ← NEW (step 3.5)
├── patrol.report
│   ├── Include score + tier in anomaly report ← enhanced
│   └── Score < 70 triggers non-silent report  ← enhanced
```

### Changes to the heartbeat span

Extend the `patrol.heartbeat` span attributes (from `otel-patrol.md`):

| Attribute | Type | Description |
|-----------|------|-------------|
| `heartbeat.score` | int | Computed reliability score 0-100 |
| `heartbeat.score_tier` | string | `healthy`/`degraded`/`unstable`/`critical` |
| `heartbeat.score_missed` | int | Missed beat component score |
| `heartbeat.score_late` | int | Late beat component score |
| `heartbeat.score_sibling` | int | Sibling health component score |
| `heartbeat.window_beats` | int | Number of beats in scoring window |

### Changes to the report

When score < 70 (`unstable`), the report severity escalates:

| Score | Report severity | Notification |
|-------|----------------|-------------|
| 90-100 | `info` | Silent (diary only) |
| 70-89 | `info` | Silent (diary only) |
| 50-69 | `warning` | Feishu, non-urgent |
| 0-49 | `critical` | Feishu, urgent ping |

## 8. Implementation Plan

### Phase 1: Heartbeat Journal (0.5 day)

- [ ] Define JSONL format for `.kyb-diaries/hb-journal-{agent_id}.jsonl`
- [ ] Modify patrol prompts to write journal entry after heartbeat file
- [ ] Add journal rotation (keep last 100 entries, ~8h history)
- [ ] Keep simple timestamp file for backwards-compatible sibling checks

### Phase 2: CK Schema (0.5 day)

- [ ] Deploy `otel.heartbeat_log` table
- [ ] Deploy `otel.heartbeat_hourly_mv` materialized view
- [ ] Deploy `otel.patrol_reliability` table
- [ ] Create `compute_score()` UDF or inline SQL

### Phase 3: Scoring Script (0.5 day)

- [ ] Write `~/.kyb/bin/hb-score` with shell + awk implementation
- [ ] Write `~/.kyb/bin/hb-score-backfill` cron job (every 1h)
- [ ] Integration test: simulate 10 rounds, verify scores

### Phase 4: Alerting + Dashboard (0.5 day)

- [ ] Add Prometheus recording rules for reliability metrics
- [ ] Deploy Grafana panels per Section 5
- [ ] Deploy alert rules per Section 6
- [ ] Test alert triggering with degraded scenario

### Phase 5: Tuning (ongoing)

- [ ] Validate score against real patrol data for 48h
- [ ] Adjust weights if false positive rate > 5%
- [ ] Add agent-specific baselines (some agents naturally slower)
- [ ] Consider ML-based anomaly detection on score_trend if useful

## 9. Fallbacks

| Scenario | Fallback |
|----------|----------|
| Journal file corrupted | Fall back to `score=0` (critical) and rotate journal |
| CK unavailable | Compute score in shell, cache to `.kyb-diaries/.last-score`, retry insert next round |
| Clock drift between siblings | Use monotonic clock (`CLOCK_MONOTONIC`) for interval delta, only use wall clock for display |
| Agent startup with no history | First 6 rounds: score based on available beats (no missed-beat penalty for missing window) |

## 10. Open Questions

1. **Window size**: 6 beats (~30 min) is a guess. Should we use a time-based window (30 min) instead of count-based (6 beats)?
   - Time-based is more intuitive. But count-based behaves consistently regardless of patrol interval changes.
   - **Decision (tentative)**: Use both. Calculate score with window = max(6 beats, 30 min). This ensures enough data points even if patrol interval drops below 5 min, and avoids stale data if interval increases.

2. **Score smoothing**: Raw score bounces between 84 (1 miss in window) and 100 (no miss). Should we EMA-smooth?
   - **Decision (tentative)**: No. Keep raw score. Alerts use `for: 5m` to avoid flapping. The raw score is more useful for debugging. An EMA-smoothed `score_trend` can be a separate Grafana query.

3. **Self-healing integration**: Should `score < 50` trigger automatic restart of the agent?
   - **Decision (tentative)**: Not in v1. Too risky. First prove the score correlates with real problems. Restart is a separate control loop.

4. **Weight tuning**: The 50/25/25 split is a starting guess. What's the acceptable false-positive rate?
   - **Decision (tentative)**: Ship with these weights. Review after 48h of real data. If >5% false positive at `unstable` threshold, reduce late_beat weight.
