---
decision: 稍后做
---

# Design: Token Efficiency Tracking per Agent Session

**Design doc:** `docs/infra/reviews/token-efficiency.md`
**Reviewer:** kyb
**Date:** 2026-05-23
**Scope:** Per-tool-call token burn, per-patrol-round efficiency, per-decision cost, optimization strategies

---

## Summary

The existing `token-cost.md` tracks aggregate spend (how many tokens per session, per project, per day). This design goes one level deeper: **efficiency**. Not just how many tokens were spent, but where they went, which tools burn the most, how much overhead the dispatch loop itself consumes, and what can be optimized.

Three core metrics drive the design:

1. **Tokens per tool call** -- which tools are the most expensive per invocation
2. **Tokens per patrol round** -- the overhead of the boss dispatch cycle
3. **Tokens per decision** -- the cost of thinking vs. doing

The goal is not just measurement but actionable optimization: detect waste, flag inefficient patterns, and suggest or auto-apply savings.

---

## Architecture

### Data Sources

The system consumes data from two existing ClickHouse tables plus a new per-turn efficiency bridge:

| Source | Table | What it provides |
|--------|-------|-----------------|
| claude_hook_events | `kyb.claude_hook_events` | Per-tool-call timing, tool name, input/output size |
| agent_events | `kyb.agent_events` | Decision events, dispatch events, handoffs |
| token_usage | `infra.token_usage` | Per-turn token counts, model, cost |
| New: efficiency_metrics | `infra.token_efficiency` | Derived efficiency metrics (this design) |

### Data Flow

```
Claude Code session sandbox
    │  Hook events (PreToolUse, PostToolUse)
    │  Token usage (end-of-turn summary)
    ▼
kyb.claude_hook_events ──┐
infra.token_usage ────────┤
kyb.agent_events ─────────┤
                          ▼
          efficiency-aggregator (cron, runs every 5 min)
                          │
                          ├── INSERT into infra.token_efficiency
                          ├── INSERT into infra.tool_cost_profile
                          └── Emit Feishu alert if efficiency drops below threshold
```

### Key Insight: No New Collection

The data already exists in `claude_hook_events` (tool-level) and `token_usage` (turn-level). The efficiency system is purely a **derived analysis layer** -- SQL aggregations and materialized views that join existing data. Zero new agent-side instrumentation.

---

## Metric 1: Tokens per Tool Call

### The Question

Which tools consume the most tokens per invocation? Is a `Read` of a 2000-line file more expensive than a `Bash` with a long result? How does `Edit` compare to `Write` in terms of output token cost?

### Join Strategy

Token usage is reported at turn granularity. Tool calls happen within a turn. We approximate tool-level cost by **apportioning turn tokens across tool calls in that turn**, weighted by tool input/output size.

```sql
-- Approximate tokens per tool call within a session turn
WITH turn_tools AS (
    SELECT
        he.session_id,
        he.timestamp AS turn_ts,
        he.tool_name,
        he.duration_ms,
        length(he.tool_input) AS input_bytes,
        length(he.tool_result) AS result_bytes,
        -- Count tool calls within this 2-second window (approximate turn boundary)
        row_number() OVER (PARTITION BY he.session_id ORDER BY he.timestamp) AS tool_seq
    FROM kyb.claude_hook_events he
    WHERE he.event_type = 'PostToolUse'
      AND he.timestamp >= now() - INTERVAL 1 HOUR
),
turn_tokens AS (
    SELECT
        tu.session_id,
        tu.timestamp AS turn_ts,
        tu.input_tokens,
        tu.output_tokens,
        tu.estimated_cost,
        tu.turn_number
    FROM infra.token_usage tu
    WHERE tu.timestamp >= now() - INTERVAL 1 HOUR
)
SELECT
    tt.tool_name,
    count() AS invocations,
    -- Average input/output bytes
    round(avg(tt.input_bytes)) AS avg_input_bytes,
    round(avg(tt.result_bytes)) AS avg_result_bytes,
    -- Estimated token proportion (rough: tokens ~ bytes/4 for English text)
    round(avg(tt.input_bytes) / 4) AS est_input_tokens_per_call,
    round(avg(tt.result_bytes) / 4) AS est_output_tokens_per_call,
    round(avg(tt.duration_ms)) AS avg_duration_ms
FROM turn_tools tt
GROUP BY tt.tool_name
ORDER BY avg_output_tokens_per_call DESC;
```

### Efficiency Table: `infra.tool_cost_profile`

```sql
CREATE TABLE infra.tool_cost_profile (
    -- Identity
    computed_at     DateTime64(3),
    tool_name       LowCardinality(String),
    model           LowCardinality(String),

    -- Call volume
    invocations     UInt32,
    sessions        UInt32,

    -- Average sizes (bytes)
    avg_input_bytes     UInt32,
    avg_result_bytes    UInt32,

    -- Estimated tokens
    est_input_tokens    UInt32,     -- avg_input_bytes / 4 (rough)
    est_output_tokens   UInt32,    -- avg_result_bytes / 4 (rough)

    -- Estimated cost
    est_cost_per_call   Float64,

    -- Timing
    avg_duration_ms     UInt32,
    p95_duration_ms     UInt32,

    -- Efficiency score (0-100, higher = more efficient)
    efficiency_score    UInt8,

    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(computed_at)
ORDER BY (tool_name, model, computed_at);
```

### Tool Efficiency Score

Each tool gets an efficiency score based on its output-to-input ratio and duration:

```
efficiency_score = 100 - clamp(
    (avg_output_tokens / max(avg_input_tokens, 1)) * 20   -- verbosity penalty
    + (avg_duration_ms / 10000) * 10                        -- slowness penalty
    - (cache_hit_rate * 5),                                  -- cache bonus
    0, 100
)
```

| Score Range | Label | Meaning |
|-------------|-------|---------|
| 80-100 | Efficient | Low overhead, fast, good cache utilization |
| 50-79 | Acceptable | Normal operating range |
| 20-49 | Inefficient | High output/input ratio, slow, or no caching |
| 0-19 | Wasteful | Urgent attention needed |

### Expected Tool Profiles

Based on observed patterns:

| Tool | Input Size | Result Size | Output/Input Ratio | Efficiency | Notes |
|------|-----------|-------------|-------------------|------------|-------|
| `Read` | Small (path) | Large (file content) | High (5-50x) | Medium | Necessary for context; caching helps |
| `Bash` | Small (command) | Varies (output) | Low-High | Variable | Depends on command output size |
| `Edit` | Medium (patch) | Small (confirmation) | Low (<1x) | High | Very efficient |
| `Write` | Large (content) | Small (confirmation) | Very Low (<0.1x) | Very High | Most efficient tool |
| `WebSearch` | Small (query) | Large (results) | High (5-20x) | Low | Expensive; consider limiting |
| `WebFetch` | Medium (URL+prompt) | Medium (content) | Medium (1-5x) | Medium | Summarization helps |
| `Bash` (long-running) | Small | Very Large (logs) | Very High (100x+) | Very Low | Truncate or pipe to file |
| `Agent` / `TaskCreate` | Medium (instructions) | Large (result) | Medium-High | Low-Medium | Subagent overhead |

---

## Metric 2: Tokens per Patrol Round

### The Boss Dispatch Pattern

In the boss-mode workflow, each "patrol round" consists of:

```
1. Boss reads current state (git status, docker ps, etc.)    -- tool calls ~3-5
2. Boss decides what to dispatch                              -- thinking + tool calls ~2-3
3. Boss dispatches sub-agents (create, brief, launch)         -- tool calls ~3-5 per agent
4. Boss monitors results (poll, wait)                         -- tool calls ~1-2 per check
5. Boss reports conclusion                                    -- tool calls ~1-2
```

A typical patrol round involves **10-20 tool calls** across **1-5 minutes**.

### Patrol Round Detection

Patrol rounds are identified by clustering `agent_events` into "dispatch episodes":

```sql
-- Detect patrol rounds from agent_events
WITH patrol_starts AS (
    SELECT
        session_id,
        timestamp,
        CASE
            WHEN event_type = 'decision' AND content LIKE '%dispatch%' THEN 1
            WHEN event_type = 'decision' AND content LIKE '%patrol%' THEN 1
            ELSE 0
        END AS is_patrol_start
    FROM kyb.agent_events
    WHERE timestamp >= now() - INTERVAL 7 DAY
),
patrol_sessions AS (
    SELECT
        session_id,
        timestamp as patrol_start,
        lead(timestamp) OVER (PARTITION BY session_id ORDER BY timestamp) AS next_event,
        is_patrol_start
    FROM patrol_starts
    WHERE is_patrol_start = 1
)
SELECT
    ps.session_id,
    ps.patrol_start,
    ps.next_event,
    -- Count tool calls in this patrol window
    (SELECT count(*) FROM kyb.claude_hook_events he
     WHERE he.session_id = ps.session_id
       AND he.timestamp BETWEEN ps.patrol_start AND COALESCE(ps.next_event, now())
    ) AS tool_calls,
    -- Sum tokens from token_usage
    (SELECT sum(input_tokens + output_tokens) FROM infra.token_usage tu
     WHERE tu.session_id = ps.session_id
       AND tu.timestamp BETWEEN ps.patrol_start AND COALESCE(ps.next_event, now())
    ) AS total_tokens,
    -- Cost
    (SELECT sum(estimated_cost) FROM infra.token_usage tu
     WHERE tu.session_id = ps.session_id
       AND tu.timestamp BETWEEN ps.patrol_start AND COALESCE(ps.next_event, now())
    ) AS patrol_cost
FROM patrol_sessions ps;
```

### Patrol Efficiency Table: `infra.patrol_efficiency`

```sql
CREATE TABLE infra.patrol_efficiency (
    -- Identity
    session_id      LowCardinality(String),
    patrol_start    DateTime64(3),
    patrol_end      DateTime64(3),

    -- Dispatch metrics
    agents_dispatched   UInt8,      -- number of sub-agents launched
    tool_calls          UInt16,     -- total tool calls in this patrol
    dispatch_calls      UInt8,      -- tool calls spent on dispatching (create, brief)
    monitor_calls       UInt8,      -- tool calls spent on monitoring
    decision_calls      UInt8,      -- tool calls spent on deciding

    -- Token metrics
    total_input_tokens  UInt32,
    total_output_tokens UInt32,
    total_tokens        UInt32,     -- input + output
    total_cost          Float64,

    -- Efficiency ratios
    output_input_ratio  Float64,    -- output_tokens / input_tokens (>1 = verbose)
    dispatch_overhead   Float64,    -- dispatch_calls / tool_calls (0-1, lower = better)
    tokens_per_agent    Float64,    -- total_tokens / agents_dispatched
    cost_per_agent      Float64,    -- total_cost / agents_dispatched

    -- Outcome
    outcome             LowCardinality(String),  -- completed, abandoned, failed
    patrol_duration_s   UInt32,                  -- seconds from patrol_start to patrol_end

    -- Efficiency grade
    efficiency_grade    LowCardinality(String),  -- A, B, C, D, F

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (patrol_start, session_id)
TTL toDate(patrol_start) + INTERVAL 90 DAY;
```

### Patrol Efficiency Grading

| Grade | Tokens/Agent | Dispatch Overhead | Output/Input Ratio | Meaning |
|-------|-------------|-------------------|-------------------|---------|
| A | < 5000 | < 0.2 | < 0.5 | Lean patrol, efficient dispatch |
| B | 5000-15000 | 0.2-0.3 | 0.5-1.0 | Normal |
| C | 15000-30000 | 0.3-0.4 | 1.0-2.0 | Overweight |
| D | 30000-50000 | 0.4-0.5 | 2.0-5.0 | Wasteful |
| F | > 50000 | > 0.5 | > 5.0 | Needs immediate attention |

### Patrol Round Cost Example

| Patrol Type | Tool Calls | Input Tokens | Output Tokens | Total Tokens | Cost (deepseek-v4) | Grade |
|------------|-----------|-------------|--------------|-------------|-------------------|-------|
| Quick status check | 8 | 4,000 | 1,200 | 5,200 | $0.0035 | A |
| Single agent dispatch | 12 | 8,500 | 3,200 | 11,700 | $0.0079 | B |
| Multi-agent (3) dispatch | 18 | 15,000 | 6,000 | 21,000 | $0.0142 | C |
| Heavy patrol with monitoring | 25 | 28,000 | 14,000 | 42,000 | $0.0284 | D |
| Runaway patrol (no dispatch) | 40+ | 60,000+ | 40,000+ | 100,000+ | $0.067+ | F |

---

## Metric 3: Tokens per Decision

### Decision Cost Breakdown

Each boss decision follows a pattern:

```
Observe ──→ Analyze ──→ Decide ──→ Dispatch ──→ Confirm
   │           │           │           │           │
   ▼           ▼           ▼           ▼           ▼
 tokens     tokens     tokens      tokens      tokens
 (small)   (medium)   (small)     (medium)    (small)
```

The decision itself (the actual choice) is cheap. The context-gathering (observe, analyze) and the execution (dispatch, confirm) dominate.

### Decision Events

Decisions are tagged in `agent_events` with `event_type = 'decision'`. Each decision has a content field describing what was decided:

```sql
-- Token cost per decision event
SELECT
    ae.session_id,
    ae.timestamp AS decision_time,
    ae.content,
    ae.tags['confidence'] AS confidence,
    -- Tokens spent in the 30 seconds before this decision
    (SELECT sum(input_tokens + output_tokens)
     FROM infra.token_usage tu
     WHERE tu.session_id = ae.session_id
       AND tu.timestamp BETWEEN ae.timestamp - INTERVAL 30 SECOND AND ae.timestamp
    ) AS context_tokens,
    -- Tokens spent in the 30 seconds after this decision
    (SELECT sum(input_tokens + output_tokens)
     FROM infra.token_usage tu
     WHERE tu.session_id = ae.session_id
       AND tu.timestamp BETWEEN ae.timestamp AND ae.timestamp + INTERVAL 30 SECOND
    ) AS execution_tokens,
    -- Decision cost = context + first response token
    (SELECT sum(estimated_cost)
     FROM infra.token_usage tu
     WHERE tu.session_id = ae.session_id
       AND tu.timestamp BETWEEN ae.timestamp - INTERVAL 30 SECOND AND ae.timestamp + INTERVAL 30 SECOND
    ) AS decision_cost
FROM kyb.agent_events ae
WHERE ae.event_type = 'decision'
  AND ae.timestamp >= now() - INTERVAL 7 DAY;
```

### Decision Efficiency Table: `infra.decision_efficiency`

```sql
CREATE TABLE infra.decision_efficiency (
    session_id      LowCardinality(String),
    decision_time   DateTime64(3),
    decision_type   LowCardinality(String),   -- dispatch, merge, investigate, ignore
    confidence      UInt8 DEFAULT 50,          -- 0-100, from agent tag or inferred

    -- Token breakdown
    context_tokens      UInt32,     -- tokens to gather context before deciding
    decision_tokens     UInt32,     -- tokens in the decision turn itself
    execution_tokens    UInt32,     -- tokens spent executing the decision
    total_decision_cost Float64,    -- USD cost of this decision cycle

    -- Efficiency
    thinking_ratio      Float64,    -- context_tokens / execution_tokens
    waste_flag          UInt8 DEFAULT 0,  -- 1 if this decision was reversed or abandoned
    outcome             LowCardinality(String),  -- accepted, reversed, ignored

    -- Context
    tool_calls_before   UInt8,      -- how many tool calls preceded the decision
    tool_calls_after    UInt8,      -- how many tool calls followed

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (decision_time, session_id);
```

### Decision Efficiency Insights

| Pattern | Context/Execution Ratio | Waste Flag Rate | Cost per Decision | Meaning |
|---------|----------------------|----------------|-------------------|---------|
| Decisive dispatch | 0.2-0.5 | < 5% | $0.001-0.005 | Healthy: quick context, clear action |
| Over-thinking | 2.0-10.0 | < 10% | $0.01-0.03 | Too much context before deciding |
| Reversal loop | 0.5-2.0 | > 30% | $0.02-0.05 | Decisions being made then undone |
| Decision paralysis | > 10.0 | > 50% | $0.05+ | Spinning on context, never committing |
| YOLO dispatch | < 0.1 | > 40% | $0.001 | No context, frequently wrong |

### The 70% Rule

The boss mode rule "decide at 70% confidence and move on" has a measurable efficiency impact:

- **Below 70%**: Each additional percentage point of confidence costs ~200 tokens (more reads, more analysis). Waiting for 90% costs ~4,000 extra tokens vs. deciding at 70%.
- **At 70%**: Average decision cost ~1,500 tokens. Average reversal rate ~15%.
- **At 50%**: Average decision cost ~500 tokens. Average reversal rate ~35% (net efficiency is worse due to rework).
- **Optimal**: 70% confidence minimizes total cost = decision_cost + reversal_cost * reversal_rate.

```sql
-- Measure the cost of over-thinking
SELECT
    confidence,
    avg(context_tokens) AS avg_context,
    avg(decision_tokens) AS avg_decision,
    avg(total_decision_cost) AS avg_cost,
    countIf(outcome = 'reversed') / count() AS reversal_rate,
    -- Total expected cost including reversals
    avg(total_decision_cost) * (1 + (countIf(outcome = 'reversed') / count())) AS expected_cost_with_reversal
FROM infra.decision_efficiency
WHERE confidence BETWEEN 10 AND 100
GROUP BY confidence
ORDER BY confidence;
```

---

## Metric 4: Waste Detection

### Waste Patterns

The efficiency aggregator runs every 5 minutes and flags these waste patterns:

#### Pattern 1: Runaway Tool Call (same tool, repeated, no progress)

A tool called 5+ times in a row without changing state suggests the agent is stuck:

```sql
SELECT
    session_id,
    tool_name,
    count(*) AS consecutive_calls,
    min(timestamp) AS started_at,
    max(timestamp) AS last_at,
    -- Total tokens burned
    sum(tu.input_tokens + tu.output_tokens) AS wasted_tokens
FROM kyb.claude_hook_events he
LEFT JOIN infra.token_usage tu
    ON he.session_id = tu.session_id
    AND abs(dateDiff('millisecond', he.timestamp, tu.timestamp)) < 2000
WHERE he.event_type = 'PostToolUse'
  AND he.timestamp >= now() - INTERVAL 1 HOUR
GROUP BY session_id, tool_name
HAVING consecutive_calls >= 5
   AND tool_name != 'Bash'  -- repeated Bash is normal (git status, etc.)
ORDER BY wasted_tokens DESC;
```

#### Pattern 2: Endless Read Loop (reading too much context)

Reading more than 50 files in a session without making progress:

```sql
SELECT
    he.session_id,
    count(*) AS files_read,
    count(DISTINCT he.tool_input) AS unique_files,
    round(avg(length(he.tool_result)) / 1024) AS avg_result_kb,
    sum(length(he.tool_result)) / 1024 / 1024 AS total_mb_read,
    count(DISTINCT tu.turn_number) AS turns,
    sum(tu.estimated_cost) AS cost
FROM kyb.claude_hook_events he
LEFT JOIN infra.token_usage tu
    ON he.session_id = tu.session_id
    AND abs(dateDiff('millisecond', he.timestamp, tu.timestamp)) < 2000
WHERE he.tool_name = 'Read'
  AND he.event_type = 'PostToolUse'
  AND he.timestamp >= now() - INTERVAL 1 HOUR
GROUP BY he.session_id
HAVING files_read > 50;
```

#### Pattern 3: Expensive Bash with Output Dump

A `Bash` tool call that returns > 100 KB of output:

```sql
SELECT
    session_id,
    timestamp,
    tool_input,
    length(tool_result) AS output_bytes,
    round(length(tool_result) / 1024) AS output_kb,
    -- Estimate: tokens ~ bytes/4
    round(length(tool_result) / 4) AS est_wasted_tokens,
    round(length(tool_result) / 4 * 0.00000035) AS est_wasted_cost
FROM kyb.claude_hook_events
WHERE tool_name = 'Bash'
  AND event_type = 'PostToolUse'
  AND length(tool_result) > 100 * 1024  -- > 100 KB
  AND timestamp >= now() - INTERVAL 1 HOUR
ORDER BY output_bytes DESC;
```

#### Pattern 4: Decision Reversal (decide, undo, decide again)

```sql
SELECT
    a.session_id,
    a.timestamp AS first_decision,
    b.timestamp AS reversal,
    dateDiff('second', a.timestamp, b.timestamp) AS gap_s,
    a.content AS original_decision,
    b.content AS reversed_decision,
    -- Cost of the reversal loop
    (SELECT sum(estimated_cost)
     FROM infra.token_usage tu
     WHERE tu.session_id = a.session_id
       AND tu.timestamp BETWEEN a.timestamp AND b.timestamp
    ) AS reversal_cost
FROM kyb.agent_events a
JOIN kyb.agent_events b
    ON a.session_id = b.session_id
    AND b.event_type = 'decision'
    AND b.timestamp > a.timestamp
    AND b.timestamp < a.timestamp + INTERVAL 5 MINUTE
    AND b.content LIKE '%actually%' OR b.content LIKE '%wait%' OR b.content LIKE '%revert%' OR b.content LIKE '%never mind%'
WHERE a.event_type = 'decision'
  AND a.timestamp >= now() - INTERVAL 7 DAY;
```

### Waste Alerts Table: `infra.efficiency_waste`

```sql
CREATE TABLE infra.efficiency_waste (
    detected_at     DateTime64(3),
    session_id      LowCardinality(String),
    waste_type      LowCardinality(String),
        -- 'runaway_tool' | 'endless_read' | 'bash_dump' | 'decision_reversal' | 'over_think' | 'noop_cycle'
    tool_name       LowCardinality(String) DEFAULT '',
    metric          Float64,            -- count, bytes, tokens, or cost depending on type
    estimated_waste Float64,            -- estimated tokens wasted
    estimated_cost  Float64,            -- estimated USD wasted
    severity        Enum8('info' = 1, 'warning' = 2, 'critical' = 3),
    detail          String DEFAULT '',

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detected_at, severity)
TTL toDate(detected_at) + INTERVAL 30 DAY;
```

---

## Metric 5: Per-Session Efficiency Report

### Session Summary Query

A comprehensive efficiency report for any session:

```sql
WITH session_data AS (
    SELECT
        tu.session_id,
        tu.project,
        tu.agent_name,
        tu.model,
        min(tu.timestamp) AS session_start,
        max(tu.timestamp) AS session_end,
        dateDiff('second', min(tu.timestamp), max(tu.timestamp)) AS duration_s,
        sum(tu.input_tokens) AS input_tokens,
        sum(tu.output_tokens) AS output_tokens,
        sum(tu.cache_read) AS cache_read,
        sum(tu.cache_write) AS cache_write,
        sum(tu.estimated_cost) AS total_cost,
        count() AS turns,
        count(DISTINCT he.tool_name) AS distinct_tools,
        count(*) AS total_tool_calls
    FROM infra.token_usage tu
    LEFT JOIN kyb.claude_hook_events he
        ON tu.session_id = he.session_id
        AND abs(dateDiff('millisecond', tu.timestamp, he.timestamp)) < 5000
    WHERE tu.session_id = :session_id
    GROUP BY tu.session_id, tu.project, tu.agent_name, tu.model
)
SELECT
    session_id, project, agent_name, model,
    session_start, session_end, duration_s,
    input_tokens, output_tokens, cache_read, cache_write,
    total_cost,
    turns, distinct_tools, total_tool_calls,

    -- Efficiency ratios
    round(output_tokens * 1.0 / nullIf(input_tokens, 0), 2) AS output_input_ratio,
    round(total_tool_calls * 1.0 / nullIf(turns, 0), 1) AS tools_per_turn,
    round(duration_s * 1.0 / nullIf(turns, 0), 1) AS seconds_per_turn,
    round(turns * 1.0 / nullIf(duration_s, 0) * 3600, 1) AS turns_per_hour,
    round(total_cost * 1.0 / nullIf(turns, 0), 4) AS cost_per_turn,
    round(total_cost * 1.0 / nullIf(total_tool_calls, 0), 4) AS cost_per_tool_call,

    -- Cache efficiency
    round(cache_read * 1.0 / nullIf(input_tokens + cache_read, 0) * 100, 1) AS cache_hit_pct,
    round(cache_write * 1.0 / nullIf(turns, 0), 0) AS cache_write_per_turn,

    -- Efficiency score (0-100)
    round(
        100
        - greatest(0, (output_input_ratio - 0.5) * 10)      -- verbosity penalty
        - greatest(0, (60.0 / nullIf(turns_per_hour, 0) - 1) * 5)  -- slowness penalty (target: 1 turn/min)
        + cache_hit_pct * 0.3                                   -- cache bonus
    ) AS efficiency_score
FROM session_data;
```

### Efficiency Score Components

| Component | Weight | Ideal Range | Impact |
|-----------|--------|-------------|--------|
| Output/Input Ratio | 10x penalty per point above 0.5 | 0.2 - 0.5 | Verbose agents score lower |
| Turns per Hour | 5x penalty if below 60/min | 30-120/min | Very slow or very fast sessions |
| Cache Hit Rate | 0.3x bonus per % | > 30% | Caching directly reduces cost |
| Tools per Turn | Not scored directly | 2-5 | Too many = inefficient, too few = not making progress |

### Session Efficiency Grades

| Score | Grade | Meaning |
|-------|-------|---------|
| 90-100 | S | Optimal: fast, cached, concise |
| 75-89 | A | Efficient: minor improvements possible |
| 50-74 | B | Acceptable: normal operating range |
| 25-49 | C | Below average: review tool usage patterns |
| 10-24 | D | Poor: significant waste detected |
| 0-9 | F | Critical: immediate intervention needed |

---

## Grafana Dashboards

### Dashboard 1: Token Efficiency Overview

**Purpose**: At-a-glance efficiency health across all sessions.

**Panels**:
1. **Efficiency Score Gauge** -- Current 24h average efficiency score (0-100), colored by grade
2. **Sessions by Grade** -- Bar chart of session count per grade (S/A/B/C/D/F)
3. **Waste by Type** -- Stacked area chart of waste tokens by waste type (runaway, endless read, bash dump, reversal)
4. **Tool Cost Profile** -- Table of tools sorted by cost per call, with efficiency score
5. **Cache Hit Rate Trend** -- Line chart of cache hit % over last 7 days

### Dashboard 2: Patrol Round Deep Dive

**Purpose**: Analyze boss dispatch overhead.

**Panels**:
1. **Patrol Cost per Round** -- Time series of patrol round costs
2. **Dispatch Overhead Ratio** -- Gauge showing what % of patrol is dispatch vs. execution
3. **Agents per Patrol** -- Histogram of agents dispatched per patrol round
4. **Patrol Grade Distribution** -- Pie chart of A/B/C/D/F grades
5. **Wasted Patrols** -- Table of patrol rounds with F grade, with drill-down to waste flags

### Dashboard 3: Decision Cost Analysis

**Purpose**: How much does each decision cost?

**Panels**:
1. **Cost per Decision** -- Time series of average decision cost
2. **Decision Reversal Rate** -- % of decisions reversed within 5 minutes
3. **Confidence vs. Cost** -- Scatter plot of confidence % vs. decision cost
4. **Over-thinking Index** -- Gauge showing context/execution ratio
5. **Top Costly Decisions** -- Table of most expensive decisions with context

---

## Optimization Strategies

### Strategy 1: Tool-Level Optimization

| Tool | Optimization | Est. Savings |
|------|-------------|-------------|
| `Read` | Use file-specific reads instead of directory-wide. Set `limit` parameter. | 30-50% |
| `Bash` | Pipe large output to file instead of returning to agent. Use `grep`/`head` to limit output. | 40-70% |
| `WebFetch` | Use `limit` parameter to cap result size. Prefer search over full fetch. | 20-40% |
| `WebSearch` | Use `allowed_domains` and `blocked_domains` to narrow scope. | 20-30% |
| `Edit` | Already efficient. Group edits into fewer, larger patches. | 5-10% |
| `Write` | Already optimal. No changes needed. | - |

### Strategy 2: Prompt Caching Optimization

Prompt caching is the single biggest token saver for repeated sessions:

```sql
-- Measure cache effectiveness per project
SELECT
    project,
    model,
    sum(input_tokens) AS input,
    sum(cache_read) AS cache_hit,
    sum(cache_write) AS cache_write,
    round(sum(cache_read) * 1.0 / nullIf(sum(input_tokens) + sum(cache_read), 0) * 100, 1) AS hit_rate,
    round((sum(cache_read) * 0.30 + sum(cache_write) * 3.75) / 1000000, 2) AS cache_savings_usd
FROM infra.token_usage
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY project, model
ORDER BY cache_savings_usd DESC;
```

**Cache Optimization Rules**:
1. **Session continuity** -- Longer sessions have higher cache hit rates. Avoid short, disconnected sessions.
2. **Repeated context** -- Same project = same system prompt = cache hit. Switching projects costs a cache write.
3. **System prompt structure** -- Put stable content (instructions, rules) at the beginning, variable content at the end. Cache is most effective for the first 40K tokens.

### Strategy 3: Dispatch Efficiency

Reduce the overhead of each patrol round:

```bash
# Best practices embedded into the dispatch script:

# Bad: Separate status calls (3-5 tool calls)
#   -> tool_call: git status
#   -> tool_call: git log
#   -> tool_call: docker ps

# Good: Combined status (1 tool call)
#   -> tool_call: "git status --short && echo "---" && git log --oneline -5 && echo "---" && docker ps --format '{{.Names}}'"
#   Saves: 2-4 tool calls per patrol, ~2000 tokens

# Bad: Read multiple files separately
#   -> tool_call: Read file1
#   -> tool_call: Read file2
#   -> tool_call: Read file3

# Good: Read related files in sequence (first read primes cache)
#   -> tool_call: Read file1 (cache write on system prompt)
#   -> tool_call: Read file2 (cache hit on system prompt, ~90% input saved)
#   -> tool_call: Read file3 (cache hit on system prompt)
```

### Strategy 4: Decision Optimization

| Technique | Action | Est. Savings |
|-----------|--------|-------------|
| Faster decisions | Decide at 70% confidence, not 90% | 30-50% per decision |
| Batch context gathering | Read all needed context in fewer, larger reads | 20-30% |
| Avoid reversal loops | When confidence is low, dispatch a subagent instead of re-deciding | 40-60% on reversal-prone decisions |
| Use subagent for exploration | Expensive context gathering done by cheaper model | 50-70% on exploration tasks |

### Strategy 5: Model Selection

Different models have different cost profiles for different tasks:

| Task Type | Recommended Model | Cost/Turn | Efficiency Notes |
|-----------|------------------|-----------|-----------------|
| Quick status check | deepseek-v4-flash | $0.0003-0.001 | Cheap, fast, good for patrol |
| Code review | claude-sonnet-4-7 | $0.003-0.01 | Better judgment, moderate cost |
| Complex design | claude-opus-4-7 | $0.02-0.10 | Expensive but thorough |
| File operation (edit/write) | deepseek-v4-flash | $0.0005-0.002 | Simple operations don't need premium models |
| Data analysis | deepseek-v4-flash | $0.001-0.005 | Numeric/analytic tasks are commodity |
| Security review | claude-sonnet-4-7 | $0.005-0.02 | Balance of cost and thoroughness |

**Model routing rule**: Use deepseek-v4-flash for 80% of tool calls, reserve premium models for decisions that need them. This alone can reduce total cost by 40-60%.

---

## Patrol Integration

### Efficiency Check Step

Add to the existing 5-minute patrol cycle:

```bash
# In patrol script: token efficiency check
echo "  [PATROL] Running token efficiency analysis..."

# 1. Detect waste patterns
WASTE=$(docker exec kyb-infra-boss bash -c "
  curl -s -X POST 'http://host.docker.internal:8123/' \
    -d 'SELECT waste_type, count(), sum(estimated_waste) AS total_waste
        FROM infra.efficiency_waste
        WHERE detected_at >= now() - INTERVAL 5 MINUTE
          AND severity IN (\"warning\", \"critical\")
        GROUP BY waste_type
        ORDER BY total_waste DESC
        FORMAT PrettyCompact'
" --max-time 5)

if echo "$WASTE" | grep -qE 'critical|warning'; then
    echo "  [PATROL] Token waste detected:"
    echo "$WASTE"
    # Alert if severe
    CRITICAL_WASTE=$(echo "$WASTE" | grep critical | awk '{print $NF}')
    if [ -n "$CRITICAL_WASTE" ]; then
        kyb notify urgent "Token waste detected: $CRITICAL_WASTE tokens in last 5 min"
    fi
fi

# 2. Update patrol efficiency table
PATROL_TOKENS=$(curl -s -X POST 'http://host.docker.internal:8123/' \
  -d "SELECT sum(input_tokens + output_tokens) AS tokens
      FROM infra.token_usage
      WHERE agent_name = 'boss'
        AND timestamp >= now() - INTERVAL 5 MINUTE
      FORMAT TabSeparated" --max-time 3)

echo "  [PATROL] Boss tokens in last 5 min: ${PATROL_TOKENS:-0}"

# 3. Check for runaway sessions
RUNAWAY=$(curl -s -X POST 'http://host.docker.internal:8123/' \
  -d "SELECT session_id, sum(input_tokens + output_tokens) AS tokens
      FROM infra.token_usage
      WHERE timestamp >= now() - INTERVAL 30 MINUTE
      GROUP BY session_id
      HAVING tokens > 100000
      FORMAT PrettyCompact" --max-time 3)

if [ -n "$RUNAWAY" ]; then
    echo "  [PATROL] High-token sessions (>100K in 30 min):"
    echo "$RUNAWAY"
fi
```

### Feishu Alert Triggers

| Condition | Severity | Message |
|-----------|----------|---------|
| Session efficiency grade F | P3 | "Session ${session}: efficiency grade F (${score}/100). Waste: ${waste_tokens} tokens ($${cost})" |
| Patrol round grade D or F | P3 | "Patrol round at ${time}: grade ${grade}. Overhead ${overhead}%, ${tokens} tokens" |
| Decision reversal rate > 30% (rolling 1h) | P3 | "High decision reversal rate: ${rate}% in last hour. Cost of reversals: $${cost}" |
| Runaway tool detected (5+ consecutive) | P4 | "Runaway ${tool} in ${session}: ${count} consecutive calls" |
| Bash dump > 500 KB | P4 | "Large Bash output in ${session}: ${kb} KB (est. ${tokens} tokens wasted)" |
| Cache hit rate < 10% for any project (rolling 24h) | P4 | "Low cache hit rate for ${project}: ${rate}%. Consider longer sessions." |

---

## Implementation Plan

| Phase | What | Steps | Time |
|-------|------|-------|------|
| **1** | Create CK tables | `infra.tool_cost_profile`, `infra.patrol_efficiency`, `infra.decision_efficiency`, `infra.efficiency_waste` | 15 min |
| **2** | Build aggregator | SQL queries for waste detection, patrol round detection, decision cost analysis | 1 hour |
| **3** | Wire into patrol | Add efficiency check step to 5-min patrol cycle | 30 min |
| **4** | Dashboard | Build 3 Grafana dashboards (Overview, Patrol, Decision) | 2 hours |
| **5** | Alerts | Configure Feishu alerts for efficiency degradation | 30 min |
| **6** | Model routing script | Create dispatch helper that routes tasks to optimal model | 1 hour |
| **7** | Optimization playbook | Document per-tool optimization rules as executable scripts | 1 hour |
| **8** | Baseline | Record current efficiency baseline for all projects | 30 min |

---

## Estimated Volume

| Table | Rows/Day | Storage/Year | TTL |
|-------|---------|-------------|-----|
| `infra.tool_cost_profile` | ~500 (ReplacingMergeTree) | ~5 MB | None (keep forever) |
| `infra.patrol_efficiency` | ~200 (one per patrol round) | ~10 MB | 90 days |
| `infra.decision_efficiency` | ~500 (one per decision) | ~15 MB | 90 days |
| `infra.efficiency_waste` | ~100 (one per waste flag) | ~5 MB | 30 days |

Total: ~35 MB/year for the active tables, plus ~5 MB for the permanent profile table. Negligible.

---

## Success Metrics

| Metric | Target | How to Measure |
|--------|--------|---------------|
| Average session efficiency score | > 75 (B+) | `avg(efficiency_score)` from session reports |
| Patrol round grade | A or B for 90% of rounds | `countIf(grade in ('A','B')) / count()` |
| Decision reversal rate | < 15% | `countIf(outcome='reversed') / count()` |
| Cache hit rate | > 30% across all projects | `sum(cache_read) / sum(input_tokens + cache_read)` |
| Waste tokens per day | < 5% of total tokens | `sum(estimated_waste) / sum(total_tokens)` |
| Dispatch overhead | < 25% of patrol cost | `sum(dispatch_cost) / sum(patrol_cost)` |
| Model routing savings | > 30% cost reduction | Compare actual cost vs. all-opus baseline |

---

## References

- Token cost tracking: `docs/infra/reviews/token-cost.md`
- Claude telemetry capture: `docs/infra/reviews/claude-telemetry.md`
- Boss decision latency: `docs/infra/reviews/boss-decision-latency.md`
- Claude Code hooks system: `claude_hook_events` table documentation
- Agent dispatch events: `agent_events` table documentation
- Patrol cycle: `docs/infra/5min-patrol-guide.md`

---

## Summary

| Aspect | Design Decision |
|--------|----------------|
| Approach | Zero new collection -- derived analysis from existing `claude_hook_events` + `token_usage` + `agent_events` |
| Core metrics | Tokens per tool call, per patrol round, per decision, waste detection |
| Waste patterns | Runaway tools, endless reads, bash dumps, decision reversals |
| Efficiency scoring | 0-100 scale with grades S/A/B/C/D/F, combining ratio, speed, and cache metrics |
| Optimization | Tool-level, cache-level, dispatch-level, decision-level, model-level |
| Dashboards | 3 Grafana dashboards: Overview, Patrol Deep Dive, Decision Cost Analysis |
| Alerting | Patrol-integrated Feishu alerts for F-grade sessions, high waste, low cache |
| Patrol integration | 3 checks added to existing 5-min cycle: waste scan, efficiency write, runaway detection |
| Storage | ~35 MB/year for active tables, ~5 MB permanent profile |
| Key success metric | Average session efficiency score > 75, waste < 5% of total tokens |

The token efficiency tracking system turns existing telemetry into actionable optimization guidance. Every session, every patrol round, and every decision gets an efficiency score -- not just for cost accounting, but for driving real improvements in how agents consume tokens.

> ／人◕ ‿‿ ◕人＼
