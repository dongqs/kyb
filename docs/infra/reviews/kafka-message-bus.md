---
decision: 不应该做
---

# Kafka Message Bus for Observability Events

**Status**: Design proposal
**Date**: 2026-05-23
**Author**: boss

---

## 1. Motivation

Current observability architecture has two independent pipelines:

- **cc-connect** logs -> Vector -> ClickHouse (direct, no buffer)
- **Patrol** heartbeat/state -> (nowhere persistent, only Feishu notifications)

Problems with the current approach:

1. **No shared event bus** -- each producer must implement its own ClickHouse ingestion logic. Vector is tied to Docker logs format; if a producer is not a container, it cannot use the same pipeline.
2. **No replay** -- if ClickHouse is down or the Vector sink fails, events are lost. There is no retention or replay capability.
3. **No unified schema** -- cc-connect and patrol events have no shared metadata envelope. Cross-event correlation (e.g., "did patrol detect an anomaly right before cc-connect stopped responding?") requires ad-hoc joins across different storage systems.
4. **No consumer-side backpressure** -- Vector writes directly to CK. If CK slows down, Vector either blocks (blocking cc-connect log collection) or drops events.

Kafka as a central message bus addresses all four:

- Producers write to Kafka topics; consumers read independently.
- Events persist in Kafka (configurable retention) for replay.
- Shared schema envelope (`source`, `event_type`, `timestamp`, `payload`) enables cross-event correlation.
- Consumer lag absorbs CK backpressure without affecting producers.

---

## 2. Architecture

```
┌─────────────────────┐     ┌─────────────────┐     ┌─────────────┐
│   cc-connect        │────>│  topic:         │────>│ ClickHouse   │
│   (container logs)  │     │  cc.events      │     │ (via CK     │
│                     │     │                 │     │  Kafka      │
│                     │     │  partitions: 3  │     │  Engine or  │
│                     │     │  retention: 7d  │     │  Vector)    │
├─────────────────────┤     ├─────────────────┤     └─────────────┘
│   patrol            │────>│  topic:         │
│   (3 concurrent     │     │  patrol.events  │
│    agents)          │     │                 │
│                     │     │  partitions: 1  │
│                     │     │  retention: 7d  │
├─────────────────────┤     ├─────────────────┤
│   Future producers  │────>│  topic:         │
│   (healthcheck,     │     │  system.events  │
│    cc-cron, ...)    │     │                 │
│                     │     │  partitions: 1  │
│                     │     │  retention: 3d  │
└─────────────────────┘     └─────────────────┘
                                    │
                                    │ Kafka cluster
                                    │ (single node,
                                    │  kyb-infra-kafka)
                                    │
```

### 2.1 Components

| Component | Role | Deployment |
|-----------|------|------------|
| **Kafka** (Redpanda / Apache Kafka) | Message broker, stores event streams | One container: `kyb-infra-kafka` (or `kyb-infra-redpanda`) |
| **cc-connect producer** | Writes structured events to `cc.events` | cc-connect process -> Kafka producer library (or lightweight sidecar that tails Docker logs and publishes) |
| **patrol producer** | Writes heartbeat and status events to `patrol.events` | Inline Kafka producer via Ruby `ruby-kafka` gem or `kcat` CLI |
| **ClickHouse consumer** | Consumes from Kafka topics, inserts into MergeTree tables | ClickHouse Kafka Engine tables (native Kafka integration) |
| **Vector** (optional, deprecate) | Falls back to current cc-connect pipeline if Kafka is not available | Existing container, kept for migration period |

### 2.2 Data Flow

Producers:

```
cc-connect (log line)
    │  parsed into structured JSON
    ▼
[sidecar / log-shipper]
    │  publishes to Kafka topic cc.events
    ▼
Kafka (cc.events, partition by msg_id hash)
    │  persisted, replicated (if multi-broker)
    ▼
ClickHouse Kafka Engine table
    │  consumed via MATERIALIZED VIEW
    ▼
cc.message_log (MergeTree)
```

```
patrol (heartbeat written)
    │  patrol agent writes structured JSON
    ▼
Inline Kafka producer
    │  publishes to Kafka topic patrol.events
    ▼
Kafka (patrol.events)
    │
    ▼
ClickHouse Kafka Engine table
    │  consumed via MATERIALIZED VIEW
    ▼
patrol.event_log (MergeTree)
```

---

## 3. Topics

### 3.1 Topic: `cc.events`

**Purpose**: All cc-connect observability events (message received, turn complete, permission requests, errors, agent state changes).

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 3 | Allows parallel consumption; partition by `msg_id` hash preserves per-message ordering |
| Replication factor | 1 | Single broker; no replication needed at this scale |
| Retention | 7 days (~40 MB total) | Ability to replay a full week of events if needed |
| Cleanup policy | `delete` | Simple time-based deletion |

**Message key**: `msg_id` (string) -- ensures all events for the same message land in the same partition, preserving order.

**Schema (envelope)**:

```json
{
  "schema_version": "1.0",
  "source": "cc-connect",
  "event_type": "message_received | turn_complete | permission_request | permission_resolved | slow_agent_send",
  "event_time": "2026-05-23T16:38:00.604Z",
  "producer": {
    "host": "kyb-boss",
    "container_id": "abc123...",
    "instance": "kyb-infra-cc-connect"
  },
  "payload": {
    // event-type-specific fields
  }
}
```

**Event types and payloads**:

- `message_received`:
  ```json
  {
    "msg_id": "om_xxx",
    "session": "feishu:oc_xxx:ou_xxx",
    "user": "ou_xxx",
    "content_len": 65,
    "has_images": false,
    "has_audio": false,
    "has_files": false,
    "platform": "feishu"
  }
  ```

- `turn_complete`:
  ```json
  {
    "msg_id": "om_xxx",
    "session": "feishu:oc_xxx:ou_xxx",
    "agent_session": "d2720c67-...",
    "tools": 2,
    "response_len": 554,
    "turn_duration_sec": 15207.227,
    "input_tokens": 431,
    "output_tokens": 521
  }
  ```

- `permission_request`:
  ```json
  {
    "request_id": "...",
    "tool": "Bash",
    "session": "feishu:oc_xxx:ou_xxx"
  }
  ```

- `permission_resolved`:
  ```json
  {
    "request_id": "...",
    "session": "feishu:oc_xxx:ou_xxx"
  }
  ```

- `slow_agent_send`:
  ```json
  {
    "session": "feishu:oc_xxx:ou_xxx",
    "elapsed_sec": 12.5,
    "content_len": 1500
  }
  ```

### 3.2 Topic: `patrol.events`

**Purpose**: Patrol agent lifecycle events, heartbeat, anomaly detection results.

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 1 | Patrol events are low volume (~3 msg/min); no parallelism needed |
| Retention | 7 days | Keep a week of patrol history for post-mortem analysis |
| Cleanup policy | `delete` | Simple time-based |

**Message key**: `patrol_id` (string, one of `patrol-1`, `patrol-2`, `patrol-3`) or omitted (keyless for low-volume topics).

**Schema (envelope)**:

Same envelope structure reuses the `source` field:

```json
{
  "schema_version": "1.0",
  "source": "patrol",
  "event_type": "heartbeat | anomaly | recovery | patrol_death | patrol_respawn",
  "event_time": "2026-05-23T16:38:00.000Z",
  "producer": {
    "host": "kyb-boss",
    "patrol_id": "patrol-1",
    "instance": "kyb-infra-boss"
  },
  "payload": {
    // event-type-specific fields
  }
}
```

**Event types and payloads**:

- `heartbeat`:
  ```json
  {
    "status": "green",
    "uptime_sec": 3600,
    "checks": {
      "docker_ps": "ok",
      "disk_usage_pct": 45,
      "proxy_github": "ok",
      "proxy_gitlab": "ok",
      "cc_healthcheck": "ok"
    }
  }
  ```

- `anomaly`:
  ```json
  {
    "severity": "warning",
    "category": "brother_dead",
    "detail": "patrol-2 last heartbeat 16 min ago",
    "affected": ["patrol-2"],
    "sibling_status": {
      "patrol-2": {"last_hb": "2026-05-23T16:22:00Z", "age_min": 16},
      "patrol-3": {"last_hb": "2026-05-23T16:37:30Z", "age_min": 0.5}
    }
  }
  ```

- `recovery`:
  ```json
  {
    "previous_severity": "warning",
    "category": "brother_dead",
    "detail": "patrol-2 heartbeat resumed",
    "recovered_at": "2026-05-23T16:40:00Z"
  }
  ```

- `patrol_death`:
  ```json
  {
    "patrol_id": "patrol-2",
    "last_heartbeat": "2026-05-23T16:22:00Z",
    "detected_by": "patrol-1",
    "consecutive_misses": 3
  }
  ```

- `patrol_respawn`:
  ```json
  {
    "new_patrol_id": "patrol-2b",
    "previous_patrol_id": "patrol-2",
    "spawned_by": "boss"
  }
  ```

### 3.3 Topic: `system.events`

**Purpose**: Future system-level events from other infra components (healthcheck, cc-cron, hook executions, container lifecycle).

**Configuration**:

| Parameter | Value |
|-----------|-------|
| Partitions | 1 |
| Retention | 3 days |
| Cleanup policy | `delete` |

**Schema**: Same envelope as above, with `source` set to the component name (e.g., `"source": "cc-healthcheck"`, `"source": "hook-system"`).

This topic acts as a catch-all for events that do not belong to cc-connect or patrol. It guarantees that every infra component has a place to publish events without requiring a dedicated topic.

---

## 4. Schema Design

### 4.1 Envelope Schema (shared across all topics)

```
field              type        description
─────────────────────────────────────────────────────
schema_version     String      Envelope schema version (semver)
source             String      Producer name: "cc-connect", "patrol", etc.
event_type         String      Specific event type within the source's domain
event_time         DateTime64  When the event occurred on the producer (ISO-8601, ms precision)
producer.host      String      Hostname of the producer
producer.instance  String      Container or process name
payload            JSON        Event-type-specific data (opaque to the bus)
```

**Why a shared envelope**:

- Consumers can route events by `source` + `event_type` without parsing payload.
- Cross-event correlation: you can query "all events from any source in a 5-minute window" by indexing `event_time`.
- Schema evolution: the envelope is stable; only the payload changes per event type.
- Self-describing: `schema_version` allows the consumer to handle format migrations.

### 4.2 ClickHouse Table Schema

**`cc.message_log`** (replaces the current Vector-only table):

```sql
CREATE TABLE cc.message_log (
    event_time      DateTime64(3),
    source          LowCardinality(String),   -- always 'cc-connect'
    event_type      LowCardinality(String),   -- 'message_received', 'turn_complete', etc.
    msg_id          String,
    session         String,
    agent_session   String,
    user            String,
    platform        LowCardinality(String),
    content_len     UInt32,
    has_images      UInt8,
    has_audio       UInt8,
    has_files       UInt8,
    tools           UInt8,
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    request_id      String,
    tool            String,
    elapsed_sec     Float64,
    
    -- raw payload for forward compatibility
    payload_raw     String
) ENGINE = MergeTree
ORDER BY (event_time, msg_id)
TTL event_time + INTERVAL 90 DAY
```

**Notes**:
- Added `source` and `event_type` to distinguish events within the same table.
- Added `platform`, `has_audio`, `has_files` (fields present in actual cc-connect logs but missing from original schema).
- `payload_raw` stores the full original JSON for future fields not yet in the schema.
- Replaced `trace_id` sort key with `msg_id` -- cc-connect logs do not reliably include `trace_id` in structured INFO lines. `msg_id` is the join key between `message_received` and `turn_complete`.

**`patrol.event_log`**:

```sql
CREATE TABLE patrol.event_log (
    event_time      DateTime64(3),
    source          LowCardinality(String),   -- always 'patrol'
    event_type      LowCardinality(String),   -- 'heartbeat', 'anomaly', etc.
    patrol_id       LowCardinality(String),   -- 'patrol-1', etc.
    status          LowCardinality(String),   -- 'green', 'yellow', 'red'
    uptime_sec      UInt32,
    disk_usage_pct  Float32,
    severity        LowCardinality(String),
    category        LowCardinality(String),
    detail          String,
    
    -- raw payload for forward compatibility
    payload_raw     String
) ENGINE = MergeTree
ORDER BY (event_time)
TTL event_time + INTERVAL 90 DAY
```

**Note on patrol storage estimation**:

- Each heartbeat event: ~500 bytes (compressed)
- 3 agents, one heartbeat every 5 minutes = 864 events/day
- 90 days = ~38 MB (compressed, ClickHouse columnar)

Tiny. Not worth optimizing.

---

## 5. ClickHouse Kafka Engine Integration

ClickHouse has native Kafka integration via the `Kafka` table engine. This is the recommended consumer approach -- no need for a separate Vector deployment for Kafka consumption.

### 5.1 Kafka Engine Table (cc.events)

```sql
CREATE TABLE cc.kafka_queue (
    event_time      DateTime64(3),
    source          String,
    event_type      String,
    msg_id          String,
    session         String,
    agent_session   String,
    user            String,
    platform        String,
    content_len     UInt32,
    has_images      UInt8,
    has_audio       UInt8,
    has_files       UInt8,
    tools           UInt8,
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    request_id      String,
    tool            String,
    elapsed_sec     Float64,
    payload_raw     String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'cc.events',
    kafka_group_name = 'ck-consumer-cc',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

**Materialized View to MergeTree**:

```sql
CREATE MATERIALIZED VIEW cc.kafka_to_message_log TO cc.message_log AS
SELECT *
FROM cc.kafka_queue;
```

### 5.2 Kafka Engine Table (patrol.events)

```sql
CREATE TABLE patrol.kafka_queue (
    event_time      DateTime64(3),
    source          String,
    event_type      String,
    patrol_id       String,
    status          String,
    uptime_sec      UInt32,
    disk_usage_pct  Float32,
    severity        String,
    category        String,
    detail          String,
    payload_raw     String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'patrol.events',
    kafka_group_name = 'ck-consumer-patrol',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

**Materialized View to MergeTree**:

```sql
CREATE MATERIALIZED VIEW patrol.kafka_to_event_log TO patrol.event_log AS
SELECT *
FROM patrol.kafka_queue;
```

### 5.3 Error Handling

The Kafka Engine table silently skips messages that fail to parse. To capture parse errors:

1. **Dead letter queue** -- set up a secondary topic `cc.events.dlq` for messages that fail schema validation. A sidecar consumer periodically reviews the DLQ.
2. **ClickHouse table for errors** -- create `cc.kafka_parse_errors` with a `_error` column to capture raw messages that failed.

At current volume (~90 messages/day for cc-connect, ~864 events/day for patrol), manual DLQ review is feasible. If the error rate stays near zero for 30 days, the DLQ can be removed.

---

## 6. Kafka Deployment

### 6.1 Choice: Redpanda vs Apache Kafka

| Factor | Redpanda | Apache Kafka |
|--------|----------|--------------|
| Resource usage | Single binary, no JVM | JVM-based, heavier |
| Startup time | ~2 seconds | ~15-30 seconds |
| Configuration | Minimal (one config file) | Many tuning params |
| Compatibility | Kafka API-compatible | Native |
| Container image size | ~150 MB | ~500 MB+ |
| Single-node perf | Excellent | Good |

**Recommendation: Redpanda** for this deployment. At our scale (single broker, << 1 MB/day throughput), Redpanda's simplicity and low resource footprint win decisively. The Kafka API compatibility means all tools and libraries work identically.

### 6.2 Container Deployment

```bash
docker run -d \
  --name kyb-infra-redpanda \
  --restart unless-stopped \
  --network kyb-infra \
  -p 9092:9092 \
  -p 9644:9644 \
  -v kafka_data:/var/lib/redpanda/data \
  docker.redpanda.com/redpandadata/redpanda:latest \
  redpanda start \
    --mode dev-container \
    --kafka-addr PLAINTEXT://0.0.0.0:9092 \
    --advertise-kafka-addr PLAINTEXT://host.orb.internal:9092
```

**Key parameters**:
- `--mode dev-container`: optimized for development/small-scale, single node, no Raft consensus overhead
- `--advertise-kafka-addr`: must match what ClickHouse and producers will use to connect
- Volume: persistent volume for Kafka data across container restarts

### 6.3 Topic Creation

Automated via init script or `rpk` CLI at startup:

```bash
# cc.events
rpk topic create cc.events --partitions 3

# patrol.events
rpk topic create patrol.events --partitions 1

# system.events (future use)
rpk topic create system.events --partitions 1
```

### 6.4 Resource Estimates

| Resource | Estimate |
|----------|----------|
| CPU | Negligible (<< 0.1 core at this volume) |
| Memory | ~256 MB (Redpanda dev mode) |
| Disk (data) | ~200 MB / 90 days (all topics combined) |
| Disk (container) | ~150 MB (image) |
| Network | < 1 KB/s average throughput |

---

## 7. Producer Integration

### 7.1 cc-connect: Log Shipper Sidecar

cc-connect outputs logs to stdout in Go `slog` key=value format (not JSON). Rather than embedding a Kafka producer in cc-connect itself, a lightweight **log shipper sidecar** tails the Docker logs and publishes to Kafka.

**Option A -- Vector (recommended for migration)**:
Vector already has both a `docker_logs` source and a `kafka` sink. During migration, Vector can dual-write: continue sending to ClickHouse directly (existing pipeline) AND publish to Kafka (new pipeline). Once the Kafka pipeline is verified, the direct CK sink is removed.

Vector config (`vector-kafka-bridge.toml`):

```toml
[sources.cc_logs]
type = "docker_logs"
include_labels = ["kyb-infra-cc-connect"]

[transforms.parse_cc_logs]
type = "remap"
inputs = ["cc_logs"]
source = '''
  # Parse key=value format, construct envelope, emit to Kafka
  .schema_version = "1.0"
  .source = "cc-connect"
  .event_time = parse_timestamp!(.timestamp, "%+")
  .producer = {"host": get_hostname() ?? "unknown", "container_id": .container_id, "instance": "kyb-infra-cc-connect"}
  # ... field mapping logic per event type
'''

[sinks.cc_kafka]
type = "kafka"
inputs = ["parse_cc_logs"]
bootstrap_servers = "host.orb.internal:9092"
topic = "cc.events"
encoding.codec = "json"
```

**Option B -- Lightweight Go sidecar**:
A small Go binary (< 100 lines) that reads the cc-connect Docker log stream, parses the key=value lines, and publishes to Kafka. This is a cleaner long-term architecture (Vector is only needed for the Kafka bridge during migration, then can be removed entirely).

Given the tiny scale, Option B is feasible but Option A is preferred initially to avoid introducing a new binary to maintain.

### 7.2 Patrol: Inline Producer

Patrol agents write events directly from Ruby. Use the `ruby-kafka` gem or shell out to `kcat` (a lightweight Kafka CLI producer).

**Using `kcat`** (simplest, no gem dependency):

```ruby
def publish_event(event_type, payload)
  event = {
    schema_version: "1.0",
    source: "patrol",
    event_type: event_type,
    event_time: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
    producer: {
      host: `hostname`.strip,
      patrol_id: ENV["PATROL_ID"],
      instance: "kyb-infra-boss"
    },
    payload: payload
  }
  IO.popen("kcat -P -b host.orb.internal:9092 -t patrol.events", "w") do |pipe|
    pipe.puts event.to_json
  end
end
```

**Using `ruby-kafka` gem** (more robust, handles connection pooling and retries):

```ruby
require "kafka"

kafka = Kafka.new(["host.orb.internal:9092"], client_id: "patrol")

def publish_event(kafka, event_type, payload)
  event = {
    schema_version: "1.0",
    source: "patrol",
    event_type: event_type,
    event_time: Time.now.utc.strftime(...),
    producer: { host: ..., patrol_id: ..., instance: "kyb-infra-boss" },
    payload: payload
  }
  kafka.deliver_message(event.to_json, topic: "patrol.events")
end
```

**Recommendation**: `kcat` initially (zero dependency, dead simple). Switch to `ruby-kafka` if retry/async delivery becomes necessary.

---

## 8. Migration Strategy

### Phase 1: Kafka + Dual Pipeline (no risk)

1. Deploy Redpanda container.
2. Create topics (`cc.events`, `patrol.events`).
3. Keep the existing Vector -> ClickHouse pipeline running unchanged.
4. Deploy a SECOND Vector instance (or a second config) that ALSO reads cc-connect logs and publishes to Kafka.
5. Kafka consumes into CK via Kafka Engine table alongside the existing `cc.message_log`.

At the end of Phase 1, data flows:
```
cc-connect -> Vector -> CK (existing, untouched)
cc-connect -> Vector -> Kafka -> CK Kafka Engine (new, side-by-side)
patrol -> kcat -> Kafka -> CK Kafka Engine (new)
```

### Phase 2: Verify and Switch

1. Run both pipelines for 24 hours.
2. Verify row counts match between direct Vector ingestion and Kafka-sourced ingestion.
3. Switch Grafana dashboards to the Kafka-sourced table.
4. Remove the Vector direct CK sink; keep Vector only as the cc-connect log shipper to Kafka.

At the end of Phase 2:
```
cc-connect -> Vector -> Kafka -> CK Kafka Engine
patrol -> kcat -> Kafka -> CK Kafka Engine
```

### Phase 3: Optional -- Remove Vector

1. Replace Vector with a lightweight log shipper sidecar (Go binary or shell script).
2. Remove Vector entirely.

If the log shipper sidecar seems like over-engineering at this scale (it probably is), skip Phase 3. Vector stays as the log shipper. The key benefit is already achieved: a unified event bus with replay capability.

---

## 9. Failure Modes and Recovery

| Failure | Effect | Recovery |
|---------|--------|----------|
| Kafka broker down | Producers cannot publish. cc-connect/patrol continue running; events are lost during downtime. | Restart container. Events lost during downtime are not recoverable (log shipper has no persistence). |
| CK down | Kafka consumption stops; events accumulate in Kafka (up to 7d retention). | Restart CK. Kafka consumer resumes from where it left off (committed offset). **No data loss.** |
| CK permanently destroyed (volume loss) | Kafka can replay all events within the 7d retention window. | Create new CK table, consumer resumes from earliest offset. **Partial recovery (up to 7d).** |
| Kafka volume loss | All un-consumed events lost. | CK has all previously consumed data. Only events in Kafka that had not yet been consumed are lost. |

The key improvement over the current architecture: **CK downtime no longer causes data loss**. As long as Kafka is up, events are buffered until CK recovers.

---

## 10. Operational Considerations

### 10.1 Monitoring Kafka

- **Redpanda metrics endpoint**: `http://host.orb.internal:9644/metrics` (Prometheus format)
- **Key metrics**: consumer lag (per consumer group), under-replicated partitions, disk usage
- **Grafana**: Add Redpanda dashboard from the Grafana marketplace or create a simple one with:
  - Consumer lag time series (`patrol.events` and `cc.events`)
  - Message rate per topic
  - Broker disk usage

### 10.2 Capacity Planning

At current volume:
- All topics combined: ~900 events/day, ~500 KB/day
- 7-day retention: ~3.5 MB
- 90-day CK retention: ~40 MB (both tables combined)

This is **~0.01% of a typical Kafka node's capacity**. No scaling concerns for the foreseeable future.

### 10.3 Authentication and Authorization

At this scale (single broker, internal network only, no sensitive data), TLS and SASL are unnecessary overhead. The topic is accessible without authentication within the Docker network.

If the bus grows to include sensitive data in the future, add:
- SASL/PLAIN authentication
- TLS encryption for client-broker communication
- ACLs restricting producer/consumer access per topic

### 10.4 When NOT to Use Kafka

Kafka adds operational complexity. It is worth it here because:
- Multiple producers need a unified pipeline
- CK is the single sink but may have intermittent availability
- Replay capability is valuable for post-mortem analysis

If you have only a single producer that always has a direct connection to the sink, Kafka is unnecessary overhead. The current Vector-only pipeline is simpler and works fine for cc-connect in isolation. The value of Kafka emerges when you add patrol, healthcheck, and future producers -- suddenly each one does not need its own ClickHouse ingestion logic.

---

## 11. Future Topics

### 11.1 `bridge.events`

For the feishu-bridge system itself: hook execution logs, cc-cron job results, session lifecycle events. Once the bus is established, every component in the infra can publish without needing a new pipeline.

### 11.2 `container.events`

Docker container lifecycle events: start, stop, restart, health check failures. Could be produced by a simple Docker events watcher. Valuable for correlating container restarts with anomaly events in patrol.

---

## 12. Appendices

### A. Quick Start (New Machine)

```bash
# 1. Start Redpanda
docker run -d --name kyb-infra-redpanda \
  --restart unless-stopped \
  --network kyb-infra \
  -p 9092:9092 -p 9644:9644 \
  -v kafka_data:/var/lib/redpanda/data \
  docker.redpanda.com/redpandadata/redpanda:latest \
  redpanda start --mode dev-container \
    --kafka-addr PLAINTEXT://0.0.0.0:9092 \
    --advertise-kafka-addr PLAINTEXT://host.orb.internal:9092

# 2. Create topics
rpk topic create cc.events --partitions 3
rpk topic create patrol.events --partitions 1
rpk topic create system.events --partitions 1

# 3. Verify
rpk topic list
rpk topic produce patrol.events <<< '{"test": "hello"}'
rpk topic consume patrol.events --num 1
```

### B. ClickHouse Kafka Engine DDL

```sql
-- cc.events queue
CREATE TABLE cc.kafka_queue ...
CREATE MATERIALIZED VIEW cc.kafka_to_message_log TO cc.message_log AS SELECT * FROM cc.kafka_queue;

-- patrol.events queue
CREATE TABLE patrol.kafka_queue ...
CREATE MATERIALIZED VIEW patrol.kafka_to_event_log TO patrol.event_log AS SELECT * FROM patrol.kafka_queue;
```

### C. Patrol Producer Snippet (kcat)

```bash
#!/bin/bash
# patrol-publish.sh -- publish an event to patrol.events
PATROL_ID="${1}" EVENT_TYPE="${2}" STATUS="${3:-green}"
shift 3
PAYLOAD=$(echo "$@" | jq -Rc '{detail: .}')

kcat -P -b host.orb.internal:9092 -t patrol.events <<EOF
{
  "schema_version": "1.0",
  "source": "patrol",
  "event_type": "${EVENT_TYPE}",
  "event_time": "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)",
  "producer": {
    "host": "$(hostname)",
    "patrol_id": "${PATROL_ID}",
    "instance": "kyb-infra-boss"
  },
  "payload": {
    "status": "${STATUS}",
    ${PAYLOAD}
  }
}
EOF
```
