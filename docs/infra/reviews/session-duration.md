---
decision: 稍后做
---

# Session Duration Monitoring — Design

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/observability-design.md` (overall observability strategy),
`docs/infra/reviews/otel-mcp.md` (tracing patterns),
`docs/infra/5min-patrol-guide.md` (heartbeat/patrol context).

---

## 1. Problem

kyb containers host AI coding agents (Claude Code). Each container has a lifecycle —
created, started, stopped, removed — and within that lifecycle, agents run sessions
(conversation turns, task dispatches, tool calls). Currently the system has:

| What | Status |
|------|--------|
| Container lifecycle events | Tracked via `Kyb::Reporter` (emit: create, start, exec, dispatch, complete, rm) |
| Heartbeats | Periodic `emit_heartbeat` with container count, disk, mem |
| Session table | ClickHouse `sessions` table exists but **underutilized** — records create/destroy only, no intermediate states |
| Cold start vs resume | **Not tracked** — no way to distinguish `kyb create` from `kyb start` on a stopped container |
| Idle timeout | **Not tracked** — no definition of "idle", no detection |
| Agent hierarchy | **Not tracked** — boss dispatches sub-agents, each with independent session, but no parent-child session relationship |

The result: operators cannot answer basic questions:

- How long does the average agent session last?
- How many sessions end via idle timeout vs. explicit completion?
- What fraction of container startups are cold starts (from scratch) vs. warm resumes (restarting a stopped container)?
- How does agent session length correlate with task complexity (dispatch depth)?
- How often do agents sit idle before being killed?

---

## 2. High-Level Architecture

```
kyb CLI                  kyb container (Claude Code agent)
    │                             │
    │  emit_container_create      │
    │  emit_container_rm          │  emit_session_start
    │  emit_session_create        │  emit_session_complete
    │  emit_session_destroy       │  emit_task_start / emit_task_end
    │                             │  emit_heartbeat
    │                             │  emit_idle / emit_resume
    ▼                             ▼
┌──────────────────────────────────────────────┐
│           ClickHouse (kyb database)           │
│                                               │
│  ┌────────────┐  ┌─────────────────────┐     │
│  │  metrics   │  │  sessions (extended) │     │
│  │  (events)  │  │  + session_events    │     │
│  └────────────┘  └─────────────────────┘     │
│                                               │
│  ┌─────────────────────────────────────┐     │
│  │  Grafana (dashboards + alerts)       │     │
│  └─────────────────────────────────────┘     │
└──────────────────────────────────────────────┘
```

### Components

| Component | Role |
|-----------|------|
| **kyb CLI** | Emits container lifecycle events (create/rm) with **provenance** (cold vs resume) |
| **Agent** | Emits session lifecycle events (start/complete/task/heartbeat/idle) from within the container |
| **Reporter** | Existing `Kyb::Reporter` module — extended to emit new event types and enriched session records |
| **ClickHouse** | Storage — existing `metrics` table for events, extended `sessions` table for stateful session tracking |
| **Grafana** | Dashboards for session duration distributions, idle timeout rates, cold start ratios |

---

## 3. Session Lifecycle States

```
                    ┌─────────────┐
                    │  CONTAINER  │
                    │  CREATED    │
                    └──────┬──────┘
                           │ kyb create
                           ▼
                    ┌─────────────┐
              ┌────►│  CONTAINER  │◄────┐
              │     │  STARTED    │     │
              │     └──────┬──────┘     │
              │            │            │
              │      agent boot         │ kyb start (resume)
              │            │            │
              │            ▼            │
              │     ┌─────────────┐     │
              │     │  SESSION    │     │
              │     │  ACTIVE     │     │
              │     └──────┬──────┘     │
              │            │            │
              │     ┌──────┴──────┐     │
              │     │             │     │
              │     ▼             ▼     │
              │  ┌────────┐  ┌────────┐│
              │  │ TASK   │  │ IDLE   ││
              │  │ RUN    │  │ (NOOP) ││
              │  └───┬────┘  └───┬────┘│
              │     │            │     │
              │     │     timeout│     │
              │     │            ▼     │
              │     │     ┌────────────┐│
              │     │     │ IDLE       ││
              │     │     │ TIMEOUT    ││
              │     │     │ (TERM)     ││
              │     │     └────────────┘│
              │     │            │     │
              │     └──────┬──────┘     │
              │            │            │
              │            ▼            │
              │     ┌─────────────┐     │
              │     │  SESSION    │     │
              │     │  COMPLETE   │     │
              │     └──────┬──────┘     │
              │            │            │
              │      kyb stop           │
              │            │            │
              │            ▼            │
              │     ┌─────────────┐     │
              └─────┤  STOPPED    │     │
                    │  (resumable)│─────┘
                    └──────┬──────┘
                           │ kyb rm
                           ▼
                    ┌─────────────┐
                    │  DESTROYED  │
                    └─────────────┘
```

### State transitions

| Transition | Trigger | Event |
|------------|---------|-------|
| CREATED → STARTED | `kyb create` finishes | `container_create` with `provenance: cold` |
| STOPPED → STARTED | `kyb start` on existing container | `container_start` with `provenance: resume` |
| STARTED → ACTIVE | Agent process starts (Claude Code boot) | `session_start` |
| ACTIVE → IDLE | No activity for configured threshold (e.g. 5 min) | `session_idle` |
| RUN → ACTIVE | Task completes with result | `task_end` |
| IDLE → ACTIVE | New activity detected | `session_resume` |
| IDLE → TIMEOUT | Idle duration exceeds max threshold | `session_timeout` |
| ACTIVE/RUN → COMPLETE | Agent signals work done or container stops gracefully | `session_complete` |
| COMPLETE → STOPPED | Container process exits normally | `container_stop` |
| Any → DESTROYED | `kyb rm` or `kyb prune` | `container_rm` |

---

## 4. Data Model

### 4.1 Extended `sessions` Table

Extend the existing ClickHouse `sessions` table with new columns for provenance and state tracking.

```sql
CREATE TABLE IF NOT EXISTS kyb.sessions (
    -- Primary key / identity
    session_id       String,          -- UUID, generated at session_start
    container_id     String,          -- e.g. kyb-project-branch (existing)

    -- Container provenance
    provenance       Enum8('cold' = 1, 'resume' = 2),  -- NEW: cold start vs resume
    container_life   UInt64,          -- NEW: number of times this container has been started

    -- State tracking
    state            String,          -- NEW: current state (active/idle/timeout/completed)
    state_changed_at DateTime,        -- NEW: timestamp of last state change

    -- Existing fields
    project          String,
    branch           String,
    model            String,
    user             String,
    hostname         String,
    pid              UInt32,

    -- Timing
    created_at       DateTime,        -- container creation time
    started_at       DateTime,        -- NEW: session start time
    destroyed_at     Nullable(DateTime),
    duration_seconds Nullable(UInt32),
    idle_seconds     Nullable(UInt32),  -- NEW: cumulative idle time during session

    -- Outcome
    exit_code        Nullable(UInt16),
    exit_reason      Nullable(String),  -- NEW: completed | idle_timeout | error | killed

    -- Agent hierarchy
    parent_session_id Nullable(String), -- NEW: boss session that dispatched this agent
    dispatch_depth    UInt8 DEFAULT 0,  -- NEW: depth in dispatch tree (0 = root)

    -- Task metrics
    tasks_completed  UInt16 DEFAULT 0,  -- NEW
    tasks_failed     UInt16 DEFAULT 0,   -- NEW

    -- ClickHouse partitioning / ordering
    timestamp        DateTime
) ENGINE = MergeTree()
ORDER BY (project, timestamp)
PARTITION BY toYYYYMM(timestamp);
```

### 4.2 New `session_events` Table

An append-only event log for session state transitions, so we can reconstruct timelines and compute durations retroactively.

```sql
CREATE TABLE IF NOT EXISTS kyb.session_events (
    session_id     String,
    event_type     Enum8(
        'start'        = 1,
        'complete'     = 2,
        'idle'         = 3,
        'resume'       = 4,
        'timeout'      = 5,
        'task_start'   = 6,
        'task_end'     = 7,
        'heartbeat'    = 8,
        'error'        = 9,
        'dispatch'     = 10
    ),
    timestamp      DateTime,
    data           String,            -- JSON payload, varies by event_type

    -- Agent hierarchy
    parent_session_id Nullable(String),
    dispatch_depth    UInt8 DEFAULT 0,
) ENGINE = MergeTree()
ORDER BY (session_id, timestamp);
```

### 4.3 Event Payloads

```yaml
session_start:
  data:
    cold_start: bool           # true = fresh container, false = resume
    container_life: int        # 1-based count of times this container has booted
    model: string
    claude_version: string     # from `claude --version` or env
    dispatch_depth: 0          # root session

session_complete:
  data:
    duration_seconds: float
    idle_seconds: float
    tasks_completed: int
    tasks_failed: int
    exit_reason: "completed" | "idle_timeout" | "error" | "killed"
    exit_code: int | null

session_idle:
  data:
    idle_seconds: float        # cumulative idle so far
    last_activity: DateTime    # timestamp of last event

session_timeout:
  data:
    total_idle_seconds: float  # total idle before timeout

task_start:
  data:
    task_type: string          # e.g. "implement", "review", "test"
    target: string             # project or scope

task_end:
  data:
    task_type: string
    duration_seconds: float
    outcome: "success" | "failure" | "partial"

dispatch:
  data:
    sub_session_id: string     # UUID of the dispatched sub-session
    task_type: string
    dispatch_depth: int        # parent depth + 1
```

---

## 5. Collection Strategy

### 5.1 At Container Boundaries (kyb CLI)

Instrument the existing CLI commands to emit enriched events.

| CLI command | Current behavior | New enrichment |
|-------------|-----------------|----------------|
| `kyb create` | Emits `container_create` + `session_create` | Add `provenance: cold`, `container_life: 1` |
| `kyb start` | No event currently | New `container_start` event with `provenance: resume`, `container_life: N+1` |
| `kyb rm` | Emits `container_rm` + `session_destroy` | Add `exit_reason`, `idle_seconds`, final state |
| `kyb prune` | Calls `remove_container` in a loop | Each removal gets individual lifecycle event |

Implementation sketch:

```ruby
# lib/kyb/reporter.rb — additions

def emit_container_start(project:, branch:, provenance:, container_life:)
  emit(:container_start, {
    project: project, branch: branch,
    provenance: provenance,       # "cold" | "resume"
    container_life: container_life
  })
end

def emit_session_idle(container_id:, idle_seconds:, last_activity:)
  emit(:session_idle, {
    container_id: container_id,
    idle_seconds: idle_seconds,
    last_activity: last_activity
  })
end

def emit_session_timeout(container_id:, total_idle_seconds:)
  emit(:session_timeout, {
    container_id: container_id,
    total_idle_seconds: total_idle_seconds
  })
end

def emit_session_resume(container_id:, idle_duration:)
  emit(:session_resume, {
    container_id: container_id,
    idle_duration: idle_duration
  })
end
```

### 5.2 In-Container Agent Instrumentation

Agent processes (Claude Code) emit session lifecycle events directly. These run inside the container and use the same `Kyb::Reporter` module or a lightweight HTTP client to POST events to ClickHouse.

**On agent boot** (CLAUDE.md workflow step 2 or entrypoint hook):
- Check `/tmp/kyb-session-active` — if exists, this is a resume; otherwise cold start
- Emit `session_start` with provenance and container_life
- Write `/tmp/kyb-session-active` with current timestamp and session_id
- Write `/tmp/kyb-container-life` with incremented counter

**On agent activity**:
- Write current timestamp to `/tmp/kyb-last-activity`
- Reset idle timer

**On agent completion** (explicit `kyb notify done` or session end):
- Emit `session_complete` with duration, outcome, task counts
- Remove `/tmp/kyb-session-active`

**On idle timeout** (detected by patroller or a watchdog):
- If `/tmp/kyb-last-activity` is older than threshold (configurable, default 15 min):
  - Emit `session_idle` warning at 5 min
  - Emit `session_timeout` at 15 min
  - Kill the agent process (SIGTERM → SIGKILL after grace period)

### 5.3 Patroller Integration

The existing 5-minute patroller (see `5min-patrol-guide.md`) can become the idle-detection watchdog:

```
Patroller check (every 5 min):
  1. Read /tmp/kyb-last-activity on each running container
  2. If age > 5 min → emit session_idle (first occurrence)
  3. If age > 15 min → emit session_timeout, trigger kill
  4. Check /tmp/kyb-session-active exists → if not, container has no active session
  5. Record results in heartbeat file as before
```

The patroller already writes heartbeat timestamps to `.kyb-diaries/.patrol-*-hb`.
Extend the check to also read container activity files:

```bash
# In patroller script, after health check:
for container in $(docker ps --filter 'name=kyb-' --format '{{.Names}}'); do
    LAST_ACT=$(docker exec "$container" cat /tmp/kyb-last-activity 2>/dev/null || echo "0")
    NOW=$(date +%s)
    IDLE_SEC=$((NOW - LAST_ACT))

    if [ "$IDLE_SEC" -gt 900 ]; then  # 15 min
        # Emit timeout, kill agent
        kyb notify urgent "Container $container idle ${IDLE_SEC}s, killing agent"
        docker exec "$container" kill -TERM 1  # or specific agent PID
    elif [ "$IDLE_SEC" -gt 300 ]; then  # 5 min
        # Emit idle warning
        kyb exec "$container" -- \
          bash -c "kyb notify blocked 'Idle ${IDLE_SEC}s — still working?'" 2>/dev/null || true
    fi
done
```

---

## 6. Cold Start vs Resume Detection

This is the core provenance question. The container's identity persists across stops
and starts (Docker keeps the container object with `docker stop`/`docker start`).
A `kyb create` always produces a new container; a `kyb start` reuses an existing one.

### Detection Logic

```ruby
# In Kyb::Docker.create_container:
# Always a cold start — new container
Kyb::Reporter.emit_container_create(project: project, branch: branch, mode: mode)
# container_life = 1 for brand new containers

# In Kyb::Docker.start_existing:
# Always a resume — container already existed
container_life = get_container_life_count(container)
Kyb::Reporter.emit_container_start(
  project: project, branch: branch,
  provenance: 'resume',
  container_life: container_life + 1
)
```

The container lifecycle counter is stored as a Docker label:

```ruby
# Set on create
args += ['-l', "kyb.container-life=1"]

# Increment on start_existing
def increment_container_life(container)
  current = `docker inspect --format '{{index .Config.Labels "kyb.container-life"}}' #{container}`.strip.to_i
  new_life = current + 1
  # Docker doesn't support label updates on existing containers → use volume file
  File.write("/tmp/kyb-container-life-#{container}", new_life.to_s)
end
```

Alternative approach (simpler): store the counter in a file on the claude_volume:

```
/home/dev/.claude/container-life   ← written by entrypoint.sh, read by reporter
```

On `kyb start` (which calls `docker start`), the entrypoint.sh would run again
(the process restarts), read the existing counter file, increment it, and the
agent boot flow picks it up.

---

## 7. Idle Timeout Detection

### Idle Signal Definition

A session is "idle" when all of the following are true for a continuous period:

1. No `exec` events from the kyb CLI into this container
2. No `dispatch` or `complete` events from the agent
3. No file modifications in the project directory
4. No active Claude Code conversation (agent process not consuming tokens)

### Thresholds

| Level | Threshold | Action |
|-------|-----------|--------|
| Warning | 5 minutes of no activity | Emit `session_idle` event, optional notification |
| Timeout | 15 minutes of no activity | Emit `session_timeout` event, kill agent process |
| Hard kill | 20 minutes | SIGKILL if SIGTERM didn't work |

These thresholds are configurable per session via environment variables:

```bash
KYB_IDLE_WARN_SEC=300       # 5 minutes
KYB_IDLE_TIMEOUT_SEC=900    # 15 minutes
KYB_IDLE_HARDKILL_SEC=1200  # 20 minutes
```

### Detector Implementation

Option A — Patroller (recommended for V1):
- Existing 5-minute patrol loop checks idle
- Low complexity, piggybacks on existing infrastructure
- ~5 min detection granularity (plus 5 min threshold = 10 min ceiling)

Option B — In-container watchdog:
- Separate process inside container monitors activity
- Sub-minute granularity
- More complex, requires a daemon

Option C — kyb CLI background thread:
- `kyb enter` starts a background thread that sends heartbeats
- If the thread stops (agent exits), idle detection is implicit

**Recommendation for V1:** Option A (patroller). The 5-minute patrol is already running,
the incremental cost is minimal, and 5-minute granularity is acceptable for session
duration monitoring.

---

## 8. Agent Hierarchy Tracking

The boss dispatches sub-agents, each of which creates its own kyb container.
The session tree looks like:

```
boss session (kyb-project-boss)
  ├── sub-agent session (kyb-project-worker-1)  dispatch_depth=1
  │     ├── sub-sub-agent (kyb-project-worker-1-sub) dispatch_depth=2
  │     └── ...
  ├── sub-agent session (kyb-project-worker-2)  dispatch_depth=1
  └── ...
```

### Parent-Child Session Linking

When boss dispatches:
1. Boss emits `dispatch` event with `sub_session_id` (pre-allocated UUID for the child's session)
2. Boss creates child container (cold) or starts existing (resume)
3. Child emits `session_start` with `parent_session_id` = boss's session_id
4. Child emits `session_complete` with `parent_session_id`
5. Boss can query: "which sub-agents did my session dispatch, and how long did each take?"

Implementation:

```ruby
# In boss dispatch flow:
sub_session_id = SecureRandom.uuid
Kyb::Reporter.emit_dispatch(
  task_type: task_type,
  target: target,
  sub_session_id: sub_session_id,
  parent_session_id: current_session_id,
  dispatch_depth: current_depth + 1
)

# Child container receives parent_session_id via env var:
args += ['-e', "KYB_PARENT_SESSION=#{current_session_id}"]
args += ['-e', "KYB_DISPATCH_DEPTH=#{current_depth + 1}"]
```

The child's `entrypoint.sh` reads these env vars and passes them to the reporter:

```bash
# entrypoint.sh addition
if [ -n "${KYB_PARENT_SESSION:-}" ]; then
    echo "$KYB_PARENT_SESSION" > /home/dev/.claude/parent-session
    echo "$KYB_DISPATCH_DEPTH" > /home/dev/.claude/dispatch-depth
fi
```

---

## 9. Dashboard and Alerts

### Grafana Dashboard: Session Overview

Panel ideas:

| Panel | Query | Purpose |
|-------|-------|---------|
| Active Sessions Count | `SELECT count() FROM sessions WHERE state = 'active'` | How many agents working right now |
| Session Duration Distribution (P50/P90/P99) | Histogram of `duration_seconds` by `provenance` | Are sessions getting longer/shorter? |
| Cold Start vs Resume Ratio | `SELECT provenance, count() FROM sessions GROUP BY provenance` | What fraction are warm starts? |
| Idle Timeout Rate | `SELECT count() FROM session_events WHERE event_type = 'timeout'` | How often do agents idle out? |
| Idle Timeout Trend | Time series of idle_timeout events over 24h | Is idle increasing? |
| Dispatch Tree Depth | `SELECT dispatch_depth, count() FROM session_events WHERE event_type = 'start' GROUP BY dispatch_depth` | How deep do agent hierarchies grow? |
| Task Success Rate | `SELECT outcome, count() FROM session_events WHERE event_type = 'task_end' GROUP BY outcome` | Are tasks completing? |
| Session Duration by Project | `SELECT project, avg(duration_seconds) FROM sessions GROUP BY project` | Which projects have longest sessions? |

### Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| Zero active sessions (expecting work) | `count() WHERE state = 'active'` = 0 for > 30 min | Warning (P2) |
| High idle timeout rate | > 5 idle timeouts per hour | Warning (P2) |
| All sessions idle | All containers in idle state for > 15 min | Info (P3) |
| Cold start spike | Cold starts > 2x historical average in 1h | Info (P3) |
| Dispatch depth anomaly | Any session with `dispatch_depth > 5` | Info (P3) |

---

## 10. Implementation Plan

### Phase 1: Event Enrichment (estimated: 1 agent-session)

Changes to `lib/kyb/reporter.rb`:
- Add `emit_container_start` with provenance tracking
- Add `emit_session_idle` / `emit_session_timeout` / `emit_session_resume`
- Add `emit_event` for the new `session_events` table

Changes to CLI manage.rb:
- `start` command: emit `container_start` with provenance
- `start` command: increment container_life counter

Changes to Docker.rb:
- `start_existing`: add label/counter logic for resume detection

### Phase 2: In-Container Agent Instrumentation (estimated: 1 agent-session)

Changes to `entrypoint.sh`:
- Write `/tmp/kyb-session-active` on agent boot (via CLAUDE.md workflow hook or entrypoint)
- Write `/tmp/kyb-last-activity` timestamp on activity
- Read `KYB_PARENT_SESSION` and `KYB_DISPATCH_DEPTH` env vars, persist to `/home/dev/.claude/`
- Read and increment `/home/dev/.claude/container-life`

Changes to `CLAUDE.md` template (generated by entrypoint.sh):
- Add workflow step: emit session_start on boot
- Add workflow step: emit heartbeat every N minutes
- Add workflow step: emit session_complete on completion

### Phase 3: Patroller Idle Detection (estimated: 0.5 agent-session)

Changes to patroller guide or script:
- Add idle check loop across all running kyb containers
- Emit idle/timeout events
- Optionally kill hung agent processes

### Phase 4: Agent Hierarchy (estimated: 1 agent-session)

Changes to boss dispatch logic:
- Pre-allocate sub_session_id, pass via env vars
- Link parent-child sessions in ClickHouse
- Emit dispatch events with depth tracking

### Phase 5: Dashboards (estimated: 0.5 agent-session)

Grafana JSON model for session overview dashboard:
- Panel queries and visualizations
- Alert definitions

---

## 11. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| ClickHouse write failures during high dispatch | Lost session events | Local file fallback: buffer events to `/tmp/kyb-events/`, retry/backfill |
| High event volume from 5-min patrol on many containers | Bandwidth, storage | Batch emit: accumulate patrol results, emit once per patrol cycle |
| Agent hierarchy UUID coordination across containers | Broken parent-child links | Pass parent_session_id via env var at container create time; child reads on boot |
| Stale `/tmp/kyb-session-active` after container crash | Phantom active sessions | Patroller reads agent PID from file; if PID not alive, clean up |
| Counter drift in `/home/dev/.claude/container-life` | Wrong container_life value | Treat file as source of truth; if missing default to 1 (conservative) |

---

## 12. Open Questions

1. **ClickHouse availability from inside containers**: Reporter uses `host.orb.internal:8123`.
   In DID containers or offline environments, this may not resolve. Should we use a local
   buffer (file-based) and flush when connectivity returns?

2. **Idle threshold tuning**: 5 min / 15 min are initial guesses. Should be configurable
   but not require redeployment. Environment variables on the container suffice.

3. **Session vs. conversation**: Claude Code has its own conversation model (each `claude`
   invocation is a conversation). Should we track individual conversations within a session?
   Probably Phase 2 — start with session boundaries.

4. **Feishu/messaging integration**: Should idle timeout notifications go to a specific
   Feishu chat? The existing `kyb notify` system can handle this, but we need to decide
   routing rules.

5. **Historical backfill**: The sessions table has data going back to when it was created,
   but without the new columns. Can we compute cold start vs resume retroactively from
   container existence checks? Approximate but useful for trend baselines.

---

## 13. Appendix: Query Examples

### Active Sessions (last 15 min)

```sql
SELECT container_id, project, state, created_at,
       dateDiff('second', started_at, now()) AS session_duration_seconds
FROM kyb.sessions
WHERE state = 'active'
  AND created_at > now() - INTERVAL 24 HOUR
ORDER BY session_duration_seconds DESC;
```

### Idle Timeout Rate (hourly)

```sql
SELECT toStartOfHour(timestamp) AS hour, count() AS timeouts
FROM kyb.session_events
WHERE event_type = 'timeout'
  AND timestamp > now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;
```

### Cold Start Ratio (daily)

```sql
SELECT toDate(created_at) AS day,
       countIf(provenance = 'cold') AS cold_starts,
       countIf(provenance = 'resume') AS resumes,
       cold_starts / (cold_starts + resumes) AS cold_ratio
FROM kyb.sessions
WHERE created_at > now() - INTERVAL 14 DAY
GROUP BY day
ORDER BY day;
```

### Dispatch Tree Depth Distribution

```sql
SELECT dispatch_depth, count() AS sessions,
       avg(duration_seconds) AS avg_duration,
       quantile(0.90)(duration_seconds) AS p90_duration
FROM kyb.sessions
WHERE created_at > now() - INTERVAL 7 DAY
GROUP BY dispatch_depth
ORDER BY dispatch_depth;
```

### Session Duration Distribution by Project

```sql
SELECT project,
       count() AS sessions,
       quantile(0.50)(duration_seconds) AS p50,
       quantile(0.90)(duration_seconds) AS p90,
       quantile(0.99)(duration_seconds) AS p99
FROM kyb.sessions
WHERE created_at > now() - INTERVAL 7 DAY
  AND duration_seconds IS NOT NULL
GROUP BY project
ORDER BY sessions DESC;
```
