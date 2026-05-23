---
decision: 稍后做
---

# Permission Request Latency Tracking

**Date**: 2026-05-23
**Scope**: End-to-end latency tracking for the human-in-the-loop permission flow in cc-connect: request creation, human decision, timeout/auto-deny, and bottleneck tool identification.

---

## Background

cc-connect implements a human-in-the-loop permission system: when Claude requests a tool call that requires approval (e.g., `Bash`, `FileWrite`), cc-connect creates a permission request, blocks the tool execution, and waits for a human to approve or deny it. The human resolves via Feishu interactive message (button approve/deny). If no response arrives within a configurable timeout, the system auto-denies.

Two structured log lines already exist in cc-connect output:

```
time=2026-05-23T16:39:03.343Z level=INFO msg="permission request" request_id=req_abc tool=Bash
time=2026-05-23T16:37:55.717Z level=INFO msg="permission resolved" request_id=req_abc decision=approved resolved_by=human
```

These provide the raw data for latency tracking, but today they are consumed only as log events in ClickHouse. There is no dedicated dashboard, alert, or analysis pipeline for permission behavior.

### Why track it

| Concern | Impact |
|---------|--------|
| **Agent stall time** | Every permission request blocks the agent loop. If resolution is slow, E2E message latency balloons. |
| **High deny rate** | Frequent denials waste Claude API tokens (the response that produced the tool call is discarded). |
| **Tool-specific patterns** | Some tools may have significantly higher request frequency or slower resolution than others. |
| **Human fatigue** | If one person is resolving all requests, response time degrades. If nobody resolves, auto-denies waste work. |
| **Auto-deny rate** | Timeouts mean the human didn't see or ignored the request. This is a UX/alerting signal. |

---

## Data Model

### Permission Event Schema (ClickHouse)

Extend the existing Vector pipeline to produce a dedicated `cc_permission_requests` table, separate from the general message log. This table is the single source of truth for permission analytics.

```sql
CREATE TABLE cc_permission_requests (
    event_date     Date,
    event_time     DateTime64(3),
    request_id     String,
    tool           LowCardinality(String),
    decision       LowCardinality(String),       -- 'approved' / 'denied' / 'timeout'
    resolved_by    LowCardinality(String),        -- 'human' / 'auto'
    duration_ms    UInt32,                        -- time from request to resolution
    session_id     String,
    msg_id         String,
    tool_input_hash String,                       -- hash of tool input (for dedup / pattern analysis, no PII)
    _inserted_at   DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, tool, decision)
TTL event_date + INTERVAL 90 DAY
```

**Key design decisions:**

- `request_id` is the unique join key between the "request" and "resolved" log lines.
- `duration_ms` is computed in the Vector transform: `parsed_resolved_time - parsed_request_time`.
- `tool_input_hash` is a SHA256 of the tool command/input, useful for identifying repeated requests for the same action without storing raw PII.
- `decision` includes `timeout` for auto-denied requests (distinct from human-denied).
- LowCardinality on `tool`, `decision`, `resolved_by` because these have small fixed sets.

### Derived View: Permission Summary (Materialized)

A materialized view for dashboard queries, updated on insert:

```sql
CREATE MATERIALIZED VIEW cc_permission_summary_mv
ENGINE = AggregatingMergeTree()
ORDER BY (toStartOfHour(event_time), tool)
POPULATE
AS SELECT
    toStartOfHour(event_time) AS hour,
    tool,
    count() AS total_requests,
    countIf(decision = 'approved') AS approved_count,
    countIf(decision = 'denied') AS denied_count,
    countIf(decision = 'timeout') AS timeout_count,
    avg(duration_ms) AS avg_duration_ms,
    quantile(0.50)(duration_ms) AS p50_duration_ms,
    quantile(0.90)(duration_ms) AS p90_duration_ms,
    quantile(0.99)(duration_ms) AS p99_duration_ms,
    countIf(resolved_by = 'auto') AS auto_resolved_count
FROM cc_permission_requests
GROUP BY hour, tool
```

---

## Vector Pipeline

### Log Parsing

The existing Vector config that ingests cc-connect logs needs two additional transforms:

1. **Permission request parser** -- matches `msg="permission request"` lines, extracts `request_id`, `tool`.
2. **Permission resolved parser** -- matches `msg="permission resolved"` lines, extracts `request_id`, `decision`, `resolved_by`.

```toml
# In vector.toml, after the general cc-connect source

[transforms.parse_permission_request]
type = "remap"
inputs = ["cc_connect_logs"]
source = '''
  if !includes(["permission request"], .message) {
    abort
  }
  parsed = parse_regex!(.message, r'msg="permission request" request_id=(?P<request_id>\S+) tool=(?P<tool>\S+)')
  .event_type = "permission_request"
  .request_id = parsed.request_id
  .tool = parsed.tool
  .request_time = .timestamp
'''

[transforms.parse_permission_resolved]
type = "remap"
inputs = ["cc_connect_logs"]
source = '''
  if !includes(["permission resolved"], .message) {
    abort
  }
  parsed = parse_regex!(.message, r'msg="permission resolved" request_id=(?P<request_id>\S+) decision=(?P<decision>\S+) resolved_by=(?P<resolved_by>\S+)')
  .event_type = "permission_resolved"
  .request_id = parsed.request_id
  .decision = parsed.decision
  .resolved_by = parsed.resolved_by
  .resolve_time = .timestamp
'''

[transforms.join_permission_events]
type = "remap"
inputs = ["parse_permission_request", "parse_permission_resolved"]
source = '''
  # Stateful join: uses Vector's tag-and-join pattern.
  # In practice, this can be done in ClickHouse via a JOIN on request_id,
  # or in Vector using the `reducer` transform with a lookup table.
  # For simplicity, emit both event types and join in the SQL view.
  . = .
'''
```

### Join strategy

Two options for joining request + resolved into a single record:

**Option A: ClickHouse side (recommended for low volume)**

Create a view that joins on `request_id`:

```sql
CREATE VIEW cc_permission_joined AS
SELECT
    r.event_time AS request_time,
    res.event_time AS resolve_time,
    r.request_id,
    r.tool,
    res.decision,
    res.resolved_by,
    dateDiff('millisecond', r.event_time, res.event_time) AS duration_ms
FROM (
    SELECT * FROM cc_permission_logs WHERE event_type = 'permission_request'
) AS r
LEFT JOIN (
    SELECT * FROM cc_permission_logs WHERE event_type = 'permission_resolved'
) AS res ON r.request_id = res.request_id
```

This is sufficient at current scale (~90 messages/day, <10 permission requests/day).

**Option B: Vector side (for scale >1000 requests/day)**

Use a Vector `reduce` transform with `merge_strategy` to correlate request/resolved pairs by `request_id`. More complex but avoids the ClickHouse join at query time.

At current volume, Option A is sufficient. Re-evaluate at >100 requests/day.

---

## Metrics

### Derived from permission events

| Metric | Type | Labels | Source |
|--------|------|--------|--------|
| `permission.requests_total` | Counter | `tool` | Request event count |
| `permission.resolved_total` | Counter | `tool`, `decision`, `resolved_by` | Resolved event count |
| `permission.duration_ms` | Histogram | `tool`, `decision` | P50/P90/P99 from joined events |
| `permission.timeout_total` | Counter | `tool` | Where `decision=timeout` |
| `permission.pending_current` | Gauge | `tool` | Requested but not yet resolved (active) |

These map to the OTel metric already defined in `otel-cc-connect.md` (`cc.permission.duration_ms`), but here we add tool-level breakdown.

### SLOs

| SLO | Target | Source |
|-----|--------|--------|
| Permission resolution P50 | < 30s | `permission.duration_ms` P50 |
| Permission resolution P90 | < 120s | `permission.duration_ms` P90 |
| Auto-deny rate | < 10% | `timeout_count / total_requests` |
| Human deny rate by tool | < 20% for any single tool | `denied_count / total_requests GROUP BY tool` |

---

## Alerts

| Condition | Severity | Rationale |
|-----------|----------|-----------|
| Permission P90 > 120s for 5 consecutive minutes | P2 | Human not responding, agents stalled |
| Auto-deny rate > 20% in last hour | P2 | Either no human online or request UI broken |
| Any tool with >50% deny rate in last hour | P3 | Tool may be too dangerous or misconfigured |
| No permission resolution for >30min during business hours | P2 | Nobody watching the permission queue |
| Single tool >80% of all requests in last hour | P3 | Claude in a loop requesting the same tool |

---

## Dashboard Panels

### Panel 1: Permission Request Volume (time series, stacked bar)

- **Metric**: `permission.requests_total` by tool
- **Granularity**: 1h buckets
- **Purpose**: See which tools generate the most requests, spot anomalous spikes

### Panel 2: Resolution Latency Heatmap (heatmap)

- **Metric**: `permission.duration_ms` histogram
- **X-axis**: Time (1h buckets)
- **Y-axis**: Latency buckets (0-10s, 10-30s, 30-60s, 60-120s, 120s+)
- **Color**: Count of requests
- **Purpose**: Visualize how resolution latency changes over time, spot outlier periods

### Panel 3: Decision Breakdown by Tool (pie chart or stacked bar)

- **Metric**: `permission.resolved_total` by `decision` and `tool`
- **Purpose**: See which tools are most frequently denied vs approved

### Panel 4: Pending Request Age (table)

- **Current unresolved permission requests, sorted by age (descending)
- **Columns**: `request_id`, `tool`, `session_id`, `elapsed_since_request`, `tool_input_preview`
- **Purpose**: Manual triage -- what is waiting right now?

### Panel 5: Tool-Level SLO Compliance (stat)

- Per tool: `current P90 / SLO target` ratio, color-coded (green < 80%, yellow 80-100%, red > 100%)
- **Purpose**: At-a-glance health of each tool's permission flow

### Panel 6: Human Resolution Speed Trend (line chart)

- **Metric**: `permission.duration_ms` P50/P90/P99, filtered to `resolved_by=human`
- **Granularity**: 1h buckets, rolling 24h window
- **Purpose**: Track human operator responsiveness over time

---

## Implementation Plan

### Phase 1: Data pipeline (Vector + ClickHouse) -- P0

1. Add Vector remap transforms for permission request/resolved log parsing
2. Create `cc_permission_requests` ClickHouse table
3. Create `cc_permission_summary_mv` materialized view
4. Validate with historical data (replay existing logs)

### Phase 2: Metrics (Prometheus / OTel) -- P1

5. Export `permission.requests_total` counter
6. Export `permission.duration_ms` histogram
7. Export `permission.pending_current` gauge
8. Wire into existing cc-connect OTel metrics pipeline

### Phase 3: Dashboards -- P1

9. Build the 6 Grafana panels listed above
10. Add to the existing cc-connect observability dashboard

### Phase 4: Alerts -- P2

11. Configure the 5 alert rules in Grafana / Alertmanager
12. Set up notification routing to Feishu (same as existing alerts)

---

## Edge Cases

### Missing resolve event

If cc-connect restarts between a permission request and its resolution, the resolve event is lost. The request row has no matching resolve, so `duration_ms` is NULL. These count as "still pending" until a configurable grace period (default 1h) after which they are treated as stale.

**Mitigation**: Add a periodic cleanup job that marks requests older than 1h without a resolve event as `decision=lost`, `resolved_by=auto`. This is a Vector scheduled transform or a ClickHouse cron.

### Duplicate resolve events

A permission might be resolved twice (e.g., human clicks approve then deny). The first resolution wins; subsequent events are ignored via `INSERT ... SELECT ... WHERE NOT EXISTS` or deduplication in the Vector pipeline using a stateful lookup.

**Mitigation**: Use `cc_permission_requests` with `ENGINE = ReplacingMergeTree` and dedup on `request_id`. Vector emits all events; ClickHouse collapses duplicates on partition merge.

### Multiple concurrent requests for the same tool

Claude can request multiple tools in parallel (though in practice the agent loop is sequential). Each gets a unique `request_id`, so no collision.

### Permission request with no timeout

If a permission request has no configured timeout (timeout_ms = 0), it blocks indefinitely. This is a configuration bug. The same latency tracking still works -- `duration_ms` will grow unbounded until human resolves. The "Pending Request Age" panel makes these visible. Alert on requests pending > 30min regardless of timeout.

---

## Appendix: Log Format Reference

### Current cc-connect permission log lines

```
time=2026-05-23T16:39:03.343Z level=INFO msg="permission request" request_id=req_abc123 tool=Bash
time=2026-05-23T16:39:03.344Z level=INFO msg="permission request" request_id=req_def456 tool=Read
time=2026-05-23T16:40:15.221Z level=INFO msg="permission resolved" request_id=req_abc123 decision=approved resolved_by=human
time=2026-05-23T16:41:00.000Z level=INFO msg="permission resolved" request_id=req_def456 decision=timeout resolved_by=auto
```

### Additional fields (future, not yet logged)

The following fields would be valuable additions to the log line but require cc-connect code changes:

| Field | Type | Example | Why |
|-------|------|---------|-----|
| `timeout_ms` | int | `30000` | When timeout is configurable, track the configured value |
| `session` | string | `feishu:oc_xxx:ou_xxx` | Which session triggered the request |
| `msg_id` | string | `om_abc123` | Which message is being processed |
| `tool_input_len` | int | `42` | Size of the tool input (not the content, just the length) |
| `resolved_by_user` | string | `ou_yyy` | Which human resolved it (for load balancing analysis) |

Adding these to cc-connect's structured log output enables richer analysis without additional instrumentation. Recommended as P2 work.

---

## References

- Existing cc-connect observability design: `docs/infra/designs/mcp-observability.md`
- OTel tracing for cc-connect: `docs/infra/reviews/otel-cc-connect.md` (includes `cc.permission.request` / `cc.permission.resolve` span definitions)
- Log format validation (review A1): `docs/infra/reviews/review-bridge-ck-ingestion-A1.md`
- Existing ClickHouse ingestion pipeline: `docs/infra/designs/bridge-ck-ingestion.md`
