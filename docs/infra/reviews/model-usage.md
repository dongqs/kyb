---
decision: 稍后做
---

# Claude Model Usage Tracking

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Track Claude model usage per agent and session -- which models (Opus, Sonnet, Haiku, Flash) are used, by whom, and at what cost.

---

## Table of Contents

1. [Why Track Model Usage](#1-why-track-model-usage)
2. [Data Sources](#2-data-sources)
3. [Model Tier Definitions & Pricing](#3-model-tier-definitions--pricing)
4. [Per-Agent / Per-Session Tracking](#4-per-agent--per-session-tracking)
5. [Model Selection Patterns](#5-model-selection-patterns)
6. [Cost Tracking Queries](#6-cost-tracking-queries)
7. [Grafana Dashboard](#7-grafana-dashboard)
8. [Alerts](#8-alerts)
9. [Optimization Strategy](#9-optimization-strategy)
10. [Appendix: Known Model Identifiers](#10-appendix-known-model-identifiers)

---

## 1. Why Track Model Usage

Model usage tracking answers three questions:

1. **Cost attribution** -- Which agent, session, or project is consuming budget?
2. **Model fit** -- Is a $15/Mtok model being used for a task a $0.15/Mtok model could handle?
3. **Pattern detection** -- Are subagents defaulting to expensive models when the boss intended cheap ones?

Without tracking, model selection is invisible. The boss dispatches a task and has no idea whether the agent used Opus (slow, expensive, thorough) or Haiku (fast, cheap, shallow). This document makes model usage measurable so the boss can adjust dispatch strategy.

### 1.1 Existing Infrastructure

The hooks-to-ClickHouse pipeline already captures the `model` field on every hook event:

```sql
model String  -- e.g. "claude-sonnet-4-20250514", "claude-3-5-haiku-20241022"
```

This means we already have per-event model data. The gap is:
- No cost calculation (model string -> $/Mtok -> cost per event)
- No aggregation by agent or session
- No dashboard or alerting
- No model selection guidance for agents

This document fills those gaps.

---

## 2. Data Sources

### 2.1 Primary: Hooks-to-ClickHouse Pipeline

Every Claude Code hook event (PreToolUse, PostToolUse, Stop, SessionStart, etc.) carries the `model` field. The existing `kyb.claude_hook_events` table in ClickHouse is the source of truth.

**Relevant columns:**

| Column | Type | Example | Source |
|--------|------|---------|--------|
| `timestamp` | DateTime64(3) | `2026-05-23 14:30:00.123` | Claude Code |
| `session_id` | String | `abc-123-def` | Claude Code |
| `agent_id` | LowCardinality(String) | `kyb-infra-boss` | Capture script enrichment |
| `parent_session_id` | String | `boss-xyz-789` | Claude Code (SubagentStart) |
| `event_type` | LowCardinality(String) | `Stop`, `SessionStart` | Claude Code |
| `model` | String | `claude-sonnet-4-20250514` | Claude Code |
| `token_count` | UInt32 | 1250 | Claude Code (Stop event) |
| `tool_name` | LowCardinality(String) | `Bash`, `Read`, `Edit` | Claude Code |
| `duration_ms` | UInt32 | 8450 | Claude Code |
| `subagent_task` | String | `Implement feature X` | SubagentStart event |
| `project` | String | `kyb` | Capture script enrichment |

### 2.2 Secondary: OTel Spans from cc-connect

When cc-connect calls the Claude API (for bridge/Feishu workloads), OTel spans capture:

| Attribute | Type | Example |
|-----------|------|---------|
| `claude.request.model` | string | `claude-sonnet-4-20250514` |
| `cc.claude.tokens_total` | counter | direction=input, value=4500 |
| `cc.claude.call_duration_ms` | histogram | value=3200 |

These cover bridge-agent Claude usage (not sandbox Claude Code sessions). Merge them in a unified view for total cost tracking.

### 2.3 Model String -> Cost Mapping

The `model` field is a raw string from Claude Code. It needs to be mapped to a cost tier for billing. Maintain this mapping in a ClickHouse dictionary or a simple lookup table.

**Dictionary definition:**

```sql
CREATE TABLE kyb.model_pricing (
    model_pattern String,
    model_tier LowCardinality(String),
    input_cost_per_mtok Decimal(10,4),
    output_cost_per_mtok Decimal(10,4),
    effective_from Date,
    effective_to Date DEFAULT '2099-12-31'
)
ENGINE = ReplacingMergeTree
ORDER BY (model_pattern, effective_from);

-- Current pricing (as of 2026-05-23, Claude Code default model routing)
INSERT INTO kyb.model_pricing VALUES
('claude-opus-4%',              'opus',   15.0000, 75.0000,  '2026-01-01'),
('claude-sonnet-4%',            'sonnet',  3.0000, 15.0000,  '2026-01-01'),
('claude-3-5-haiku%',           'haiku',   0.8000,  4.0000,  '2026-01-01'),
('claude-3-haiku%',             'haiku',   0.2500,  1.2500,  '2025-01-01'),
('claude-sonnet-3.5%',          'sonnet',  3.0000, 15.0000,  '2025-01-01'),
('claude-sonnet-4-flash%',      'flash',   0.8000,  4.0000,  '2026-05-01'),
('claude-4-5-sonnet%',          'sonnet',  3.0000, 15.0000,  '2026-05-01'),
('claude-opus-4.5%',            'opus',   15.0000, 75.0000,  '2026-05-01');
```

Pricing sources: Anthropic published API pricing. Claude Code default model routing may differ from direct API pricing -- adjust as needed when billing data becomes available.

---

## 3. Model Tier Definitions & Pricing

### 3.1 Tier Overview

| Tier | Example Model | Input $/Mtok | Output $/Mtok | Best For | Avoid For |
|------|--------------|-------------|--------------|----------|-----------|
| **Opus** | claude-opus-4 | $15.00 | $75.00 | Architecture decisions, complex debugging, code review, security review | Simple edits, file reads, git status |
| **Sonnet** | claude-sonnet-4 | $3.00 | $15.00 | Default coding, feature implementation, test writing | Trivial lookups, ls/cat commands |
| **Haiku** | claude-3-5-haiku | $0.80 | $4.00 | Simple tasks, tool-heavy workflows, exploration | Complex logic, multi-step reasoning |
| **Flash** | claude-sonnet-4-flash | $0.80 | $4.00 | Fast iteration, large context, quick lookups | Tasks requiring deep reasoning |

### 3.2 Cost Multiplier (Relative to Haiku)

| Tier | Input Cost Ratio | Output Cost Ratio | Typical Session Cost (1h) |
|------|-----------------|-------------------|--------------------------|
| Haiku | 1x | 1x | ~$0.10 - $0.30 |
| Flash | 1x | 1x | ~$0.10 - $0.30 |
| Sonnet | 3.75x | 3.75x | ~$0.50 - $1.50 |
| Opus | 18.75x | 18.75x | ~$2.00 - $8.00 |

An Opus session costs ~10-20x a Haiku session for the same amount of work. Using Opus for trivial tasks is the #1 source of wasted spend.

### 3.3 Claude Code Default Model Routing

Claude Code uses model routing, not a fixed model. The effective model depends on:
- **Task complexity** -- Claude Code's internal router picks Opus for hard tasks, Haiku for easy ones
- **User override** -- `claude --model claude-opus-4-...` forces a specific model
- **Subagent inheritance** -- Subagents inherit the parent agent's model by default, unless explicitly overridden

This means the `model` field in hooks is the actual model used, not just the configured one. The routing decision is opaque but observable.

---

## 4. Per-Agent / Per-Session Tracking

### 4.1 Session Hierarchy

Claude Code creates a session tree:

```
boss session (model: claude-sonnet-4-20250514)
  ├── subagent A (model: claude-sonnet-4-20250514)  [inherited]
  ├── subagent B (model: claude-3-5-haiku-20241022) [explicit override]
  │     └── subagent B.1 (model: claude-3-5-haiku-20241022) [inherited]
  └── subagent C (model: claude-opus-4-20250514)     [explicit override]
```

The `session_id` and `parent_session_id` columns in `kyb.claude_hook_events` capture this tree. Query pattern:

```sql
-- Full session tree with model info
SELECT
    session_id,
    parent_session_id,
    model,
    count() AS events,
    sum(token_count) AS total_tokens
FROM kyb.claude_hook_events
WHERE session_id = 'boss-session-xyz'
   OR parent_session_id = 'boss-session-xyz'
GROUP BY session_id, parent_session_id, model
ORDER BY session_id;
```

### 4.2 Agent Identification

The `agent_id` column identifies which agent container or process generated the events. Typical values:

| agent_id | Context | Typical Model |
|----------|---------|--------------|
| `kyb-infra-boss` | Main boss container | sonnet |
| `kyb-patrol-1` | Patrol agent | haiku |
| `kyb-patrol-2` | Patrol agent | haiku |
| `kyb-patrol-3` | Patrol agent | haiku |
| `feishu-bridge-agent` | cc-connect bridge | sonnet |
| `sandbox-<project>-<user>` | Sandbox containers | varies |

### 4.3 Tracking Subagent Model Overrides

When the boss dispatches a subagent with a specific `--model` flag, the subagent's `parent_session_id` links back to the boss session. Query to detect when agents override models:

```sql
-- Detect model downgrade/upgrade in subagent tree
SELECT
    parent.session_id AS boss_session,
    parent.model AS boss_model,
    child.session_id AS subagent_session,
    child.model AS subagent_model,
    child.subagent_task
FROM (
    SELECT DISTINCT session_id, model
    FROM kyb.claude_hook_events
    WHERE event_type = 'SessionStart'
) AS parent
JOIN (
    SELECT DISTINCT session_id, parent_session_id, model, subagent_task
    FROM kyb.claude_hook_events
    WHERE event_type = 'SubagentStart'
) AS child ON parent.session_id = child.parent_session_id
WHERE parent.model != child.model
ORDER BY parent.session_id;
```

---

## 5. Model Selection Patterns

### 5.1 Current Patterns (Observed)

Based on available hook data, the typical model selection patterns in this infra are:

| Pattern | Agent Type | Model | Rationale |
|---------|-----------|-------|-----------|
| **Boss dispatches** | Boss | Sonnet | Default Claude Code model; good balance |
| **Patrol checks** | Patrol | Haiku | Simple deterministic checks; cheap enough to run 3x |
| **Bridge conversations** | Bridge agent | Sonnet | Complex multi-turn reasoning with users |
| **Security review** | Review agent | Opus | High-stakes; needs thorough analysis |
| **Code review** | Review agent | Sonnet | Medium stakes; Claude Code default |
| **Quick lookup** | Any | Haiku | Zero reasoning needed; fastest response |

### 5.2 Recommended Selection Rules

```
┌─────────────────────────────────────────────────────────┐
│                    Task Category                        │
│                                                         │
│  Architecture / Design  ──────► Opus (if complex)      │
│  Security Review        ──────► Opus                    │
│  Code Review            ──────► Sonnet (default)        │
│  Feature Implementation ──────► Sonnet                  │
│  Bug Fix (complex)      ──────► Sonnet                  │
│  Bug Fix (trivial)      ──────► Haiku                   │
│  Test Writing           ──────► Sonnet or Haiku         │
│  File Read / Search     ──────► Haiku                   │
│  Patrol / Health Check  ──────► Haiku                   │
│  Data Analysis Query    ──────► Flash or Haiku          │
│  Batch / Bulk Operation ──────► Flash                   │
└─────────────────────────────────────────────────────────┘
```

### 5.3 Cost-Per-Task Benchmarks

Establish benchmarks for common task types to detect outliers:

| Task Type | Expected Model | Expected Tokens | Expected Cost | Alert If |
|-----------|---------------|----------------|---------------|----------|
| Patrol check | Haiku | 5K-15K | $0.01-0.03 | Cost > $0.10 |
| Quick file read | Haiku | 2K-5K | $0.002-0.005 | Cost > $0.02 |
| Bug fix (simple) | Sonnet or Haiku | 20K-50K | $0.08-0.20 | Cost > $0.50 |
| Feature implementation | Sonnet | 50K-200K | $0.30-0.90 | Cost > $2.00 |
| Code review | Sonnet | 30K-100K | $0.15-0.50 | Cost > $1.00 |
| Security review | Opus | 50K-150K | $1.50-5.00 | Cost > $10.00 |
| Architecture design | Opus | 80K-250K | $3.00-10.00 | Cost > $20.00 |

### 5.4 Common Anti-Patterns

| Anti-Pattern | Symptom | Fix |
|-------------|---------|-----|
| **Opus for trivial reads** | Agent reads a 10-line file using Opus | Set default model to Haiku in project settings; only override to Opus explicitly |
| **Model drift in subagents** | Boss dispatches with Sonnet but subagent upgrades to Opus | Add `--model haiku` flag in dispatch command for simple tasks |
| **Expensive patrols** | Patrol agent using Sonnet for check-send-sleep loop | Hard-code `model: haiku` in patrol CLAUDE.md |
| **Mixed-tier sessions** | Single session switches between Haiku and Opus multiple times | Check for tool-use patterns causing model escalation; split into separate sessions |
| **Forgotten overrides** | `~/.claude/settings.json` has `model: opus` set globally | Use project-level settings, not global; override per-session with `--model` |

---

## 6. Cost Tracking Queries

All queries target the `kyb.claude_hook_events` table with the `model` field. The `Stop` event carries `token_count` (total tokens for that response). Token usage estimates are conservative -- they do not include caching or prompt overhead.

### 6.1 Daily Cost by Model Tier

```sql
SELECT
    toDate(timestamp) AS day,
    multiIf(
        model LIKE 'claude-opus%', 'opus',
        model LIKE 'claude-sonnet-4-flash%', 'flash',
        model LIKE 'claude-sonnet%', 'sonnet',
        model LIKE 'claude-3-5-haiku%', 'haiku',
        model LIKE 'claude-3-haiku%', 'haiku',
        model LIKE 'claude-4-5-sonnet%', 'sonnet',
        model LIKE 'claude-opus-4.5%', 'opus',
        'other'
    ) AS model_tier,
    count() AS events,
    sum(token_count) AS total_tokens,
    round(sum(token_count) * 0.75 / 1000000 * multiIf(
        model_tier = 'opus', 15.0,
        model_tier = 'sonnet', 3.0,
        model_tier = 'flash', 0.80,
        model_tier = 'haiku', 0.80,
        3.0
    ), 2) AS estimated_input_cost,
    round(sum(token_count) * 0.25 / 1000000 * multiIf(
        model_tier = 'opus', 75.0,
        model_tier = 'sonnet', 15.0,
        model_tier = 'flash', 4.0,
        model_tier = 'haiku', 4.0,
        15.0
    ), 2) AS estimated_output_cost,
    round(estimated_input_cost + estimated_output_cost, 2) AS estimated_total_cost
FROM kyb.claude_hook_events
WHERE event_type = 'Stop'
  AND token_count > 0
GROUP BY day, model_tier
ORDER BY day DESC, model_tier;
```

### 6.2 Cost Per Agent (Last 7 Days)

```sql
SELECT
    agent_id,
    multiIf(
        model LIKE 'claude-opus%', 'opus',
        model LIKE 'claude-sonnet-4-flash%', 'flash',
        model LIKE 'claude-sonnet%', 'sonnet',
        model LIKE 'claude-3-5-haiku%', 'haiku',
        model LIKE 'claude-3-haiku%', 'haiku',
        model LIKE 'claude-4-5-sonnet%', 'sonnet',
        model LIKE 'claude-opus-4.5%', 'opus',
        'other'
    ) AS model_tier,
    count() AS sessions,
    sum(token_count) AS total_tokens,
    round(sum(token_count) * 0.75 / 1000000 * multiIf(
        model_tier = 'opus', 15.0,
        model_tier = 'sonnet', 3.0,
        model_tier = 'flash', 0.80,
        model_tier = 'haiku', 0.80,
        3.0
    ), 2) AS estimated_input_cost
FROM kyb.claude_hook_events
WHERE event_type = 'Stop'
  AND timestamp > now() - INTERVAL 7 DAY
  AND token_count > 0
GROUP BY agent_id, model_tier
ORDER BY estimated_input_cost DESC;
```

### 6.3 Current Session Cost (Real-time)

Useful for checking how much a running session has cost so far:

```sql
SELECT
    session_id,
    model,
    count() AS responses,
    sum(token_count) AS total_tokens,
    round(sum(token_count) * 0.75 / 1000000 * 3.0, 2) AS est_input_cost_sonnet_rate,
    round(sum(token_count) * 0.25 / 1000000 * 15.0, 2) AS est_output_cost_sonnet_rate
FROM kyb.claude_hook_events
WHERE session_id = '<session-id>'
  AND event_type = 'Stop'
  AND token_count > 0
GROUP BY session_id, model;
```

### 6.4 Session Cost Distribution

```sql
SELECT
    multiIf(
        total_session_cost < 0.05, '< $0.05',
        total_session_cost < 0.20, '$0.05 - $0.20',
        total_session_cost < 0.50, '$0.20 - $0.50',
        total_session_cost < 1.00, '$0.50 - $1.00',
        total_session_cost < 5.00, '$1.00 - $5.00',
        '> $5.00'
    ) AS cost_bucket,
    count() AS sessions,
    round(avg(total_session_cost), 2) AS avg_cost,
    round(sum(total_session_cost), 2) AS total_cost
FROM (
    SELECT
        session_id,
        sum(token_count * 0.75 / 1000000 * 3.0) AS est_input_cost,
        sum(token_count * 0.25 / 1000000 * 15.0) AS est_output_cost,
        est_input_cost + est_output_cost AS total_session_cost
    FROM kyb.claude_hook_events
    WHERE event_type = 'Stop'
      AND timestamp > now() - INTERVAL 30 DAY
      AND token_count > 0
    GROUP BY session_id
)
GROUP BY cost_bucket
ORDER BY cost_bucket;
```

### 6.5 Model Selection Heatmap (Agent x Model)

```sql
SELECT
    agent_id,
    countIf(model LIKE 'claude-opus%') AS opus_count,
    countIf(model LIKE 'claude-sonnet%' AND model NOT LIKE '%flash%') AS sonnet_count,
    countIf(model LIKE 'claude-3-5-haiku%' OR model LIKE 'claude-3-haiku%') AS haiku_count,
    countIf(model LIKE 'claude-sonnet-4-flash%') AS flash_count,
    count() AS total_events
FROM kyb.claude_hook_events
WHERE event_type = 'Stop'
  AND timestamp > now() - INTERVAL 7 DAY
GROUP BY agent_id
ORDER BY total_events DESC;
```

---

## 7. Grafana Dashboard

### 7.1 Model Usage Overview Panel

**Query:** Daily cost by model tier (from 6.1)
**Visualization:** Stacked bar chart
**X-axis:** Day
**Y-axis:** Estimated cost ($)
**Legend:** Model tiers (opus, sonnet, haiku, flash, other)

### 7.2 Agent Cost Breakdown Panel

**Query:** Cost per agent (from 6.2)
**Visualization:** Table
**Columns:** agent_id, model_tier, sessions, total_tokens, estimated_cost
**Sort:** estimated_cost DESC

### 7.3 Session Cost Distribution Panel

**Query:** Session cost distribution (from 6.4)
**Visualization:** Pie chart or bar chart
**Labels:** Cost buckets

### 7.4 Model Selection Heatmap Panel

**Query:** Model selection heatmap (from 6.5)
**Visualization:** Table with conditional coloring
**Highlight:** Red for high Opus usage on patrol/infra agents

### 7.5 Real-Time Session Cost Panel

**Query:** Active sessions with running cost estimate
**Visualization:** Table, auto-refresh every 30s
**Columns:** session_id, agent_id, model, est_cost, duration

### 7.6 Model Routing Distribution Panel

**Query:** For sessions using Claude Code default routing (no forced model), show the distribution of actual models selected:

```sql
SELECT
    toDate(timestamp) AS day,
    model,
    count(DISTINCT session_id) AS sessions,
    sum(token_count) AS total_tokens
FROM kyb.claude_hook_events
WHERE event_type = 'SessionStart'
  AND timestamp > now() - INTERVAL 7 DAY
GROUP BY day, model
ORDER BY day, sessions DESC;
```

---

## 8. Alerts

### 8.1 Cost Anomaly Alerts

| Condition | Query | Threshold | Action |
|-----------|-------|-----------|--------|
| Daily cost > 2x rolling 7-day avg | Cost per day (6.1) | > 2x avg | Notify boss |
| Single session > $10 | Session cost (6.3) | > $10 | Investigate model selection |
| Any agent using Opus for >50% of events | Agent model ratio (6.5) | > 50% Opus | Check agent config |
| Patrol using non-Haiku model | Model heatmap (6.5), agent_id LIKE '%patrol%' | Any non-Haiku | Fix patrol CLAUDE.md |
| Unknown model string detected | DISTINCT model in last 24h | New value not in pricing table | Update model_pricing table |

### 8.2 Alert Queries

**Daily cost spike:**

```sql
-- Compare today with rolling 7-day average
SELECT
    round(sum(token_count) * 0.75 / 1000000 * 3.0, 2) AS today_cost
FROM kyb.claude_hook_events
WHERE event_type = 'Stop'
  AND toDate(timestamp) = today()
  AND token_count > 0;
```

Compare against the pre-computed 7-day average from a materialized view:

```sql
CREATE MATERIALIZED VIEW kyb.daily_cost_7d_avg
ENGINE = AggregatingMergeTree
ORDER BY day
AS SELECT
    day,
    avgState(estimated_total_cost) AS avg_cost_7d
FROM daily_cost_mv
GROUP BY day;
```

### 8.3 Unknown Model Alert

Run hourly:

```sql
SELECT DISTINCT model
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 1 HOUR
  AND model NOT LIKE 'claude-opus%'
  AND model NOT LIKE 'claude-sonnet%'
  AND model NOT LIKE 'claude-3-5-haiku%'
  AND model NOT LIKE 'claude-3-haiku%'
  AND model NOT LIKE 'claude-4-5-sonnet%'
  AND model NOT LIKE 'claude-opus-4.5%';
```

If any rows returned, the pricing table needs updating for the new model.

---

## 9. Optimization Strategy

### 9.1 Default Model by Agent Type

Configure default models per agent container via their `~/.claude/settings.json` or CLAUDE.md:

| Agent Container | Default Model | Rationale |
|----------------|--------------|-----------|
| kyb-infra-boss | Sonnet (Claude Code default) | Boss needs reasoning for dispatch decisions |
| kyb-patrol-* | Haiku (forced) | Cheap, fast, deterministic checks |
| sandbox-* | Haiku (recommended) | Most sandbox work is simple edits and reads |
| feishu-bridge-agent | Sonnet | User conversations need reasoning |
| review-* (security) | Opus (explicit) | High-stakes, only when dispatched with `--model opus` |

### 9.2 CLAUDE.md Model Instructions

Add model selection guidance to each agent's CLAUDE.md:

```
## Model Usage
- Default: haiku (this container is configured for fast, cheap operation)
- Only use sonnet if explicitly asked by the dispatcher
- Do NOT upgrade to opus unless explicitly instructed
- If you think you need a more powerful model, explain why and ask
```

### 9.3 Patrol Cost Budget

Patrols run continuously and are the highest-volume agent type. Budget target:

| Patrol | Model | Expected Cost/Day | Expected Cost/Month |
|--------|-------|-------------------|---------------------|
| patrol-1 | Haiku | $0.50 - $1.00 | $15 - $30 |
| patrol-2 | Haiku | $0.50 - $1.00 | $15 - $30 |
| patrol-3 | Haiku | $0.50 - $1.00 | $15 - $30 |
| **Total patrols** | | **$1.50 - $3.00** | **$45 - $90** |

If any patrol exceeds $2/day, investigate immediately -- it likely means the model was overridden or the patrol logic is looping excessively.

### 9.4 Monthly Cost Targets

| Category | Target | Alert At |
|----------|--------|----------|
| Patrol agents | $90/mo (3 x $30) | $150/mo |
| Boss sessions | $200/mo | $400/mo |
| Bridge agents | $100/mo | $200/mo |
| Sandbox agents | $100/mo | $200/mo |
| Review agents | $150/mo | $300/mo |
| **Total infra** | **$640/mo** | **$1,250/mo** |

### 9.5 Model Override Audit Trail

When an agent overrides its default model, the `metadata` map column can record the reason. The hook script should capture the `--model` flag from the Claude invocation:

```
metadata = {
  'model_override_reason': 'explicit --model flag',
  'invocation': 'claude --model claude-opus-4-20250514 ...'
}
```

This requires the hook script to parse the process command line. Implementation is deferred -- for now, use the model change query in Section 4.3 to detect overrides.

---

## 10. Appendix: Known Model Identifiers

### 10.1 Claude Code Model Strings (Observed)

| Model String | Tier | Notes |
|-------------|------|-------|
| `claude-opus-4-20250514` | Opus | Current Opus model |
| `claude-sonnet-4-20250514` | Sonnet | Current Sonnet model |
| `claude-sonnet-4-flash-20250514` | Flash | Flash variant of Sonnet 4 |
| `claude-3-5-haiku-20241022` | Haiku | Current Haiku model |
| `claude-3-haiku-20240307` | Haiku | Legacy Haiku (rarely seen) |
| `claude-4-5-sonnet-20260218` | Sonnet | Opus-class model in Sonnet pricing tier |
| `claude-opus-4-5-20260218` | Opus | Latest Opus model |

### 10.2 Model String Pattern Matching

The `model` field format: `claude-{family}-{variant}-{date}`

```python
# Python helper for model tier classification (for Grafana or script use)
def classify_model(model_str: str) -> str:
    if not model_str:
        return 'unknown'
    if model_str.startswith('claude-opus'):
        return 'opus'
    if model_str.startswith('claude-sonnet-4-flash'):
        return 'flash'
    if model_str.startswith('claude-sonnet'):
        return 'sonnet'
    if 'haiku' in model_str:
        return 'haiku'
    if 'clair' in model_str.lower():
        # CLAIR is a "poor man's o1" -- treat as opus-tier cost
        return 'opus'
    return 'other'
```
