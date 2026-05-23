---
decision: 稍后做
---

# Session Monitor: cc-connect Session Files Observability

**Date**: 2026-05-23
**Scope**: Monitor cc-connect session files on disk -- track count, age, activity, and alert on stale/zombie sessions.

---

## 1. Background

cc-connect persists session state to disk files. Each session represents an ongoing conversation between a Feishu user and a Claude Code agent. Sessions are:

- **Created** when a user sends the first message in a new conversation
- **Updated** on each message turn (user -> Claude -> response -> Feishu)
- **Closed** on explicit session end, timeout, or cc-connect restart with no recovery

Without monitoring, stale session files accumulate silently, consuming disk space and potentially masking issues (e.g., cc-connect thinks a session is alive but the Claude agent process has been killed).

### Current Blind Spots

| Gap | Impact |
|-----|--------|
| No visibility into active session count | Cannot distinguish between normal usage and session leak |
| No session age tracking | Old sessions may be using resources without producing value |
| No last-activity timestamp per session | Cannot detect stuck sessions (Claude process alive but not responding) |
| No session file corruption detection | Corrupted state can cause crashes on restart or session resume |
| No auto-cleanup of stale sessions | Manual intervention required to reclaim disk and state slots |

---

## 2. Session File Location and Format

### Expected Location

cc-connect persists session state in its data directory:

```
/root/.cc-connect/sessions/
```

Each session is stored as an individual file:

```
/root/.cc-connect/sessions/feishu:oc_xxx:ou_yyy.json
/root/.cc-connect/sessions/feishu:oc_abc:ou_def.json
```

### Expected Format

JSON files with the following structure (inferred from cc-connect v1.3.2 log fields and session lifecycle):

```json
{
  "session_id": "feishu:oc_xxx:ou_yyy",
  "agent_session": "d2720c67-...",
  "created_at": "2026-05-22T10:00:00Z",
  "last_activity": "2026-05-23T15:30:00Z",
  "turn_count": 42,
  "message_count": 87,
  "state": "active",
  "chat_type": "group",
  "platform": "feishu",
  "metadata": {
    "user_id": "ou_yyy",
    "chat_id": "oc_xxx"
  }
}
```

> **Note**: The exact fields depend on cc-connect's internal session serialization. The monitor script must be configured to match the actual file format. Verify by inspecting a sample session file.

---

## 3. Monitoring Dimensions

### 3.1 Session Count

Track the number of session files on disk.

| Metric | Type | Source |
|--------|------|--------|
| `cc.sessions.active` | gauge | Count of `.json` files in session dir |
| `cc.sessions.active_by_state` | gauge | Count per `state` value (active / paused / error) |
| `cc.sessions.active_by_platform` | gauge | Count per platform (feishu / dingtalk) |

**Normal range**: TBD after baseline observation. Expected: 1-10 at current usage (~90 messages/day across likely 1-3 users).

**Alert**: Count exceeds 2x baseline for >1 hour, or count > 20 (whichever is lower, tune after baseline).

### 3.2 Session Age

Track how long each session has existed since creation.

| Metric | Type | Source |
|--------|------|--------|
| `cc.sessions.age_seconds` | histogram | `now() - created_at` per file |
| `cc.sessions.age_max_seconds` | gauge | Oldest session age |
| `cc.sessions.age_p50_seconds` | gauge | Median session age |
| `cc.sessions.age_p90_seconds` | gauge | P90 session age |

**Normal range**: Most sessions should be < 24h (conversations resolve within a day). Some may persist longer if users have ongoing multi-day conversations.

### 3.3 Session Activity

Track the time since each session's last message.

| Metric | Type | Source |
|--------|------|--------|
| `cc.sessions.idle_seconds` | histogram | `now() - last_activity` per file |
| `cc.sessions.idle_max_seconds` | gauge | Most idle session |
| `cc.sessions.stale_count` | gauge | Sessions idle > 24h |
| `cc.sessions.zombie_count` | gauge | Sessions idle > 7d |

**This is the most important dimension** -- idle time directly indicates whether sessions are alive or stuck.

### 3.4 Session File Health

Track file integrity.

| Metric | Type | Source |
|--------|------|--------|
| `cc.sessions.corrupted` | gauge | Files that fail JSON parse |
| `cc.sessions.filesize_bytes` | histogram | File size distribution |
| `cc.sessions.filesize_max_bytes` | gauge | Largest session file |

Corrupted files suggest disk corruption, partial writes, or a bug in cc-connect's session persistence. Abnormally large files may indicate runaway state (e.g., accumulating context without bound).

---

## 4. Alert Thresholds

| Rule | Condition | Level | Action |
|------|-----------|-------|--------|
| **StaleSession** | Any session idle > 24h | P3 | Notify daily digest; flag for manual review |
| **ZombieSession** | Any session idle > 7d | P2 | Auto-archive or prompt user for cleanup |
| **SessionCountAnomaly** | Count > 2x baseline for 1h | P2 | Investigate: normal usage spike or session leak? |
| **CorruptedSession** | Any file fails JSON parse | P2 | Inspect file, report to cc-connect maintainer |
| **OversizedSession** | Any file > 10 MB | P3 | Likely runaway state accumulation |
| **NoSessionDir** | Session directory missing | P1 | cc-connect may not have started or disk is unmounted |
| **SessionDirNotWritable** | Cannot write to session dir | P1 | cc-connect will fail to persist sessions |

### Alert Staging

The above rules are tiered to avoid noise. Implement in this order:

1. **StaleSession + ZombieSession** (same script, different thresholds)
2. **SessionCountAnomaly** (needs baseline -- deploy after 1 week of data)
3. **CorruptedSession + OversizedSession** (health checks)
4. **NoSessionDir + SessionDirNotWritable** (infrastructure checks)

---

## 5. Implementation Options

### Option A: Bash Script (cc-healthcheck integration)

Add a `session-check` subcommand or flag to `~/.kyb/bin/cc-healthcheck`.

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/cc-session-check
# Monitor cc-connect session files.

SESSION_DIR="/root/.cc-connect/sessions"
STALE_THRESHOLD_SECONDS=$((24 * 60 * 60))       # 24h
ZOMBIE_THRESHOLD_SECONDS=$((7 * 24 * 60 * 60))  # 7d
NOW=$(date +%s)

# Check directory exists
if [ ! -d "$SESSION_DIR" ]; then
  echo "CRITICAL: Session directory $SESSION_DIR does not exist"
  exit 2
fi

# Count sessions
TOTAL=$(ls -1 "$SESSION_DIR"/*.json 2>/dev/null | wc -l)
STALE=0
ZOMBIE=0
CORRUPTED=0
OLDEST_AGE=0
MAX_IDLE=0

for f in "$SESSION_DIR"/*.json; do
  [ -f "$f" ] || continue

  # Check JSON validity
  if ! jq empty "$f" 2>/dev/null; then
    CORRUPTED=$((CORRUPTED + 1))
    continue
  fi

  # Parse timestamps
  CREATED=$(jq -r '.created_at // "1970-01-01T00:00:00Z"' "$f")
  LAST_ACT=$(jq -r '.last_activity // .created_at // "1970-01-01T00:00:00Z"' "$f")

  CREATED_TS=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)
  LAST_TS=$(date -d "$LAST_ACT" +%s 2>/dev/null || echo 0)

  AGE=$((NOW - CREATED_TS))
  IDLE=$((NOW - LAST_TS))

  [ "$AGE" -gt "$OLDEST_AGE" ] && OLDEST_AGE=$AGE
  [ "$IDLE" -gt "$MAX_IDLE" ] && MAX_IDLE=$IDLE

  if [ "$IDLE" -gt "$ZOMBIE_THRESHOLD_SECONDS" ]; then
    ZOMBIE=$((ZOMBIE + 1))
  elif [ "$IDLE" -gt "$STALE_THRESHOLD_SECONDS" ]; then
    STALE=$((STALE + 1))
  fi
done

# Output structured metrics (machine-parseable)
cat <<METRICS
cc_sessions_total $TOTAL
cc_sessions_stale $STALE
cc_sessions_zombie $ZOMBIE
cc_sessions_corrupted $CORRUPTED
cc_sessions_oldest_age_seconds $OLDEST_AGE
cc_sessions_max_idle_seconds $MAX_IDLE
METRICS

# Exit codes for alerting
if [ "$ZOMBIE" -gt 0 ]; then
  exit 2  # CRITICAL
elif [ "$STALE" -gt 0 ] || [ "$CORRUPTED" -gt 0 ]; then
  exit 1  # WARNING
else
  exit 0  # OK
fi
```

**Integration**: Run every patrol cycle (5 min) from `cc-healthcheck`, or as a standalone cron every 15 min. Output metrics can be:

- Written to a heartbeat/metrics file consumed by Vector
- Exported via Prometheus node_exporter textfile collector
- Logged to stdout for Vector log ingestion

### Option B: Vector Ingestion into ClickHouse

Parse the session files and ingest their state as time-series data into ClickHouse.

**Table schema**:

```sql
CREATE TABLE cc.session_snapshots (
    timestamp       DateTime64(3),
    session_id      String,
    agent_session   String,
    created_at      DateTime64(3),
    last_activity   DateTime64(3),
    turn_count      UInt32,
    message_count   UInt32,
    state           LowCardinality(String),
    chat_type       LowCardinality(String),
    platform        LowCardinality(String),
    user_id         String,
    chat_id         String,
    file_size_bytes UInt32,
    is_corrupted    UInt8
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), session_id)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

**Materialized view for live session state** (always the latest snapshot per session):

```sql
CREATE MATERIALIZED VIEW cc.session_latest
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (session_id)
POPULATE AS
SELECT argMax(session_id, timestamp) AS session_id,
       argMax(agent_session, timestamp),
       argMax(created_at, timestamp),
       argMax(last_activity, timestamp),
       argMax(turn_count, timestamp),
       argMax(message_count, timestamp),
       argMax(state, timestamp),
       argMax(chat_type, timestamp),
       argMax(platform, timestamp),
       argMax(user_id, timestamp),
       argMax(chat_id, timestamp),
       argMax(file_size_bytes, timestamp),
       argMax(is_corrupted, timestamp),
       max(timestamp) AS last_seen
FROM cc.session_snapshots
GROUP BY session_id;
```

**Grafana queries**:

Active session count:
```sql
SELECT count() AS active_sessions FROM cc.session_latest
WHERE state = 'active'
  AND last_activity > now() - INTERVAL 24 HOUR;
```

Stale sessions (idle > 24h):
```sql
SELECT session_id, last_activity,
       dateDiff('hour', last_activity, now()) AS idle_hours
FROM cc.session_latest
WHERE last_activity < now() - INTERVAL 24 HOUR
ORDER BY idle_hours DESC;
```

Session age distribution:
```sql
SELECT floor(dateDiff('hour', created_at, now()) / 24) AS age_days,
       count() AS session_count
FROM cc.session_latest
GROUP BY age_days
ORDER BY age_days;
```

### Option C: Prometheus Exporter

Run a lightweight exporter that reads session files every 15s and exposes Prometheus metrics on an HTTP endpoint.

```
cc_sessions_active 3
cc_sessions_stale 0
cc_sessions_zombie 0
cc_sessions_corrupted 0
cc_sessions_idle_seconds{session_id="feishu:oc_xxx:ou_yyy"} 3600
cc_sessions_age_seconds{session_id="feishu:oc_xxx:ou_yyy"} 86400
cc_sessions_turn_count{session_id="feishu:oc_xxx:ou_yyy"} 42
cc_sessions_file_size_bytes{session_id="feishu:oc_xxx:ou_yyy"} 4096
```

Implementation approaches:

1. **node_exporter textfile collector**: Run the Option A script via cron, write output to a `.prom` file. Simplest, but per-session metrics require a dynamic file.
2. **Dedicated Go/Python exporter**: A small HTTP server with a metrics endpoint. More work but supports per-session labels. ~50 lines of Python (prometheus_client library).
3. **Vector Prometheus sink**: Use Option B (Vector -> CK) and add a Prometheus sink in Vector. No new daemon, but lacks per-session cardinality.

---

## 6. Recommended Approach: Hybrid (Option A + Option B)

For the current scale (~90 messages/day, 1-3 sessions), deploy a **two-layer** approach:

### Layer 1: Patrol Integration (immediate, < 1h)

Add session file monitoring to the existing 5-min patrol:

1. Add `~/.kyb/bin/cc-session-check` (the Option A script) to the codebase.
2. Call it from `cc-healthcheck` or the patrol prompt.
3. On stale/zombie detection, include session stats in the patrol report (feishu notification).

**Metric output**: Write to `.kyb-diaries/.session-metrics` for human review and basic trend tracking.

### Layer 2: ClickHouse + Grafana (after baseline, < 1 day)

Once baseline activity is established:

1. Deploy Vector to ingest session file snapshots (Option B).
2. Create ClickHouse tables `cc.session_snapshots` and `cc.session_latest`.
3. Build a Grafana dashboard with:
   - **Stat panel**: active session count (current)
   - **Time series**: session count over time (24h, 7d)
   - **Table**: list of active sessions with age, idle time, turn count
   - **Stat panel**: stale/zombie count (current)
   - **Table**: stale sessions needing attention
   - **Logs/history**: session lifecycle events
4. Configure Grafana alerts on the thresholds from Section 4.

### When to Add Option C (Prometheus)

Only if:
- Session count grows beyond 50 (per-session cardinality becomes meaningful)
- Other Prometheus-native monitoring is already in place for cc-connect
- Need sub-minute scrape intervals for session data

At current scale, Option C is premature optimization.

---

## 7. Session Lifecycle Events (CK Enrichment)

Beyond periodic snapshots, ingest session lifecycle events for richer observability. cc-connect v1.3.2 native hooks emit:

| Hook Event | CK Action |
|------------|-----------|
| `session.created` | INSERT into session lifecycle table |
| `session.resumed` | UPDATE last_activity |
| `session.timeout` | Flag as idle + record timeout duration |
| `session.crashed` | Flag as error + record error context |
| `session.closed` | Close the session record (add end_time) |

**Lifecycle table**:

```sql
CREATE TABLE cc.session_events (
    timestamp       DateTime64(3),
    event_type      LowCardinality(String),  -- created / resumed / timeout / crashed / closed
    session_id      String,
    agent_session   String,
    turn_count      UInt32,
    duration_ms     UInt32,                  -- session lifetime or idle period
    error           String,                  -- only for crashed/timeout events
    metadata        Map(String, String)      -- extensible context
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), session_id, event_type)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

**Grafana alert**: If a `session.crashed` event is not followed by a `session.resumed` or `session.closed` within 15 minutes, alert -- the crash recovery may have failed.

---

## 8. Auto-Cleanup Policy

Once monitoring is in place, add automatic cleanup for identified stale/zombie sessions:

| Condition | Action | Safety |
|-----------|--------|--------|
| Idle > 7 days | Delete session file | Daemon creates a `.backup` before delete |
| Corrupted file | Move to `.corrupted/` dir | Preserved for forensic analysis |
| Crashed + no recovery > 1h | Delete session file | Allows user to start fresh |
| Session count > 50 | Alert only (no auto-cleanup) | Human decision required |

Auto-cleanup should be a **separate script** from the monitor script, gated by a `--cleanup` flag:

```bash
~/.kyb/bin/cc-session-check --cleanup --dry-run   # Preview only
~/.kyb/bin/cc-session-check --cleanup              # Execute cleanup
```

**Cron schedule**: Run cleanup once per hour (not every 5 min like monitoring).

---

## 9. Grafana Dashboard Layout

```
Row: "Session Overview"
  ├── Stat: Active Sessions (current, gauge: green 0-10, yellow 10-20, red >20)
  ├── Stat: Stale Sessions (current, gauge: green 0, yellow 1-3, red >3)
  ├── Stat: Zombie Sessions (current, gauge: green 0, yellow 0, red >0)
  └── Stat: Corrupted Files (current, gauge: green 0, red >0)

Row: "Session Activity"
  ├── Time Series: Session Count over 7d
  ├── Time Series: Active vs Stale over 24h
  └── Time Series: Session Creation Rate (per hour)

Row: "Session Detail"
  ├── Table: Active Sessions (session_id, created_at, last_activity, idle_hours, turn_count)
  ├── Table: Stale Sessions (session_id, last_activity, idle_hours)
  └── Table: Session Events (recent 50)

Row: "Session Health"
  ├── Histogram: Session Age Distribution
  ├── Histogram: Idle Time Distribution
  └── Stat: Max Session File Size
```

---

## 10. Implementation Checklist

### Phase 1: Discovery (done during this review)
- [ ] Verify session file location on the target host (ssh into the infra machine, check `/root/.cc-connect/sessions/`)
- [ ] Inspect actual file format (field names, timestamps, state values)
- [ ] Establish baseline: typical active session count, age, idle times

### Phase 2: Script (immediate, < 1h)
- [ ] Write `~/.kyb/bin/cc-session-check` with the structure from Option A
- [ ] Test against actual session files
- [ ] Integrate into patrol (call from cc-healthcheck or patrol prompt)
- [ ] Confirm patrol report includes session stats

### Phase 3: ClickHouse (after baseline, < 1 day)
- [ ] Create `cc.session_snapshots` table
- [ ] Create `cc.session_latest` materialized view
- [ ] Configure Vector to parse and ingest session file contents
- [ ] Verify data flows to ClickHouse

### Phase 4: Grafana (after CK data, < 2h)
- [ ] Build the session dashboard (Section 9 layout)
- [ ] Configure Grafana alerts (Section 4 thresholds)
- [ ] Verify alert fires on test data

### Phase 5: Auto-Cleanup (optional, after 1 week)
- [ ] Implement `--cleanup` mode in session-check script
- [ ] Deploy cleanup cron (hourly)
- [ ] Monitor cleanup logs for unexpected behavior

---

## 11. References

- cc-connect log format: `docs/infra/reviews/review-bridge-ck-ingestion-A1.md`
- cc-connect hooks: `docs/infra/reviews/review-bridge-hooks-C1.md`
- Patrol guide: `docs/infra/5min-patrol-guide.md`
- Observability design: `docs/infra/observability-design.md`
- OTel cc-connect: `docs/infra/reviews/otel-cc-connect.md`
- Hook CK pipeline: `docs/infra/handbook/hooks-ck-pipeline.md`
