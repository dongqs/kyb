---
decision: 稍后做
---

# Design: Boss Container Lifecycle Tracking

**Design doc**: `docs/infra/reviews/boss-lifecycle.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Track create/destroy counts, session duration per boss, idle detection, auto-cleanup

---

## 1. Background

Each infrastructure cluster runs a `kyb-infra-boss` container that manages local Docker containers (services and sandboxes). These boss containers are:

- **Long-lived** (24/7, `--restart=unless-stopped`)
- **Autonomous** (each boss manages its cluster without super-boss supervision)
- **Ephemeral** (on the host machine, they are just Docker containers -- can be stopped, killed, or recreated)

Currently, the heartbeat system (Section 2.4 of `multi-cluster-boss-architecture.md`) tracks basic liveness (`docker_running`, `docker_total`, `disk_used_pct`) every 60 seconds. However, this gives no visibility into:

- Whether a boss has been restarted (was the container recreated?)
- How long a boss has been continuously running (uptime since last container start)
- Whether the boss is productively active vs. sitting idle (zero sandbox activity)
- Historical creation/destruction patterns (did the boss crash? Was it deliberately recreated?)
- What to do when a boss container stops reporting (auto-cleanup decision)

### Current Blind Spots

| Gap | Impact |
|-----|--------|
| No boss container uptime tracking | Cannot distinguish between "boss running for 30 days" and "boss just restarted after crash" |
| No sandbox activity per boss | Cannot tell if a boss is working or idle (heartbeat does not track sandbox creates/removes) |
| No boss restart history | Boss restart erases container-local state, but central CK has no record of why |
| No idle detection | A boss that is alive but not doing useful work goes unnoticed |
| No auto-cleanup trigger | When a boss dies, its entry in clusters.yml stays ACTIVE forever |

---

## 2. Design Goals

1. **Track every boss creation and destruction event** -- know when a boss container was created, stopped, or destroyed, and why.
2. **Track boss session duration** -- how long each "incarnation" of a boss container has been running.
3. **Detect idle bosses** -- a boss is "idle" when it has not created/removed any sandbox in a configurable window.
4. **Auto-cleanup** -- when a boss stops heartbeating for a threshold duration, auto-cleanup its state (avoid stale registrations).
5. **Minimal overhead** -- no new daemon processes, no polling beyond the existing heartbeat loop.

---

## 3. Data Model

### 3.1 Boss Lifecycle Events

Append-only event log for each boss container incarnation. One row per lifecycle transition.

```sql
CREATE TABLE infra.boss_lifecycle_events (
    event_id        UUID DEFAULT generateUUIDv4(),
    boss_id         String,
    cluster         LowCardinality(String),
    event_type      Enum8(                        -- lifecycle transition
        'created'     = 1,                        -- container first created
        'started'     = 2,                        -- container started (after stop or daemon restart)
        'stopped'     = 3,                        -- container stopped (docker stop)
        'destroyed'   = 4,                        -- container removed (docker rm)
        'crashed'     = 5,                        -- container exited unexpectedly
        'restarted'   = 6,                        -- container restart (docker restart)
        'heartbeat_lost' = 7,                     -- heartbeat stopped for > threshold
        'cleanup'     = 8                         -- auto-cleanup action taken
    ),
    timestamp       DateTime64(3) DEFAULT now64(),
    boss_version    String,                        -- kyb version tag on the container
    host_machine    String,                        -- hostname of the physical machine
    container_id    String,                        -- Docker container ID (truncated 12-char)
    host_uptime     UInt32,                        -- host uptime in seconds at time of event
    session_id      UInt64,                        -- incrementing incarnation counter per boss_id
    payload         String                         -- JSON: reason, exit code, error context
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), cluster, boss_id, event_type)
TTL toDate(timestamp) + INTERVAL 90 DAY;

-- Materialized view: current boss state (latest event per boss_id)
CREATE MATERIALIZED VIEW infra.boss_current
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (boss_id)
POPULATE AS
SELECT argMax(boss_id, timestamp) AS boss_id,
       argMax(cluster, timestamp),
       argMax(event_type, timestamp) AS current_state,
       argMax(timestamp, timestamp) AS last_event_at,
       argMax(boss_version, timestamp),
       argMax(host_machine, timestamp),
       argMax(container_id, timestamp),
       argMax(session_id, timestamp)
FROM infra.boss_lifecycle_events
GROUP BY boss_id;
```

### 3.2 Heartbeat Enrichment

Add boss session fields to the existing `boss_heartbeats` table. These fields are populated every heartbeat cycle (60s) alongside the existing metrics.

```sql
ALTER TABLE boss_heartbeats
    ADD COLUMN IF NOT EXISTS boss_uptime_seconds UInt32 DEFAULT 0,
    ADD COLUMN IF NOT EXISTS sandbox_count UInt16 DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_sandbox_activity DateTime64(3) DEFAULT '1970-01-01 00:00:00',
    ADD COLUMN IF NOT EXISTS incarnation_id UInt64 DEFAULT 0;
```

- `boss_uptime_seconds`: seconds since this boss container was started (`$(date +%s) - $(stat -c %Y /proc/1 2>/dev/null)` or similar)
- `sandbox_count`: output of `kyb ps --quiet | wc -l` (number of sandbox containers managed)
- `last_sandbox_activity`: timestamp of the most recent `kyb create` or `kyb rm` on this boss
- `incarnation_id`: incremented each time the boss container restarts (tracked via a label or file)

### 3.3 Boss Session (Incarnation) Table

A boss "session" is a continuous run of a boss container from `created` to `stopped/destroyed/crashed`. This table is populated by merging lifecycle events.

```sql
CREATE TABLE infra.boss_sessions (
    boss_id         String,
    cluster         LowCardinality(String),
    incarnation_id  UInt64,
    version         String,
    host_machine    String,
    container_id    String,
    started_at      DateTime64(3),
    ended_at        DateTime64(3),
    duration_seconds UInt32,                     -- ended_at - started_at (or 0 if still running)
    end_reason      LowCardinality(String),      -- stopped / destroyed / crashed / running
    sandbox_count_peak   UInt16,                 -- max concurrent sandboxes during this session
    sandbox_count_total  UInt32                  -- total sandboxes created during this session
) ENGINE = ReplacingMergeTree(started_at)
ORDER BY (boss_id, incarnation_id)
TTL toDate(started_at) + INTERVAL 180 DAY;
```

### 3.4 Sandbox Activity Log

Track every sandbox create/destroy event per boss. This is the granular data needed for idle detection and activity metrics.

```sql
CREATE TABLE infra.boss_sandbox_events (
    event_id        UUID DEFAULT generateUUIDv4(),
    boss_id         String,
    cluster         LowCardinality(String),
    timestamp       DateTime64(3) DEFAULT now64(),
    action          Enum8(
        'create'    = 1,
        'destroy'   = 2,
        'exec'      = 3
    ),
    sandbox_name    String,
    sandbox_id      String,
    duration_ms     UInt32 DEFAULT 0,            -- for exec actions: duration of command
    exit_code       UInt8 DEFAULT 0              -- for exec actions: exit code
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), boss_id, action)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

---

## 4. Tracking Mechanisms

### 4.1 Lifecycle Event Emission (Inside kyb-infra-boss)

The boss container sends lifecycle events to CK on state transitions. Hook into Docker events (using the docker-event-watcher pattern from `docker-events.md`) specifically for the boss container itself:

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/boss-event-watcher.sh
# Runs inside kyb-infra-boss. Watches Docker events for THIS container
# and emits lifecycle events to central CK.

CK_URL="${CK_URL:-http://100.104.244.99:8123}"
CK_TABLE="infra.boss_lifecycle_events"
BOSS_ID="${BOSS_ID:-$(hostname)}"
CLUSTER="${CLUSTER_NAME:-unknown}"
CONTAINER_ID="$(hostname)"          # kyb containers share hostname with container ID
HOST_MACHINE="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
BOSS_VERSION="${KYB_VERSION:-unknown}"

# Read incarnation counter from a label or file
INCARNATION_FILE="/var/run/boss-incarnation"
if [ -f "$INCARNATION_FILE" ]; then
    INCARNATION=$(cat "$INCARNATION_FILE")
else
    INCARNATION=1
fi

# Listen to Docker events for the boss container itself
docker events \
  --filter "container=$CONTAINER_ID" \
  --filter 'event=die' \
  --filter 'event=stop' \
  --filter 'event=destroy' \
  --filter 'event=restart' \
  --format '{{json .}}' | while read -r event; do

    event_type=$(echo "$event" | jq -r '.Action')
    exit_code=$(echo "$event" | jq -r '.Actor.Attributes.exitCode // "0"')

    # Map Docker event type to our enum
    case "$event_type" in
        die)        our_event="crashed" ;;
        stop)       our_event="stopped" ;;
        destroy)    our_event="destroyed" ;;
        restart)    our_event="restarted" ;;
        *)          our_event="$event_type" ;;
    esac

    payload=$(jq -n --arg ec "$exit_code" --arg et "$event_type" \
        '{exit_code: $ec, docker_event: $et}')

    curl -s -X POST "$CK_URL" \
        -d "INSERT INTO $CK_TABLE FORMAT JSONEachRow {
            \"boss_id\": \"$BOSS_ID\",
            \"cluster\": \"$CLUSTER\",
            \"event_type\": \"$our_event\",
            \"boss_version\": \"$BOSS_VERSION\",
            \"host_machine\": \"$HOST_MACHINE\",
            \"container_id\": \"$CONTAINER_ID\",
            \"host_uptime\": $(cat /proc/uptime 2>/dev/null | cut -d. -f1 || echo 0),
            \"session_id\": $INCARNATION,
            \"payload\": $(printf '%s' "$payload" | jq -R -s '.')
        }" > /dev/null 2>&1

done
```

### 4.2 Heartbeat Enrichment (Modified Existing Loop)

Extend the existing heartbeat loop (from Section 2.4 of `multi-cluster-boss-architecture.md`) to include boss session metrics:

```bash
# Inside the heartbeat loop (runs every 60s):

# Calculate uptime from container start time
CONTAINER_STARTED=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_ID" 2>/dev/null)
if [ -n "$CONTAINER_STARTED" ]; then
    START_SEC=$(date -d "$CONTAINER_STARTED" +%s 2>/dev/null)
    NOW_SEC=$(date +%s)
    UPTIME_SEC=$((NOW_SEC - START_SEC))
else
    UPTIME_SEC=0
fi

# Count sandboxes (containers created by kyb, excluding infra containers)
SANDBOX_COUNT=$(kyb ps --quiet 2>/dev/null | wc -l)

# Find most recent sandbox activity from syslog or Docker inspect
# (Fallback: set to epoch if unknown)
LAST_SANDBOX_ACTIVITY=$(cat /var/run/boss-last-sandbox-activity 2>/dev/null || echo "1970-01-01 00:00:00")

# Read incarnation ID
INCARNATION=$(cat /var/run/boss-incarnation 2>/dev/null || echo 0)

# Extend the heartbeat POST:
curl -s -X POST "$CK_URL" \
    -d "INSERT INTO boss_heartbeats FORMAT JSONEachRow {
        \"boss_id\": \"$BOSS_ID\",
        \"cluster\": \"$CLUSTER\",
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"docker_running\": $(docker ps -q | wc -l),
        \"docker_total\": $(docker ps -aq | wc -l),
        \"disk_used_pct\": $(df / | tail -1 | awk '{print $5}' | tr -d '%'),
        \"mem_used_pct\": $(free | grep Mem | awk '{print $3/$2 * 100.0}' | cut -d. -f1),
        \"load_1m\": $(cat /proc/loadavg | cut -d' ' -f1),
        \"boss_uptime_seconds\": $UPTIME_SEC,
        \"sandbox_count\": $SANDBOX_COUNT,
        \"last_sandbox_activity\": \"$LAST_SANDBOX_ACTIVITY\",
        \"incarnation_id\": $INCARNATION
    }"
```

### 4.3 Sandbox Activity Tracking

To track sandbox create/destroy for idle detection, wrap `kyb create` and `kyb rm` so they write a timestamp before executing:

```bash
# In kyb create / kyb rm (or as a pre/post hook in bin/kyb):
KYB_LAST_ACTIVITY_FILE="/var/run/boss-last-sandbox-activity"
date -u +%Y-%m-%dT%H:%M:%S > "$KYB_LAST_ACTIVITY_FILE"

# Also emit to CK (async, non-blocking):
curl -s -X POST "$CK_URL" \
    -d "INSERT INTO infra.boss_sandbox_events FORMAT JSONEachRow {
        \"boss_id\": \"$BOSS_ID\",
        \"cluster\": \"$CLUSTER\",
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"action\": \"$ACTION\",
        \"sandbox_name\": \"$SANDBOX_NAME\",
        \"sandbox_id\": \"$SANDBOX_ID\"
    }" > /dev/null 2>&1 &
```

This does not block the create/rm command -- the curl is fire-and-forget.

---

## 5. Metrics and Dimensions

### 5.1 Boss Container Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `boss.containers.total` | gauge | `infra.boss_current` | Total boss containers registered (any state) |
| `boss.containers.alive` | gauge | `infra.boss_current WHERE current_state IN (created, started)` | Bosses currently running |
| `boss.containers.dead` | gauge | `infra.boss_current WHERE current_state IN (stopped, destroyed, crashed)` | Dead bosses with stale registration |
| `boss.uptime_seconds` | gauge | `boss_heartbeats.boss_uptime_seconds` | Current uptime of each boss |
| `boss.incarnation` | gauge | `boss_heartbeats.incarnation_id` | How many times this boss has restarted |

### 5.2 Session Duration Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `boss.session.duration_seconds` | histogram | `infra.boss_sessions` | Distribution of boss session lengths |
| `boss.session.max_seconds` | gauge | `infra.boss_sessions` | Longest completed session |
| `boss.session.count_total` | counter | `infra.boss_sessions` | Total sessions recorded (all bosses) |
| `boss.session.count_by_cluster` | gauge | `infra.boss_sessions` | Sessions per cluster |

### 5.3 Sandbox Activity Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `boss.sandbox.create_rate` | rate | `infra.boss_sandbox_events` | Sandbox create events per hour per boss |
| `boss.sandbox.destroy_rate` | rate | `infra.boss_sandbox_events` | Sandbox destroy events per hour per boss |
| `boss.sandbox.concurrent` | gauge | `boss_heartbeats.sandbox_count` | Current concurrent sandboxes managed by this boss |
| `boss.sandbox.total_created` | counter | `infra.boss_sessions` | Total sandboxes created during a boss session |

---

## 6. Idle Detection

### 6.1 Definition of "Idle"

A boss is idle when it has not performed any sandbox activity (create or destroy) within a configurable window. A boss that is running but has zero sandbox activity for hours is not contributing useful work.

This is distinct from "dead" (no heartbeat) and "stale" (heartbeating but container is in a bad state).

### 6.2 Idle Levels

| Level | Condition | Meaning | Action |
|-------|-----------|---------|--------|
| **Active** | Last activity < 1 hour ago | Boss is being used normally | None |
| **Quiet** | Last activity 1-4 hours ago | Boss may be between tasks | Note in patrol report |
| **Idle** | Last activity 4-24 hours ago | Boss is likely unused | Flag for review; suggest cleanup |
| **Abandoned** | Last activity > 24 hours ago | Boss is almost certainly abandoned | Recommend cleanup; escalate |

### 6.3 Idle Detection Query

```sql
-- Idle bosses: heartbeating but no recent sandbox activity
SELECT
    b.boss_id,
    b.cluster,
    b.boss_uptime_seconds,
    b.sandbox_count,
    b.last_sandbox_activity,
    dateDiff('hour', b.last_sandbox_activity, now()) AS idle_hours,
    multiIf(
        idle_hours > 24, 'abandoned',
        idle_hours > 4,  'idle',
        idle_hours > 1,  'quiet',
        'active'
    ) AS idle_level
FROM boss_heartbeats AS b
INNER JOIN (
    -- Most recent heartbeat per boss
    SELECT boss_id, max(timestamp) AS max_ts
    FROM boss_heartbeats
    WHERE timestamp > now() - INTERVAL 5 MINUTE
    GROUP BY boss_id
) AS latest ON b.boss_id = latest.boss_id AND b.timestamp = latest.max_ts
ORDER BY idle_hours DESC;
```

### 6.4 Heartbeat-Lost Detection

A boss that stops heartbeating for more than 5 minutes is "unreachable". This is tracked in a separate dimension because it means the boss may have crashed or lost network.

```sql
-- Dead bosses: last heartbeat older than threshold
SELECT
    boss_id,
    cluster,
    max(timestamp) AS last_heartbeat,
    dateDiff('minute', max(timestamp), now()) AS minutes_since_heartbeat,
    multiIf(
        minutes_since_heartbeat > 60, 'dead',
        minutes_since_heartbeat > 15, 'critical',
        minutes_since_heartbeat > 5,  'unreachable',
        'alive'
    ) AS status
FROM boss_heartbeats
GROUP BY boss_id, cluster
HAVING minutes_since_heartbeat > 5
ORDER BY minutes_since_heartbeat DESC;
```

### 6.5 Combined Boss Status (Lifecycle View)

```sql
-- Full status per boss: alive/dead/unreachable + active/idle/abandoned
SELECT
    COALESCE(lc.boss_id, hb.boss_id) AS boss_id,
    COALESCE(lc.cluster, hb.cluster) AS cluster,
    lc.current_state,
    lc.last_event_at AS last_lifecycle_event,
    hb.boss_uptime_seconds,
    hb.sandbox_count,
    hb.last_sandbox_activity,
    dateDiff('hour', hb.last_sandbox_activity, now()) AS idle_hours,
    hb.timestamp AS last_heartbeat,
    dateDiff('minute', hb.timestamp, now()) AS minutes_since_heartbeat,
    CASE
        WHEN hb.timestamp IS NULL
            OR dateDiff('minute', hb.timestamp, now()) > 60
            THEN 'dead'
        WHEN lc.current_state IN ('stopped', 'destroyed', 'crashed')
            THEN 'stopped'
        WHEN dateDiff('hour', hb.last_sandbox_activity, now()) > 24
            THEN 'abandoned'
        WHEN dateDiff('hour', hb.last_sandbox_activity, now()) > 4
            THEN 'idle'
        ELSE 'active'
    END AS boss_status
FROM infra.boss_current AS lc
FULL OUTER JOIN (
    SELECT boss_id, cluster, argMax(boss_uptime_seconds, timestamp) AS boss_uptime_seconds,
           argMax(sandbox_count, timestamp) AS sandbox_count,
           argMax(last_sandbox_activity, timestamp) AS last_sandbox_activity,
           max(timestamp) AS timestamp
    FROM boss_heartbeats
    GROUP BY boss_id, cluster
) AS hb ON lc.boss_id = hb.boss_id;
```

---

## 7. Auto-Cleanup Policy

### 7.1 Principles

1. **Never delete a boss container automatically** -- removing a boss container means stopping a machine's management layer. This is always a human decision.
2. **Do auto-cleanup registry state** -- when a boss is confirmed dead, update `clusters.yml` and clear stale entries from CK materialized views.
3. **Do auto-cleanup sandbox orphans** -- when a boss dies, its sandbox containers become orphans. If the host is unreachable for > 24 hours, flag for manual cleanup.

### 7.2 Cleanup Tiers

| Tier | Condition | Action | Automation |
|------|-----------|--------|------------|
| **T1: Stale registration** | Boss heartbeats missing > 60 min AND per-clusters.yml ACTIVE | Mark cluster state as UNREACHABLE in clusters.yml | Automated script (dry-run first) |
| **T2: Orphan sandbox** | Boss heartbeats missing > 24h AND host unreachable via SSH | List orphan sandboxes; do NOT auto-destroy | Alert for human review |
| **T3: Registration purge** | Boss heartbeats missing > 7 days AND manually confirmed dead | Remove from clusters.yml; archive CK events | Human decision required |

### 7.3 Cleanup Script

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/boss-cleanup.sh
# Identify and clean up stale boss registrations.
# Usage: boss-cleanup.sh [--dry-run] [--force]

DRY_RUN=true
if [ "$1" = "--force" ]; then
    DRY_RUN=false
elif [ "$1" = "--dry-run" ]; then
    DRY_RUN=true
fi

CK_URL="${CK_URL:-http://100.104.244.99:8123}"
CLUSTERS_YML="${CLUSTERS_YML:-$HOME/.config/kyb/clusters.yml}"

echo "=== Boss Cleanup Check ($(date -u)) ==="

# Find dead bosses (no heartbeat > 60 min)
DEAD_BOSSES=$(curl -s "$CK_URL?query=
    SELECT boss_id, cluster, max(timestamp) AS last_hb,
           dateDiff('minute', max(timestamp), now()) AS mins_ago
    FROM boss_heartbeats
    GROUP BY boss_id, cluster
    HAVING mins_ago > 60
    FORMAT PrettyCompact
")

if [ -z "$DEAD_BOSSES" ] || [ "$DEAD_BOSSES" = "0 rows in set" ]; then
    echo "No dead bosses found. All good."
    exit 0
fi

echo "Dead bosses detected:"
echo "$DEAD_BOSSES"

# For each dead boss, check if host is reachable via SSH
echo "$DEAD_BOSSES" | while read -r boss_id cluster last_hb mins_ago; do
    # Skip header rows
    [[ "$boss_id" == "boss_id" || "$boss_id" == "" || "$boss_id" == *"rows"* ]] && continue
    [[ "$cluster" == "cluster" || "$cluster" == "" ]] && continue

    # Look up SSH config from clusters.yml
    SSH_HOST=$(grep -A5 "cluster: $cluster" "$CLUSTERS_YML" 2>/dev/null \
               | grep 'ssh:' | head -1 | awk '{print $2}')
    HOST_MACHINE=$(grep -A5 "cluster: $cluster" "$CLUSTERS_YML" 2>/dev/null \
                   | grep 'host:' | head -1 | awk '{print $2}')

    if [ -n "$SSH_HOST" ]; then
        # Try to reach the host
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_HOST" \
               "docker ps --filter name=kyb-infra-boss --format '{{.Names}}'" 2>/dev/null | grep -q .; then
            echo "  $boss_id ($cluster): Host reachable, boss container may be restarting. Skipping."
            continue
        else
            echo "  $boss_id ($cluster): Host unreachable or no boss container found."
        fi
    else
        echo "  $boss_id ($cluster): No SSH config found in clusters.yml."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would mark $cluster as UNREACHABLE in clusters.yml"
        echo "  [DRY RUN] Would emit cleanup event to CK: boss_id=$boss_id event_type=cleanup"
    else
        echo "  [ACTION] Emitting cleanup event to CK..."
        curl -s -X POST "$CK_URL" \
            -d "INSERT INTO infra.boss_lifecycle_events FORMAT JSONEachRow {
                \"boss_id\": \"$boss_id\",
                \"cluster\": \"$cluster\",
                \"event_type\": \"cleanup\",
                \"host_machine\": \"$HOST_MACHINE\",
                \"container_id\": \"unknown\",
                \"session_id\": 0,
                \"payload\": \"{\\\"reason\\\": \\\"heartbeat_lost_\\$(date -u +%Y-%m-%dT%H:%M:%SZ)\\\"}\"
            }" > /dev/null 2>&1

        # Mark cluster as UNREACHABLE (comment out in clusters.yml)
        echo "  Marking $cluster as UNREACHABLE in $CLUSTERS_YML (not implemented: manual edit required)"
    fi
done
```

### 7.4 Cleanup Schedule

| Action | Cadence | Trigger |
|--------|---------|---------|
| Check for dead bosses | Every patrol cycle (5 min) | Patrol prompt |
| Mark unreachable clusters | After 60 min without heartbeat | Manual or semi-automated |
| Archive stale events | Daily (cron) | Cron job on super-boss |
| Purge old records | > 90 days | ClickHouse TTL (automatic) |

---

## 8. Incarnation Tracking

Boss restart detection is handled via a simple incarnation counter file inside the boss container:

```bash
# /var/run/boss-incarnation — written by entrypoint.sh or a kyb lifecycle hook
# On first container start: value = 1
# After container restart: previous value may be lost (ephemeral /var/run)
# But /var/run is tmpfs, so on restart it resets to 1 anyway.
```

However, `/var/run` is tmpfs and resets on restart. To persist incarnation across restarts, use a Docker label:

```bash
# On first create: label the container
docker label kyb-infra-boss kyb.incarnation=1

# After restart detection (by the heartbeat enrichment):
CURRENT_INCARNATION=$(docker inspect --format '{{index .Config.Labels "kyb.incarnation"}}' \
    "$CONTAINER_ID" 2>/dev/null || echo 0)

if [ "$CURRENT_INCARNATION" -eq 0 ]; then
    # New container without label — set to 1
    docker label "$CONTAINER_ID" "kyb.incarnation=1"
else
    # Check if uptime is less than the last known uptime from heartbeat
    # (means container was restarted)
    PREVIOUS_UPTIME=$(curl -s "$CK_URL?query=
        SELECT argMax(boss_uptime_seconds, timestamp)
        FROM boss_heartbeats
        WHERE boss_id='$BOSS_ID'
        FORMAT TabSeparated" 2>/dev/null | head -1)

    if [ -n "$PREVIOUS_UPTIME" ] && [ "$PREVIOUS_UPTIME" -gt "$UPTIME_SEC" ] && [ "$UPTIME_SEC" -lt 120 ]; then
        # Uptime reset — container was restarted
        NEW_INCARNATION=$((CURRENT_INCARNATION + 1))
        docker label "$CONTAINER_ID" "kyb.incarnation=$NEW_INCARNATION"

        # Emit restart event
        curl -s -X POST "$CK_URL" \
            -d "INSERT INTO infra.boss_lifecycle_events FORMAT JSONEachRow { ... event_type='started' ... }"
    fi
fi
```

Practical simplification: since boss containers are created via `kyb create`, which sets labels, the incarnation can be initialized at creation time. Restart detection is then: heartbeat uptime resets to a low value after having been high. No need for a persistent counter -- the lifecycle events table tracks the sequence.

---

## 9. Grafana Dashboard

### Layout

```
Row: "Boss Status Overview"
  ├── Stat: Total Bosses (count of distinct boss_id with heartbeat < 5 min)
  ├── Stat: Alive + Active (green)
  ├── Stat: Alive + Idle (yellow)
  ├── Stat: Dead / Unreachable (red)
  └── Stat: Abandoned (red, blinking if > 0)

Row: "Boss Details"
  ├── Table: All Bosses (boss_id, cluster, status, uptime, sandbox_count, idle_hours, last_heartbeat)
  │   Color rows by status: green=active, yellow=idle, red=dead/abandoned
  └── Table: Dead/Unreachable Bosses (for cleanup action)

Row: "Sessions Timeline"
  ├── Time Series: Boss Sessions Over Time (stacked: each boss_id a line, event_type as color)
  ├── Time Series: Sandbox Count Over Time (per boss, 24h)
  └── Time Series: Uptime Seconds (per boss, 7d, step function that resets on restart)

Row: "Session Duration Distribution"
  ├── Histogram: Session Durations (bins: <1h, 1-6h, 6-24h, 1-7d, 7-30d, >30d)
  └── Stat: Longest Current Session (boss_id + duration)

Row: "Activity Heatmap"
  └── Heatmap: Sandbox Creates per Hour (x=hour of day, y=day of week, value=count)
```

### Key Grafana Queries

**Alive boss count:**
```sql
SELECT count(DISTINCT boss_id) AS alive_bosses
FROM boss_heartbeats
WHERE timestamp > now() - INTERVAL 5 MINUTE;
```

**Active vs idle breakdown:**
```sql
WITH latest_hb AS (
    SELECT boss_id, cluster,
           argMax(sandbox_count, timestamp) AS sandbox_count,
           argMax(last_sandbox_activity, timestamp) AS last_activity,
           argMax(boss_uptime_seconds, timestamp) AS uptime_sec,
           max(timestamp) AS last_hb
    FROM boss_heartbeats
    WHERE timestamp > now() - INTERVAL 5 MINUTE
    GROUP BY boss_id, cluster
)
SELECT
    CASE
        WHEN dateDiff('hour', last_activity, now()) > 24 THEN 'abandoned'
        WHEN dateDiff('hour', last_activity, now()) > 4  THEN 'idle'
        ELSE 'active'
    END AS status,
    count() AS count
FROM latest_hb
GROUP BY status;
```

**Session duration (current running sessions):**
```sql
SELECT
    boss_id,
    cluster,
    boss_uptime_seconds,
    floor(boss_uptime_seconds / 3600) AS uptime_hours,
    sandbox_count,
    last_sandbox_activity
FROM boss_heartbeats
WHERE timestamp IN (
    SELECT max(timestamp) FROM boss_heartbeats
    WHERE timestamp > now() - INTERVAL 5 MINUTE
    GROUP BY boss_id
)
ORDER BY boss_uptime_seconds DESC;
```

---

## 10. Alert Thresholds

| Rule | Condition | Level | Action |
|------|-----------|-------|--------|
| **BossDead** | Any boss stops heartbeating for > 15 min | P2 | Notify; check host connectivity |
| **BossCrashed** | `event_type = 'crashed'` in `boss_lifecycle_events` | P1 | Critical: management layer down; investigate immediately |
| **BossAbandoned** | `idle_hours > 24` AND `sandbox_count = 0` | P3 | Flag for review; suggest boss rm |
| **BossRestartLoop** | > 3 lifecycle events (crashed/started) within 1 hour | P2 | Boss may be in crash loop; check Docker logs |
| **TooManyIdle** | > 50% of bosses idle for > 4 hours | P3 | Investigate: is work pipeline stalled? |
| **OrphanSandbox** | Boss dead > 24h AND host has running sandbox containers | P2 | Orphan sandboxes consuming resources |
| **IncarnationSpike** | `incarnation_id` jumps by > 3 in 1 hour for same boss | P2 | Boss repeatedly restarting; flag for investigation |

---

## 11. Alert Actions

| Alert | Notification Destination | Remediation |
|-------|-------------------------|-------------|
| BossDead | Feishu (immediate) + Grafana alert | SSH into host, check Docker daemon, restart boss |
| BossCrashed | Feishu (immediate) | `docker logs kyb-infra-boss --tail 100`; investigate exit code |
| BossAbandoned | Patrol digest (next cycle) | `kyb rm <boss>` if no longer needed; or mark as intentionally dormant |
| BossRestartLoop | Feishu (immediate) | Check host resources (disk, memory); check Docker daemon health |
| TooManyIdle | Patrol digest (daily) | Review workload distribution; consider consolidating clusters |
| OrphanSandbox | Feishu (with list) | SSH into host, `kyb ps`, `kyb prune`; or manually `docker rm` |

---

## 12. Implementation Plan

### Phase 1: Heartbeat Enrichment (< 1 hour)

1. Add `boss_uptime_seconds`, `sandbox_count`, `last_sandbox_activity`, `incarnation_id` columns to `boss_heartbeats` (ALTER TABLE).
2. Update the heartbeat loop script on each boss to emit the new fields.
3. Verify in Grafana: new columns appear in `boss_heartbeats` table.

### Phase 2: Lifecycle Events (< 2 hours)

1. Create `infra.boss_lifecycle_events`, `infra.boss_current`, `infra.boss_sessions`, `infra.boss_sandbox_events` tables in CK.
2. Deploy `boss-event-watcher.sh` inside each boss container.
3. Verify events are flowing on `docker restart kyb-infra-boss` (simulate a restart).

### Phase 3: Grafana Dashboard (< 1 hour)

1. Build the dashboard following Section 9 layout.
2. Configure alerts from Section 10.
3. Verify alert fires on a test event.

### Phase 4: Cleanup Script (< 1 hour)

1. Deploy `boss-cleanup.sh` on the super-boss (Mac/Orbstack).
2. Integrate into the patrol cycle (run dry-run every patrol).
3. Train human operator on manual confirmation step.

---

## 13. Operational Notes

### Boss Restart Detection Reliability

The incarnation counter via Docker labels is a best-effort mechanism. Scenarios where it may fail:

- **Host reboot**: Docker daemon restarts, all containers become "new" with the same labels. Incarnation counter survives (label persisted) but container uptime resets. The uptime-reset detection handles this: if `PREVIOUS_UPTIME > UPTIME_SEC` (meaning the heartbeat was previously running for hours, now it shows seconds), it infers a restart.
- **Docker daemon crash**: Containers survive (Docker usually preserves them), but events during daemon downtime are lost. The watcher misses the `stop` event. This is acceptable: the next heartbeat will show uptime dropping.
- **`docker rm -f` + `kyb create`**: New container, no label, incarnation counter starts at 1. This is correct behavior (wiped and recreated).

### Side Effects

- The sandbox activity tracking adds a fire-and-forget curl per `kyb create/destroy`. At current volume (~50 creates/day), this is negligible (< 0.01% of boss container CPU).
- The heartbeat enrichment uses `docker inspect` and `kyb ps`, which are already available inside the boss container (Docker socket is mounted). No new dependencies.
- The lifecycle event watcher uses `docker events`, which is also already available. It runs as a background process inside the boss container.

### When To Skip Auto-Cleanup

- **Single-boss deployments**: If only one boss exists (e.g., home lab with just a NUC), auto-cleanup should not mark it unreachable -- there is no redundancy. Add a `single_boss: true` flag to clusters.yml to suppress auto-cleanup.
- **Intentional downtime**: A boss may be intentionally stopped (e.g., host maintenance). The operator should update clusters.yml to mark it as MAINTENANCE before stopping.
- **Network partition**: If the super-boss itself loses connectivity (e.g., Mac goes to sleep), heartbeats from remote bosses will appear "dead" to the super-boss. The cleanup script should verify host reachability via SSH before taking action (as implemented in Section 7.3).

---

## 14. References

- Boss architecture: `docs/infra/multi-cluster-boss-architecture.md`
- Docker event monitoring: `docs/infra/reviews/docker-events.md`
- Session monitor (cc-connect): `docs/infra/reviews/session-monitor.md`
- Observability design: `docs/infra/observability-design.md`
- Patrol guide: `docs/infra/5min-patrol-guide.md`
- Heartbeat system: Section 2.4 of `multi-cluster-boss-architecture.md`
