---
decision: 稍后做
---

# Feishu Open API Webhook Interception

**Design doc:** `docs/infra/reviews/feishu-webhook-intercept.md`
**Date:** 2026-05-23
**Scope:** HTTP-intercept layer between Feishu Open Platform webhook delivery and the bot's event processing pipeline, replacing the current WebSocket subscription model.

---

## 1. Motivation

The current Feishu bot infrastructure uses **WebSocket (WS)** to receive events:

- `cc-connect` opens a persistent WSS connection to `wss://msg-frontier.feishu.cn`
- `lark-cli event consume` subscribes via WS for CLI-based testing
- Events arrive as push frames over the WS connection

This WS-only approach has several operational gaps:

| Gap | Impact |
|-----|--------|
| **No persistent event log** | WS frames are in-memory only. When `cc-connect` restarts, unprocessed events are lost. No replay, no audit trail. |
| **Single point of failure** | One WS connection per process. If the process crashes, all event delivery stops until it reconnects. |
| **Reconnection latency** | WS reconnection takes seconds. During that window, Feishu delivers events to nobody. Feishu does not queue events for WS clients. |
| **Process coupling** | Event consumption is tied to the process lifecycle. You cannot inspect events without attaching to the process. |
| **No rate visibility** | WS frames arrive as opaque payloads. No way to measure event arrival rate, burst patterns, or delayed delivery. |
| **No offline testing** | Must talk to real Feishu to receive events. No captured event replay for regression testing. |

The **Feishu Open Platform supports HTTP webhook callbacks** as an alternative to WebSocket. By switching to webhook mode and placing an interception layer in front of the processing pipeline, we gain persistence, observability, and decoupling.

---

## 2. Current Architecture

```
Feishu Open Platform
    │
    │ WSS (wss://msg-frontier.feishu.cn:443)
    │ Persistent connection, auto-reconnect
    │
    ▼
┌──────────────────┐   ┌──────────────────┐
│   cc-connect     │   │   lark-cli       │
│  (Go binary,     │   │  (CLI tool,      │
│   production)    │   │   dev/testing)   │
│                  │   │                  │
│  ┌────────────┐  │   │  ┌────────────┐  │
│  │ WS client  │  │   │  │ WS client  │  │
│  └────────────┘  │   │  └────────────┘  │
│        │         │   │        │         │
│  ┌────────────┐  │   │  ┌────────────┐  │
│  │ msg queue  │  │   │  │ file dump  │  │
│  └────────────┘  │   │  │ ./events/  │  │
│        │         │   │  └────────────┘  │
│  ┌────────────┐  │   └──────────────────┘
│  │ Claude API │  │
│  └────────────┘  │
└──────────────────┘
```

Key characteristics:

- **One WS connection per process** — Feishu pushes events; if the connection drops, events are lost.
- **No event persistence** — `cc-connect` processes events in memory. `lark-cli` can optionally dump raw events to `--output-dir`, but this is a file dump, not a queryable store.
- **No HTTP endpoint** — the bot has no inbound HTTP server for receiving callbacks.

---

## 3. Target Architecture: Webhook Interception

### 3.1 High-Level Flow

```
Feishu Open Platform
    │
    │ HTTP POST (webhook callback)
    │ Event types: im.message.receive_v1, ...
    │ Headers: X-Lark-Request-Timestamp, X-Lark-Nonce, X-Lark-Signature
    │
    ▼
┌─────────────────────────────────────────────────┐
│           Webhook Intercept Server              │
│                                                 │
│  1. Receive POST /feishu/webhook                │
│  2. Validate signature                          │
│  3. Handle URL challenge (GET / challenge)      │
│  4. Log raw event to ClickHouse                 │
│  5. Acknowledge immediately (200 OK)            │
│  6. Enqueue event to internal queue             │
│  7. Forward to event processor                  │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│  │ ingress  │→│ validate │→│ acknowledge   │ │
│  └──────────┘  └──────────┘  └──────┬────────┘ │
│                                      │          │
│  ┌──────────┐  ┌──────────┐  ┌──────┴────────┐ │
│  │ persist  │←│ enrich   │←│ event queue  │ │
│  └──────────┘  └──────────┘  └───────────────┘ │
│                                      │          │
│  ┌───────────────────────────────────┴────────┐ │
│  │ forward to processor(s)                    │ │
│  └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
┌─────────────────┐   ┌─────────────────┐
│  cc-connect     │   │  ClickHouse     │
│  (event loop)   │   │  (event store)  │
│                 │   │                 │
│  processes msg  │   │  raw events     │
│  via Claude API │   │  for query &    │
│                 │   │  replay         │
└─────────────────┘   └─────────────────┘
```

### 3.2 Why Interception, Not Direct Replacement

An intercept layer (rather than replacing `cc-connect` entirely) provides:

1. **Decoupled logging** — events are logged before any processing happens. Processing bugs cannot lose events.
2. **Fail-open semantics** — if the interceptor crashes, events are still buffered by Feishu's retry mechanism (up to 3 times over 24h).
3. **Gradual migration** — run WS and webhook in parallel during transition; compare event arrival times and content.
4. **Multi-tenant potential** — one interceptor can fan events to multiple downstream processors (cc-connect, alerting, analytics).

---

## 4. Feishu Webhook Protocol

### 4.1 Configuration

On the Feishu Open Platform, under **应用 → 事件与回调 → 回调模式**:

| Setting | Value |
|---------|-------|
| Callback mode | HTTP (not WebSocket) |
| Callback URL | `https://<public-domain>/feishu/webhook` |
| Verification token | Auto-generated by Feishu when HTTP mode is enabled |
| Event types | Subscribe to `im.message.receive_v1` (add more as needed) |

**Prerequisite:** The callback URL must be publicly reachable (public IP or reverse proxy with a domain).

### 4.2 URL Challenge

When configuring or changing the callback URL, Feishu sends a challenge request:

**Feishu → Server:**
```
POST /feishu/webhook
Content-Type: application/json

{
  "challenge": "ajISi123jks83...",
  "token": "v0_xxxxx",
  "type": "url_verification"
}
```

**Server → Feishu (must respond within 1s):**
```json
{
  "challenge": "ajISi123jks83..."
}
```

### 4.3 Event Delivery

**Feishu → Server:**
```
POST /feishu/webhook
Content-Type: application/json
X-Lark-Request-Timestamp: 1688888888
X-Lark-Request-Nonce: "abc123xyz"
X-Lark-Signature: "sha256=..."

{
  "schema": "2.0",
  "header": {
    "event_id": "5e220b6e-8c9c-4f12-9b6b-7e5dce2e1234",
    "event_type": "im.message.receive_v1",
    "create_time": "1688888888000",
    "token": "v0_xxxxx",
    "app_id": "cli_xxxxx"
  },
  "event": {
    "sender": {
      "sender_id": {
        "union_id": "on_xxx",
        "user_id": "ou_xxx",
        "open_id": "ou_xxx"
      },
      "sender_type": "user"
    },
    "message": {
      "chat_id": "oc_xxx",
      "chat_type": "group",
      "content": "{\"text\":\"hello\"}",
      "message_id": "om_xxx",
      "message_type": "text",
      "root_id": "",
      "parent_id": ""
    }
  }
}
```

### 4.4 Signature Verification

Feishu signs every webhook POST. The signature is `SHA256` of:
```
verification_token + request_timestamp + request_nonce + body
```

**Verification steps:**

```
1. Extract headers:
   - X-Lark-Request-Timestamp
   - X-Lark-Request-Nonce
   - X-Lark-Signature (prefix "sha256=")

2. Reconstruct signing string:
   signing_string = verification_token + timestamp + nonce + request_body

3. Compute:
   expected_sig = "sha256=" + hex(SHA256(signing_string))

4. Compare:
   expected_sig == X-Lark-Signature
```

**Implementation notes:**
- Use constant-time comparison to prevent timing attacks.
- Reject requests with timestamp older than 5 minutes (replay protection).
- Cache verification token in memory; reload on process restart.

### 4.5 Retry Policy

| Condition | Retry behavior |
|-----------|----------------|
| Non-200 response | Up to 3 retries with exponential backoff (~1m, ~10m, ~1h) |
| Timeout (>3s) | Treated as failure; same retry as non-200 |
| Network error | Retried up to 24h |
| Successful 200 | No retry |

**Design implication:** The intercept server MUST return 200 as quickly as possible (within 1s) after signature validation, deferring all processing to asynchronous workers. Never block the HTTP response on downstream processing.

---

## 5. Endpoint Design

### 5.1 Single Endpoint, Dual Mode

```
Path:  POST /feishu/webhook
Mode:  webhook (event delivery) / challenge (url verification)

Dispatch logic:
  body.type == "url_verification"  →  challenge handler → return { "challenge": ... }
  header.event_type == "im.message.*"  →  event handler → validate → ack → enqueue
```

### 5.2 Response Contracts

| Scenario | HTTP Status | Body |
|----------|-------------|------|
| Challenge request | 200 | `{ "challenge": "<value>" }` |
| Valid event, accepted | 200 | `{}` (empty, or omitted entirely) |
| Invalid signature | 401 | `{ "error": "invalid signature" }` |
| Invalid token | 403 | `{ "error": "invalid token" }` |
| Rate limited (server-side) | 429 | `{ "error": "too many requests" }` |

### 5.3 Timeout Contract

Feishu expects the HTTP response within **3 seconds**. The intercept server should:

1. Validate signature (<10ms)
2. Log raw event to ClickHouse via async insert (<50ms for ack, not waiting for flush)
3. Enqueue to internal queue (in-memory channel, <1ms)
4. Return 200

Total synchronous path: <100ms. This leaves ample headroom.

---

## 6. Event Queue & Processing

### 6.1 Queue Options

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **In-memory channel** (Go chan / Ruby Queue) | Zero infra, lowest latency | Lost on restart, no backpressure | OK for initial deployment with fast consumers |
| **Redis list/stream** | Persistence, multi-consumer, TTL | Requires Redis; another service to manage | Phase 2 when scaling to multiple consumers |
| **Kafka topic** | Durable, replayable, partitioned | Overkill for current volume (~100 events/day) | Not recommended at this stage |

**Initial choice:** In-memory bounded channel (size 1000) with a fallback file log. If the channel is full, events spill to a JSON lines file for manual replay.

### 6.2 Processing Pipeline

```
webhook POST arrives
       │
       ▼
┌──────────────┐
│  validate    │  ← signature + timestamp + token
└──────┬───────┘
       │ (invalid) → 401/403
       │ (valid)
       ▼
┌──────────────┐
│  acknowledge │  ← return 200 immediately
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  persist     │  ← log raw event (ClickHouse + optional file fallback)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  enqueue     │  ← push to in-memory channel
└──────┬───────┘
       │
       ▼
┌──────────────────┐
│  event processor │  ← goroutine/thread, reads from channel
└──────┬───────────┘
       │
       ▼
┌─────────────────────────────────────┐
│  dispatch by event_type:            │
│                                     │
│  im.message.receive_v1 →            │
│    parse content (text/image/...)   │
│    enrich (lookup user, session)    │
│    forward to cc-connect's loop     │
│    (via internal API or file)       │
│                                     │
│  im.message.message_read_v1 →       │
│    update delivery status           │
│                                     │
│  im.message.message_recalled_v1 →   │
│    log recall, no action needed     │
└─────────────────────────────────────┘
```

### 6.3 cc-connect Integration

`cc-connect` currently polls for events via WS. After webhook interception, events arrive via the HTTP path. Two integration strategies:

**Strategy A: cc-connect reads from a queue file**
- Event processor writes newline-delimited JSON to a shared file or FIFO.
- `cc-connect` reads from this file instead of (or in addition to) WS.
- Minimal code change: replace WS reader with file reader.

**Strategy B: cc-connect exposes a local HTTP endpoint**
- Event processor forwards events to `http://localhost:<port>/event` on the cc-connect container.
- cc-connect runs a tiny HTTP server alongside its WS client during migration.
- Cleaner interface; allows both WS and webhook to coexist.

**Recommendation:** Strategy B for production, Strategy A for quick PoC.

---

## 7. Observability

### 7.1 Metrics

All metrics exposed via a `/metrics` endpoint on the intercept server (Prometheus scrape):

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `feishu_webhook_requests_total` | Counter | `status` (ok/sig_invalid/timeout) | Total POST requests received |
| `feishu_webhook_request_duration_ms` | Histogram | `event_type` | Processing time before 200 |
| `feishu_webhook_events_total` | Counter | `event_type` | Events by type |
| `feishu_webhook_channel_depth` | Gauge | - | Number of events waiting in queue |
| `feishu_webhook_channel_dropped_total` | Counter | - | Events dropped because queue was full |
| `feishu_webhook_retry_count` | Counter | - | Events received as retries (detected by duplicate event_id) |

### 7.2 Logging

Structured JSON logs to stdout (compatible with the existing Vector → ClickHouse pipeline):

```json
{
  "timestamp": "2026-05-23T12:00:00Z",
  "level": "info",
  "event": "feishu_webhook.event_received",
  "event_id": "5e220b6e-8c9c-4f12-9b6b-7e5dce2e1234",
  "event_type": "im.message.receive_v1",
  "chat_type": "group",
  "message_type": "text",
  "processing_ms": 12,
  "retry": false
}
```

### 7.3 ClickHouse Event Store

Table for raw event storage (same schema convention as `cc.message_log` in observability-design.md):

```sql
CREATE TABLE feishu.webhook_events (
    event_id     String,
    event_type   String,
    app_id       String,
    create_time  DateTime64(3),
    received_at  DateTime64(3),
    header       String,   -- JSON
    event_body   String,   -- JSON raw
    signature    String,
    retry_of     Nullable(String)  -- event_id this is a retry of (if deduped)
) ENGINE = MergeTree()
ORDER BY (event_type, create_time);
```

---

## 8. Deployment

### 8.1 Option: Standalone Container

A lightweight HTTP server (Go or Node.js) deployed as a sidecar or standalone container.

| Aspect | Detail |
|--------|--------|
| Language | Go (preferred, matches cc-connect ecosystem) or Node.js (matches lark-cli ecosystem) |
| Dependencies | None beyond stdlib + HTTP router |
| Image size | <20MB (Go static binary) |
| Resource | 0.1 CPU, 64MB RAM |
| Port | 8080 (internal) |
| Public exposure | Via reverse proxy (nginx/Caddy) with TLS termination |

**Public URL requirements:**
- Must be HTTPS (Feishu requires TLS for callback URLs)
- A public-facing reverse proxy (e.g., the existing nginx or a new Caddy instance)
- Domain with valid TLS certificate (Let's Encrypt)

### 8.2 Option: Existing Reverse Proxy

If the infrastructure already has an nginx reverse proxy, the interceptor can be mounted behind it:

```
Internet → nginx (TLS termination) → /feishu/webhook → interceptor:8080
```

This avoids exposing a new port or service. Add to existing nginx config:

```nginx
location /feishu/webhook {
    proxy_pass http://127.0.0.1:8080;
    proxy_read_timeout 5s;
    proxy_connect_timeout 3s;
}
```

### 8.3 Migration Path

```
Phase 1: Parallel run (WS + webhook)
  - Deploy intercept server, subscribe to webhook events
  - Keep cc-connect / lark-cli on WS
  - Compare event arrival times, content, reliability
  - Duration: 7 days

Phase 2: Webhook primary, WS backup
  - Make cc-connect read from interceptor queue
  - WS stays connected as hot standby
  - If interceptor fails, cc-connect falls back to WS
  - Duration: 7 days

Phase 3: Webhook only
  - Disable WS subscription in Feishu console
  - Remove WS client code from cc-connect
  - Clean up WS-related config
```

---

## 9. Failure Modes

| Failure | Effect | Mitigation |
|---------|--------|------------|
| Interceptor crashes | Events not received until restart | Systemd auto-restart; Feishu retries for 24h |
| Network partition | Feishu cannot reach the endpoint | Retry mechanism; alert on `feishu_webhook_requests_total == 0` for >5m |
| Signature mismatch | 401 returned, event lost | Log full request for debugging; alert on `feishu_webhook_requests_total{status="sig_invalid"}` |
| Queue full | Events dropped (spill to file) | Monitor `channel_dropped_total`; increase queue size or consumer speed |
| ClickHouse unavailable | Raw event not persisted | Fallback to file log; retry async insert |
| Downstream processor slow | Queue backs up | Backpressure: reject with 503 after queue > threshold |
| TLS cert expired | Feishu refuses to connect | Auto-renew (Let's Encrypt); monitor cert expiry |
| Verification token rotated | All events rejected with 403 | Automatically reload token from config; alert on 403 spike |

---

## 10. Rejected Alternatives

### 10.1 Direct Webhook to cc-connect (No Interception)

```
Feishu → cc-connect HTTP server → process
```

**Rejected because:** No persistence layer. If cc-connect is busy processing a request and a webhook arrives, the request could time out. No audit trail. Harder to debug.

### 10.2 NJS / Lua Script in nginx

Handle signature verification and event logging directly in nginx via njs (nginx JavaScript) or Lua.

**Rejected because:** Complex to maintain; njs ecosystem is niche; difficult to add metrics, queue management, or async processing. The intercept server is simple enough (a few hundred lines) that a dedicated service is cleaner.

### 10.3 Pure ClickHouse HTTP Endpoint

Point Feishu webhook directly at ClickHouse's HTTP endpoint (`http://clickhouse:8123`).

**Rejected because:** No signature verification, no challenge handling, no enrichment, no queue. Feishu would get ClickHouse's raw response format, which is incompatible with the expected challenge/ack protocol.

---

## 11. Implementation Checklist

- [ ] Stand up HTTP endpoint (`POST /feishu/webhook`)
- [ ] Implement URL challenge handler
- [ ] Implement signature verification (constant-time comparison)
- [ ] Implement replay protection (timestamp window check)
- [ ] Implement event deduplication (by `event_id`)
- [ ] Implement async event logging (stdout + ClickHouse)
- [ ] Implement bounded in-memory event queue
- [ ] Implement event type dispatch
- [ ] Implement cc-connect integration (Strategy B)
- [ ] Add Prometheus metrics endpoint
- [ ] Add structured logging (Vector-compatible JSON)
- [ ] Set up reverse proxy (nginx rule)
- [ ] Switch Feishu app to HTTP callback mode
- [ ] Run parallel (WS + webhook) for 7 days
- [ ] Phase out WS after validation

---

## See Also

- [proxy-intercept.md](proxy-intercept.md) — MITM proxy for Feishu WS frames (different scope: captures WS frames; this doc replaces WS entirely)
- [feishu-delivery.md](feishu-delivery.md) — Delivery monitoring for outgoing messages
- [chat.md](../chat.md) — Feishu bot operational FAQ and troubleshooting
- [observability-design.md](../observability-design.md) — Metrics stack overview
- [Feishu Open API: Event Callback](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-callback) — Official Feishu webhook documentation
