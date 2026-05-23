---
decision: 稍后做
---

# Claude Telemetry Capture Design

**Author:** boss
**Date:** 2026-05-23
**Status:** Design draft
**Scope:** Collect `tengu_*` events (tool_use, session, error) from Claude Code agent runtime into ClickHouse for observability.

---

## 1. Current State

Two tables already exist in ClickHouse (`kyb` database) capturing Claude agent activity:

### `claude_hook_events`

Raw hook-level events from Claude Code's tool-use lifecycle. Populated by a claude_hook script.

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | DateTime64(3) | Event timestamp (ms precision) |
| `session_id` | String | UUID per Claude session |
| `event_type` | LowCardinality(String) | `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionStart`, `SessionEnd` |
| `tool_name` | LowCardinality(String) | `Bash`, `Read`, `Edit`, `Write`, `Agent`, `TaskStop` ... |
| `tool_input` | String | Full tool input payload (JSON) |
| `tool_result` | String | Full tool result payload (JSON) |
| `duration_ms` | UInt32 | Tool execution wall time |
| `status` | Enum8 | `start=1`, `success=2`, `error=3`, `timeout=4` |
| `error_message` | String | Error detail (empty on success) |
| `project` | String | Project name from context |
| `agent_type` | String | Agent role (`boss`, subagent name) |
| `metadata` | Map(String,String) | Transcript path, cwd, permission mode, hooks config |

**Daily volume: ~4,800 events / ~30 MB raw** (May 23). 30-day TTL.

### `agent_events`

High-level agent decisions and lifecycle events from the boss-dispatch workflow.

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | DateTime | Event timestamp |
| `agent_id` | String | Agent name (`boss`, `ci-pragmatism`, `empiricism`) |
| `session_id` | String | Session identifier |
| `task_id` | String | Sub-task identifier |
| `project` | String | Project name |
| `event_type` | String | `decision`, `done`, `fix`, `experiment`, `handoff`, `finding` ... |
| `content` | String | Event body (free text) |
| `parent_agent_id` | String | Empty for boss, parent agent for subagents |
| `tags` | Map(String,String) | Extensible labels |

**Daily volume: ~20-50 events.** Low cardinality, high value.

---

## 2. Gap Analysis

### What exists

| tengu event | Coverage in claude_hook_events |
|---|---|
| `tengu_tool_use` | Partial. PreToolUse + PostToolUse capture start/finish, but no structured cost attribution, no tool-specific input/output normalization |
| `tengu_session` | Partial. SessionStart/SessionEnd logged, but no cross-session aggregation, no session-level summary at close |
| `tengu_error` | Partial. PostToolUseFailure + Stop logged, but no error classification taxonomy, no grouped error rollup |

### What is missing

1. **Normalized event schema** -- Current data is a firehose. No standardized `tengu_*` event envelope with common fields (version, event_id, trace_id, environment).
2. **Session aggregation** -- No materialized view that rolls up per-session stats (total tools, total errors, total duration, cost estimate).
3. **Error taxonomy** -- Errors are raw strings in `error_message`. No classification layer (transient vs persistent, user error vs system error, tool-specific error categories).
4. **Cost estimation** -- No token cost tracking. Could be derived from tool_input/tool_result length + known Claude model pricing.
5. **Latency tracking** -- No P50/P90/P99 views on tool duration by tool_name.
6. **Vector pipeline** -- Current ingestion path is unknown (possibly direct insert from claude_hook script). No formal Vector pipeline with parsing, transform, and routing.
7. **Grafana dashboards** -- No dashboards querying claude_hook_events.
8. **Alerting** -- No rules for error rate spikes, silent agents, or session anomalies.

---

## 3. Design: tengu Event Format

### 3.1 Common Envelope

Every `tengu_*` event carries this structure:

```json
{
  "tengu_version": "1.0",
  "event_id": "uuid-v4",
  "event_type": "tengu_tool_use | tengu_session | tengu_error",
  "timestamp": "2026-05-23T11:41:09.607Z",
  "session_id": "uuid-v4",
  "agent_id": "boss",
  "agent_type": "boss | subagent-<role>",
  "project": "kyb",
  "environment": "production | development",
  "trace_id": "uuid-v4",
  "span_id": "uuid-v4",
  "data": { }
}
```

### 3.2 `tengu_tool_use`

Captured at two points (start / end), joined on `span_id`.

```json
{
  "event_type": "tengu_tool_use",
  "phase": "start | end",
  "data": {
    "tool_name": "Bash | Read | Edit | Write | WebSearch | Agent ...",
    "tool_category": "execution | filesystem | network | agent | utility",
    "input_schema": "command | path | content | url | query",
    "input_summary": "<truncated first 200 chars>",
    "input_token_est": 42,
    "output_summary": "<truncated first 200 chars>",
    "output_token_est": 128,
    "duration_ms": 3254,
    "success": true,
    "error_type": null,
    "error_message": null
  }
}
```

**Rationale for new fields over existing claude_hook_events:**

- `phase`: Enables querying "tool in flight" at any point in time (gauge of concurrent tools).
- `tool_category`: Enables group-by category analysis (e.g., "how much time spent on filesystem vs network").
- `input_summary` / `output_summary`: Truncated to 200 chars for CK storage efficiency. Full payload still in `claude_hook_events` for drill-down.
- `input_token_est` / `output_token_est`: Estimated from character count / 4 (rough Claude tokenizer approximation). Enables cost analysis without actual token counting.

### 3.3 `tengu_session`

```json
{
  "event_type": "tengu_session",
  "phase": "start | end | heartbeat",
  "data": {
    "model": "claude-sonnet-4-20250514",
    "project_dir": "/home/dev/projects/kyb",
    "tool_count": 47,
    "error_count": 3,
    "duration_seconds": 8452,
    "total_input_tokens_est": 12000,
    "total_output_tokens_est": 28000,
    "cost_est_usd": 0.15,
    "stop_reason": "user_interrupt | task_complete | error | timeout"
  }
}
```

**Rationale:**
- `model`: Track which Claude model variant is being used.
- `tool_count`/`error_count`: Session-level rollup.
- `cost_est_usd`: Estimated cost using current Claude API pricing ($3/M input, $15/M output for Sonnet 4).
- `stop_reason`: Understand why sessions end.

### 3.4 `tengu_error`

```json
{
  "event_type": "tengu_error",
  "data": {
    "tool_name": "Bash",
    "error_class": "command_failure | tool_timeout | permission_denied | api_error | agent_crash",
    "error_message": "<truncated 500 chars>",
    "exit_code": 1,
    "is_transient": false,
    "is_known": true,
    "suggestion": null
  }
}
```

**Rationale:**
- `error_class`: Taxonomy for grouping and alerting.
- `is_transient`: True if retry might succeed (network blip, rate limit).
- `is_known`: True if this error pattern has been seen before (populated by a background dedup job).
- `suggestion`: Remediation hint for dashboard operators.

**Error Classification Taxonomy:**

| Class | Subclass | Examples | Transient? |
|-------|----------|----------|------------|
| `command_failure` | `exit_nonzero`, `syntax_error`, `file_not_found` | `bash: line 1: foo: command not found` | No |
| `tool_timeout` | `tool_exceeded_timeout` | Tool execution exceeded time limit | Maybe |
| `permission_denied` | `docker_denied`, `file_permission`, `sudo_required` | `Permission denied` | No |
| `api_error` | `rate_limited`, `auth_expired`, `network_error` | `429 Too Many Requests` | Yes |
| `agent_crash` | `hook_failure`, `session_terminated` | Hook script returned non-zero | Maybe |
| `unknown` | - | Unclassified error | Unknown |

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Claude Code Process                                                  │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────┐ │
│  │ claude_hook  │───▶│  tengu_emit  │───▶│  stdout / <jsonl file>  │ │
│  │ (existing)   │    │  (new)       │    │                         │ │
│  └─────────────┘    └──────────────┘    └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼ (tail)
                                     ┌──────────────┐
                                     │    Vector     │
                                     │  (sidecar or  │
                                     │   host agent) │
                                     └──────┬───────┘
                                            │ (Native TCP/HTTP)
                                            ▼
                                     ┌──────────────┐
                                     │  ClickHouse   │
                                     │  kyb database │
                                     │               │
                                     │ tengu_tool_use│
                                     │ tengu_session │
                                     │ tengu_error   │
                                     │ (raw tables)  │
                                     │               │
                                     │ .mv_*         │
                                     │ (materialized)│
                                     └──────────────┘
                                            │
                                            ▼
                                     ┌──────────────┐
                                     │   Grafana     │
                                     │   Dashboards  │
                                     └──────────────┘
```

### 4.1 Capture Layer: `tengu_emit`

A lightweight shell/Python adapter that wraps the existing claude_hook script output. It receives raw hook events from Claude Code via the existing hook mechanism (environment variables `CLAUDE_HOOK_*`), transforms them into `tengu_*` JSON events, and writes to a structured `.jsonl` file.

**Location:** `~/.kyb/bin/tengu-emit` (within the kyb workspace or per-container).

**Interface:**

```bash
# Invoked by claude_hook script as a post-processing step
tengu-emit --event-type <raw_event> \
           --session-id <uuid> \
           --tool-name <tool> \
           --tool-input <json> \
           --tool-result <json> \
           --duration-ms <ms> \
           --status <start|success|error>
```

**Output:** Appends a single JSON line to `~/.kyb/logs/tengu-events.jsonl`.

```jsonl
{"tengu_version":"1.0","event_id":"...","event_type":"tengu_tool_use","timestamp":"...","session_id":"...",...}
{"tengu_version":"1.0","event_id":"...","event_type":"tengu_session","timestamp":"...","session_id":"...",...}
{"tengu_version":"1.0","event_id":"...","event_type":"tengu_error","timestamp":"...","session_id":"...",...}
```

### 4.2 Collection Layer: Vector

Vector (running on the host or as a sidecar) tails `~/.kyb/logs/tengu-events.jsonl`, parses each JSON line, enriches with `hostname`, `environment`, and routes to the appropriate ClickHouse table via `native` sink.

**Source config:**

```toml
[sources.tengu_logs]
type = "file"
include = ["/home/dev/.kyb/logs/tengu-events.jsonl"]
read_from = "beginning"

[sources.tengu_logs.multiline]
mode = "newline_before"
start_pattern = '^{'
```

**Transform config:**

```toml
[transforms.parse_tengu]
type = "native"

[transforms.route_tengu]
type = "route"

[transforms.route_tengu.router]
tengu_tool_use = '.event_type == "tengu_tool_use"'
tengu_session = '.event_type == "tengu_session"'
tengu_error = '.event_type == "tengu_error"'
```

**Sink config:**

```toml
[sinks.ck_tool_use]
type = "clickhouse"
inputs = ["route_tengu.tengu_tool_use"]
host = "host.orb.internal"
table = "kyb.tengu_tool_use"
compression = "lz4"

[sinks.ck_session]
type = "clickhouse"
inputs = ["route_tengu.tengu_session"]
host = "host.orb.internal"
table = "kyb.tengu_session"
compression = "lz4"

[sinks.ck_error]
type = "clickhouse"
inputs = ["route_tengu.tengu_error"]
host = "host.orb.internal"
table = "kyb.tengu_error"
compression = "lz4"
```

### 4.3 Alternative: Vector-less fallback

If Vector is not available, `tengu-emit` can write directly to ClickHouse via the HTTP endpoint (`http://host.orb.internal:8123`). This is simpler for initial deployment but loses reliability guarantees (buffer, retry, backpressure).

---

## 5. ClickHouse Schema

### 5.1 `tengu_tool_use`

```sql
CREATE TABLE kyb.tengu_tool_use (
    tengu_version    LowCardinality(String),
    event_id         String,
    timestamp        DateTime64(3),
    session_id       String,
    agent_id         String,
    agent_type       LowCardinality(String),
    project          LowCardinality(String),
    environment      LowCardinality(String),
    phase            Enum8('start' = 1, 'end' = 2),
    tool_name        LowCardinality(String),
    tool_category    LowCardinality(String),
    input_summary    String,
    output_summary   String,
    input_token_est  UInt32,
    output_token_est UInt32,
    duration_ms      UInt32,
    success          Bool,
    error_type       LowCardinality(String),
    error_message    String,
    metadata         Map(String, String)
)
ENGINE = MergeTree
ORDER BY (session_id, timestamp)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(90)
SETTINGS index_granularity = 8192;
```

### 5.2 `tengu_session`

```sql
CREATE TABLE kyb.tengu_session (
    tengu_version        LowCardinality(String),
    event_id             String,
    timestamp            DateTime64(3),
    session_id           String,
    agent_id             String,
    agent_type           LowCardinality(String),
    project              LowCardinality(String),
    environment          LowCardinality(String),
    phase                Enum8('start' = 1, 'end' = 2, 'heartbeat' = 3),
    model                LowCardinality(String),
    project_dir          String,
    tool_count           UInt32,
    error_count          UInt32,
    duration_seconds     UInt32,
    total_input_tokens   UInt32,
    total_output_tokens  UInt32,
    cost_est_usd         Float32,
    stop_reason          LowCardinality(String),
    metadata             Map(String, String)
)
ENGINE = MergeTree
ORDER BY (session_id, timestamp)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(365)
SETTINGS index_granularity = 8192;
```

### 5.3 `tengu_error`

```sql
CREATE TABLE kyb.tengu_error (
    tengu_version    LowCardinality(String),
    event_id         String,
    timestamp        DateTime64(3),
    session_id       String,
    agent_id         String,
    agent_type       LowCardinality(String),
    project          LowCardinality(String),
    environment      LowCardinality(String),
    tool_name        LowCardinality(String),
    tool_category    LowCardinality(String),
    error_class      LowCardinality(String),
    error_subclass   LowCardinality(String),
    error_message    String,
    exit_code        Int16,
    is_transient     Bool,
    is_known         Bool,
    suggestion       String,
    metadata         Map(String, String)
)
ENGINE = MergeTree
ORDER BY (timestamp, error_class)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(90)
SETTINGS index_granularity = 8192;
```

### 5.4 Materialized Views

#### Tool latency by category (P50/P90/P99)

```sql
CREATE MATERIALIZED VIEW kyb.mv_tool_latency_daily
ENGINE = AggregatingMergeTree
ORDER BY (day, tool_category, tool_name)
AS SELECT
    toDate(timestamp) AS day,
    tool_category,
    tool_name,
    countState() AS calls,
    quantileState(0.5)(duration_ms) AS p50_ms,
    quantileState(0.9)(duration_ms) AS p90_ms,
    quantileState(0.99)(duration_ms) AS p99_ms,
    avgState(duration_ms) AS avg_ms,
    sumState(COALESCE(input_token_est, 0)) AS total_input_tokens,
    sumState(COALESCE(output_token_est, 0)) AS total_output_tokens
FROM kyb.tengu_tool_use
WHERE phase = 'end'
GROUP BY day, tool_category, tool_name;
```

#### Error rate by hour

```sql
CREATE MATERIALIZED VIEW kyb.mv_error_rate_hourly
ENGINE = AggregatingMergeTree
ORDER BY (hour, error_class)
AS SELECT
    toStartOfHour(timestamp) AS hour,
    error_class,
    countState() AS total,
    uniqState(session_id) AS affected_sessions,
    uniqState(tool_name) AS affected_tools
FROM kyb.tengu_error
GROUP BY hour, error_class;
```

#### Session summary daily

```sql
CREATE MATERIALIZED VIEW kyb.mv_session_summary_daily
ENGINE = AggregatingMergeTree
ORDER BY (day, agent_type)
AS SELECT
    toDate(timestamp) AS day,
    agent_type,
    countState() AS sessions,
    avgState(duration_seconds) AS avg_duration_sec,
    sumState(tool_count) AS total_tools,
    sumState(error_count) AS total_errors,
    sumState(cost_est_usd) AS total_cost_est
FROM kyb.tengu_session
WHERE phase = 'end'
GROUP BY day, agent_type;
```

### 5.5 Storage Estimates

| Table | Events/day | Row size | Daily volume | 90-day total |
|-------|-----------|----------|-------------|--------------|
| `tengu_tool_use` | ~8,000 | ~500 B | ~4 MB | ~360 MB |
| `tengu_session` | ~100 | ~300 B | ~30 KB | ~2.7 MB |
| `tengu_error` | ~500 | ~400 B | ~200 KB | ~18 MB |
| `mv_tool_latency_daily` | ~50 (agg rows) | ~200 B | ~10 KB | ~900 KB |
| `mv_error_rate_hourly` | ~120 (agg rows) | ~100 B | ~12 KB | ~1 MB |
| `mv_session_summary_daily` | ~10 (agg rows) | ~100 B | ~1 KB | ~90 KB |

**Total: <400 MB for 90 days.** Trivial for ClickHouse. No partitioning tuning needed.

---

## 6. Grafana Dashboards

### 6.1 Tool Usage Overview

Panels:
- **Tool calls per hour** -- Bar chart, stacked by `tool_category`. Query: `SELECT toStartOfHour(timestamp), tool_category, count() FROM tengu_tool_use WHERE phase='end' AND timestamp > now() - INTERVAL 24 HOUR GROUP BY ...`
- **Tool latency P50/P90/P99** -- Table grouped by `tool_name`. Query: `SELECT tool_name, quantile(0.5)(duration_ms), quantile(0.9)(duration_ms), quantile(0.99)(duration_ms) FROM mv_tool_latency_daily WHERE day=today() GROUP BY tool_name`
- **Success rate by tool** -- Gauge panel per tool. Ratio of `success=true` to total calls.
- **Token cost estimate** -- Area chart. Sum of `input_token_est + output_token_est` over time.

### 6.2 Session Dashboard

Panels:
- **Active sessions** -- Time series gauge counting distinct `session_id` where latest phase != 'end'.
- **Session duration distribution** -- Histogram of `duration_seconds` from `tengu_session WHERE phase='end'`.
- **Cost per session** -- Table of top-N sessions by `cost_est_usd`.
- **Session timeline** -- Gantt-like chart showing session start/end overlap.

### 6.3 Error Dashboard

Panels:
- **Error rate** -- Time series, `count() / total_requests` as rate. Query: `SELECT toStartOfHour(timestamp), count() FROM tengu_error WHERE timestamp > now() - INTERVAL 24 HOUR GROUP BY hour`
- **Error by class** -- Pie chart, grouped by `error_class`.
- **Top error messages** -- Table of most frequent `error_message` values.
- **Transient vs persistent** -- Stacked bar, `is_transient` boolean split.

### 6.4 Cost Dashboard

Panels:
- **Daily estimated cost** -- Bar chart, sum of `cost_est_usd` per day.
- **Cost by tool** -- Table, sum of `(input_token_est + output_token_est) / 4 * pricing` per tool.
- **Project cost breakdown** -- Pie chart, sum of `cost_est_usd` per `project` (if multiple projects).

---

## 7. Alerting Rules (Grafana / Feishu)

| Rule | Metric | Condition | Severity | Response |
|------|--------|-----------|----------|----------|
| Error rate spike | Error rate from `tengu_error` | >10% of all tool calls in 5min window | P1 | Feishu notification + auto-pause |
| Silent agent | Session heartbeat | No heartbeat for >30min in active session | P2 | Check agent, consider restart |
| Tool cascade failure | Same tool error | `Bash` error count >20 in 5min | P2 | Investigate environment issue |
| Cost anomaly | `cost_est_usd` | >$5 in 1 hour | P2 | Investigate runaway agent |
| Session crash | `stop_reason` | `error` or `timeout` for all sessions in 5min | P1 | Full environment down |

---

## 8. Implementation Plan

### Phase 1: tengu-emit (capture)

1. Write `~/.kyb/bin/tengu-emit` adapter script in Python or Bash
2. Integrate into `claude_hook` post-processing (appends after each hook invocation)
3. Validate JSON output format against ClickHouse schema
4. Test: run a Claude session, verify `.jsonl` file contains valid tengu events

### Phase 2: Vector pipeline (collection)

1. Write Vector TOML config for `tengu-events.jsonl` tail → CK sink
2. Deploy Vector alongside Claude Code (via `kyb exec` post-create or systemd user service)
3. Validate end-to-end: event → file → Vector → CK → `SELECT` returns data
4. Add retry, buffer, and backpressure config for reliability

### Phase 3: ClickHouse tables (storage)

1. Create all three raw tables (`tengu_tool_use`, `tengu_session`, `tengu_error`)
2. Create materialized views (`mv_tool_latency_daily`, `mv_error_rate_hourly`, `mv_session_summary_daily`)
3. Backfill historical data from existing `claude_hook_events` and `agent_events`
4. Compare `claude_hook_events` ↔ `tengu_tool_use` row counts for parity validation

### Phase 4: Grafana dashboards (visualization)

1. Create folder: "Claude Telemetry"
2. Create dashboards: Tool Usage, Session, Error, Cost
3. Set up dashboard auto-refresh (30s)
4. Add annotations for session boundaries

### Phase 5: Alerting (reaction)

1. Configure Grafana alert rules for P0/P1 conditions
2. Wire P1 alerts to Feishu via `kyb notify` or `cc-connect`
3. Test: induce an error (run invalid Bash command), verify alert fires

---

## 9. Future Work

| Item | Priority | Notes |
|------|----------|-------|
| Anomaly detection on tool duration | P3 | ML-based detection of outliers beyond fixed P99 thresholds |
| Agent cost attribution | P3 | Track which subagent/department incur costs |
| Claude model version tracking | P3 | `model` field in `tengu_session` enables model performance comparison |
| Token accuracy calibration | P3 | Compare estimated tokens vs actual from Claude API billing |
| Real-time streaming dashboard | P4 | WebSocket-based live view of agent activity |
| Historical trend analysis | P4 | Week-over-week and month-over-month comparisons |

---

## 10. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `tengu-emit` blocks Claude Code startup | Low | High | Use non-blocking write (asynchronous file append, never wait on flush) |
| JSONL file fills disk | Low | Medium | Set max size (100 MB default), rotate on SIGHUP, TTL cleanup via cron |
| Vector crashes silently | Low | Medium | Healthcheck endpoint, `kyb notify urgent` on Vector process death |
| ClickHouse write latency spikes | Low | Low | Tenyu-emit writes to local file first; CK sink is async. No data loss. |
| Schema drift (new event types) | Medium | Low | `metadata` Map field as catch-all. Version field routes unknown types. |

---

## 11. Comparison: Existing vs Proposed

| Aspect | Current (`claude_hook_events`) | Proposed (`tengu_*`) |
|--------|-------------------------------|----------------------|
| Schema | Single table, all events mixed | Three typed tables + materialized views |
| Event format | Raw hook dump | Normalized envelope with versioning |
| Cost tracking | None | Estimated token count + cost |
| Error classification | Raw error_message string | Taxonomy with class/subclass/transient |
| Query performance | Full scan on event_type filter | Partitioned, typed, aggregated views |
| Retention | 30 days | 90 days (tool/error), 365 days (session) |
| Alerting | None | Defined rules with severity mapping |
| Dashboard | None | Four dashboards defined |
| Vector pipeline | Assumed (not documented) | Fully specified TOML config |

---

## 12. Entity Relationship

```
tengu_session (1) ────── (N) tengu_tool_use
tengu_session (1) ────── (N) tengu_error
tengu_tool_use (N) ────── (M) tengu_error    -- an error may be associated with a specific tool use

Join keys:
  session_id across all three tables
  For tool_use <-> error correlation:
    tengu_tool_use.event_id -> tengu_error.metadata['source_event_id']
```

Relationships are logical (CK is a column store, not relational). Materialized views provide the aggregation layer that compensates for the lack of JOINs.

---

## Appendices

### A. Backfill query from claude_hook_events

```sql
-- Backfill tengu_tool_use from claude_hook_events PostToolUse rows
INSERT INTO kyb.tengu_tool_use
SELECT
    '1.0' AS tengu_version,
    generateUUIDv4() AS event_id,
    timestamp,
    session_id,
    metadata['agent_id'] AS agent_id,
    COALESCE(agent_type, 'unknown') AS agent_type,
    project,
    'production' AS environment,
    'end' AS phase,
    tool_name,
    CASE
        WHEN tool_name IN ('Bash', 'Agent', 'CronCreate') THEN 'execution'
        WHEN tool_name IN ('Read', 'Edit', 'Write') THEN 'filesystem'
        WHEN tool_name IN ('WebSearch', 'WebFetch') THEN 'network'
        WHEN tool_name IN ('TaskCreate', 'TaskStop', 'TaskList', 'TaskUpdate') THEN 'agent'
        ELSE 'utility'
    END AS tool_category,
    substring(tool_input, 1, 200) AS input_summary,
    substring(tool_result, 1, 200) AS output_summary,
    length(tool_input) / 4 AS input_token_est,
    length(tool_result) / 4 AS output_token_est,
    duration_ms,
    status = 'success' AS success,
    error_message,
    metadata
FROM kyb.claude_hook_events
WHERE event_type = 'PostToolUse';
```

### B. Pricing model for cost estimation

Based on Claude Sonnet 4 pricing (May 2026):

| Model | Input $/1M tokens | Output $/1M tokens | Cached input $/1M |
|-------|------------------|-------------------|-------------------|
| Claude Sonnet 4 | $3.00 | $15.00 | $0.30 |

Cost estimate formula:
```
cost_est = (input_tokens_est * $3.00 + output_tokens_est * $15.00) / 1_000_000
```

Token estimation heuristic: `length(text) / 4` (approximate, ~25% error margin). Acceptable for relative cost tracking; upgrade to actual tokenizer when Claude API billing data is available.

### C. Migration: existing `agent_events` integration

`agent_events` contains high-level boss decisions and agent lifecycle events that complement low-level tool telemetry. A lightweight materialized view can bridge the two:

```sql
CREATE MATERIALIZED VIEW kyb.mv_decision_session_map
ENGINE = MergeTree
ORDER BY (session_id, timestamp)
AS SELECT
    timestamp,
    session_id,
    agent_id,
    event_type AS decision_type,
    content AS decision_content
FROM kyb.agent_events;
```

This allows Grafana to show: "during session X, boss made decisions Y and Z, and used tools A, B, C."
