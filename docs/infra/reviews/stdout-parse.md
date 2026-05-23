---
decision: 稍后做
---

# Stdout Log Parsing as Interception

**Design doc**: `docs/infra/reviews/stdout-parse.md`
**Date**: 2026-05-23
**Scope**: Parse cc-connect stdout structured logs with Vector to extract every available message signal — no proxy needed. Position this as the primary interception layer; the MITM proxy (`proxy-intercept.md`) is a future complement for raw payload capture.

---

## 1. Motivation

cc-connect already emits structured key=value log lines via Go `slog` for every significant event: message receive, turn completion, permission flow, agent warnings, WebSocket state changes. These lines are today consumed by Vector for basic metrics, but **they contain far more signal than is currently extracted**.

The grep below reveals everything cc-connect tells us about itself today:

```
$ docker logs kyb-infra-cc-connect 2>&1 | grep -oP 'msg="[^"]*"' | sort | uniq -c | sort -rn
```

Each `msg=` value represents a **trace point** in the message lifecycle. By exhaustively cataloging and parsing every message type, we reconstruct the full message turn lifecycle without any code changes to cc-connect.

### Why This Matters

| Concern | Stdout Parse Solves It | Proxy Needed? |
|---------|------------------------|---------------|
| Message lifecycle tracking | All turn events available | No |
| Token consumption monitoring | `input_tokens`, `output_tokens` in turn complete | No |
| Latency breakdown | `turn_duration` in every turn complete | No, but proxy gives sub-ms timing |
| Permission flow timing | `permission request` + `permission resolved` pair | No |
| Tool usage tracking | `tools=2` in turn complete | No |
| WS reconnect detection | `reconnect` / `websocket: connected` lines | No |
| Slow operations | `slow agent send` with elapsed time | No |
| Raw WS frame payloads | **Not in stdout** | Yes |
| Replay capability | **Not possible without payloads** | Yes |
| Sub-ms frame timing | Go `slog` precision is ms | Yes |

**Thesis**: Stdout parsing covers ~90% of observability signals. The proxy is only needed for the remaining 10% (payload debugging, replay, protocol-level analysis). Build the stdout parse layer first — it's zero-cost (no new binary, no connection changes) and immediately valuable.

---

## 2. Current Architecture

```
Feishu (open.feishu.cn)
    │
    │ WSS (wss://msg-frontier.feishu.cn:443)
    ▼
cc-connect  (Go binary, single Docker container)
    │
    ├──→ stdout: slog key=value lines
    │            - "message received"
    │            - "turn complete"
    │            - "permission request/response"
    │            - "slow agent send"
    │            - "reconnect" / WS events
    │            - Debug/INFO/WARN/ERROR lines
    │
    ├──→ Claude API (outbound HTTPS)
    │
    └──→ Vector (docker_logs source → parse → CK)
```

### 2.1 The Interception Point

Vector reads cc-connect's stdout via the Docker socket. This is **log-level interception** — we observe the events as cc-connect reports them, not as they occur on the wire. The trade-off:

| Aspect | Log Interception (this doc) | Proxy Interception (proxy-intercept.md) |
|--------|----------------------------|----------------------------------------|
| Observability | Events as cc-connect sees them | Events as they happen on the wire |
| Latency precision | ms-level (Go slog timestamp) | ns-level (monotonic clock in proxy) |
| Payload visibility | Metadata only (lengths, counts) | Full payload (truncated configurable) |
| Deployment impact | None (reads existing stdout) | New binary, connection rerouting |
| Fail-open | Inherent (logs are non-blocking) | Requires bypass mechanism |
| Code changes needed | None | Yes (proxy binary + config) |

---

## 3. Signal Catalog

Every cc-connect stdout message type, its fields, and what signal it provides.

### 3.1 Message Lifecycle

#### `msg="message received"`

```
time=2026-05-23T16:37:37.828Z level=INFO msg="message received" platform=feishu msg_id=om_x... session=feishu:oc_...:ou_... user=ou_... content_len=65 has_images=false has_audio=false has_files=false
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Inbound event rate | Count of this msg type per time window | Messages/min |
| User activity | `user` / `sender_id` field | Per-user message count |
| Content size trend | `content_len` across all messages | Avg/min/max content bytes |
| Media type ratio | `has_images`, `has_audio`, `has_files` booleans | % of messages with media |
| Session identity | `session` → parse `oc_CHATID:ou_USERID` | Chat-level aggregation |

#### `msg="turn complete"`

```
time=2026-05-23T16:38:00.604Z level=INFO msg="turn complete" session=s1 agent_session=d2720c67-... msg_id=om_x... tools=2 response_len=554 turn_duration=4h13m27.227059634s input_tokens=431 output_tokens=521
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Token consumption | `input_tokens`, `output_tokens` | Total token spend per turn; daily/monthly cost tracking |
| Turn latency | `turn_duration` (Go duration → Float64 seconds) | P50/P95/P99 response time |
| Tool usage | `tools` count | How many tool calls per turn |
| Response size | `response_len` bytes | Output verbosity trend |
| Agent session | `agent_session` UUID | Correlation with upstream trace IDs |

#### `msg="message_send_failed"` (observed but undocumented)

```
time=... level=ERROR msg="message_send_failed" msg_id=om_x... error="rate_limit" retry_after=30
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Feishu API errors | Count per error type | Error rate, rate limit frequency |
| Backoff behavior | `retry_after` field | How long cc-connect pauses |

### 3.2 Permission Flow

#### `msg="permission request"`

```
time=... level=INFO msg="permission request" request_id=... tool=Bash
```

#### `msg="permission resolved"`

```
time=... level=INFO msg="permission resolved" request_id=... decision=approved duration=12.5
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Permission latency | Join request→resolved on `request_id`, compute `duration` | Human response time (P50/P95) |
| Permission rate | Count per tool | Which tools trigger most permission requests |
| Decision ratio | `decision=approved` vs `decision=denied` | % of tool uses approved |
| Tool heatmap | `tool` field on request | Permission-demanding tools rank |

**Join strategy**: "permission request" and "permission resolved" share `request_id`. Vector's `reduce` transform merges them (see Section 6).

### 3.3 Performance Warnings

#### `msg="slow agent send"`

```
time=... level=WARN msg="slow agent send" elapsed=45.2 session=... content_len=...
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Slow response detection | Threshold-based: WARN level + `elapsed` field | Early warning for stuck agents |
| Content accumulation | `content_len` on slow sends | Agent accumulating context without responding |

### 3.4 WebSocket Health

cc-connect uses Go standard library logger (not slog) for WS-level events:

```
[Debug] 2026/05/23 16:37:35 websocket: connected to wss://msg-frontier.feishu.cn:443
[Debug] 2026/05/23 16:37:35 websocket: connection established in 1.234s
[Error] 2026/05/23 16:42:10 websocket: close received: going away
[Info]  2026/05/23 16:42:10 websocket: reconnecting in 5s (attempt 2)
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Reconnect count | Line count matching `reconnecting` | Reconnects per time window |
| Reconnect backoff | `attempt N` value | Backoff stage, detect reset |
| Connection latency | `connection established in Xs` | WS handshake time |
| Disconnect reason | `close received: ...` text | Categorize disconnect causes |
| Connection state | Uptime between connect/disconnect lines | Connection stability |

**Parsing challenge**: These lines use Go std logger format, NOT `slog` key=value. Vector needs regex-based parsing for this section.

### 3.5 Error Conditions

Observed error line patterns:

```
time=... level=ERROR msg="context deadline exceeded" ...
time=... level=ERROR msg="feishu API error" status=429 body="..."
time=... level=ERROR msg="websocket: failed to connect after 3 attempts"
```

| Signal | How Extracted | Value |
|--------|---------------|-------|
| Error rate | Count of `level=ERROR` lines per time window | Overall bridge error rate |
| Error type breakdown | `msg` value for each ERROR line | Which errors dominate |
| Transient vs persistent | Consecutive same error | Distinguish blips from systemic failures |

### 3.6 Debug Lines (Structured)

```
time=... level=DEBUG msg="agent response" response_truncated=true content_preview="..."
```

cc-connect's debug-level lines (when enabled) contain detailed agent response data. These are **opt-in** via `--debug` flag or `CC_DEBUG=true` env var.

---

## 4. Interception Architecture

### 4.1 Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                   cc-connect container                       │
│                                                              │
│  Go slog (key=value) ──→ stdout ──→ Docker log driver        │
│  Go stdlog ([Debug])  ──→ stdout ──→ Docker log driver       │
│                                                              │
└─────────────────────────────────┬───────────────────────────┘
                                  │ Docker socket
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│                     Vector Pipeline                          │
│                                                              │
│  Source: docker_logs(kyb-infra-cc-connect)                   │
│       │                                                      │
│       ▼                                                      │
│  Transform: filter_cc_connect                                │
│       │  (by container_name or kyb.service label)            │
│       ▼                                                      │
│  Transform: parse_cc_kv                                      │
│       │  (parse key=value, extract all fields)               │
│       ▼                                                      │
│  Transform: parse_cc_debug                                   │
│       │  (regex-parse [Debug] lines for WS events)           │
│       ▼                                                      │
│  Transform: classify_event                                   │
│       │  (map msg→event_type, enrich metadata)               │
│       ▼                                                      │
│  Transform: reduce_cc_turn                                   │
│       │  (join msg_id groups: receive + complete)            │
│       ▼                                                      │
│  Transform: reduce_cc_permission                             │
│       │  (join request_id groups: req + resolved)            │
│       ▼                                                      │
│  Transform: add_cluster_metadata                             │
│       │                                                      │
│       ▼                                                      │
│  Sink: clickhouse (cc.message_log)                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Distinction from Proxy

The proxy approach (`proxy-intercept.md`) intercepts at **layer 7 (WebSocket)**, giving payload-level visibility. This approach intercepts at **layer 7 (application log)**, giving event-level visibility.

```
                    Proxy intercept (WS frames)
                    ─────────────────────────
Feishu ──WSS──→  feishu-proxy  ──WS──→ cc-connect
                     │
                     ▼ capture every WS frame
                [raw payload, ns timing]


                    Stdout intercept (application logs)
                    ─────────────────────────────────
Feishu ──WSS──→ cc-connect ──stdout──→ Vector
                                       ▼ capture every log line
                                  [structured metadata, ms timing]
```

The two approaches are **complementary**, not alternatives:
- **Stdout parse first** (this doc): zero new code, covers 90% of signals
- **Proxy later** (proxy-intercept.md): covers the remaining 10% (raw payloads, replay)

Both write to the same ClickHouse tables for unified querying.

---

## 5. Vector Configuration

### 5.1 Source

```toml
[sources.docker_infra]
type = "docker_logs"
docker_host = "unix:///var/run/docker.sock"
auto_partial_merge = true
auto_partial_merge_wait_ms = 2000
```

Auto-discovery via container labels `kyb.logs=true` and `kyb.service=cc-connect`.

### 5.2 Filter

```toml
[transforms.filter_cc_connect]
type = "filter"
inputs = ["docker_infra"]
condition = '''
  .container_name == "kyb-infra-cc-connect" ||
  .labels."kyb.service" == "cc-connect"
'''
```

### 5.3 Key=Value Parser (slog lines)

```toml
[transforms.parse_cc_kv]
type = "remap"
inputs = ["filter_cc_connect"]
source = '''
  # ── Route: Go slog key=value vs Go stdlog [Debug] ──
  if exists(.message) {
    # Detect [Debug] prefix (Go std logger format)
    if match!(.message, r'^\[(Debug|Info|Error|Warn)\]\s+\d{4}/\d{2}/\d{2}') {
      .log_format = "stdlog"
      .parsed = parse_regex!(.message, r'^\[(?P<level>\w+)\]\s+(?P<timestamp>\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})\s+(?P<subsystem>\w+):\s+(?P<content>.+)$')
      if !is_null(.parsed) {
        .log_level = .parsed.level
        .raw_timestamp = .parsed.timestamp
        .subsystem = .parsed.subsystem
        .raw_content = .parsed.content
      }
      # Route to WS event classifier
      .event_source = "ws_health"
    } else {
      # Go slog key=value format
      .log_format = "slog"
      .parsed = parse_key_value!(.message, field_delimiter: " ")
      .log_level = .parsed.level
      .event_time = .parsed.time
      .msg = .parsed.msg
      .event_source = "app_event"

      # Extract all known fields by category
      #
      # Message identifiers
      .msg_id = .parsed.msg_id ?? ""
      .session = .parsed.session ?? ""
      .agent_session = .parsed.agent_session ?? ""
      .request_id = .parsed.request_id ?? ""

      # Message metadata (from "message received")
      .platform = .parsed.platform ?? ""
      .user = .parsed.user ?? ""
      .content_len = to_int!(.parsed.content_len) ?? 0
      .has_images = .parsed.has_images == "true"
      .has_audio = .parsed.has_audio == "true"
      .has_files = .parsed.has_files == "true"

      # Turn metrics (from "turn complete")
      .tools_used = to_int!(.parsed.tools) ?? 0
      .response_len = to_int!(.parsed.response_len) ?? 0
      .turn_duration_raw = .parsed.turn_duration ?? ""
      .input_tokens = to_int!(.parsed.input_tokens) ?? 0
      .output_tokens = to_int!(.parsed.output_tokens) ?? 0

      # Permission fields (from "permission request" / "permission resolved")
      .tool_name = .parsed.tool ?? ""
      .decision = .parsed.decision ?? ""
      .permission_duration = .parsed.duration ?? ""

      # Error fields
      .error = .parsed.error ?? ""
      .status_code = to_int!(.parsed.status) ?? 0
      .retry_after = to_int!(.parsed.retry_after) ?? 0

      # Agent response fields (DEBUG level)
      .response_truncated = .parsed.response_truncated == "true"
      .content_preview = .parsed.content_preview ?? ""

      # Slow agent fields
      .elapsed = .parsed.elapsed ?? ""

      # Session field parsing
      if .session != "" {
        parts = split(.session, ":")
        if length(parts) >= 3 {
          .chat_id = parts[1]
          .sender_id = parts[2]
        } else if length(parts) >= 2 {
          .chat_id = parts[1]
        }
      }
      if .sender_id == "" {
        .sender_id = .user ?? ""
      }

      # Convert turn_duration Go string to Float64 seconds
      if .turn_duration_raw != "" {
        .turn_duration = parse_go_duration(.turn_duration_raw)
      } else {
        .turn_duration = 0.0
      }

      # Normalize timestamp
      if .event_time != "" {
        .timestamp = parse_timestamp!(.event_time, format: "%+") ?? now()
      } else {
        .timestamp = now()
      }

      # Event classification
      if .msg == "turn complete" {
        .event_type = "message_sent"
        .direction = "outbound"
      } else if .msg == "message received" {
        .event_type = "message_received"
        .direction = "inbound"
      } else if .msg == "permission request" {
        .event_type = "permission_request"
        .direction = null
      } else if .msg == "permission resolved" {
        .event_type = "permission_resolved"
        .direction = null
      } else if find(.msg, "slow agent") != null {
        .event_type = "slow_agent_send"
        .direction = "outbound"
      } else if find(.msg, "failed") != null || find(.msg, "error") != null {
        .event_type = "error"
        .direction = null
      } else if .log_level == "DEBUG" {
        .event_type = "debug"
        .direction = null
      } else {
        .event_type = "unknown"
        .direction = null
      }
    }
  }
'''
```

### 5.4 WS Health Parser (stdlog lines)

```toml
[transforms.extract_ws_events]
type = "remap"
inputs = ["parse_cc_kv"]
source = '''
  if .event_source != "ws_health" {
    abort
  }

  .timestamp = now()
  .event_type = "ws_event"

  # Classify WS event from raw_content
  content = .raw_content ?? ""

  if match(content, r'connected\s+to') {
    .ws_event_type = "ws_connect_start"
  } else if match(content, r'connection\s+established') {
    .ws_event_type = "ws_connected"
    .ws_handshake_ms = to_float!(parse_regex(content, r'in\s+([\d.]+)s")[1]) ?? 0.0
  } else if match(content, r'close\s+received') {
    .ws_event_type = "ws_close_received"
    .ws_close_reason = content
  } else if match(content, r'reconnecting') {
    .ws_event_type = "ws_reconnecting"
    .ws_reconnect_attempt = to_int!(parse_regex(content, r'attempt\s+(\d+)")[1]) ?? 0
  } else if match(content, r'failed\s+to\s+connect') {
    .ws_event_type = "ws_connect_failed"
    .ws_fail_attempts = to_int!(parse_regex(content, r'(\d+)\s+attempts?")[1]) ?? 0
  } else {
    .ws_event_type = "ws_other"
  }

  # Derive WS state and health signals
  if .ws_event_type == "ws_connected" {
    .ws_state = "connected"
  } else if .ws_event_type == "ws_reconnecting" {
    .ws_state = "reconnecting"
  } else if .ws_event_type == "ws_connect_failed" {
    .ws_state = "disconnected"
  } else if .ws_event_type == "ws_close_received" {
    .ws_state = "disconnected"
  }
'''
```

### 5.5 Join Transforms

#### Turn Join (message_received + message_sent on msg_id)

```toml
[transforms.reduce_cc_turn]
type = "reduce"
inputs = ["parse_cc_kv"]
group_by = ["msg_id"]
starts_when = '.event_type == "message_received"'
ends_when = '.event_type == "message_sent" || .event_type == "error"'
merge_strategies = { struct = "merge" }
when_full = "wait_for_timeout"
timeout_ms = 300000  # 5 min — if no complete, emit as orphan
source = '''
  .event_type = "message_turn"
  .turn_complete = true
  .direction = null
  .trace_id = .msg_id
'''
```

#### Permission Join (permission_request + permission_resolved on request_id)

```toml
[transforms.reduce_cc_permission]
type = "reduce"
inputs = ["parse_cc_kv"]
group_by = ["request_id"]
starts_when = '.event_type == "permission_request"'
ends_when = '.event_type == "permission_resolved"'
merge_strategies = { struct = "merge" }
when_full = "wait_for_timeout"
timeout_ms = 600000  # 10 min — permission timeout
source = '''
  .event_type = "permission_completed"
  .permission_complete = true
'''
```

### 5.6 Go Duration Parser (VRL Function)

Vector has no built-in Go `time.Duration` parser. Implement as a helper:

```coffee
# Parse Go time.Duration to Float64 seconds
# Input: "4h13m27.227059634s" → 15207.227
#        "2.941035153s"       → 2.941
#        "500ms"              → 0.5
#        "1m30s"              → 90.0

def parse_go_duration(raw) -> float {
  if raw == "" || raw == "0s" {
    return 0.0
  }

  s = raw

  # Strip trailing 's' if present
  if ends_with(s, "s") && !ends_with(s, "ms") {
    s = trim_suffix(s, "s")
  } else if ends_with(s, "ms") {
    # Milliseconds: strip "ms" and divide
    ms_val = to_float!(trim_suffix(s, "ms")) ?? 0.0
    return ms_val / 1000.0
  }

  total = 0.0

  # Extract hours
  parts = split(s, "h")
  if length(parts) >= 2 {
    total = total + (to_float!(parts[0]) * 3600.0)
    s = parts[1]
  }

  # Extract minutes
  parts = split(s, "m")
  if length(parts) >= 2 {
    total = total + (to_float!(parts[0]) * 60.0)
    s = parts[1]
  }

  # Remaining is seconds
  if s != "" && s != "0" {
    total = total + to_float!(s)
  }

  total
}
```

---

## 6. ClickHouse Schema

### 6.1 Unified Table: `cc.message_log`

This is the **single consolidated table** for ALL intercepted stdout signals. Both this pipeline and the future proxy pipeline write to it. Fields that only the proxy provides are marked `-- proxy only`.

```sql
CREATE TABLE cc.message_log (
    -- Timestamps
    timestamp           DateTime64(3),
    ingested_at         DateTime64(3) DEFAULT now64(),

    -- Event classification
    event_type          LowCardinality(String),
    -- Values: message_received, message_sent, message_turn, permission_request,
    --         permission_resolved, permission_completed, slow_agent_send,
    --         ws_event, error, debug, unknown
    direction           LowCardinality(String),
    -- Values: inbound, outbound, null
    log_level           LowCardinality(String),
    -- Values: DEBUG, INFO, WARN, ERROR
    log_format          LowCardinality(String),
    -- Values: slog, stdlog

    -- Identifiers
    msg_id              String,
    session             String,
    chat_id             String,
    sender_id           String,
    agent_session       String,
    request_id          String,

    -- Message metadata (from "message received")
    content_len         UInt32,
    content_preview     String,
    has_images          UInt8,
    has_audio           UInt8,
    has_files           UInt8,
    platform            LowCardinality(String),

    -- Turn metrics (from "turn complete")
    response_len        UInt32,
    turn_duration       Float64,
    input_tokens        UInt32,
    output_tokens       UInt32,
    tools_used          UInt8,

    -- Permission fields
    tool_name           LowCardinality(String),
    decision            LowCardinality(String),
    permission_duration Float64,

    -- Error fields
    error               String,
    status_code         UInt16,
    retry_after         UInt16,

    -- Slow agent fields
    elapsed             Float64,
    response_truncated  UInt8,

    -- WebSocket health fields
    ws_event_type       LowCardinality(String),
    ws_state            LowCardinality(String),
    ws_handshake_ms     Float64,
    ws_reconnect_attempt UInt8,
    ws_close_reason     String,

    -- Vector enrichment
    cluster             LowCardinality(String),
    container_name      String,
    host                String,

    -- Proxy-only fields (populated by proxy intercept, null here)
    -- frame_len           UInt32,           -- proxy only
    -- frame_opcode        LowCardinality(String),  -- proxy only
    -- payload_truncated   UInt8,            -- proxy only
    -- payload_sha256      FixedString(64),  -- proxy only
    -- payload             String,           -- proxy only
    -- conn_id             String            -- proxy only
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), event_type, msg_id)
TTL toDate(timestamp) + INTERVAL 90 DAY
```

**Indexes**:

```sql
-- For msg_id lookups (turn join, debugging)
ALTER TABLE cc.message_log ADD INDEX idx_msg_id msg_id TYPE set(100) GRANULARITY 1;

-- For chat_id analysis
ALTER TABLE cc.message_log ADD INDEX idx_chat_id chat_id TYPE set(100) GRANULARITY 4;

-- For request_id lookups (permission flow)
ALTER TABLE cc.message_log ADD INDEX idx_request_id request_id TYPE set(100) GRANULARITY 1;

-- For WS health queries
ALTER TABLE cc.message_log ADD INDEX idx_ws_state ws_state TYPE set(10) GRANULARITY 4;
```

**Why a single table**: All intercepted stdout events share the same time-series + identifier dimensions. Separate tables would force JOINs for cross-event correlation (e.g., "what was the token cost for the message that caused a reconnect?"). Proxy-only fields are simply left NULL until the proxy pipeline is active.

### 6.2 Materialized Views for Query Performance

#### Turn Summary View

```sql
CREATE MATERIALIZED VIEW cc.turn_summary
ENGINE = AggregatingMergeTree
ORDER BY (toDate(timestamp), chat_id)
POPULATE AS
SELECT
    toDate(timestamp) AS day,
    chat_id,
    countIf(event_type == 'message_turn') AS turns,
    sum(input_tokens) AS total_input_tokens,
    sum(output_tokens) AS total_output_tokens,
    avg(turn_duration) AS avg_turn_duration_sec,
    quantile(0.50)(turn_duration) AS p50_turn_duration,
    quantile(0.95)(turn_duration) AS p95_turn_duration,
    quantile(0.99)(turn_duration) AS p99_turn_duration
FROM cc.message_log
WHERE event_type == 'message_turn'
GROUP BY day, chat_id;
```

#### WS Health Summary View

```sql
CREATE MATERIALIZED VIEW cc.ws_health_hourly
ENGINE = AggregatingMergeTree
ORDER BY (toDate(timestamp), cluster)
POPULATE AS
SELECT
    toStartOfHour(timestamp) AS hour,
    cluster,
    countIf(ws_event_type == 'ws_reconnecting') AS reconnects,
    countIf(ws_event_type == 'ws_connect_failed') AS connect_failures,
    maxIf(ws_reconnect_attempt, ws_event_type == 'ws_reconnecting') AS max_reconnect_attempt,
    countIf(ws_event_type == 'ws_connected') AS connections_established
FROM cc.message_log
WHERE event_type == 'ws_event'
GROUP BY hour, cluster;
```

---

## 7. Grafana Panels

### 7.1 Message Lifecycle Dashboard

| Panel | Query | Purpose |
|-------|-------|---------|
| Messages per hour | `count() GROUP BY toStartOfHour(timestamp)` WHERE event_type IN ('message_received','message_sent') | Throughput overview |
| Turn latency (P50/P95/P99) | `quantile(0.50/0.95/0.99)(turn_duration)` WHERE event_type='message_turn' | Response time SLO tracking |
| Token consumption | `sum(input_tokens + output_tokens) GROUP BY toDate(timestamp)` | Daily token spend |
| Active sessions | `uniq(sender_id)` over 1h window | Unique users engaging the bot |
| Permission latency | `quantile(0.50/0.95)(permission_duration)` | Human response time |

### 7.2 Permission Flow Dashboard

| Panel | Query | Purpose |
|-------|-------|---------|
| Permission requests per tool | `count() GROUP BY tool_name` | Which tools trigger most permission requests |
| Approval rate | `countIf(decision='approved') / count() * 100` | % of tool uses approved |
| Permission latency heatmap | `quantiles(permission_duration)` by `tool_name` | Human response time per tool |
| Pending permissions | `countIf(event_type='permission_request' AND timestamp > now() - 1h)` | Currently unresolved requests (with timeout awareness) |

### 7.3 WS Health Dashboard

| Panel | Query | Purpose |
|-------|-------|---------|
| Reconnects per hour | `countIf(ws_event_type='ws_reconnecting')` | Reconnect frequency |
| Connection state | Last `ws_state` value | Currently connected or disconnected |
| Reconnect attempts | `max(ws_reconnect_attempt)` per event | Backoff escalation (spike = trouble) |
| Connection uptime | Gap between connect and disconnect events | Connection stability duration |
| Handshake latency | `quantile(0.50/0.95)(ws_handshake_ms)` WS connect time | Network path quality to feishu |

---

## 8. Coverage Analysis

### 8.1 What We CAN See (Stdout Parse)

| Domain | Signal | Completeness |
|--------|--------|-------------|
| **Message lifecycle** | Receive event → process → send response | Full — every turn has a "message received" + "turn complete" pair |
| **Token tracking** | Input tokens, output tokens per turn | Full — every turn complete has these fields |
| **Latency** | Turn duration in seconds | Full — ms precision from Go slog timestamp |
| **Permission flow** | Request → decision + timing | Full — request/resolved pairs always logged |
| **Tool usage** | How many tools per turn | Full — `tools=N` in every turn complete |
| **WS health** | Connect, disconnect, reconnects | Partial — Go stdlog lines are present but only at [Debug] level; may be suppressed |
| **Errors** | Any ERROR-level message | Full — all errors logged with context |
| **Content size** | inbound content_len, outbound response_len | Full — every message has these |
| **Session identity** | chat_id, sender_id, agent_session | Full — extracted from session field |

### 8.2 What We MISS (Needs Proxy)

| Domain | Signal | Reason Missing |
|--------|--------|---------------|
| **Raw message content** | User text, image URLs, card payloads | cc-connect does not log content, only `content_len` |
| **Frame-level timing** | Nanosecond precision between WS frames | Go slog only provides ms precision; proxy uses `clock_gettime` |
| **Protocol errors** | Malformed frames, sequence violations | cc-connect handles these internally, only logs the outcome |
| **Replay capability** | Offline playback of real traffic | Requires captured payloads |
| **Payload integrity verification** | SHA-256 of WS frames | Requires proxy to compute and log |
| **Connection-level metrics** | Frame sequence gaps, out-of-order delivery | Proxy's connection tracking per frame_seq |
| **Heartbeat ping/pong** | WS-level keepalive tracking | cc-connect may not log every ping/pong |

### 8.3 Coverage Ratio Estimate

Based on the signal catalog and current message volume (~90 messages/day):

| Metric | Lines/day | Signals Extracted | Proxy Needed? |
|--------|-----------|-------------------|---------------|
| "message received" | ~90 | 10 (msg_id, session, user, content_len, 4 booleans, platform) | No |
| "turn complete" | ~90 | 11 (tokens, duration, tools, response_len, agent_session) | No |
| "permission request" | ~5-30 | 3 (request_id, tool, timing) | No |
| "permission resolved" | ~5-30 | Same join with timing | No |
| "slow agent send" | ~0-5 | 3 (elapsed, session, content_len) | No |
| WS events | ~2-20 | 5 (connect, disconnect, reconnect, attempt, handshake) | No |
| ERROR lines | ~0-10 | 4 (error, status, retry_after) | No |

**Estimated coverage: ~90% of actionable observability signals** without a proxy. The missing 10% (raw payloads, frame timing) only matters during deep debugging or replay scenarios.

---

## 9. Comparison: Stdout Parse vs Proxy Intercept

| Dimension | Stdout Parse (this doc) | Proxy Intercept (proxy-intercept.md) |
|-----------|------------------------|--------------------------------------|
| **Deployment** | Zero — reads existing stdout | New Go binary, config changes, connection rerouting |
| **Code changes** | None | New `feishu-proxy` binary to build and maintain |
| **Fail-open** | Inherent — logs are non-blocking | Requires DNS fallback + health endpoint |
| **Latency impact** | None | <1ms added per frame |
| **Payload visibility** | Metadata only | Full payload (truncated configurable) |
| **Timing precision** | ms (from Go slog) | ns (from monotonic clock) |
| **Replay capability** | None | Full (captured frames replayed) |
| **Storage cost/day** | ~5 KB (metadata only) | ~108 KB (truncated) or ~4.5 MB (full) |
| **Operational burden** | None (already running in Vector) | New binary to build, ship, monitor |
| **Confidence** | 90% signal coverage | 100% signal coverage |

### When to Use Each

| Scenario | Use |
|----------|-----|
| **Daily operations** (SLOs, token cost, error rate, latency) | Stdout parse — sufficient, zero cost |
| **Incident response** ("why did this message fail?") | Stdout parse first (fastest path to clues), proxy if payload needed |
| **Deep debugging** ("feishu sent a malformed frame") | Proxy — only way to see raw payloads |
| **Regression testing** ("does new cc-connect handle old traffic?") | Proxy — replay requires captured frames |
| **Capacity planning** (token trends, user growth) | Stdout parse — aggregate metrics are metadata |
| **Security audit** ("was PII leaked in a WS frame?") | Proxy — only way to inspect payloads |

---

## 10. Implementation Plan

### Phase 0: Quick Win (1 hour)

- [ ] Verify Vector reads cc-connect docker logs and current `parse_cc_kv` transform works
- [ ] Confirm all known `msg=` values from cc-connect stdout exist in logs
- [ ] Add missing event types to classification lookup (`message_send_failed`, `debug`, etc.)
- [ ] Deploy updated Vector config

### Phase 1: Full Signal Extraction (1 day)

- [ ] Implement `parse_go_duration` VRL function (from Section 5.6)
- [ ] Implement session field parser (`chat_id`, `sender_id` extraction)
- [ ] Implement WS health parser for Go stdlog lines (`[Debug] websocket: ...`)
- [ ] Implement `reduce` transforms for msg_id and request_id joins
- [ ] Add `add_cluster_metadata` enrichment
- [ ] Create `cc.message_log` table in ClickHouse

### Phase 2: Query Layer (0.5 day)

- [ ] Create materialized views: `cc.turn_summary`, `cc.ws_health_hourly`
- [ ] Add secondary indexes for msg_id, chat_id, request_id, ws_state
- [ ] Create Grafana dashboard: message lifecycle + permissions + WS health
- [ ] Verify dashboard query performance with 30 days of data

### Phase 3: Alert Rules (0.5 day)

- [ ] Error rate spike: `rate(countIf(log_level='ERROR')) > 2x baseline`
- [ ] Turn latency degraded: `p95(turn_duration) > 30s` for 5m
- [ ] Reconnect storm: `reconnects/hour > 10`
- [ ] Zombie connection: `no ws_connected event for > 10m`
- [ ] Permission timeout: `unresolved permission > 5m`

### Phase 4: Proxy Complement (Future)

- [ ] Build `feishu-proxy` binary (per proxy-intercept.md)
- [ ] Deploy in parallel with stdout parse (both write to `cc.message_log`)
- [ ] Proxy-only fields populated in `cc.message_log` when proxy is active
- [ ] Proxy adds `payload`, `frame_len`, `conn_id`, `payload_sha256` to existing records

---

## 11. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Interception layer** | Stdout parse (not proxy) as primary | Zero deployment cost, covers 90% of signals, no new binary |
| **Storage model** | Single `cc.message_log` table with nullable proxy fields | Unified querying; proxy fields are additive, not breaking |
| **WS health** | Regex parse of Go stdlog lines | Simpler than OTel metrics for WS state; OTel can be added later |
| **Permission join** | Vector `reduce` on `request_id` | Handles 10-min timeout; unmatched requests orphan naturally |
| **Duration parsing** | Custom VRL function | Vector lacks native Go duration parser; VRL handles it cleanly |
| **Proxy deployment** | Postpone to Phase 4 | Stdout parse meets current needs; proxy is nice-to-have, not required |
| **Alerting** | Based on `cc.message_log` queries | Reuses existing CK pipeline; no Prometheus dependency for alerts |

---

## 12. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| Enable cc-connect debug logging in production? | (a) Always on (b) Toggle via env var (c) Never | Debug lines add signal but increase volume ~2x — benchmark first |
| TTL for `cc.message_log`? | (a) 90 days (b) 30 days (c) Tiered: 30d hot, 1y cold | Depends on token cost tracking requirements (need year-over-year comparison?) |
| Alert from CK queries or Prometheus? | (a) CK alerts via Grafana (b) Prometheus recording rules from Vector metrics | Vector can export Prometheus metrics directly — lighter weight than CK queries |
| Correlation with OTel traces? | (a) By `agent_session` UUID (b) By `msg_id` (c) By timestamp window | `msg_id` is the most reliable join key between logs and traces |
| Handle cc-connect log format changes? | (a) Validate config in CI when cc-connect updates (b) Schema-on-read with ClickHouse (c) Both | cc-connect may add new fields or change log format — needs a monitoring check |

---

> **Summary**: Stdout log parsing IS interception. By exhaustively cataloging and parsing every cc-connect stdout log message, Vector reconstructs the full message lifecycle — receive, process, permission, send, errors, WS health — without any proxy binary, connection changes, or fail-open mechanisms. Coverage is ~90% of actionable observability signals at zero deployment cost. The MITM proxy (`proxy-intercept.md`) remains a future complement for the remaining 10% (raw payloads, replay, nanosecond timing). Implementation: Phase 0 in 1 hour (quick win), full pipeline in 1.5 days.

> ／人◕ ‿‿ ◕人＼
