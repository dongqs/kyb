---
decision: 不应该做
---

# Design: cc-connect Native Hooks to Kafka Pipeline

**Date**: 2026-05-23  
**Status**: Design  
**Author**: kyb  
**System**: cc-connect v1.3.2 native hooks -> Kafka REST Proxy -> topic -> ClickHouse

---

## 1. Motivation

### Problem

cc-connect v1.3.2 has native hooks (6 events: `message.received`, `response.complete`, `session.timeout`, `session.crashed`, `session.resumed`, `permission.requested`) but currently **no pipeline to forward these events to a durable store**. Without persistence:

- Alert rules cannot reference historical event patterns (e.g., "3 timeouts in 5 minutes").
- Post-mortems rely on Feishu chat history (fragile, incomplete).
- There is no cross-event correlation (e.g., "did a `session.crashed` coincide with a patrol anomaly?").

### Approach

The existing [Kafka Message Bus design](../reviews/kafka-message-bus.md) already defines the infrastructure for event streaming (Redpanda broker + CK Kafka Engine). This design extends it by adding:

1. **Kafka REST Proxy** (built into Redpanda) as the ingestion endpoint.
2. **cc-connect native hooks** configured to POST directly to the REST Proxy.
3. A dedicated **topic** for cc-connect hooks events.
4. **ClickHouse Kafka Engine** consumption into a unified `cc.hook_events` table.

### Why REST Proxy Instead of a Kafka Client Library

| Dimension | REST Proxy | Kafka Client Library |
|-----------|-----------|---------------------|
| cc-connect integration | Native webhook target (HTTP POST) | Requires embedding a client or sidecar process |
| Deployment complexity | Already included in Redpanda | Requires additional binary or sidecar |
| Protocol | Plain HTTP (no extra deps) | Kafka wire protocol (needs binary protocol lib) |
| Latency | ~5-10ms per POST (negligible at < 1 msg/s) | ~1-2ms (not meaningful at this scale) |
| Reliability | Webhook target controls retries | Client controls retries and acks |
| Schema enforcement | None (validated at consumer) | None (validated at consumer) |

At the current volume (< 1 event per second), HTTP overhead is irrelevant. The simplicity of using cc-connect's built-in webhook target wins.

---

## 2. Architecture

```
cc-connect v1.3.2
  │
  │  native hooks configured with webhook target
  │  (built-in retry with backoff)
  │
  ▼  HTTP POST /topics/cc.hooks
  │
  Kafka REST Proxy (Redpanda :8082)
  │
  ▼  Kafka topic: cc.hooks (partitions: 3, retention: 7d)
  │
  ClickHouse Kafka Engine table (cc.hook_queue)
  │  MATERIALIZED VIEW
  ▼
  cc.hook_events (MergeTree, TTL 90d)
```

### 2.1 Components

| Component | Role | Where |
|-----------|------|-------|
| **cc-connect** | Emits hook events via native webhook target | `kyb-infra-cc-connect` container |
| **Kafka REST Proxy** | Accepts HTTP POST, writes to Kafka | Redpanda broker (built-in, port 8082) |
| **Redpanda** | Message broker, stores event stream | `kyb-infra-kafka` (or `kyb-infra-redpanda`) |
| **Topic `cc.hooks`** | All cc-connect hook events | 3 partitions, 7d retention |
| **ClickHouse** | Kafka Engine consumer + MergeTree store | `kyb-infra-clickhouse` |

### 2.2 Data Flow Detail

```
Step 1: cc-connect hook fires
  cc-connect detects event (e.g., session.crashed)
  → native hook engine constructs JSON payload
  → POST to http://host.orb.internal:8082/topics/cc.hooks

Step 2: REST Proxy writes to Kafka
  REST Proxy receives POST
  → validates format (must be JSON Array of records)
  → writes to cc.hooks topic, partition by key hash
  → returns 200 OK with partition + offset

Step 3: ClickHouse consumes from Kafka
  Kafka Engine table pulls from cc.hooks
  → MATERIALIZED VIEW transforms and inserts
  → Data lands in cc.hook_events (MergeTree)
```

### 2.3 Key Design Property: Fail-Open

cc-connect's native hook engine supports **configurable retry with backoff**. The webhook target should be configured with:

- `retry_count`: 2 (retry twice before giving up)
- `retry_interval_ms`: 1000 (1 second between retries)
- `timeout_ms`: 5000 (5 second HTTP timeout)

If the REST Proxy is down after all retries, cc-connect **drops the event** and continues. The hook must never block message processing.

> This aligns with the fail-open principle established in the [Claude Hooks to CK Pipeline](../handbook/hooks-ck-pipeline.md).

---

## 3. Kafka REST Proxy Setup

### 3.1 Redpanda Built-in Proxy

Redpanda includes a Kafka-compatible REST Proxy on port 8082 (enabled by default in `--mode dev-container`). No additional deployment needed.

Verify the proxy is running:

```bash
curl http://host.orb.internal:8082/topics
# Expected: ["cc.events", "patrol.events", ...]
```

### 3.2 Standalone confluentinc/cp-kafka-rest (if using Apache Kafka)

If using Apache Kafka instead of Redpanda, deploy the Confluent REST Proxy:

```bash
docker run -d \
  --name kyb-infra-kafka-rest \
  --restart unless-stopped \
  --network kyb-infra \
  -p 8082:8082 \
  -e KAFKA_REST_BOOTSTRAP_SERVERS=host.orb.internal:9092 \
  -e KAFKA_REST_HOST_NAME=host.orb.internal \
  -e KAFKA_REST_LISTENERS=http://0.0.0.0:8082 \
  confluentinc/cp-kafka-rest:latest
```

### 3.3 Topic Configuration

```bash
rpk topic create cc.hooks --partitions 3
```

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 3 | Partition by `event_type` hash; parallel consumption |
| Replication factor | 1 | Single broker |
| Retention | 7 days | Replay capability for a full week |
| Cleanup policy | `delete` | Time-based deletion |

### 3.4 Why 3 Partitions

The partition key is `event_type`. This ensures:

- All `session.crashed` events land in the same partition (ordered).
- All `message.received` events for the same session land in the same partition (ordered).
- Parallel consumption by up to 3 ClickHouse consumers.

Partition mapping:

| Partition | event_type |
|-----------|------------|
| 0         | `message.received`, `response.complete` |
| 1         | `session.timeout`, `session.crashed`, `session.resumed` |
| 2         | `permission.requested` |

---

## 4. cc-connect Native Hooks Configuration

### 4.1 cc-connect Hooks Config File

cc-connect v1.3.2 reads hooks config from a YAML file. This file should be mounted into the container or generated at startup.

```yaml
# /etc/cc-connect/hooks.yaml
hooks:
  webhooks:
    - url: "http://host.orb.internal:8082/topics/cc.hooks"
      events:
        - "message.received"
        - "response.complete"
        - "session.timeout"
        - "session.crashed"
        - "session.resumed"
        - "permission.requested"
      retry_count: 2
      retry_interval_ms: 1000
      timeout_ms: 5000
      headers:
        Content-Type: "application/vnd.kafka.json.v2+json"
        Accept: "application/vnd.kafka.v2+json"
```

### 4.2 Required HTTP Headers

The [Kafka REST Proxy API](https://docs.confluent.io/platform/current/kafka-rest/api.html) requires:

- `Content-Type: application/vnd.kafka.json.v2+json` — tells the proxy the body is a JSON record set.
- `Accept: application/vnd.kafka.v2+json` — tells the proxy what response format to use.

### 4.3 POST Body Format

The REST Proxy expects a JSON object with a `records` array. Each record has a `key` and `value`.

```json
{
  "records": [
    {
      "key": "session.crashed",
      "value": {
        "schema_version": "1.0",
        "source": "cc-connect",
        "event_type": "session.crashed",
        "event_time": "2026-05-23T16:38:00.604Z",
        "producer": {
          "host": "kyb-boss",
          "instance": "kyb-infra-cc-connect",
          "container_id": "abc123..."
        },
        "payload": {
          "session": "feishu:oc_xxx:ou_xxx",
          "agent_session": "d2720c67-...",
          "error": "Claude process exited with code 137",
          "crash_time_sec": 15207
        }
      }
    }
  ]
}
```

### 4.4 REST Proxy Response

On success, the proxy returns:

```json
{
  "offsets": [
    {
      "partition": 1,
      "offset": 42,
      "error_code": null,
      "error": null
    }
  ]
}
```

cc-connect ignores the response body (fire-and-forget from the hook's perspective). The response is only useful for debugging.

### 4.5 cc-connect Startup Configuration

The hooks config file path is passed to cc-connect at startup. The exact flag depends on cc-connect v1.3.2's CLI:

```bash
# Hypothetical — verify against actual cc-connect v1.3.2 CLI docs
cc-connect --hooks-config /etc/cc-connect/hooks.yaml
```

Or via environment variable:

```bash
CC_CONNECT_HOOKS_CONFIG=/etc/cc-connect/hooks.yaml
```

---

## 5. ClickHouse Schema

### 5.1 Kafka Engine Table (`cc.hook_queue`)

```sql
CREATE TABLE cc.hook_queue (
    schema_version  String,
    source          String,
    event_type      String,
    event_time      DateTime64(3),
    host            String,
    instance        String,

    -- Payload fields (extracted from JSON payload)
    session         String DEFAULT '',
    agent_session   String DEFAULT '',
    error           String DEFAULT '',
    crash_time_sec  Float64 DEFAULT 0,
    turn_duration   Float64 DEFAULT 0,
    input_tokens    UInt32 DEFAULT 0,
    output_tokens   UInt32 DEFAULT 0,
    tools           UInt8 DEFAULT 0,
    msg_id          String DEFAULT '',
    user            String DEFAULT '',
    platform        String DEFAULT '',

    -- Raw payload for forward compatibility
    payload_raw     String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'cc.hooks',
    kafka_group_name = 'ck-consumer-cc-hooks',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

### 5.2 MergeTree Table (`cc.hook_events`)

```sql
CREATE TABLE cc.hook_events (
    schema_version  LowCardinality(String),
    source          LowCardinality(String),
    event_type      LowCardinality(String),
    event_time      DateTime64(3),

    -- Producer identity
    host            LowCardinality(String),
    instance        LowCardinality(String),

    -- Session context
    session         String,
    agent_session   String,
    msg_id          String,
    user            String,
    platform        LowCardinality(String),

    -- Event-specific fields
    error           String,
    crash_time_sec  Float64,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    tools           UInt8,

    -- Raw payload for forward compatibility
    payload_raw     String,

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, session)
TTL event_time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

**Design decisions:**

1. **Sorting key `(toDate(event_time), event_type, session)`**: Covers the two most common query patterns — time-range filtering by event type ("show all crashes in the last 24h") and per-session event sequence ("show all events for a specific session in order").

2. **`payload_raw`**: Stores the full original JSON for any future event fields not yet in the schema. This allows adding new fields without a schema migration.

3. **`_ingested_at` separate from `event_time`**: The gap between them measures pipeline latency.

4. **TTL 90 days**: Matches the `cc.message_log` retention policy. Event volume is low, so storage is negligible.

### 5.3 Materialized View

```sql
CREATE MATERIALIZED VIEW cc.hook_queue_to_events TO cc.hook_events AS
SELECT *
FROM cc.hook_queue;
```

### 5.4 Estimated Volume

| Item | Value |
|------|-------|
| Events per turn | ~3 (received, processing, complete/timeout) |
| Daily turns | ~90 (from kafka-message-bus.md estimate) |
| Raw daily events | ~270 |
| Storage per event | ~400 bytes (compressed ~80 bytes) |
| 90-day storage | ~270 * 90 * 80 = ~1.9 MB |

Negligible. No capacity concerns.

---

## 6. Event Types and Payloads

### 6.1 `message.received`

Fires when cc-connect receives a new message from Feishu.

```json
{
  "event_type": "message.received",
  "payload": {
    "msg_id": "om_xxx",
    "session": "feishu:oc_xxx:ou_xxx",
    "user": "ou_xxx",
    "content_len": 65,
    "has_images": false,
    "has_audio": false,
    "has_files": false,
    "platform": "feishu"
  }
}
```

**Usage**: Count incoming messages, detect spam bursts, track per-user activity.

### 6.2 `response.complete`

Fires when cc-connect finishes sending a response to Feishu.

```json
{
  "event_type": "response.complete",
  "payload": {
    "msg_id": "om_xxx",
    "session": "feishu:oc_xxx:ou_xxx",
    "agent_session": "d2720c67-...",
    "tools": 2,
    "response_len": 554,
    "turn_duration_sec": 15.2,
    "input_tokens": 431,
    "output_tokens": 521
  }
}
```

**Usage**: Compute latency percentiles (P50/P90/P99), track token consumption, detect slow turns.

### 6.3 `session.timeout`

Fires when a Claude Code session times out (no response within timeout window).

```json
{
  "event_type": "session.timeout",
  "payload": {
    "session": "feishu:oc_xxx:ou_xxx",
    "agent_session": "d2720c67-...",
    "timeout_sec": 300,
    "last_activity": "2026-05-23T16:33:00.000Z"
  }
}
```

**Usage**: Detect timeout patterns. If 3+ timeouts in 5 minutes for the same session, something is wrong with that Claude instance.

### 6.4 `session.crashed`

Fires when the Claude Code process crashes.

```json
{
  "event_type": "session.crashed",
  "payload": {
    "session": "feishu:oc_xxx:ou_xxx",
    "agent_session": "d2720c67-...",
    "error": "Claude process exited with code 137",
    "crash_time_sec": 15207,
    "exit_code": 137
  }
}
```

**Usage**: P1/P0 alert trigger. Any `session.crashed` event should produce an immediate notification.

### 6.5 `session.resumed`

Fires when cc-connect recovers a session after a crash.

```json
{
  "event_type": "session.resumed",
  "payload": {
    "session": "feishu:oc_xxx:ou_xxx",
    "agent_session": "d2720c67-...",
    "recovered": true,
    "recovery_time_sec": 12.5
  }
}
```

**Usage**: Track recovery effectiveness. If `session.resumed` follows `session.crashed` within 30 seconds, auto-recovery worked. If not, manual intervention is needed.

### 6.6 `permission.requested`

Fires when Claude requests a permission (e.g., run a Bash command).

```json
{
  "event_type": "permission.requested",
  "payload": {
    "request_id": "perm_xxx",
    "tool": "Bash",
    "session": "feishu:oc_xxx:ou_xxx",
    "command_preview": "rm -rf /data"
  }
}
```

**Usage**: Track permission resolution time. If a permission request is unresolved for >10 minutes, escalate (alert rule: P2).

---

## 7. Alert Rules (Referencing CK Queries)

These rules complement the [bridge-hooks-alerting design](../designs/bridge-hooks-alerting.md) by providing concrete CK queries.

| Rule | Level | Condition | CK Query |
|------|-------|-----------|----------|
| Session crashed | P0 | Any `session.crashed` event | `SELECT count() FROM cc.hook_events WHERE event_type='session.crashed' AND event_time > now() - INTERVAL 1 MINUTE` |
| Timeout burst | P1 | 3+ `session.timeout` in 5 min for same session | `SELECT session, count() AS cnt FROM cc.hook_events WHERE event_type='session.timeout' AND event_time > now() - INTERVAL 5 MINUTE GROUP BY session HAVING cnt >= 3` |
| Slow response | P1 | `turn_duration_sec` > 120 (p99 is ~15s) | `SELECT msg_id, turn_duration FROM cc.hook_events WHERE event_type='response.complete' AND turn_duration > 120 AND event_time > now() - INTERVAL 5 MINUTE` |
| Permission stuck | P2 | `permission.requested` without matching resolution for 10 min | `SELECT session, request_id FROM cc.hook_events WHERE event_type='permission.requested' AND event_time < now() - INTERVAL 10 MINUTE` |
| Pipeline silence | P2 | No hook events in 15 minutes | `SELECT count() AS cnt FROM cc.hook_events WHERE event_time > now() - INTERVAL 15 MINUTE` (cnt = 0 = alert) |
| Crash loop | P1 | 3+ `session.crashed` in 5 min (same host) | `SELECT host, count() AS cnt FROM cc.hook_events WHERE event_type='session.crashed' AND event_time > now() - INTERVAL 5 MINUTE GROUP BY host HAVING cnt >= 3` |

### Alert Routing

| Level | Channel | Response Time |
|-------|---------|---------------|
| P0 | Feishu group + kyb notify urgent | Immediate |
| P1 | Feishu group | Within 5 min |
| P2 | Feishu group (batched) | Within 30 min |

### Deduplication Window

- Same alert rule + same `session` within 5 minutes: suppress.
- Same alert rule + same `host` within 1 minute: suppress.

---

## 8. Deployment Steps

### Step 1: Verify Kafka REST Proxy

```bash
# Check if Redpanda REST Proxy is running
curl -s http://host.orb.internal:8082/topics | python3 -m json.tool

# Expected: list of existing topics (may be empty if no topics exist yet)
```

### Step 2: Create Topic

```bash
rpk topic create cc.hooks --partitions 3

# Verify
rpk topic list | grep cc.hooks
```

### Step 3: Create ClickHouse Tables

```sql
-- Kafka Engine queue
CREATE TABLE cc.hook_queue ( ... ) ENGINE = Kafka ... ;

-- MergeTree target
CREATE TABLE cc.hook_events ( ... ) ENGINE = MergeTree ... ;

-- Materialized View
CREATE MATERIALIZED VIEW cc.hook_queue_to_events TO cc.hook_events AS SELECT * FROM cc.hook_queue;
```

### Step 4: Configure cc-connect Hooks

Place the hooks YAML config:

```bash
# Create config directory inside cc-connect container (or bind-mount)
docker exec kyb-infra-cc-connect mkdir -p /etc/cc-connect

# Write hooks config
docker exec kyb-infra-cc-connect bash -c 'cat > /etc/cc-connect/hooks.yaml << '\''EOF'\''
hooks:
  webhooks:
    - url: "http://host.orb.internal:8082/topics/cc.hooks"
      events:
        - "message.received"
        - "response.complete"
        - "session.timeout"
        - "session.crashed"
        - "session.resumed"
        - "permission.requested"
      retry_count: 2
      retry_interval_ms: 1000
      timeout_ms: 5000
      headers:
        Content-Type: "application/vnd.kafka.json.v2+json"
        Accept: "application/vnd.kafka.v2+json"
EOF'

# Restart cc-connect with hooks config flag
docker restart kyb-infra-cc-connect
```

### Step 5: Verify Data Flow

```bash
# Check Kafka topic has messages
rpk topic consume cc.hooks --num 5

# Check ClickHouse has events
clickhouse-client --host host.orb.internal \
  --query "SELECT count(), event_type FROM cc.hook_events GROUP BY event_type"
```

### Step 6: Set Up Grafana Alerts

Create a `cc-connect Hooks` dashboard with:

1. **Event rate** (time series, count by `event_type`)
2. **Session crashes** (single stat, count in last 24h)
3. **Turn duration P50/P90/P99** (time series, from `response.complete`)
4. **Timeout count** (time series, from `session.timeout`)
5. **Pipeline health** (single stat, last event timestamp)

---

## 9. Failure Modes

| Failure | Effect | Detection | Recovery |
|---------|--------|-----------|----------|
| REST Proxy down | Hook POST fails -> cc-connect retries 2x -> event lost | No events in Kafka topic | Restart Redpanda or cp-kafka-rest. Lost events are NOT recovered (cc-connect does not queue). |
| Redpanda broker down | REST Proxy unavailable, same as above | `curl --max-time 5 http://host.orb.internal:8082` fails | Restart Redpanda container. |
| Kafka disk full | REST Proxy returns 500 | `rpk cluster info` shows disk usage > 90% | Increase retention or clean old topics. |
| CK down | Kafka consumption stops, events accumulate in Kafka | CK Kafka Engine consumer lag grows | Restart CK. Consumer resumes from committed offset. **No data loss.** |
| CK volume lost | No historical data | CK table missing | Restore from backup or replay Kafka (7d retention). |
| cc-connect misconfigured | No hooks YAML, or wrong URL | No events but no errors | Check cc-connect logs for hook config errors. Verify hooks file exists and is well-formed. |
| Wrong REST Proxy format | POST succeeds but event is malformed | Events in Kafka but null/missing fields in CK | Check REST Proxy logs. Validate payload format matches `application/vnd.kafka.json.v2+json`. |

### Key Difference from Direct-CK Pipeline

Unlike the [Claude Hooks -> CK pipeline](../handbook/hooks-ck-pipeline.md) which POSTs directly to CK HTTP interface:

- This pipeline has **Kafka as buffer** — CK downtime does NOT cause data loss.
- But it has **one more failure point** (REST Proxy). If the proxy is down, events are lost.
- To mitigate: ensure REST Proxy has `--restart=unless-stopped` and monitor its health.

---

## 10. Migration from Direct-CK Pipeline

The existing [Claude Hooks pipeline](../handbook/hooks-ck-pipeline.md) sends Claude Code session events directly to ClickHouse via HTTP POST. This design is for **cc-connect level events** (message lifecycle, session state), which are a different data domain:

| Pipeline | Source | Events | Destination | Buffer |
|----------|--------|--------|-------------|--------|
| Claude Hooks -> CK | Claude Code session | Tool calls, session lifecycle (PostToolUse, SessionStart, etc.) | `kyb.claude_hook_events` | None (fail-open, events lost if CK down) |
| **cc-connect Hooks -> Kafka -> CK** (this design) | cc-connect bridge | Message lifecycle (received, complete, timeout, crash, resume, permission) | `cc.hook_events` | **Kafka** (7d retention, no loss on CK down) |

**They are complementary, not duplicative.** The Claude Hooks pipeline captures agent-level observability (what Claude does). The cc-connect hooks pipeline captures bridge-level observability (how messages flow through the system).

### Long-Term Vision

```
                    ┌──────────────────────────────┐
                    │      Kafka Event Bus          │
                    │  ┌──────────┐ ┌────────────┐  │
                    │  │cc.events │ │ cc.hooks   │  │
                    │  │(log data)│ │(hook data) │  │
                    │  └──────────┘ └────────────┘  │
                    │  ┌──────────┐ ┌────────────┐  │
                    │  │patrol.   │ │ system.    │  │
                    │  │events    │ │ events     │  │
                    │  └──────────┘ └────────────┘  │
                    └──────────┬───────────────────┘
                               │ ClickHouse Kafka Engine
                               ▼
                    ┌──────────────────────────────┐
                    │         ClickHouse            │
                    │  ┌──────────────┐             │
                    │  │cc.hook_events│  ...         │
                    │  └──────────────┘             │
                    └──────────────────────────────┘
```

All infra events converge into ClickHouse via Kafka, enabling cross-source correlation and single-pane-of-glass observability.

---

## 11. Appendices

### A. Test the Pipeline Manually

```bash
# 1. Verify REST Proxy is online
curl -s http://host.orb.internal:8082/topics | python3 -m json.tool

# 2. Send a test event directly to REST Proxy
curl -s -X POST http://host.orb.internal:8082/topics/cc.hooks \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {
        "key": "test",
        "value": {
          "schema_version": "1.0",
          "source": "cc-connect",
          "event_type": "test.hook",
          "event_time": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'",
          "producer": {
            "host": "'$(hostname)'",
            "instance": "manual-test"
          },
          "payload": {"msg": "pipeline verification"}
        }
      }
    ]
  }'

# 3. Verify event appears in Kafka
rpk topic consume cc.hooks --num 1

# 4. Verify event appears in ClickHouse
clickhouse-client --host host.orb.internal \
  --query "SELECT event_type, source, event_time FROM cc.hook_events ORDER BY event_time DESC LIMIT 5"
```

### B. ce-connect Hooks Config Template

```yaml
# /etc/cc-connect/hooks.yaml
# Mount this into the container at runtime.
# Reference: cc-connect v1.3.2 hooks documentation.
hooks:
  webhooks:
    - url: "http://host.orb.internal:8082/topics/cc.hooks"
      events:
        - "message.received"
        - "response.complete"
        - "session.timeout"
        - "session.crashed"
        - "session.resumed"
        - "permission.requested"
      retry_count: 2
      retry_interval_ms: 1000
      timeout_ms: 5000
      headers:
        Content-Type: "application/vnd.kafka.json.v2+json"
        Accept: "application/vnd.kafka.v2+json"
```

### C. Removing Events from Kafka (if needed)

```bash
# Delete the topic entirely (WARNING: destroys all data)
rpk topic delete cc.hooks

# Recreate
rpk topic create cc.hooks --partitions 3

# Or reduce retention to purge old data
rpk topic alter-config cc.hooks --set retention.ms=3600000  # 1 hour
```

---

> ／人◕ ‿‿ ◕人＼
