---
decision: 稍后做
---

# Feishu Bot Delivery Monitoring

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/chat.md` (feishu bot operational FAQ),
`docs/infra/multi-cluster-boss-architecture.md` (cluster topology),
`docs/infra/observability-design.md` (metrics stack).

---

## 1. Problem

The current feishu bot infrastructure (`lark-cli` + `cc-connect`) handles message
reception and sending, but there is **no delivery observability**:

| Gap | Impact |
|-----|--------|
| No send acknowledgement tracking | A `send_message` API call succeeds (HTTP 200), but the message may never reach the user (rate-limited, blocked by anti-spam, or silently dropped by feishu server). |
| No read receipt tracking | Cannot distinguish "user saw it but ignored" from "message never arrived". |
| No silent drop detection | Messages that vanish between feishu's server and the user's client go undetected for hours. Users report "I didn't get the notification" and there is no way to retroactively verify. |
| No delivery metrics | Cannot alert on delivery degradation, p95 latency, or regional failures. |
| No correlation with bot events | The `im.message.receive_v1` events arrive via WebSocket but are not correlated with outgoing messages to form a complete send-receive-read lifecycle. |

### 1.1 What "Delivery" Means for a Feishu Bot

```
  Bot Server                    Feishu Open API              Feishu Client
      │                              │                            │
      │  1. Send Message             │                            │
      │ ──────────────────────────►  │                            │
      │                              │  2. Push to user           │
      │                              │ ────────────────────────►  │
      │                              │                            │
      │ ←────────────────── 202 OK   │                            │
      │   (message_id, status=done)  │                            │
      │                              │                            │
      │                              │  3. User receives msg      │
      │  WebSocket Event             │ ◄───────────────────────   │
      │ ◄── im.message.receive_v1    │                            │
      │                              │                            │
      │                              │  4. User reads msg         │
      │  Read Receipt API           │ ◄───────────────────────   │
      │ ◄── GET read_receipt         │                            │
      │                              │                            │
```

Each arrow is a potential failure point:

1. **Send fails** (HTTP 4xx/5xx) — caught by existing error handling.
2. **Send succeeds but message is silently dropped** (HTTP 200, `status=done`, but
   message never reaches the user). This is the hardest to detect — feishu may
   accept the message but then discard it due to:
   - Tenant rate limiting (too many messages/second).
   - User has disabled notifications for the bot.
   - Anti-spam rules triggered.
   - Message was blocked by content audit.
3. **Receive event never arrives** — WebSocket connection drops, event missed,
   or event delivery is delayed beyond SLA.
4. **User receives but never reads** — may or may not be a problem depending on
   use case (urgent alerts should be read within a timeout).

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Bot Server                                     │
│                                                                          │
│  ┌──────────────┐    ┌──────────────────────┐    ┌──────────────────┐   │
│  │ Send Message  │───►│ Delivery Tracker      │───►│ Metrics Export   │   │
│  │ (lark-cli)   │    │ (in-memory + SQLite)  │    │ (Prometheus)    │   │
│  └──────────────┘    └──────────────────────┘    └──────────────────┘   │
│       │                       │                          │               │
│       │  HTTP POST            │                          │               │
│       ▼                       ▼                          ▼               │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │                     Delivery State Machine                        │   │
│  │                                                                    │   │
│  │  PENDING_SEND ──► SENT ──► DELIVERED ──► READ                     │   │
│  │       │               │          │          │                       │   │
│  │       │               ├──► DROPPED (no delivery within TTL)        │   │
│  │       │               ├──► FAILED  (API error)                     │   │
│  │       │               └──► STALE   (delivered but no read within   │   │
│  │       │                         threshold for urgent messages)      │   │
│  │       └──► TIMEOUT (pre-send validation fails)                     │   │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │                     Delivery Alerter                               │   │
│  │  ┌────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │   │
│  │  │ Drop Alert │  │ Stale Alert  │  │ Degradation Alert        │  │   │
│  │  │ (Pager)    │  │ (Ticket)     │  │ (Dashboard warning)      │  │   │
│  │  └────────────┘  └──────────────┘  └──────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘

                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Observability Storage                                 │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│  │ Delivery Events   │  │ Delivery Metrics  │  │ Delivery Logs    │      │
│  │ (ClickHouse)     │  │ (Prometheus)     │  │ (stdout JSON)    │      │
│  │ infra.delivery_  │  │ feishu_sent_total │  │ structured       │      │
│  │ events           │  │ feishu_delivered  │  │ per-message      │      │
│  │                  │  │ feishu_read_total │  │                  │      │
│  │                  │  │ feishu_dropped_   │  │                  │      │
│  │                  │  │ total             │  │                  │      │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Delivery State Machine

### 3.1 States

```
                    ┌──────────┐
                    │ QUEUED   │  Message submitted to lark-cli for sending
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ SENDING  │  HTTP request in-flight
                    └────┬─────┘
                         │
                 ┌───────┼───────────┐
                 │       │           │
            ┌────▼──┐ ┌──▼───┐ ┌────▼───┐
            │ SENT  │ │FAILED│ │TIMEOUT │
            └────┬──┘ └──────┘ └────────┘
                 │
          ┌──────┼──────────┐
          │      │          │
     ┌────▼─┐ ┌──▼───┐ ┌───▼────┐
     │DELVRD│ │DROPPED│ │STALE   │  (no receive event within TTL)
     └────┬─┘ └──────┘ └────────┘
          │
     ┌────▼─┐
     │ READ │
     └──────┘
```

### 3.2 State Transitions

| From | To | Trigger | Data Captured |
|------|----|---------|---------------|
| `QUEUED` | `SENDING` | lark-cli invoke started | `queued_at` timestamp, `chat_id`, `message_type` |
| `SENDING` | `SENT` | HTTP 200 with `message_id` | `message_id`, `sent_at`, `feishu_status_code` |
| `SENDING` | `FAILED` | HTTP error (4xx/5xx) or network error | `error_code`, `error_message`, `http_status` |
| `SENDING` | `TIMEOUT` | HTTP request exceeds timeout (15s default) | `timeout_ms` |
| `SENT` | `DELIVERED` | WebSocket `im.message.receive_v1` received | `delivered_at`, `receive_event_id` |
| `SENT` | `DROPPED` | No receive event within TTL (see 3.3) | `dropped_at`, `ttl_seconds` |
| `SENT` | `STALE` | Delivered but no read receipt within urgent threshold | `stale_at`, `stale_threshold_seconds` |
| `DELIVERED` | `READ` | Read receipt API confirms read | `read_at`, `read_count` |

### 3.3 TTL Configuration

| Message Category | Delivery TTL | Read TTL | Action on Timeout |
|-----------------|--------------|----------|-------------------|
| Alert (urgent) | 30s | 5min | Alert on-call |
| Notification (normal) | 2min | 1h | Log + increment counter |
| System broadcast | 5min | N/A | Increment drop counter |
| Debug/info | 30s | N/A | No action |

TTLs are configurable per message category via message metadata.

---

## 4. Components

### 4.1 Delivery Tracker

A lightweight state machine running in-process alongside the bot server.

**Interface:**

```go
// Tracker manages delivery state for outbound messages.
type Tracker struct {
    store   StateStore        // persistence layer
    metrics MetricsRecorder   // prometheus counters/histograms
    alerter AlertDispatcher   // alert routing
}

// Track begins tracking a message sent via lark-cli.
func (t *Tracker) Track(ctx context.Context, msg *OutboundMessage) (*Delivery, error)

// ConfirmDelivery is called when im.message.receive_v1 arrives.
func (t *Tracker) ConfirmDelivery(ctx context.Context, messageID string) error

// ConfirmRead is called when read receipt is confirmed.
func (t *Tracker) ConfirmRead(ctx context.Context, messageID string, readBy []string) error

// ReportFailed is called when the send API returns an error.
func (t *Tracker) ReportFailed(ctx context.Context, messageID string, err error) error

// Sweep runs periodically to detect silent drops and stale messages.
func (t *Tracker) Sweep(ctx context.Context) ([]*Delivery, error)
```

**Delivery object:**

```go
type Delivery struct {
    MessageID    string            `json:"message_id"`
    ChatID       string            `json:"chat_id"`
    State        DeliveryState     `json:"state"`
    Category     MessageCategory   `json:"category"`
    SentAt       *time.Time        `json:"sent_at,omitempty"`
    DeliveredAt  *time.Time        `json:"delivered_at,omitempty"`
    ReadAt       *time.Time        `json:"read_at,omitempty"`
    ErrorCode    string            `json:"error_code,omitempty"`
    ErrorMsg     string            `json:"error_msg,omitempty"`
    Metadata     map[string]string `json:"metadata,omitempty"`   // free-form for routing context
}
```

### 4.2 State Store

Two-tier storage:

**Hot storage (in-memory, bounded):**
- LRU cache of recent deliveries (last 10,000 messages).
- Used for fast state transitions (receive events arrive within seconds of send).
- TTL-based expiry: entries older than 5 minutes are evicted to cold storage.

**Cold storage (SQLite or ClickHouse via buffered insert):**

SQLite (local, for single-instance bots):
```sql
CREATE TABLE delivery_tracking (
  message_id    TEXT PRIMARY KEY,
  chat_id       TEXT NOT NULL,
  state         TEXT NOT NULL DEFAULT 'queued',
  category      TEXT NOT NULL DEFAULT 'normal',
  queued_at     INTEGER NOT NULL,              -- unix ms
  sent_at       INTEGER,
  delivered_at  INTEGER,
  read_at       INTEGER,
  error_code    TEXT,
  error_message TEXT,
  metadata_json TEXT,
  created_at    INTEGER NOT NULL DEFAULT (unixepoch('subsec') * 1000),
  updated_at    INTEGER NOT NULL DEFAULT (unixepoch('subsec') * 1000)
);

CREATE INDEX idx_delivery_state ON delivery_tracking(state);
CREATE INDEX idx_delivery_updated ON delivery_tracking(updated_at);
CREATE INDEX idx_delivery_chat ON delivery_tracking(chat_id);
```

ClickHouse (for multi-instance / long-term analytics):
```sql
CREATE TABLE infra.delivery_events (
  timestamp     DateTime64(3),
  message_id    String,
  chat_id       String,
  state         LowCardinality(String),
  category      LowCardinality(String),
  queued_at     DateTime64(3),
  sent_at       DateTime64(3),
  delivered_at  DateTime64(3),
  read_at       DateTime64(3),
  fail_code     String,
  fail_message  String,
  metadata      String                -- JSON
) ENGINE = MergeTree()
ORDER BY (timestamp, state);

CREATE MATERIALIZED VIEW infra.delivery_metrics_mv
  (toStartOfMinute(timestamp) AS minute, state, count() AS count)
  ENGINE = AggregatingMergeTree()
  ORDER BY (minute, state)
AS SELECT ...;
```

### 4.3 Event Correlator

Maps incoming `im.message.receive_v1` WebSocket events to tracked outbound messages.

**Correlation key:** `message_id`.

The `send_message` API response includes `message_id` (format: `om_xxxxxxxxxx`).
The `im.message.receive_v1` event also includes `message_id`.

**Problem:** Bot-received messages (from user to bot) arrive as `im.message.receive_v1`
but may not have a matching outbound `message_id`. Solution: maintain a **reverse map**
of `(sender_id, bot_reply_message_id)` so that when a user's message triggers a bot
reply, the reply's delivery can be correlated back to the trigger message.

```
User: "deploy staging" (receive_v1 event, message_id: om_A)
  Bot sends: "Deploying..." (send API, message_id: om_B)
  Correlation: om_B -> triggered_by -> om_A
```

This enables end-to-end tracking: user request -> bot processing -> bot response deliver -> user reads.

### 4.4 Silent Drop Detector

Runs as a periodic sweep (every 10 seconds by default):

1. Query `delivery_tracking` for all messages in `SENT` state where
   `updated_at < NOW() - TTL(category)`.
2. For each candidate, call the **message get API** to check actual feishu-side status:
   `GET /open-apis/im/v1/messages/{message_id}`.
   - If the message exists with `status=done` but no receive events → `DROPPED`.
   - If the message status is `failed` or `timeout` → `FAILED`.
   - If the API returns 404 (message doesn't exist) → `DROPPED` (never accepted
     by feishu despite HTTP 200 — rare but known edge case).
3. Transition state and fire appropriate alert.

**Feishu message status values** (from `GET /im/v1/messages/{id}`):

| `status` | Meaning | Our Action |
|----------|---------|------------|
| `done` | Sent to user's device | Await receive event |
| `sent` | Accepted by feishu server | Await final status |
| `failed` | Send failed | Transition to FAILED |
| `timeout` | Delivery timed out | Transition to DROPPED |
| `recalled` | Message recalled | Log (informational) |

### 4.5 Read Receipt Poller

Feishu provides read receipt data via:
`GET /open-apis/im/v1/messages/{message_id}/read_receipt`

**Strategy:**

| Message Type | Polling | Action |
|-------------|---------|--------|
| Group chat urgent | Poll 3x at 30s intervals after delivery | Alert if no read within 5min |
| Group chat normal | Poll once at 1h after delivery | Log read count |
| P2P bot message | No polling possible (P2P read receipts not supported) | Mark as delivered only |
| Urgent app notification | Poll 5x at 10s intervals | Alert immediately if no read |

**Response shape:**

```json
{
  "code": 0,
  "data": {
    "read_count": "3",
    "total_count": "10",
    "read_details": [
      {"reader_id": "ou_xxx", "read_time": "1745376000"},
      {"reader_id": "ou_yyy", "read_time": "1745376005"}
    ]
  }
}
```

Metrics emitted per poll:
- `feishu_read_ratio` = read_count / total_count (gauge)
- `feishu_read_latency_ms` = time from delivered_at to first read (histogram)

### 4.6 Alerter

**Alert rules:**

| Rule | Condition | Severity | Channel | Cooldown |
|------|-----------|----------|---------|----------|
| SilentDrop | Any message enters DROPPED state | P1 | PagerDuty + Feishu | 5min |
| SendFailure | Any message enters FAILED state | P1 | PagerDuty + Feishu | 2min |
| DeliveryDegradation | Delivery rate < 99% over 5min window | P2 | Feishu alert group | 10min |
| ReadStaleUrgent | Urgent message unread after 5min | P2 | Feishu alert group | 15min |
| ReadRateDrop | Read ratio < 50% over 1h window | P3 | Dashboard warning | 1h |
| SweepStall | Sweeper hasn't run in >60s | P2 | PagerDuty | 10min |

**Alert payload:**

```json
{
  "title": "[P1] Silent Drop Detected — feishu bot",
  "message": "Message om_xxx sent to chat oc_yyy (Deploy Alerts) at 14:30:00, no delivery confirmed within 30s TTL.",
  "fields": {
    "message_id": "om_xxx",
    "chat_id": "oc_yyy",
    "category": "urgent",
    "sent_ago": "35s",
    "feishu_status": "done (API says sent but no receive event)"
  },
  "action": "Check lark-cli events log. Restart WebSocket consumer if disconnected. Verify feishu Open API health."
}
```

---

## 5. Metrics

### 5.1 Prometheus Metrics

```go
// Counters
feishu_messages_sent_total{chat_type, category, status}   // status=ok|fail|timeout
feishu_messages_delivered_total{chat_type, category}
feishu_messages_read_total{chat_type, category}
feishu_messages_dropped_total{chat_type, category}
feishu_messages_failed_total{chat_type, category, error_code}

// Histograms
feishu_send_latency_ms{chat_type, category}               // time from queue to sent
feishu_delivery_latency_ms{chat_type, category}           // time from sent to delivered
feishu_read_latency_ms{chat_type, category}               // time from delivered to read
feishu_sweep_duration_ms                                  // sweeper run time

// Gauges
feishu_pending_deliveries{state}                           // current in-flight count
feishu_sweep_lag_seconds                                   // time since last successful sweep
feishu_read_ratio{chat_id}                                 // read_count / total_count per chat
```

### 5.2 Dashboards

**Delivery Overview panel:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Feishu Bot Delivery Status — Last 1h           ┌──────────────────────┐ │
│ ┌─────────────────────────────────────────────┐│ Total Sent:   1,234  │ │
│ │ Sent / Delivered / Read — stacked area      ││ Delivered:    1,198  │ │
│ │                                              ││ Read:           876  │ │
│ │  █████████████████████████████████████████   ││ Dropped:          12 │ │
│ │  ████████████████████████████████████        ││ Failed:            4 │ │
│ │  █████████████████████████                   ││                      │ │
│ │                                              ││ Delivery Rate: 97.1% │ │
│ │  ── sent  ── delivered  ── read             ││ Read Rate:     73.1% │ │
│ └─────────────────────────────────────────────┘└──────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘

┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
│ Drop Reasons (pie)   │ │ Delivery Latency (p50 │ │ Top Failure Chats    │
│ ┌──────────────────┐ │ │ / p95 / p99)         │ │ ┌──────────────────┐ │
│ │ Anti-spam   45%  │ │ │ ┌──────────────────┐ │ │ │ oc_deploy   12   │ │
│ │ Rate limit  30%  │ │ │ │ p99: 1.2s       │ │ │ │ oc_monitor  5    │ │
│ │ User block  15%  │ │ │ │ p95: 400ms      │ │ │ │ oc_broadcast 2   │ │
│ │ Unknown     10%  │ │ │ │ p50: 120ms      │ │ │ └──────────────────┘ │
│ └──────────────────┘ │ │ └──────────────────┘ │ └──────────────────────┘
└──────────────────────┘ └──────────────────────┘
```

---

## 6. Integration Points

### 6.1 lark-cli Hook

Wrap `lark-cli im +messages-send` calls:

```
Before:
  lark-cli im +messages-send --chat-id oc_xxx --as bot --text "hello"

After:
  delivery-tracker send --chat-id oc_xxx --category urgent -- \
    lark-cli im +messages-send --chat-id oc_xxx --as bot --text "hello"
```

The wrapper captures stdout to extract `message_id`, records the `QUEUED` → `SENT`
transition, and returns the `message_id` for later correlation.

**Implementation options:**

| Option | Pros | Cons |
|--------|------|------|
| **Wrapper script** (`delivery-tracker send -- ...`) | Minimal changes to existing code, no SDK dependency | Relies on parsing CLI output |
| **Go library integration** | Type-safe, structured error handling | Requires modifying bot server code |
| **Middleware interceptor** (HTTP middleware for feishu API calls) | Zero code changes, intercepts at HTTP level | Harder to extract message_id from response |

**Recommendation:** Start with the wrapper script (lowest friction), migrate to
library integration as the bot codebase matures.

### 6.2 WebSocket Event Binding

The `cc-connect` WebSocket consumer (or `lark-cli event consume`) needs to:

1. Receive `im.message.receive_v1` events.
2. Extract `message_id` from event payload.
3. Call `delivery-tracker confirm-delivery <message_id>`.
4. For messages sent BY the bot (bot is the sender), log the delivery confirmation.

**Correlation edge case — broadcast messages:**

When the bot sends to a group chat, multiple receive events may arrive (one per
group member). Only the first receive event triggers `QUEUED` → `DELIVERED`;
subsequent events increment a `delivery_count` counter but do not change state.

### 6.3 Read Receipt Cron

A lightweight cron job (every minute):

1. Query `delivery_tracking WHERE state = 'delivered' AND delivered_at < NOW() - interval`.
2. For each candidate, call `GET /im/v1/messages/{message_id}/read_receipt`.
3. If `read_count > 0`, transition state to `READ`.
4. If the message is `urgent` and `read_count == 0` beyond threshold, fire alert.

**Rate limiting:** Feishu read receipt API has a rate limit of 5 QPS per app.
Batch reads with a 200ms delay between calls.

---

## 7. Alert Escalation

```
                    ┌──────────────────────────┐
                    │ Delivery Event Detected   │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │ Classify Severity         │
                    │ P1: Drop / Send Failure   │
                    │ P2: Degradation / Stale   │
                    │ P3: Read Rate Drop        │
                    └────────────┬─────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
         ┌────▼────┐      ┌─────▼─────┐     ┌─────▼─────┐
         │ P1      │      │ P2        │     │ P3        │
         │         │      │           │     │           │
         │ Pager   │      │ Feishu    │     │ Dashboard │
         │ Dusty   │      │ Alert     │     │ Widget    │
         │ + Feishu│      │ Group     │     │           │
         └────┬────┘      └─────┬─────┘     └───────────┘
              │                 │
              ▼                 ▼
    Auto-remediate       Human investigates
    (restart WS conn,    within 15min (P2) /
    re-send message)     1h (P3)
```

### 7.1 Auto-Remediation (P1 only)

When a **SilentDrop** alert fires, the system should automatically:

1. **Check WebSocket health:** `GET /health` of `cc-connect` / `lark-cli event consumer`.
   - If unhealthy → restart the consumer process.
   - Record in `delivery_tracking.metadata_json`:
     `{"auto_action": "restarted_ws_consumer", "result": "success/failure"}`.
2. **Re-send critical messages:** If the dropped message is `urgent`, re-send once.
   - New send gets a new `message_id`.
   - Original message is marked `DROPPED(re-sent=<new_message_id>)`.
3. **If auto-remediation fails → escalate to human.**

---

## 8. Implementation Plan

### Phase 1: Foundational Tracking (Week 1)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 1.1 | Add `delivery_tracking` table (SQLite) to bot server | — |
| 1.2 | Implement `Tracker.Track()` and `Tracker.ConfirmDelivery()` | 1.1 |
| 1.3 | Wrap `lark-cli send` calls with delivery tracking | 1.2 |
| 1.4 | Wire `im.message.receive_v1` handler to `ConfirmDelivery()` | 1.2 |

**Verification:** Send a test message, verify state transitions QUEUED → SENT → DELIVERED
in the tracking table.

### Phase 2: Silent Drop Detection (Week 1)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 2.1 | Implement `Tracker.Sweep()` | 1.2 |
| 2.2 | Add TTL config per message category | 2.1 |
| 2.3 | Implement `GET /im/v1/messages/{id}` status check in sweeper | 2.1 |
| 2.4 | Emit metrics for Prometheus | 2.1 |
| 2.5 | Add Grafana dashboard panel: Delivery status | 2.4 |

**Verification:** Simulate a dropped message (send to a deactivated user), confirm
sweeper detects it within 30s, metric `feishu_messages_dropped_total` increments.

### Phase 3: Read Receipt Tracking (Week 2)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 3.1 | Implement `Tracker.ConfirmRead()` | 1.2 |
| 3.2 | Implement read receipt poller cron | 2.1 |
| 3.3 | Track read ratio per chat | 3.2 |
| 3.4 | Emit `feishu_read_ratio` gauge + `feishu_read_latency_ms` histogram | 3.3 |

**Verification:** Send message to a group with 10 members, verify read receipt
captures 10/10 delivered, and read_count increments as members open the message.

### Phase 4: Alerting & Auto-Remediation (Week 2-3)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 4.1 | Implement `Alerter` with P1/P2/P3 routing | 2.1, 3.2 |
| 4.2 | Wire alerts to PagerDuty + feishu alert group | 4.1 |
| 4.3 | Implement WebSocket health check + auto-restart | 2.1 |
| 4.4 | Implement critical message re-send on drop | 4.3 |

**Verification:** Kill the WebSocket consumer, send an urgent message, confirm
alert fires, auto-remediation restarts consumer within 30s.

### Phase 5: ClickHouse Migration & Dashboards (Week 3)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 5.1 | Create `infra.delivery_events` table in ClickHouse | 1.1 |
| 5.2 | Buffered insert from SQLite → ClickHouse | 5.1 |
| 5.3 | Grafana dashboard: delivery overview, drop analysis, latency panels | 5.2 |
| 5.4 | Alert rules in Grafana/Mimir | 4.1, 5.3 |

---

## 9. Operational Considerations

### 9.1 Feishu API Rate Limits

| API | Limit | Mitigation |
|-----|-------|------------|
| `send_message` | 5 QPS per app | Queue + batch, use tenant-level rate limiting |
| `read_receipt` | 5 QPS per app | 200ms delay between polls, batch processing in cron |
| `get_message` | 50 QPS per app | Sweeper limits to 20 messages per sweep cycle |
| Event delivery | Up to 100 events/second | Process events asynchronously, buffer to internal queue |

### 9.2 WebSocket Reliability

The WebSocket connection (`wss://msg-frontier.feishu.cn`) is the critical path for
delivery confirmation. Failure modes and mitigations:

| Failure | Detection | Mitigation |
|---------|-----------|------------|
| Connection drop | `connected` log message stops | Auto-reconnect with exponential backoff (1s, 2s, 4s, max 30s) |
| Event gap (missed events) | No receive events for SENT messages beyond TTL | Sweeper detects → fall back to `GET /im/v1/messages/{id}` status |
| Reconnect storm (rapid connect/disconnect) | 5+ reconnects in 60s | Enter degraded mode: poll `GET /im/v1/messages/{id}` for all SENT messages |
| Stale connection (connected but no events) | No events for 300s while messages are being sent | Force reconnect, alert |

### 9.3 Storage Cost

| Storage | Growth Rate | Retention | Total at Retention |
|---------|-------------|-----------|-------------------|
| SQLite (hot) | ~200 bytes per delivery | 24h (evicted to ClickHouse) | ~17 MB @ 50k messages/day |
| ClickHouse (cold) | ~200 bytes per delivery | 90 days | ~900 MB @ 50k messages/day |
| ClickHouse (aggregated metrics MV) | ~50 bytes per minute | 90 days | ~6.5 MB |
| Prometheus metrics | ~10 samples per metric per minute | 30 days | Negligible |

### 9.4 Failure Mode: Delivery Tracker Down

If the delivery tracker process crashes:

1. **In-flight deliveries** are lost (state in memory). Recovery from SQLite on restart.
2. **Messages sent during downtime** have no tracking. Mitigation: query recent messages
   from feishu API on startup (`GET /im/v1/messages?page_size=50&sort_by=create_time`).
3. **Alerts may fire incorrectly** if sweep runs after restart with stale data.
   Mitigation: skip sweep for 60s after startup to allow events to drain.

---

## 10. Summary

| Aspect | Design Decision |
|--------|----------------|
| State machine | 7 states (QUEUED → SENDING → SENT → DELIVERED → READ, with FAILED/TIMEOUT/DROPPED/STALE as terminal error states) |
| Correlation key | `message_id` (from send API response and receive event) |
| Drop detection | Periodic sweeper (10s interval) + feishu message status API |
| Read tracking | Poll-based (`GET /im/v1/messages/{id}/read_receipt`) |
| Hot storage | In-memory LRU + SQLite (single instance) |
| Cold storage | ClickHouse `infra.delivery_events` (multi-instance, long-term) |
| Alert severity | P1=Drop/Failure (PagerDuty), P2=Degradation/Stale (feishu group), P3=Read rate (dashboard) |
| Auto-remediation | WebSocket restart + critical message re-send (P1 only) |
| Integration | Wrapper script around `lark-cli send` (Phase 1), migrate to library (Phase 2+) |

This system closes the observability gap between "message sent" (HTTP 200) and
"message received by user". Without it, silent drops are invisible until a user
reports they didn't get a notification — which may be hours later, or never.

---

/人◕ ‿‿ ◕人＼
