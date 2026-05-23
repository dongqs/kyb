---
decision: 稍后做
---

# Feishu @Mention Response Time Tracking

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/chat.md` (feishu bot operational FAQ),
`docs/infra/reviews/feishu-delivery.md` (delivery monitoring),
`docs/infra/multi-cluster-boss-architecture.md` (agent topology).

---

## 1. Problem

The current feishu bot infrastructure routes @mentions to agents (`@kyb` to kyb-boss,
`@kyb-infra` to infra-boss) via cc-connect, but there is **no response observability**:

| Gap | Impact |
|-----|--------|
| No mention-to-response latency tracking | Cannot measure SLA adherence for agent response times. Users say "the agent didn't reply" but there is no data to confirm or deny. |
| No per-agent response rate | Cannot identify which agents are ignoring mentions or failing silently. |
| No unanswered mention tracking | Mentions that fall through the cracks (agent crashed, routing failed, message dropped) are invisible until a human re-@mentions. |
| No mention volume trending | Cannot distinguish normal usage from an alert storm or spam. |
| No cross-agent response time comparison | Cannot benchmark agents against each other to identify performance regressions. |

### 1.1 What "Response" Means

A **mention** is an inbound `im.message.receive_v1` event whose `content` field
contains an @-reference to one of our bots (e.g., `@kyb`, `@kyb-infra`).

A **response** is the next outbound message sent by the bot to the **same chat**
within a defined SLA window. The response is correlated to the mention via the
chat thread -- each `@kyb` in group chat `oc_xxx` should produce at least one
outbound message to `oc_xxx`.

```
  User                       Bot Server                    cc-connect/Agent
   │                            │                               │
   │  @kyb-infra deploy now      │                               │
   │ ──────────────────────────► │                               │
   │   im.message.receive_v1     │                               │
   │                            │  Route to infra-boss           │
   │                            │ ──────────────────────────────►│
   │                            │                               │
   │                            │  Agent processes...           │
   │                            │             ...thinking...    │
   │                            │                               │
   │                            │ ◄─────────────────────── OK   │
   │                            │  Send message via API          │
   │ ◄──────────────────────────│                               │
   │  "Deploying to production" │                               │
   │                            │                               │
   │←──── MENTION ────│←── RESPONSE ──│                         │
   │←── RESPONSE_LATENCY ──→│                                    │
```

Each phase can fail:

1. **Mention never reaches bot** -- WebSocket down, event subscription missing,
   routing misconfigured. No `im.message.receive_v1` event is generated.
2. **Bot receives but doesn't route** -- cc-connect receives the event but fails
   to dispatch to an agent (agent pool exhausted, routing rule missing).
3. **Agent receives but fails to respond** -- agent crashes, hangs, or produces
   an error that doesn't result in an outbound message.
4. **Response sent but never delivered** -- API call succeeds but message is
   silently dropped (covered by delivery monitoring).

### 1.2 Data We Already Have

**Inbound events** (from `lark-cli event consume im.message.receive_v1`):

```json
{
  "type": "im.message.receive_v1",
  "event_id": "4796626f5b920bdec5815739fd7e12e3",
  "timestamp": "1779524982819",
  "message_id": "om_x100b6e2219ab94a4c346734aa8d3d2a",
  "create_time": "1779524982483",
  "chat_id": "oc_9b1a09bbdd80887acd63cc02626618c6",
  "chat_type": "group",
  "message_type": "text",
  "sender_id": "ou_75b1fec6d3c2ae67ca1a65fea92a79f0",
  "content": "@kyb-infra deploy now"
}
```

**Outbound messages** (from `feishu-delivery.md` tracking, once deployed):

```json
{
  "message_id": "om_x100b6e23...",
  "chat_id": "oc_9b1a09bbdd80887acd63cc02626618c6",
  "state": "sent",
  "sent_at": "1779524985000",
  "category": "response"
}
```

The correlation challenge: mentions and responses live in **separate data streams**
(inbound events vs. outbound tracking). They share `chat_id` as the correlation key,
but there is no explicit mention-to-response link.

---

## 2. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Mention Response Tracker                           │
│                                                                           │
│  ┌──────────────────┐    ┌─────────────────────┐    ┌─────────────────┐  │
│  │ Inbound Parser    │───►│ Mention Correlator   │───►│ Metrics Export  │  │
│  │ (extract @ from   │    │ (match mentions to   │    │ (Prometheus /   │  │
│  │  receive_v1)      │    │  outbound messages)  │    │  ClickHouse)    │  │
│  └──────────────────┘    └─────────────────────┘    └─────────────────┘  │
│         │                         │                         │              │
│         ▼                         ▼                         ▼              │
│  ┌──────────────────┐    ┌─────────────────────┐    ┌─────────────────┐  │
│  │ Mention Store     │    │ Response Window     │    │ Alert Router    │  │
│  │ (pending mentions │    │ (SLA timer per      │    │ (P1/P2/P3 per   │  │
│  │  awaiting response)│   │  mention category)  │    │  agent/chat)    │  │
│  └──────────────────┘    └─────────────────────┘    └─────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘

         │                              │
         ▼                              ▼
┌──────────────────────┐    ┌──────────────────────────┐
│  Inbound Events      │    │  Outbound Delivery       │
│  (lark-cli events)   │    │  (delivery tracking)     │
│  im.message.receive  │    │  send_message responses  │
│  stored as JSON files│    │  stored in ClickHouse    │
└──────────────────────┘    └──────────────────────────┘
```

### 2.1 Data Flow

```
 Step 1: Mention ingested
   im.message.receive_v1 event for @mention
   → Parser extracts: chat_id, sender, mentioned_agent, timestamp
   → Insert into `mention_events` (ClickHouse) with state=PENDING
   → Start SLA timer (configurable per agent)

 Step 2: Response detected
   Outbound message to same chat_id arrives in delivery tracking
   → Correlator matches the most recent PENDING mention in that chat
   → Calculate: response_latency_ms = response_time - mention_time
   → Update mention state to RESPONDED with latency
   → Emit metric: mention_response_latency{agent, chat}

 Step 3: Timeout / no response
   SLA timer fires, mention still PENDING
   → Transition mention to UNANSWERED
   → Emit metric: mention_unanswered{agent, chat}
   → Fire alert if configured (per-agent threshold)

 Step 4: Periodic sweep
   Every 5 minutes, sweep all PENDING mentions older than max SLA
   → Catch mentions missed by timer (tracker restart, etc.)
   → Same as Step 3 for all stragglers
```

---

## 3. Data Model

### 3.1 Mention Events Table (ClickHouse)

```sql
CREATE TABLE infra.mention_events (
  timestamp           DateTime64(3)           -- mention time (from receive_v1 event)
    DEFAULT now64(3),

  -- Identity
  mention_id          String,                 -- unique: chat_id + message_id
  event_id            String,                 -- lark event_id for dedup
  message_id          String,                 -- feishu message_id
  chat_id             String,                 -- oc_xxx
  chat_type           LowCardinality(String), -- group / p2p
  sender_id           String,                 -- ou_xxx (who @mentioned)
  sender_name         String,                 -- display name (enriched)

  -- Mention analysis
  raw_content         String,                 -- full message text
  mentioned_agent     LowCardinality(String), -- extracted @target: kyb, kyb-infra, etc.
  mention_count       UInt8,                  -- number of @mentions in this message
  has_pure_mention    UInt8,                  -- 1 if message is ONLY @mention (no other text)

  -- Response tracking
  state               LowCardinality(String)  -- PENDING / RESPONDED / UNANSWERED / STALE
    DEFAULT 'PENDING',

  responded_at        DateTime64(3),          -- when response was sent
  response_message_id String,                 -- outbound message_id of response
  response_latency_ms UInt32,                 -- ms from mention to response

  -- Routing info
  routed_to           LowCardinality(String), -- agent name: kyb-boss, infra-boss
  routing_error       String,                 -- error if routing failed

  -- Metadata
  metadata            Map(String, String),    -- extensible

  -- Audit
  updated_at          DateTime64(3)
    DEFAULT now64(3)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (toDate(timestamp), mentioned_agent, state)
TTL toDate(timestamp) + INTERVAL 90 DAY;

-- For unanswered alerts
CREATE INDEX idx_mention_unanswered
ON infra.mention_events (state, timestamp)
TYPE minmax
GRANULARITY 1;
```

### 3.2 Materialized Views

**Response rate aggregation (hourly):**

```sql
CREATE MATERIALIZED VIEW infra.mention_response_rates_hourly
ENGINE = AggregatingMergeTree()
ORDER BY (hour, mentioned_agent)
POPULATE AS
SELECT
  toStartOfHour(timestamp) AS hour,
  mentioned_agent,
  countIf(state = 'RESPONDED') AS responded_count,
  countIf(state = 'UNANSWERED') AS unanswered_count,
  countIf(state = 'PENDING') AS pending_count,
  count() AS total_mentions,
  avgIf(response_latency_ms, state = 'RESPONDED') AS avg_response_latency_ms,
  quantileMerge(0.50)(quantileState(0.50)(response_latency_ms))
    FILTER (WHERE state = 'RESPONDED') AS p50_response_latency_ms,
  quantileMerge(0.95)(quantileState(0.95)(response_latency_ms))
    FILTER (WHERE state = 'RESPONDED') AS p95_response_latency_ms
FROM infra.mention_events
GROUP BY hour, mentioned_agent;
```

**Per-agent response time distribution (daily):**

```sql
CREATE MATERIALIZED VIEW infra.mention_agent_response_daily
ENGINE = AggregatingMergeTree()
ORDER BY (day, mentioned_agent)
POPULATE AS
SELECT
  toDate(timestamp) AS day,
  mentioned_agent,
  count() AS total_mentions,
  countIf(state = 'RESPONDED') AS responded,
  countIf(state = 'UNANSWERED') AS unanswered,
  minIf(response_latency_ms, state = 'RESPONDED') AS min_latency_ms,
  maxIf(response_latency_ms, state = 'RESPONDED') AS max_latency_ms,
  avgIf(response_latency_ms, state = 'RESPONDED') AS avg_latency_ms
FROM infra.mention_events
GROUP BY day, mentioned_agent;
```

### 3.3 In-Memory State (for real-time correlation)

The correlator maintains a bounded LRU cache of PENDING mentions:

```go
type PendingMention struct {
    MentionID      string    // chat_id + message_id
    ChatID         string
    MentionedAgent string
    MentionedAt    time.Time
    SenderID       string
    RawContent     string
    SLADeadline    time.Time
}

type Correlator struct {
    pending     *lru.Cache[string, *PendingMention]  // keyed by chat_id
    slaConfig   map[string]time.Duration              // per-agent SLA
    store       MentionStore                          // ClickHouse persistence
}

// OnInboundEvent is called when a receive_v1 event is parsed.
func (c *Correlator) OnInboundEvent(ctx context.Context, event *InboundEvent) error

// OnOutboundMessage is called when a message send is confirmed.
// It checks if this is a response to a pending mention in the same chat.
func (c *Correlator) OnOutboundMessage(ctx context.Context, msg *OutboundMessage) error

// Sweep is called periodically to flush stale PENDING mentions.
func (c *Correlator) Sweep(ctx context.Context) ([]*MentionEvent, error)
```

**Correlation logic in `OnOutboundMessage`:**

```
1. Look up PENDING mention for chat_id in LRU cache
2. If found:
   a. Calculate latency = now - mention.timestamp
   b. Update mention state to RESPONDED with response_message_id
   c. Remove from LRU cache
   d. Emit metric
3. If not found in cache:
   a. Query ClickHouse for most recent PENDING mention in this chat
   b. If found and within 2x max SLA, treat as response (edge: out-of-order processing)
   c. If not found, this is a proactive message (not a response to a mention)
```

---

## 4. Metrics

### 4.1 Prometheus Metrics

```go
// Counters
mention_total{agent, chat, chat_type}            // Total mentions received
mention_responded_total{agent, chat}              // Mentions that got a response
mention_unanswered_total{agent, chat}              // Mentions that timed out

// Histograms
mention_response_latency_ms{agent, chat_type}     // Time from mention to first response
mention_pending_duration_ms{agent}                // How long unanswered mentions stay open

// Gauges
mention_pending_current{agent}                    // Currently pending mentions
mention_response_rate{agent}                      // responded / total (rolling 1h)
mention_unanswered_streak{agent}                  // Consecutive unanswered mentions

// Per-agent health
agent_responded_total{agent}                      // Total responses sent (regardless of mention)
agent_mention_coverage_ratio{agent}               // Mentions handled / total mentions
```

### 4.2 Grafana Dashboard

```
┌──────────────────────────────────────────────────────────────────────────┐
│ @Mention Response Tracking — Last 24h              ┌──────────────────┐ │
│ ┌────────────────────────────────────────────────┐ │ Total Mentions   │ │
│ │ Mentions / Responses — stacked bar chart       │ │    142           │ │
│ │                                                │ │ Responded  131   │ │
│ │  ██████████████████████████████████████████    │ │ Unanswered 11    │ │
│ │  ██████████████████████████████████████        │ │                  │ │
│ │  ████████████████████████                      │ │ Response Rate    │ │
│ │                                                │ │     92.3%        │ │
│ │  ── mentions  ── responded                     │ └──────────────────┘ │
│ └────────────────────────────────────────────────┘                      │
│                                                                          │
│ ┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────┐  │
│ │ Per-Agent Response   │ │ Response Latency     │ │ Unanswered by    │  │
│ │ Rate (bar)           │ │ (heatmap by hour)    │ │ Agent (table)    │  │
│ │ ┌──────────────────┐ │ │ ┌──────────────────┐ │ │ ┌────────────────┐│  │
│ │ │ kyb-infra   94%  │ │ │ │ 00  ██░░   p50   │ │ │ │ kyb-infra   3 ││  │
│ │ │ kyb         88%  │ │ │ │ 06  ████   p95   │ │ │ │ kyb         8 ││  │
│ │ │ kyb-deploy  67%  │ │ │ │ 12  ██░░   2.1s  │ │ │ │              ││  │
│ │ └──────────────────┘ │ │ │ 18  ████   8.7s  │ │ │ └────────────────┘│  │
│ └──────────────────────┘ │ └──────────────────┘ │ └──────────────────┘  │
│                                                                          │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ Recent Unanswered Mentions (last 24h)                                │ │
│ │ ┌──────────┬──────────┬──────────┬──────────┬─────────────────────┐ │ │
│ │ │ Time     │ Agent    │ Sender   │ Content  │ Chat                │ │ │
│ │ ├──────────┼──────────┼──────────┼──────────┼─────────────────────┤ │ │
│ │ │ 14:32:01 │ kyb-infra│ ou_75... │ @kyb-inf │ oc_9b1a...          │ │ │
│ │ │ 14:30:15 │ kyb      │ ou_9a... │ @kyb 发  │ oc_9b1a...          │ │ │
│ │ └──────────┴──────────┴──────────┴──────────┴─────────────────────┘ │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.3 Alert Rules

| Rule | Condition | Severity | Channel | Cooldown |
|------|-----------|----------|---------|----------|
| MentionUnansweredUrgent | Any urgent-priority mention unanswered > SLA | P1 | PagerDuty + Feishu | 5min |
| ResponseRateDrop | Response rate < 80% over 30min window | P2 | Feishu alert group | 15min |
| AgentSilent | Agent received 3+ mentions in 15min, responded to 0 | P2 | Feishu alert group | 10min |
| MentionSurge | Mention count > 3x baseline over 1h | P3 | Dashboard warning | 30min |
| UnansweredAccumulation | Unanswered mentions > 5 in the last hour | P2 | Feishu alert group | 15min |
| CorrelatorStall | Correlator hasn't processed events in >120s | P2 | PagerDuty | 10min |

---

## 5. Mention Extraction and Classification

### 5.1 Parser

The inbound event parser extracts @mentions from the raw content field. Feishu
@mentions in text messages appear as `@agent_name` in the content.

**Parser rules:**

```python
import re

MENTION_PATTERN = re.compile(r'@([\w\-]+)')

# Known agents and their routing targets
AGENT_MAP = {
    'kyb':        'kyb-boss',
    'kyb-infra':  'infra-boss',
    'kyb-deploy': 'deploy-agent',
    # Extensible via config file
}

def parse_mention(content: str) -> list[ParsedMention]:
    """Extract @mentions from message content."""
    matches = MENTION_PATTERN.findall(content)
    results = []
    for m in matches:
        agent_name = m.strip()
        routed_to = AGENT_MAP.get(agent_name, 'unknown')
        results.append(ParsedMention(
            agent_name=agent_name,
            routed_to=routed_to,
        ))
    return results
```

**Edge cases:**

| Content | Mentions | Notes |
|---------|----------|-------|
| `@kyb hello` | `@kyb` | Simple mention with message |
| `@kyb @kyb-infra both help` | `@kyb`, `@kyb-infra` | Multiple agents mentioned |
| `@kyb` | `@kyb` | Pure mention (no other text) |
| `@kyb-infra can you check @kyb` | `@kyb-infra`, `@kyb` | Mention with reference to other agent |
| `hello world` | (none) | No mention |
| `email@example.com` | (none) | `@` but not mention (regex handles this: `@example.com` requires word boundary) |

### 5.2 Mention Classification

| Category | Criteria | SLA | Response Expected |
|----------|----------|-----|-------------------|
| **Command** | Starts with `@agent` + action verb (deploy, restart, check) | 30s | Action confirmation |
| **Question** | Contains `?` or query syntax after `@agent` | 60s | Answer |
| **Status check** | `@agent` + status/health keywords | 15s | Status report |
| **Alert** | `@agent` + high-urgency keywords (fire, down, crash) | 10s | Immediate response |
| **Pure mention** | Only `@agent` with no other content | 30s | "How can I help?" |
| **Unclassified** | None of the above | 60s | Varies |

**Note:** Classification is optional in v1. Start with a flat SLA (default: 60s)
and add classification when patterns emerge from real data.

---

## 6. Response Correlation Strategies

### 6.1 Simple Strategy: Chat-Based Correlation (Recommended for v1)

Correlate by `chat_id` + temporal proximity:

```
Inbound:  @kyb-infra deploy now      → chat=oc_xxx, ts=T0
Outbound: "Deploying to production"   → chat=oc_xxx, ts=T1

Correlation: outbound to oc_xxx at T1 is a response to the most recent
PENDING mention in oc_xxx (if T1 - T0 < SLA_WINDOW)
```

**Pros:**
- Simple to implement (no changes to cc-connect or agent code)
- Works with existing outbound delivery tracking
- No correlation headers needed

**Cons:**
- Cannot distinguish response to `@A` vs `@B` when both mentioned in same message
- If agent sends multiple messages, only the first is counted as response time
- Proactive messages (not triggered by mention) may incorrectly match a pending mention
  (mitigated by SLA window: if message arrives outside 2x SLA, don't correlate)

### 6.2 Medium Strategy: Thread-Aware Correlation

Use feishu message threads or parent_message_id if available:

```
Inbound:  @kyb-infra deploy now      → message_id=om_A
Outbound: "Deploying to production"   → parent_message_id=om_A → chat=oc_xxx

Correlation: outbound has parent_message_id matching mention message_id
```

Feishu's send API supports `parent_message_id` in `send_message` to reply in thread.
If cc-connect sets `parent_message_id` when responding to a mention, correlation
is deterministic.

**Pros:** 100% accurate correlation, no time window ambiguity
**Cons:** Requires cc-connect to include `parent_message_id` in outbound messages

### 6.3 Advanced Strategy: Explicit Correlation Headers

Add a custom `mention_id` header or metadata field to outbound messages:

```
Inbound:  @kyb-infra deploy now      → mention_id=chat_ts_hash
Outbound: "Deploying to production"   → metadata: {mention_id: chat_ts_hash}

Correlation: outbound metadata.mention_id matches inbound mention_id
```

**Pros:** Deterministic, survives restarts, supports multi-agent chats
**Cons:** Requires changes to both inbound processing and outbound message API

### 6.4 Recommendation

| Phase | Strategy | Effort | Accuracy | Depends on |
|-------|----------|--------|----------|------------|
| v1 | Chat-based (6.1) | < 1h | 90% | Delivery tracking |
| v2 | Thread-aware (6.2) | < 1h | 99% | cc-connect parent_message_id |
| v3 | Explicit headers (6.3) | < 2h | 100% | Inbound/outbound metadata |

Start with v1 (chat-based). If false correlations become a problem, upgrade to v2.

---

## 7. Implementation

### 7.1 Inbound Parser Script

A lightweight script that scans lark event JSON files and extracts mentions.

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/mention-parse
# Parse lark event files for @mentions and emit structured records.

EVENTS_DIR="${1:-/home/dev/projects/kyb/.lark-events}"
PROCESSED_DIR="${EVENTS_DIR}/.processed"
METRICS_FILE="${2:-/tmp/mention-metrics.prom}"

mkdir -p "$PROCESSED_DIR"

for event_file in "$EVENTS_DIR"/*.json; do
    [ -f "$event_file" ] || continue

    # Skip already-processed files
    basename=$(basename "$event_file")
    [ -f "$PROCESSED_DIR/$basename" ] && continue

    # Extract mention fields via jq
    content=$(jq -r '.content // ""' "$event_file")
    mentioned=$(echo "$content" | grep -oP '@[\w\-]+' | tr '@' ' ' | xargs)

    if [ -n "$mentioned" ]; then
        chat_id=$(jq -r '.chat_id' "$event_file")
        message_id=$(jq -r '.message_id' "$event_file")
        sender_id=$(jq -r '.sender_id' "$event_file")
        ts=$(jq -r '.timestamp' "$event_file")
        chat_type=$(jq -r '.chat_type' "$event_file")

        # Emit JSON line for each mention
        for agent in $mentioned; do
            echo "{\"ts\":$ts,\"chat_id\":\"$chat_id\",\"message_id\":\"$message_id\",\"sender_id\":\"$sender_id\",\"chat_type\":\"$chat_type\",\"mentioned_agent\":\"$agent\",\"raw_content\":$(jq -Rsa . <<<"$content")}"
        done
    fi

    # Mark as processed
    cp "$event_file" "$PROCESSED_DIR/$basename"
done
```

**Integration:**
- Run from patrol cycle (every 5 minutes) or as a cron job.
- Output piped to Vector for ClickHouse ingestion.
- Mark processed files to avoid re-processing (`.processed/` directory).

### 7.2 Correlator Daemon

A minimal Go daemon that:

1. Watches the inbound event stream (or polls every 10s).
2. Maintains in-memory PENDING mentions per chat (LRU, max 1000 entries).
3. Listens for outbound delivery confirmations (from delivery tracker or polled from CK).
4. On outbound event, checks for matching PENDING mention.
5. Updates MentionStore (ClickHouse) and emits metrics.

**Note:** The correlator can be combined with the delivery tracker from
`feishu-delivery.md` as a single daemon (`feishu-observer`) rather than a separate
process. This avoids duplicate event ingestion and shared state complexity.

### 7.3 ClickHouse Integration

Vector configuration to parse mention events:

```toml
[sources.mention_events]
type = "file"
include = ["/home/dev/projects/kyb/.lark-events/*.json"]
ignore_older_secs = 600

[transforms.mention_parser]
type = "remap"
inputs = ["mention_events"]
source = '''
  . = parse_json!(.message)
  mentions = parse_mentions(.content)  # custom VRL function or script
  if mentions != [] {
    .mentions = mentions
  } else {
    abort
  }
'''

[sinks.mention_clickhouse]
type = "clickhouse"
inputs = ["mention_parser"]
endpoint = "http://host.orb.internal:8123"
table = "infra.mention_events"
```

**Alternative:** Use a lightweight Ruby/Python script instead of Vector VRL
for mention parsing (more flexible with @mention regex). Pipe into `clickhouse-client`.

### 7.4 Prometheus Exporter

Expose mention metrics via the existing feishu observability endpoint:

```
# HELP mention_total Total @mentions received
# TYPE mention_total counter
mention_total{agent="kyb-infra",chat="oc_xxx"} 142
mention_total{agent="kyb",chat="oc_xxx"} 38

# HELP mention_responded_total Mentions that received a response
# TYPE mention_responded_total counter
mention_responded_total{agent="kyb-infra"} 134
mention_responded_total{agent="kyb"} 30

# HELP mention_unanswered_total Mentions that did not receive a response
# TYPE mention_unanswered_total counter
mention_unanswered_total{agent="kyb-infra"} 8
mention_unanswered_total{agent="kyb"} 8

# HELP mention_response_latency_ms Time from mention to first response
# TYPE mention_response_latency_ms histogram
mention_response_latency_ms_bucket{agent="kyb-infra",le="1000"} 45
mention_response_latency_ms_bucket{agent="kyb-infra",le="5000"} 120
mention_response_latency_ms_bucket{agent="kyb-infra",le="30000"} 134
mention_response_latency_ms_bucket{agent="kyb-infra",le="+Inf"} 134
mention_response_latency_ms_count{agent="kyb-infra"} 134
mention_response_latency_ms_sum{agent="kyb-infra"} 89000
```

---

## 8. SLA Configuration

### 8.1 Per-Agent SLA

```yaml
# ~/.kyb/config/mention-sla.yml
agents:
  kyb:
    sla_ms: 30000           # 30s for kyb-boss
    urgent_sla_ms: 10000    # 10s for urgent mentions
    alert_on_unanswered: true
    max_unanswered_streak: 3

  kyb-infra:
    sla_ms: 60000           # 60s for infra-boss
    urgent_sla_ms: 20000    # 20s for urgent
    alert_on_unanswered: true
    max_unanswered_streak: 3

  kyb-deploy:
    sla_ms: 120000          # 120s for deploy agent
    urgent_sla_ms: 30000
    alert_on_unanswered: true
    max_unanswered_streak: 5  # deploy may be slower, tolerate more

default:
  sla_ms: 60000
  urgent_sla_ms: 30000
  alert_on_unanswered: false
  max_unanswered_streak: 10
```

### 8.2 SLA Windows by Chat Type

| Chat Type | SLA (normal) | SLA (urgent) | Reasoning |
|-----------|-------------|--------------|-----------|
| Group chat | 60s | 20s | Cooldown from user @mention to agent response |
| P2P (private) | 120s | 30s | P2P goes through routing, may be slower |
| Thread reply | 30s | 10s | Thread context already loaded |

---

## 9. Alerting and Reporting

### 9.1 Real-Time Alerts

```
┌──────────────────────────────────────────────┐
│          Mention Response Alert                │
│                                                │
│  [P2] Response Rate Drop — kyb (67%)          │
│                                                │
│  Agent kyb has responded to 8 of 12 mentions   │
│  in the last 30 minutes. 4 unanswered.         │
│                                                │
│  Unanswered mentions:                          │
│  • 14:32:01 "kyb 在吗" → chat oc_9b1a...      │
│  • 14:35:22 "kyb 回话" → chat oc_9b1a...      │
│  • 14:40:00 "kyb 重启" → chat oc_9b1a...      │
│  • 14:45:15 "kyb 看下" → chat oc_9b1a...      │
│                                                │
│  Action: Check cc-connect routing for kyb,     │
│  verify agent container is running.            │
└──────────────────────────────────────────────┘
```

### 9.2 Daily Summary (Feishu Card)

A daily summary posted to the ops chat at 09:00:

| Section | Content |
|---------|---------|
| Header | @Mention Response Summary — 2026-05-23 |
| Overall | Total mentions: 142 | Responded: 131 (92.3%) | Avg latency: 4.2s |
| Per-agent | Table: agent | mentions | responses | rate | p50 | p95 |
| Top unanswered | Links to 3 most recent unanswered mentions |
| Trend | 7-day response rate sparkline |
| Action items | Agents with < 80% response rate highlighted |

### 9.3 Operational Runbook

| Symptom | Likely Cause | Check | Fix |
|---------|-------------|-------|-----|
| All agents have 0% response rate | WebSocket disconnected | `docker logs cc-connect` for `connected to wss://` | Restart cc-connect container |
| Single agent has 0% response rate | Agent container crashed or routing broken | `kyb ps` to check if agent container exists | `kyb start <agent>` or recreate |
| Sporadic unanswered mentions | Agent busy/queue full | Check agent logs for `rate limited` or `context window full` | Adjust agent concurrency or scale up |
| High latency (>60s) for all mentions | Under-provisioned compute | `docker stats` on agent host | Add resources or reduce concurrent sessions |
| False positives (response detected but not a real response) | Chat-based correlation glitch | Check if proactive messages are matching pending mentions | Upgrade to thread-aware correlation (6.2) |

---

## 10. Implementation Plan

### Phase 1: Mention Parser + ClickHouse (Day 1, < 2h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 1.1 | Write `mention-parse` script (bash + jq) | — |
| 1.2 | Create `infra.mention_events` table in ClickHouse | — |
| 1.3 | Run parser on existing event files (~50 events), ingest historical mentions | 1.1, 1.2 |
| 1.4 | Add script to patrol cycle (5min cron or cc-healthcheck integration) | 1.1 |

**Verification:** Query `infra.mention_events` and see all historical @mentions with correct state=PENDING.

### Phase 2: Response Correlation (Day 1, < 3h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 2.1 | Implement simple chat-based correlator (Ruby/Python script or Go daemon) | Phase 1 |
| 2.2 | Wire correlator to outbound delivery events (from delivery tracker or lark-cli send wrapper) | feishu-delivery.md Phases 1-2 |
| 2.3 | Update `infra.mention_events`: set state=RESPONDED with latency on match | 2.1 |
| 2.4 | Implement sweeper: mark PENDING > SLA as UNANSWERED | 2.1 |

**Verification:** Send `@kyb-infra test` to a chat, verify mention is recorded, then verify agent responds, and query shows state=RESPONDED with correct latency.

### Phase 3: Metrics and Alerting (Day 2, < 2h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 3.1 | Emit Prometheus metrics from correlator | Phase 2 |
| 3.2 | Build Grafana dashboard: per-agent response rate, latency histogram, unanswered table | 3.1 |
| 3.3 | Configure Grafana alerts on response rate drop and unanswered accumulation | 3.2 |
| 3.4 | Test alerts with simulated failures | 3.3 |

**Verification:** Stop an agent, @mention it, confirm alert fires within SLA + 1 sweep cycle.

### Phase 4: Daily Summary + Reporting (Day 2-3, < 1h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 4.1 | Implement daily summary card (feishu message card, sent to ops chat) | Phase 3 |
| 4.2 | Add 7-day trend view to dashboard | 3.2 |
| 4.3 | Document runbook in this document | Phase 3 |

### Phase 5: Correlation Upgrade (Optional, Week 2)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 5.1 | Add `parent_message_id` to cc-connect outbound messages | cc-connect changes |
| 5.2 | Upgrade correlator to thread-aware matching (6.2) | 5.1 |
| 5.3 | Evaluate need for explicit correlation headers (6.3) | 5.2 |

---

## 11. Operational Considerations

### 11.1 Event File Management

The `lark-cli event consume` command stores events as individual JSON files.
At current volume (~50-100 events/day), this is fine. At higher volumes:

| Volume | Files/day | Disk/month | Action |
|--------|-----------|------------|--------|
| Current (~50/day) | 50 | ~5 MB | No action needed, clean `.processed` on restart |
| Medium (~500/day) | 500 | ~50 MB | Add log rotation: keep 7 days raw, aggregate to CK |
| High (~5000/day) | 5000 | ~500 MB | Switch to stream processing (skip file storage) |

Cleanup strategy:
- Raw event files older than 7 days are deleted.
- Processed markers in `.processed/` are cleaned on correlator restart.
- ClickHouse is the source of truth (90-day retention).

### 11.2 Correlator Reliability

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Correlator process crashes | PENDING mentions in memory lost | Sweep on restart: re-query CK for all PENDING mentions older than 15s, re-arm timers |
| Event processed twice (duplicate) | Double-counted response | Dedup by `mention_id` (chat_id + message_id) in CK INSERT with `ReplacingMergeTree` |
| Outbound event arrives before inbound event | Missed correlation | Buffer outbound events for 5s on correlator startup, or use `ORDER BY` + `argMin` in CK |
| Clock skew between containers | Negative latency | Use feishu timestamps (not local clock) for all latency calculations |

### 11.3 Feishu API Considerations

| Aspect | Detail |
|--------|--------|
| Event dedup key | `event_id` in `im.message.receive_v1` — same message can produce multiple events (dedup by `event_id`) |
| Message ID format | `om_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx` (33 chars) |
| Timestamp precision | Milliseconds (Unix epoch in ms) |
| Group vs P2P | `chat_type` distinguishes group and p2p — different SLA and correlation logic |
| Sender ID | `ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx` — open_id, stable per user per app |
| Content truncation | Long messages may be truncated in `content`; use `GET /im/v1/messages/{id}` for full content if needed |

### 11.4 Privacy

Mention tracking stores raw content and sender IDs. For compliance:

- Retention: 90 days in ClickHouse (configurable, min 30 days).
- Raw content is only accessible via ClickHouse (not in Prometheus).
- Sender IDs (ou_xxx) are meaningless outside feishu context — no PII mapping.
- Dashboard excludes raw content; only displays in alert details and unanswered table.
- Daily summary includes anonymized sender IDs (last 4 chars: `ou_xxxx...75f0`).

---

## 12. Existing Data Analysis

Based on 46 event files from `.lark-events/` (2026-05-23):

| Dimension | Value |
|-----------|-------|
| Total messages | 46 |
| Mentions found | 24 (52.2% of all messages) |
| @kyb-infra | 20 (83.3% of mentions) |
| @kyb | 4 (16.7% of mentions) |
| Unique senders | 2 (ou_75..., ou_9a...) |
| Unique chat | 1 (oc_9b1a...) |
| Pure mentions | 2 (message is only `@agent`) |
| Messages with only text (no mention) | 22 (47.8%) |

**Implication:** At this volume (~50 events/day), a simple script-based approach
(bash + jq CRON) is sufficient. No need for stream processing or a dedicated daemon
in Phase 1. The correlator can be a lightweight script that runs every minute.

---

## 13. Summary

| Aspect | Design Decision |
|--------|----------------|
| Mention extraction | Regex `@(\w+-?\w+)` on `content` field from `im.message.receive_v1` |
| Correlation key | `chat_id` + temporal proximity (v1), upgrade to `parent_message_id` / explicit headers later |
| Mention store | ClickHouse `infra.mention_events`, 90-day retention |
| In-memory cache | LRU of PENDING mentions (max 1000), keyed by chat_id |
| Metrics | Prometheus counters + histograms per agent, per chat |
| SLA | 30s/60s/120s per agent, configurable in YAML |
| Alert severity | P1=urgent unanswered, P2=rate drop/agent silent, P3=surge |
| Default response rate threshold | 80% over 30min triggers alert |
| Phase 1 effort | ~2h (parser + CK table + historical ingest) |
| Phase 2 effort | ~3h (correlator + outbound wire-up) |

Without this system, unanswered @mentions are invisible until a human double-posts
"hello??". With it, we get per-agent response time SLAs, automated alerting on
silent agents, and a data-driven answer to "is the bot working?"

---

## References

- Feishu delivery monitoring: `docs/infra/reviews/feishu-delivery.md`
- Session monitoring: `docs/infra/reviews/session-monitor.md`
- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`
- IM integration FAQ: `docs/infra/chat.md`
- Observability design: `docs/infra/observability-design.md`
- Event files (raw data): `.lark-events/`
- Patrol guide: `docs/infra/5min-patrol-guide.md`

---

/人◕ ‿‿ ◕人＼
