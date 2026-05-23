---
decision: 稍后做
---

# User Activity Heatmap — infra 用户活跃度监控

**Date**: 2026-05-23
**Scope**: Track user active hours, session frequency, and Feishu message patterns across the infra. Build a heatmap visualization for at-a-glance activity awareness.

---

## 1. Background

We have multiple users interacting with the infra through different channels:

- **Feishu users** sending messages to Claude Code agents via cc-connect
- **Developers** running `kyb exec/enter` on sandbox containers
- **Boss/patrol agents** issuing automated commands during 5-min patrol cycles
- **Git contributors** pushing commits at various hours

Without aggregated activity visibility, we cannot answer basic questions:

| Question | Impact |
|----------|--------|
| When are users most active? | Capacity planning, maintenance windows |
| Which users are dormant? | License cleanup, onboarding follow-up |
| Are Feishu message patterns aligning with session activity? | Verify cc-connect is the primary channel |
| Is there activity outside expected hours? | Anomaly detection, security review |
| How many active users per day/week? | Growth tracking, SLA commitments |

A **heatmap** (hour-of-day vs day-of-week, color-coded by activity count) provides an at-a-glance answer to all of these.

---

## 2. Data Sources

### 2.1 Session Activity (cc-connect)

cc-connect session files and hook events already contain per-user activity timestamps.

**Source**: `cc.session_events` table (from `review-bridge-ck-ingestion-A1`/`session-monitor.md`)

```json
{
  "session_id": "feishu:oc_xxx:ou_yyy",
  "event_type": "created / resumed / timeout / closed",
  "timestamp": "2026-05-23T14:30:00Z",
  "user_id": "ou_yyy",
  "turn_count": 42
}
```

**Extracted dimensions**:
- `user_id` — Feishu open_id (mapped to display name via Feishu API)
- `timestamp` — event time
- `event_type` — type of activity
- `turn_count` — message volume

### 2.2 Feishu Message Patterns

Feishu webhook events (from `bridge-hooks-alerting.md` / proxy-intercept.md) record every inbound and outbound message.

**Source**: `lark.message_event` table (ingested via feishu webhook proxy)

```json
{
  "event_id": "xxxxxxxx",
  "timestamp": "2026-05-23T14:30:00Z",
  "chat_id": "oc_xxx",
  "sender_id": "ou_yyy",
  "message_type": "text / image / post",
  "is_from_user": true/false
}
```

**Extracted dimensions**:
- `sender_id` — who sent the message
- `timestamp` — when
- `message_type` — what kind
- `is_from_user` — distinguishes human messages from bot replies

### 2.3 Sandbox Exec Activity (kyb)

Each `kyb exec` and `kyb enter` command generates a log entry. This tells us when developers are actively using sandboxes.

**Source**: Docker daemon events (`docker-events.md`) or `kyb` audit log

```json
{
  "timestamp": "2026-05-23T14:30:00Z",
  "container": "kyb-feat-foo",
  "action": "exec_create / exec_start / exec_die",
  "user": "dev"
}
```

**Extracted dimensions**:
- `user` — who ran the command (from host user or SSH)
- `timestamp` — when
- `container` — which sandbox
- `action` — exec_create (entered) or exec_die (exited)

### 2.4 Git Activity (optional, enrichment)

Git commit timestamps per developer.

**Source**: `git log --format="%H %ai %an"` (periodic scan or webhook)

**Extracted dimensions**:
- `author` — developer name
- `timestamp` — commit time
- `project` — repository

### 2.5 Patrol Agent Activity

Automated patrol cycles generate their own activity. Include or exclude based on intent:

- **Include** if we want to see total infra utilization
- **Exclude** if we want to see only human activity

**Recommendation**: Track separately with an `activity_source` tag (`human` / `bot` / `patrol`).

---

## 3. Architecture

```
                    ┌──────────────────┐
                    │   Data Sources   │
                    │  ┌─────────────┐ │
                    │  │  cc-connect │ │
                    │  │  sessions   │ │
                    │  └──────┬──────┘ │
                    │  ┌─────────────┐ │
                    │  │  Feishu     │ │
                    │  │  messages   │ │
                    │  └──────┬──────┘ │
                    │  ┌─────────────┐ │
                    │  │  Docker     │ │
                    │  │  exec logs  │ │
                    │  └──────┬──────┘ │
                    │  ┌─────────────┐ │
                    │  │  Git events │ │
                    │  └──────┬──────┘ │
                    └─────────┼────────┘
                              │
                    ┌─────────▼────────┐
                    │   Vector (or     │
                    │   Fluentd)       │
                    │   Aggregation    │
                    └─────────┬────────┘
                              │
                    ┌─────────▼────────┐
                    │   ClickHouse     │
                    │  ┌─────────────┐ │
                    │  │ user_events │ │
                    │  │ (raw)       │ │
                    │  └──────┬──────┘ │
                    │  ┌─────────────┐ │
                    │  │ user_hourly │ │
                    │  │ (MV/agg)    │ │
                    │  └──────┬──────┘ │
                    │  ┌─────────────┐ │
                    │  │ user_weekly │ │
                    │  │ (MV/agg)    │ │
                    │  └──────┬──────┘ │
                    └─────────┼────────┘
                              │
                    ┌─────────▼────────┐
                    │     Grafana      │
                    │  ┌─────────────┐ │
                    │  │  Heatmap    │ │
                    │  │  (hour/day) │ │
                    │  ├─────────────┤ │
                    │  │  User stats │ │
                    │  │  (per user) │ │
                    │  ├─────────────┤ │
                    │  │  Msg volume │ │
                    │  │  (time ser) │ │
                    │  └─────────────┘ │
                    └──────────────────┘
```

**Recommended approach**: Ingest all sources into a unified `user_events` table in ClickHouse, then build materialized views for hourly/weekly aggregation. Grafana queries the aggregated views for heatmap rendering.

---

## 4. ClickHouse Schema

### 4.1 Raw Events Table

Stores every activity event from all sources. Minimal processing at write time.

```sql
CREATE TABLE infra.user_events (
    timestamp       DateTime64(3),
    event_id        String,
    source          LowCardinality(String),  -- 'cc_session' / 'feishu_msg' / 'docker_exec' / 'git_commit' / 'patrol'
    user_id         String,
    user_display    String,                  -- display name (enriched post-ingest)
    activity_type   LowCardinality(String),  -- 'session_start' / 'session_end' / 'msg_send' / 'exec_enter' / 'commit_push'
    detail          String,                  -- optional context (e.g., container name, chat title)
    metadata        Map(String, String)      -- extensible: chat_id, project, session_id, etc.
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), source, user_id)
TTL toDate(timestamp) + INTERVAL 90 DAY
PARTITION BY toDate(timestamp);
```

**Justification**:
- `ORDER BY (toDate(timestamp), source, user_id)` — optimizes the common heatmap query pattern (date range + source filter + user group)
- `PARTITION BY toDate(timestamp)` — efficient TTL-based cleanup and partition pruning
- `TTL 90 days` — heatmap value diminishes beyond 3 months; archive raw data elsewhere if needed
- `LowCardinality` for source/activity_type — these have few distinct values

### 4.2 Hourly Aggregation (Materialized View)

Pre-aggregated counts per user per hour. This is what the heatmap queries.

```sql
CREATE MATERIALIZED VIEW infra.user_activity_hourly
ENGINE = SummingMergeTree
ORDER BY (toStartOfHour(timestamp), user_id, source)
POPULATE AS
SELECT
    toStartOfHour(timestamp) AS hour,
    user_id,
    user_display,
    source,
    count()                   AS event_count,
    countDistinct(activity_type) AS type_count,
    min(timestamp)            AS first_event,
    max(timestamp)            AS last_event
FROM infra.user_events
GROUP BY hour, user_id, user_display, source;
```

### 4.3 Daily User Summary (Materialized View)

Per-user daily stats for dashboard stat panels.

```sql
CREATE MATERIALIZED VIEW infra.user_activity_daily
ENGINE = SummingMergeTree
ORDER BY (toDate(timestamp), user_id)
POPULATE AS
SELECT
    toDate(timestamp)         AS day,
    user_id,
    user_display,
    source,
    count()                   AS event_count,
    countDistinct(activity_type) AS type_count,
    countDistinct(
        toStartOfHour(timestamp)
    )                         AS active_hours,
    min(timestamp)            AS first_event,
    max(timestamp)            AS last_event,
    dateDiff('minute', min(timestamp), max(timestamp))
                              AS activity_span_minutes
FROM infra.user_events
GROUP BY day, user_id, user_display, source;
```

### 4.4 Source-Specific Detail Tables (Optional)

For drill-down from the heatmap. Each source gets its own table for source-specific fields.

#### cc-connect session activity

```sql
CREATE TABLE infra.cc_session_events (
    timestamp       DateTime64(3),
    session_id      String,
    user_id         String,
    event_type      LowCardinality(String),  -- created / resumed / timeout / closed
    turn_count      UInt32,
    chat_type       LowCardinality(String),  -- group / p2p
    chat_id         String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), user_id, session_id)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

#### Feishu message events

```sql
CREATE TABLE infra.feishu_message_events (
    timestamp       DateTime64(3),
    message_id      String,
    sender_id       String,
    chat_id         String,
    message_type    LowCardinality(String),  -- text / image / post / sticker
    is_from_user    UInt8,                   -- 1 = human, 0 = bot reply
    content_length  UInt32,
    metadata        Map(String, String)
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), sender_id)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

#### Docker exec events

```sql
CREATE TABLE infra.docker_exec_events (
    timestamp       DateTime64(3),
    container       String,
    user            String,
    action          LowCardinality(String),  -- exec_create / exec_die
    exit_code       UInt32,
    command         String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), user, container)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

---

## 5. Data Ingestion

### 5.1 cc-connect Sessions → Vector

Vector parses cc-connect log lines or hook event JSON and writes to `infra.user_events`.

```toml
# vector.toml — cc-connect session events
[sources.cc_sessions]
type = "file"
includes = ["/root/.cc-connect/logs/*.log"]

[transforms.parse_cc_events]
type = "remap"
inputs = ["cc_sessions"]
source = '''
. = parse_json!(.message)
.source = "cc_session"
.user_id = .user_id
.activity_type = .event_type
.timestamp = .timestamp
'''

[sinks.cc_events_to_ck]
type = "clickhouse"
inputs = ["parse_cc_events"]
endpoint = "http://clickhouse:8123"
table = "infra.user_events"
```

### 5.2 Feishu Messages → Vector

Feishu events arrive via webhook proxy. Vector consumes from a file or HTTP source.

```toml
[sources.feishu_webhook]
type = "http_server"
address = "0.0.0.0:8088"
path = "/feishu/events"

[transforms.parse_feishu]
type = "remap"
inputs = ["feishu_webhook"]
source = '''
.source = "feishu_msg"
.user_id = .sender_id
.activity_type = "msg_send"
.timestamp = .timestamp
'''
```

### 5.3 Docker Exec Events → Vector

Docker events consumed via Docker socket or file log.

```toml
[sources.docker_events]
type = "docker_logs"
include_images = ["kyb-*"]

[transforms.parse_docker_exec]
type = "remap"
inputs = ["docker_events"]
source = '''
if .action == "exec_create" || .action == "exec_die" {
  .source = "docker_exec"
  .user_id = .actor.attributes.user // "unknown"
  .activity_type = .action
}
'''
```

### 5.4 Fallback: Patrol Script

If Vector pipeline is not yet deployed, use a lightweight patrol script that polls the sources and writes to a heartbeat file consumed by Vector later.

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/kyb-activity-snapshot
# Snapshot current activity state for heatmap ingestion.

SNAPSHOT_DIR="/root/.kyb-diaries/activity"
mkdir -p "$SNAPSHOT_DIR"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOUR=$(date -u +%H)
DAY=$(date -u +%u)  # 1=Mon .. 7=Sun

# 1. Count active sessions from cc-connect
SESSION_DIR="/root/.cc-connect/sessions"
ACTIVE_SESSIONS=0
if [ -d "$SESSION_DIR" ]; then
  ACTIVE_SESSIONS=$(ls -1 "$SESSION_DIR"/*.json 2>/dev/null | wc -l)
fi

# 2. Count recent Docker exec events (last hour)
DOCKER_EXECS=$(docker events --since "${HOUR}h" --filter 'type=container' --format '{{.Action}}' 2>/dev/null | grep -c exec_start || true)

# 3. Write snapshot
cat <<SNAPSHOT > "$SNAPSHOT_DIR/$(date -u +%Y%m%d-%H%M).json"
{
  "timestamp": "$NOW",
  "day_of_week": $DAY,
  "hour": $HOUR,
  "active_sessions": $ACTIVE_SESSIONS,
  "docker_execs_last_hour": $DOCKER_EXECS
}
SNAPSHOT

echo "infra_activity_snapshots{hour=\"$HOUR\",dow=\"$DAY\"} $ACTIVE_SESSIONS"
```

Run from patrol cron (every 5 min):
```
*/5 * * * * ~/.kyb/bin/kyb-activity-snapshot
```

---

## 6. Grafana Heatmap Dashboard

### 6.1 Layout

```
Row: "Activity Summary"
  ├── Stat: Active Users Today (count distinct user_id with event in last 24h)
  ├── Stat: Total Events Today (sum of event_count)
  ├── Stat: Peak Hour Today (hour with most events)
  └── Stat: Most Active User (user_display with highest event_count today)

Row: "Activity Heatmap"
  ├── Heatmap: All Sources — Hour vs Day of Week (last 28 days)
  ├── Heatmap: Feishu Messages — Hour vs Day of Week (last 28 days)
  └── Heatmap: Session Activity — Hour vs Day of Week (last 28 days)

Row: "Per-User Breakdown"
  ├── Time Series: Top 5 Users — Events per Hour (last 7d)
  ├── Table: User Activity Ranking (last 7d)
  └── Stat: New vs Returning Users (weekly)

Row: "Message Pattern Analysis"
  ├── Time Series: Messages per Hour (last 7d, colored by user)
  ├── Bar Chart: Peak Hours by User (last 7d)
  └── Table: Response Latency by Hour (if available from cc-connect)
```

### 6.2 Heatmap Query (ClickHouse)

**Main heatmap**: events per (hour, day_of_week) cell over last 28 days.

```sql
SELECT
    toDayOfWeek(hour) AS day_of_week,   -- 1=Mon .. 7=Sun
    toHour(hour)      AS hour_of_day,
    sum(event_count)  AS total_events
FROM infra.user_activity_hourly
WHERE hour >= now() - INTERVAL 28 DAY
  AND source NOT IN ('patrol')   -- exclude bots for human-focused view
GROUP BY day_of_week, hour_of_day
ORDER BY day_of_week, hour_of_day;
```

**Per-user heatmap source override** (Grafana variable `$user`):

```sql
SELECT
    toDayOfWeek(hour) AS day_of_week,
    toHour(hour)      AS hour_of_day,
    sum(event_count)  AS total_events
FROM infra.user_activity_hourly
WHERE hour >= now() - INTERVAL 28 DAY
  AND user_id = {user_id: String}
GROUP BY day_of_week, hour_of_day
ORDER BY day_of_week, hour_of_day;
```

### 6.3 Grafana Heatmap Panel Configuration

| Setting | Value |
|---------|-------|
| **Visualization** | Heatmap |
| **Bucket size** | 1h × 1d |
| **Y-axis** | Hour of day (0-23) |
| **X-axis** | Day of week (Mon-Sun) or Date |
| **Color scheme** | `#E0F2FE` (cool) → `#1E40AF` (hot), or use `thresholds` |
| **Cell display** | event count on hover |
| **Data format** | Time series buckets |

**Two layout options**:

| Layout | X-axis | Use Case |
|--------|--------|----------|
| **Weekly pattern** | Day of week (1-7) | "Which days/hours are busiest?" — aggregates across weeks |
| **Calendar** | Date | "What happened on specific days?" — includes trend over time |

Recommendation: Show **weekly pattern** by default, with a toggle or second panel for **calendar** view.

### 6.4 TOPN User Activity (Drill-Down)

Click on a heatmap cell → drill into which users contributed:

```sql
SELECT
    user_display,
    sum(event_count) AS events,
    count()          AS sessions
FROM infra.user_activity_hourly
WHERE hour >= now() - INTERVAL 7 DAY
  AND toHour(hour) = {hour: UInt8}
  AND toDayOfWeek(hour) = {dow: UInt8}
GROUP BY user_display
ORDER BY events DESC
LIMIT 20;
```

### 6.5 User Summary Panel

Top-N users by activity in the last 7 days:

```sql
SELECT
    user_display,
    sum(event_count)                      AS total_events,
    countDistinct(toDate(hour))           AS active_days,
    round(avg(event_count), 1)            AS avg_events_per_hour,
    max(event_count)                      AS peak_events_hour,
    argMax(toHour(hour), event_count)     AS peak_hour
FROM infra.user_activity_hourly
WHERE hour >= now() - INTERVAL 7 DAY
GROUP BY user_display
ORDER BY total_events DESC;
```

---

## 7. Alert Rules

| Rule | Condition | Level | Action |
|------|-----------|-------|--------|
| **NoActivity** | 0 events across all sources for > 6h during business hours (Mon-Fri 9-18) | P3 | Check cc-connect, Vector, and host availability |
| **ActivityDrop** | Event count drops > 80% compared to same hour last week | P3 | Could indicate upstream issue (Feishu outage, cc-connect down) |
| **ActivitySurge** | Event count > 3x baseline for > 2h | P4 | Investigate: new user onboarding, runaway process, or DDoS-like Feishu flood |
| **NewUserDetected** | First-ever event for a `user_id` | P4 | Notify team: new user joined |
| **DormantUser** | User with > 7d history has 0 events for 7 consecutive days | P4 | Check if user needs follow-up or cleanup |
| **OffHoursActivity** | > 50 events between 00:00-06:00 from a single user | P4 | Could be automated script or genuine late-night work |

**Staging**:
1. **NoActivity** + **ActivityDrop** (infra health, deploy immediately)
2. **NewUserDetected** (low noise, deploy after Phase 2)
3. **ActivitySurge** + **DormantUser** (needs baseline, deploy after 2 weeks of data)
4. **OffHoursActivity** (security-adjacent, confirm with team before enabling)

---

## 8. Implementation Plan

### Phase 1: Schema and Base Ingestion (< 2h)

- [ ] Create `infra.user_events` table in ClickHouse
- [ ] Create `infra.user_activity_hourly` materialized view
- [ ] Create `infra.user_activity_daily` materialized view
- [ ] Create source-specific tables: `infra.cc_session_events`, `infra.feishu_message_events`, `infra.docker_exec_events`
- [ ] Configure Vector to parse cc-connect session events → `infra.user_events`
- [ ] Configure Vector to parse Feishu webhook events → `infra.user_events`
- [ ] Configure Vector to parse Docker exec events → `infra.user_events`
- [ ] Verify data flows: run `SELECT count() FROM infra.user_events` after 1 patrol cycle

### Phase 2: Grafana Dashboard (< 2h)

- [ ] Build "Activity Summary" row with stat panels
- [ ] Build "Activity Heatmap" row with 3 heatmap panels (all, feishu, session)
- [ ] Build "Per-User Breakdown" row with time series and table
- [ ] Build "Message Pattern Analysis" row
- [ ] Add Grafana variables: `$source`, `$user_id`, `$time_range`
- [ ] Configure drill-down links from heatmap cells to user detail

### Phase 3: Enrichment and Polish (< 1h)

- [ ] Map `user_id` → `user_display` names (use Feishu API or static mapping)
- [ ] Add `activity_source` tag to distinguish human vs bot vs patrol
- [ ] Add tooltip details on heatmap hover (exact count, top users)
- [ ] Add annotations for known events (deployments, holidays, incidents)
- [ ] Set up weekly report (feishu card with top activity stats)

### Phase 4: Alerting (after 2 weeks baseline)

- [ ] Configure Grafana alert rules from Section 7
- [ ] Wire alerts to Feishu notification channel
- [ ] Tune thresholds based on observed baselines
- [ ] Document expected activity patterns as reference

---

## 9. Storage Estimation

| Table | Rows/day | Row size | Daily | 90-day |
|-------|----------|----------|-------|--------|
| `user_events` | ~5,000 | ~200 B | ~1 MB | ~90 MB |
| `user_activity_hourly` | ~500 | ~100 B | ~50 KB | ~4.5 MB |
| `user_activity_daily` | ~50 | ~100 B | ~5 KB | ~450 KB |
| `cc_session_events` | ~500 | ~150 B | ~75 KB | ~6.75 MB |
| `feishu_message_events` | ~3,000 | ~200 B | ~600 KB | ~54 MB |
| `docker_exec_events` | ~500 | ~150 B | ~75 KB | ~6.75 MB |

**Total (90 days)**: ~162 MB across all tables. Negligible impact on ClickHouse storage.

---

## 10. User Identity Mapping

Heatmaps are only useful if we can map opaque IDs to human-readable names.

### Approach: Static Mapping File

```bash
# /root/.kyb/etc/user-mapping.json
{
  "ou_xxx": {"name": "Alice", "role": "developer", "timezone": "Asia/Shanghai"},
  "ou_yyy": {"name": "Bob",   "role": "developer", "timezone": "Asia/Shanghai"},
  "ou_zzz": {"name": "Carol", "role": "ops",       "timezone": "Asia/Shanghai"}
}
```

Ingested into `infra.user_events.user_display` at write time via Vector enrich transform.

### Future: Feishu API Enrichment

```toml
[transforms.enrich_user]
type = "remap"
inputs = ["parse_feishu"]
source = '''
user_info = get_enrichment_table!("feishu_users")
.user_display = user_info[.user_id].name ?? .user_id
'''
```

---

## 11. Grafana Dashboard JSON Model

Key panel definitions for the heatmap (exportable as provisioning JSON):

```json
{
  "title": "Activity Heatmap — All Sources",
  "type": "heatmap",
  "datasource": "ClickHouse",
  "targets": [{
    "rawSql": "SELECT toDayOfWeek(hour) AS day_of_week, toHour(hour) AS hour_of_day, sum(event_count) AS total_events FROM infra.user_activity_hourly WHERE hour >= now() - INTERVAL 28 DAY GROUP BY day_of_week, hour_of_day ORDER BY day_of_week, hour_of_day",
    "format": "time_series"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "short",
      "color": {
        "mode": "continuous-blues"
      }
    }
  },
  "heatmap": {
    "yBucketBound": "auto",
    "yBucketNumber": 24,
    "xBucketBound": "auto",
    "xBucketNumber": 7,
    "yAxis": {
      "min": 0,
      "max": 23,
      "unit": "hour"
    },
    "xAxis": {
      "unit": "dayOfWeek"
    }
  }
}
```

---

## 12. References

- Session monitoring: `docs/infra/reviews/session-monitor.md`
- Fluentd log collector: `docs/infra/reviews/fluentd-pipeline.md`
- Proxy interception (Feishu WS): `docs/infra/reviews/proxy-intercept.md`
- Bridge CK ingestion: `docs/infra/reviews/review-bridge-ck-ingestion-A1.md`
- Docker event monitoring: `docs/infra/reviews/docker-events.md`
- Observability design overview: `docs/infra/observability-design.md`
- Feishu message schema: `docs/infra/handbook/hooks-ck-pipeline.md`
