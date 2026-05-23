---
decision: 稍后做
---

# Design: Boss Decision Latency Tracking

**Design doc**: `docs/infra/reviews/boss-decision-latency.md`
**Designer**: kyb infra-boss
**Date**: 2026-05-23
**Scope**: Time-from-event-to-response for every link in the boss dispatch chain, from patrol alert to MR merge to feishu message reply.

---

## Summary

The infra boss operates a multi-cluster dispatch pipeline. An agent sees a problem, reports to the boss, the boss decides, dispatches a fixer, the fixer creates an MR, CI runs, the boss decides to merge, and master CI goes green. Each step in this chain has latency, and currently none of it is measured. This design defines the metrics, data sources, CK schemas, and Grafana panels to track the boss's decision velocity end-to-end.

### Why This Matters

1. **Bottleneck detection** — is the boss the slow link (taking too long to decide) or the agents (slow to implement)?
2. **Patrol effectiveness** — does the boss actually respond faster to patrol alerts now than last week?
3. **SLA enforcement** — if the boss promises a <5min response to feishu messages, is it keeping that promise?
4. **Dispatch chain health** — the chain "issue → dispatch → implement → MR → CI → merge → master CI green" should complete in <30min for urgent fixes. Tracking this per-incident shows where the chain breaks.

---

## Metrics Definitions

### 1. Patrol → Dispatch Latency (PDL)

Time from when the patrol detects an anomaly (e.g., disk > 90%, brother timer expired, container crash loop) to when the boss dispatches a fix agent via `dispatch()`.

```
PDL = dispatch_timestamp - patrol_alert_timestamp

Measured at: P50, P90, P99 (in seconds)
Target: P50 < 10s, P90 < 30s, P99 < 60s
```

**Data sources:**
- Patrol heartbeat files (`.kyb-diaries/.patrol-{1,2,3}-hb`) — record patrol completion + any anomalies detected
- `kyb.claude_hook_events` — `SubagentStart` event marks the dispatch timestamp
- New: `infra.patrol_log` table — each patrol cycle writes its findings here (anomaly yes/no, what kind)

### 2. Issue → Action Latency (IAL)

Time from GitLab issue creation to the boss's first non-trivial action on that issue (comment, assign, close, or dispatch a fix agent).

```
IAL = first_action_timestamp - issue_created_at

Measured at: P50, P90, P99 (in minutes)
Target: P50 < 2min, P90 < 10min, P99 < 30min
```

**Data sources:**
- GitLab webhook events (or `glab issue list` polling snapshots) — captured in `infra.gitlab_events`
- `kyb.claude_hook_events` — `UserPromptSubmit` or tool calls referencing the issue number
- New: `infra.issue_latency` materialized view joining issue creation with first action

### 3. Feishu → Response Latency (FRL)

Time from when a feishu message arrives (via WebSocket or webhook) to when the boss responds (sends a message back, or dispatches an agent, or acknowledges the message).

```
FRL = response_timestamp - message_received_timestamp

Measured at: P50, P90, P99 (in seconds)
Target: P50 < 5s, P90 < 30s, P99 < 60s
```

**Data sources:**
- cc-connect event log (`cc.message_log`) — every incoming message is timestamped at `event_time`
- `kyb.claude_hook_events` — `UserPromptSubmit` is the boss seeing the message, `PostToolUse` for feishu-send is the boss responding
- New: correlation via session proximity (message arrival and boss "send" action within the same session window)

### 4. Boss Decision Time (BDT)

Time from when a subagent reports back (SubagentStop with a status payload) to when the boss makes a decision (dispatches a merge agent, dispatches a reviewer, or replies to the user).

```
BDT = decision_timestamp - report_timestamp

Measured at: P50, P90, P99 (in seconds)
Target: P50 < 5s, P90 < 30s, P99 < 60s
```

**Data sources:**
- `kyb.claude_hook_events` — `SubagentStop` event (agent reports back), followed by next `SubagentStart` (boss dispatches next step) or `Stop` (boss responds)
- The gap between `SubagentStop` and the next non-trivial event is the decision window

### 5. Subagent Turnaround Time (STT)

Time from subagent dispatch (SubagentStart) to subagent completion (SubagentStop). This includes the subagent's entire workflow: think, code, test, create MR.

```
STT = subagent_stop_timestamp - subagent_start_timestamp

Measured at: P50, P90, P99 (in minutes)
Target (simple fix): P50 < 3min, P90 < 10min
Target (complex feature): P50 < 15min, P90 < 30min
```

**Data sources:**
- `kyb.claude_hook_events` — `SubagentStart` (start) and `SubagentStop` (end) events, correlated by `session_id` and `parent_session_id`
- `subagent_task` field in the event describes what the agent was asked to do

### 6. End-to-End Cycle Time (E2E)

From the moment a trigger fires (issue created, patrol alert, feishu message) to the moment master CI is green with the fix.

```
E2E = master_ci_green_timestamp - trigger_timestamp

Measured at: P50, P90, P99 (in minutes)
Target (urgent fix): P50 < 15min, P90 < 30min
Target (normal): P50 < 45min, P90 < 2h
```

**Data sources:**
- Any of the trigger timestamps above (issue creation, patrol anomaly, feishu message)
- CI pipeline events (from `glab ci status` or GitLab webhook)
- `kyb.claude_hook_events` — session end / final notification to user

---

## Data Sources (Existing)

### 1. `kyb.claude_hook_events` (Already in CK)

The richest signal. Every session event is already captured. Relevant fields for latency tracking:

| Field | Used For |
|-------|----------|
| `timestamp` | Event timing (UTC, ms precision) |
| `event_type` | `SubagentStart`, `SubagentStop`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`, `PostToolUse`, `PreToolUse` |
| `session_id` | Correlate events in one session |
| `parent_session_id` | Correlate subagent with parent |
| `subagent_task` | What the subagent was asked to do (task description) |
| `tool_name` | Which tool was used (feishu-send, git commands, etc.) |
| `tool_input` | Input to the tool (contains MR URLs, issue numbers, etc.) |
| `duration_ms` | Duration of the tool call itself |
| `cwd` | Project context (which repo) |
| `project` | Project name |

**Gaps:**
- `subagent_task` currently only contains the task description, not a structured "status=done/fail" payload
- There is no explicit "decision" event type — we infer it from the gap between SubagentStop and the next dispatch

### 2. `boss_heartbeats` (Already in CK)

Per-cluster boss aliveness. Not directly used for latency, but useful context:

| Field | Used For |
|-------|----------|
| `boss_id` / `cluster` | Which boss |
| `timestamp` | When heartbeat was written |
| `agent_alive` | Is the Claude agent running inside the boss container |

### 3. `cc.message_log` (Already in CK, if deployed)

Feishu message timestamps. Used for FRL calculation when running via cc-connect.

| Field | Used For |
|-------|----------|
| `event_time` | When message was received |
| `sender_id` | Who sent it |
| `content_text` | Message body |

### 4. Patrol heartbeat files (On-disk, per boss)

```
.kyb-diaries/.patrol-{1,2,3}-hb
```

Each file contains:
- Line 1: ISO timestamp of last patrol completion
- Line 2: Status emoji (green/yellow/red) — presence of a non-green status = anomaly

These files are local to each boss and not currently in CK. A patrol log table would bring them into central observability.

---

## New CK Schemas

### 1. `infra.patrol_log`

Each patrol cycle (one per boss, per ~5min) writes a row. This replaces the local heartbeat files for observability purposes.

```sql
CREATE TABLE IF NOT EXISTS infra.patrol_log (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    patrol_time     DateTime64(3),

    -- Patrol findings
    patrol_status   LowCardinality(String),         -- 'ok' | 'warning' | 'critical'
    anomalies_found UInt8 DEFAULT 0,                -- count of anomalies detected

    -- Environment snapshot at patrol time
    docker_running  UInt16,
    docker_total    UInt16,
    disk_used_pct   UInt8,
    mem_used_pct    UInt8,
    load_1m         Float32,

    -- Brother patrol health (other patrol timers in same cluster)
    patrol_1_age_sec UInt16,                        -- seconds since patrol-1 heartbeat
    patrol_2_age_sec UInt16,
    patrol_3_age_sec UInt16,

    -- Free-text anomaly descriptions (JSON array)
    anomalies       String DEFAULT '[]',

    -- Ingestion timestamp (CK server time)
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (patrol_time, cluster, boss_id)
TTL patrol_time + INTERVAL 90 DAY;
```

### 2. `infra.decision_log`

Every time the boss makes a dispatch decision, a row is written. This is the core latency tracking table.

```sql
CREATE TABLE IF NOT EXISTS infra.decision_log (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),

    -- Decision metadata
    decision_time   DateTime64(3),
    trigger_type    LowCardinality(String),
        -- 'patrol_alert' | 'feishu_message' | 'issue_created' |
        -- 'subagent_report' | 'ci_result' | 'user_command'

    decision_type   LowCardinality(String),
        -- 'dispatch_fix_agent' | 'dispatch_review' | 'dispatch_merge' |
        -- 'acknowledge' | 'escalate' | 'ignore' | 'close' |
        -- 'request_clarification' | 'delegate_to_human'

    -- Trigger timing (when the input arrived)
    trigger_time    DateTime64(3),

    -- Decision latency this decision_time - trigger_time
    latency_sec     UInt32,

    -- Context references
    reference_type  LowCardinality(String),
        -- 'patrol_id' | 'issue_iid' | 'feishu_chat_id' | 'session_id' | 'mr_iid'
    reference_id    String,

    -- Subagent tracking (if dispatch produced subagent work)
    subagent_session_id String DEFAULT '',
    parent_session_id   String DEFAULT '',

    -- Decision notes / reasoning (brief, high-cardinality)
    notes           String DEFAULT '',

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (decision_time, trigger_type, decision_type)
TTL decision_time + INTERVAL 90 DAY;
```

### 3. `infra.issue_latency` (Materialized View)

Joins GitLab issue creation events with first-action events to compute IAL.

```sql
CREATE TABLE IF NOT EXISTS infra.issue_latency (
    issue_iid       UInt32,
    project         String,
    cluster         LowCardinality(String),

    issue_created_at    DateTime64(3),
    first_action_at     DateTime64(3),
    first_action_type   LowCardinality(String),
        -- 'dispatch' | 'comment' | 'close' | 'assign'

    ial_sec             UInt32,          -- first_action_at - issue_created_at
    assignee            String DEFAULT '',
    title               String DEFAULT '',
    severity            LowCardinality(String) DEFAULT 'normal',

    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (issue_created_at, cluster)
TTL issue_created_at + INTERVAL 90 DAY;
```

### 4. `infra.e2e_cycle_times`

End-to-end latency per incident, from trigger to master-green.

```sql
CREATE TABLE IF NOT EXISTS infra.e2e_cycle_times (
    cycle_id        UUID DEFAULT generateUUIDv4(),

    -- Incident identity
    trigger_type    LowCardinality(String),
    trigger_time    DateTime64(3),
    cluster         LowCardinality(String),
    description     String,

    -- Milestone timestamps (latency pipeline)
    patrol_time     DateTime64(3),      -- when patrol detected it, if applicable
    dispatch_time   DateTime64(3),      -- when boss dispatched a fix agent
    subagent_start  DateTime64(3),      -- when fix agent started working
    subagent_stop   DateTime64(3),      -- when fix agent completed + reported
    decision_time   DateTime64(3),      -- when boss decided to merge
    mr_created_time DateTime64(3),      -- when the MR was created
    mr_merged_time  DateTime64(3),      -- when the MR was merged
    master_ci_time  DateTime64(3),      -- when master CI went green

    -- Individual stage latencies (seconds, computed)
    pdl_sec         Nullable(UInt32),   -- patrol -> dispatch
    stt_sec         Nullable(UInt32),   -- dispatch -> subagent stop
    bdt_sec         Nullable(UInt32),   -- subagent stop -> decision
    mrl_sec         Nullable(UInt32),   -- decision -> mr merged
    cil_sec         Nullable(UInt32),   -- mr merged -> master ci green
    e2e_sec         UInt32,             -- trigger -> master ci green

    -- Outcome
    status          LowCardinality(String) DEFAULT 'in_progress',
        -- 'in_progress' | 'success' | 'failure' | 'abandoned'

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (trigger_time, trigger_type)
TTL trigger_time + INTERVAL 90 DAY;
```

---

## Data Instrumentation

### 1. Hook Enrichment: Add Decision Signal

The existing `emit-ck.sh` hook already captures all tool calls and session events. To extract decision latency, enrich the `metadata` map field with structured decision context:

In `emit-ck.sh`, add enrichment for `PostToolUse` events that match dispatch patterns:

- `tool_name = 'Bash'` and `tool_input` contains `dispatch` → tag as `decision_type: dispatch`
- `tool_name = 'Bash'` and `tool_input` contains `kyb notify` → tag as `decision_type: notify`
- `tool_name = 'Skill'` or `tool_name = 'Agent'` (future) → tag as `decision_type: subagent_dispatch`

The enrichment adds a `metadata.kyb_decision_type` key to the event payload.

Additionally, for `SubagentStop` events:

- Parse `tool_output` for status keywords ("done", "failed", "report") and add `metadata.kyb_subagent_result`
- Parse `tool_output` for MR URLs and add `metadata.kyb_mr_url`

```
Enrichment logic in emit-ck.sh (to add):

case "$EVENT_TYPE" in
  PostToolUse)
    case "$TOOL_NAME" in
      Bash)
        # Detect dispatch commands
        if echo "$TOOL_INPUT" | grep -qE '\bdispatch\b'; then
          METADATA_MAP="$METADATA_MAP,\"kyb_decision_type\":\"dispatch\""
        fi
        # Detect feishu send
        if echo "$TOOL_INPUT" | grep -qE 'feishu.*send|lark.*send|notify-im'; then
          METADATA_MAP="$METADATA_MAP,\"kyb_decision_type\":\"feishu_send\""
        fi
        # Detect MR operations
        if echo "$TOOL_INPUT" | grep -qE '(glab mr|git merge|mr create|mr merge)'; then
          METADATA_MAP="$METADATA_MAP,\"kyb_decision_type\":\"mr_op\""
        fi
        ;;
      Skill|TaskCreate)
        METADATA_MAP="$METADATA_MAP,\"kyb_decision_type\":\"subagent_dispatch\""
        ;;
    esac
    ;;
  SubagentStop)
    # Extract result from tool output
    if echo "$TOOL_OUTPUT" | grep -qiE '(done|complete|success)'; then
      METADATA_MAP="$METADATA_MAP,\"kyb_subagent_result\":\"success\""
    elif echo "$TOOL_OUTPUT" | grep -qiE '(fail|error|blocked)'; then
      METADATA_MAP="$METADATA_MAP,\"kyb_subagent_result\":\"failed\""
    fi
    # Extract MR URL
    MR_URL=$(echo "$TOOL_OUTPUT" | grep -oE 'https://git\.leyantech\.com/[^/]+/[^/]+/-/merge_requests/[0-9]+' | head -1)
    if [ -n "$MR_URL" ]; then
      METADATA_MAP="$METADATA_MAP,\"kyb_mr_url\":\"$MR_URL\""
    fi
    ;;
esac
```

### 2. Patrol Log Writer

Add to the patrol script a step that POSTs findings to `infra.patrol_log` in CK after each patrol cycle.

```bash
# At the end of each patrol cycle:
# Write patrol findings to CK

PATROL_STATUS="ok"      # or "warning" or "critical"
ANOMALIES=()

# Check each anomaly source
if [ "$DISK_USED_PCT" -gt 90 ]; then
  PATROL_STATUS="critical"
  ANOMALIES+=("disk_above_90")
fi
if [ "$PATROL_1_AGE" -gt 900 ]; then
  PATROL_STATUS="critical"
  ANOMALIES+=("patrol-1_stale")
fi
# ... etc

# POST to CK
curl -s -X POST "http://100.104.244.99:8123?query=INSERT+INTO+infra.patrol_log+FORMAT+JSONEachRow" \
  -d "{
    \"boss_id\": \"$(hostname)\",
    \"cluster\": \"${CLUSTER_NAME:-unknown}\",
    \"patrol_time\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
    \"patrol_status\": \"$PATROL_STATUS\",
    \"anomalies_found\": ${#ANOMALIES[@]},
    \"docker_running\": $(docker ps -q | wc -l),
    \"docker_total\": $(docker ps -aq | wc -l),
    \"disk_used_pct\": $(df / | tail -1 | awk '{print $5}' | tr -d '%'),
    \"mem_used_pct\": $(free | grep Mem | awk '{print $3/$2 * 100.0}' | cut -d. -f1),
    \"load_1m\": $(cat /proc/loadavg | cut -d' ' -f1),
    \"patrol_1_age_sec\": ${PATROL_1_AGE:-0},
    \"patrol_2_age_sec\": ${PATROL_2_AGE:-0},
    \"patrol_3_age_sec\": ${PATROL_3_AGE:-0},
    \"anomalies\": \"$(printf '%s' "${ANOMALIES[*]}")\"
  }" \
  --max-time 5 2>/dev/null || echo "[PATROL] CK write failed"
```

### 3. Decision Log Writer

After every `dispatch()` call, write a decision log row. This can be done either as a hook enrichment (automatic, but needs pattern matching) or as an explicit step after every `dispatch` (more reliable, but manual).

**Recommended approach**: Both.

- **Hook-based**: The hook enrichment above tags `PostToolUse` events with `decision_type: dispatch`. A materialized view on `kyb.claude_hook_events` can extract these into `infra.decision_log`.
- **Explicit**: Add a `kyb decision-log` command or curl snippet at the end of each `dispatch` call:

```bash
# After every dispatch() call, log the decision
curl -s -X POST "http://100.104.244.99:8123?query=INSERT+INTO+infra.decision_log+FORMAT+JSONEachRow" \
  -d "{
    \"boss_id\": \"$(hostname)\",
    \"cluster\": \"${CLUSTER_NAME:-unknown}\",
    \"decision_time\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
    \"trigger_type\": \"$TRIGGER_TYPE\",
    \"decision_type\": \"dispatch_fix_agent\",
    \"trigger_time\": \"$TRIGGER_TIME\",
    \"latency_sec\": $(( $(date +%s) - TRIGGER_UNIX )),
    \"reference_type\": \"$REF_TYPE\",
    \"reference_id\": \"$REF_ID\",
    \"subagent_session_id\": \"$SESSION_ID\",
    \"parent_session_id\": \"$PARENT_SESSION_ID\",
    \"notes\": \"dispatched agent for $REF_ID\"
  }" \
  --max-time 5 2>/dev/null || echo "[DISPATCH] CK decision log write failed"
```

---

## Query Examples

### Patrol → Dispatch Latency (PDL) over last 7 days

```sql
SELECT
    toDate(decision_time) AS day,
    trigger_type,
    count() AS decisions,
    round(quantile(0.50)(latency_sec)) AS p50_sec,
    round(quantile(0.90)(latency_sec)) AS p90_sec,
    round(quantile(0.99)(latency_sec)) AS p99_sec
FROM infra.decision_log
WHERE trigger_type = 'patrol_alert'
  AND decision_time >= now() - INTERVAL 7 DAY
GROUP BY day, trigger_type
ORDER BY day DESC;
```

### Subagent turnaround breakdown (by task type)

```sql
SELECT
    toDate(timestamp) AS day,
    event_type,
    count() AS events,
    round(avg(duration_ms) / 1000) AS avg_sec,
    round(quantile(0.50)(duration_ms) / 1000) AS p50_sec,
    round(quantile(0.90)(duration_ms) / 1000) AS p90_sec,
    round(quantile(0.99)(duration_ms) / 1000) AS p99_sec
FROM kyb.claude_hook_events
WHERE event_type IN ('SubagentStart', 'SubagentStop')
  AND timestamp >= now() - INTERVAL 7 DAY
GROUP BY day, event_type
ORDER BY day DESC;
```

### Boss decision time (gap between SubagentStop and next dispatch)

```sql
WITH subagent_stops AS (
    SELECT
        timestamp AS stop_time,
        session_id,
        parent_session_id,
        subagent_task,
        lead(timestamp) OVER (PARTITION BY parent_session_id ORDER BY timestamp) AS next_event_time,
        lead(event_type) OVER (PARTITION BY parent_session_id ORDER BY timestamp) AS next_event_type
    FROM kyb.claude_hook_events
    WHERE event_type IN ('SubagentStop', 'SubagentStart', 'Stop')
      AND timestamp >= now() - INTERVAL 7 DAY
)
SELECT
    toDate(stop_time) AS day,
    count() AS decisions,
    round(quantile(0.50)(decision_sec)) AS p50_sec,
    round(quantile(0.90)(decision_sec)) AS p90_sec,
    round(quantile(0.99)(decision_sec)) AS p99_sec
FROM (
    SELECT *,
        dateDiff('second', stop_time, next_event_time) AS decision_sec
    FROM subagent_stops
    WHERE event_type = 'SubagentStop'
      AND next_event_type IN ('SubagentStart', 'Stop')
      AND next_event_time IS NOT NULL
)
WHERE day = today()
GROUP BY day;
```

### End-to-end: current week vs last week

```sql
SELECT
    toStartOfWeek(trigger_time) AS week,
    trigger_type,
    count() AS cycles,
    round(quantile(0.50)(e2e_sec) / 60) AS p50_min,
    round(quantile(0.90)(e2e_sec) / 60) AS p90_min,
    round(quantile(0.99)(e2e_sec) / 60) AS p99_min
FROM infra.e2e_cycle_times
WHERE status = 'success'
  AND trigger_time >= now() - INTERVAL 14 DAY
GROUP BY week, trigger_type
ORDER BY week DESC;
```

### Slowest patrol-dispatch decisions this week

```sql
SELECT
    decision_time,
    cluster,
    latency_sec,
    reference_type,
    reference_id,
    notes
FROM infra.decision_log
WHERE trigger_type = 'patrol_alert'
  AND decision_time >= now() - INTERVAL 7 DAY
ORDER BY latency_sec DESC
LIMIT 20;
```

### Crash loop response time (patrol to dispatch for container crash)

```sql
SELECT
    patrol_log.patrol_time,
    decision_log.decision_time,
    patrol_log.cluster,
    patrol_log.anomalies,
    decision_log.latency_sec,
    decision_log.decision_type,
    decision_log.notes
FROM infra.patrol_log
JOIN infra.decision_log
    ON patrol_log.cluster = decision_log.cluster
    AND decision_log.trigger_time >= patrol_log.patrol_time - INTERVAL 5 SECOND
    AND decision_log.trigger_time <= patrol_log.patrol_time + INTERVAL 30 SECOND
WHERE patrol_log.anomalies_found > 0
  AND position(patrol_log.anomalies, 'crash') > 0
  AND patrol_log.patrol_time >= now() - INTERVAL 7 DAY
ORDER BY decision_log.latency_sec DESC;
```

---

## Grafana Dashboard

### Panel 1: Decision Velocity Gauges (Singlestat)

One gauge per metric, showing P50 latency:

| Panel | Metric | Source | Target | Red |
|-------|--------|--------|--------|-----|
| PDL P50 | `quantile(0.50)(latency_sec) WHERE trigger_type = 'patrol_alert'` last 24h | `infra.decision_log` | < 10s | > 30s |
| FRL P50 | same, `trigger_type = 'feishu_message'` | `infra.decision_log` | < 5s | > 30s |
| BDT P50 | computed window between SubagentStop and next dispatch | `kyb.claude_hook_events` | < 5s | > 30s |
| IAL P50 | `quantile(0.50)(ial_sec)` last 24h | `infra.issue_latency` | < 2min | > 10min |
| E2E P50 | `quantile(0.50)(e2e_sec)` last 24h, status=success | `infra.e2e_cycle_times` | < 15min | > 30min |

### Panel 2: Latency Trend (Time Series)

Five lines: PDL P50, FRL P50, BDT P50, IAL P50, E2E P50 over the last 7 days, bucketed by hour.

- X-axis: time (hourly buckets)
- Y-axis: median latency in seconds
- Color: one color per metric
- Threshold lines: target per metric (dashed)

### Panel 3: Current Week vs Last Week (Bar Chart)

Grouped bars for current-week P50 vs last-week P50 for each latency metric.

### Panel 4: Dispatch Volume by Trigger Type (Time Series)

Stacked area chart: patrol_alert, feishu_message, issue_created, subagent_report, user_command as stacked areas over time.

- Helps identify which trigger is driving the most decisions
- A sudden spike in one trigger type may indicate an infrastructure problem

### Panel 5: Slowest Decisions Table (Logs)

| Time | Cluster | Trigger Type | Latency (s) | Reference | Notes |
|------|---------|-------------|-------------|-----------|-------|

- Sorted by latency descending
- Filterable by cluster, trigger type
- Drill-down capability (click on a row to see the subagent_session_id in the hooks table)

### Panel 6: Patrol Health Check (Table)

| Cluster | Last Patrol | Status | Anomalies | Docker Running | Disk % |
|---------|-------------|--------|-----------|----------------|--------|

- From `infra.patrol_log`, latest row per cluster
- Color-coded by `patrol_status`

### Panel 7: Issue Response Scatter Plot

X-axis: issue creation time, Y-axis: IAL in seconds. Each point = one issue. Color by severity.

- Shows whether the boss is responding faster/slower over time
- Outliers (high Y values) are issues that slipped through

---

## Alert Rules

| Rule | Trigger | Condition | Severity | Action |
|------|---------|-----------|----------|--------|
| PDL too slow | `infra.decision_log` | P90 PDL > 30s in last 15min | P2 | Feishu: "Patrol response degraded — P90 PDL ${value}s (target <30s)" |
| FRL too slow | `infra.decision_log` | P90 FRL > 60s in last 15min | P2 | Feishu: "Feishu response degraded — P90 FRL ${value}s (target <60s)" |
| No patrol data | `infra.patrol_log` | No rows from a cluster in >10min | P1 | Feishu: "No patrol data from ${cluster} — patrol timer may be dead" |
| E2E degradation | `infra.e2e_cycle_times` | P90 E2E > 60min in last 24h | P3 | Feishu: "End-to-end cycle time degraded this week (${value}min P50, was ${baseline}min last week)" |
| Issue slipping | `infra.issue_latency` | Any issue with IAL > 30min and status != closed | P3 | Feishu: "Issue #${iid} has been open for ${ial_min}min without response" |

---

## Deployment

### Phase 1: CK Tables (P0, today)

Run `CREATE TABLE` statements for `infra.patrol_log`, `infra.decision_log`, `infra.issue_latency`, `infra.e2e_cycle_times` on central ClickHouse. These are pure DDL — no data movement.

```bash
# From super-boss (Mac/Orbstack):
for table in infra.patrol_log infra.decision_log infra.issue_latency infra.e2e_cycle_times; do
  echo "-- Creating $table"
  clickhouse-client --host host.orb.internal --query "$(sed -n "/^CREATE TABLE IF NOT EXISTS $table/,/^) ENGINE/p" docs/infra/reviews/boss-decision-latency.md)"
done
```

### Phase 2: Hook Enrichment (P0, today)

Update `emit-ck.sh` with decision-type detection logic (see Data Instrumentation section above). This starts tagging existing hook events with decision metadata immediately.

### Phase 3: Patrol Log Writer (P1, this week)

Add the patrol log POST to the 5-minute patrol script on each boss. Start with the Mac/Orbstack boss, then Aliyun and Office.

### Phase 4: Decision Log Writer (P1, this week)

Add explicit `decision_log` writes after every `dispatch()` call. Start with one boss, validate data quality, then deploy to all.

### Phase 5: Issue Latency (P2, next week)

Wire up GitLab issue tracking to `infra.issue_latency`. Either via:
- Glab polling script (`kyb-gl-issue-watch`) writing to CK
- GitLab webhook writing to CK

### Phase 6: E2E Cycle Tracking (P2, next week)

Build the E2E pipeline view in Grafana. This requires all earlier phases to be producing data so there is something to visualize.

### Phase 7: Grafana Dashboard (P2, next week)

Build the 7-panel dashboard described above. Wire alert rules to feishu.

---

## References

- [Multi-Cluster Boss Architecture](multi-cluster-boss-architecture.md) — boss dispatch mechanics and heartbeat protocol
- [Hooks to CK Pipeline](handbook/hooks-ck-pipeline.md) — existing hook event pipeline that PDL/BDT enrichment builds on
- [Observability Design](observability-design.md) — broader observability context
- [5-Min Patrol Guide](5min-patrol-guide.md) — patrol timer behavior that triggers PDL events
- [Docker Event Monitoring](docker-events.md) — infra container crash detection that triggers patrol alerts
- [Issue Automation](designs/issue-automation.md) — issue lifecycle tracking that feeds IAL
- [IM Integration](chat.md) — feishu message handling that feeds FRL

---

## Verdict

**Design is ready for incremental implementation.** No new infrastructure is required — all data sources already exist (hooks, heartbeats, patrol files, feishu logs) and the new CK tables are lightweight (a few hundred bytes per row, a few hundred rows per day).

The key insight is that **decision latency is already implicitly present in the hook event stream** — the `kyb.claude_hook_events` table contains all the timestamps needed to compute PDL, BDT, and STT. The missing piece is structured tagging of which events correspond to which decision. The enrichment logic in Phase 2 closes this gap with zero new agents or infrastructure.

Priority order:
1. Create CK tables + hook enrichment (immediate value — existing hook events get tagged)
2. Add patrol log writer (turns patrol heartbeat files into queryable data)
3. Add decision log writer (makes decision latency directly queryable)
4. Build Grafana dashboard + alerts (turns data into action)

> ／人◕ ‿‿ ◕人＼
