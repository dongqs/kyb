---
decision: 稍后做
---

# Design: Docker Event Monitoring for Infra Containers

**Design doc**: `docs/infra/reviews/docker-events.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Infra container lifecycle tracking, ClickHouse ingestion, alert triggers

---

## Summary

Currently, infra container lifecycle events (crashes, restarts, health failures) are invisible unless someone happens to run `docker ps` during a patrol. There is no historical record of when a container died, restarted, or became unhealthy. This design fills that gap by subscribing to the Docker event stream inside each `kyb-infra-boss` container and forwarding relevant events to the central ClickHouse for analysis and alerting.

---

## Architecture

### Data Flow

```
Docker Engine (local to each cluster)
    │  (unix:///var/run/docker.sock)
    ▼
docker-event-watcher (lightweight shell/Python daemon inside kyb-infra-boss)
    │  (HTTP POST to central CK:8123)
    ▼
ClickHouse (infra.docker_events)  ← on Mac/Orbstack (super-boss)
    │
    ├── Grafana dashboard (events timeline, health transitions)
    └── Patrol / alert system (unexpected stop/destroy alerts)
```

### Where It Runs

The watcher runs **inside each `kyb-infra-boss` container** (Mac/Orbstack, Aliyun, Office -- every cluster). This is zero new infrastructure: the boss container already has:

- `/var/run/docker.sock` mounted (manages local containers)
- Outbound HTTP access to central CK (`100.104.244.99:8123`)
- `bash` + `curl` + `docker` CLI (all available in the kyb base image)
- Restart policy (`--restart=unless-stopped`), so the watcher survives boss restarts

### Watcher Implementation

Lightweight shell script is sufficient -- no binary needed. Docker events are already JSON, and ClickHouse accepts JSONEachRow via HTTP.

```bash
#!/usr/bin/env bash
# docker-event-watcher.sh — runs inside kyb-infra-boss
# Subscribes to Docker events, filters for infra containers,
# and POSTs normalized records to central ClickHouse.

CK_URL="http://100.104.244.99:8123"
CK_TABLE="infra.docker_events"
BOSS_ID="$(hostname)"
CLUSTER="${CLUSTER_NAME:-unknown}"  # set per-boss: mac-orbstack|aliyun|office

docker events \
  --filter 'type=container' \
  --filter 'event=create' \
  --filter 'event=start' \
  --filter 'event=die' \
  --filter 'event=destroy' \
  --filter 'event=restart' \
  --filter 'event=pause' \
  --filter 'event=unpause' \
  --filter 'event=oom' \
  --filter 'event=health_status' \
  --format '{{ json . }}' \
| while read -r line; do
    # Echo the raw event to stdout (container logs) for debugging
    echo "$line"

    # Extract fields from Docker's JSON event format.
    # Docker events: https://docs.docker.com/engine/api/sdk/examples/#docker-events
    event_type=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('Type','')+':'+e.get('Action',''))" 2>/dev/null)
    container_name=$(echo "$line" | python3 -c "
import sys,json
e=json.load(sys.stdin)
actor=e.get('Actor',{})
attrs=actor.get('Attributes',{})
# Docker names have leading slash
name=attrs.get('name', actor.get('ID','')[:12])
print(name)
" 2>/dev/null)
    actor_id=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('Actor',{}).get('ID',''))" 2>/dev/null)
    image=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('Actor',{}).get('Attributes',{}).get('image',''))" 2>/dev/null)
    exit_code=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('Actor',{}).get('Attributes',{}).get('exitCode',''))" 2>/dev/null)
    health_status=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); a=e.get('Actor',{}).get('Attributes',{}); print(a.get('health_status',''))" 2>/dev/null)
    timestamp=$(echo "$line" | python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('time',int(__import__('time').time())))" 2>/dev/null)

    # Convert Unix timestamp to CK DateTime64(3)
    event_time=$(python3 -c "from datetime import datetime; print(datetime.utcfromtimestamp($timestamp).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" 2>/dev/null)

    # Build JSON payload for CK
    payload=$(python3 -c "
import json, sys
p = {
    'boss_id': '$BOSS_ID',
    'cluster': '$CLUSTER',
    'event_time': '$event_time',
    'event_type': '$event_type',
    'container_name': '$container_name',
    'actor_id': '$actor_id',
    'image': '$image',
    'exit_code': ${exit_code:-0},
    'health_status': '$health_status',
    'raw_json': '''$(echo "$line" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))")'''
}
print(json.dumps(p))
" 2>/dev/null)

    # Skip non-infra containers based on name prefix
    case "$container_name" in
        kyb-infra-*|kyb-registry-*|kyb-ubuntu-test|bold_almeida)
            # Infra container — proceed
            ;;
        *)
            # Skip user/sandbox containers
            continue
            ;;
    esac

    # Send to CK (best-effort, fire-and-forget)
    curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_TABLE+FORMAT+JSONEachRow" \
      -d "$payload" \
      --max-time 5 2>/dev/null || echo "[WARN] CK write failed for $event_type on $container_name"
done
```

### Infra Container Filtering

The watcher tracks containers whose name starts with `kyb-infra-` or `kyb-registry-`. Additionally, bare test containers (`kyb-ubuntu-test`, `bold_almeida`) are included because they are long-running test services.

Current infra container fleet (from `docker ps`):

| Container | Image | Health |
|-----------|-------|--------|
| `kyb-infra-boss` | kyb-base | no health check |
| `kyb-infra-boss2` | kyb-infra-boss-snapshot | no health check |
| `kyb-infra-boss3` | kyb-base | no health check |
| `kyb-infra-boss-fallback` | 7cb4dba... | no health check |
| `kyb-infra-cc-connect` | kyb-cc-connect | healthy |
| `kyb-infra-clickhouse` | clickhouse/clickhouse-server:24.2-alpine | no health check |
| `kyb-infra-grafana` | grafana/grafana | no health check |
| `kyb-infra-kafka` | apache/kafka | no health check |
| `kyb-infra-postgresql-14` | postgres:14-alpine | no health check |
| `kyb-infra-postgresql-15` | postgres:15-alpine | no health check |
| `kyb-infra-postgresql-16` | postgres:16-alpine | no health check |
| `kyb-infra-postgresql-17` | postgres:17-alpine | no health check |
| `kyb-infra-redis` | redis:7-alpine | no health check |
| `kyb-infra-sing-box` | kyb-sing-box:1.13.11 | no health check |
| `kyb-registry-cache` | registry:2 | no health check |
| `kyb-ubuntu-test` | ubuntu:24.04 | no health check |
| `bold_almeida` | bcac519... | **unhealthy** |

Key observation: Only `kyb-infra-cc-connect` has a Docker HEALTHCHECK defined. All other containers lack health monitoring entirely. Adding Docker HEALTHCHECK to critical containers (PG, Redis, Kafka, ClickHouse, Grafana) dramatically increases the value of event monitoring -- `health_status` events would then fire on real failures.

---

## Event Types

### Captured Events

| Docker event | CK `event_type` | Trigger | Significance |
|---|---|---|---|
| `container:create` | `container:create` | Container created | Infra deployment event |
| `container:start` | `container:start` | Container started | Normal start after create, or recovery |
| `container:die` | `container:die` | Container stopped/exited | **Unexpected stop = possible crash** |
| `container:destroy` | `container:destroy` | Container removed | Teardown (intentional or accidental) |
| `container:restart` | `container:restart` | Container restarted | Usually a crash + auto-restart cycle |
| `container:pause` | `container:pause` | Process paused | Suspension event |
| `container:unpause` | `container:unpause` | Process resumed | Recovery from pause |
| `container:oom` | `container:oom` | **Out of memory killed** | Critical -- container was OOM-killed |
| `container:health_status: healthy` | `container:health_status` | Health check passed | Normal |
| `container:health_status: unhealthy` | `container:health_status` | **Health check failed** | Service is degraded |

### Key Signal: `die` + `exitCode`

The most actionable event is `container:die` with a non-zero exit code. This sequence indicates:

1. Container exited abnormally (exit code != 0 → crash / error)
2. Docker `--restart=unless-stopped` will restart it (creates a `start` event shortly after)
3. A `die` followed by `start` within 5 seconds = auto-restart cycle
4. A `die` with exit code 0 = intentional stop (manual, or graceful shutdown)

Anomaly detection rule: **3 or more `die`+`restart` cycles within 5 minutes = crash loop. Alert P1.**

### Key Signal: `health_status: unhealthy`

Only emitted for containers with a Docker HEALTHCHECK. Currently only `kyb-infra-cc-connect` has one. If HEALTHCHECK is added to other containers:

- `unhealthy` followed by `healthy` = transient glitch (normal)
- `unhealthy` sustained for >30 seconds = service degradation (P2 alert)
- Repeated `healthy` ↔ `unhealthy` oscillations = flapping (P1 alert)

### Key Signal: `oom`

OOM events are always critical. Docker fires `oom` as a separate event (not just `die` with exit code 137). CK schema includes an `oom_killed` boolean for easy filtering.

---

## ClickHouse Schema

```sql
CREATE DATABASE IF NOT EXISTS infra;

CREATE TABLE infra.docker_events (
    -- Identity
    boss_id         LowCardinality(String),       -- hostname of the boss container
    cluster         LowCardinality(String),       -- mac-orbstack | aliyun | office

    -- Event metadata
    event_time      DateTime64(3),                -- when the Docker event fired
    event_type      LowCardinality(String),       -- container:die, container:start, etc.

    -- Container details
    container_name  String,                       -- kyb-infra-cc-connect, etc.
    actor_id        String,                       -- Docker container ID (sha256 prefix)
    image           String,                       -- kyb-cc-connect:latest, etc.

    -- Event payload
    exit_code       UInt8 DEFAULT 0,              -- non-zero = abnormal exit
    health_status   String DEFAULT '',            -- 'healthy' | 'unhealthy' | ''
    oom_killed      UInt8 DEFAULT 0,              -- 1 if Docker oom event fired
    restart_count   UInt16 DEFAULT 0,             -- cumulative restart count (from Docker inspect)

    -- Raw event (for forensic debugging)
    raw_json        String DEFAULT '',

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, boss_id, event_type)
TTL event_time + INTERVAL 90 DAY;
```

### Design Decisions

1. **Sorting key `(event_time, boss_id, event_type)`**: Covers the two most common query patterns: time-range scans ("what happened in the last hour?") and per-cluster filtered time series ("show Mac events for the last 7 days").

2. **LowCardinality for `boss_id`, `cluster`, `event_type`**: Few distinct values (3 clusters, ~4 boss instances, ~10 event types). LowCardinality gives ~8-10x compression on these columns.

3. **TTL 90 days**: Matches the `cc.message_log` retention policy. Event volume is tiny (~100 events/day per cluster), so storage is negligible even without TTL.

4. **`_ingested_at` separate from `event_time`**: The event_time is when the Docker event fired (source clock). `_ingested_at` is when CK received it. The gap between them measures pipeline latency.

### Estimated Volume

| Item | Value |
|------|-------|
| Events per container per day | ~2-5 (create once, die on restart, health_status every 30s for healthy containers) |
| Infra containers per cluster | ~16 (current Mac fleet) |
| Raw daily events | ~16 containers * ~3 events/day average = ~50 events/day |
| On HEALTHCHECK rollout | ~16 containers * ~2880 health events/day = ~46k events/day (at 30s interval) |
| Storage per event | ~400 bytes (compressed ~80 bytes) |
| Without HEALTHCHECK | ~50 events/day * 90 days * 80 bytes = ~360 KB |
| With full HEALTHCHECK | ~46k events/day * 90 days * 80 bytes = ~331 MB |

Even with full HEALTHCHECK on all containers, 331 MB over 90 days is negligible for ClickHouse. For the initial deployment (no HEALTHCHECK on most containers), volume is under 1 MB.

---

## Deployment

### Per-Boss Setup Script

Each boss (Mac/Orbstack, Aliyun, Office) runs the same setup:

```bash
# Inside the kyb-infra-boss container:
# 1. Write the watcher script
cat > /usr/local/bin/docker-event-watcher.sh << 'SCRIPT'
#!/usr/bin/env bash
# [paste the full watcher script from above]
SCRIPT
chmod +x /usr/local/bin/docker-event-watcher.sh

# 2. Create the CK table (run once on super-boss CK)
#    Execute from Mac/Orbstack:
docker exec kyb-infra-boss bash -c "
  curl -s -X POST http://host.docker.internal:8123 \
    -d 'CREATE DATABASE IF NOT EXISTS infra'
  curl -s -X POST http://host.docker.internal:8123 \
    -d '$(cat docs/infra/reviews/docker-events.md | sed -n '/^```sql/,/^```/p' | head -n -1 | tail -n +2)'
"

# 3. Start the watcher in background (survives boss restart)
nohup /usr/local/bin/docker-event-watcher.sh \
  > /var/log/docker-event-watcher.log 2>&1 &

# 4. Add to boss startup for persistence across reboots
echo '/usr/local/bin/docker-event-watcher.sh > /var/log/docker-event-watcher.log 2>&1 &' \
  >> /home/dev/.bashrc
```

### Boss Startup Integration

Rather than relying on `.bashrc` (fragile -- only runs for interactive shells), the watcher should be started as part of the boss container's entrypoint. For kyb-managed containers, this means adding a `--init` flag or a startup hook in `entrypoint.sh`.

Current approach (sufficient for now): add a systemd-like one-shot via `docker exec` from the super-boss patrol cycle, or integrate into the existing heartbeat loop:

```bash
# Start event watcher alongside heartbeat (idempotent)
pgrep -f docker-event-watcher >/dev/null 2>&1 || (
  nohup /usr/local/bin/docker-event-watcher.sh \
    > /var/log/docker-event-watcher.log 2>&1 &
)
```

### Idempotent Start via Cron

The 5-minute patrol already runs on each boss. Add to the patrol checklist:

```bash
# In patrol script:
# Ensure docker-event-watcher is running
pgrep -f docker-event-watcher > /dev/null || {
  logger "[PATROL] docker-event-watcher not running, restarting"
  nohup /usr/local/bin/docker-event-watcher.sh \
    > /var/log/docker-event-watcher.log 2>&1 &
}
```

---

## Query Examples

### Last 10 events across all clusters

```sql
SELECT event_time, cluster, event_type, container_name, exit_code, health_status
FROM infra.docker_events
ORDER BY event_time DESC
LIMIT 10;
```

### Containers that crashed in the last 24h

```sql
SELECT container_name, count() AS crash_count
FROM infra.docker_events
WHERE event_type = 'container:die'
  AND exit_code > 0
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY container_name
ORDER BY crash_count DESC;
```

### Health status transitions for a specific container

```sql
SELECT event_time, health_status
FROM infra.docker_events
WHERE container_name = 'kyb-infra-cc-connect'
  AND event_type = 'container:health_status'
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time;
```

### Crash loop detection (3+ die in 5 minutes)

```sql
SELECT cluster, container_name, count() AS deaths,
       min(event_time) AS first_death, max(event_time) AS last_death
FROM infra.docker_events
WHERE event_type = 'container:die'
  AND exit_code > 0
  AND event_time >= now() - INTERVAL 5 MINUTE
GROUP BY cluster, container_name
HAVING deaths >= 3;
```

### OOM events (critical)

```sql
SELECT event_time, cluster, container_name, image
FROM infra.docker_events
WHERE oom_killed = 1
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;
```

### Containers restart frequency (rolling 7-day window)

```sql
SELECT cluster, container_name,
       countIf(event_type = 'container:restart') AS restarts,
       countIf(event_type = 'container:die' AND exit_code > 0) AS crashes,
       countIf(event_type = 'container:die' AND exit_code = 0) AS graceful_stops
FROM infra.docker_events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY cluster, container_name
ORDER BY restarts DESC;
```

---

## Grafana Dashboard

Recommended panels for a `Docker Events` dashboard:

### 1. Event Timeline (Time Series)
- Metric: `count()` grouped by `event_type`
- Granularity: 5 minutes
- Filter: exclude `health_status` (too noisy when HEALTHCHECK is deployed on all containers)
- Purpose: visual overview of cluster activity

### 2. Recent Crashes (Table)
- Columns: time, cluster, container_name, exit_code, image
- Filter: `event_type = 'container:die' AND exit_code > 0`
- Sort: descending time, limit 50
- Purpose: immediate visibility into failures

### 3. Crash Count by Container (Bar Chart)
- Metric: `count()` per `container_name`
- Filter: same as above, last 24h
- Purpose: identify the most crash-prone containers

### 4. Health Status Changes (Time Series)
- Metric: `count()` by `health_status` (healthy vs unhealthy)
- Filter: `event_type = 'container:health_status'`
- Granularity: 1 minute
- Purpose: detect health oscillations (flapping)

### 5. OOM Watch (Single Stat)
- Metric: `countIf(oom_killed = 1)` in last 7 days
- Threshold: > 0 = RED
- Purpose: zero-tolerance OOM monitor

### 6. Restart Cycle Detection (Table)
- Columns: cluster, container_name, restarts_in_5m
- Query: crash loop detection query above
- Purpose: catch crash loops early

---

## Alert Rules

| Rule | Conditions | Severity | Response |
|------|-----------|----------|----------|
| Crash loop | 3+ non-zero die events in 5min for same container | P1 | Feishu alert: "${container} crash loop on ${cluster}, exit_code=${code}" |
| OOM kill | `oom_killed = 1` | P1 | Feishu alert: "${container} OOM-killed on ${cluster}" |
| Health failure | `health_status: unhealthy` sustained > 30s | P2 | Feishu: "${container} unhealthy on ${cluster}" |
| Unexpected destroy | `container:destroy` on infra container | P2 | Feishu: "${container} destroyed on ${cluster} — investigate" |
| Event pipeline down | No events from a boss in > 5 minutes | P2 | Feishu: "No Docker events from ${cluster} — event watcher may be down" |

---

## Recommendations

### P0 — Deploy watcher to all bosses
The watcher script should be deployed to every `kyb-infra-boss` container. Priority: Mac/Orbstack (already has CK), then Aliyun, then Office.

### P0 — Create CK table before deployment
The `infra.docker_events` table must exist before the watcher starts writing. Run the CREATE TABLE once from the super-boss.

### P1 — Add Docker HEALTHCHECK to critical infra containers
Currently only `kyb-infra-cc-connect` has a health check. Adding HEALTHCHECK to postgres, redis, clickhouse, grafana, kafka, and sing-box enables `health_status` events which are the most valuable signal for degradation detection.

Suggested HEALTHCHECK additions to `docker run` or container definitions:

```bash
# PostgreSQL
docker run --health-cmd='pg_isready -U postgres' --health-interval=15s --health-timeout=5s --health-retries=3 ...

# Redis
docker run --health-cmd='redis-cli ping' --health-interval=15s --health-timeout=5s --health-retries=3 ...

# ClickHouse
docker run --health-cmd='clickhouse-client --query "SELECT 1"' --health-interval=15s --health-timeout=5s --health-retries=3 ...

# Grafana
docker run --health-cmd='wget -qO- http://localhost:3000/api/health' --health-interval=30s --health-timeout=10s --health-retries=3 ...
```

### P1 — Add Grafana dashboard
Create a Docker Events dashboard (panels 1-6 above) connected to the `infra.docker_events` ClickHouse data source.

### P2 — Integrate crash loop alert into patrol
The 5-minute patrol script should query the crash loop detection SQL and alert via Feishu if any crash loops are detected.

### P2 — Add restart_count to events
The watcher script should capture the container's current `restart_count` from `docker inspect` at event time. This allows tracking how many times Docker's restart policy has triggered.

### P2 — Monitor watcher health via heartbeat correlation
The existing `boss_heartbeats` table records `docker_running` and `docker_total`. If the watcher is working, the events table should show activity. Cross-reference: if `boss_heartbeats` is active but no events for 10+ minutes, the watcher may be stuck. This can be a Grafana alert.

---

## Verdict

**Design is sound and ready for implementation.** The architecture is zero-infrastructure (reuses existing boss containers and CK), the data model is minimal but covers all actionable event types, and the volume is negligible. The highest-value follow-up is adding Docker HEALTHCHECK to all infra containers -- without it, the watcher can only detect crashes, not degradations.

Key implementation steps:
1. Run CREATE TABLE on central CK
2. Deploy watcher script to Mac/Orbstack boss
3. Validate events appearing in CK
4. Deploy to Aliyun and Office bosses
5. Add HEALTHCHECK to critical infra containers
6. Build Grafana dashboard
7. Wire crash-loop alert into patrol

> ／人◕ ‿‿ ◕人＼
