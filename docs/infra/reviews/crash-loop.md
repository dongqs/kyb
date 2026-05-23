---
decision: 稍后做
---

# Design: Container Crash Loop Detection

**Design doc**: `docs/infra/reviews/crash-loop.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Real-time crash loop detection from Docker events stream, alerting, Grafana visualization

---

## Summary

The Docker event watcher (designed in `docker-events.md`) captures every container crash, restart, and health transition. However, raw events alone do not answer the question: "is this container crash-looping?" A crash loop is a temporal pattern -- N restarts within T minutes -- not a single event. This design adds a detection layer that consumes the Docker event stream, maintains per-container restart windows, and generates structured crash loop alerts.

Three detection tiers are proposed:

1. **Instant** -- container dies and restarts >= 3 times in 5 minutes (P1)
2. **Fast** -- >= 5 restarts in 30 minutes (P2, possible resource leak)
3. **Slow** -- >= 10 restarts in 24 hours (P3, chronic instability)

These tiers run on every boss cluster and write results to a dedicated ClickHouse table, feeding both Grafana dashboards and Feishu alerts.

---

## Architecture

### Data Flow

```
Docker Engine (per-cluster)
    │  (docker-event-watcher -> infra.docker_events)
    ▼
crash-loop-detector (daemon or cron inside kyb-infra-boss)
    │  reads infra.docker_events via ClickHouse SQL
    │  or maintains in-memory sliding windows
    ▼
Detection:
    ├── Instant (3x/5min) → P1 alert
    ├── Fast   (5x/30min) → P2 alert
    └── Slow   (10x/24h)  → P3 alert
    │
    ├── Write alert to infra.crash_loops (ClickHouse)
    ├── Emit Feishu notification via webhook
    └── Expose metrics for Grafana: /metrics endpoint
```

### Two Implementation Approaches

**Approach A: SQL-only (simpler, stateless).** The patrol script runs a ClickHouse query every 5 minutes over the `infra.docker_events` table. No new daemon, no state to manage. Drawback: the time window is always measured from `now()`, so an alert fires as long as N deaths exist in the trailing window -- it keeps firing if the crash loop persists.

**Approach B: Sliding-window daemon (stateful, precise).** A lightweight daemon consumes the Docker event stream in real time via `docker events --filter 'event=die'` and maintains per-container sliding windows in memory. Alerts fire once when a threshold is crossed and suppress until the window slides past. This is more accurate but requires a running process.

**Recommended**: Approach A for initial deployment (zero infrastructure, 20 lines of SQL in the existing patrol), then upgrade to Approach B when false-positive suppression needs arise.

---

## Detection Algorithm

### Approach A: SQL Detection

The patrol (running every 5 minutes) executes:

```sql
-- Tier 1: Instant crash loop (3+ deaths in 5 min)
INSERT INTO infra.crash_loops
SELECT
    now() AS detected_at,
    cluster,
    container_name,
    'instant' AS tier,
    count() AS crash_count,
    min(event_time) AS window_start,
    max(event_time) AS window_end,
    0 AS resolved
FROM infra.docker_events
WHERE event_type = 'container:die'
  AND exit_code > 0
  AND event_time >= now() - INTERVAL 5 MINUTE
GROUP BY cluster, container_name
HAVING crash_count >= 3;

-- Tier 2: Fast crash loop (5+ deaths in 30 min)
INSERT INTO infra.crash_loops
SELECT ... WHERE event_time >= now() - INTERVAL 30 MINUTE
GROUP BY ... HAVING crash_count >= 5;

-- Tier 3: Slow crash loop (10+ deaths in 24h)
INSERT INTO infra.crash_loops
SELECT ... WHERE event_time >= now() - INTERVAL 24 HOUR
GROUP BY ... HAVING crash_count >= 10;
```

**Key property**: These queries are idempotent -- running them repeatedly produces the same result as long as the event data is unchanged. The `infra.crash_loops` table uses a `ReplacingMergeTree` engine so duplicate alerts are collapsed.

### Approach B: Sliding-Window State Machine (future)

```
Container "kyb-infra-clickhouse"
  Window: [t-5min, t]   ← deque of (event_time, exit_code)
  State:  OK | CRASH_LOOP_INSTANT | CRASH_LOOP_FAST | CRASH_LOOP_SLOW
  Alert sent: false (toggled true on first send, reset when window slides under threshold)
  Last notified: 2026-05-23T10:00:00Z

On each die event:
  push(t, exit_code)
  evict events older than max_window (24h)
  recompute state from deque length at each tier
  if state transitions (e.g. OK → CRASH_LOOP_INSTANT):
    send alert, mark alert_sent = true
  if state transitions back (e.g. CRASH_LOOP_INSTANT → OK):
    send recovery, mark alert_sent = false
```

This avoids re-alerting on every patrol cycle. The daemon tracks "have we already alerted for this crash loop episode?" and only fires on transitions.

---

## ClickHouse Schema

### Alert Events Table

```sql
CREATE TABLE infra.crash_loops (
    -- When the detection fired
    detected_at     DateTime64(3),
    cluster         LowCardinality(String),
    container_name  String,
    tier            Enum8('instant' = 1, 'fast' = 2, 'slow' = 3),

    -- Detection window
    crash_count     UInt16,
    window_start    DateTime64(3),
    window_end      DateTime64(3),

    -- Last known exit code (mode or max)
    last_exit_code  UInt16 DEFAULT 0,
    last_image      String DEFAULT '',

    -- Resolution tracking
    resolved        UInt8 DEFAULT 0,    -- 0 = active, 1 = resolved
    resolved_at     DateTime64(3) DEFAULT 0,

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(detected_at)
ORDER BY (tier, cluster, container_name, detected_at);
```

**Design notes**:

1. **ReplacingMergeTree** deduplicates alerts that fire repeatedly for the same crash loop session. The `detected_at` ordering ensures the most recent detection wins.
2. **No TTL needed** -- crash loop events are rare (target: < 1/day per cluster). Keep indefinitely for trend analysis.
3. **`tier` is part of the sort key** because queries always filter by tier (`WHERE tier = 'instant'`).

### Resolution Tracking

An alert is considered "resolved" when the container has been stable (no die events) for at least 2x the detection window:

```sql
-- Mark resolved: instant crash loop with no deaths in 10 minutes
ALTER TABLE infra.crash_loops
UPDATE resolved = 1, resolved_at = now()
WHERE tier = 'instant'
  AND resolved = 0
  AND detected_at > now() - INTERVAL 1 HOUR
  AND container_name NOT IN (
      SELECT container_name
      FROM infra.docker_events
      WHERE event_type = 'container:die'
        AND exit_code > 0
        AND event_time >= now() - INTERVAL 10 MINUTE
  );
```

Resolution runs on the same patrol cycle (every 5 min).

### Detection Metadata Table

For observability into the detector itself:

```sql
CREATE TABLE infra.detector_heartbeats (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    checked_at      DateTime64(3),
    windows_tracked UInt16,           -- number of containers with active windows
    alerts_active   UInt8,            -- number of unresolved alerts
    mode            LowCardinality(String),  -- 'sql' or 'daemon'
    duration_ms     UInt16,           -- how long the detection cycle took
    error           String DEFAULT ''
) ENGINE = MergeTree
ORDER BY (cluster, checked_at)
TTL toDate(checked_at) + INTERVAL 7 DAY;
```

This answers "is the detector working?" -- a Grafana alert fires if no heartbeat from a cluster in > 10 minutes.

---

## Grafana Dashboard: Crash Loops

### Panel 1: Active Crash Loops (Table)

```
+------------------+---------+-------+-------------+---------------------+---------------------+
| Container        | Cluster | Tier  | Crashes (n) | First Crash         | Last Crash          |
+------------------+---------+-------+-------------+---------------------+---------------------+
| kyb-infra-redis  | mac     | fast  | 7           | 2026-05-23T09:15:00 | 2026-05-23T09:42:00 |
| kyb-infra-boss3  | aliyun  | slow  | 11          | 2026-05-22T14:00:00 | 2026-05-23T08:30:00 |
+------------------+---------+-------+-------------+---------------------+---------------------+
```

Query:
```sql
SELECT container_name, cluster, tier, crash_count,
       window_start AS first_crash, window_end AS last_crash
FROM infra.crash_loops
WHERE resolved = 0
ORDER BY tier ASC, crash_count DESC;
```

### Panel 2: Crash Loop Timeline (Time Series)

Stacked bar chart showing crash count per container over time (last 24h). Each bar = one patrol cycle's detection result. Color by tier (red = instant, yellow = fast, blue = slow).

```sql
SELECT toStartOfInterval(detected_at, INTERVAL 5 MINUTE) AS t,
       container_name,
       sum(crash_count) AS total_crashes
FROM infra.crash_loops
WHERE detected_at >= now() - INTERVAL 24 HOUR
GROUP BY t, container_name
ORDER BY t;
```

### Panel 3: Crash Frequency by Container (Bar Chart)

Total resolved + active crash loop incidents per container (last 7 days). Identifies chronically unstable containers.

```sql
SELECT container_name, tier, count() AS incidents
FROM infra.crash_loops
WHERE detected_at >= now() - INTERVAL 7 DAY
GROUP BY container_name, tier
ORDER BY incidents DESC
LIMIT 20;
```

### Panel 4: Detector Health (Stat)

- **Last detection cycle**: `max(checked_at)` from `infra.detector_heartbeats`
- **Active windows**: `sum(windows_tracked)` -- number of containers currently in a crash window
- **Unresolved alerts**: `sum(alerts_active)` -- current P1+P2+P3 burden
- **Detection latency**: `avg(duration_ms)` -- should be < 500ms for SQL mode

### Panel 5: Time-to-Resolve (Histogram)

For resolved alerts only: how long did the crash loop last from first detection to resolution?

```sql
SELECT floor(dateDiff('minute', detected_at, resolved_at) / 5) * 5 AS bucket_min,
       count() AS incidents
FROM infra.crash_loops
WHERE resolved = 1
  AND resolved_at > 0
GROUP BY bucket_min
ORDER BY bucket_min;
```

---

## Alert Rules

### Feishu Alert Format

All alerts send to the infra Feishu group via webhook:

```json
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {"tag": "plain_text", "content": "CRASH LOOP: ${container} on ${cluster}"},
      "template": "${color}"   // red / yellow / blue
    },
    "elements": [
      {"tag": "div", "text": {"tag": "lark_md", "content": "**Tier**: ${tier}\n**Crashes**: ${crash_count} in window\n**Window**: ${window_start} → ${window_end}\n**Last exit code**: ${exit_code}"}},
      {"tag": "action", "actions": [
        {"tag": "button", "text": {"tag": "plain_text", "content": "View in Grafana"}, "url": "${grafana_url}"},
        {"tag": "button", "text": {"tag": "plain_text", "content": "SSH to cluster"}, "url": "${ssh_url}"}
      ]}
    ]
  }
}
```

### Alert Rules Matrix

| Tier | Condition | Severity | Color | Response | Suppression |
|------|-----------|----------|-------|----------|-------------|
| Instant | >= 3 die events in 5 min | P1 | Red | Feishu alert immediately. Triggers patrol intervention: SSH to cluster, inspect `docker logs`, check OOM scores. | Auto-resolve after 10 min of no crashes. Re-alert if another crash loop starts within 1 hour (not a new episode). |
| Fast | >= 5 die events in 30 min | P2 | Yellow | Feishu alert. Less urgent but needs investigation within the hour. Possible causes: resource pressure, config reload loop, dependency unavailable. | Auto-resolve after 60 min of no crashes. |
| Slow | >= 10 die events in 24 h | P3 | Blue | Feishu daily digest (or immediate if no other alerts in 24h). Indicates chronic instability. Container should be deprioritized for replacement. | Auto-resolve after 48h of no crashes. |

### Alert Cooldown and Throttling

To prevent alert fatigue:

1. **Same-tier cooldown**: After an Instant alert fires for container X, do not re-alert for the same container+tier for 30 minutes (unless the crash count exceeded the previous window by 2x).
2. **Escalation**: If a container has been in Fast crash loop for > 2 hours, escalate to P1 (it's effectively Instant, just slower).
3. **Silence during maintenance**: If the `infra.maintenance_windows` table has an active maintenance entry for the cluster, suppress all crash loop alerts.
4. **Container-level snooze**: A `--snooze` flag or CK mutation can silence alerts for a specific container for N hours (useful during known-bad deploys).

```sql
-- Maintenance window check (used in patrol to skip alerting)
SELECT count() AS active
FROM infra.maintenance_windows
WHERE cluster = '${CLUSTER}'
  AND now() BETWEEN starts_at AND ends_at
  AND active = 1;
```

---

## Detection Edge Cases

### 1. Init Container Crashes

Containers with `--init` (the recent fix from commit `c1dff06`) start an init process (tini/dumb-init) as PID 1. If the init process crashes, Docker reports `die` with exit code 1 or 137 (SIGKILL). These are valid crash loop events and should be detected normally.

However, if the init process reaps zombies correctly, the application process crash may NOT cause a container restart -- only the application's exit triggers the restart policy. The detector only sees container-level `die` events, not process-level exits. This is correct behavior: we monitor container restarts, not process restarts.

### 2. One-off Restarts vs Crash Loops

A single `die`+`start` pair within 5 minutes is NOT a crash loop. The threshold of 3 ensures transient restarts (e.g., config reload requiring a restart) do not trigger P1 alerts.

Edge: A container that restarts exactly 2 times in 5 minutes (just under the threshold) and then stops. This is a "near miss" -- the patrol should log near misses to a separate table for analysis:

```sql
CREATE TABLE infra.near_misses (
    detected_at     DateTime64(3),
    cluster         LowCardinality(String),
    container_name  String,
    crash_count     UInt8,   -- 1 or 2
    window_minutes  UInt8,
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detected_at, cluster)
TTL toDate(detected_at) + INTERVAL 7 DAY;
```

Query:
```sql
INSERT INTO infra.near_misses
SELECT now(), cluster, container_name, count() AS crash_count, 5
FROM infra.docker_events
WHERE event_type = 'container:die'
  AND exit_code > 0
  AND event_time >= now() - INTERVAL 5 MINUTE
GROUP BY cluster, container_name
HAVING crash_count IN (1, 2);
```

### 3. Graceful Stops (exit code 0)

Container `die` events with `exit_code = 0` are intentional stops (docker stop, graceful shutdown). They must NOT count toward crash loop detection. The SQL queries already filter `exit_code > 0`.

Edge: Some applications exit 0 on SIGTERM and restart immediately (e.g., `--restart=always`). This looks like a fast restart loop but is actually intentional. Mitigation: if a container has >= 3 restarts in 5 minutes with exit code 0, log a warning but do not alert P1 -- these are likely restarts, not crashes.

### 4. Multiple Clusters, Same Container Name

Container names are unique per cluster but not globally. The detection key is `(cluster, container_name)`. The `infra.crash_loops` sort key includes both. Grafana dashboards group by this composite key.

### 5. Detector Itself Crashing

The crash loop detector must survive its own crashes. Approach A (SQL patrol) inherently survives -- the patrol script is PID 1 or managed by `--restart=unless-stopped`. If the patrol fails one cycle, the next cycle picks up the full window again.

For Approach B (daemon), add:
- `--restart=unless-stopped` to the daemon container
- Heartbeat table writes every cycle (if missing for 2 cycles, alert that the detector is down)
- In-memory window persisted to disk every 5 minutes (crash recovery)

---

## Grafana Dashboard Layout

```
Row: "Crash Loop Overview"
  ├── Stat: Active Crash Loops (current, gauge: green=0, yellow=1-2, red=3+)
  ├── Stat: Instant (P1) Count (current, gauge: green=0, red>0)
  ├── Stat: Fast (P2) Count (current, gauge: green=0, yellow=1-2, red=3+)
  └── Stat: Slow (P3) Count (current, gauge: green 0-2, yellow 3-5, red 5+)

Row: "Active Alerts"
  └── Table: unresolved crash loops (Panel 1 query)

Row: "Crash Loop History"
  ├── Time Series: Crash incidents per tier (last 7d, stacked bar)
  ├── Bar Chart: Crash frequency by container (last 7d, Panel 3 query)
  └── Histogram: Time-to-Resolve distribution (Panel 5 query)

Row: "Near Misses"
  ├── Table: Recent near misses (last 24h, container, cluster, crash_count)
  └── Time Series: Near miss rate (per hour, last 7d)

Row: "Detector Health"
  ├── Stat: Last detection cycle (Panel 4 query)
  ├── Stat: Detection latency (p95 ms)
  └── Stat: Clusters reporting (healthy / total)
```

---

## Integration Points

### With docker-events.md (existing)

The crash loop detector depends on `infra.docker_events` being populated. The dependency graph:

```
docker-event-watcher (docker-events.md)
    → infra.docker_events table
        → crash-loop-detector (this doc)
            → infra.crash_loops table
                → Grafana dashboards + Feishu alerts
```

If `infra.docker_events` has no data, the crash loop detector produces no results. The detector heartbeat table (`infra.detector_heartbeats`) includes an error column that captures "no events in the last 5 minutes" as a warning.

### With Patrol (existing 5-min cycle)

The patrol script should call the crash loop detection as a step:

```bash
# Inside patrol script, after docker-event-watcher health check:
echo "  [PATROL] Running crash loop detection..."

# Run SQL detection (Approach A)
detection_result=$(docker exec kyb-infra-boss bash -c "
  curl -s -X POST 'http://host.docker.internal:8123/' \
    -d '$(cat /usr/local/bin/crash-loop-detection.sql)'
")

# Check for active alerts
active_alerts=$(echo "$detection_result" | grep -c 'instant\|fast')
if [ "$active_alerts" -gt 0 ]; then
  echo "  [PATROL] WARNING: $active_alerts active crash loop alert(s)"
  # Send Feishu notification
  /usr/local/bin/feishu-alert.sh "$detection_result"
fi

# Write heartbeat
curl -s -X POST 'http://host.docker.internal:8123/' \
  -d "INSERT INTO infra.detector_heartbeats FORMAT JSONEachRow" \
  -d "{\"boss_id\":\"$(hostname)\",\"cluster\":\"${CLUSTER}\",\"checked_at\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"windows_tracked\":0,\"alerts_active\":$active_alerts,\"mode\":\"sql\",\"duration_ms\":$duration}"
```

### With Feishu Alerting

Two channels:

1. **Immediate (P1/P2)**: The patrol cycle sends a Feishu card via webhook as soon as a crash loop is detected.
2. **Daily Digest (P3)**: A separate daily cron job queries `infra.crash_loops WHERE resolved = 0 AND tier = 'slow'` and sends a summary card each morning.

Feishu webhook endpoint (set per-cluster):

```bash
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-https://open.feishu.cn/open-apis/bot/v2/hook/xxx}"
```

### With Grafana Alerting

Grafana can query `infra.crash_loops` directly via the ClickHouse data source. Set up alert rules:

- **ActiveCrashLoops**: `countIf(resolved = 0 AND tier = 'instant') > 0` → P1
- **ActiveFastLoops**: `countIf(resolved = 0 AND tier = 'fast') > 0` → P2
- **ActiveSlowLoops**: `countIf(resolved = 0 AND tier = 'slow') > 0` → P3
- **DetectorDown**: `max(detector_heartbeats.checked_at) < now() - INTERVAL 10 MINUTE` → P1

---

## Implementation Plan

### Phase 1: SQL Detection (Approach A) — < 1 hour

1. Create `infra.crash_loops` and `infra.detector_heartbeats` tables on central ClickHouse.
2. Create `infra.near_misses` table for edge case tracking (TTL 7 days).
3. Write the three-tier detection SQL as a single file `/usr/local/bin/crash-loop-detection.sql`.
4. Add crash loop detection step to the existing patrol script (idempotent, runs every 5 min).
5. Add Feishu alert webhook call on P1/P2 detection.
6. Add detector heartbeat write to the patrol cycle.

### Phase 2: Grafana — < 2 hours

1. Build the Grafana dashboard (layout above) connected to `infra.crash_loops`.
2. Configure Grafana alert rules (ActiveCrashLoops, ActiveFastLoops, DetectorDown).
3. Test with synthetic data (INSERT a mock crash loop record).
4. Verify Feishu alert fires correctly from both patrol and Grafana paths.

### Phase 3: Resolution Tracking — < 1 hour

1. Add resolution SQL to the patrol cycle (mark resolved after 2x window of stability).
2. Add time-to-resolve tracking (Grafana Panel 5).
3. Set up maintenance window suppression table (optional, < 30 min).

### Phase 4: Sliding-Window Daemon (Approach B) — future

Only if:
- False alerts become a problem (patrol re-alerting on persistent crash loops)
- Need sub-minute detection latency (patrol runs every 5 min)
- Multiple clusters produce > 100 crash loop events per day

---

## References

- Docker event monitoring: `docs/infra/reviews/docker-events.md`
- Patrol guide: `docs/infra/5min-patrol-guide.md`
- Feishu alert integration: `docs/infra/feishu-alert-guide.md`
- ClickHouse ReplacingMergeTree docs
- Docker restart policies: `--restart=unless-stopped` behavior on crash

---

## Verdict

The design is simple and incremental. Approach A (SQL detection via existing patrol) requires zero new infrastructure -- just a ClickHouse query in the 5-minute patrol cycle and a Grafana dashboard. The three-tier system (Instant/Fast/Slow) catches everything from acute crash loops to chronic instability.

All three phases can be implemented in a single day. The sliding-window daemon (Approach B) is explicitly deferred until signal quality demands it, avoiding premature optimization.

Key success metrics:
- Mean time to detect crash loop (MTTD): < 5 minutes (patrol cycle)
- Mean time to resolve (MTTR): < 15 minutes for P1 (alert → human action)
- False positive rate: < 1 per week (near misses table helps tune thresholds)
- Detector uptime: > 99.9% (runs as part of patrol, survives boss restarts)

> ／人◕ ‿‿ ◕人＼
