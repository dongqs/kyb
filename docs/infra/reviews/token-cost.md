---
decision: 稍后做
---

# Design: Token Cost Tracking for AI Agent Sessions

**Design doc:** `docs/infra/reviews/token-cost.md`
**Reviewer:** kyb
**Date:** 2026-05-23
**Scope:** Per-session/agent token usage tracking, cost estimation, budget alerts

---

## Summary

Claude Code (and other LLM-powered agents) consume API tokens with every interaction. Currently, token usage is visible only inside individual sandbox sessions -- there is no aggregated view of total spend, no per-agent breakdown, and no budget alerting. This design fills that gap by capturing token usage from each agent session, centralizing it in ClickHouse, estimating cost per model, and alerting when spend exceeds configurable thresholds.

The system is designed to be **model-agnostic** (works with any LLM provider that reports token counts) and **zero-effort** (runs as a background daemon, no changes to how agents work).

---

## Architecture

### Data Flow

```
Sandbox Container (Claude Code session)
    │  Claude Code stdout/stderr
    ▼
token-tracker.sh (lightweight daemon inside sandbox or boss)
    │  Parses token usage from Claude Code output
    │  (or receives it via env var / hook)
    ▼
    │  HTTP POST (JSON) to central CK:8123 or Kafka topic
    ▼
ClickHouse (infra.token_usage)
    │
    ├── Grafana dashboard (cost by day, by project, by agent)
    ├── Budget alert rules (daily/weekly/monthly thresholds)
    └── Patrol integration (cost anomaly detection)
```

### Where It Runs

Two deployment modes, chosen by priority:

**Mode A: Inside sandbox (most accurate, recommended)**

A lightweight shell daemon runs alongside Claude Code inside each sandbox container. It:
- Tails the session log for token usage reports
- Captures model name, input/output token counts, and timestamps
- Posts batches to ClickHouse or Kafka

This mode captures every API call, including those made by sub-agents and tools that the user never sees.

**Mode B: Inside boss container (zero sandbox changes)**

The boss container monitors all sandbox logs. It:
- Reads logs from each sandbox container via `docker logs`
- Parses token usage lines from Claude Code output
- Attributes usage to the sandbox/project

This mode requires no sandbox changes but may miss some token lines if log output is truncated.

### Token Capture Points

Claude Code outputs token usage in several places:

| Source | Format | Reliability |
|--------|--------|-------------|
| End-of-turn summary | `Tokens: Input: X, Output: Y, Cache Read: Z, Cache Write: W` | Always present at end of each turn |
| API response header | `x-request-id`, `anthropic-ratelimit-*` | Requires proxy capture |
| Anthropic dashboard API | Aggregated billing data | Post-hoc, not real-time |

**Initial implementation targets the end-of-turn summary** -- it is always visible in Claude Code stdout and requires no API changes.

---

## Token Usage Parsing

### Input Format

Claude Code prints token usage at the end of each turn:

```
Tokens: Input: 1532 Output: 421 Cache Read: 0 Cache Write: 178
```

### Parsing Strategy

```bash
# Minimal parser: extracts token counts from any Claude Code output line
parse_tokens() {
    local line="$1"
    local input=$(echo "$line" | grep -oP 'Input:\s*(\d+)' | grep -oP '\d+')
    local output=$(echo "$line" | grep -oP 'Output:\s*(\d+)' | grep -oP '\d+')
    local cache_read=$(echo "$line" | grep -oP 'Cache Read:\s*(\d+)' | grep -oP '\d+')
    local cache_write=$(echo "$line" | grep -oP 'Cache Write:\s*(\d+)' | grep -oP '\d+')

    if [ -n "$input" ] && [ -n "$output" ]; then
        echo "{\"input_tokens\":$input,\"output_tokens\":$output,\"cache_read\":${cache_read:-0},\"cache_write\":${cache_write:-0}}"
    fi
}
```

### Session Metadata

Each token usage record is enriched with session context:

| Field | Source | Example |
|-------|--------|---------|
| `session_id` | Sandbox container name or env var | `kyb-my-feature-abc123` |
| `project` | Env var `KYB_PROJECT` or container label | `kyb` |
| `agent_name` | Env var `CLAUDE_AGENT_NAME` or hostname | `boss`, `worker-1` |
| `model` | Env var `CLAUDE_MODEL` or from API response | `deepseek-v4-flash` |
| `container_id` | Docker container ID | `a1b2c3d4e5f6` |
| `boss_id` | Hostname of managing boss container | `kyb-infra-boss` |

---

## ClickHouse Schema

### Main Table: `infra.token_usage`

```sql
CREATE DATABASE IF NOT EXISTS infra;

CREATE TABLE infra.token_usage (
    -- Identity
    session_id      LowCardinality(String),      -- sandbox container name or session UUID
    project         LowCardinality(String),      -- project name (kyb, leyantech, etc.)
    agent_name      LowCardinality(String),      -- boss, worker-1, worker-2, etc.

    -- Token counts
    timestamp       DateTime64(3),               -- when the turn completed
    input_tokens    UInt32,                      -- prompt tokens consumed
    output_tokens   UInt32,                      -- completion tokens generated
    cache_read      UInt32 DEFAULT 0,            -- cached input tokens read
    cache_write     UInt32 DEFAULT 0,            -- cached input tokens written

    -- Model info
    model           LowCardinality(String),      -- model identifier (e.g., deepseek-v4-flash, claude-opus-4-7)
    provider        LowCardinality(String),      -- anthropic, openai, deepseek, etc.

    -- Cost (client-side estimation)
    estimated_cost  Float64 DEFAULT 0,           -- USD cost estimate for this turn
    currency        LowCardinality(String) DEFAULT 'USD',

    -- Attribution
    container_id    String DEFAULT '',           -- Docker container ID
    boss_id         LowCardinality(String),      -- boss container hostname
    cluster         LowCardinality(String),      -- mac-orbstack | aliyun | office

    -- Turn metadata
    turn_number     UInt32 DEFAULT 0,            -- sequential turn number within session
    duration_ms     UInt32 DEFAULT 0,            -- wall-clock duration of this turn
    error           UInt8 DEFAULT 0,             -- 1 if this turn had an error

    -- Ingestion
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (timestamp, project, session_id)
TTL timestamp + INTERVAL 365 DAY;
```

### Aggregated Table: `infra.token_usage_daily`

```sql
CREATE MATERIALIZED VIEW infra.token_usage_daily
ENGINE = SummingMergeTree
ORDER BY (date, project, agent_name, model)
AS SELECT
    toDate(timestamp) AS date,
    project,
    agent_name,
    model,
    provider,
    sum(input_tokens) AS total_input_tokens,
    sum(output_tokens) AS total_output_tokens,
    sum(cache_read) AS total_cache_read,
    sum(cache_write) AS total_cache_write,
    sum(estimated_cost) AS total_cost,
    count() AS turns
FROM infra.token_usage
GROUP BY date, project, agent_name, model, provider;
```

### Budget Table: `infra.token_budgets`

```sql
CREATE TABLE infra.token_budgets (
    project         LowCardinality(String),
    budget_period   LowCardinality(String),      -- daily | weekly | monthly
    budget_limit    Float64,                     -- USD limit
    alert_threshold Float64 DEFAULT 0.8,         -- alert at 80% of budget
    notify_channel  String DEFAULT 'feishu',     -- feishu | email | webhook
    enabled         UInt8 DEFAULT 1,
    _updated_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (project, budget_period);
```

### Cost Coefficients Table: `infra.model_pricing`

```sql
CREATE TABLE infra.model_pricing (
    model           LowCardinality(String),
    provider        LowCardinality(String),
    input_price     Float64,                     -- USD per 1M input tokens
    output_price    Float64,                     -- USD per 1M output tokens
    cache_read_price Float64 DEFAULT 0,          -- USD per 1M cache read tokens
    cache_write_price Float64 DEFAULT 0,         -- USD per 1M cache write tokens
    effective_from  Date,
    effective_to    Date DEFAULT '9999-12-31'
) ENGINE = ReplacingMergeTree(effective_to)
ORDER BY (model, effective_from);
```

**Initial pricing data:**

| Model | Provider | Input $/1M | Output $/1M | Cache Read $/1M | Cache Write $/1M |
|-------|----------|-----------|------------|----------------|-----------------|
| `deepseek-v4-flash` | deepseek | 0.35 | 1.40 | 0.07 | 0.35 |
| `claude-sonnet-4-6` | anthropic | 3.00 | 15.00 | 0.30 | 3.75 |
| `claude-sonnet-4-7` | anthropic | 3.00 | 15.00 | 0.30 | 3.75 |
| `claude-opus-4-7` | anthropic | 15.00 | 75.00 | 1.50 | 18.75 |
| `claude-haiku-3-5` | anthropic | 0.80 | 4.00 | 0.08 | 1.00 |
| `gpt-4o` | openai | 2.50 | 10.00 | 1.25 | 2.50 |

### Cost Estimation Formula

Client-side cost estimation per turn:

```
cost = (input_tokens / 1_000_000) * model.input_price
     + (output_tokens / 1_000_000) * model.output_price
     + (cache_read / 1_000_000) * model.cache_read_price
     + (cache_write / 1_000_000) * model.cache_write_price
```

This is an estimate -- actual billing may differ due to:
- Free tier credits
- Volume discounts
- Prompt caching granularity (128-token blocks on Anthropic)
- Special pricing agreements

The estimate is **conservative (slightly over)** to avoid surprise bills.

---

## Token Tracker Implementation

### Tracked Agent Wrapper

The recommended approach is a lightweight wrapper that sits in front of Claude Code inside the sandbox:

```bash
#!/usr/bin/env bash
# token-tracker.sh — wraps Claude Code to capture token usage
# Source this in .bashrc of sandbox containers.

TOKEN_LOG="/var/log/token-usage.$(date +%Y%m%d).jsonl"
SESSION_ID="${KYB_SANDBOX_NAME:-$(hostname)}"
PROJECT="${KYB_PROJECT:-unknown}"
AGENT_NAME="${CLAUDE_AGENT_NAME:-unknown}"
MODEL="${CLAUDE_MODEL:-unknown}"
BOSS_ID="$(hostname -f 2>/dev/null || hostname)"
CK_URL="${CK_URL:-http://100.104.244.99:8123}"
CK_TABLE="infra.token_usage"
FLUSH_INTERVAL=30  # seconds
TURN=0

# Start background flusher
_flush_loop() {
    while true; do
        sleep "$FLUSH_INTERVAL"
        if [ -f "$TOKEN_LOG" ] && [ -s "$TOKEN_LOG" ]; then
            local lines=$(wc -l < "$TOKEN_LOG")
            # Batch insert via CK HTTP
            curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_TABLE+FORMAT+JSONEachRow" \
                --data-binary @"$TOKEN_LOG" \
                --max-time 5 2>/dev/null || echo "[TOKEN] CK flush failed" >&2
            # Clear flushed lines
            : > "$TOKEN_LOG"
        fi
    done
}

# Start flush loop in background
_flush_loop &
FLUSHER_PID=$!

# Cleanup on exit
trap "kill $FLUSHER_PID 2>/dev/null; _flush_final" EXIT

_flush_final() {
    if [ -f "$TOKEN_LOG" ] && [ -s "$TOKEN_LOG" ]; then
        curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_TABLE+FORMAT+JSONEachRow" \
            --data-binary @"$TOKEN_LOG" \
            --max-time 5 2>/dev/null || true
    fi
}

# Parse token line and log it
log_tokens() {
    local line="$1"
    local input output cache_read cache_write

    input=$(echo "$line" | grep -oP 'Input:\s*(\d+)' | grep -oP '\d+')
    output=$(echo "$line" | grep -oP 'Output:\s*(\d+)' | grep -oP '\d+')
    cache_read=$(echo "$line" | grep -oP 'Cache Read:\s*(\d+)' | grep -oP '\d+')
    cache_write=$(echo "$line" | grep -oP 'Cache Write:\s*(\d+)' | grep -oP '\d+')

    [ -z "$input" ] && [ -z "$output" ] && return

    input=${input:-0}
    output=${output:-0}
    cache_read=${cache_read:-0}
    cache_write=${cache_write:-0}

    # Look up model pricing from env or use defaults
    local input_price="${TOKEN_INPUT_PRICE:-0.00000035}"
    local output_price="${TOKEN_OUTPUT_PRICE:-0.00000140}"
    local cache_read_price="${TOKEN_CACHE_READ_PRICE:-0.00000007}"
    local cache_write_price="${TOKEN_CACHE_WRITE_PRICE:-0.00000035}"

    # Calculate cost
    local cost=$(echo "scale=10;
        ($input * $input_price) +
        ($output * $output_price) +
        ($cache_read * $cache_read_price) +
        ($cache_write * $cache_write_price)" | bc 2>/dev/null || echo 0)

    TURN=$((TURN + 1))

    # Build JSON record
    local record
    record=$(cat <<JSON
{
  "session_id": "$SESSION_ID",
  "project": "$PROJECT",
  "agent_name": "$AGENT_NAME",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "input_tokens": $input,
  "output_tokens": $output,
  "cache_read": $cache_read,
  "cache_write": $cache_write,
  "model": "$MODEL",
  "provider": "anthropic",
  "estimated_cost": $cost,
  "container_id": "$(cat /proc/self/cgroup 2>/dev/null | head -1 | grep -oP '(?<=docker/)[a-f0-9]{12}' || echo '')",
  "boss_id": "$BOSS_ID",
  "cluster": "${CLUSTER_NAME:-unknown}",
  "turn_number": $TURN,
  "duration_ms": 0,
  "error": 0
}
JSON
    )
    echo "$record" >> "$TOKEN_LOG"
}

# Hook into Claude Code output
# If claude is started via a wrapper, pipe its output here:
# claude "$@" | tee >(grep '^Tokens:' | while read -r l; do log_tokens "$l"; done)
```

### Boss-Level Aggregator (Mode B)

For mode B (no sandbox changes), the boss container runs a daemon that tails all sandbox logs:

```bash
#!/usr/bin/env bash
# boss-token-collector.sh — runs inside kyb-infra-boss
# Tails sandbox container logs and parses token usage.

CK_URL="${CK_URL:-http://100.104.244.99:8123}"
CK_TABLE="infra.token_usage"
BOSS_ID="$(hostname)"
CLUSTER="${CLUSTER_NAME:-unknown}"

# Track which containers we're already tailing
declare -A TAILED_CONTAINERS

tail_sandbox() {
    local container="$1"
    docker logs --since 5m -f "$container" 2>/dev/null | while read -r line; do
        case "$line" in
            Tokens:*)
                # Extract project and agent from container labels
                local project=$(docker inspect "$container" \
                    --format '{{.Config.Labels.project}}' 2>/dev/null || echo "unknown")
                local agent=$(docker inspect "$container" \
                    --format '{{.Config.Labels.agent}}' 2>/dev/null || echo "unknown")
                local model=$(docker inspect "$container" \
                    --format '{{.Config.Labels.model}}' 2>/dev/null || echo "unknown")

                # Parse and submit
                parse_and_submit "$container" "$project" "$agent" "$model" "$line"
                ;;
        esac
    done
}

# Main loop: discover sandbox containers
while true; do
    for container in $(docker ps --format '{{.Names}}' | grep -E '^kyb-'); do
        if [ -z "${TAILED_CONTAINERS[$container]}" ]; then
            echo "[TOKEN] Starting tail for $container"
            tail_sandbox "$container" &
            TAILED_CONTAINERS[$container]=1
        fi
    done
    sleep 30
done
```

---

## Session and Cost Aggregation

### Session Lifecycle

Each Claude Code session (a `kyb enter` or `kyb exec` invocation) generates multiple token usage records -- one per turn. A session is identified by:

- **Session ID**: The sandbox container name (e.g., `kyb-my-feature-abc123`)
- **Birth-death window**: From container create to destroy

The token tracker accumulates records throughout the session and flushes to CK every 30 seconds. When the session ends (container stops), any remaining buffered records are flushed.

### Session-Level Metrics

```sql
-- Total tokens and cost for a specific session
SELECT
    session_id,
    min(timestamp) AS session_start,
    max(timestamp) AS session_end,
    dateDiff('second', min(timestamp), max(timestamp)) AS duration_s,
    sum(input_tokens) AS total_input,
    sum(output_tokens) AS total_output,
    sum(cache_read) AS total_cache_read,
    sum(cache_write) AS total_cache_write,
    sum(estimated_cost) AS total_cost,
    count() AS turns
FROM infra.token_usage
WHERE session_id = 'kyb-my-feature-abc123'
GROUP BY session_id;
```

### Agent-Level Metrics

```sql
-- Cost breakdown by agent within a project
SELECT
    agent_name,
    sum(estimated_cost) AS total_cost,
    sum(input_tokens) AS total_input,
    sum(output_tokens) AS total_output,
    count(DISTINCT session_id) AS sessions,
    count() AS turns
FROM infra.token_usage
WHERE project = 'kyb'
  AND timestamp >= now() - INTERVAL 7 DAY
GROUP BY agent_name
ORDER BY total_cost DESC;
```

---

## Grafana Dashboard

### Panel 1: Daily Cost (Time Series)

- **Metric**: `sum(estimated_cost)` by `project`
- **Granularity**: 1 day
- **Visualization**: Bar chart (stacked by project)
- **Purpose**: Daily spend overview

### Panel 2: Cost by Project (Pie/Table)

- **Metric**: `sum(estimated_cost)` by `project`
- **Filter**: Last 7 days, last 30 days
- **Visualization**: Pie chart + table with percentages
- **Purpose**: Which projects consume the most tokens

### Panel 3: Token Ratio (Time Series)

- **Metric**: `sum(output_tokens) / sum(input_tokens)` by `project`
- **Granularity**: 1 hour
- **Visualization**: Line chart
- **Purpose**: Monitor output/input ratio -- high ratio = verbose agents

### Panel 4: Cost by Model (Table)

- **Metric**: `sum(estimated_cost)` by `model`
- **Filter**: Last 7 days
- **Columns**: model, total_cost, total_input, total_output, turns
- **Purpose**: Which models are driving spend

### Panel 5: Active Sessions (Single Stat)

- **Metric**: `count(DISTINCT session_id)` where `timestamp > now() - INTERVAL 1 HOUR`
- **Purpose**: How many concurrent sessions are running

### Panel 6: Budget Burn Rate (Gauge)

- **Metric**: Current period spend vs limit
- **Per-project gauge**: Shows budget consumption as percentage
- **Threshold**: Yellow at 50%, Red at 80%
- **Purpose**: At-a-glance budget health

### Panel 7: Top-Talking Agents (Table)

- **Metric**: `sum(output_tokens)` per `session_id`
- **Filter**: Last 24h, limit 20
- **Purpose**: Find the most token-hungry sessions

### Panel 8: Cache Hit Rate (Time Series)

- **Metric**: `sum(cache_read) / (sum(input_tokens) + sum(cache_read)) * 100`
- **Granularity**: 1 hour
- **Visualization**: Line chart
- **Purpose**: Monitor prompt caching effectiveness

---

## Budget Alerts

### Alert Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────┐
│ ClickHouse   │     │ Alert Evaluator  │     │ Notify       │
│ (aggregated  │ ◄── │ (runs every 5min │ ──► │ (Feishu,     │
│  token_usage)│     │  inside patrol   │     │  Email, etc.)│
└──────────────┘     └──────────────────┘     └──────────────┘
```

### Alert Rules

| Rule | Condition | Severity | Action |
|------|-----------|----------|--------|
| Daily budget warning | Project spends > 80% of daily budget | P3 | Feishu message: "${project} at ${pct}% of daily budget ($${spent}/${limit})" |
| Daily budget exceeded | Project spends > 100% of daily budget | P2 | Feishu alert: "${project} exceeded daily budget! $${spent} > $${limit}" |
| Weekly budget warning | Project spends > 80% of weekly budget | P3 | Feishu message |
| Monthly budget exceeded | Project spends > 100% of monthly budget | P1 | Feishu alert + optionally pause new sessions |
| Cost anomaly (daily) | Today's spend > 3x trailing 7-day average | P2 | Feishu: "${project} cost anomaly: today $${today} vs avg $${avg}" |
| Cost spike (per session) | Single session cost > $10 | P3 | Feishu: "${session} cost $${cost} — investigate" |
| Agent gone rogue | Single agent spends > 50% of project daily budget | P2 | Feishu: "${agent} using ${pct}% of ${project} daily budget" |

### Budget Alert Query

```sql
-- Daily budget check for a specific project
WITH
    today AS (SELECT sum(estimated_cost) AS spent FROM infra.token_usage
              WHERE project = 'kyb' AND toDate(timestamp) = today()),
    budget AS (SELECT budget_limit, alert_threshold FROM infra.token_budgets
               WHERE project = 'kyb' AND budget_period = 'daily')
SELECT
    today.spent,
    budget.budget_limit,
    (today.spent / budget.budget_limit) * 100 AS pct,
    today.spent >= budget.budget_limit * budget.alert_threshold AS should_alert
FROM today, budget;
```

### Anomaly Detection Query

```sql
-- Detect cost anomaly: today vs trailing 7-day average
SELECT
    sumIf(estimated_cost, toDate(timestamp) = today()) AS today_cost,
    avg(estimated_cost) AS avg_daily_cost_7d
FROM infra.token_usage
WHERE project = 'kyb'
  AND timestamp >= now() - INTERVAL 8 DAY;

-- If today_cost > 3 * avg_daily_cost_7d → alert
```

---

## Integration Points

### Patrol Integration

The 5-minute patrol already runs on every boss. Add these checks:

```bash
# In patrol script:

# 1. Check for any project that exceeded daily budget
BUDGET_ALERTS=$(curl -s "$CK_URL?query=..."
    "SELECT project, sum(estimated_cost) AS spent
     FROM infra.token_usage
     WHERE toDate(timestamp) = today()
     GROUP BY project
     HAVING spent > (SELECT budget_limit FROM infra.token_budgets
                     WHERE budget_period='daily' AND project=project)"
    --max-time 5 2>/dev/null)

if [ -n "$BUDGET_ALERTS" ]; then
    echo "[PATROL] Budget exceeded: $BUDGET_ALERTS"
    # Trigger Feishu notification
    kyb notify urgent "Budget exceeded: $BUDGET_ALERTS"
fi

# 2. Check for cost anomalies
ANOMALY=$(curl -s "$CK_URL?query=..."
    "SELECT project, sum(estimated_cost) AS today_cost
     FROM infra.token_usage WHERE toDate(timestamp) = today()
     GROUP BY project
     HAVING today_cost > 3 * (
         SELECT avg(spent) FROM (
             SELECT sum(estimated_cost) AS spent
             FROM infra.token_usage
             WHERE project = project AND timestamp >= now() - INTERVAL 8 DAY
               AND toDate(timestamp) < today()
             GROUP BY toDate(timestamp)
         )
     )" --max-time 5 2>/dev/null)

if [ -n "$ANOMALY" ]; then
    echo "[PATROL] Cost anomaly: $ANOMALY"
    kyb notify urgent "Cost anomaly detected: $ANOMALY"
fi
```

### Opt-Out / Dry-Run Mode

Projects or sessions can opt out of tracking:

```bash
export TOKEN_TRACKING_DISABLE=1   # Disable token tracking for this session
export TOKEN_TRACKING_DRY_RUN=1   # Log to file only, don't send to CK
export TOKEN_TRACKING_INTERVAL=60 # Override flush interval (default 30s)
```

### CI Pipeline Integration

For CI pipelines that use agents (e.g., automated PR reviews), token tracking is essential because CI runs can be long and expensive:

```yaml
# Example: GitLab CI job with token tracking
token-tracked-review:
  script:
    - export TOKEN_TRACKING_INTERVAL=10
    - kyb exec review-agent -- "review this MR"
  after_script:
    # Force flush token usage
    - curl -s -X POST "$CK_URL?query=INSERT+INTO+infra.token_usage+FORMAT+JSONEachRow"
        --data-binary @"${TOKEN_LOG:-/dev/null}" --max-time 5 || true
```

---

## Deployment Plan

| Phase | What | Steps |
|-------|------|-------|
| **1** | Create CK tables | Run `CREATE TABLE` on central ClickHouse: `token_usage`, `token_usage_daily`, `token_budgets`, `model_pricing` | 1 command |
| **2** | Seed pricing data | Insert initial model pricing into `infra.model_pricing` | 1 command |
| **3** | Seed budgets | Insert budget limits for active projects into `infra.token_budgets` | Per project |
| **4** | Deploy token tracker | Add `token-tracker.sh` to boss container(s) (Mode B), or inject into sandbox entrypoint (Mode A) | Per boss |
| **5** | Verify ingestion | Run test queries on `infra.token_usage` to confirm data is flowing | Verify |
| **6** | Build dashboard | Create Grafana dashboard with panels 1-8 | Build |
| **7** | Add budget alerts | Wire budget queries into patrol cycle | Per boss |
| **8** | Enable for all | Enable token tracking on all sandbox containers | Enable |

---

## Estimated Volume

| Item | Value |
|------|-------|
| Turns per active session per hour | ~60 (1 turn per minute, conservative) |
| Concurrent sessions (peak) | ~10 |
| Records per day | ~10 sessions * ~8h * 60 turns = ~4,800 records/day |
| Records per month | ~144,000 records/month |
| Bytes per record | ~300 bytes (compressed ~60 bytes) |
| Storage per month | ~8.6 MB (compressed) |
| Storage per year | ~105 MB (compressed) |
| Daily aggregated rows | ~30 rows/day (few projects * few models) |

Volume is negligible. Even at 10x scale (100 concurrent sessions), storage is under 100 MB/month. TTL of 365 days on raw data is sufficient; daily aggregates can be kept indefinitely.

---

## Query Examples

### Cost by project this month

```sql
SELECT project, sum(estimated_cost) AS total_cost,
       sum(input_tokens) AS total_input,
       sum(output_tokens) AS total_output,
       count(DISTINCT session_id) AS sessions
FROM infra.token_usage
WHERE toMonth(timestamp) = toMonth(now())
  AND toYear(timestamp) = toYear(now())
GROUP BY project
ORDER BY total_cost DESC;
```

### Sessions that cost more than $5

```sql
SELECT session_id, project, agent_name,
       sum(estimated_cost) AS total_cost,
       count() AS turns,
       min(timestamp) AS started,
       max(timestamp) AS ended
FROM infra.token_usage
GROUP BY session_id, project, agent_name
HAVING total_cost > 5
ORDER BY total_cost DESC;
```

### Hourly token consumption (last 24h)

```sql
SELECT toStartOfHour(timestamp) AS hour,
       model,
       sum(input_tokens) AS input_tokens,
       sum(output_tokens) AS output_tokens,
       sum(estimated_cost) AS cost
FROM infra.token_usage
WHERE timestamp >= now() - INTERVAL 24 HOUR
GROUP BY hour, model
ORDER BY hour, cost DESC;
```

### Budget utilization for all projects

```sql
SELECT
    t.project,
    sum(t.estimated_cost) AS spent,
    b.budget_limit,
    (sum(t.estimated_cost) / b.budget_limit) * 100 AS pct,
    b.alert_threshold * 100 AS alert_at_pct,
    CASE
        WHEN pct >= 100 THEN 'EXCEEDED'
        WHEN pct >= b.alert_threshold * 100 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM infra.token_usage AS t
LEFT JOIN infra.token_budgets AS b
    ON t.project = b.project AND b.budget_period = 'daily'
WHERE toDate(t.timestamp) = today()
GROUP BY t.project, b.budget_limit, b.alert_threshold
ORDER BY pct DESC;
```

### Prompt caching efficiency

```sql
SELECT
    project,
    model,
    sum(input_tokens) AS input,
    sum(cache_read) AS cache_read,
    sum(cache_write) AS cache_write,
    (sum(cache_read) / sum(input_tokens + cache_read)) * 100 AS cache_hit_pct,
    sum(estimated_cost) AS cost,
    -- Estimated savings from caching
    sum(cache_read) / 1000000.0 * 0.30 AS cache_savings_usd
FROM infra.token_usage
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY project, model
ORDER BY cache_hit_pct DESC;
```

---

## Operational Concerns

### Accuracy

| Concern | Mitigation |
|---------|------------|
| Token counts are client-side estimates | Cost estimation uses official published pricing. Actual bill from provider may differ up to 5%. Treat estimates as "conservative upper bound". |
| Non-deterministic model selection | If model changes mid-session (fallback), each turn records its own model. Session-level cost is accurate if every turn has the right model. |
| Missed token lines (log truncation) | Flush interval keeps data loss under 30s. If the container dies before flush, the lost entry is at most 1 turn. |
| Multiple agents same container | Unlikely in current architecture (one Claude Code process per container). If needed, each agent writes to its own log file. |

### Privacy

Token usage records contain:
- **Session ID** (container name) -- identifies which sandbox but not the content
- **Token counts** -- aggregate counts, not the actual tokens/prompts
- **Model name** -- which LLM was used

No prompt content, completion content, or any user data is transmitted. Token usage is metadata only.

### Overhead

| Resource | Cost |
|----------|------|
| CPU per tracked session | Negligible (<0.1% of one core) -- parsing a regex line every 60s |
| Memory per tracked session | ~5 MB (JSONL buffer + background process) |
| Network per tracked session | ~300 bytes per turn, every 30s -- ~600 bytes/min |
| CK storage | ~60 MB/year at current scale |

---

## Summary

| Aspect | Design Decision |
|--------|----------------|
| Data source | Claude Code end-of-turn token summary (`Tokens: Input: X Output: Y ...`) |
| Parsing | Regex-based (no API dependency, works with any LLM that reports token counts) |
| Collection mode | Mode A (inside sandbox, per-agent daemon) preferred; Mode B (boss log tail) as fallback |
| Storage | ClickHouse with raw table + materialized daily aggregate |
| Cost estimation | Client-side using published model pricing, conservative (slightly over) |
| Budget alerts | Patrol-integrated SQL queries with Feishu notification |
| Dashboard | 8 Grafana panels covering cost, usage, efficiency, and active sessions |
| Volume | ~5 MB/month raw, ~60 MB/year compressed -- negligible |
| Privacy | Metadata only (token counts, model, session ID) -- no prompt content |
| TTL | 365 days for raw data; daily aggregates kept indefinitely |

The token cost tracking system provides complete visibility into LLM spend across all agents, projects, and sessions. It requires no changes to how Claude Code works, adds negligible overhead, and integrates into the existing observability stack (ClickHouse + Grafana + patrol cycle).

---

/人◕ ‿‿ ◕人＼
