---
decision: 现在就做
---

# cc-connect Hooks Direct to ClickHouse

**Author**: kyb-infra-boss  
**Date**: 2026-05-23  
**Status**: Design Document  
**Context**: Replace the Vector-middlware bridge pattern with direct HTTP POST from cc-connect native hooks to ClickHouse.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Current Architecture (Bridge Pattern)](#2-current-architecture-bridge-pattern)
3. [Proposed Architecture (Direct Pattern)](#3-proposed-architecture-direct-pattern)
4. [cc-connect Hooks Configuration](#4-cc-connect-hooks-configuration)
5. [Table Schema](#5-table-schema)
6. [Event Payload Design](#6-event-payload-design)
7. [Retry and Reliability](#7-retry-and-reliability)
8. [Fail-Open Design](#8-fail-open-design)
9. [Comparision Matrix](#9-comparison-matrix)
10. [Pros and Cons](#10-pros-and-cons)
11. [Migration Path](#11-migration-path)
12. [Grafana Queries](#12-grafana-queries)

---

## 1. Motivation

### Why Direct?

The current bridge ingestion pipeline (`cc-connect -> Vector -> ClickHouse`) was designed under the assumption that cc-connect v1.3.2 had no native hook mechanism. Review C1 discovered that cc-connect v1.3.2 **does** ship with a built-in hooks system supporting:

- Webhook (HTTP POST) backend
- Configurable event filtering
- Built-in retry with backoff
- No extra deployment required

Running Vector as a middleware sidecar when cc-connect can POST directly to ClickHouse is unnecessary operational overhead.

### Data Volume Is Trivial

From the bridge design doc: ~90 messages/day, ~34 KB/day, <1 MB after ClickHouse compression over 90 days. At this volume, ClickHouse HTTP endpoint (port 8123) handles the load trivially. No batching layer is needed.

### Fail-Open Requirement

Just like the Claude Code hooks pipeline ([hooks-ck-pipeline.md](../handbook/hooks-ck-pipeline.md)), cc-connect hooks must never block the main message flow. Hooks are observability, not critical path.

---

## 2. Current Architecture (Bridge Pattern)

```
Feishu message
     │
     ▼
cc-connect
     │  (structured JSON log to stdout)
     ▼
Vector container (sidecar)
     │  (log parsing + CK sink)
     ▼
ClickHouse (cc.message_log)
     │
     ▼
Grafana
```

### Deployment

- Vector runs as a separate container on the same Docker host
- Vector parses cc-connect stdout logs for structured JSON lines
- Vector batches writes to ClickHouse sink
- Requires managing Vector config, updates, and resource allocation

### Failure Modes

| Component | Failure Impact | Recovery |
|-----------|---------------|----------|
| Vector container crash | Data loss until restart | Docker auto-restart |
| Vector config mismatch | Silent data loss (wrong log format) | Manual fix |
| Vector version upgrade | Requires container restart | Manual intervention |
| CK unavailable | Vector backpressure -> buffer growth | Vector retries with backoff |
| cc-connect log format change | Vector parse failure, no data | Update Vector config |

---

## 3. Proposed Architecture (Direct Pattern)

```
Feishu message
     │
     ▼
cc-connect v1.3.2+
     │  (native hook: HTTP POST)
     │
     ▼
ClickHouse (cc.hook_events)
     │
     ▼
Grafana
```

### What Changes

| Layer | Before (Bridge) | After (Direct) |
|-------|----------------|----------------|
| Data source | cc-connect stdout logs | cc-connect native hooks |
| Transport | Vector docker log collector | HTTP POST (cc-connect -> CK) |
| Middleware | Vector container | None |
| ClickHouse table | `cc.message_log` | `cc.hook_events` |
| Config location | Vector `config.toml` | cc-connect `config.toml` |

---

## 4. cc-connect Hooks Configuration

### File Location

cc-connect reads configuration from `/root/.cc-connect/config.toml`.

### TOML Configuration

```toml
[app]
app_id = "cli_xxxxx"
app_secret = "plaintext-secret"

[hooks]

# Webhook backend: POST directly to ClickHouse HTTP endpoint
[hooks.webhook]
enabled = true
url = "http://host.orb.internal:8123"
method = "POST"
timeout_ms = 5000

# ClickHouse expects the query as a URL parameter (INSERT ... FORMAT JSONEachRow)
# and the data as the request body.
# The body is a single JSON object per event. CK parses it via FORMAT JSONEachRow.
#
# Note: cc-connect may or may not support URL-encoded query params in the webhook URL.
# If not, a thin shim (see section 4.1) or `query` param in the URL is needed.

[hooks.webhook.retry]
max_retries = 2
backoff_base_ms = 500
backoff_max_ms = 5000

[hooks.webhook.headers]
Content-Type = "application/json"
# ClickHouse user/password if not using default (trust auth)
# X-ClickHouse-User = "default"
# X-ClickHouse-Key = ""

# Subscribe to specific events (default: all)
[hooks.webhook.events]
subscribe = [
    "message.received",
    "response.complete",
    "session.timeout",
    "session.crashed",
    "session.resumed",
    "permission.requested",
    "heartbeat",
]
```

### 4.1 CK HTTP Query Shim (If cc-connect Does Not Support URL Query Params)

ClickHouse HTTP interface requires the INSERT statement as a URL query parameter:

```
POST /?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow
Body: {"event":"message.received",...}
```

If cc-connect's webhook backend sends the body as-is to a fixed URL without custom query parameters, there are two options:

**Option A: Hard-code the query in CK as a named database.**

Create a ClickHouse `MATERIALIZED VIEW` or use the `INSERT` with `FORMAT` as column name trick — not ideal.

**Option B: Deploy a tiny nginx/OpenResty shim (zero code).**

```
nginx
location /ck-hook {
    proxy_pass http://host.orb.internal:8123?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow;
}
```

This is a 5-line nginx config, no business logic, no application code. It lives on the same machine as ClickHouse and handles path-to-query translation.

**Recommendation: Option B only if needed.** Test first whether cc-connect supports full URLs with query parameters. If it does, no shim is needed.

### 4.2 Event Filtering

cc-connect v1.3.2 hooks support per-event-type matchers for the webhook backend. The subscribe list above shows the recommended set. The `heartbeat` event (a periodic liveness signal from cc-connect) is optional but recommended for detecting silent cc-connect crashes.

Subscribe to all events during initial deployment, then trim based on actual needs.

---

## 5. Table Schema

### New Table: `cc.hook_events`

This table stores all cc-connect native hook events. It is designed to supersede the `cc.message_log` table from the bridge design.

```sql
CREATE TABLE cc.hook_events (
    -- Event metadata
    event_time      DateTime64(3) DEFAULT now(),
    event_type      LowCardinality(String),
    hook_version    LowCardinality(String),

    -- Correlation
    trace_id        String,
    chat_id         String,
    chat_type       LowCardinality(String),

    -- Sender info
    sender_id       String,
    sender_type     LowCardinality(String),

    -- Message details
    message_id      String,
    message_type    LowCardinality(String),
    content_text    String,
    content_len     UInt32,
    has_images      UInt8,

    -- Session info
    session_id      String,
    agent_session   String,

    -- Response metrics (for response.complete)
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    tools_used      UInt8,

    -- Error info (for session.timeout, session.crashed)
    error_code      LowCardinality(String),
    error_message   String,

    -- Permission info (for permission.requested)
    permission_type LowCardinality(String),
    permission_status LowCardinality(String),

    -- Health info (for heartbeat)
    container_uptime UInt32,
    active_sessions UInt16,
    memory_mb       UInt16,

    -- Metadata
    cluster         LowCardinality(String) DEFAULT 'mac-orbstack',
    hostname        String,
    via_hook        Bool DEFAULT true
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, chat_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### Fields by Event Type

| Event | Core Fields | Event-Specific Fields |
|-------|-------------|----------------------|
| `message.received` | trace_id, chat_id, sender_id, message_id, message_type, content_text, content_len, has_images | + session_id, chat_type, sender_type |
| `response.complete` | trace_id, chat_id, message_id | + response_len, turn_duration, input_tokens, output_tokens, tools_used, agent_session |
| `session.timeout` | trace_id, session_id | + error_code, error_message, turn_duration |
| `session.crashed` | trace_id, session_id | + error_code, error_message |
| `session.resumed` | trace_id, session_id | + agent_session |
| `permission.requested` | trace_id, session_id | + permission_type, permission_status, permission_timeout |
| `heartbeat` | hostname | + container_uptime, active_sessions, memory_mb |

The table uses nullable fields for event-type-specific data. This is intentional: a wide table with NULL-heavy sparse storage is simpler to query than a join-heavy normalized schema, and ClickHouse handles NULL storage efficiently.

### Migration from `cc.message_log`

If `cc.message_log` already has data, the schema is a subset of `cc.hook_events`. Migrate:

```sql
INSERT INTO cc.hook_events (
    event_time, event_type, trace_id, message_id, chat_id, chat_type,
    sender_id, sender_type, message_type, content_text, content_len,
    has_images, session_id, agent_session, response_len, turn_duration,
    input_tokens, output_tokens, tools_used, via_hook
)
SELECT
    event_time, event_type, trace_id, message_id, chat_id, chat_type,
    sender_id, sender_type, message_type, content_text, content_len,
    has_images, session, agent_session, response_len, turn_duration,
    input_tokens, output_tokens, tools_used, false AS via_hook
FROM cc.message_log;
```

After migration, drop `cc.message_log` or keep as an archive partition.

---

## 6. Event Payload Design

cc-connect sends JSON bodies that match the ClickHouse `JSONEachRow` format. Each event type produces a known shape.

### Example: `message.received`

```json
{
    "event_type": "message.received",
    "event_time": "2026-05-23T10:30:00.123Z",
    "trace_id": "tr_abc123",
    "chat_id": "oc_xxxxxxxx",
    "chat_type": "group",
    "sender_id": "ou_yyyyyyy",
    "sender_type": "user",
    "message_id": "om_zzzzzzz",
    "message_type": "text",
    "content_text": "你好，帮我查一下今天的天气",
    "content_len": 16,
    "has_images": 0,
    "session_id": "sess_001",
    "agent_session": "",
    "hostname": "infra-boss"
}
```

### Example: `response.complete`

```json
{
    "event_type": "response.complete",
    "event_time": "2026-05-23T10:30:05.456Z",
    "trace_id": "tr_abc123",
    "chat_id": "oc_xxxxxxxx",
    "chat_type": "group",
    "sender_id": "ou_yyyyyyy",
    "message_id": "om_zzzzzzz",
    "response_len": 245,
    "turn_duration": 5.33,
    "input_tokens": 1520,
    "output_tokens": 89,
    "tools_used": 2,
    "session_id": "sess_001",
    "agent_session": "agent_kkkk",
    "hostname": "infra-boss"
}
```

### Example: `session.crashed`

```json
{
    "event_type": "session.crashed",
    "event_time": "2026-05-23T11:15:00.000Z",
    "trace_id": "tr_def456",
    "session_id": "sess_002",
    "error_code": "CLAUDE_EXIT_NONZERO",
    "error_message": "Claude Code process exited with code 137 (OOM killed)",
    "hostname": "infra-boss"
}
```

### Example: `heartbeat`

```json
{
    "event_type": "heartbeat",
    "event_time": "2026-05-23T12:00:00.000Z",
    "hostname": "infra-boss",
    "container_uptime": 86400,
    "active_sessions": 1,
    "memory_mb": 256,
    "cluster": "mac-orbstack"
}
```

### CK HTTP POST Format

ClickHouse accepts raw data via POST when the query parameter specifies INSERT:

```bash
curl -s -X POST "http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message.received",
    "trace_id": "tr_abc123",
    "chat_id": "oc_xxxxxxxx",
    ...
  }'
```

Each POST contains a single JSON object (not an array). cc-connect fires one HTTP request per hook event.

---

## 7. Retry and Reliability

cc-connect v1.3.2 native hooks support built-in retry with configurable backoff.

### Recommended Retry Configuration

```toml
[hooks.webhook.retry]
max_retries = 2          # Total attempts: 1 original + 2 retries = 3
backoff_base_ms = 500    # First retry: 500ms
backoff_max_ms = 5000    # Cap at 5 seconds
```

Retry backoff: `min(base * 2^n, max)` where `n` is the retry attempt number.

- Attempt 1: 0ms (immediate)
- Retry 1: 500ms delay
- Retry 2: 1000ms delay
- Total window: ~1.5s of delay before giving up

### What Happens When All Retries Fail

cc-connect logs the failure but **does not block** the message pipeline. The hook is non-blocking by design. This means:

| Scenario | Hook Result | cc-connect Behavior |
|----------|-------------|---------------------|
| CK is down (connection refused) | All 3 attempts fail | Log warning, continue processing |
| CK is slow (>5s timeout) | Attempt times out, retries same | Log warning, continue |
| Network partition | All 3 attempts fail | Log warning, continue |
| Invalid JSON from cc-connect | CK returns 400 | Log error, continue |
| Retry succeeds on 2nd attempt | Event written | No log, transparent to user |

### Data Loss Window

With `max_retries = 2`, the maximum data loss window is the period CK is unreachable. Unlike Vector (which buffers to disk), the direct pattern has **no buffer**. If CK is down, hook events from that period are lost permanently.

This is acceptable because:
1. Hook events are observability data, not transactional data
2. The data volume is ~34 KB/day -- reingestion from logs is feasible if needed
3. CK uptime on the same machine (Orbstack) is >99.9%

If buffered delivery is required (e.g., for CK on a remote cluster), add a local flush queue (see section 10).

---

## 8. Fail-Open Design

Following the same principles as the Claude Code hooks pipeline:

### Design Principles

1. **Hook execution never blocks message processing.** cc-connect handles messages regardless of hook outcome.
2. **Short timeout** (5s) prevents slow CK from delaying event delivery.
3. **Fail-open**: if CK is unreachable, cc-connect logs a warning and continues.
4. **No proxy bypass required**: CK is on `host.orb.internal` (localhost-equivalent on Orbstack), NATS through the SOCKS5 proxy is not a concern. If needed, cc-connect can be configured to connect directly.

### Comparison with Claude Code Hooks Fail-Open

| Aspect | Claude Code Hooks | cc-connect Hooks |
|--------|-------------------|------------------|
| Hook type | `command` (shell script) | `webhook` (HTTP POST) |
| Blocking | PreToolUse blocks tool execution | Non-blocking by design |
| Timeout | 5s in settings.json | 5s in hooks config |
| Fail mode | Exit 0 always | Log warning, continue |
| Proxy bypass | `--noproxy '*'` in curl | Not needed (host.orb.internal) |

---

## 9. Comparison Matrix

### Architecture Comparison

| Dimension | Bridge (Vector) | Direct (Hook) | Winner |
|-----------|----------------|---------------|--------|
| Deployments | 2 containers (cc-connect + Vector) | 1 container (cc-connect) | Direct |
| Configuration surface | Vector TOML + cc-connect | cc-connect only | Direct |
| Data path | cc-connect -> stdout -> Docker -> Vector -> CK | cc-connect -> CK | Direct |
| Latency (event -> CK) | ~1-5s (log tail + batch) | ~100-500ms (direct POST) | Direct |
| Buffer on CK outage | Vector disk buffer (configurable) | None (events lost) | Bridge |
| Retry policy | Vector sink retry (configurable) | cc-connect hook retry (2 retries, ~1.5s) | Tie |
| Monitoring surface | Vector metrics + cc-connect logs | cc-connect hook health | Bridge |
| Version coupling | Decoupled (Vector + cc-connect independent) | Coupled (hook config per cc-connect version) | Bridge |
| Upgrade complexity | Upgrade Vector separately | No upgrade needed (part of cc-connect) | Direct |

### Operational Comparison

| Task | Bridge | Direct |
|------|--------|--------|
| Initial setup | Install Vector, write TOML, test log parsing | Add 15 lines of TOML to existing cc-connect config |
| Debug data loss | Check Vector logs, CK logs, Docker logs | Check cc-connect logs, CK logs |
| Add new event type | Update Vector parsing rules + CK schema | Update CK schema (if new fields needed) |
| Roll back | Stop Vector, switch to raw logs | Remove hooks block from config |
| Resource usage | Vector: ~50 MB RAM, ~1% CPU | Zero additional resources |

---

## 10. Pros and Cons

### Pros

1. **Zero additional infrastructure.** No Vector container to deploy, monitor, or update. Fewer containers means fewer failure modes.

2. **Lower latency.** Events reach CK within 100-500ms instead of 1-5s. The log tail + parse + batch pipeline introduces inherent delay.

3. **Simpler debugging.** One config file, one data path. When events don't appear in CK, there are exactly two places to check: cc-connect logs and CK logs. Vector adds a third opaque layer.

4. **Native event semantics.** cc-connect hooks fire at semantically meaningful points (`message.received`, `response.complete`, `session.crashed`). The bridge pattern reconstructed these from log lines, which is fragile and loses context.

5. **Built-in retry.** cc-connect's hook retry with exponential backoff covers the most common failure mode (transient CK unavailability) without additional configuration or infrastructure.

6. **No log format coupling.** The bridge pattern depends on cc-connect's stdout log format, which can change between versions. The hooks API is a stable interface.

7. **Aligns with existing pattern.** Claude Code hooks already use direct-to-CK ([hooks-ck-pipeline.md](../handbook/hooks-ck-pipeline.md)). This makes the observability architecture consistent across both systems.

### Cons

1. **No buffering on CK outage.** Vector's disk buffer can survive multi-hour CK outages. The direct pattern loses events during CK downtime. Mitigation: CK is on the same machine (Orbstack) with >99.9% uptime. Data volume is so low (~34 KB/day) that reingestion from cc-connect logs is trivial.

2. **Requires cc-connect v1.3.2+.** Older versions don't have the hooks system. If an older version is in production, the bridge pattern is the only option. Mitigation: verify the running version.

3. **Thin shim might be needed.** If cc-connect's webhook backend doesn't support URL query parameters in the target URL, a tiny nginx shim (5 lines) is required to translate the POST path into a CK query parameter. This is not middleware -- it has zero business logic.

4. **Event loss on cc-connect crash.** If cc-connect crashes between generating a hook event and successfully POSTing to CK, that event is lost. Vector would have already captured it from the log stream. Mitigation: the last-chance retry covers the 1.5s window after the event fires. For crash loss, the heartbeat event provides a dead-man's-switch: if heartbeats stop, an alert fires.

5. **No event replay.** Once lost, hook events cannot be replayed from cc-connect (no event store). Bridge pattern can replay from Docker logs. Mitigation: keep cc-connect docker logs with a short retention (7 days) as a backup replay source.

6. **Hook config is per cc-connect version.** If the hook API changes between cc-connect versions, the config needs updating. The bridge pattern abstracts this.

### Verdict

**Direct pattern wins for the current scale** (<100 messages/day, single CK instance on the same machine). The zero-infrastructure benefit outweighs the buffering loss for observability data.

**Switch to bridge pattern if any of these conditions are met:**
- cc-connect is deployed on a remote cluster and CK is on a different machine with unreliable connectivity
- Data volume exceeds 1000 events/day and event loss during CK downtime is unacceptable
- Regulatory compliance requires guaranteed event capture (unlikely for chat observability)

---

## 11. Migration Path

### Phase 1: Dual Write (both patterns active)

1. Deploy cc-connect v1.3.2+ with hooks pointing to CK.
2. Keep Vector running during migration.
3. Verify events appear in both `cc.message_log` (via Vector) and `cc.hook_events` (via hooks).
4. Compare counts for a day:

```sql
SELECT 'bridge' AS source, count() AS events
FROM cc.message_log
WHERE event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 'direct' AS source, count() AS events
FROM cc.hook_events
WHERE event_time >= now() - INTERVAL 1 DAY;
```

### Phase 2: Switch Grafana to New Table

1. Update Grafana dashboards to query `cc.hook_events` instead of `cc.message_log`.
2. Verify all panels show matching data.

### Phase 3: Retire Vector

1. Stop Vector container: `docker stop kyb-infra-vector && docker rm kyb-infra-vector`.
2. Remove Vector config.
3. Clean up Vector's ClickHouse user if one was created.

### Phase 4: Archive Old Table

1. Wait 90 days (TTL of `cc.message_log`).
2. Drop `cc.message_log` after confirming no queries reference it.

```sql
DROP TABLE cc.message_log;
```

---

## 12. Grafana Queries

Replace the bridge-pattern queries with these direct-hook queries.

### Message Volume (Replaces bridge query on `cc.message_log`)

```sql
SELECT
    toStartOfMinute(event_time) AS ts,
    event_type,
    count() AS cnt
FROM cc.hook_events
WHERE event_time >= now() - INTERVAL 1 DAY
  AND event_type IN ('message.received', 'response.complete')
GROUP BY ts, event_type
ORDER BY ts;
```

### Response Latency P50/P90/P99 (Replaces `turn_duration` from bridge)

```sql
SELECT
    toStartOfMinute(event_time) AS ts,
    quantile(0.50)(turn_duration) AS p50,
    quantile(0.90)(turn_duration) AS p90,
    quantile(0.99)(turn_duration) AS p99
FROM cc.hook_events
WHERE event_type = 'response.complete'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY ts
ORDER BY ts;
```

### Active Sessions (New -- only available via hooks)

```sql
SELECT
    toStartOfMinute(event_time) AS ts,
    avg(active_sessions) AS avg_sessions,
    max(active_sessions) AS max_sessions
FROM cc.hook_events
WHERE event_type = 'heartbeat'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY ts
ORDER BY ts;
```

### Session Crash Rate (New -- only available via hooks)

```sql
SELECT
    toStartOfHour(event_time) AS ts,
    count() AS crashes,
    error_code
FROM cc.hook_events
WHERE event_type = 'session.crashed'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY ts, error_code
ORDER BY ts;
```

### Hook Health (Dead Man's Switch)

```sql
SELECT
    count() AS events_last_15min
FROM cc.hook_events
WHERE event_type = 'heartbeat'
  AND event_time > now() - INTERVAL 15 MINUTE;
```

If `events_last_15min` is 0, cc-connect hooks pipeline is broken.

### End-to-End Message Flow (Trace)

```sql
SELECT
    event_time,
    event_type,
    turn_duration,
    content_text,
    input_tokens,
    output_tokens,
    tools_used,
    error_message
FROM cc.hook_events
WHERE trace_id = 'tr_abc123'
ORDER BY event_time;
```

This query shows the full lifecycle of a single message: received -> response complete (or timeout/crash).

---

## Summary

| Aspect | Decision |
|--------|----------|
| Architecture | Direct: cc-connect hook -> HTTP POST -> CK |
| Middleware | None (thin nginx shim only if needed for CK query params) |
| Events captured | message.received, response.complete, session.timeout, session.crashed, session.resumed, permission.requested, heartbeat |
| Table | `cc.hook_events` (supersedes `cc.message_log`) |
| Retry | cc-connect native: 2 retries, exponential backoff 500ms-5s |
| Fail-open | Yes: hook failure never blocks message pipeline |
| TTL | 90 days |
| Migration | Dual write -> Grafana switch -> retire Vector -> archive old table |
| Verdict | Direct wins at current scale. Revisit if multi-cluster CK with unreliable WAN. |

---

**Related Documents:**
- [hooks-ck-pipeline.md](../handbook/hooks-ck-pipeline.md) -- Claude Code hooks to CK (same direct pattern)
- [Review C1: bridge-hooks-alerting.md](review-bridge-hooks-C1.md) -- Discovery that cc-connect v1.3.2 has native hooks
- [Review C2: bridge-hooks-alerting.md](review-bridge-hooks-C2.md) -- Grafana alerting review
- [Review C3: bridge-hooks-alerting.md](review-bridge-hooks-C3.md) -- cc-healthcheck coverage analysis
